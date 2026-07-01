# Ubuntu single-node IMServer deployment

This deployment profile is for one small Ubuntu 24.04 server used for development, demo, or small internal testing.

All `*.yourdomain.com` targets in examples are replace-before-run placeholders.
Production gates reject literal `yourdomain.com` and `*.yourdomain.com` values;
use the real DNS names configured for your HTTPS and TCP entrypoints.

It installs and runs:

- PostgreSQL on `127.0.0.1:5432`
- Redis on `127.0.0.1:6379`
- Kafka KRaft single node on `127.0.0.1:9092`
- IMServer split roles:
  - `nginx` public HTTP entry on `0.0.0.0:80` in production, or `8080` outside production
  - `gateway` HTTP on `127.0.0.1:18080` and TCP `9000`
  - `command-api` on `127.0.0.1:8081`
  - `query-api` on `127.0.0.1:8082`
  - `outbox-relay`
  - `stream-consumer`
- Nginx public HTTP port is controlled by `IM_PUBLIC_HTTP_PORT` and defaults to
  `80` when `APP_ENV=production`, otherwise `8080`.

OpenSearch is disabled by default:

```env
IM_SEARCH_DRIVER=database
```

If you enable OpenSearch in production, set `IM_OPENSEARCH_ENDPOINT` to an
`https://` endpoint with a real non-placeholder DNS host. The production runtime
and env gates reject HTTP, IP/localhost, and placeholder hosts such as
`*.example` or `*.yourdomain.com`.

Kafka is enabled by default:

```env
IM_EVENT_STREAM_DRIVER=kafka
IM_KAFKA_BROKERS=127.0.0.1:9092
IM_KAFKA_SECURITY_PROTOCOL=plaintext
```

## Install

Clone the repo on the server, then run:

```bash
cd /opt/IMMonorepo
sudo bash deploy/ubuntu/00_install_dependencies.sh
sudo bash deploy/ubuntu/15_setup_kernel_tuning.sh
sudo bash deploy/ubuntu/25_setup_host_security.sh
sudo bash deploy/ubuntu/10_setup_postgres.sh
sudo bash deploy/ubuntu/20_setup_redis.sh
sudo bash deploy/ubuntu/30_setup_kafka.sh
sudo bash deploy/ubuntu/40_build_imserver.sh
sudo bash deploy/ubuntu/50_install_systemd_units.sh
sudo bash deploy/ubuntu/52_verify_systemd_units.sh
sudo bash deploy/ubuntu/55_verify_production_env.sh
sudo bash deploy/ubuntu/56_run_migrations.sh
sudo bash deploy/ubuntu/35_setup_logrotate.sh
sudo bash deploy/ubuntu/60_install_nginx.sh
```

`00_install_dependencies.sh` installs base packages and, when Swift is missing,
downloads the pinned Swiftly Linux archive plus its `.sig` signature. The script
imports the Swift.org public key bundle into a temporary GPG keyring, verifies
the archive signature, then extracts the archive with path, link, duplicate, and
size safety checks before running `./swiftly init`. A bad signature, unsafe tar
member, or oversized payload fails the install before any Swiftly binary is run.

Start services:

```bash
sudo systemctl start imserver-command-api
sudo systemctl start imserver-gateway imserver-query-api imserver-outbox-relay imserver-stream-consumer
sudo bash deploy/ubuntu/70_status.sh
sudo bash deploy/ubuntu/65_verify_entrypoint.sh
sudo bash deploy/ubuntu/66_smoke_entrypoint.sh
```

If SSH and public HTTP are both suspicious, use the one-command access repair
from the cloud console or rescue shell. It repairs SSH first, then repairs and
verifies the HTTP entrypoint:

```bash
sudo SSH_PORT=22 \
  SSH_USER=root \
  HTTP_PORT=80 \
  PUBLIC_BASE_URL=https://chat.yourdomain.com \
  bash deploy/ubuntu/23_repair_node_access.sh
```

For first bootstrap before DNS/HTTPS exists, `PUBLIC_BASE_URL=http://<server-public-ip>`
is only a temporary rescue value. Do not keep that value in production env files
or performance evidence.

If the server does not have the latest checkout, use the self-contained rescue
script instead. It does not source any other repo file, so it can be copied into
the cloud console and run as-is:

```bash
sudo SSH_PORT=22 \
  SSH_USER=root \
  HTTP_PORT=80 \
  PUBLIC_BASE_URL=https://chat.yourdomain.com \
  bash deploy/ubuntu/22_node_access_rescue.sh
```

To avoid manually copying a long script, render a paste-ready command locally:

```bash
PUBLIC_BASE_URL=https://chat.yourdomain.com \
SSH_PORT=22 \
SSH_USER=root \
HTTP_PORT=80 \
deploy/ubuntu/21_render_node_access_rescue_command.sh \
  > /tmp/im-node-access-rescue-command.sh
```

Open `/tmp/im-node-access-rescue-command.sh`, paste it into the cloud console,
and run it. The rendered command embeds `22_node_access_rescue.sh` as base64 and
executes it on the target host with the supplied environment.

If only the public probe returns an empty `403` for `/nginx-health`, rerun the
idempotent HTTP entrypoint repair before load testing:

```bash
sudo HTTP_PORT=80 \
  PUBLIC_BASE_URL=https://chat.yourdomain.com \
  bash deploy/ubuntu/64_repair_http_entrypoint.sh
```

The repair script reinstalls the IMServer Nginx default server block, disables
the stock default site, reloads Nginx, checks local `/nginx-health` and
`/health`, and then checks public `/nginx-health` when `PUBLIC_BASE_URL` is set.
If local health passes but public `/nginx-health` still fails, the remaining
problem is outside the IMServer process: cloud security group, WAF, external
proxy, NAT, wrong public IP/port, or another listener in front of the host.

`60_install_nginx.sh` renders the public HTTP entrypoint with production defaults:

- `server_tokens off`.
- `/internal/metrics` is loopback-only through Nginx.
- security headers: `X-Content-Type-Options: nosniff`,
  `X-Frame-Options: DENY`, and `Referrer-Policy: no-referrer`.
- request and connection guardrails:
  `NGINX_CLIENT_MAX_BODY_SIZE=100m`, `NGINX_CONNECTION_LIMIT=1000`,
  `NGINX_AUTH_RATE_LIMIT=50r/s`, `NGINX_AUTH_RATE_BURST=100`,
  `NGINX_API_RATE_LIMIT=1000r/s`, and `NGINX_API_RATE_BURST=2000`.

Tune those Nginx limits deliberately for the real edge topology. If a CDN,
WAF, or cloud load balancer sits in front of this node, configure trusted real
client IP handling first; otherwise per-IP limits may apply to the proxy's IP
instead of end users. Run the local render test after changing Nginx templates:

```bash
NGINX_INSTALL_SELF_TEST=true \
  bash deploy/ubuntu/60_install_nginx.sh
```

Verify an installed Nginx configuration after manual edits or package upgrades:

```bash
sudo bash deploy/ubuntu/62_verify_nginx_config.sh
```

The verifier checks that rendered HTTP, location, and optional HTTPS configs no
longer contain template placeholders, that public security headers and
rate/connection guardrails are present, and that `/internal/metrics` stays
loopback-only. Set `NGINX_VERIFY_REQUIRE_SSL=true` when HTTPS must be installed
on the node.

For repeatable single-node deployment, prefer the all-in-one script. It installs
dependencies, applies kernel tuning, configures host security, builds the
binary, writes systemd units, configures Nginx, starts services, and fails the
deployment if the local entrypoint does not pass health checks:

```bash
cd /opt/IMMonorepo
sudo bash deploy/ubuntu/90_deploy_single_node.sh
```

For the long-term production profile, pass the latest exported cloud security
group snapshot so the final audit has a fresh root-owned edge-posture evidence
file:

```bash
cd /opt/IMMonorepo
sudo IM_DEPLOY_CLOUD_SECURITY_GROUP_SOURCE_FILE=/tmp/imserver-security-group.json \
  bash deploy/ubuntu/90_deploy_single_node.sh
```

If the deploy host has an authenticated Aliyun CLI profile or RAM-role-backed
CLI access, the all-in-one deploy can fetch and audit the live security group
snapshot before installing it:

```bash
cd /opt/IMMonorepo
sudo IM_DEPLOY_ALIYUN_SECURITY_GROUP_ID=sg-... \
  IM_DEPLOY_ALIYUN_SECURITY_GROUP_REGION_ID=cn-shenzhen \
  bash deploy/ubuntu/90_deploy_single_node.sh
```

`IM_DEPLOY_CLOUD_SECURITY_GROUP_SOURCE_FILE` still takes precedence when both
are set. The Aliyun fetch path only reads `DescribeSecurityGroupAttribute`; it
does not create, edit, or delete cloud security group rules.

If you are editing the Aliyun console manually, make the inbound security group
match this production target before collecting evidence:

| Port | Source | Action |
| --- | --- | --- |
| `80/tcp` | `0.0.0.0/0` | Allow only for ACME HTTP challenge or HTTP-to-HTTPS redirect. |
| `443/tcp` | `0.0.0.0/0` | Allow public HTTPS API traffic. |
| `9000/tcp` | `0.0.0.0/0` | Allow public IM TCP gateway traffic when clients connect directly. |
| `22/tcp` | `<your-admin-public-ip>/32` | Allow SSH only from the operator IP or VPN egress. |
| `3389/tcp` | any | Delete. This Ubuntu deployment does not use Windows RDP. |
| `8080/tcp` | any public CIDR | Delete for production. Keep it only during a short bootstrap window before DNS/HTTPS is ready. |
| `5432`, `6379`, `9092`, `8081`, `8082`, `18080` | any public CIDR | Delete; these must stay local/private. |

After manual edits, fetch and audit a fresh snapshot. A screenshot is useful for
human review, but production gates require the exported rules JSON and, for an
applied repair path, the verified repair receipt.

To make the all-in-one deploy generate the Aliyun repair plan before fetching
the final snapshot, enable the repair stage. This is still dry-run unless the
apply flag is also enabled:

```bash
cd /opt/IMMonorepo
sudo IM_DEPLOY_REPAIR_ALIYUN_SECURITY_GROUP=true \
  IM_DEPLOY_ALIYUN_SECURITY_GROUP_ID=sg-... \
  IM_DEPLOY_ALIYUN_SECURITY_GROUP_REGION_ID=cn-shenzhen \
  IM_DEPLOY_REPAIR_ALIYUN_SECURITY_GROUP_ADMIN_CIDR=<your-admin-public-ip>/32 \
  bash deploy/ubuntu/90_deploy_single_node.sh
```

Apply cloud changes during deploy only in a controlled maintenance window:

```bash
cd /opt/IMMonorepo
sudo IM_DEPLOY_REPAIR_ALIYUN_SECURITY_GROUP=true \
  IM_DEPLOY_REPAIR_ALIYUN_SECURITY_GROUP_APPLY=true \
  IM_DEPLOY_ALIYUN_SECURITY_GROUP_ID=sg-... \
  IM_DEPLOY_ALIYUN_SECURITY_GROUP_REGION_ID=cn-shenzhen \
  IM_DEPLOY_REPAIR_ALIYUN_SECURITY_GROUP_ADMIN_CIDR=<your-admin-public-ip>/32 \
  bash deploy/ubuntu/90_deploy_single_node.sh
```

The repair stage runs before services restart. After it completes, the deploy
fetches the live security group snapshot, audits it, installs it as
`/etc/imserver/cloud-security-group.json`, and then continues the existing
production gates. The repair stage writes a machine-readable plan and receipt to
`/var/lib/imserver/cloud-security-group/repairs/imserver-cloud-security-group-repair-plan-<deploy-id>.json`
and
`/var/lib/imserver/cloud-security-group/repairs/imserver-cloud-security-group-repair-receipt-<deploy-id>.json`
by default. The fetched Aliyun snapshot is also kept under
`/var/lib/imserver/cloud-security-group/snapshots/`. Override the evidence root
with `IM_DEPLOY_CLOUD_SECURITY_GROUP_EVIDENCE_DIR`, or override individual files
with `IM_DEPLOY_REPAIR_ALIYUN_SECURITY_GROUP_PLAN_JSON` and
`IM_DEPLOY_REPAIR_ALIYUN_SECURITY_GROUP_RECEIPT_JSON`. The receipt includes
status, apply and verify flags, summary counts, and SHA-256 records for the
plan, source snapshot, and post-apply snapshot when present. Dry-run repair
receipts are kept for review but do not advance stable production evidence
links. After an applied repair passes post-apply verification, deploy also
advances stable symlinks:
`/var/lib/imserver/cloud-security-group/snapshots/latest-snapshot.json`,
`/var/lib/imserver/cloud-security-group/repairs/latest-repair-plan.json`, and
`/var/lib/imserver/cloud-security-group/repairs/latest-repair-receipt.json`.
When cloud security group auditing is required, the production readiness gate,
final deploy audit, and recurring operational audit also verify the latest
repair receipt by default. This keeps the installed rules file tied to the
audited Aliyun repair/fetch evidence instead of accepting a copied JSON file with
no provenance.

Verify a saved repair receipt before treating it as production evidence:

```bash
ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_JSON=/var/lib/imserver/cloud-security-group/repairs/latest-repair-receipt.json \
ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_REQUIRE_APPLIED=true \
ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_REQUIRE_VERIFIED=true \
ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_SECURITY_GROUP_ID=sg-... \
ALIYUN_SECURITY_GROUP_REPAIR_RECEIPT_EXPECT_REGION_ID=cn-shenzhen \
  bash deploy/ubuntu/31_verify_aliyun_security_group_repair_receipt.sh
```

If a new production topology smoke receipt and performance evidence package have
already been generated, install them in the same deploy so readiness,
`productionGate`, and recurring audits use the same target-bound evidence:

```bash
cd /opt/IMMonorepo
sudo IM_DEPLOY_CLOUD_SECURITY_GROUP_SOURCE_FILE=/tmp/imserver-security-group.json \
  IM_DEPLOY_TOPOLOGY_SMOKE_RECEIPT_SOURCE=/tmp/latest-production-smoke.json \
  IM_DEPLOY_PERFORMANCE_EVIDENCE_PACKAGE_SOURCE=/tmp/production-evidence.tar.gz \
  IM_DEPLOY_PRODUCTION_ACCEPTANCE_RECEIPT_JSON=/tmp/production-acceptance.json \
  bash deploy/ubuntu/90_deploy_single_node.sh
```

When the final performance gate is required, the all-in-one deploy checks this
before restarting services: either `IM_DEPLOY_TOPOLOGY_SMOKE_RECEIPT_SOURCE`
must point to an existing `latest-production-smoke.json`, or
`IM_DEPLOY_TOPOLOGY_SMOKE_LATEST_RECEIPT` must already exist at the readiness
path. Likewise, either `IM_DEPLOY_PERFORMANCE_EVIDENCE_PACKAGE_SOURCE` must
point to an existing package, or the configured current-evidence link must
already exist with durable `production-acceptance.json` and
`production-acceptance-package.tar.gz` sidecars. When installing new evidence,
`IM_DEPLOY_PRODUCTION_ACCEPTANCE_RECEIPT_JSON` must point to the matching
`run_production_acceptance.sh` receipt; the deploy installer stores the receipt
and package as sidecars inside the current evidence release. This catches missing
or non-durable topology/performance evidence in the pre-restart gate instead of
waiting for the post-restart final audit or readiness gate to fail.
The same pre-restart gate also checks cloud security group evidence whenever the
final audit requires it: either `IM_DEPLOY_CLOUD_SECURITY_GROUP_SOURCE_FILE`
must point to an existing rules JSON export, or the configured
`IM_DEPLOY_FINAL_AUDIT_CLOUD_SECURITY_GROUP_RULES_FILE` must already be
installed.

