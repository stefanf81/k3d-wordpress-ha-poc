# k3d WordPress HA PoC

Local WordPress high-availability **web tier** lab using k3d.





### Idempotent pinned-plugin reconciliation

Pinned plugins are no longer re-downloaded when the installed version already
matches the requested version.

The version lookup uses `--skip-plugins --skip-themes` and takes the final
non-empty output line. This prevents PHP 8.5 deprecation notices from active
plugins from contaminating the captured version string.

A repeated bootstrap now produces output like:

```text
wordfence is already pinned at 8.2.2; skipping download/reinstall.
wordfence is already active.
```

A pinned plugin is downloaded only when it is missing or its installed version
differs from the requested pin.


### Idempotent Primary menu reconciliation

The content bootstrap may be run repeatedly with `./reconfigure.sh`.

The Primary navigation menu is resolved by its WordPress `nav_menu` taxonomy
term ID rather than by parsing `wp menu list` output. If the menu already
exists it is reused; if it does not exist it is created with
`wp menu create --porcelain`. Each page is then added only when its
`_menu_item_object_id` is not already related to that exact menu term.

This avoids duplicate-menu failures such as:

```text
Error: The menu name Primary conflicts with another menu name.
```



### Clean WP-CLI inventory under Restricted Pod Security

The on-demand `wordpress-inventory` Job explicitly declares
`runAsNonRoot: true`. The official `wordpress:cli-php8.5` image already runs as
`www-data`; this explicit declaration lets Kubernetes Pod Security Admission
verify the non-root intent and removes the Restricted-profile warning.

Plugin and theme inventory commands use `--skip-plugins --skip-themes`.
Inventory does not need to execute active plugin/theme runtime code, so this
keeps Wordfence PHP 8.5 deprecation messages out of the JSON while preserving
installed versions, activation state and update metadata.

The bootstrap's final plugin table uses the same flags, `show-plugins.sh`
filters historical `Deprecated:` lines, and `versions.sh` explicitly selects
the main `wordpress` container.


## 2026 engineering review

This revision applies a set of current Kubernetes, k3s, WordPress and MariaDB
practices while keeping the project intentionally lightweight enough for a local
security lab.






### MariaDB Docker named volume

MariaDB persistence is provided by the Docker volume:

```text
wordpress-ha-poc-mariadb-data
```

`k3d.yaml` mounts that volume only into `server:0` at:

```text
/var/lib/mariadb-data
```

The Kubernetes `mariadb-data` hostPath PV then maps `/var/lib/mysql` in the
MariaDB pod to that node-local path.

This keeps the PoC's Kubernetes storage model simple while avoiding the macOS
bind-mount filesystem semantics that caused:

```text
Setting lower_case_table_names=2 because file system for /var/lib/mysql/ is case insensitive
```

`start.sh` and `verify.sh` query MariaDB and require:

```sql
SELECT @@lower_case_table_names;
-- 0
```

You may override the Docker volume name:

```bash
MARIADB_DATA_VOLUME=my-test-db ./start.sh
```

Use the same environment variable with `stop.sh`, `reset.sh`, `verify.sh` and
`versions.sh` when using a custom name.


### WP-Cron readiness gating

The Kubernetes WP-Cron Job does not immediately call `wp-cron.php`.

During a WordPress Deployment rollout or initial bootstrap, the `wordpress`
Service can temporarily have zero Ready endpoints. A direct curl during that
window produces:

```text
curl: (7) Failed to connect to wordpress port 80
```

The CronJob now waits for:

```text
http://wordpress/healthz.php
```

to return HTTP 200 before triggering `wp-cron.php`.

It checks every 5 seconds for up to 5 minutes. If WordPress becomes Ready, the
cron request is sent normally. If the application remains unavailable for the
entire window, the Job fails intentionally so the outage remains visible
instead of being silently ignored.


### Runtime log cleanup

Live testing showed two harmless but noisy messages:

