#!/bin/sh
set -eu

cd /var/www/html

# Seeding writes only core tables. Skipping plugin and theme loading keeps each
# of the ~200 wp calls below from booting every active plugin.
# configure-plugins.php runs later, with everything loaded.
wp() {
  command wp --skip-plugins --skip-themes "$@"
}

log() {
  printf '\n==> %s\n' "$*"
}

post_id_by_slug() {
  wp post list \
    --post_type="$1" \
    --name="$2" \
    --field=ID \
    --format=ids | awk '{print $1}'
}

page_upsert() {
  slug="$1"
  title="$2"
  content_file="$3"

  id="$(post_id_by_slug page "$slug")"

  if [ -n "$id" ]; then
    wp post update "$id" \
      --post_title="$title" \
      --post_content="$(cat "$content_file")" \
      --post_status=publish >/dev/null
  else
    id="$(wp post create \
      --post_type=page \
      --post_status=publish \
      --post_title="$title" \
      --post_name="$slug" \
      --post_content="$(cat "$content_file")" \
      --porcelain)"
  fi

  printf '%s' "$id"
}

# Creates the page with initial content but never rewrites an existing one.
# Used for pages whose content another step owns afterwards.
page_ensure() {
  slug="$1"
  title="$2"
  content_file="$3"

  id="$(post_id_by_slug page "$slug")"

  if [ -z "$id" ]; then
    id="$(wp post create \
      --post_type=page \
      --post_status=publish \
      --post_title="$title" \
      --post_name="$slug" \
      --post_content="$(cat "$content_file")" \
      --porcelain)"
  fi

  printf '%s' "$id"
}

term_ensure() {
  taxonomy="$1"
  slug="$2"
  name="$3"

  id="$(wp term get "$taxonomy" "$slug" \
      --by=slug \
      --field=term_id 2>/dev/null || true)"

  if [ -z "$id" ]; then
    id="$(wp term create "$taxonomy" "$name" \
      --slug="$slug" \
      --porcelain)"
  fi

  printf '%s' "$id"
}

user_ensure() {
  login="$1"
  email="$2"
  display="$3"
  first="$4"
  last="$5"

  id="$(wp user get "$login" --field=ID 2>/dev/null || true)"

  if [ -z "$id" ]; then
    id="$(wp user create "$login" "$email" \
      --role=author \
      --display_name="$display" \
      --user_pass='northstar-author-poc' \
      --porcelain)"
  fi

  wp user update "$id" \
    --display_name="$display" \
    --first_name="$first" \
    --last_name="$last" >/dev/null

  printf '%s' "$id"
}

post_upsert() {
  slug="$1"
  title="$2"
  author_id="$3"
  category_slug="$4"
  tags_csv="$5"
  content_file="$6"
  excerpt="$7"

  id="$(post_id_by_slug post "$slug")"

  # Articles accept comments explicitly, independent of the site-wide
  # default_comment_status that after-install.sh closes.
  if [ -n "$id" ]; then
    wp post update "$id" \
      --post_title="$title" \
      --post_content="$(cat "$content_file")" \
      --post_excerpt="$excerpt" \
      --post_author="$author_id" \
      --comment_status=open \
      --post_status=publish >/dev/null
  else
    id="$(wp post create \
      --post_type=post \
      --post_status=publish \
      --post_title="$title" \
      --post_name="$slug" \
      --post_content="$(cat "$content_file")" \
      --post_excerpt="$excerpt" \
      --post_author="$author_id" \
      --comment_status=open \
      --porcelain)"
  fi

  wp post term set "$id" category "$category_slug" --by=slug >/dev/null

  old_ifs="$IFS"
  IFS=','
  # shellcheck disable=SC2086
  set -- $tags_csv
  IFS="$old_ifs"

  if [ "$#" -gt 0 ]; then
    wp post term set "$id" post_tag "$@" --by=slug >/dev/null
  fi

  printf '%s' "$id"
}

featured_image_ensure() {
  post_id="$1"
  seed="$2"
  title="$3"

  thumb="$(wp post meta get "$post_id" _thumbnail_id 2>/dev/null || true)"
  if [ -n "$thumb" ]; then
    return 0
  fi

  # Remote media is intentionally best-effort. The PoC still works if the
  # machine is temporarily offline after images/plugins are already cached.
  wp media import \
    "https://picsum.photos/seed/${seed}/1200/675.jpg" \
    --post_id="$post_id" \
    --featured_image \
    --title="$title" \
    --alt="$title" >/dev/null 2>&1 || \
    echo "WARNING: could not import featured image for post $post_id"
}