Builds are installed as versioned releases under `/opt/imserver/releases`.
`/opt/imserver/bin/IMServer` and `/opt/imserver/current` are symlinks to the
active release. The all-in-one deploy script builds the new release, verifies
production environment requirements, runs database migrations with the one-shot
`ops` role, and only then restarts long-running services. The downtime window is
limited to restart plus health and smoke gates.
When `IMSERVER_RELEASE_ID` is provided manually, `40_build_imserver.sh` requires
it to be a short safe token made of letters, numbers, `.`, `_`, and `-`, starting
with a letter or number and containing no `..` sequence. The resolved release
directory must stay under `/opt/imserver/releases`; otherwise the build fails
before deleting or creating the release directory.

Each release includes:

- `release.env` for shell-readable release metadata.
- `release-manifest.json` with release id, build configuration, source path,
  git commit, branch, dirty flag, Swift version, and binary SHA-256.
- `SHA256SUMS` covering `bin/IMServer`, `release.env`, and
  `release-manifest.json`.

The operational audit validates that release `SHA256SUMS` contains only those
three expected relative paths before running `sha256sum -c`, so a tampered
release checksum file cannot make the audit read arbitrary host paths.
Run the local release-id safety self-test after changing release build logic:

```bash
BUILD_IMSERVER_SELF_TEST=true \
  bash deploy/ubuntu/40_build_imserver.sh
```

On an existing deployment, the all-in-one script also runs a pre-deploy backup
before building and switching the release. The backup id is
`predeploy-<timestamp>`, it is verified immediately with `81_verify_backup.sh`,
and any failure stops the deploy before the active binary is changed. First-time
deploys skip this step because `/etc/imserver/common.env` does not exist yet.
Set `IM_DEPLOY_PRE_BACKUP=false` only when an external database snapshot has
already been taken and verified.

After services restart and pass entrypoint smoke, the all-in-one script runs a
post-deploy backup by default. The backup id is `postdeploy-<timestamp>`, it is
verified immediately, and it advances `/var/backups/imserver/latest`. The final
operational audit then requires that latest backup to exist and pass
`81_verify_backup.sh`. Set `IM_DEPLOY_POST_BACKUP=false` only when another
verified backup mechanism has already produced the latest backup, and pair that
with `IM_DEPLOY_FINAL_AUDIT_REQUIRE_BACKUP=false` only during first-bootstrap
diagnostics.

The all-in-one deploy must be run as root and uses a local deploy lock at
`/run/lock/imserver-deploy.lock.d` to prevent two deployments from racing the same
release symlinks, migrations, service restarts, and rollback gates. If a deploy
process dies, the lock is considered stale after `21600` seconds by default.
Override with `IM_DEPLOY_LOCK_DIR` or `IM_DEPLOY_LOCK_STALE_SECONDS`. Set
`IM_DEPLOY_DISABLE_LOCK=true` only after manually confirming no deploy is still
running.

Before restart, the all-in-one deploy resolves the final audit profile, verifies
mandatory public target binding, enforces the hard evidence gates, verifies
generated systemd units, runs production environment validation, the
migration/schema gate, logrotate installation, Nginx/HTTPS installation, and
then installs any provided cloud security group snapshot or performance evidence
package. If one of those pre-restart gates fails after the release symlink has
been updated and a previous release exists, the script rolls the symlink back
before exiting. Migrations must stay backward compatible because database
changes that already succeeded are not reversed automatically.

Run the systemd unit gate manually after changing service templates:

```bash
sudo bash deploy/ubuntu/52_verify_systemd_units.sh
```

It checks that each IMServer unit has the common and role environment files,
`ExecStart`, restart policy, `LimitNOFILE`, `TasksMax`, resource accounting, and
basic sandboxing, then runs `systemd-analyze verify` when available. It also
checks the generated `kafka.service` for the Kafka user/group, startup command,
restart policy, file/task limits, resource accounting, and the same basic
sandboxing posture.

After restart, the all-in-one deploy runs the HTTP entrypoint repair, entrypoint
health, application smoke, backup timer install, operational-audit timer install,
post-deploy backup, and final operational audit. When the final performance gate
is required, `PUBLIC_BASE_URL` or `IM_PUBLIC_BASE_URL` is mandatory and the
entrypoint gate requires public `/nginx-health` and `/health` to return `200`, so
a cloud/WAF misroute fails before any performance evidence can satisfy the
deploy. The application smoke step also uses the same effective public base URL,
so login and `/api/me` are checked through the public route instead of silently
falling back to loopback. Disable the repair step with
`IM_REPAIR_ENTRYPOINT_ON_VERIFY=false` only during a controlled diagnosis. The
final audit defaults to
`IM_DEPLOY_FINAL_AUDIT_REQUIRE_BACKUP=true` and
`IM_DEPLOY_FINAL_AUDIT_VERIFY_BACKUP=true`, so a deployment does not finish as
healthy without a verified backup. When the final performance gate is required,
the deploy also refuses `IM_RUN_ENTRYPOINT_SMOKE=false`,
`IM_DEPLOY_FINAL_AUDIT_REQUIRE_BACKUP=false`, or
`IM_DEPLOY_FINAL_AUDIT_VERIFY_BACKUP=false`, and it forces
`IM_DEPLOY_FINAL_AUDIT_REQUIRE_ALERT_WEBHOOK=true`,
`IM_DEPLOY_FINAL_AUDIT_REQUIRE_RESTORE_DRILL_FRESHNESS=true`, and
`IM_DEPLOY_FINAL_AUDIT_REQUIRE_OFFSITE_BACKUP_FRESHNESS=true` even if the raw
overrides are `false`; first bootstrap or diagnostic deploys must disable
`IM_DEPLOY_FINAL_AUDIT_REQUIRE_PERFORMANCE_GATE` instead of weakening those hard
checks individually. The final audit policy also owns the operational baseline:
entrypoint, host security, production env validation, HTTPS certificate,
certbot renewal, restricted SSH CIDR, closed RDP, SSH access, release manifest,
datastore loopback, and disk threshold settings are passed to both the recurring
audit timer and the final deploy audit. It also owns backup and DR freshness
policy: latest-backup freshness is required by default, and restore-drill plus
offsite-backup freshness are required whenever the final performance gate is
enabled. If their first PASS receipts do not exist yet, run a first-bootstrap
deploy with `IM_DEPLOY_FINAL_AUDIT_REQUIRE_PERFORMANCE_GATE=false`, create the
restore/offsite receipts, then rerun the long-term gate. The final audit also inherits
operational audit's performance-evidence defaults: in production it requires the installed
performance gate and, by default, profile artifacts plus broader product-plan
and product-campaign evidence plus current production readiness artifacts. Set
`IM_DEPLOY_FINAL_AUDIT_REQUIRE_PERFORMANCE_GATE=false` only during
a first-bootstrap or controlled diagnostic deploy where evidence is not
installed yet. When the performance gate is required, profile, product-plan,
product-campaign, and current-readiness artifact requirements are forced on even
if their deploy overrides are set to `false`. The operational-audit timer installed by the same
deploy receives the effective performance-gate, profile-artifact, product-plan,
product-campaign, current-readiness, and validation-inventory requirements, so
recurring audits do not drift from the final deploy audit. It also receives the
same edge-posture requirements as the final deploy audit:
`IM_DEPLOY_FINAL_AUDIT_REQUIRE_CLOUD_SECURITY_GROUP`,
`IM_DEPLOY_FINAL_AUDIT_CLOUD_SECURITY_GROUP_RULES_FILE`, the cloud security
group port policy, `IM_DEPLOY_FINAL_AUDIT_REQUIRE_NGINX_CONFIG`, and the Nginx
config paths. When the final performance gate is required, cloud security group
auditing is forced on even if the raw override is false; use
`IM_DEPLOY_FINAL_AUDIT_REQUIRE_PERFORMANCE_GATE=false` only for first bootstrap.
If you have just exported the cloud security group rules, pass
`IM_DEPLOY_CLOUD_SECURITY_GROUP_SOURCE_FILE=/path/rules.json`; the all-in-one
deploy validates and installs that snapshot with
`27_install_cloud_security_group_snapshot.sh` before services restart. If you also pass
`IM_DEPLOY_TOPOLOGY_SMOKE_RECEIPT_SOURCE=/path/latest-production-smoke.json`,
the deploy installs that receipt and rewrites its artifact paths with
`72_install_topology_smoke_receipt.sh` before services restart. If you pass
`IM_DEPLOY_PERFORMANCE_EVIDENCE_PACKAGE_SOURCE=/path/production-evidence.tar.gz`,
the deploy installs that package with `69_install_performance_evidence_package.sh`
before services restart, using the same profile, target binding, artifact
requirements, current-evidence link, and gate JSON path that the final audit
will verify.
It also receives the same performance
evidence target binding: gate JSON path, selected profile, evidence-current
link, expected public `BASE_URL`, and expected TCP host/port. By default the
deploy resolves public `BASE_URL` from `PUBLIC_BASE_URL` or
`IM_PUBLIC_BASE_URL`, resolves TCP host from
`IM_DEPLOY_FINAL_AUDIT_PERFORMANCE_GATE_EXPECT_TCP_HOST`, `TCP_HOST`,
`IM_PUBLIC_HOST`, or the hostname parsed from the public base URL, and resolves
TCP port from `TCP_PORT` or `IM_TCP_PORT`, with TCP port falling back to `9000`.
Override with `IM_DEPLOY_FINAL_AUDIT_PERFORMANCE_GATE_EXPECT_BASE_URL`,
`IM_DEPLOY_FINAL_AUDIT_PERFORMANCE_GATE_EXPECT_TCP_HOST`, and
`IM_DEPLOY_FINAL_AUDIT_PERFORMANCE_GATE_EXPECT_TCP_PORT` when the public HTTP
and TCP endpoints intentionally differ. This prevents performance evidence from
another server, DNS name, or TCP port from satisfying the cutover gate. The final
`deploy result=pass` line also prints those effective audit requirements and
target fields, not the raw optional overrides, so release logs show the actual
policy that was enforced. It prints `cloudSecurityGroupSourceProvided` and
`performanceEvidencePackageProvided` as booleans so operators can tell whether
the deploy installed fresh external evidence without exposing local source
paths in logs. If any post-deploy gate fails and a previous release exists, it
rolls back automatically through `45_rollback_release.sh`.
Automatic rollback carries the effective final-audit policy from the failed
deploy into the rollback audit: backup/DR freshness, public target binding,
performance gate, product evidence requirements, production acceptance receipt
freshness, cloud security group policy, Nginx config paths, alert webhook, and
release/host safety checks. This keeps a failed deploy from rolling back under a
weaker audit profile than the one that blocked the deploy.
Set `IM_DEPLOY_AUTO_ROLLBACK=false` only for a controlled diagnostic deploy
where you want to leave the failed release active for inspection. First-time
deploys have no previous release, so they fail without attempting rollback.

Before rollback, the all-in-one deploy writes best-effort failure artifacts to
`/var/log/imserver/deploy-failures/<deploy-id>/` by default. The directory
includes `summary.txt`, machine-readable `failure-manifest.json`,
`entrypoint-diagnose.log`, a redacted diagnostics bundle, and, when
`SSH_AUTHORIZED_KEY` or `SSH_PRIVATE_KEY_PATH` is available, a
`current-node-access-rescue` cloud-console recovery package. The manifest records
file sizes and SHA256 digests for later integrity checks. The deploy also writes
`failure-artifacts-verify.log` after running
`91_verify_deploy_failure_artifacts.sh`; the manifest records that verifier log
as verification metadata without hashing it, avoiding a self-referential
checksum. It then packages the directory with
`92_package_deploy_failure_artifacts.sh`, producing sibling `.tar.gz`,
`.sha256`, `.verify.sh`, `.README.md`, and `.receipt.json` sidecars for offline
handoff. Set
`IM_DEPLOY_FAILURE_ARTIFACTS=false` only for a controlled run where no local
failure bundle should be written; set `IM_DEPLOY_FAILURE_RESCUE_ARTIFACT=false`
to keep diagnostics but skip rescue-package generation. The package verifier
checks the archive hash, safely extracts members inside the verifier, and
rejects unsafe tar members such as absolute paths, `..` traversal, links,
unsupported member types, oversized files, and oversized total payloads. It
also validates the adjacent `.receipt.json` sidecar so the recorded archive
name, SHA256, verifier script, and first command stay consistent with the
package being handed off.

Verify a failure artifact directory before sharing or archiving it:

```bash
sudo DEPLOY_FAILURE_ARTIFACT_DIR=/var/log/imserver/deploy-failures/<deploy-id> \
  bash deploy/ubuntu/91_verify_deploy_failure_artifacts.sh
```

Package an existing failure artifact directory manually when needed:

```bash
sudo DEPLOY_FAILURE_ARTIFACT_DIR=/var/log/imserver/deploy-failures/<deploy-id> \
  bash deploy/ubuntu/92_package_deploy_failure_artifacts.sh
```

Run the all-in-one deploy self-test locally after changing deployment order or
post-deploy gates. It does not require root and does not touch system services;
it verifies that the script still runs post-deploy backup before the final audit,
requires the final audit to verify latest backup, writes failure artifacts before
rollback, and keeps release cleanup after all post-deploy gates:

```bash
IM_DEPLOY_SELF_TEST=true bash deploy/ubuntu/90_deploy_single_node.sh
```

Release cleanup runs only after all post-deploy gates pass. Use
`IMSERVER_RELEASE_KEEP` to control retention; the value must be at least `2` so
one previous release remains available for rollback. Run cleanup manually when
needed:

```bash
sudo IMSERVER_RELEASE_KEEP=5 bash deploy/ubuntu/46_prune_releases.sh
```

Run the migration/schema gate manually after editing production database
configuration or before a controlled restart:

```bash
sudo bash deploy/ubuntu/56_run_migrations.sh
```

The script reads `/etc/imserver/common.env`, sets `IM_RUNTIME_ROLE=ops` and
`IM_AUTO_MIGRATE_ON_START=true`, runs the current
`/opt/imserver/bin/IMServer ops` process, and relies on server startup to execute
registered Fluent migrations plus `IMSchemaValidator`. Serving roles must keep
`IM_AUTO_MIGRATE_ON_START` unset or false in production.

Configuration files under `/etc/imserver` are treated as secret-bearing
deployment state. `50_install_systemd_units.sh` creates or repairs these modes
on every run:

- `/etc/imserver`: `root:root 0750`
- `/etc/imserver/common.env`: `root:root 0640`
- `/etc/imserver/roles`: `root:root 0750`
- `/etc/imserver/roles/*.env`: `root:root 0640`
- `/etc/imserver/operational-alert.env`: `root:root 0600` when alerting is configured

The operational audit fails if these files drift to broader permissions.

Rollback to the previous release:

```bash
sudo bash deploy/ubuntu/45_rollback_release.sh
```

Rollback to a specific release id:

```bash
sudo bash deploy/ubuntu/45_rollback_release.sh 20260617T120000Z
```