- Apache emitted `AH00558` because a Kubernetes pod IP is not a stable FQDN.
  The WordPress container now creates an Apache `ServerName localhost`
  configuration before starting `apache2-foreground`.
- MariaDB logged an `Aborted connection ... unauthenticated` entry every ten
  seconds because a raw TCP liveness probe opened a socket and immediately
  disconnected. Startup/readiness still execute an authenticated `SELECT 1`,
  while liveness now checks the MariaDB Unix socket and PID 1 locally.

The WordPress readiness interval is also 10 seconds instead of 5 seconds to
reduce health-check access-log volume while still removing an unhealthy pod
quickly.

A single initial MariaDB startup-probe failure such as `Can't connect to server
on 127.0.0.1` is expected while the server is still starting; the generous
startup failure threshold handles this without causing a restart.

### Traefik rollout strategy

Traefik uses three replicas with required pod anti-affinity: one ingress pod per
WordPress worker.

The Traefik Helm chart normally uses a surge rollout (`maxSurge: 1`,
`maxUnavailable: 0`). That cannot work when all three eligible workers already
contain a Traefik pod: the fourth surge pod has no legal node.

The PoC therefore explicitly uses:

```yaml
updateStrategy:
  type: RollingUpdate
  rollingUpdate:
    maxUnavailable: 1
    maxSurge: 0
```

Together with the Traefik PDB `minAvailable: 2`, this rolls the ingress tier as:

```text
3 ready
  -> remove 1 old pod
2 ready
  -> schedule replacement on the freed worker
3 ready
  -> repeat
```

This preserves hard one-per-worker placement without deadlocking Deployment
rollouts.

### k3d/containerd compatibility fixes

Two local-runtime issues found during live testing on Apple Silicon are handled
explicitly:

1. `wp-config.php` and `healthz.php` are **not mounted as ConfigMap subPath files
   inside `/var/www/html`**. `/var/www/html` is already the RWX WordPress
   filesystem. The init container instead copies both files into that shared
   filesystem with mode `0444`. This avoids nested bind-mount failures from
   containerd/runc while keeping the files non-writable by Apache/PHP.

2. MariaDB probes **do not depend on `.my-healthcheck.cnf`**. Startup and
   readiness execute `SELECT 1` using the WordPress database account from the
   Kubernetes Secret. Liveness checks only TCP/3306, so a credential/config
   problem makes MariaDB NotReady without creating an endless restart loop.

WP-Cron also uses curl retry-all-errors so a short Service endpoint transition
does not immediately fail the scheduled Job.

### WordPress readiness probe

The WordPress readiness probe uses:

```text
/healthz.php
```

rather than `/`.

This is intentional. The public site URL is `http://localhost:8080`, while
WordPress pods themselves listen on port 80. Probing `/` can trigger WordPress
canonical URL handling and redirect kubelet from the pod's port 80 to port
8080. The dedicated endpoint avoids that redirect and checks:

- PHP/Apache can execute the request
- MariaDB accepts a connection
- the WordPress `wp_options` table exists

Liveness remains a lightweight TCP check so a temporary database failure makes
a replica NotReady without causing Kubernetes to restart all web containers.

On a fresh database the readiness endpoint returns HTTP 503 until the WP-CLI
bootstrap Job creates the WordPress schema. `start.sh` therefore starts the
bootstrap Job before waiting for all WordPress replicas to become Ready.

### Changes applied

- **K3s is pinned by default** through `K3S_IMAGE` instead of silently changing
  the Kubernetes runtime underneath the lab. Override the environment variable
  when you intentionally want to test another k3s release.
- **K3s Secret encryption at rest** is enabled with `--secrets-encryption`.
- The namespace **enforces Pod Security `baseline`** and audits/warns against
  `restricted`. The stock WordPress Apache image is not a clean fit for
  `restricted` enforcement, so the lab exposes that gap rather than pretending
  it is compliant.
