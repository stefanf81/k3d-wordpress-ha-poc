# k3d WordPress HA PoC

A local lab for a highly available WordPress **web tier** on k3d: three
WordPress replicas on three worker nodes, three Traefik ingress replicas,
shared WordPress files and a single MariaDB instance. The site is installed,
populated with realistic demo content and configured with a pinned plugin set
automatically.

The lab is meant for HA experiments, plugin/vulnerability testing and
scanner practice on your own machine. It is **not** a production design; see
[Intentional trade-offs](#intentional-trade-offs).

## Quick start

```bash
make up          # or ./start.sh
```

Then open <http://localhost:8080>. The admin area is at
<http://localhost:8080/wp-admin/>:

```text
Username: admin
Password: admin-poc-change-me
```

These credentials are disposable PoC values. The site and the Kubernetes API
are bound to `127.0.0.1` only, so nothing is published on your network.

## Requirements

- Docker: Docker Desktop on macOS/Windows, or Docker Engine on Linux
- [k3d](https://k3d.io) v5.8.3, the version CI tests. `k3d.yaml` uses the
  `k3d.io/v1alpha5` config API, so use a 5.x release that supports it.
- kubectl
- curl

Any CPU architecture works. k3d nodes are containers on the Docker host, so
they run natively on its architecture (arm64 on Apple Silicon, amd64 on most
Linux and Intel machines), and every image used is multi-arch.

`make lint` additionally uses shellcheck, php and kubeconform when they are
installed; missing tools are skipped.

## Commands

| Make target            | Script                               | What it does |
| ---------------------- | ------------------------------------ | ------------ |
| `make up`              | `./start.sh`                         | Create (or reuse) the cluster and reconcile everything |
| `make reconfigure`     | `./reconfigure.sh`                   | Re-run the WP-CLI bootstrap only (plugins, content, settings) |
| `make verify`          | `./verify.sh`                        | Check placement, HA, storage, policies and HTTP |
| `make check`           | `./check.sh`                         | Runtime checks: bootstrap idempotency, file ownership, WP-Cron, inventory |
| `make test-ha`         | `./test-ha.sh`                       | Delete a WordPress pod and assert the site keeps answering |
| `make test-ingress-ha` | `./test-ingress-ha.sh`               | Delete a Traefik pod and assert the site keeps answering |
| `make inventory`       | `./wordpress-inventory.sh`           | Save core/plugin/theme versions to `./reports/inventory/` |
| `make plugins`         | `./show-plugins.sh`                  | Show the plugin table from the latest bootstrap |
| `make versions`        | `./versions.sh`                      | Show tool, k3s, image and application versions |
| `make arch`            | `./verify-arm64.sh`                  | Show node architectures and the PHP build |
| `make lint`            | `./lint.sh`                          | Static checks; no cluster needed |
| `make down`            | `./stop.sh`                          | Delete the cluster, keep WordPress files and the database |
| `make reset`           | `./reset.sh`                         | Delete everything (except `./backups/`) and start fresh |
| `make migrate-db`      | `./migrate-mariadb-to-named-volume.sh` | Migrate a database from an older revision |

Every script talks to the lab through the `k3d-wordpress-ha-poc` kubectl
context explicitly, so none of them can act on another cluster even if your
current context points elsewhere.

## Architecture

```text
                    http://localhost:8080 (127.0.0.1 only)
                                  |
                           k3d load balancer
                                  |
                Traefik (3 replicas, one per worker)
                                  |
                         wordpress Service
                       /          |          \
             worker-0         worker-1         worker-2
             WordPress        WordPress        WordPress
             PHP 8.5          PHP 8.5          PHP 8.5
                 \               |               /
                  +---- shared WordPress tree ---+
                       (one Docker named volume)
                                  |
                                  v
                              MariaDB
                           on server-0
```

### What is HA here?

The WordPress **web/application tier** is HA:

- 3 k3d worker nodes, 3 WordPress replicas, one per worker
  (`topologySpreadConstraints` with `maxSkew: 1`, `minDomains: 3`,
  `whenUnsatisfiable: DoNotSchedule`)
- Kubernetes Service load balancing behind 3 Traefik replicas, one per worker
- PodDisruptionBudgets with `minAvailable: 2` for WordPress and Traefik
- a shared WordPress filesystem for core, plugins, themes and uploads
- Kubernetes recreates a failed WordPress pod on its worker

### Important limitation

MariaDB is intentionally a **single instance**, so a MariaDB failure is still
a site outage. This lab demonstrates frontend/application HA, not a fully HA
WordPress stack. A production-style next step would use a clustered database
such as MariaDB Galera (normally behind a database proxy) and production-grade
shared or object storage.

## Repository layout

```text
k3d.yaml                 cluster: 1 server, 3 agents, ports, volumes, k3s flags
lib.sh                   shared settings and helpers for every script
k8s/
  storage.yaml           namespace (Pod Security labels), PVs and PVCs
  secrets.yaml           PoC credentials and WordPress salts
  security.yaml          service accounts and network policies
  mariadb.yaml           MariaDB Deployment and Service
  traefik-config.yaml    HelmChartConfig for the bundled Traefik
  wordpress/             kustomization: Deployment, PDB, Service, Ingress,
                         WP-Cron CronJob, wp-config.php, healthz.php and the
                         init-container script
  bootstrap/             kustomization: WP-CLI bootstrap Job, site.env,
                         plugins.txt, seed and configuration scripts
  inventory/             kustomization: on-demand WP-CLI inventory Job
.github/workflows/ci.yaml  lint plus an end-to-end k3d smoke test
```

Scripts, PHP and page content are real files. Kustomize's
`configMapGenerator` turns them into ConfigMaps (`kubectl apply -k`), so they
can be linted, diffed and reviewed like any other code. The WordPress
ConfigMap name carries a content hash: editing `wp-config.php`,
`healthz.php` or the init script and re-running `./start.sh` rolls the
WordPress Deployment. Each replica mounts its own copy of the config, so
replicas still running the previous revision keep the config they started
with until they are replaced.

## Configuration

| What | Where |
| ---- | ----- |
| Site URL, title, admin user/email, timezone, WordPress core version | `k8s/bootstrap/site.env` |
| Plugins and pinned versions | `k8s/bootstrap/plugins.txt` |
| Extra WP-CLI settings (run last, every reconcile) | `k8s/bootstrap/after-install.sh` |
| Plugin configuration | `k8s/bootstrap/configure-plugins.php` |
| Demo content | `k8s/bootstrap/seed-site.sh`, `k8s/bootstrap/contact.html` |
| Passwords and salts | `k8s/secrets.yaml` |
| WordPress runtime config | `k8s/wordpress/wp-config.php` |

After editing anything under `k8s/bootstrap/`:

```bash
./reconfigure.sh
```

This recreates only the WP-CLI bootstrap Job. It does not rebuild the cluster
or restart the WordPress replicas. If the bootstrap fails, the script prints
the Job's logs and exits non-zero.

Environment overrides for `./start.sh` and the other scripts:

```bash
K3S_IMAGE=rancher/k3s:<version> ./start.sh     # try another k3s release
MARIADB_DATA_VOLUME=my-test-db ./start.sh      # use another database volume
WORDPRESS_SHARED_VOLUME=my-test-wp ./start.sh  # use another WordPress volume
```

k3s is pinned by default (`rancher/k3s:v1.36.2-k3s1`, set in `lib.sh`) so the
Kubernetes runtime doesn't change underneath the lab. Use the same
`MARIADB_DATA_VOLUME` and `WORDPRESS_SHARED_VOLUME` with every script when you
override them.

### WordPress core version

`WORDPRESS_CORE_VERSION` in `k8s/bootstrap/site.env` is `latest` or an exact
version. To reproduce a particular release:

```text
WORDPRESS_CORE_VERSION=7.0.2
```

then run `./reconfigure.sh`.

The WP-CLI bootstrap is the single update authority for core and plugins. The
web replicas have background updates disabled (`WP_AUTO_UPDATE_CORE`,
`AUTOMATIC_UPDATER_DISABLED`) so three replicas can't race each other on the
shared files. Changing the WordPress image tag does **not** replace core files
already on the shared volume; the bootstrap does.

## Automatic WordPress and plugin setup

`./start.sh` installs WordPress with WP-CLI (`wordpress:cli-php8.5`), so no
installer wizard is needed. The administrator password, database passwords and
WordPress salts live in Kubernetes Secrets, and k3s encrypts Secrets at rest
(`--secrets-encryption`). They are still committed to Git: do not reuse these
values or this secret-management approach outside the lab.

### Pinned plugins

The default `plugins.txt`:

```text
wordfence@8.2.2
wordpress-seo@28.1
contact-form-7@6.1.6
flamingo@2.6.3
query-monitor@4.0.7
redirection@5.9.0
```

Each line is one of:

```text
plugin-slug          latest stable
plugin-slug@latest   latest stable
plugin-slug@1.2.3    exactly 1.2.3
```

Blank lines and `#` comments are ignored.

A pinned plugin is downloaded only when it is missing or its installed version
differs from the pin; then it is installed with `--version` and `--force`. A
repeated bootstrap prints, for example:

```text
wordfence is already pinned at 8.2.2; skipping download/reinstall.
wordfence is already active.
```

The installed version is read with `--skip-plugins --skip-themes`, taking the
last non-empty output line, so PHP 8.5 deprecation notices from active
plugins can't make a correct version look different. WordPress's own
auto-updates are disabled for every managed plugin, so a version doesn't
silently move between vulnerability-testing runs.

### Plugin configuration

`configure-plugins.php` configures plugins rather than only activating them:

- **Yoast SEO**: Northstar Digital as an organization, website and
  organization names, homepage Open Graph title/description, and SEO titles and
  descriptions for key pages.
- **Contact Form 7 + Flamingo**: a `Northstar Project Enquiry` form (name,
  email, company, project type, message, consent) embedded in the Contact page.
  `skip_mail: on` because the lab has no mail server; Flamingo stores
  submissions in MariaDB, so you can submit the form and inspect the messages
  in WordPress Admin.
- **Query Monitor**: active with its development defaults.
- **Wordfence**: active with defaults, intentionally not locked down so it
  doesn't interfere with scanning and vulnerability testing in the lab.
- **Redirection**: its database is installed/upgraded by WP-CLI.

For plugins that store settings as options, add WP-CLI commands to
`after-install.sh`, for example:

```bash
wp option update OPTION_NAME 'value'
wp option patch update OPTION_NAME nested_key 'value'
```

Keep them idempotent: the hook runs on every `./start.sh` and
`./reconfigure.sh`. It also owns the site-wide defaults (`blog_public 0`,
comments and pings closed by default).

## Demo content

The bootstrap creates a fictional technology consultancy, **Northstar
Digital**, so the site behaves like a real one:

- 7 published pages: Home, About, Services, Case Studies, Insights, Contact
  and Privacy Policy
- 12 technical articles (cloud security, CI/CD, Kubernetes adoption, cost
  optimisation, migrations, infrastructure as code, container security,
  observability, zero-downtime deployment, managed vs self-hosted Kubernetes,
  platform engineering, incident response), open for comments
- 3 fictional authors, 5 categories, 12 tags and up to 24 seeded comments
- featured images when the placeholder-image download succeeds
- a static homepage, a separate Insights blog page and a Primary menu
- the Twenty Twenty-Five theme

All names, organisations, email addresses, statistics and case studies are
fictional. WordPress's default `Hello world!` post and `Sample Page` are
removed.

### Idempotent seeding

Everything is keyed by stable slugs and updated in place, so `./start.sh` and
`./reconfigure.sh` are safe to repeat; `make check` verifies that a repeated
bootstrap changes no content counts.

- The Primary menu is managed through WordPress' menu API (`wp eval-file`
  calling `wp_get_nav_menu_object` and `wp_update_nav_menu_item`), not raw SQL.
  It is reused if it exists, otherwise created. A page is added only when no
  item in that exact menu already points to it. A failed lookup stops the
  bootstrap instead of creating a duplicate menu.
- The Contact page is created once by `seed-site.sh`; afterwards
  `configure-plugins.php` owns its content (the enquiry form, or
  `contact.html` when Contact Form 7 is inactive) and only writes it when it
  changed.

### Featured images

Images are imported from `picsum.photos` on a best-effort basis: if the
service is unreachable, the site still provisions and a later
`./reconfigure.sh` fills in the missing images. Plugins and themes need
internet access the first time they are downloaded.

## Storage

### Shared WordPress files

This lab avoids NFS, Ceph or Longhorn. The Docker named volume
`wordpress-ha-poc-wordpress-shared` is mounted into **all three k3d worker
containers** at `/var/lib/wordpress-shared`, and Kubernetes exposes that path
through an RWX `hostPath` PV, so all WordPress pods see the same physical
files.

Do not copy this pattern to a real multi-machine cluster: there, identical
hostPath strings point to different disks.

The tree is a named volume rather than a host directory because it lives on
Docker's Linux filesystem. A macOS or Windows bind mount goes through a VM file
share, where `flock(1)` may not exclude across containers and file ownership
isn't enforced. Either would break the init container's copy lock below. To
browse the files, use a replica:

```bash
kubectl exec -n wordpress-poc deployment/wordpress -c wordpress -- \
  find /var/www/html/wp-content -maxdepth 2 -type d
```

Each replica's init container prepares the tree before Apache starts:

- The first replica copies WordPress from the image while holding an `flock(1)`
  lock on `.wordpress-files.lock`; the others wait. The kernel releases the lock
  when its holder exits or is killed, so no stale-lock cleanup is needed. A
  completion marker (`.wordpress-files-ready`) is written only after the copy
  finishes, so an interrupted copy is retried rather than mistaken for a
  complete tree. The script handles the image's stop signal, so deleting a pod
  mid-copy exits promptly.
- Config is not copied into the shared tree. `wp-config.php` is mounted at
  `/var/www/wp-config.php`, one level above the WordPress root, where
  WordPress and WP-CLI look for it when the root has none. `healthz.php` is
  served by an Apache alias to the read-only ConfigMap mount at `/config`.
  Both mounts sit outside the shared volume. Those `subPath`/alias mounts are
  not yet verified on a live cluster: run `./start.sh` and `./verify.sh` after
  changing them.
- Older revisions copied `wp-config.php` and `healthz.php` into the shared
  tree. `./start.sh` removes those copies after the rollout, because a copy
  there would take precedence over the per-pod mount.

### File ownership

Apache runs as `www-data`, uid 33 (Debian). The WP-CLI image's `www-data` is
uid 82 (Alpine), so the bootstrap and inventory Jobs run explicitly as uid/gid
33. Plugins, themes and media they install stay writable by Apache. The named
volume enforces container user IDs on every platform, including Docker Desktop.

### MariaDB named volume

MariaDB persists to the Docker named volume `wordpress-ha-poc-mariadb-data`.
`k3d.yaml` mounts it only into `server:0` at `/var/lib/mariadb-data`, and the
`mariadb-data` hostPath PV maps the pod's `/var/lib/mysql` to it.

A named volume lives on Docker's Linux filesystem. A macOS bind mount would
inherit the host's case-insensitive filesystem and make MariaDB initialize
with `lower_case_table_names=2`:

```text
Setting lower_case_table_names=2 because file system for /var/lib/mysql/ is case insensitive
```

`./start.sh` and `./verify.sh` require `SELECT @@lower_case_table_names;` to
return `0`.

### Migrate an existing bind-mounted database

Older revisions stored MariaDB in `./data/mariadb`. Don't raw-copy that
datadir into the named volume: `lower_case_table_names` is fixed when a
datadir is initialized, so migrate logically. With the old cluster still
running:

```bash
./migrate-mariadb-to-named-volume.sh     # or: make migrate-db
```

The helper:

1. checks that the target volume doesn't exist yet
2. creates a logical SQL dump under `./backups/`
3. deletes the old k3d cluster and creates a fresh named volume
4. recreates the lab on it
5. restores the SQL dump
6. reconciles WordPress, plugins and content
7. verifies `@@lower_case_table_names = 0` and runs `./verify.sh`

The SQL backup is kept after a successful migration, and its location is
printed if any later step fails.

## Health checks

**WordPress** readiness uses `/healthz.php` rather than `/`. The public URL is
`http://localhost:8080` while pods listen on port 80, so probing `/` can trigger
WordPress's canonical redirect to port 8080. The endpoint checks that
PHP/Apache execute the request, MariaDB accepts a connection and the
`wp_options` table exists. On a fresh database it returns 503 until the
bootstrap creates the schema, which is why `./start.sh` runs the bootstrap
before waiting for the replicas. Readiness runs every 10 seconds. Liveness is
a TCP check, so a database outage makes replicas NotReady instead of
restarting every web container.

**MariaDB** startup and readiness run an authenticated `SELECT 1` with the
WordPress account, so a credential problem makes MariaDB NotReady without a
restart loop. Liveness checks the Unix socket and PID 1 locally: a TCP probe
would log `Aborted connection ... unauthenticated` every period. A single
initial startup-probe failure (`Can't connect to server on 127.0.0.1`) is
expected while the server starts.

**WP-Cron** is disabled on page loads (`DISABLE_WP_CRON`) and triggered
centrally by the `wordpress-cron` CronJob every 5 minutes. During a rollout
the Service can briefly have no Ready endpoints, so the Job first waits for
`http://wordpress/healthz.php` to return 200 (every 5 seconds, up to 5
minutes), then calls `wp-cron.php` with `--retry-all-errors`. If WordPress
stays unavailable, the Job fails so the outage stays visible.

Apache gets `ServerName localhost`, which silences `AH00558` (pod IPs aren't
stable FQDNs).

## Rollouts and disruption

WordPress rolls with `maxUnavailable: 0`, `maxSurge: 1`, a 5-second
`minReadySeconds` soak and a 5-second `preStop` sleep. Its PDB uses
`unhealthyPodEvictionPolicy: AlwaysAllow`, so draining a node doesn't
deadlock on an already-unhealthy pod.

Traefik needs a different strategy. It has three replicas with **required**
pod anti-affinity, one per worker. The chart's default surge rollout
(`maxSurge: 1`, `maxUnavailable: 0`) cannot work: when all three workers
already run a Traefik pod, the surge pod has no legal node. The lab uses:

```yaml
updateStrategy:
  type: RollingUpdate
  rollingUpdate:
    maxUnavailable: 1
    maxSurge: 0
```

With the Traefik PDB (`minAvailable: 2`), a rollout goes 3 ready -> remove
one old pod -> 2 ready -> replacement on the freed worker -> 3 ready, and
repeats. That keeps one-per-worker placement without deadlocking.

Images use `imagePullPolicy: IfNotPresent`, so restarting or replacing a pod
in a running cluster needs no registry access, and failover tests also work
offline. Floating tags (`wordpress:php8.5-apache`, `wordpress:cli-php8.5`)
are pulled fresh whenever the cluster is recreated (`./stop.sh && ./start.sh`);
`./versions.sh` shows the image IDs actually in use.

## Security posture

- The site (`127.0.0.1:8080`) and the Kubernetes API are bound to localhost.
  The lab ships known credentials, debug settings and deliberately old plugin
  versions, so it must not be reachable from your network. `./start.sh` warns,
  and `./verify.sh` fails, if an existing cluster still publishes beyond
  localhost; recreate it with `./stop.sh && ./start.sh`.
- The namespace **enforces Pod Security `baseline`** and audits/warns against
  `restricted`. The WP-CLI Jobs and the WP-Cron Job meet `restricted` (numeric
  non-root user, no privilege escalation, all capabilities dropped,
  `RuntimeDefault` seccomp). The stock Apache WordPress and MariaDB images
  start as root, so they produce `restricted` warnings; the lab shows that gap
  rather than pretending to comply.
- Each workload has its own ServiceAccount with API token automount disabled,
  and gets only the Secrets it needs (e.g. only the bootstrap Job sees the admin
  password, only MariaDB the root password).
- Ingress is default-deny. WordPress accepts HTTP only from `kube-system`
  (Traefik) and pods in its own namespace; MariaDB accepts TCP/3306 only from
  WordPress and the WP-CLI bootstrap and inventory Jobs. Egress is open, because
  plugin/theme/image downloads and vulnerability testing need the internet.
- k3s encrypts Secrets at rest.
- `DISALLOW_FILE_EDIT` is on, the environment type is `local`, memory limits
  are explicit, and the debug log is written to `/tmp`, outside the web root.

## Testing

```bash
make lint             # static: exec bits, shellcheck, php -l, kustomize + kubeconform
make verify           # the running lab has the intended shape
make check            # bootstrap idempotency, file ownership, WP-Cron, inventory
make test-ha          # delete a WordPress pod while requesting the site
make test-ingress-ha  # delete a Traefik pod while requesting the site
```

The failover tests request `http://localhost:8080` once a second while the pod
is replaced. They fail if any request doesn't get a 2xx/3xx answer, then wait
for the three replicas to recover and show the new placement. Allow a few
failed requests with `MAX_FAILED_REQUESTS=2 ./test-ha.sh`.

GitHub Actions (`.github/workflows/ci.yaml`) runs `lint.sh`, then a smoke test
that creates the lab on a fresh runner and runs `verify.sh`, `check.sh`,
`test-ha.sh` and `test-ingress-ha.sh`.

To delete a pod by hand:

```bash
kubectl delete pod -n wordpress-poc \
  "$(kubectl get pods -n wordpress-poc -l app=wordpress -o jsonpath='{.items[0].metadata.name}')"

curl -I http://localhost:8080
```

The Service still has the other two WordPress endpoints.

## Inspecting the lab

The commands below use your current kubectl context, which `./start.sh` sets
to `k3d-wordpress-ha-poc`.

```bash
# Nodes and their roles (one server, three workers)
kubectl get nodes -L workload

# WordPress placement: three different NODE values
kubectl get pods -n wordpress-poc -l app=wordpress -o wide

# Node architectures
kubectl get nodes \
  -o custom-columns='NAME:.metadata.name,ARCH:.status.nodeInfo.architecture,OS:.status.nodeInfo.operatingSystem'

# PHP inside a replica
kubectl exec -n wordpress-poc deployment/wordpress -c wordpress -- php -v

# Watch endpoints during a failover
kubectl get endpointslice -n wordpress-poc -l kubernetes.io/service-name=wordpress -w

# Logs from all replicas
kubectl logs -n wordpress-poc -l app=wordpress --prefix --tail=100

# Everything in the namespace
kubectl get all,pvc,pdb,ingress -n wordpress-poc
```

Plugins and uploads live in the shared WordPress volume (see
[Shared WordPress files](#shared-wordpress-files) for how to browse it):

```bash
kubectl exec -n wordpress-poc deployment/wordpress -c wordpress -- \
  ls /var/www/html/wp-content/plugins
```

Inside the cluster the site is `http://wordpress.wordpress-poc.svc.cluster.local`.
For example, to scan it with WPScan from a throwaway pod:

```bash
kubectl run wpscan -n wordpress-poc --rm -it --restart=Never \
  --image=wpscanteam/wpscan -- \
  --url http://wordpress.wordpress-poc.svc.cluster.local \
  --enumerate vp,vt \
  --plugins-detection mixed
```

## Stop, reset and upgrade

```bash
./stop.sh
```

This deletes the k3d cluster but keeps the `wordpress-ha-poc-wordpress-shared`
and `wordpress-ha-poc-mariadb-data` volumes; `./start.sh` recreates the same
site.

```bash
./reset.sh
```

This deletes the cluster, both volumes and any legacy `./data/wordpress` and
`./data/mariadb`, then starts a fresh lab. `./backups/` is kept.

Runtime data (`data/`, `backups/`, `reports/`) is ignored by Git.

**Upgrading from an older revision:** run `./stop.sh && ./start.sh` once. A
cluster's published ports and node mounts can't change in place, so this is what
moves the site to `127.0.0.1` and onto the WordPress volume. Your data is kept:
`./start.sh` copies `./data/wordpress` into the new volume, leaving the
directory untouched so you can delete it once the site works. The init
container then adopts the copied tree, adds any missing core files without
overwriting updates, and resets ownership to uid 33. A database still in
`./data/mariadb` needs the separate
[migration](#migrate-an-existing-bind-mounted-database), which also carries the
WordPress files over.

## Intentional trade-offs

- MariaDB is a single instance and the largest remaining application SPOF.
- k3d has one control-plane server and one host-facing load-balancer
  container: acceptable local-lab constraints, not production HA.
- Shared WordPress storage is one Docker volume mounted into all workers, fine
  for one machine but not a multi-node storage design.
- Egress is open for plugin/theme/image bootstrap and vulnerability testing.
- The official Apache WordPress image is kept for familiarity and plugin
  compatibility, rather than a heavily hardened custom image.

For production, the next substantial changes would be an HA managed or
clustered database, production RWX/object storage for media, immutable
application images for plugin/theme code, TLS and stricter egress controls.

## Troubleshooting

- **Bootstrap failed**: `./start.sh` and `./reconfigure.sh` print the Job's
  logs and stop. Fix the cause (often network access to wordpress.org) and run
  `./reconfigure.sh`.
- **A WordPress pod waits in `Init`** with "Another pod is preparing the shared
  WordPress files": another replica holds the `flock` lock and is copying. The
  waiting pod continues once that replica exits.
- **`./verify.sh` says the site is published beyond localhost**: the cluster
  predates the localhost binding; run `./stop.sh && ./start.sh`.
- **`./start.sh` reports an unexpected WordPress mount**: the cluster came from
  a revision that bind-mounted `./data/wordpress`; run `./stop.sh && ./start.sh`
  and the files are imported into the volume.
- **`./start.sh` reports an unexpected MariaDB mount**: the cluster came from a
  revision that used `./data/mariadb`; see
  [Migrate an existing bind-mounted database](#migrate-an-existing-bind-mounted-database).