Rollback restarts IMServer services and reruns entrypoint health plus application
smoke by default. In production, rollback verification defaults
`IM_RELEASE_VERIFY_REQUIRE_PUBLIC=true`; it resolves `PUBLIC_BASE_URL` or
`IM_PUBLIC_BASE_URL` from the environment or `/etc/imserver/common.env`, passes
that value to `65_verify_entrypoint.sh`, and runs `66_smoke_entrypoint.sh`
against the same public base URL. This prevents a rollback from reporting
healthy when only loopback recovered but the cloud/public entrypoint still
returns `403` or routes to the wrong host. Set
`IM_RELEASE_VERIFY_REQUIRE_PUBLIC=false` only for a controlled local-only
diagnostic, and set `IM_RELEASE_VERIFY_AFTER_ROLLBACK=false` only when you are
manually recovering a broken host and will run verification yourself.
Production rollback also defaults `IM_RELEASE_AUDIT_AFTER_ROLLBACK=true` and
runs `77_operational_audit.sh` after the public entrypoint and smoke checks. The
rollback audit requires the operational-audit timer, restore-drill timer, latest
backup presence, host security, performance evidence, and alert webhook through
the same production defaults as normal readiness. It explicitly passes the
rollback operational baseline into the audit: public entrypoint, production env
validation, HTTPS certificate, certbot renewal timer, restricted SSH CIDR,
closed RDP, SSH access, release manifest, datastore loopback, and disk threshold
settings. It also passes backup and DR freshness policy: latest-backup
freshness, restore-drill freshness receipt/path/age, and offsite-backup
freshness receipt/path/age. It also passes the rollback
performance-gate settings into the audit: `IM_RELEASE_AUDIT_REQUIRE_PERFORMANCE_GATE`,
`IM_RELEASE_AUDIT_PERFORMANCE_GATE_JSON`, `IM_RELEASE_AUDIT_PERFORMANCE_GATE_PROFILE`,
freshness/git checks, expected public base URL, expected TCP host/port,
production profile catalog, current evidence link, and performance evidence
artifact policy. When the rollback performance gate is required, the rollback
audit also forces `AUDIT_REQUIRE_ALERT_WEBHOOK=true` so a rollback cannot report
production-ready without an alert path. It also forces profile, product-plan,
product-campaign, product scenario suite, and current-readiness evidence
artifact checks on even if the corresponding
`IM_RELEASE_AUDIT_REQUIRE_*_ARTIFACTS` override is set to `false`; use
`IM_RELEASE_AUDIT_REQUIRE_PERFORMANCE_GATE=false` only for a controlled
first-bootstrap or diagnostic rollback.
The rollback audit also carries the final production acceptance policy:
`IM_RELEASE_AUDIT_REQUIRE_PRODUCTION_ACCEPTANCE`,
`IM_RELEASE_AUDIT_PRODUCTION_ACCEPTANCE_MAX_AGE_SECONDS`,
`IM_RELEASE_AUDIT_PRODUCTION_ACCEPTANCE_MAX_FUTURE_SKEW_SECONDS`,
`IM_RELEASE_AUDIT_PRODUCTION_ACCEPTANCE_RECEIPT_JSON`, and
`IM_RELEASE_AUDIT_PRODUCTION_ACCEPTANCE_PACKAGE_FILE`. When the rollback
performance gate is required, production acceptance evidence is required too.
By default the audit verifies the durable `production-acceptance.json` and
`production-acceptance-package.tar.gz` sidecars in the installed current
evidence release, with the same 86400-second freshness policy used by deploy,
readiness, and recurring audits.

Rollback also passes the edge-posture settings into the audit:
`IM_RELEASE_AUDIT_REQUIRE_CLOUD_SECURITY_GROUP`,
`IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_RULES_FILE`, the cloud security group
port policy, `IM_RELEASE_AUDIT_REQUIRE_NGINX_CONFIG`, and the Nginx config
paths. In production, cloud security group auditing defaults to required after
rollback. When the rollback performance gate is required, cloud security group
auditing is forced on even if `IM_RELEASE_AUDIT_REQUIRE_CLOUD_SECURITY_GROUP=false`;
the rollback audit also verifies the latest applied Aliyun repair receipt via
`IM_RELEASE_AUDIT_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON` plus the expected
security group id, region, admin CIDR, and max-age policy.
disable `IM_RELEASE_AUDIT_REQUIRE_PERFORMANCE_GATE` only for a controlled
first-bootstrap or diagnostic rollback. It sets
`AUDIT_VERIFY_LATEST_BACKUP=false` by default so rollback does not spend time
rechecksumming a large backup artifact; set `IM_RELEASE_AUDIT_VERIFY_BACKUP=true`
when you want a full latest-backup verification after rollback. Set
`IM_RELEASE_AUDIT_AFTER_ROLLBACK=false` only for an emergency diagnostic where
you are intentionally restoring service first and will run the audit manually
afterward.

Run the read-only operational audit after manual changes or before a load test:

```bash
sudo -E make run-operational-audit
```

This delegates to the underlying script:

```bash
sudo bash deploy/ubuntu/77_operational_audit.sh
```

The audit checks active services, backup timer state, current release symlinks,
release manifest validity, release checksums, latest backup validity when
present, core long-connection sysctl values, disk usage, host security, HTTPS
certificate validity, production environment drift, and entrypoint health. The
all-in-one deploy script runs it as the final step.
When performance evidence is required, the audit also verifies that the
installed evidence summary exposes valid profile status, product-plan status,
and product-campaign name/status/failure/attempted/skipped counters; a verifier
that returns success but omits those fields, emits placeholder names, or emits
non-numeric campaign counters is treated as an audit failure. For a `PASS`
campaign summary, failure counters and skipped stages must be zero and attempted
stages must be greater than zero.
It also verifies the installed operational-audit, backup, and restore-drill
systemd units still point to the repository audit, backup, backup-verification,
restore-drill, and alert scripts; an enabled timer with a drifted `ExecStart`,
missing `OnFailure`, or missing log append target is treated as audit failure.
For old releases built before manifests existed, set
`AUDIT_REQUIRE_RELEASE_MANIFEST=false` only during a controlled migration window;
new production releases should keep the default `true`.

Run the unit-content self-test locally after changing operational audit or
backup/restore unit templates:

```bash
make check-production-ops

# Focused script-level checks:
INSTALL_DEPENDENCIES_SELF_TEST=true bash deploy/ubuntu/00_install_dependencies.sh
AUDIT_UNIT_SELF_TEST=true bash deploy/ubuntu/77_operational_audit.sh
AUDIT_PERFORMANCE_SUMMARY_SELF_TEST=true bash deploy/ubuntu/77_operational_audit.sh
```

Use the production readiness gate before declaring a node ready for production
traffic or before starting a serious load test:

```bash
sudo -E make run-production-readiness-gate

# Equivalent script-level command:
sudo PUBLIC_BASE_URL=https://chat.yourdomain.com \
  bash deploy/ubuntu/95_production_readiness_gate.sh
```

It runs systemd unit verification, production environment validation, entrypoint
health, optional application smoke, production topology-smoke receipt
verification, operational audit, latest backup verification when present,
diagnostics redaction self-test, and optional restore drill or diagnostics
bundle collection. When a public base URL is configured, readiness passes it to
both entrypoint health and application smoke. On success it writes a
machine-readable readiness receipt to
`/var/lib/imserver/readiness/latest.json` by default; override
`READINESS_RECEIPT_JSON` for a custom path or set `READINESS_WRITE_RECEIPT=false`
only for local script experiments. The receipt records the public target,
effective hard gates, evidence paths, and the pass/skipped state of each
readiness step, so later deployment reviews can prove which production
requirements were enforced by that run. Useful toggles:

- `READINESS_REQUIRE_SMOKE=false` skips application login smoke only when the
  performance gate is also disabled.
- `READINESS_REQUIRE_BACKUP=false` allows a first run before the first scheduled
  backup only when the performance gate is also disabled.
- `READINESS_REQUIRE_TOPOLOGY_SMOKE=false` skips the Docker production topology
  smoke receipt only when the performance gate is also disabled. When the
  performance gate is enabled, readiness requires
  `READINESS_TOPOLOGY_SMOKE_JSON` to point at a fresh
  `latest-production-smoke.json` produced by `make run-imserver-production-smoke`
  and verified by `IMServer/scripts/verify_production_smoke.py`. The default
  path is `/var/lib/imserver/production-smoke/latest-production-smoke.json`;
  keep `READINESS_TOPOLOGY_SMOKE_REQUIRE_ARTIFACTS=true` when the referenced
  report/state/log artifacts are copied to the production host.
- `READINESS_REQUIRE_LATEST_BACKUP_FRESHNESS=true` is required whenever the
  performance gate is enabled; adjust `READINESS_LATEST_BACKUP_MAX_AGE_SECONDS`
  only when the backup schedule intentionally differs from the default daily
  cadence. `READINESS_REQUIRE_RESTORE_DRILL_FRESHNESS=true` and
  `READINESS_REQUIRE_OFFSITE_BACKUP_FRESHNESS=true` are forced whenever the
  performance gate is enabled, even if their raw overrides are `false`, so
  long-term readiness requires recent PASS receipts for restore drill and
  offsite backup.
- `READINESS_RUN_RESTORE_DRILL=true` verifies the latest backup can restore into a temporary drill database.
- `READINESS_COLLECT_DIAGNOSTICS=true` writes a redacted diagnostics bundle as part of the gate.
- `READINESS_REQUIRE_ALERT_WEBHOOK=true` requires the operational alert webhook
  to be configured and valid before readiness can pass. It is forced on whenever
  `READINESS_REQUIRE_PERFORMANCE_GATE=true`, even if the raw override is `false`.
- `BACKUP_ROOT=/path/to/backups` makes readiness verify and optionally restore
  `${BACKUP_ROOT}/latest`; keep it aligned with the backup timer and operational
  audit when backups are stored outside `/var/backups/imserver`.
- `READINESS_REQUIRE_PERFORMANCE_GATE` defaults to `true` when the effective
  `APP_ENV` is `production`, and `false` otherwise. When enabled, it requires a
  production public target: `PUBLIC_BASE_URL` or `IM_PUBLIC_BASE_URL` must use
  `https://` with a real DNS name, not a raw IP, localhost, single-label host,
  `.local`, `.test`, `.invalid`, or `example.*` placeholder domain. The TCP
  target must also be a real DNS name resolved from
  `PERF_PRODUCTION_GATE_EXPECT_TCP_HOST`, `TCP_HOST`, `IM_PUBLIC_HOST`, or the
  public URL host. Readiness then passes `VERIFY_REQUIRE_PUBLIC=true` to the
  entrypoint verifier, so a production gate cannot silently fall back to
  loopback-only health checks. It also requires a copied `production-gate.json`
  from `IMServer/LoadTests/run_perf_scenarios.sh` before declaring the node
  ready for production traffic. By default it reads
  `/var/lib/imserver/performance/production-gate.json`, expects profile
  `normal-product-baseline`, and rejects evidence older than 7 days. Set
  `READINESS_REQUIRE_PERFORMANCE_GATE=false` only for first bootstrap or a
  controlled diagnostic where performance evidence is not yet available.
  Override with `PERF_PRODUCTION_GATE_JSON`, `PERF_PRODUCTION_GATE_PROFILE`, or
  `PERF_PRODUCTION_GATE_MAX_AGE_SECONDS`. Override
  `PERF_PRODUCTION_PROFILE_CATALOG` only when the deployment scripts are not
  running from the repository path that contains
  `IMServer/LoadTests/perf_production_profiles.json`. Set
  `PERF_PRODUCTION_GATE_REQUIRE_CURRENT_GIT=true` when readiness must reject
  evidence whose `source.gitCommit` differs from the current repository `HEAD`.
  Set `PERF_PRODUCTION_GATE_REQUIRE_CLEAN_GIT=true` when production readiness
  must also reject evidence generated from a dirty worktree. Readiness resolves
  target fields from `PUBLIC_BASE_URL`, `IM_PUBLIC_BASE_URL`, `TCP_HOST`,
  `IM_PUBLIC_HOST`, `TCP_PORT`, or `IM_TCP_PORT` in the current environment or
  `/etc/imserver/common.env`, with TCP port falling back to `9000`, so the
  installed performance gate must match the current server target. Set
  `PERF_PRODUCTION_GATE_EXPECT_BASE_URL`,
  `PERF_PRODUCTION_GATE_EXPECT_TCP_HOST`, or
  `PERF_PRODUCTION_GATE_EXPECT_TCP_PORT` explicitly only when the expected
  evidence target intentionally differs from the deployed public endpoint.
  When the performance gate is required, readiness also refuses
  `READINESS_REQUIRE_SMOKE=false`, `READINESS_REQUIRE_BACKUP=false`, or
  `READINESS_VERIFY_BACKUP=false`,
  `READINESS_REQUIRE_LATEST_BACKUP_FRESHNESS=false`, and forces
  `READINESS_REQUIRE_ALERT_WEBHOOK=true`; use
  `READINESS_REQUIRE_PERFORMANCE_GATE=false` for first bootstrap or controlled
  diagnostics instead of weakening those hard checks individually.
  When the performance gate is required, readiness also defaults
  `PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_PLAN_ARTIFACTS=true`; production
  readiness therefore requires broader product-plan evidence in addition to the
  selected production-profile SLO gate. When the performance gate is required,
  an explicit `false` is ignored; first-bootstrap or diagnostic windows must
  disable `READINESS_REQUIRE_PERFORMANCE_GATE` instead.
  When the performance gate is required, readiness also defaults
  `PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS=true`;
  production readiness therefore requires an executed PASS campaign receipt,
  including non-large-group release stages before isolated large-group stress.
  Domain regression campaigns such as `product-scenario-regression` are useful
  diagnostics, but they are not accepted as production-gate campaign evidence.
  When the performance gate is required, an explicit `false` is ignored;
  first-bootstrap or diagnostic windows must disable
  `READINESS_REQUIRE_PERFORMANCE_GATE` instead.
  When the performance gate is required, readiness also defaults
  `PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS=true` and
  `PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_NO_LARGE_GROUP=true`;
  production readiness therefore requires the packaged current-readiness run to
  include a PASS product scenario suite receipt, and rejects ordinary production
  evidence if that suite coverage includes isolated large-group stress. When the
  performance gate is required, an explicit artifact `false` is ignored;
  first-bootstrap or diagnostic windows must disable
  `READINESS_REQUIRE_PERFORMANCE_GATE` instead.
  When the performance gate is required, readiness also defaults
  `PERF_PRODUCTION_EVIDENCE_REQUIRE_CURRENT_READINESS_ARTIFACTS=true`;
  production readiness therefore requires a current-environment readiness
  receipt with smoke, baseline, and full-acceptance runs all passing. This keeps
  large-group stress isolated from broader product-surface acceptance: ordinary
  auth/session, sync, direct-message, group workflow, media, social, moderation,
  and realtime scenarios must be packaged as evidence before the isolated
  large-group result can support a production claim. When the performance gate
  is required, an explicit `false` is ignored; first-bootstrap or diagnostic
  windows must disable `READINESS_REQUIRE_PERFORMANCE_GATE` instead.
  `PERF_PRODUCTION_EVIDENCE_REQUIRE_VALIDATION_INVENTORY=true` is also the
  production default; keep it enabled so readiness proves the packaged evidence
  included the validation inventory generated with the load-test toolchain.
The readiness gate passes the same profile, gate path, catalog,
current-evidence link, freshness, git-match, clean-git, profile-artifact,
product-plan-artifact, product-campaign-artifact, product-scenario-suite,
current-readiness-artifact, and validation-inventory settings into its embedded
operational audit step, so both checks evaluate the same performance evidence.
It also passes the production edge-posture checks into that audit:
`READINESS_REQUIRE_CLOUD_SECURITY_GROUP` maps to
`AUDIT_REQUIRE_CLOUD_SECURITY_GROUP`, the cloud security group rules path and
port policy are forwarded, and `READINESS_REQUIRE_NGINX_CONFIG` plus the Nginx
config paths map to the Nginx drift verifier. When the performance gate is
required, cloud security group auditing is forced on even if the raw readiness
override is false; disable `READINESS_REQUIRE_PERFORMANCE_GATE` for first
bootstrap instead of weakening the edge checks.
Its local audit-env self-test also
verifies that readiness maps the production hard gates into operational audit:
latest backup required, latest backup verification required, operational-audit
timer required, and restore-drill timer required.
Use `READINESS_AUDIT_ENV_SELF_TEST=true` when you need to validate that mapping
without running the full readiness gate.

After the Docker production topology smoke and the selected production
performance profile both pass, copy the topology smoke receipt and performance
evidence package to the server, install both through their verifiers, and run
the readiness gate:

```bash
sudo TOPOLOGY_SMOKE_RECEIPT_SOURCE=/tmp/latest-production-smoke.json \
  bash deploy/ubuntu/72_install_topology_smoke_receipt.sh
sudo PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCTION_ACCEPTANCE=true \
  PERF_PRODUCTION_ACCEPTANCE_RECEIPT_JSON=/tmp/production-acceptance.json \
  bash deploy/ubuntu/69_install_performance_evidence_package.sh \
  /tmp/production-evidence-*.tar.gz
sudo READINESS_REQUIRE_PERFORMANCE_GATE=true \
  PUBLIC_BASE_URL=https://chat.yourdomain.com \
  bash deploy/ubuntu/95_production_readiness_gate.sh

sudo python3 -m json.tool /var/lib/imserver/readiness/latest.json >/dev/null
```