- Workloads use dedicated **ServiceAccounts with API token automount disabled**.
- A namespace **default-deny ingress NetworkPolicy** is applied. WordPress
  accepts HTTP only from Traefik and same-namespace lab clients; MariaDB accepts
  TCP/3306 only from WordPress and the bootstrap Job.
- Pods use **`seccompProfile: RuntimeDefault`**.
- MariaDB uses the official image's **`healthcheck.sh`** probe and
  `MARIADB_AUTO_UPGRADE=1`.
- Bundled **Traefik is scaled to 3 replicas**, pinned to the worker pool,
  anti-affined across all three workers and protected by a PDB. The ingress
  tier therefore does not remain a hidden single-pod dependency.
- WordPress uses **one central WP-CLI update authority**. This fixes an important
  shared-storage edge case: changing the floating WordPress image does not by
  itself replace core files already persisted in the RWX volume.
- Set `WORDPRESS_CORE_VERSION` in `k8s/bootstrap.yaml` to `latest` or an exact
  version when reproducing a vulnerability.
- WordPress background core/plugin auto-updates are disabled so three web
  replicas cannot race the central reconciler.
- `DISALLOW_FILE_EDIT` is enabled; the environment type is `local`; PHP memory
  limits are explicit; debug logs are written outside the web root.
- WordPress rolls with **`maxUnavailable: 0`**, a short readiness soak and a
  graceful `preStop`; the PDB allows eviction of already-unhealthy pods so a
  drain is less likely to deadlock.
- WP-Cron has retry/timeout controls, job-history limits and resource bounds.
- Runtime data is ignored by Git via `.gitignore`.
- `Makefile`, `verify.sh` and `versions.sh` provide repeatable developer
  operations and capture the actual image IDs used by floating tags.

### Useful commands

```bash
make up
make verify
make versions
make test-ha
make test-ingress-ha
make reconfigure
make down
```

To reproduce a particular WordPress core release:

```yaml
# k8s/bootstrap.yaml
WORDPRESS_CORE_VERSION: "7.0.2"
```

Then:

```bash
./reconfigure.sh
```

To try another k3s release without editing YAML:

```bash
K3S_IMAGE=rancher/k3s:<version> ./start.sh
```

### Intentional PoC trade-offs

The project still does **not** claim full-stack HA:

- MariaDB remains a single instance and is the largest remaining application SPOF.
- k3d itself still has one control-plane server and one host-facing load-balancer
  container; those are acceptable local-lab constraints, not production HA.
- Shared WordPress storage is a k3d host bind mount; it is appropriate for this
  one-machine lab, not a real multi-node storage design.
- Egress is intentionally open because plugin/theme/image bootstrap and
  vulnerability testing need internet access.
- The official Apache WordPress image is retained for familiarity and plugin
  compatibility rather than replacing it with a heavily hardened custom image.

For a production architecture, the next substantial changes would be an HA
managed/clustered database, production RWX/object storage for media, immutable
application images for plugin/theme code, TLS and stricter egress controls.

## Architecture

```text
                         http://localhost:8080
                                  |
                           k3d load balancer
                                  |
                              Traefik
                                  |
                         wordpress Service
                       /          |          \
                      /           |           \
             worker-0         worker-1         worker-2
             WordPress        WordPress        WordPress
             PHP 8.5          PHP 8.5          PHP 8.5
                 \               |               /
                  \              |              /
                   +---- shared wp-content ----+
                         + WordPress core
                         via one host directory
                                  |
                                  v
                              MariaDB
                           on server-0
```

## What is HA here?

The WordPress **web/application tier** is HA:

- 3 k3d worker nodes
- 3 WordPress replicas
- strict topology spreading by `kubernetes.io/hostname`
- one WordPress pod per worker
- Kubernetes Service load balancing
- Traefik ingress
- PodDisruptionBudget with `minAvailable: 2`
- shared WordPress filesystem for plugins, themes and uploads
- Kubernetes recreates a failed WordPress pod on its worker pool