comment_seed_if_empty() {
  post_id="$1"

  count="$(wp comment list \
    --post_id="$post_id" \
    --status=approve \
    --format=count)"

  if [ "$count" -gt 0 ]; then
    return 0
  fi

  wp comment create \
    --comment_post_ID="$post_id" \
    --comment_author="Maya Chen" \
    --comment_author_email="maya@example.test" \
    --comment_content="Clear explanation. The trade-offs section is especially useful for teams that need to move incrementally." \
    --comment_approved=1 >/dev/null

  wp comment create \
    --comment_post_ID="$post_id" \
    --comment_author="Jonas Vermeer" \
    --comment_author_email="jonas@example.test" \
    --comment_content="We ran into a similar issue during a platform migration. Measuring the baseline first made the biggest difference." \
    --comment_approved=1 >/dev/null
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

log "Configuring fictional Northstar Digital demo site"

# Site-wide visibility and discussion defaults live in after-install.sh.
wp option update blogname "Northstar Digital" >/dev/null
wp option update blogdescription "Cloud, DevOps and security engineering for growing teams." >/dev/null
wp option update posts_per_page 6 >/dev/null

log "Installing and activating Twenty Twenty-Five"
if wp theme is-installed twentytwentyfive >/dev/null 2>&1; then
  wp theme update twentytwentyfive >/dev/null 2>&1 || true
else
  wp theme install twentytwentyfive >/dev/null
fi
wp theme activate twentytwentyfive >/dev/null

log "Creating realistic authors"
AUTHOR_ELENA="$(user_ensure elena.rossi elena.rossi@example.test "Elena Rossi" Elena Rossi)"
AUTHOR_SAMIR="$(user_ensure samir.patel samir.patel@example.test "Samir Patel" Samir Patel)"
AUTHOR_NOOR="$(user_ensure noor.janssens noor.janssens@example.test "Noor Janssens" Noor Janssens)"

log "Creating categories and tags"
term_ensure category cloud-engineering "Cloud Engineering" >/dev/null
term_ensure category devops "DevOps" >/dev/null
term_ensure category security "Security" >/dev/null
term_ensure category platform-engineering "Platform Engineering" >/dev/null
term_ensure category reliability "Reliability" >/dev/null

for item in \
  "aws:AWS" \
  "kubernetes:Kubernetes" \
  "terraform:Terraform" \
  "cicd:CI/CD" \
  "containers:Containers" \
  "observability:Observability" \
  "sre:SRE" \
  "devsecops:DevSecOps" \
  "finops:FinOps" \
  "incident-response:Incident Response" \
  "platform:Platform" \
  "automation:Automation"
do
  slug="${item%%:*}"
  name="${item#*:}"
  term_ensure post_tag "$slug" "$name" >/dev/null
done

cat >"$tmpdir/home.html" <<'EOF'
<!-- wp:group {"layout":{"type":"constrained"}} -->
<div class="wp-block-group">
<!-- wp:heading {"level":1,"fontSize":"xx-large"} -->
<h1 class="wp-block-heading has-xx-large-font-size">Modern infrastructure. Secure by design.</h1>
<!-- /wp:heading -->

<!-- wp:paragraph {"fontSize":"large"} -->
<p class="has-large-font-size">Northstar Digital helps growing companies build reliable cloud platforms, automate delivery pipelines and improve application security without slowing developers down.</p>
<!-- /wp:paragraph -->

<!-- wp:buttons -->
<div class="wp-block-buttons">
<!-- wp:button --><div class="wp-block-button"><a class="wp-block-button__link wp-element-button" href="/services/">Explore our services</a></div><!-- /wp:button -->
<!-- wp:button {"className":"is-style-outline"} --><div class="wp-block-button is-style-outline"><a class="wp-block-button__link wp-element-button" href="/contact/">Talk to our team</a></div><!-- /wp:button -->
</div>
<!-- /wp:buttons -->

<!-- wp:separator --><hr class="wp-block-separator has-alpha-channel-opacity"/><!-- /wp:separator -->

<!-- wp:heading --><h2 class="wp-block-heading">What we do</h2><!-- /wp:heading -->

<!-- wp:columns -->
<div class="wp-block-columns">
<div class="wp-block-column"><h3>Cloud Engineering</h3><p>Design and operate scalable AWS and Kubernetes platforms with infrastructure as code, sensible guardrails and clear ownership.</p></div>
<div class="wp-block-column"><h3>DevOps</h3><p>Automate builds, testing and deployment so engineering teams can ship changes safely and repeatedly.</p></div>
<div class="wp-block-column"><h3>Security</h3><p>Move security checks into everyday delivery workflows with practical DevSecOps controls and actionable feedback.</p></div>
</div>
<!-- /wp:columns -->

<!-- wp:columns -->
<div class="wp-block-columns">
<div class="wp-block-column"><h3>Platform Engineering</h3><p>Create paved roads that give developers self-service infrastructure without exposing unnecessary complexity.</p></div>
<div class="wp-block-column"><h3>Reliability</h3><p>Improve observability, incident response and service resilience using measurable SRE practices.</p></div>
<div class="wp-block-column"><h3>Cloud Cost</h3><p>Reduce waste with right-sizing, lifecycle policies and architecture decisions that balance cost against reliability.</p></div>
</div>
<!-- /wp:columns -->

<!-- wp:heading --><h2 class="wp-block-heading">Engineering outcomes</h2><!-- /wp:heading -->
<!-- wp:columns -->
<div class="wp-block-columns">
<div class="wp-block-column"><p><strong>99.95%</strong><br>average platform availability</p></div>
<div class="wp-block-column"><p><strong>40%</strong><br>faster deployment cycles</p></div>
<div class="wp-block-column"><p><strong>25+</strong><br>successful cloud migrations</p></div>
<div class="wp-block-column"><p><strong>24/7</strong><br>infrastructure visibility</p></div>
</div>
<!-- /wp:columns -->

<!-- wp:heading --><h2 class="wp-block-heading">Recent work</h2><!-- /wp:heading -->
<!-- wp:list -->
<ul class="wp-block-list">
<li><strong>Modernising a growing SaaS platform:</strong> migrated legacy workloads into a repeatable Kubernetes platform without customer downtime.</li>
<li><strong>Building a secure CI/CD platform:</strong> introduced automated code, dependency, container and infrastructure security checks.</li>
<li><strong>Scaling for seasonal traffic:</strong> improved autoscaling and observability while reducing idle cloud capacity.</li>
</ul>
<!-- /wp:list -->

<!-- wp:heading --><h2 class="wp-block-heading">Latest insights</h2><!-- /wp:heading -->
<!-- wp:latest-posts {"postsToShow":4,"displayPostDate":true} /-->
</div>
<!-- /wp:group -->
EOF

cat >"$tmpdir/about.html" <<'EOF'
<!-- wp:heading {"level":1} --><h1 class="wp-block-heading">About Northstar Digital</h1><!-- /wp:heading -->
<!-- wp:paragraph --><p>Northstar Digital is a fictional technology consultancy created for this Kubernetes WordPress lab. The site is deliberately populated like a real small consultancy so security scanners, caching tests, search, media handling and WordPress APIs have meaningful content to work with.</p><!-- /wp:paragraph -->
<!-- wp:heading --><h2 class="wp-block-heading">How we work</h2><!-- /wp:heading -->
<!-- wp:list --><ul class="wp-block-list"><li>Start with measurable reliability and delivery goals.</li><li>Automate repetitive platform operations.</li><li>Prefer secure defaults over manual review gates.</li><li>Make observability part of the application lifecycle.</li><li>Document operational ownership and recovery paths.</li></ul><!-- /wp:list -->
<!-- wp:heading --><h2 class="wp-block-heading">Our team</h2><!-- /wp:heading -->
<!-- wp:paragraph --><p>Our engineers combine cloud architecture, application delivery, Kubernetes, security engineering and site reliability experience. The names and biographies on this demo site are fictional.</p><!-- /wp:paragraph -->
EOF

cat >"$tmpdir/services.html" <<'EOF'
<!-- wp:heading {"level":1} --><h1 class="wp-block-heading">Services</h1><!-- /wp:heading -->
<!-- wp:heading --><h2 class="wp-block-heading">Cloud platform engineering</h2><!-- /wp:heading -->
<!-- wp:paragraph --><p>Landing zones, network architecture, Kubernetes platforms, infrastructure as code and workload migration with a focus on maintainability and clear operational boundaries.</p><!-- /wp:paragraph -->
<!-- wp:heading --><h2 class="wp-block-heading">CI/CD and developer experience</h2><!-- /wp:heading -->
<!-- wp:paragraph --><p>Build pipelines, deployment automation, artifact management, reusable workflows and internal platform capabilities designed to shorten feedback loops.</p><!-- /wp:paragraph -->
<!-- wp:heading --><h2 class="wp-block-heading">DevSecOps</h2><!-- /wp:heading -->
<!-- wp:paragraph --><p>Secret scanning, dependency analysis, SAST, container scanning, IaC policy checks, DAST and vulnerability triage integrated into delivery pipelines.</p><!-- /wp:paragraph -->
<!-- wp:heading --><h2 class="wp-block-heading">Reliability and observability</h2><!-- /wp:heading -->
<!-- wp:paragraph --><p>Service-level objectives, metrics, logs, traces, alert design, runbooks and incident response practices that help teams understand systems before customers report problems.</p><!-- /wp:paragraph -->
EOF

cat >"$tmpdir/case-studies.html" <<'EOF'
<!-- wp:heading {"level":1} --><h1 class="wp-block-heading">Case Studies</h1><!-- /wp:heading -->
<!-- wp:heading --><h2 class="wp-block-heading">SaaS platform migration</h2><!-- /wp:heading -->
<!-- wp:paragraph --><p>A growing software company needed to move a manually operated application estate to Kubernetes. Northstar designed a staged migration using infrastructure as code, managed databases and progressive delivery. Deployment frequency increased while recovery procedures became repeatable.</p><!-- /wp:paragraph -->
<!-- wp:heading --><h2 class="wp-block-heading">Secure software delivery</h2><!-- /wp:heading -->
<!-- wp:paragraph --><p>A product team had multiple security tools but little consistency. We created a reusable CI/CD security workflow covering secrets, dependencies, containers and infrastructure. Findings were routed to developers with severity thresholds and documented exception handling.</p><!-- /wp:paragraph -->
<!-- wp:heading --><h2 class="wp-block-heading">Seasonal scale without permanent cost</h2><!-- /wp:heading -->
<!-- wp:paragraph --><p>An online service experienced short periods of very high demand. Capacity tests, autoscaling policies and improved dashboards allowed the platform to absorb traffic bursts while scaling back when demand returned to normal.</p><!-- /wp:paragraph -->
EOF

cat >"$tmpdir/privacy.html" <<'EOF'
<!-- wp:heading {"level":1} --><h1 class="wp-block-heading">Privacy Policy</h1><!-- /wp:heading -->
<!-- wp:paragraph --><p>This website is a local demonstration environment. Any names, email addresses, companies, metrics and contact details shown here are fictional test data.</p><!-- /wp:paragraph -->
<!-- wp:heading --><h2 class="wp-block-heading">Demo data</h2><!-- /wp:heading -->
<!-- wp:paragraph --><p>The site may store test comments, administrator activity, plugin configuration and locally generated WordPress data in its MariaDB database and shared WordPress filesystem.</p><!-- /wp:paragraph -->
<!-- wp:heading --><h2 class="wp-block-heading">External services</h2><!-- /wp:heading -->
<!-- wp:paragraph --><p>During initial provisioning the lab can download plugins, themes and placeholder images from public repositories. Do not place real personal or confidential data in this PoC.</p><!-- /wp:paragraph -->
EOF

cat >"$tmpdir/insights.html" <<'EOF'
<!-- wp:heading {"level":1} --><h1 class="wp-block-heading">Insights</h1><!-- /wp:heading -->
<!-- wp:paragraph --><p>Practical notes on cloud engineering, Kubernetes, delivery automation, security and reliability.</p><!-- /wp:paragraph -->
EOF

HOME_ID="$(page_upsert home "Home" "$tmpdir/home.html")"
ABOUT_ID="$(page_upsert about "About" "$tmpdir/about.html")"
SERVICES_ID="$(page_upsert services "Services" "$tmpdir/services.html")"
CASE_ID="$(page_upsert case-studies "Case Studies" "$tmpdir/case-studies.html")"
INSIGHTS_ID="$(page_upsert insights "Insights" "$tmpdir/insights.html")"
# configure-plugins.php owns the Contact content after creation: it embeds
# the Contact Form 7 form, or restores contact.html when CF7 is inactive.
CONTACT_ID="$(page_ensure contact "Contact" /bootstrap/contact.html)"
PRIVACY_ID="$(page_upsert privacy-policy "Privacy Policy" "$tmpdir/privacy.html")"

wp option update show_on_front page >/dev/null
wp option update page_on_front "$HOME_ID" >/dev/null
wp option update page_for_posts "$INSIGHTS_ID" >/dev/null
wp option update wp_page_for_privacy_policy "$PRIVACY_ID" >/dev/null

log "Reconciling classic Primary menu fallback"

# Core's menu API rather than raw SQL. A failed query used to look like "no
# menu yet" and created a duplicate menu, so errors here must stop the run.
# Repeated runs are idempotent: existing pages are detected and skipped.
cat >"$tmpdir/primary-menu.php" <<'EOF'
<?php
// Usage: wp eval-file primary-menu.php <page-id>...
// Creates the Primary menu if needed, then adds each listed page that is not
// already in it.
$menu = wp_get_nav_menu_object( 'Primary' );

if ( $menu ) {
	$menu_id = (int) $menu->term_id;
	WP_CLI::log( "Reusing Primary menu (term ID: $menu_id)." );
} else {
	$menu_id = wp_create_nav_menu( 'Primary' );

	if ( is_wp_error( $menu_id ) ) {
		WP_CLI::error( $menu_id->get_error_message() );
	}

	WP_CLI::log( 'Creating Primary menu...' );
}

$in_menu = array();

foreach ( (array) wp_get_nav_menu_items( $menu_id, array( 'post_status' => 'any' ) ) as $item ) {
	if ( 'post_type' === $item->type ) {
		$in_menu[ (int) $item->object_id ] = true;
	}
}

foreach ( $args as $page_id ) {
	$page_id = (int) $page_id;

	if ( isset( $in_menu[ $page_id ] ) ) {
		continue;
	}

	$item_id = wp_update_nav_menu_item(
		$menu_id,
		0,
		array(
			'menu-item-object-id' => $page_id,
			'menu-item-object'    => 'page',
			'menu-item-type'      => 'post_type',
			'menu-item-status'    => 'publish',
		)
	);

	if ( is_wp_error( $item_id ) ) {
		WP_CLI::error( $item_id->get_error_message() );
	}
}
EOF

wp eval-file "$tmpdir/primary-menu.php" \
  "$HOME_ID" "$SERVICES_ID" "$CASE_ID" "$ABOUT_ID" "$INSIGHTS_ID" "$CONTACT_ID"

log "Creating realistic articles"

create_article_file() {
  slug="$1"
  shift
  cat >"$tmpdir/$slug.html"
}

create_article_file "improve-cloud-security" <<'EOF'
<!-- wp:paragraph --><p>Cloud security improves fastest when teams focus on a few controls that apply everywhere rather than a long list of exceptions. Start with identity, network boundaries, software supply chain visibility and reliable logging.</p><!-- /wp:paragraph -->
<!-- wp:heading --><h2 class="wp-block-heading">1. Reduce standing privilege</h2><!-- /wp:heading -->
<!-- wp:paragraph --><p>Prefer short-lived roles and workload identities over long-lived access keys. Review privileged paths, require MFA for human access and separate deployment permissions from day-to-day read access.</p><!-- /wp:paragraph -->
<!-- wp:heading --><h2 class="wp-block-heading">2. Treat infrastructure as code as production code</h2><!-- /wp:heading -->
<!-- wp:paragraph --><p>Changes to networks, IAM policies and Kubernetes resources should be reviewed, scanned and reproducible. Policy checks are most useful when they explain exactly why a risky configuration was rejected.</p><!-- /wp:paragraph -->
<!-- wp:heading --><h2 class="wp-block-heading">3. Centralise security telemetry</h2><!-- /wp:heading -->
<!-- wp:paragraph --><p>Collect audit logs, workload events and identity activity in a place that survives the failure of the system being investigated. Alerts should point to a response path, not merely state that something unusual occurred.</p><!-- /wp:paragraph -->
EOF

create_article_file "reliable-cicd-pipeline" <<'EOF'
<!-- wp:paragraph --><p>A reliable delivery pipeline is less about having many stages and more about making each stage deterministic. The same commit should produce the same artifact, and that artifact should progress through environments without being rebuilt.</p><!-- /wp:paragraph -->
<!-- wp:heading --><h2 class="wp-block-heading">Build once</h2><!-- /wp:heading -->
<!-- wp:paragraph --><p>Create an immutable artifact, attach provenance and an SBOM, then promote the artifact rather than rebuilding source code for each environment.</p><!-- /wp:paragraph -->
<!-- wp:heading --><h2 class="wp-block-heading">Fail early, but keep feedback useful</h2><!-- /wp:heading -->
<!-- wp:paragraph --><p>Fast checks such as formatting, unit tests and secret scanning belong near the beginning. Longer integration and dynamic tests can run after an artifact exists. Security findings need severity and ownership rules so pipelines do not become permanently red.</p><!-- /wp:paragraph -->
EOF

create_article_file "when-to-use-kubernetes" <<'EOF'
<!-- wp:paragraph --><p>Kubernetes is valuable when a team needs consistent workload scheduling, service discovery, declarative rollout behaviour and a common operational model across many services. It is not automatically the simplest answer for every application.</p><!-- /wp:paragraph -->
<!-- wp:heading --><h2 class="wp-block-heading">Good signals</h2><!-- /wp:heading -->
<!-- wp:list --><ul class="wp-block-list"><li>Many independently deployed services.</li><li>Teams already operate containers at scale.</li><li>High availability and rollout controls are important.</li><li>A platform team can own cluster-level capabilities.</li></ul><!-- /wp:list -->
<!-- wp:heading --><h2 class="wp-block-heading">Warning signs</h2><!-- /wp:heading -->
<!-- wp:paragraph --><p>If one small team owns two simple applications and has no need for platform abstraction, a managed application service may deliver more value with much less operational overhead.</p><!-- /wp:paragraph -->
EOF

create_article_file "reduce-cloud-costs" <<'EOF'
<!-- wp:paragraph --><p>Cost optimisation is most sustainable when it is part of architecture and operations rather than an occasional cleanup exercise. Start by understanding which resources are expensive and which business capability they support.</p><!-- /wp:paragraph -->
<!-- wp:heading --><h2 class="wp-block-heading">Measure before resizing</h2><!-- /wp:heading -->
<!-- wp:paragraph --><p>CPU alone is rarely enough. Review memory pressure, storage throughput, network patterns, request latency and scaling behaviour. Rightsizing without this context can simply trade cloud spend for instability.</p><!-- /wp:paragraph -->
<!-- wp:heading --><h2 class="wp-block-heading">Automate obvious waste</h2><!-- /wp:heading -->
<!-- wp:paragraph --><p>Non-production schedules, lifecycle rules, stale snapshots and abandoned environments are good automation targets. These savings repeat every month without requiring engineers to remember a cleanup checklist.</p><!-- /wp:paragraph -->
EOF

create_article_file "production-platform-migration" <<'EOF'
<!-- wp:paragraph --><p>The safest production migrations are designed around reversible steps. Instead of planning one large cutover, create checkpoints where traffic, data and operational responsibility can move independently.</p><!-- /wp:paragraph -->
<!-- wp:heading --><h2 class="wp-block-heading">Establish a baseline</h2><!-- /wp:heading -->
<!-- wp:paragraph --><p>Before changing the platform, capture current latency, error rates, deployment times, recovery procedures and cost. Without a baseline it is difficult to prove that the migration improved anything.</p><!-- /wp:paragraph -->
<!-- wp:heading --><h2 class="wp-block-heading">Move observability first</h2><!-- /wp:heading -->
<!-- wp:paragraph --><p>Dashboards and logs should understand both old and new environments before customer traffic changes. This shortens troubleshooting when behaviour differs during the transition.</p><!-- /wp:paragraph -->
EOF

create_article_file "why-infrastructure-as-code-matters" <<'EOF'
<!-- wp:paragraph --><p>Infrastructure as code turns environment configuration into reviewable, repeatable change. Its biggest benefit is not syntax; it is that infrastructure stops depending on undocumented console history.</p><!-- /wp:paragraph -->
<!-- wp:heading --><h2 class="wp-block-heading">Review becomes possible</h2><!-- /wp:heading -->
<!-- wp:paragraph --><p>Network routes, IAM policy and service configuration can be discussed before they are applied. Automated checks can enforce organisational requirements consistently.</p><!-- /wp:paragraph -->
<!-- wp:heading --><h2 class="wp-block-heading">Recovery becomes less mysterious</h2><!-- /wp:heading -->
<!-- wp:paragraph --><p>When infrastructure definitions, state strategy and bootstrap dependencies are understood, rebuilding a damaged environment becomes an engineering process instead of an archaeological exercise.</p><!-- /wp:paragraph -->
EOF

create_article_file "container-security-guide" <<'EOF'
<!-- wp:paragraph --><p>Container security begins before the image is built. Dependencies, base images, build provenance and runtime permissions all contribute to the final risk profile.</p><!-- /wp:paragraph -->
<!-- wp:heading --><h2 class="wp-block-heading">Keep images intentional</h2><!-- /wp:heading -->
<!-- wp:paragraph --><p>Use a small runtime base, pin important dependencies, remove build tools from the final stage and run as a non-root user. Scan the image, but also know which packages are actually reachable by the application.</p><!-- /wp:paragraph -->
<!-- wp:heading --><h2 class="wp-block-heading">Runtime still matters</h2><!-- /wp:heading -->
<!-- wp:paragraph --><p>Read-only filesystems, dropped Linux capabilities, resource limits and network policy reduce the impact of a compromised process. Image scanning and runtime controls solve different problems.</p><!-- /wp:paragraph -->
EOF

create_article_file "kubernetes-metrics-that-matter" <<'EOF'
<!-- wp:paragraph --><p>A Kubernetes dashboard can contain hundreds of charts and still fail to answer the question operators care about: is the service healthy for users?</p><!-- /wp:paragraph -->
<!-- wp:heading --><h2 class="wp-block-heading">Start from service behaviour</h2><!-- /wp:heading -->
<!-- wp:paragraph --><p>Request rate, error rate and latency usually matter before pod CPU. Infrastructure metrics explain why service behaviour changed; they are not a replacement for service-level signals.</p><!-- /wp:paragraph -->
<!-- wp:heading --><h2 class="wp-block-heading">Watch scheduling and saturation</h2><!-- /wp:heading -->
<!-- wp:paragraph --><p>Pending pods, memory pressure, throttling, restart frequency and unavailable replicas reveal capacity or workload problems that may not yet be visible in average CPU charts.</p><!-- /wp:paragraph -->
EOF

create_article_file "zero-downtime-deployments" <<'EOF'
<!-- wp:paragraph --><p>Zero-downtime deployment is a coordination problem between application readiness, traffic routing and compatibility. Kubernetes provides useful primitives, but applications still need to behave correctly during overlap.</p><!-- /wp:paragraph -->
<!-- wp:heading --><h2 class="wp-block-heading">Readiness controls traffic</h2><!-- /wp:heading -->
<!-- wp:paragraph --><p>A pod should only receive traffic when it can serve real requests. Startup probes prevent slow applications from being killed prematurely, while readiness probes keep unhealthy instances out of service endpoints.</p><!-- /wp:paragraph -->
<!-- wp:heading --><h2 class="wp-block-heading">Keep database changes compatible</h2><!-- /wp:heading -->
<!-- wp:paragraph --><p>During rolling updates old and new application versions can run together. Expand-and-contract database changes avoid forcing every replica to change at exactly the same moment.</p><!-- /wp:paragraph -->
EOF

create_article_file "managed-vs-self-hosted-kubernetes" <<'EOF'
<!-- wp:paragraph --><p>Managed Kubernetes removes part of the control-plane burden, but it does not remove responsibility for workload security, networking choices, node lifecycle, observability or platform design.</p><!-- /wp:paragraph -->
<!-- wp:heading --><h2 class="wp-block-heading">Managed usually wins for production teams</h2><!-- /wp:heading -->
<!-- wp:paragraph --><p>Cloud-managed offerings reduce undifferentiated control-plane work and integrate with identity, load balancing and storage services. This lets platform teams spend more time on workload experience.</p><!-- /wp:paragraph -->
<!-- wp:heading --><h2 class="wp-block-heading">Self-hosting still has a place</h2><!-- /wp:heading -->
<!-- wp:paragraph --><p>Edge environments, disconnected systems, specialised infrastructure and learning labs can justify self-managed clusters. The operational cost should be treated as a real product requirement.</p><!-- /wp:paragraph -->
EOF

create_article_file "platform-engineering-developer-experience" <<'EOF'
<!-- wp:paragraph --><p>Platform engineering works when it removes repeated decisions from product teams without hiding the information they need to operate their services.</p><!-- /wp:paragraph -->
<!-- wp:heading --><h2 class="wp-block-heading">Build paved roads, not locked rooms</h2><!-- /wp:heading -->
<!-- wp:paragraph --><p>Provide supported templates for common workloads, sensible defaults and self-service workflows. Teams should be able to understand what the platform creates and how to escape the default when justified.</p><!-- /wp:paragraph -->
<!-- wp:heading --><h2 class="wp-block-heading">Measure developer friction</h2><!-- /wp:heading -->
<!-- wp:paragraph --><p>Lead time, failed deployments, onboarding time and support requests reveal whether a platform is actually improving the engineering experience.</p><!-- /wp:paragraph -->
EOF

create_article_file "lessons-from-production-incident" <<'EOF'
<!-- wp:paragraph --><p>Incidents expose the difference between how a system is documented and how it actually behaves. The most valuable follow-up work reduces uncertainty for the next responder.</p><!-- /wp:paragraph -->
<!-- wp:heading --><h2 class="wp-block-heading">Timelines beat memory</h2><!-- /wp:heading -->
<!-- wp:paragraph --><p>Record observable events, decisions and hypotheses as the incident unfolds. A factual timeline makes the later review more useful and reduces hindsight bias.</p><!-- /wp:paragraph -->
<!-- wp:heading --><h2 class="wp-block-heading">Fix detection and recovery paths</h2><!-- /wp:heading -->
<!-- wp:paragraph --><p>Correcting the immediate bug is only one outcome. Better alerts, safer defaults, clearer runbooks and rehearsed rollback paths can prevent a similar failure from becoming another prolonged outage.</p><!-- /wp:paragraph -->
EOF

P1="$(post_upsert improve-cloud-security \
  "5 Practical Ways to Improve Cloud Security" \
  "$AUTHOR_NOOR" security \
  "devsecops,aws,automation" \
  "$tmpdir/improve-cloud-security.html" \
  "A practical security baseline for identity, infrastructure as code, software delivery and telemetry.")"

P2="$(post_upsert reliable-cicd-pipeline \
  "Building a Reliable CI/CD Pipeline" \
  "$AUTHOR_SAMIR" devops \
  "cicd,automation,devsecops" \
  "$tmpdir/reliable-cicd-pipeline.html" \
  "Design delivery pipelines around immutable artifacts, deterministic stages and useful feedback.")"

P3="$(post_upsert when-to-use-kubernetes \
  "When Should You Use Kubernetes?" \
  "$AUTHOR_ELENA" platform-engineering \
  "kubernetes,platform,containers" \
  "$tmpdir/when-to-use-kubernetes.html" \
  "Signals that Kubernetes is helping—and warning signs that it may be unnecessary complexity.")"

P4="$(post_upsert reduce-cloud-costs \
  "Reducing Cloud Costs Without Sacrificing Reliability" \
  "$AUTHOR_ELENA" cloud-engineering \
  "finops,aws,reliability" \
  "$tmpdir/reduce-cloud-costs.html" \
  "How to remove recurring cloud waste while protecting service reliability.")"

P5="$(post_upsert production-platform-migration \
  "What We Learned Migrating a Production Platform" \
  "$AUTHOR_SAMIR" cloud-engineering \
  "kubernetes,terraform,observability" \
  "$tmpdir/production-platform-migration.html" \
  "A staged migration approach built around baselines, observability and reversible steps.")"

P6="$(post_upsert why-infrastructure-as-code-matters \
  "Why Infrastructure as Code Matters" \
  "$AUTHOR_NOOR" cloud-engineering \
  "terraform,automation,devsecops" \
  "$tmpdir/why-infrastructure-as-code-matters.html" \
  "Infrastructure as code makes platform change reviewable, repeatable and easier to recover.")"

P7="$(post_upsert container-security-guide \
  "A Practical Guide to Container Security" \
  "$AUTHOR_NOOR" security \
  "containers,devsecops,kubernetes" \
  "$tmpdir/container-security-guide.html" \
  "Security controls from image construction through Kubernetes runtime.")"

P8="$(post_upsert kubernetes-metrics-that-matter \
  "Monitoring Kubernetes: The Metrics That Actually Matter" \
  "$AUTHOR_ELENA" reliability \
  "kubernetes,observability,sre" \
  "$tmpdir/kubernetes-metrics-that-matter.html" \
  "Start with service behaviour, then use cluster signals to explain saturation and scheduling problems.")"

P9="$(post_upsert zero-downtime-deployments \
  "How Zero-Downtime Deployments Work" \
  "$AUTHOR_SAMIR" devops \
  "kubernetes,cicd,reliability" \
  "$tmpdir/zero-downtime-deployments.html" \
  "Readiness, rolling updates and compatible database changes are the foundation of safe deployments.")"

P10="$(post_upsert managed-vs-self-hosted-kubernetes \
  "Choosing Between Managed and Self-Hosted Kubernetes" \
  "$AUTHOR_ELENA" platform-engineering \
  "kubernetes,platform,aws" \
  "$tmpdir/managed-vs-self-hosted-kubernetes.html" \
  "A practical comparison of operational responsibility, integration and valid self-hosted use cases.")"

P11="$(post_upsert platform-engineering-developer-experience \
  "Improving Developer Experience with Platform Engineering" \
  "$AUTHOR_SAMIR" platform-engineering \
  "platform,automation,cicd" \
  "$tmpdir/platform-engineering-developer-experience.html" \
  "Paved roads should reduce repetitive decisions without hiding operational reality.")"

P12="$(post_upsert lessons-from-production-incident \
  "Lessons From a Production Incident" \
  "$AUTHOR_NOOR" reliability \
  "incident-response,sre,observability" \
  "$tmpdir/lessons-from-production-incident.html" \
  "Use incidents to improve timelines, detection, recovery paths and the next responder's experience.")"

log "Adding featured media"
featured_image_ensure "$P1" security-controls "Cloud security controls"
featured_image_ensure "$P2" delivery-pipeline "CI/CD pipeline"
featured_image_ensure "$P3" kubernetes-platform "Kubernetes platform"
featured_image_ensure "$P4" cloud-cost "Cloud infrastructure"
featured_image_ensure "$P5" migration "Platform migration"
featured_image_ensure "$P6" infrastructure-code "Infrastructure as code"
featured_image_ensure "$P7" container-security "Container security"
featured_image_ensure "$P8" observability "Kubernetes observability"
featured_image_ensure "$P9" deployment "Application deployment"
featured_image_ensure "$P10" managed-kubernetes "Managed Kubernetes"
featured_image_ensure "$P11" platform-engineering "Platform engineering"
featured_image_ensure "$P12" incident-response "Incident response"

log "Adding realistic comments"
for post_id in "$P1" "$P2" "$P3" "$P4" "$P5" "$P6" "$P7" "$P8" "$P9" "$P10" "$P11" "$P12"; do
  comment_seed_if_empty "$post_id"
done

log "Removing default placeholder content"
HELLO_ID="$(post_id_by_slug post hello-world)"
if [ -n "$HELLO_ID" ]; then
  wp post delete "$HELLO_ID" --force >/dev/null
fi

SAMPLE_ID="$(post_id_by_slug page sample-page)"
if [ -n "$SAMPLE_ID" ]; then
  wp post delete "$SAMPLE_ID" --force >/dev/null
fi

log "Northstar Digital content summary"
printf 'Pages:    %s\n' "$(wp post list --post_type=page --post_status=publish --format=count)"
printf 'Posts:    %s\n' "$(wp post list --post_type=post --post_status=publish --format=count)"
printf 'Users:    %s\n' "$(wp user list --format=count)"
printf 'Comments: %s\n' "$(wp comment list --status=approve --format=count)"
printf 'Media:    %s\n' "$(wp post list --post_type=attachment --format=count)"