Prefer the evidence package produced by
`IMServer/LoadTests/package_production_evidence.sh`; it contains the verified
gate file plus the matching dashboard, SLO, state, scenario status,
required profile catalog snapshot, validation inventory, structured evidence
manifest, README, optional product-plan runbook/receipt artifacts, and checksums.
For final production acceptance, also pass
`PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_RULES_FILE=/etc/imserver/cloud-security-group.json`
and
`PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_JSON=/var/lib/imserver/cloud-security-group/repairs/latest-repair-receipt.json`
when packaging. If `PERF_PRODUCTION_GATE_REQUIRE_PRODUCTION_TARGET=true`, the
package step automatically requires both the audited snapshot and an applied,
verified repair receipt. Set
`PERF_PRODUCTION_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP=true` when installing or
verifying the package. This copies the audited cloud security group snapshot into
the package as `cloud-security-group.json`, rewrites the Aliyun repair receipt
and its referenced plan/snapshot/post-apply snapshot into portable package-local
files, records their sha256 and size in the manifest, and makes packaging,
install, and recurring verification fail if the snapshot, repair receipt, or
manifest policy is missing or downgraded.
For the final long-term acceptance flow, also keep the sidecar
`production-acceptance.json` produced by `run_production_acceptance.sh` next to
the tarball and install with
`PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCTION_ACCEPTANCE=true` plus
`PERF_PRODUCTION_ACCEPTANCE_RECEIPT_JSON=/path/production-acceptance.json`. The
installer passes the tarball path to the receipt verifier, so the receipt's
package size and sha256 must match the evidence tarball being installed.
It then stores durable copies as
`production-acceptance.json` and `production-acceptance-package.tar.gz` inside
the installed current-evidence release.
The readiness gate also treats final production acceptance as required whenever
`READINESS_REQUIRE_PERFORMANCE_GATE=true`; by default it reuses those installed
sidecars to prove the evidence came from the same accepted package instead of
only from a standalone profile run. Use
`PERF_PRODUCTION_ACCEPTANCE_RECEIPT_JSON` during install/package handoff; after
installation, readiness and recurring audits verify the durable sidecars inside
the installed current-evidence release. Missing installed sidecars fail even if
the original temporary receipt or tarball path still exists.
The `production-acceptance.json` receipt itself also records
`cloudSecurityGroupRepairReceiptJSON` and requires
`requireCloudSecurityGroupRepairReceipt=true`; its verifier rejects receipts that
do not point to an applied and verified Aliyun security group repair receipt.
The verifier checks the repair receipt's snapshot, post-apply snapshot, and plan
artifact size/sha256 records, plus plan status and summary consistency, so a
hand-written status-only receipt cannot satisfy final acceptance.
The evidence package install and verify scripts also validate the package-local
`cloud-security-group-repair-receipt.json` with the same applied/verified and
freshness policy. `PERF_PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS`
defaults to `86400`; set it to `0` only for a documented historical evidence
audit.
It also enforces the receipt's `generatedAtEpoch` freshness. The default
acceptance receipt max age is `86400` seconds with a small future-clock-skew
tolerance; do not use a stale receipt to satisfy a new deploy gate. Generate a
new `production-acceptance.json` with `run_production_acceptance.sh` when the
evidence is older than the release window.
`69_install_performance_evidence_package.sh`,
`70_verify_performance_evidence_package.sh`, `77_operational_audit.sh`, the
operational audit timer, and `90_deploy_single_node.sh` all pass the same
freshness policy to `perf_production_acceptance_verify.py`. Override
`PERF_PRODUCTION_ACCEPTANCE_MAX_AGE_SECONDS` or
`IM_DEPLOY_PRODUCTION_ACCEPTANCE_MAX_AGE_SECONDS` only for an explicit
historical audit; keep the default `86400` seconds for new releases.
`69_install_performance_evidence_package.sh` verifies those checksums, validates
the extracted gate, validation inventory, profile artifacts, required
product-plan/product-campaign artifacts, and required current production
readiness artifacts before changing installed state, then installs
`production-gate.json` through
`68_install_performance_gate.sh`, keeps the full package contents under
`/var/lib/imserver/performance/current-evidence`, and runs
`70_verify_performance_evidence_package.sh` against the installed evidence
directory. It rejects unsafe tar members such as absolute paths or `..` path
traversal entries before extraction, and rejects extracted evidence trees that
contain symlinks or other non-regular files. A package that fails pre-install
validation does not advance the installed gate or current evidence link.
When direct evidence install is run outside the readiness gate, it still binds
verification to the current server target. If
`PERF_PRODUCTION_GATE_EXPECT_BASE_URL`,
`PERF_PRODUCTION_GATE_EXPECT_TCP_HOST`, or
`PERF_PRODUCTION_GATE_EXPECT_TCP_PORT` is not provided, the installer resolves
them from `PUBLIC_BASE_URL`, `IM_PUBLIC_BASE_URL`, `TCP_HOST`,
`IM_PUBLIC_HOST`, `TCP_PORT`, or `IM_TCP_PORT` in the current environment or
`/etc/imserver/common.env`, with TCP port falling back to `9000`. The install
summary prints `expectBaseURL`, `expectTCPHost`, `expectTCPPort`,
`profileEntrypointDiagnosis`, `profileEntrypointBlocker`, and
`productPlanBlockerType`/`productCampaignTarget` from the installed product
evidence receipts.
Standalone `70_verify_performance_evidence_package.sh` uses the same default
target resolution and prints those fields in its pass summary, so a manual
recurring-evidence check cannot accidentally validate evidence from another
server when the production env file is present.
Production evidence package install and recurring verification require the
broader non-large-group product plan by default, in addition to the
production-profile SLO gate. Set
`PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_PLAN_ARTIFACTS=false` only for a
controlled diagnostic package that intentionally contains profile evidence but
not product-plan evidence.
The package manifest records whether product-plan evidence is present and which
product-plan files were included. It also records the effective product-plan,
product-campaign, and current-readiness artifact policy; install and recurring
verification reject a missing or partial required evidence family. Operational audit also requires the
verifier summary to include `manifestRequireProfileArtifacts=true`,
`manifestRequireProductPlanArtifacts=true`, and
`manifestRequireProductCampaignArtifacts=true` whenever the corresponding
evidence family is required, so recurring audit logs prove that the active
package was not generated with a downgraded manifest policy. The readiness gate
performs the same summary check for its direct `performance-evidence` step
before reporting `readiness result=pass`; when profile evidence is required it
also requires `profileRunStatus`, `profileRunBlockerType`,
`profileEntrypointDiagnosis`, and a non-blocking `profileEntrypointBlocker`, so
an entrypoint P0 blocker cannot pass final readiness. When product-plan and
product-campaign evidence are required, readiness also checks that the product
plan is `PASS`, has no blocker, excludes large-group-only evidence, covers the
required domains, and that the campaign is `PASS` with zero failures, at least
one attempted stage, no skipped stages, and a concrete target. The same evidence
summary must include `productProfileGate=PASS` with positive
`productProfileGateChecked` and `productProfileGateRequiredDomains` counters, so
readiness cannot be satisfied by a large-group-only package.
Production evidence package install and recurring verification also require
`product-campaign-run.json` and `product-campaign-runbook.md` by default. The
campaign receipt must be an executed production-gate campaign with `PASS`.
Set `PERF_PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS=false` only
during a controlled bootstrap or diagnostic window where campaign evidence has
not been produced yet. Standalone `run_production_profile.sh` and
`run_product_test_plan.sh` packages explicitly opt out unless the caller sets
`PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS=true`; treat those as
diagnostic/profile packages, not final production acceptance evidence.
Production evidence package install and recurring verification also require
`current-production-readiness.json`/`.md` by default. The readiness receipt must
be `PASS`, and `smoke`, `productScenarioSuite`, `baseline`, and `fullAcceptance`
must all be requested with exit code `0`; the full-acceptance campaign run JSON
and runbook must also be present. Set
`PERF_PRODUCTION_EVIDENCE_REQUIRE_CURRENT_READINESS_ARTIFACTS=false` only during
a controlled bootstrap or diagnostic window where current-environment full
acceptance has intentionally not been produced yet.
Generate final acceptance receipts with
`CURRENT_PRODUCTION_REQUIRE_PACKAGEABLE_EVIDENCE=true` so
`run_current_production_readiness.sh` refuses partial baseline or
full-acceptance runs before load starts. The installed package summaries and
readiness gate must expose the product scenario suite fields
`currentReadinessRequestedProductScenarioSuite`,
`currentReadinessProductScenarioSuiteExitCode`,
`currentReadinessProductScenarioSuiteExpected`,
`currentReadinessProductScenarioSuiteStatus`, and
`currentReadinessProductScenarioSuiteLargeGroupIncluded`; production readiness
requires the suite to be requested, pass, and exclude isolated large-group
stress.
Installed evidence releases under `/var/lib/imserver/performance/evidence` are
pruned after a successful install; `PERF_PRODUCTION_EVIDENCE_RETAIN_RELEASES`
defaults to `10` and the active `current-evidence` target is always preserved.

`68_install_performance_gate.sh` validates the source `production-gate.json`
first, writes it atomically to `/var/lib/imserver/performance/production-gate.json`,
and verifies the installed copy. It rejects stale, failed, mismatched-profile, or
internally inconsistent evidence before the production readiness gate can use it.
The verifier also requires the `requiredScenarios` array to match the summary and
each required scenario to have `passed=true`, `latestSLOStatus=PASS`,
`runCount>0`, a non-empty `latestRunID`, a non-empty `latestRunDir`, and a
positive `latestMtime`. It also requires `requirements.runArtifacts=true`,
`summary.runArtifactMissingCount=0`, and every required scenario to record
`runArtifactsVerified=true` plus `runArtifactsOK=true`; this proves the local
production gate was tied to inspectable run output before packaging. Evidence
age is calculated from the oldest required scenario `latestMtime`, not from the
copied file's filesystem mtime, so reinstalling an old JSON file does not make
old performance evidence fresh. A hand-written summary-only PASS file or older
summary-only gate format is not accepted as production evidence. The gate also
requires `targetFilter.enabled=true` with non-empty `baseURL`, `tcpHost`, and
`tcpPort`, so a standalone copied gate cannot claim readiness using evidence from
another server target. When `PERF_PRODUCTION_GATE_EXPECT_BASE_URL`,
`PERF_PRODUCTION_GATE_EXPECT_TCP_HOST`, or
`PERF_PRODUCTION_GATE_EXPECT_TCP_PORT` is set, the verifier also compares those
values against the gate target and rejects mismatches. If those values are not
set, `67_verify_performance_gate.sh` resolves them from `PUBLIC_BASE_URL`,
`IM_PUBLIC_BASE_URL`, `TCP_HOST`, `IM_PUBLIC_HOST`, `TCP_PORT`, or `IM_TCP_PORT`
in the current environment or `/etc/imserver/common.env`, with TCP host falling
back to the hostname parsed from the public base URL and TCP port falling back to
`9000`. When the effective `APP_ENV` is `production`, or when
`PERF_PRODUCTION_GATE_REQUIRE_PRODUCTION_TARGET=true` is set,
`67_verify_performance_gate.sh` also requires the gate's `targetFilter.baseURL`
and the expected base URL to use `https://` with a real DNS name, and requires
the gate's `targetFilter.tcpHost` and expected TCP host to be real DNS names.
It rejects raw IPs, localhost, single-label hosts, `.local`, `.test`,
`.invalid`, and `example.*` placeholder domains, so loopback or temporary IP
performance evidence cannot satisfy a production gate.
`68_install_performance_gate.sh`, `69_install_performance_evidence_package.sh`,
and `70_verify_performance_evidence_package.sh` use the same resolution and
print the effective target in their result lines. Failed gates expose
`summary.failureKindCounts` and deployment verifier
errors print those counts as `failureKinds=...`, so operators can distinguish
missing runtime evidence, SLO failures, missing run artifacts, and missing
required scenarios without opening every scenario row. A `PASS` gate must not
carry non-zero failure-kind counts, and the verifier rejects inconsistent
`failedScenarioCount` versus `summary.failureKindCounts` totals. The installed
evidence directory must also keep
valid `SHA256SUMS`, a matching `production-gate.json`, required
`production-evidence-manifest.json`, required `perf_production_profiles.json`,
required `validation-inventory.json`/`.md`, required `docs-audit.json`/`.md`,
and profile/prereq audit artifacts generated by `run_production_profile.sh`, including
`production-profile-run.json`, `production-profile-entrypoint-probe.log`,
`production-profile-entrypoint-probe.json`, and `production-profile-runbook.md`. The runbook
records the exact profile command, manual batch commands, prereq state, and
expected evidence paths used to produce the package. The validation inventory source commit and dirty
flag must match the gate source, so a result generated from one checkout cannot
be packaged with script hashes from another checkout. The packaged
`docs-audit.json` must prove the load-test README scenario-group commands and
production-profile references match the executable matrix/profile catalog. The
packaged `product-profile-gate.json`/`.md` must prove
`normal-product-smoke`, `normal-product-baseline`, and
`normal-product-capacity` cover the required product domains without isolated
`large-group-*` stress profiles. The packaged
`perf_production_profiles.json` snapshot must match
`production-gate.json.profileCatalog.sha256`, so the installed evidence keeps
the exact profile definition used for the run. Those profile artifacts must match
the gate profile, the run receipt must be non-dry-run with final status `PASS` or
`NOOP`, its selected, skipped, and batch scenario counts must be internally
consistent, and all referenced batch/prereq scenarios may only reference
scenarios required by the selected production profile. The run receipt must have
`statusFilterTarget=true`, `production-gate.json.targetFilter.enabled` must be
true, and the gate target must match the runbook `baseURL`/`tcpHost`/`tcpPort`
when those fields are present. The gate file must include
`source.gitCommit`;
with `PERF_PRODUCTION_GATE_REQUIRE_CURRENT_GIT=true`, that commit must match the
repository `HEAD` visible to the deployment scripts. With
`PERF_PRODUCTION_GATE_REQUIRE_CLEAN_GIT=true`, the gate must also record
`source.gitDirty=false`. The verifier also loads
`IMServer/LoadTests/perf_production_profiles.json` and rejects a gate file whose
required scenario names do not exactly match the selected profile, so a partial
profile run cannot claim `normal-product-baseline` or
`non-large-group-baseline`. `production-gate.json` also records the SHA-256 of
the profile catalog used when the evidence was generated; deployment rejects the
gate if the current catalog hash differs. After changing
`perf_production_profiles.json`, rerun the selected production profile instead
of reusing an older gate file.

`78_install_operational_audit_timer.sh` installs a recurring operational audit:

```bash
sudo bash deploy/ubuntu/78_install_operational_audit_timer.sh
systemctl list-timers imserver-operational-audit.timer
```

To validate the rendered systemd units without root or systemd side effects:

```bash
AUDIT_TIMER_RENDER_SELF_TEST=true \
  bash deploy/ubuntu/78_install_operational_audit_timer.sh
```

Default behavior:

- schedule: every `15` minutes with up to `60s` randomized delay
- log file: `/var/log/imserver/operational-audit.log`
- install summary: prints the effective cloud-security-group repair receipt
  path, expected Aliyun identifiers/admin CIDR, repair-receipt max age, topology
  smoke receipt path/freshness/artifact policy, and production-acceptance
  max-age/future-skew policy so operators can confirm the recurring audit is
  using the same freshness window as deploy/readiness.
- checks: systemd services, backup timer, release symlinks, sysctl thresholds,
  release manifest/checksums, disk usage, host security, HTTPS certificate
  validity, production environment drift, and HTTP/TCP entrypoint health
- HTTPS certificate check: defaults to required. The audit expects
  `PUBLIC_BASE_URL`/`IM_PUBLIC_BASE_URL` to use `https://`, then checks that the
  certificate is valid for at least `14` more days. With
  `AUDIT_HTTPS_CERT_MODE=auto` it first checks
  `/etc/letsencrypt/live/<public-host>/fullchain.pem` when present, then falls
  back to the public TLS endpoint. Use `AUDIT_HTTPS_CERT_MODE=local` to require
  the local certificate file, `AUDIT_HTTPS_CERT_MODE=public` to always probe the
  public endpoint, `AUDIT_HTTPS_CERT_MIN_VALID_DAYS=<days>` to adjust the
  threshold, or `AUDIT_REQUIRE_HTTPS_CERTIFICATE=false` only during a controlled
  HTTP-only bootstrap window.