The WordPress image is:

```text
wordpress:php8.5-apache
```

This tag means:

- latest stable WordPress published in the official image
- PHP 8.5
- Apache
- multi-architecture image
- native `linux/arm64` is selected on an Apple Silicon Mac

The WordPress Deployment also uses:

```yaml
imagePullPolicy: Always
nodeSelector:
  workload: wordpress
  kubernetes.io/arch: arm64
```

so recreating/restarting the lab checks for a newer build of the floating PHP 8.5
tag, and WordPress is only scheduled on ARM64 worker nodes.

## Important limitation

MariaDB is intentionally still a **single database instance**.

Therefore this lab demonstrates WordPress frontend/application HA, but it is
**not a fully HA WordPress stack**. A MariaDB failure is still a site outage.

A production-style next step would use a clustered database such as MariaDB
Galera (normally behind a database proxy/service) and production-grade shared
storage or object storage.

## How shared WordPress storage works locally

This setup avoids NFS/Ceph/Longhorn because it is a local k3d PoC.

`./data/wordpress` on your machine is bind-mounted into **all three k3d worker
containers** at:

```text
/var/lib/wordpress-shared
```

Kubernetes then exposes that path through an RWX `hostPath` PV.

All three WordPress pods therefore see the same physical files.

This is useful for k3d, but **do not copy this pattern to a real multi-machine
Kubernetes cluster**. On real nodes, identical hostPath strings point to
different disks.

## Requirements

- Docker
- k3d
- kubectl
- curl

k3d itself requires Docker and is intended for running multi-node k3s clusters
inside Docker.

## Start

```bash
./start.sh
```

Then open:

```text
http://localhost:8080
```

The site is installed and populated automatically. No WordPress installer
wizard is required.


## Automatic WordPress + plugin setup

`./start.sh` now completes the WordPress installer automatically with WP-CLI.

Default local login:

```text
URL:      http://localhost:8080/wp-admin/
Username: admin
Password: admin-poc-change-me
```

These credentials are intentionally disposable. The administrator password,
database passwords and WordPress salts are stored in a Kubernetes Secret; k3s
Secret encryption at rest is enabled for this local lab. Do not reuse these
static PoC values outside this environment.

The bootstrap uses the official native multi-architecture image:

```text
wordpress:cli-php8.5
```

### Default plugins and pinned versions

The lab now ships with a realistic, explicitly pinned plugin set:

```text
wordfence@8.2.2
wordpress-seo@28.1
contact-form-7@6.1.6
flamingo@2.6.3
query-monitor@4.0.7
redirection@5.9.0
```

The version syntax is handled directly by the bootstrap:

```text
plugin-slug          latest stable
plugin-slug@latest   latest stable
plugin-slug@1.2.3    exactly 1.2.3
```


```yaml
plugins.txt: |
  wordfence@8.2.2
  contact-form-7@6.0.3
```

Then run:

```bash
./reconfigure.sh
```

Pinned versions are installed with WP-CLI's `--version` and `--force` options.
The bootstrap also disables WordPress core auto-updates for managed plugins so
a version doesn't silently move between vulnerability-testing runs.

### Common plugin configuration

The bootstrap configures several plugins instead of only activating them:

**Yoast SEO**

- Northstar Digital is configured as an organization
- website and organization names are populated
- homepage Open Graph title/description are populated
- realistic SEO titles and descriptions are added to key pages

**Contact Form 7 + Flamingo**

- creates a `Northstar Project Enquiry` form
- adds name, email, company, project type, message and consent fields
- embeds the form into the Contact page
- uses `skip_mail: on` because this local PoC has no mail server
- Flamingo stores submitted test messages in MariaDB

This means you can actually submit the form locally and then inspect its
stored messages from WordPress Admin.

**Query Monitor**

- activated with its normal development defaults

**Wordfence**

- activated with defaults
- intentionally not aggressively locked down so it doesn't interfere with

**Redirection**

- plugin database is automatically installed/upgraded by WP-CLI


### Preconfigure plugin settings

`k8s/bootstrap.yaml` also contains:

```yaml
after-install.sh: |
  #!/bin/sh
  set -eu

  wp option update blog_public 0
  wp option update default_comment_status closed
  wp option update default_ping_status closed
```

Add plugin-specific WP-CLI commands there.

For plugins that save their configuration as WordPress options, common patterns
are:

```bash
wp option update OPTION_NAME 'value'
wp option patch update OPTION_NAME nested_key 'value'
```

The exact option names depend on the plugin.

`after-install.sh` should be idempotent because it runs whenever
`./reconfigure.sh` or `./start.sh` reconciles the environment.

### Reconcile plugins/settings

After editing the bootstrap ConfigMap:

```bash
./reconfigure.sh
```

This recreates only the WP-CLI bootstrap Job. It does not rebuild the cluster
or restart the three WordPress web replicas.

Show the plugin inventory from the most recent bootstrap:

```bash
./show-plugins.sh
```


## Realistic demo content

The bootstrap now creates a fictional technology consultancy called
**Northstar Digital** so the WordPress installation looks and behaves more like
a real site.

It creates:

- 7 published pages: Home, About, Services, Case Studies, Insights, Contact and Privacy Policy
- 12 published technical articles
- 3 fictional author accounts
- 5 categories
- 12 tags
- up to 24 seeded comments
- featured images for the articles when placeholder-image download succeeds
- a static homepage and separate Insights/blog page
- a Primary menu fallback
- the Twenty Twenty-Five theme

Example article topics include:

- cloud security
- CI/CD reliability
- Kubernetes adoption
- cloud cost optimisation
- platform migrations
- infrastructure as code
- container security
- Kubernetes observability
- zero-downtime deployment
- managed vs self-hosted Kubernetes
- platform engineering
- incident response

All names, organisations, email addresses, statistics and case studies in the
seed data are fictional.

### Idempotent seeding

The content generator is stored inside:

```text
k8s/bootstrap.yaml
```

as:

```text
seed-site.sh
```

It uses stable slugs and updates existing pages/posts rather than creating
duplicates.

That means these are safe to run repeatedly:

```bash
./start.sh
./reconfigure.sh
```

The seed process also removes WordPress's default `Hello world!` post and
`Sample Page`.

### Featured images

The bootstrap tries to import deterministic placeholder images from
`picsum.photos`.

Image import is best-effort: if the machine cannot reach the image service, the
site still provisions successfully and can be reconciled again later with:

```bash
./reconfigure.sh
```

The plugins and theme also require internet access the first time they are
downloaded.

## Verify the three workers

```bash
kubectl get nodes -L workload
```

You should see one server node and three worker/agent nodes.

## Verify WordPress placement

```bash
kubectl get pods \
  -n wordpress-poc \
  -l app=wordpress \
  -o wide
```

The three WordPress pods should have three different values in the `NODE`
column.

This is enforced with:

```yaml
topologySpreadConstraints:
  - maxSkew: 1
    minDomains: 3
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: DoNotSchedule
```

## Verify native Apple Silicon / ARM64

Check the k3d node architectures:

```bash
kubectl get nodes   -o custom-columns='NAME:.metadata.name,ARCH:.status.nodeInfo.architecture,OS:.status.nodeInfo.operatingSystem'
```

On an M4 Pro you should see:

```text
ARCH
arm64
```

Check the actual image used by the WordPress pods:

```bash
kubectl get pods   -n wordpress-poc   -l app=wordpress   -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.spec.containers[0].image}{"\n"}{end}'
```

Expected image:

```text
wordpress:php8.5-apache
```

Check PHP directly:

```bash
kubectl exec   -n wordpress-poc   deployment/wordpress   -- php -v
```

### Test ingress failover

The bundled k3s Traefik deployment is configured with three replicas, one per
worker node. Test that layer independently:

```bash
./test-ingress-ha.sh
```

This deletes one Traefik pod while repeatedly requesting
`http://localhost:8080`, then waits for all three ingress replicas to recover.

## Test failover

After completing the WordPress installer:

```bash
./test-ha.sh
```

The script:

1. confirms the site is reachable
2. deletes one WordPress pod
3. repeatedly requests `http://localhost:8080`
4. waits for Kubernetes to restore three ready replicas
5. displays the new pod placement

You can also do it manually:

```bash
kubectl delete pod \
  -n wordpress-poc \
  "$(kubectl get pods -n wordpress-poc -l app=wordpress \
     -o jsonpath='{.items[0].metadata.name}')"
```

Immediately check:

```bash
curl -I http://localhost:8080
```

The Service still has the other two WordPress endpoints.

## Watch endpoints

```bash
kubectl get endpointslice \
  -n wordpress-poc \
  -l kubernetes.io/service-name=wordpress \
  -w
```

## Shared files

Install a plugin or upload an image in WordPress, then inspect the same shared
directory on your host:

```bash
find ./data/wordpress/wp-content -maxdepth 2 -type d
```

All WordPress replicas mount this directory.

## Check PHP

```bash
kubectl exec \
  -n wordpress-poc \
  deployment/wordpress \
  -- php -v
```

## Logs from all WordPress replicas

```bash
kubectl logs \
  -n wordpress-poc \
  -l app=wordpress \
  --prefix \
  --tail=100
```

## Resources

```bash
kubectl get all,pvc,pdb,ingress \
  -n wordpress-poc
```


From a pod in the cluster:

```text
http://wordpress.wordpress-poc.svc.cluster.local
```

Example:

```bash
  --url http://wordpress.wordpress-poc.svc.cluster.local \
  --enumerate vp,vt \
  --plugins-detection mixed
```

## Stop but preserve data

```bash
./stop.sh
```

This removes the k3d cluster but preserves:

```text
./data/wordpress
Docker volume: wordpress-ha-poc-mariadb-data
```

Running `./start.sh` again recreates the cluster against the same WordPress
files and MariaDB Docker volume.

MariaDB intentionally does **not** use `./data/mariadb` anymore. On Docker
Desktop for macOS, a bind mount inherits host filesystem case behavior and
MariaDB can initialize with `lower_case_table_names=2`. A Docker named volume
is stored inside Docker's Linux VM and gives this lab normal Linux
case-sensitive MariaDB semantics (`lower_case_table_names=0`).

## Migrate an existing bind-mounted MariaDB database

If the cluster was created with an older project revision that used:

```text
./data/mariadb
```

do not raw-copy that datadir into the Docker named volume. MariaDB's
`lower_case_table_names` behavior is selected when the datadir is initialized,
so a logical migration is the clean way to switch filesystem semantics.

With the old cluster still running:

```bash
./migrate-mariadb-to-named-volume.sh
```

or:

```bash
make migrate-db
```

The helper:

1. creates a logical SQL dump under `./backups/`
2. deletes the old k3d cluster
3. creates a fresh Docker named volume
4. recreates MariaDB on its Linux filesystem
5. restores the SQL dump
6. reconciles WordPress/plugins/content
7. verifies `@@lower_case_table_names = 0`
8. runs the normal project verification

The SQL backup is retained after a successful migration.

## Full reset

```bash
./reset.sh
```

This deletes:

- the k3d cluster
- WordPress shared files
- the MariaDB Docker named volume
- any legacy `./data/mariadb` directory

and starts a fresh environment. Files under `./backups/` are intentionally
preserved.

## PoC credentials

The manifest intentionally contains simple database passwords.

Do not use these values or this Secret-management approach in production.