- Certbot renewal check: defaults to required when HTTPS certificate checks are
  enabled. The audit requires `certbot.timer` to be enabled and active so a
  certificate that is healthy today does not silently expire later. Set
  `AUDIT_REQUIRE_CERTBOT_RENEWAL_TIMER=false` only when HTTPS terminates outside
  this node or another renewal monitor owns the certificate lifecycle.
- Restore-drill freshness: disabled by default for first bootstrap, because the
  first production cutover may install the monthly timer before the first drill
  has run. After a successful drill, set
  `AUDIT_REQUIRE_RESTORE_DRILL_FRESHNESS=true` to require
  `/var/lib/imserver/restore-drill/latest.json` to be a recent PASS receipt.
  The default threshold is `AUDIT_RESTORE_DRILL_MAX_AGE_SECONDS=3888000`
  (`45d`), matching the monthly timer with operational slack. The receipt must
  include `backupManifestSha256`, a positive `publicBaseTables`, and non-empty
  `requiredTables`; shallow hand-written restore receipts do not satisfy the
  recurring audit. Receipts with `completedAt` more than
  `AUDIT_RESTORE_DRILL_MAX_FUTURE_SKEW_SECONDS=300` seconds in the future are
  rejected so clock skew cannot make a stale or hand-written drill look fresh.
- performance evidence check: defaults to required when the effective `APP_ENV`
  is `production`, and skipped otherwise. Set
  `AUDIT_REQUIRE_PERFORMANCE_GATE=false` only during first bootstrap or a
  controlled diagnostic where performance evidence is not yet installed. When
  enabled, the audit verifies both `/var/lib/imserver/performance/production-gate.json`
  and `/var/lib/imserver/performance/current-evidence`, including checksums,
  validation inventory, profile/prereq audit artifacts, and product-plan
  artifacts when required.
- topology smoke receipt check: defaults to required whenever the operational
  audit's performance gate is required. It verifies
  `/var/lib/imserver/production-smoke/latest-production-smoke.json` with
  `verify_production_smoke.py --require-pass`, requires referenced artifacts to
  exist by default, and fails when the receipt is older than
  `AUDIT_TOPOLOGY_SMOKE_MAX_AGE_SECONDS=86400` or has a future timestamp beyond
  `AUDIT_TOPOLOGY_SMOKE_MAX_FUTURE_SKEW_SECONDS=300`. Override
  `AUDIT_TOPOLOGY_SMOKE_RECEIPT_JSON` only when the installed topology smoke
  receipt lives elsewhere, and set `AUDIT_REQUIRE_TOPOLOGY_SMOKE=false` only
  for a controlled first-bootstrap window where the production topology smoke
  has not run yet.
- scheduled audits set `AUDIT_VERIFY_LATEST_BACKUP=false` by default to avoid
  repeatedly checksumming large backup artifacts; the backup timer still verifies
  each backup immediately after it is created
- latest backup freshness: defaults to required with
  `AUDIT_LATEST_BACKUP_MAX_AGE_SECONDS=172800` (`48h`). This keeps recurring
  audits cheap while still failing when the backup timer has not produced a fresh
  verified artifact. Manifests with `createdAt` more than
  `AUDIT_LATEST_BACKUP_MAX_FUTURE_SKEW_SECONDS=300` seconds in the future are
  rejected. Set `AUDIT_REQUIRE_LATEST_BACKUP_FRESHNESS=false` only when another
  backup monitor owns freshness alerts.
- Offsite backup freshness: disabled by default until an offsite destination is
  configured. After enabling `OFFSITE_BACKUP_DESTINATION` on the backup timer,
  set `AUDIT_REQUIRE_OFFSITE_BACKUP_FRESHNESS=true` to require
  `/var/lib/imserver/offsite-backup/latest.json` to be a recent PASS receipt.
  The default threshold is `AUDIT_OFFSITE_BACKUP_MAX_AGE_SECONDS=172800`
  (`48h`), matching the daily backup freshness window. The receipt must include
  `backupManifestSha256`, `postSyncVerify=true`, and
  `postSyncVerifyMode=rsync-dry-run-checksum-delete`, so an offsite copy that was
  not verified after sync cannot satisfy recurring audits. Receipts with
  `completedAt` more than
  `AUDIT_OFFSITE_BACKUP_MAX_FUTURE_SKEW_SECONDS=300` seconds in the future are
  rejected.
- Kafka lag check: defaults to required whenever the operational audit's
  performance gate is required. It runs `74_check_kafka_lag.sh` for
  `summary-projection-consumer` and `domain-delivery-consumer`, failing when
  total lag exceeds `AUDIT_KAFKA_LAG_MAX_TOTAL=10000`, any partition exceeds
  `AUDIT_KAFKA_LAG_MAX_PARTITION=5000`, or required consumer groups have no lag
  rows. Override `AUDIT_KAFKA_LAG_GROUPS` only when the deployed consumer group
  topology intentionally changes.
- Nginx config check: defaults to required. It runs
  `62_verify_nginx_config.sh` against the installed HTTP, locations, and
  optional HTTPS configs, failing if security headers, rate/connection
  guardrails, rendered includes, or loopback-only `/internal/metrics` drift.
  Set `AUDIT_NGINX_REQUIRE_SSL=true` when TLS must terminate on this node.
  Disable `AUDIT_REQUIRE_NGINX_CONFIG=false` only during a controlled Nginx
  migration window.
- Time synchronization check: defaults to required with
  `AUDIT_REQUIRE_TIME_SYNC=true`. The audit fails unless
  `timedatectl show -p NTPSynchronized --value` reports `yes` and one supported
  time sync unit (`systemd-timesyncd`, `chrony`, `chronyd`, `ntp`, or `ntpsec`)
  is both enabled and active. Disable it only during a controlled bootstrap or
  rescue window where host time is verified by another mechanism.
- SSH access and release manifest checks: default to required. The timer writes
  `AUDIT_REQUIRE_SSH_ACCESS=true` and `AUDIT_REQUIRE_RELEASE_MANIFEST=true` so
  recurring audits fail when SSH is not reachable on the configured management
  port or when the active release metadata/checksums drift.

Override with `AUDIT_CALENDAR`, `AUDIT_RANDOMIZED_DELAY_SEC`,
`AUDIT_LOG_FILE`, and the same `AUDIT_REQUIRE_*` variables used by
`77_operational_audit.sh`. If `AUDIT_REQUIRE_PERFORMANCE_GATE` is left unset,
the timer installer resolves it from `APP_ENV` in `/etc/imserver/common.env`
and writes the effective value into the systemd unit. When that effective
performance gate is required, the timer also writes
`AUDIT_REQUIRE_ALERT_WEBHOOK=true` into the unit even if the raw
`AUDIT_REQUIRE_ALERT_WEBHOOK` override was false or unset, so recurring audits
keep the same alerting standard as the readiness/deploy gate. The all-in-one
deploy script installs this timer and then runs a final audit with
`AUDIT_REQUIRE_AUDIT_TIMER=true`.

To force recurring audits to fail when performance evidence is missing, stale,
or no longer matches the selected production profile regardless of `APP_ENV`:

```bash
sudo AUDIT_REQUIRE_PERFORMANCE_GATE=true \
  AUDIT_REQUIRE_ALERT_WEBHOOK=true \
  AUDIT_PERFORMANCE_GATE_PROFILE=normal-product-baseline \
  AUDIT_PERFORMANCE_GATE_MAX_AGE_SECONDS=604800 \
  AUDIT_PERFORMANCE_GATE_REQUIRE_CURRENT_GIT=true \
  AUDIT_PERFORMANCE_GATE_EXPECT_BASE_URL=https://<your-domain> \
  AUDIT_PERFORMANCE_GATE_EXPECT_TCP_HOST=<your-domain> \
  AUDIT_PERFORMANCE_GATE_EXPECT_TCP_PORT=9000 \
  AUDIT_PERFORMANCE_EVIDENCE_CURRENT_LINK=/var/lib/imserver/performance/current-evidence \
  AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PROFILE_ARTIFACTS=true \
  AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_PLAN_ARTIFACTS=true \
  AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS=true \
  AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS=true \
  AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_NO_LARGE_GROUP=true \
  AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_CURRENT_READINESS_ARTIFACTS=true \
  AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_VALIDATION_INVENTORY=true \
  AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCTION_ACCEPTANCE=true \
  AUDIT_REQUIRE_TOPOLOGY_SMOKE=true \
  AUDIT_TOPOLOGY_SMOKE_RECEIPT_JSON=/var/lib/imserver/production-smoke/latest-production-smoke.json \
  AUDIT_TOPOLOGY_SMOKE_MAX_AGE_SECONDS=86400 \
  AUDIT_TOPOLOGY_SMOKE_MAX_FUTURE_SKEW_SECONDS=300 \
  AUDIT_TOPOLOGY_SMOKE_REQUIRE_ARTIFACTS=true \
  bash deploy/ubuntu/78_install_operational_audit_timer.sh
```

The timer uses `/var/lib/imserver/performance/production-gate.json` by default.
Override `AUDIT_PERFORMANCE_GATE_JSON` when the evidence is installed elsewhere.
Override `AUDIT_PERFORMANCE_EVIDENCE_CURRENT_LINK` when the retained evidence
directory is installed elsewhere. If the target fields are not passed directly,
the timer installer resolves public `BASE_URL` from `PUBLIC_BASE_URL` or
`IM_PUBLIC_BASE_URL`, resolves TCP host from `AUDIT_PERFORMANCE_GATE_EXPECT_TCP_HOST`,
`TCP_HOST`, `IM_PUBLIC_HOST`, or the hostname parsed from the public base URL,
and resolves TCP port from `TCP_PORT` or `IM_TCP_PORT`, with TCP port falling
back to `9000`. It writes the effective `PUBLIC_BASE_URL` and expected target
fields into the systemd unit. When the performance gate is required, the audit
fails closed if the public base URL or expected target is missing, if the public
base URL is not `https://`, or if the public HTTP/TCP target is a raw IP,
localhost, single-label host, `.local`, `.test`, `.invalid`, or `example.*`
placeholder domain. A loopback-only, HTTP-only, IP-bound, or targetless
recurring audit is not valid production evidence.
The same public base URL is also passed into the HTTP entrypoint verifier with
`VERIFY_REQUIRE_PUBLIC=true`, so recurring audits fail on cloud-edge `403`,
security-group, WAF, DNS, or public routing failures even when local loopback
health checks still pass.
When the performance gate is required,
`AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PROFILE_ARTIFACTS=true` is forced even if an
override sets it to `false`.
When the performance gate is required, operational audit also defaults
`AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_PLAN_ARTIFACTS=true`; recurring
audits therefore require broader product-plan evidence in addition to the
selected production-profile SLO gate. The verifier summary must also expose a
non-zero `productPlanScenarioCount` with
`productPlanLargeGroupIncluded=false`,
`productPlanRequiredDomainsCovered=true`, and a non-zero
`productPlanDomainCount`, so entrypoint-only evidence, large-group-only runs, or
partial product-domain runs cannot be mistaken for ordinary product-surface
coverage.
When the performance gate is required, an explicit `false` is ignored; a
controlled diagnostic or first-bootstrap window must disable
`AUDIT_REQUIRE_PERFORMANCE_GATE` instead.
When the performance gate is required, operational audit also defaults
`AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS=true`; recurring
audits therefore require the product campaign receipt, including the non-large
group release stages and the isolated large-group stage, to be an executed
`PASS`. When the performance gate is required, an explicit `false` is ignored;
a controlled diagnostic or first-bootstrap window must disable
`AUDIT_REQUIRE_PERFORMANCE_GATE` instead.
When the performance gate is required, operational audit also defaults
`AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS=true` and
`AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_NO_LARGE_GROUP=true`;
recurring audits therefore require a PASS product scenario suite receipt in the
current production evidence, with non-large-group coverage for ordinary
production claims. When the performance gate is required, an explicit artifact
`false` is ignored; a controlled diagnostic or first-bootstrap window must
disable `AUDIT_REQUIRE_PERFORMANCE_GATE` instead.
When the performance gate is required, operational audit also defaults
`AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_CURRENT_READINESS_ARTIFACTS=true`;
recurring audits therefore require the current production readiness receipt to
show smoke, baseline, and full-acceptance runs all requested and passing. This
prevents a large-group-only or campaign-only package from being treated as
current production evidence. When the performance gate is required, an explicit
`false` is ignored; a controlled diagnostic or first-bootstrap window must
disable `AUDIT_REQUIRE_PERFORMANCE_GATE` instead.
When the performance gate is required, operational audit also treats
`AUDIT_REQUIRE_ALERT_WEBHOOK=true` as effective even if the raw override is
unset or `false`; configure `/etc/imserver/operational-alert.env` before
claiming production readiness, or disable `AUDIT_REQUIRE_PERFORMANCE_GATE` for a
first-bootstrap diagnostic run.
Recurring audits also default
`AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_VALIDATION_INVENTORY=true`; keep it enabled
in production so installed evidence must include and verify the validation
inventory produced with the load-test scripts.
When the performance gate is required, operational audit also defaults
`AUDIT_PERFORMANCE_EVIDENCE_REQUIRE_PRODUCTION_ACCEPTANCE=true`; recurring
audits therefore require the final production acceptance receipt and its matching
evidence tarball to remain available. The verifier reads
`production-acceptance.json` and `production-acceptance-package.tar.gz` from the
installed current-evidence release. Do not point the timer at temporary external
acceptance files for production; reinstall the accepted evidence package if
those durable sidecars are missing.
This requirement is separate from the profile evidence generated through
`run_production_profile.sh`.
Override `AUDIT_PERFORMANCE_PROFILE_CATALOG` only when the operational audit
service cannot read the repository copy of
`IMServer/LoadTests/perf_production_profiles.json`.
Set `AUDIT_PERFORMANCE_GATE_REQUIRE_CURRENT_GIT=true` to make scheduled audits
reject performance evidence generated from a different commit than the deployed
repository checkout.
Set `AUDIT_PERFORMANCE_GATE_REQUIRE_CLEAN_GIT=true` to make scheduled audits
reject evidence generated from a dirty worktree.
Use `AUDIT_PERFORMANCE_GATE_MAX_AGE_SECONDS=0` only for controlled diagnostics
where stale evidence should not fail the audit.

Optional failure alerting is supported through a webhook. Scheduled operational
audit, backup, and restore-drill services use `OnFailure` units that call
`79_send_operational_alert.sh` and post the failing service name, host,
timestamp, and the tail of the relevant log file.

Configure it during timer install:

```bash
sudo AUDIT_ALERT_WEBHOOK_URL='https://alerts.yourdomain.com/imserver' \
  AUDIT_ALERT_WEBHOOK_HEADER='Authorization: Bearer replace-with-token' \
  bash deploy/ubuntu/78_install_operational_audit_timer.sh
```

The installer writes alert settings to
`/etc/imserver/operational-alert.env` with mode `0600`. If no webhook URL is
configured, alert services exit successfully with
`operational-alert result=skipped`; failures are still visible in systemd
journal and the relevant log under `/var/log/imserver/`. Rerunning the timer
installer without `AUDIT_ALERT_WEBHOOK_URL` or `AUDIT_ALERT_WEBHOOK_HEADER`
preserves the existing webhook destination and header, but it still rewrites the
alert safety policy, log file, and timeout values so stale insecure bootstrap
settings cannot drift into scheduled production alerts. Alert webhooks must use
`https://` by default because the payload includes the tail of operational logs.
Set `AUDIT_ALERT_ALLOW_INSECURE_HTTP=true` only for a controlled local/bootstrap
diagnostic where that log tail cannot leave a trusted network. The alert sender
also redacts common secret, token, password, key, and `Authorization: Bearer`
patterns from `logTail` by default before posting the JSON payload. Keep
`AUDIT_ALERT_REDACT_LOG_TAIL=true` for production; set it to `false` only for a
short local diagnostic where the webhook target and logs are both trusted. Run
the local sender self-test after changing alert payload, URL policy, redaction,
or curl behavior:

```bash
AUDIT_ALERT_SELF_TEST=true \
  bash deploy/ubuntu/79_send_operational_alert.sh
```

For production cutover, alerting is part of the hard readiness requirement when
`READINESS_REQUIRE_PERFORMANCE_GATE=true`. Configure the webhook before running
readiness; setting `READINESS_REQUIRE_ALERT_WEBHOOK=true` explicitly is optional
because the performance gate forces it on:

```bash
sudo READINESS_REQUIRE_ALERT_WEBHOOK=true \
  PUBLIC_BASE_URL=https://chat.yourdomain.com \
  bash deploy/ubuntu/95_production_readiness_gate.sh
```

This maps to `AUDIT_REQUIRE_ALERT_WEBHOOK=true` inside operational audit, which
requires `AUDIT_ALERT_WEBHOOK_URL` from the environment or
`/etc/imserver/operational-alert.env` and rejects placeholder or insecure
non-HTTPS values unless `AUDIT_ALERT_ALLOW_INSECURE_HTTP=true` is set for a
temporary diagnostic exception. That exception only allows the `http://` scheme;
it does not allow placeholder, IP, localhost, single-label, `.test`, or
`.invalid` webhook hosts. The recurring operational audit service and the alert
sender both read the same insecure-HTTP exception policy from the rendered systemd
environment and `/etc/imserver/operational-alert.env`, so the audit does not pass
a webhook configuration that the alert sender would later reject. When alerting
is required, readiness also passes `AUDIT_REQUIRE_ALERT_LOG_REDACTION=true`, and
operational audit requires `AUDIT_ALERT_REDACT_LOG_TAIL=true`; this keeps failure
notifications useful without allowing operational log tails to leak tokens,
passwords, or bearer headers into the external webhook.

Outside production, Nginx defaults to `8080` for bootstrap convenience. In
production it defaults to `80`; you can still pass the port explicitly during
Nginx install and verification:

```bash
sudo IM_PUBLIC_HTTP_PORT=80 bash deploy/ubuntu/60_install_nginx.sh
sudo HTTP_PORT=80 PUBLIC_BASE_URL=https://chat.yourdomain.com bash deploy/ubuntu/65_verify_entrypoint.sh
```

For production HTTPS, first point a real DNS name at the server and open
`80/tcp` plus `443/tcp` in the cloud security group. Then install the HTTP
entrypoint on port `80`, request a Let's Encrypt certificate through Certbot,
and add a `443` Nginx server using the same IMServer routes:

```bash
sudo NGINX_TLS_DOMAIN=chat.yourdomain.com \
  NGINX_TLS_EMAIL=ops@example.com \
  bash deploy/ubuntu/61_install_https.sh
```

`61_install_https.sh` uses the webroot challenge under
`/var/www/imserver-acme`, writes `/etc/nginx/conf.d/imserver_ssl.conf`, installs
a Certbot renewal hook that reloads Nginx, enables `certbot.timer` by default,
and allows `443/tcp` in UFW when UFW is active. Use `CERTBOT_STAGING=true` for a
dry run against Let's Encrypt's staging issuer. Do not run this script against a
bare public IP; ACME HTTP-01 requires a domain name. Keep
`CERTBOT_REQUIRE_RENEWAL_TIMER=true` for production so installation fails if
automatic renewal cannot be enabled.

After HTTPS is configured, use:

```bash
sudo HTTP_PORT=80 \
  PUBLIC_BASE_URL=https://chat.yourdomain.com \
  bash deploy/ubuntu/65_verify_entrypoint.sh
```

To enable HTTPS during the all-in-one deploy, set:

```bash
sudo IM_ENABLE_HTTPS=true \
  NGINX_TLS_DOMAIN=chat.yourdomain.com \
  NGINX_TLS_EMAIL=ops@example.com \
  bash deploy/ubuntu/90_deploy_single_node.sh
```

If the public HTTP port is open but every request returns the same empty `403`,
first verify the operator workstation route before changing application code or
server firewall rules:

```bash
bash deploy/ubuntu/20_verify_operator_network.sh \
  http://<server-public-ip> \
  <server-public-ip>:9000 \
  root@<server-public-ip>
```

This preflight fails when the local route goes through common TUN/proxy
interfaces such as `utun*`, `tun*`, `tap*`, `wg*`, or a `198.18.0.0/15`
reserved proxy gateway. In that state, empty `403` responses and SSH disconnects
are not useful server evidence; disconnect the local TUN/proxy or rerun from a
clean network path first.

After the operator route is clean, run the read-only entrypoint diagnosis before
changing application code. The diagnosis also samples the public SSH, HTTP, and
IM TCP ports. If those sampled ports all return `http_403_intercepted`, the
public IP is being intercepted before traffic reaches the instance; use the
cloud console to fix security policy, WAF, NAT/public-IP routing, or provider
edge rules first. If you are probing from a workstation with
`IMServer/LoadTests/http_entrypoint_probe.sh` and it prints
`diagnosis=local_network_proxy_http_403_intercept`, fix the workstation route or
proxy first. A `utun*` interface or `198.18.0.1` gateway means the local
TUN/proxy can return the empty `403` before traffic ever reaches the cloud
instance, so server-side Nginx or security-group changes are not useful evidence
until the probe is rerun from a clean network path.
For final production readiness, the entrypoint probe also enforces the public
port policy when cloud security group evidence is required: `80/443/9000` must
be reachable, while `3389`, `8080`, datastore ports, Kafka, and internal API
ports must not be reachable from the public Internet. If the operator route is
not clean, this check reports `public_port_policy_blocked_by_local_network`
instead of treating intercepted port results as cloud evidence.

```bash
cd /opt/IMMonorepo
sudo HTTP_PORT=80 \
  PUBLIC_BASE_URL=https://chat.yourdomain.com \
  bash deploy/ubuntu/75_entrypoint_diagnose.sh
```

The deployed Nginx exposes `GET /nginx-health` locally. If public
`/nginx-health` also returns an empty `403`, traffic is not reaching the expected
IMServer Nginx server block. Check the cloud security group, WAF, external
reverse proxy, NAT/public IP mapping, or whether the updated Nginx config has
actually been deployed.

If the diagnosis prints `diagnosis=cloud_edge_http_403_intercept`, do not keep
tuning Nginx, IMServer, Kafka, or performance settings. SSH and IM TCP are not
reaching the instance either, even if `nc -z` reports the ports as open. Repair
access through the cloud console or rescue shell, then rerun
`75_entrypoint_diagnose.sh`, `65_verify_entrypoint.sh`, and
`66_smoke_entrypoint.sh`. The probe JSON marks this as
`blocker.type=entrypoint`, `blocker.severity=P0`, and
`blocker.action=cloud_console_rescue_required`; treat any performance evidence
captured under that blocker as invalid.

Use `65_verify_entrypoint.sh` as the deploy gate and
`75_entrypoint_diagnose.sh` as the investigation tool:

- `65_verify_entrypoint.sh` fails fast when Nginx, gateway, command-api,
  query-api, TCP `9000`, or optional public `/health` is not reachable.
- `75_entrypoint_diagnose.sh` checks selected listeners, public protocol
  banners, local and public HTTP probes, systemd state, recent IMServer/Nginx
  logs, Nginx routing, Docker state, and firewall rules. It does not restart or
  reload services.

For incident handoff, collect a redacted diagnostics bundle instead of copying
raw logs and environment files by hand:

```bash
sudo PUBLIC_BASE_URL=https://<your-domain> \
  bash deploy/ubuntu/76_collect_diagnostics_bundle.sh
```

The bundle is written to `/tmp/imserver-diagnostics-<timestamp>.tar.gz` by
default with mode `0600`. It includes release metadata/checksums, redacted
`/etc/imserver` env files, systemd status, selected journal tails, listener and
firewall snapshots, Nginx route summary, performance evidence verifier output,
redacted performance gate/profile/run artifacts, production profile runbook
JSON/Markdown plus its summary fields, product-plan preview/domain-coverage
summary, product campaign receipt, validation inventory when present,
operational audit output, and entrypoint diagnosis output. The script
redacts common password, token, secret,
JWT signing key material including legacy `JWT_SECRET` and rotated `JWT_SECRETS`,
authorization, Markdown/YAML-style secret fields, database URL, Redis URL, S3
key, Kafka SASL, and alert webhook patterns before writing files. Set
`DIAGNOSTIC_OUTPUT_DIR` to change the archive
directory or `DIAGNOSTIC_KEEP_DIR=true` to keep the unpacked work directory for
local inspection.

The redaction rules have a self-test that is also run by
`IMServer/LoadTests/validate_load_tests.sh`:

```bash
DIAGNOSTIC_REDACTION_SELF_TEST=true \
  bash deploy/ubuntu/76_collect_diagnostics_bundle.sh
```

The performance evidence section has its own non-root self-test. It verifies
that installed gate/profile artifacts are copied into the bundle, verifier
output is captured, and secrets inside performance evidence are redacted:

```bash
DIAGNOSTIC_PERFORMANCE_SELF_TEST=true \
  bash deploy/ubuntu/76_collect_diagnostics_bundle.sh
```

`66_smoke_entrypoint.sh` is the application-level deploy gate. It logs in,
calls `/api/me`, and checks local `/internal/metrics` when the internal secret is
available. If `BASE_URL` is not set, it uses `PUBLIC_BASE_URL` or
`IM_PUBLIC_BASE_URL` before falling back to loopback. The all-in-one deploy and
readiness gate pass their effective public base URL, so production smoke
validates the public route for login and `/api/me`. Metrics stay on
`METRICS_BASE_URL`, which defaults to `http://127.0.0.1:<HTTP_PORT>` because
Nginx intentionally restricts `/internal/metrics` to loopback. Use a dedicated
smoke account in production:

```bash
sudo PUBLIC_BASE_URL=https://chat.yourdomain.com \
  IM_SMOKE_EMAIL=smoke@example.com \
  IM_SMOKE_PASSWORD='replace-with-password' \
  bash deploy/ubuntu/66_smoke_entrypoint.sh
```

Set `IM_RUN_ENTRYPOINT_SMOKE=false` only for a controlled bootstrap where the
smoke account has not been created yet; do not treat that run as production
ready.
When `APP_ENV=production`, the smoke script refuses to use the built-in
`demo@example.com / password1234` fallback. Pass `IM_SMOKE_EMAIL` and
`IM_SMOKE_PASSWORD`, or an `ACCOUNT_FILE` containing a dedicated smoke account.

The generated systemd units are intended to fail closed:

- gateway, command-api, and query-api run a post-start `/health` check and will
  restart if the role is active but not healthy.
- internal role-to-role traffic uses loopback ports directly:
  command-api `8081`, query-api `8082`, gateway HTTP `18080`.
- gateway TCP port defaults to `9000`, TCP listen backlog defaults to `8192`,
  and `IM_TCP_DROP_REALTIME_WHEN_NOT_WRITABLE=true` protects the gateway from
  retaining unbounded realtime writes for slow clients.
- `LimitNOFILE` defaults to `1048576`; override with
  `IMSERVER_LIMIT_NOFILE=...` before installing units if the host policy uses a
  lower target.
- `TasksMax` defaults to `65535`; override with `IMSERVER_TASKS_MAX=...` only
  after sizing worker/thread needs for the selected machine.
- units enable `CPUAccounting=true` and `MemoryAccounting=true`, so operational
  tooling can inspect cgroup-level usage even before a full metrics stack is in
  place.
- units use systemd sandboxing (`NoNewPrivileges`, `PrivateTmp`,
  `PrivateDevices`, `ProtectSystem=full`, `ProtectHome=true`,
  `ProtectKernelTunables`, `ProtectKernelModules`, `ProtectControlGroups`,
  `RestrictSUIDSGID`, `RestrictRealtime`, `RestrictNamespaces`,
  `RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6`, `LockPersonality`,
  `SystemCallArchitectures=native`, empty `CapabilityBoundingSet`, and empty
  `AmbientCapabilities`) while keeping `/opt/imserver`, `/var/log/imserver`, and
  `/tmp` writable.
  `52_verify_systemd_units.sh` fails if these production fields drift out of the
  generated unit files.
  Run `SYSTEMD_UNITS_RENDER_SELF_TEST=true bash deploy/ubuntu/50_install_systemd_units.sh`
  after changing unit rendering, and
  `SYSTEMD_UNIT_VERIFY_SELF_TEST=true bash deploy/ubuntu/52_verify_systemd_units.sh`
  after changing runtime drift verification.

`30_setup_kafka.sh` renders `kafka.service` with the same production baseline:
`LimitNOFILE` defaults to `262144`, `TasksMax` defaults to `16384`, CPU and
memory accounting are enabled, and the unit is sandboxed while keeping
`${KAFKA_DATA_DIR}`, `${KAFKA_LOG_DIR}`, and `/etc/kafka/kraft` writable.
The same `52_verify_systemd_units.sh` drift verifier checks Kafka's sandbox
fields, so manually loosening the broker unit fails the readiness gate.
When Kafka is not already installed, the script downloads the Apache archive
plus its sibling `.sha512`, verifies the archive digest, and safely extracts only
members under the expected `kafka_<scala>-<version>/` root before syncing into
`${KAFKA_HOME}`. Unsafe archive paths, links, unsupported members, oversized
members, and oversized total payloads are rejected before install.
Override `KAFKA_LIMIT_NOFILE` or `KAFKA_TASKS_MAX` only after validating the
target workload and host limits.

`10_setup_postgres.sh` keeps the single-node database private by default:
`POSTGRES_LISTEN_ADDRESSES=127.0.0.1` and
`POSTGRES_PASSWORD_ENCRYPTION=scram-sha-256`. It validates database and role
identifiers before rendering SQL. Do not change Postgres to a public listener on
this single-node profile; move to a private VPC database endpoint instead.

`20_setup_redis.sh` keeps Redis private by default with `bind 127.0.0.1 ::1`,
`protected-mode yes`, bounded memory, and `allkeys-lru`. The operational audit
checks that Postgres `5432` and Redis `6379` are not listening on non-loopback
addresses, and it verifies Redis `bind` plus `protected-mode`. Keep
`AUDIT_REQUIRE_DATASTORE_LOOPBACK=true` unless Postgres/Redis have moved to
managed private endpoints and this node no longer hosts them.

`15_setup_kernel_tuning.sh` persists the host-level defaults needed for long
connections:

- `fs.file-max` and `fs.nr_open` default to `2097152`.
- service user `nofile` defaults to `1048576`.
- `net.core.somaxconn` and `net.ipv4.tcp_max_syn_backlog` default to `8192`.
- ephemeral ports default to `10000 65000`.
- TCP keepalive defaults to `60s` plus `15s * 4` probes.

Override these with environment variables such as `IM_TCP_SOMAXCONN`,
`IM_TCP_MAX_SYN_BACKLOG`, or `IMSERVER_LIMIT_NOFILE` before running the script.

`25_setup_host_security.sh` installs and verifies the host security baseline:

- UFW defaults to deny incoming and allow outgoing.
- SSH, public HTTP, and IM TCP ports are allowed.
- RDP `3389/tcp` is explicitly denied and any old UFW allow rule for it is
  removed. Ubuntu hosts should not expose Windows Remote Desktop.
- fail2ban is enabled for `sshd`.
- unattended security upgrades are enabled.
- host time synchronization is enabled with `timedatectl set-ntp true` and a
  supported time sync service. `00_install_dependencies.sh` installs
  `systemd-timesyncd`; `25_setup_host_security.sh` starts it when present and
  falls back to `chrony`/`chronyd` when that is the installed provider.
- Swiftly bootstrap is supply-chain checked in `00_install_dependencies.sh`:
  the pinned `SWIFTLY_VERSION` archive must pass Swift.org PGP signature
  verification and safe tar extraction before the installer binary is executed.

Default ports:

- SSH: `22`
- public HTTP: `IM_PUBLIC_HTTP_PORT` or `HTTP_PORT`, default `80` when `APP_ENV=production`, otherwise `8080`
- IM TCP: `IM_TCP_PORT` or `TCP_PORT`, default `9000`

The all-in-one deploy runs host security with
`IM_HOST_SECURITY_PROFILE=production` by default. Production mode requires
`SSH_ALLOW_CIDR` to be a concrete admin CIDR such as `<your-office-ip>/32`; it
fails fast when SSH is left as `any` or `0.0.0.0/0`, and requires UFW,
fail2ban, unattended upgrades, and time synchronization to stay enabled. Use
`IM_HOST_SECURITY_PROFILE=bootstrap` only for short-lived rescue or initial
access windows, then rerun production mode after you confirm your stable admin
IP.

`22_node_access_rescue.sh` is the self-contained emergency variant for cloud
console use when the repo checkout is missing or stale. It installs
`openssh-server`, `nginx`, `curl`, `ufw`, and `netcat-openbsd` if needed, writes
the minimum SSH and Nginx entrypoint configuration directly, repairs UFW rules,
and probes local/public health.

`23_repair_node_access.sh` is the preferred recovery command when the target host
has the current repo checkout. It runs `24_repair_ssh_access.sh` and then
`64_repair_http_entrypoint.sh`, writing one report to
`/var/log/imserver/node-access-repair.log`.

`24_repair_ssh_access.sh` is the idempotent SSH-only recovery step used by the
all-in-one deploy before host security hardening. Use it from the cloud console
or rescue shell when TCP `22` accepts and immediately closes, when `sshd` is
stopped, or after firewall drift:

```bash
sudo SSH_PORT=22 \
  SSH_USER=root \
  SSH_ALLOW_CIDR=0.0.0.0/0 \
  bash deploy/ubuntu/24_repair_ssh_access.sh
```

To inject or repair a public key at the same time:

```bash
sudo SSH_AUTHORIZED_KEY='ssh-ed25519 AAAA... comment' \
  SSH_USER=root \
  bash deploy/ubuntu/24_repair_ssh_access.sh
```

The script installs `openssh-server` if missing, writes
`/etc/ssh/sshd_config.d/99-imserver-access.conf`, validates `sshd -t`, enables
and restarts the SSH service, repairs optional `authorized_keys` permissions,
allows the SSH port through UFW, and verifies the listener. The operational audit
fails if SSH service or the configured SSH listener is not healthy.

Restrict exposed ports with CIDR variables when the cloud security group and
client locations are known:

```bash
sudo IM_HOST_SECURITY_PROFILE=production \
  SSH_ALLOW_CIDR=<your-office-ip>/32 \
  HTTP_ALLOW_CIDR=0.0.0.0/0 \
  TCP_ALLOW_CIDR=0.0.0.0/0 \
  bash deploy/ubuntu/25_setup_host_security.sh
```

The script does not reset existing UFW rules by default. Set `UFW_RESET=true`
only during controlled bootstrap when you explicitly want to clear old firewall
state. Cloud security groups are still required; UFW only protects traffic after
it reaches the host.

Set `ENABLE_UFW=false`, `ENABLE_FAIL2BAN=false`, or
`ENABLE_UNATTENDED_UPGRADES=false` only for a host where another managed control
already provides the same protection. If you intentionally skip those controls,
set `IM_HOST_SECURITY_ALLOW_WEAKENED=true` and run the operational audit with
`AUDIT_REQUIRE_HOST_SECURITY=false`.

The operational audit continuously checks the host firewall posture. With the
defaults it fails when UFW allows SSH from `Anywhere`/`0.0.0.0/0` or when
`3389/tcp` is allowed. Broad public SSH CIDRs are also rejected: a rule such as
`47.0.0.0/8` is treated as public exposure, while a concrete admin source such
as `<your-office-ip>/32` remains valid. Set
`AUDIT_REQUIRE_RESTRICTED_SSH_CIDR=false` or `AUDIT_REQUIRE_RDP_CLOSED=false`
only for a temporary bootstrap window, then restore the defaults.

`26_audit_cloud_security_group.sh` checks the cloud security group posture before
traffic reaches the host. Save the inbound security group rules as JSON and run:

```bash
CLOUD_SECURITY_GROUP_RULES_FILE=/tmp/imserver-security-group.json \
  bash deploy/ubuntu/26_audit_cloud_security_group.sh
```

Print the target long-term policy before editing the cloud console:

```bash
CLOUD_SECURITY_GROUP_PRINT_POLICY=true \
  bash deploy/ubuntu/26_audit_cloud_security_group.sh
```

You can also render a reviewed snapshot template before or after editing the
cloud console. Replace the admin CIDR with your current operator public IP. The
production default requires a single public IPv4 `/32` or IPv6 `/128` for SSH:

```bash
CLOUD_SECURITY_GROUP_TEMPLATE_ADMIN_CIDR=<your-admin-public-ip>/32 \
CLOUD_SECURITY_GROUP_TEMPLATE_OUTPUT=/tmp/imserver-security-group.json \
  bash deploy/ubuntu/28_render_cloud_security_group_snapshot_template.sh
```

The renderer writes only local JSON. It does not call cloud APIs or change the
cloud security group. Apply equivalent rules in the Aliyun console, then audit
the exported or rendered snapshot with `26_audit_cloud_security_group.sh`.

If the local machine has an authenticated Aliyun CLI profile, fetch the live ECS
security group snapshot directly instead of relying on a screenshot or manual
export:

```bash
ALIYUN_SECURITY_GROUP_ID=sg-... \
ALIYUN_REGION_ID=cn-shenzhen \
ALIYUN_SECURITY_GROUP_OUTPUT=/tmp/imserver-security-group.json \
  bash deploy/ubuntu/29_fetch_aliyun_security_group_snapshot.sh
```

The fetcher calls `aliyun ecs DescribeSecurityGroupAttribute`, writes the raw
JSON response, and runs the same production audit as
`26_audit_cloud_security_group.sh`. It does not modify cloud rules. If the
audit fails, fix the Aliyun security group first, then fetch again. After the
snapshot passes, install it on the server or pass it into the all-in-one deploy:

```bash
sudo CLOUD_SECURITY_GROUP_SOURCE_FILE=/tmp/imserver-security-group.json \
  bash deploy/ubuntu/27_install_cloud_security_group_snapshot.sh

sudo IM_DEPLOY_CLOUD_SECURITY_GROUP_SOURCE_FILE=/tmp/imserver-security-group.json \
  bash deploy/ubuntu/90_deploy_single_node.sh
```

To repair the Aliyun security group through the CLI instead of clicking in the
console, generate a dry-run plan first. Replace the admin CIDR with your current
operator public IP. The repair script reads the current security group, plans
the missing `80/443/9000` allow rules, plans the admin-only SSH rule, and plans
revocation of public `22/3389/8080` and other internal ports:

```bash
ALIYUN_SECURITY_GROUP_ID=sg-... \
ALIYUN_REGION_ID=cn-shenzhen \
ALIYUN_SECURITY_GROUP_ADMIN_CIDR=<your-admin-public-ip>/32 \
ALIYUN_SECURITY_GROUP_REPAIR_EVIDENCE_DIR=/var/lib/imserver/cloud-security-group \
  bash deploy/ubuntu/30_repair_aliyun_security_group.sh
```

Apply only after reviewing the generated plan:

```bash
ALIYUN_SECURITY_GROUP_REPAIR_APPLY=true \
ALIYUN_SECURITY_GROUP_ID=sg-... \
ALIYUN_REGION_ID=cn-shenzhen \
ALIYUN_SECURITY_GROUP_ADMIN_CIDR=<your-admin-public-ip>/32 \
ALIYUN_SECURITY_GROUP_REPAIR_EVIDENCE_DIR=/var/lib/imserver/cloud-security-group \
  bash deploy/ubuntu/30_repair_aliyun_security_group.sh
```

The script adds required rules before revoking public admin/denied rules, then
refetches and audits the security group by default. It calls
`AuthorizeSecurityGroup` and `RevokeSecurityGroup` only when
`ALIYUN_SECURITY_GROUP_REPAIR_APPLY=true`. When
`ALIYUN_SECURITY_GROUP_REPAIR_EVIDENCE_DIR` is set, the script writes timestamped
snapshot, plan, and receipt artifacts under that directory. It updates
`snapshots/latest-snapshot.json`, `repairs/latest-repair-plan.json`, and
`repairs/latest-repair-receipt.json` only after the applied repair passes
post-apply verification, so production readiness gates do not trust dry-run or
unverified repair receipts.

For Aliyun ECS security groups, the production target is:

- allow `tcp/80`, `tcp/443`, and `tcp/9000` from `0.0.0.0/0`.
- edit `tcp/22` so the source is your admin public IP, normally `/32`, not
  `0.0.0.0/0` or a broad office/ISP range.
- delete public `tcp/3389`; it is Windows RDP and is not used by Ubuntu.
- delete public `tcp/8080` after Nginx/HTTPS is installed. `8080` is only a
  bootstrap diagnostic port.
- never expose PostgreSQL `5432`, Redis `6379`, Kafka `9092`,
  command-api `8081`, query-api `8082`, or gateway HTTP `18080`.

For recurring production audits, keep the latest reviewed inbound rules on the
server. Use the installer so the JSON is validated before it is trusted by the
production gate:

```bash
sudo CLOUD_SECURITY_GROUP_SOURCE_FILE=/tmp/imserver-security-group.json \
  bash deploy/ubuntu/27_install_cloud_security_group_snapshot.sh
```

When the production performance gate is required, `77_operational_audit.sh` also
requires this cloud security group audit by default. Disable it with
`AUDIT_REQUIRE_CLOUD_SECURITY_GROUP=false` only during first bootstrap or a
controlled diagnostic window where the cloud rule snapshot has not been copied
yet. In production, the rules snapshot is also treated as stale after 86400
seconds by default; set `CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS=0` or
`AUDIT_CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS=0` only for a documented
private/offline audit exception. The snapshot file must not be writable by group
or other users, and production audits require it to be owned by root by default;
keep it at `0644` or stricter. `27_install_cloud_security_group_snapshot.sh`
installs the snapshot as `root:root`, backs up any previous snapshot, and reruns
the production cloud security group audit on the installed file.
Set `CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER=false` or
`AUDIT_CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER=false` only for local
bootstrap diagnostics where the snapshot cannot yet be installed as root.

The production profile treats public `80/tcp`, `443/tcp`, and `9000/tcp` as
required client ports, requires `22/tcp` to be restricted to a concrete admin
host CIDR, and fails if public `3389/tcp`, `5432/tcp`, `6379/tcp`, `9092/tcp`,
`8081/tcp`, `8082/tcp`, `18080/tcp`, or `8080/tcp` are allowed. If a private
deployment intentionally does not expose all client ports, set
`CLOUD_SECURITY_GROUP_REQUIRE_PUBLIC_CLIENT_PORTS=false` for that audit and
record the exception. Broad public CIDRs such as `0.0.0.0/1` are treated as
public exposure; by default globally routable IPv4 `/8` or wider and IPv6
`/16` or wider are blocked for admin/denied ports. Private ranges such as
`10.0.0.0/8` are not treated as public exposure. In addition, admin SSH sources
must be specific by default: globally routable IPv4 must be `/32`, and globally
routable IPv6 must be `/128`. If a real enterprise fixed egress range must be
used, set `CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV4_MIN_PREFIX` or
`CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV6_MIN_PREFIX` deliberately and record the
exception in the deployment evidence. Keep `8080/tcp` public only for a short
bootstrap or diagnostic window:

```bash
CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080=true \
CLOUD_SECURITY_GROUP_REQUIRE_PUBLIC_CLIENT_PORTS=false \
CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS=0 \
CLOUD_SECURITY_GROUP_RULES_FILE=/tmp/imserver-security-group.json \
  bash deploy/ubuntu/26_audit_cloud_security_group.sh
```

Remove that exception after HTTPS/Nginx is in place. UFW and cloud security
groups are both required in production: cloud rules reject unwanted public
traffic first, and UFW remains the host-level guardrail if cloud rules drift.
Refresh `/etc/imserver/cloud-security-group.json` after every cloud-console
security group change, and at least once per day while the production gate is
enforced.

The same audit also runs `55_verify_production_env.sh` by default through
`AUDIT_REQUIRE_PRODUCTION_ENV=true`. This catches configuration drift after
deployment: weak secrets, missing HTTPS `PUBLIC_BASE_URL`, development seed
accounts, public internal service URLs, or unsafe production transport flags
make the recurring audit fail instead of waiting for the next deploy.
When the performance gate is required, the audit also checks Kafka consumer lag
through `74_check_kafka_lag.sh`. This catches a live message-delivery backlog
even when the historical performance evidence package is still valid. Set
`AUDIT_REQUIRE_KAFKA_LAG=false` only during first bootstrap or a controlled
diagnostic where consumer groups have not committed offsets yet.

With `AUDIT_REQUIRE_HTTPS_CERTIFICATE=true`, the audit also checks the
configured public HTTPS certificate before each recurring run can pass. This
catches expired or soon-to-expire certificates as operational failures. Keep the
default threshold of `AUDIT_HTTPS_CERT_MIN_VALID_DAYS=14` unless you have a
separate certificate-expiry monitor with a stricter alert window.
The audit also checks `certbot.timer` by default through
`AUDIT_REQUIRE_CERTBOT_RENEWAL_TIMER=true`, matching the HTTPS installer. Disable
that only if TLS terminates at a managed load balancer or CDN and this node no
longer owns renewal.
The audit also checks Nginx config drift through
`AUDIT_REQUIRE_NGINX_CONFIG=true`. This keeps the public reverse proxy aligned
with the hardened template after manual edits, package upgrades, or emergency
repairs. Set `AUDIT_NGINX_REQUIRE_SSL=true` once HTTPS is required on the node.

`35_setup_logrotate.sh` installs log retention:

- `/var/log/imserver/*.log` and `/var/log/nginx/imserver_*.log` rotate daily and
  keep `14` rotations by default.
- journald is capped with `SystemMaxUse=1G` and `MaxRetentionSec=14day`.

Override with `IMSERVER_LOGROTATE_RETENTION_DAYS`,
`NGINX_LOGROTATE_RETENTION_DAYS`, `JOURNAL_SYSTEM_MAX_USE`, and
`JOURNAL_MAX_RETENTION_SEC`.

Backups are installed as a daily systemd timer by `85_install_backup_timer.sh`.
The backup job runs `80_backup_single_node.sh` and then verifies the artifact
with `81_verify_backup.sh`. If creation or verification fails, systemd triggers
`imserver-backup-alert@.service`, which uses the same optional webhook env file
as operational audit alerts and includes the tail of the backup log. The
operational audit checks that this alert unit has both the shared
`EnvironmentFile` and a backup-specific `AUDIT_ALERT_LOG_FILE`, so a backup
timer cannot silently point failure alerts at the wrong log.
The operational audit also checks that `${BACKUP_ROOT}/latest` is fresh by
default. The freshness threshold is `AUDIT_LATEST_BACKUP_MAX_AGE_SECONDS=172800`
seconds, giving the daily backup timer one missed run of slack before the node
is considered unhealthy.

Default behavior:

- backup root: `/var/backups/imserver`
- schedule: daily at `03:15` with up to `900s` randomized delay
- retention: `14` days
- log file: `/var/log/imserver/backup.log`
- contents: PostgreSQL custom dump, `/etc/imserver` config archive, runtime
  state, manifest, sha256 checksums, and local media archive when
  `MEDIA_STORAGE_PROVIDER=local`
- manifest evidence: `manifest.json` records each backup artifact's relative
  file name, `sha256`, and `sizeBytes`; `81_verify_backup.sh` compares those
  records against the files in addition to checking `SHA256SUMS`
- S3-compatible media storage is not copied by this host backup; use bucket
  versioning/lifecycle/object-store backup for media in production
- optional offsite sync: set `OFFSITE_BACKUP_DESTINATION` to an rsync
  destination such as `backup.example.com:/srv/imserver-backups` or a mounted
  absolute path. After the local backup verifies, the timer runs
  `86_sync_backup_offsite.sh`, uploads the verified backup under its `backupID`,
  and writes `/var/lib/imserver/offsite-backup/latest.json`. Offsite and
  restore-drill receipts include `backupManifestSha256`, tying the copied or
  restored backup back to the exact local manifest.

Run and verify a backup manually:

```bash
sudo -E make create-backup-single-node
sudo -E make verify-backup

# Equivalent script-level commands:
sudo bash deploy/ubuntu/80_backup_single_node.sh
sudo bash deploy/ubuntu/81_verify_backup.sh
```

`80_backup_single_node.sh` refuses unsafe backup targets. `BACKUP_ID` may only
contain letters, numbers, `.`, `_`, and `-`; `BACKUP_DIR` must be an absolute
directory under `BACKUP_ROOT`, must not be a symlink, and must not already contain
files. This prevents a root-run backup job from writing outside the configured
backup tree or merging a new backup into an old artifact. `${BACKUP_ROOT}/latest`
must be absent or a symlink; a real directory or file named `latest` is treated
as drift and the backup job refuses to continue. When a backup completes, the
`latest` pointer is switched through a temporary symlink and atomic replace so
readiness checks and restore drills do not observe a half-updated pointer. Run
the local target safety self-test after changing backup creation logic:

```bash
BACKUP_CREATE_SELF_TEST=true \
  bash deploy/ubuntu/80_backup_single_node.sh
```

`81_verify_backup.sh` verifies checksums, the PostgreSQL custom dump, manifest
schema, manifest artifact `sha256`/`sizeBytes` records, and backup archives.
Before invoking `sha256sum -c`, it validates `SHA256SUMS` entries so a retained
or copied backup cannot make the verifier read absolute paths, `..` traversal,
subdirectories, duplicate entries, missing files, or malformed digests.
Archive members must be relative regular files or directories; absolute paths,
`..` traversal, symlinks, hardlinks, and unsupported tar member types are
rejected so a retained backup cannot later become an unsafe restore input. The
verifier also bounds `manifest.json` to `BACKUP_VERIFY_MANIFEST_MAX_BYTES`
(`4 MiB` by default) and bounds the `imserver-etc.tgz` configuration archive
with `BACKUP_VERIFY_ETC_ARCHIVE_MEMBER_MAX_BYTES` (`64 MiB` by default) and
`BACKUP_VERIFY_ETC_ARCHIVE_TOTAL_MAX_BYTES` (`256 MiB` by default). Media
archives are still path/type validated without a default size cap, because local
media backup size is deployment-specific. Run its local safety self-test after
changing backup validation:

```bash
BACKUP_VERIFY_SELF_TEST=true \
  bash deploy/ubuntu/81_verify_backup.sh
```

Configure offsite backup sync after SSH keys or a mounted backup volume are in
place:

```bash
sudo -E OFFSITE_BACKUP_DESTINATION=backup.example.com:/srv/imserver-backups \
  make install-backup-timer

# Equivalent script-level command:
sudo OFFSITE_BACKUP_DESTINATION=backup.example.com:/srv/imserver-backups \
  bash deploy/ubuntu/85_install_backup_timer.sh
```

Run a one-off sync for the current latest backup:

```bash
sudo -E OFFSITE_BACKUP_DESTINATION=backup.example.com:/srv/imserver-backups \
  make sync-offsite-backup

# Equivalent script-level command:
sudo OFFSITE_BACKUP_DESTINATION=backup.example.com:/srv/imserver-backups \
  bash deploy/ubuntu/86_sync_backup_offsite.sh
```

`86_sync_backup_offsite.sh` verifies the backup first by default, refuses unsafe
relative/root destinations, syncs the backup under its manifest `backupID`, and
writes an atomic PASS receipt containing the manifest SHA256. It also runs a
post-sync `rsync --dry-run --checksum --delete` comparison by default, so the
receipt is only written after the remote `backupID` directory matches the local
backup artifacts. Set `OFFSITE_BACKUP_POST_VERIFY=false` only for a controlled
bootstrap diagnostic where the offsite target cannot support a dry-run checksum
comparison yet. Enable `AUDIT_REQUIRE_OFFSITE_BACKUP_FRESHNESS=true` only after
the first successful offsite sync, so recurring operational audits fail when no
recent offsite copy has succeeded. Run its self-test locally after changing sync
behavior:

```bash
OFFSITE_BACKUP_SYNC_SELF_TEST=true \
  bash deploy/ubuntu/86_sync_backup_offsite.sh
```

Run a safe restore drill after a backup. This restores `postgres.dump` into a
temporary database whose name must contain `restore_drill`, verifies that the
schema is queryable, verifies the configured critical IM tables exist, and drops
the temporary database by default. The restore uses
`pg_restore --exit-on-error --single-transaction`, so any object restore failure
aborts the drill instead of leaving a partially restored database that looks
healthy from a shallow schema probe:

```bash
sudo -E BACKUP_DIR=/var/backups/imserver/latest \
  make run-restore-drill

# Equivalent script-level command:
sudo BACKUP_DIR=/var/backups/imserver/latest \
  bash deploy/ubuntu/82_restore_drill_single_node.sh
```

Keep the restored drill database for manual inspection only when needed:

```bash
sudo RESTORE_DRILL_KEEP_DB=true \
  RESTORE_DRILL_DB=imserver_restore_drill_manual \
  BACKUP_DIR=/var/backups/imserver/latest \
  bash deploy/ubuntu/82_restore_drill_single_node.sh
```

The default critical-table probe checks `users`, `auth_sessions`,
`im_conversations`, `im_conversation_members`, `im_messages`,
`conversation_domain_events`, `owner_domain_event_deliveries`,
`im_conversation_user_summaries`, and `conversation_read_model_tokens`. Override
`RESTORE_DRILL_REQUIRED_TABLES` with a comma or whitespace separated list if a
future topology moves a read model to a different database and the primary
restore drill should assert a different table set.

The restore drill refuses to use the configured production database name and
refuses database names without the `restore_drill` marker. It does not restore
local media; media archives are already validated by `81_verify_backup.sh`.
On success it writes an atomic PASS receipt to
`/var/lib/imserver/restore-drill/latest.json` by default. The receipt includes
`completedAt`, backup id, backup directory, target drill database, and public
table count, plus `requiredTables` for the critical-table probe. Enable
`AUDIT_REQUIRE_RESTORE_DRILL_FRESHNESS=true` after the first successful drill to
make recurring operational audits fail when no recent restore proof exists.

Install the monthly restore drill timer:

```bash
sudo -E make install-restore-drill-timer

# Equivalent script-level command:
sudo bash deploy/ubuntu/83_install_restore_drill_timer.sh
systemctl list-timers imserver-restore-drill.timer
```

Default behavior:

- schedule: monthly on day `01` at `04:30` with up to `1800s` randomized delay
- input: `/var/backups/imserver/latest`
- log file: `/var/log/imserver/restore-drill.log`
- receipt: `/var/lib/imserver/restore-drill/latest.json`
- cleanup: drop the temporary restore-drill database after the run
- alerting: failures trigger `imserver-restore-drill-alert@.service`, which
  uses the same optional webhook env file as operational audit alerts and sets
  `AUDIT_ALERT_LOG_FILE` to the restore-drill log; operational audit checks both
  fields.

Override with `RESTORE_DRILL_CALENDAR`,
`RESTORE_DRILL_RANDOMIZED_DELAY_SEC`, `RESTORE_DRILL_LOG_FILE`, and
`RESTORE_DRILL_KEEP_DB`. The all-in-one deploy script installs this timer and
requires it in the final operational audit.

Validate the restore-drill safety guards and rendered timer units without root
or systemd side effects:

```bash
RESTORE_DRILL_SAFETY_SELF_TEST=true \
  bash deploy/ubuntu/82_restore_drill_single_node.sh

RESTORE_DRILL_TIMER_RENDER_SELF_TEST=true \
  bash deploy/ubuntu/83_install_restore_drill_timer.sh
```

Install or update the timer:

```bash
sudo -E make install-backup-timer

# Equivalent script-level command:
sudo bash deploy/ubuntu/85_install_backup_timer.sh
systemctl list-timers imserver-backup.timer
```

Override with `BACKUP_ROOT`, `BACKUP_RETENTION_DAYS`, `BACKUP_CALENDAR`,
`BACKUP_RANDOMIZED_DELAY_SEC`, `BACKUP_LOG_FILE`, and `AUDIT_ALERT_ENV_FILE`.
Validate the rendered backup service/timer
without root or systemd side effects:

```bash
BACKUP_TIMER_RENDER_SELF_TEST=true \
  bash deploy/ubuntu/85_install_backup_timer.sh
```

Full production restore is intentionally not
automated by this script set; first verify the backup, run the restore drill,
provision or isolate the replacement database, then use `pg_restore` under an
operator-controlled maintenance window.

`54_migrate_jwt_rotation.sh` runs before production env validation during the
all-in-one deploy. It handles the one safe upgrade case for older nodes:
`/etc/imserver/common.env` contains `JWT_SECRET` but does not yet contain
`JWT_SECRETS` or `JWT_ACTIVE_KID`. The script backs up the env file, removes the
legacy key, and writes:

```env
JWT_SECRETS=active:<old-jwt-secret>
JWT_ACTIVE_KID=active
```

If both `JWT_SECRET` and `JWT_SECRETS` are present, the script fails instead of
guessing operator intent. Resolve that manually, then rerun:

```bash
sudo bash deploy/ubuntu/54_migrate_jwt_rotation.sh
sudo bash deploy/ubuntu/55_verify_production_env.sh
```

`55_verify_production_env.sh` is run by the all-in-one deploy before services
start. It skips development mode, but when `APP_ENV=production` it requires
production-safe dependencies and transport settings:

- Kafka driver with explicit topics plus `IM_KAFKA_CLIENT_ID`, `acks=all`,
  `auto_create_topics=false`, `sasl_tls`, SCRAM-SHA-512 credentials, and
  `IM_KAFKA_TLS_CA_FILE`.
- S3-compatible media storage instead of local disk, with explicit endpoint,
  bucket, access key, secret key, region, and `MEDIA_STORAGE_S3_FORCE_PATH_STYLE`.
  The endpoint must use `https://` with a real non-placeholder DNS host;
  production validation rejects `IM_PRODUCTION_ALLOW_INSECURE_MEDIA_STORAGE_ENDPOINT=true`.
- `PUBLIC_BASE_URL` or `IM_PUBLIC_BASE_URL` with a real production DNS name.
  It must use default HTTPS (`https://your-domain`, or explicit `:443`) for
  long-term production. Raw IPs, localhost, single-label hosts, placeholder
  domains, non-HTTPS URLs, and non-default public HTTPS ports are rejected by
  the production env check and final deploy audit. Do not set
  `IM_PRODUCTION_ALLOW_INSECURE_PUBLIC_BASE_URL=true` for long-term production;
  the gate treats it as a bootstrap-only escape hatch and fails production
  validation when present.
- explicit primary database settings, plus host, port, database name, username,
  and password for every conversation shard in `IM_CONVERSATION_SHARD_IDS` and
  every summary shard in `IM_SUMMARY_SHARD_IDS`.
- internal command-api and gateway URLs. These must use loopback, private/link-local
  addresses, or single-label internal service names; public IPs and public
  FQDNs are rejected so internal traffic cannot accidentally leave the node/VPC.
- TCP slow-client protection and an explicit TLS-termination requirement for
  public realtime TCP.
- strong non-placeholder secrets: configure `JWT_SECRETS=kid:secret,...` with
  `JWT_ACTIVE_KID`; legacy single `JWT_SECRET` is rejected in production so key
  rotation is always available. Every JWT signing secret and
  `IM_INTERNAL_SHARED_SECRET` must be at least 32 characters;
  primary/shard database, Kafka SASL, and S3 secret values must be at least 16 characters.
  Known sample values such as `change_me`, `replace-me`, `password1234`, and the
  generated documentation placeholders are rejected.
- no `SEED_USER_EMAIL`, `SEED_USER_EMAILS`, or `SEED_USER_PASSWORD` entries.
  Development seed accounts are not allowed in production configuration.

Run it manually after editing `/etc/imserver/common.env`:

```bash
sudo bash deploy/ubuntu/55_verify_production_env.sh
```

## Environment

The generated environment file is:

```text
/etc/imserver/common.env
```

The default profile uses:

```env
APP_ENV=development
MEDIA_STORAGE_PROVIDER=local
```

This is intentional for a small test server because production mode requires S3-compatible media storage. Before switching to production, edit `/etc/imserver/common.env`:

```env
APP_ENV=production
MEDIA_STORAGE_PROVIDER=s3compatible
MEDIA_STORAGE_S3_ENDPOINT=https://<your-object-storage-domain>
MEDIA_STORAGE_S3_BUCKET=...
MEDIA_STORAGE_S3_ACCESS_KEY_ID=...
MEDIA_STORAGE_S3_SECRET_ACCESS_KEY=...
MEDIA_STORAGE_S3_REGION=...
MEDIA_STORAGE_S3_FORCE_PATH_STYLE=false
```

Then restart:

```bash
sudo systemctl restart imserver-gateway imserver-command-api imserver-query-api imserver-outbox-relay imserver-stream-consumer
```

## Ports

Open these security group ports for the long-term production profile:

- `80/tcp` for Let's Encrypt HTTP-01 validation and HTTP-to-HTTPS redirect
- `443/tcp` for HTTPS API through Nginx when `61_install_https.sh` is used
- `9000/tcp` for IM TCP connections
- `22/tcp` for SSH, restricted to your admin IP `/32` after bootstrap

Do not open `3389/tcp`; this is a Windows RDP port and is not used by the Ubuntu
IMServer deployment. For the long-term production posture, keep cloud security
group and UFW aligned: public client ports are `80`, `443`, and `9000`;
admin-only SSH is `22`; databases, Kafka, Redis, and internal APIs stay private.
The cloud security group audit fails production if any required client port is
missing unless `CLOUD_SECURITY_GROUP_REQUIRE_PUBLIC_CLIENT_PORTS=false` is set
for an intentional private deployment. It also fails when the audited rules file
is older than 86400 seconds unless `CLOUD_SECURITY_GROUP_RULES_MAX_AGE_SECONDS=0`
is explicitly set. Production also requires the audited rules file to be
root-owned unless `CLOUD_SECURITY_GROUP_RULES_REQUIRE_ROOT_OWNER=false` is set
for a documented local/bootstrap diagnostic. Broad public CIDR detection defaults to
`CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV4_MAX_PREFIX=8` and
`CLOUD_SECURITY_GROUP_PUBLIC_BROAD_IPV6_MAX_PREFIX=16`. SSH admin source
specificity defaults to `CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV4_MIN_PREFIX=32`
and `CLOUD_SECURITY_GROUP_ADMIN_PUBLIC_IPV6_MIN_PREFIX=128`. `8080/tcp` is a
bootstrap-only HTTP port and should be removed from the cloud security group
after HTTPS/Nginx is installed.

Keep these local only:

- PostgreSQL `5432`
- Redis `6379`
- Kafka `9092`
- internal APIs `8081`, `8082`

For temporary bootstrap testing, the iOS app can point the HTTP base URL at the
public HTTP entrypoint:

```text
http://<server-public-ip>
```

For long-term production, use HTTPS with a real domain and set
`PUBLIC_BASE_URL`/`IM_PUBLIC_BASE_URL` to the same value:

```text
https://<your-domain>
```

Point the TCP host/port at:

```text
<your-domain>:9000
```

Using `<server-public-ip>:9000` is acceptable only during short-lived bootstrap
diagnostics. The long-term production gate requires a real DNS host for TCP so
clients, certificates, load balancers, and future node replacement can move
without shipping a new app build.

## Test accounts

Development mode seeds these accounts:

- `demo@example.com / password1234`
- `alice@example.com / password1234`
- `bob@example.com / password1234`
- `carol@example.com / password1234`
- `dave@example.com / password1234`

These accounts are development-only. Before setting `APP_ENV=production`, remove
`SEED_USER_EMAIL`, `SEED_USER_EMAILS`, and `SEED_USER_PASSWORD` from
`/etc/imserver/common.env`; `55_verify_production_env.sh` fails if any remain.
