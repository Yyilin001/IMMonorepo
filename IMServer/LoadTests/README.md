# IMServer Load Tests

These load tests cover the text IM capacity paths that are currently production
gated: HTTP login, private/small-group baseline traffic, TCP online capacity,
and hot large-group message delivery through lightweight realtime hints plus
`timeline/since` catch-up. They do not claim media delivery, push notification,
or channel/broadcast capacity unless a profile explicitly says so.

All `*.yourdomain.com` targets in examples are replace-before-run placeholders.
Production gates reject literal `yourdomain.com` and `*.yourdomain.com` values;
use the real DNS names configured for your HTTPS and TCP entrypoints.
For final production acceptance, `BASE_URL` is the HTTPS origin only, such as
`https://chat.prod.company.com`; do not append `/api`, query strings, fragments,
userinfo, trailing dots, surrounding whitespace, or a non-default HTTPS port.
`TCP_HOST` is the DNS host only, such as `tcp.prod.company.com`; do not include `:9000`,
raw IPs, local/LAN hosts, wildcard hosts, underscores, trailing dots, surrounding
whitespace, or placeholder domains. `TCP_PORT` must be `9000`.
The shared `production_target_policy.py` enforces the same contract in current
readiness, production acceptance, receipt verification, acceptance env
validation, and final production-ready assertion.

## Profiles

- `local-smoke`: 100 virtual users, roughly 10 msg/s.
- `staging-baseline`: 10k virtual users, roughly 300 msg/s.
- `capacity-target`: 50k-100k TCP connections and 3k msg/s; run only against isolated capacity infrastructure.

## Local Acceptance

When the remote server is stopped, use the local wrapper instead of weakening
the production acceptance gates:

```bash
make run-local-acceptance-plan
make check-local-acceptance
make run-local-acceptance
make verify-local-acceptance
```

By default, `run_local_acceptance.sh` uses
`LOCAL_ACCEPTANCE_BACKEND=swift-postgres`: it starts a local Swift `combined`
server against the dedicated local PostgreSQL database
`imserver_local_acceptance`, waits on
`http://127.0.0.1:8080`, then runs `run_local_http_smoke.sh`. This path does
not require Docker, but it does require `swift`, `curl`, `python3`,
`psql`, `createdb`, `dropdb`, `pg_isready`, and a running local PostgreSQL on
`127.0.0.1:5432` unless those database environment variables are overridden.
It also defaults `LOCAL_ACCEPTANCE_RESET_SCHEMA=true`, which passes
`--reset-im-schema` to the development server and recreates the dedicated
`imserver_local_acceptance*` database so stale local migration state does not
break repeatable smoke runs. Set `LOCAL_ACCEPTANCE_RESET_SCHEMA=false` only
when deliberately testing against an existing local dev dataset.

The local HTTP smoke covers auth, direct/group conversation creation, internal
message write, conversation summary projection, conversation changes,
`timeline/since`, and internal metrics secret protection. It writes local-only
artifacts under
`IMServer/LoadTests/results/local-acceptance/` and marks them with
`productionEvidence=false`. These results are useful for local regression and
debugging, but they do not satisfy `run_production_acceptance.sh`,
`make validate-production-acceptance-env`, or `make verify-production-acceptance`.
`make verify-local-acceptance` checks the latest local summary, linked HTTP
smoke report, server log, required smoke checks, and the `productionEvidence=false`
guard so local artifacts cannot be confused with production evidence.

To use the Docker production-smoke topology instead:

```bash
LOCAL_ACCEPTANCE_BACKEND=docker-compose make check-local-acceptance
LOCAL_ACCEPTANCE_BACKEND=docker-compose make run-local-acceptance
```

To run the local HTTP smoke against a server you already started yourself:

```bash
LOCAL_ACCEPTANCE_BACKEND=external \
LOCAL_ACCEPTANCE_BASE_URL=http://127.0.0.1:8080 \
  make run-local-acceptance
```

To add broader product smoke after the local smoke passes:

```bash
LOCAL_ACCEPTANCE_RUN_PRODUCT_SCENARIOS=true \
LOCAL_ACCEPTANCE_SUITE=smoke \
  make check-local-acceptance
LOCAL_ACCEPTANCE_RUN_PRODUCT_SCENARIOS=true \
LOCAL_ACCEPTANCE_SUITE=smoke \
  make run-local-acceptance
```

## Current Production Readiness

Use `make run-current-production-readiness` as the fixed production validation
entrypoint. It first verifies the operator workstation route, then probes the
public HTTP and TCP entrypoints, and then chooses the next safe action:

- If the operator route is blocked by a local TUN/proxy route, it writes
  `operator-network.log`, records `reason=local_operator_network_blocked`, and
  stops before HTTP/TCP entrypoint probing. Disconnect the local TUN/proxy or
  rerun from a clean network before collecting production evidence.
- If the public entrypoint is blocked, it writes
  `entrypoint-probe.json`, generates or records a node-access rescue artifact,
  and refreshes `current-production-state-summary.*` plus
  `current-production-dashboard.*`. Do not start load while this is blocked.
- If the entrypoint is healthy, it runs `normal-product-smoke` by default.
- Set `CURRENT_PRODUCTION_RUN_SCENARIO_SUITE=true` to run the recommended
  ordinary-product scenario suite after a smoke-only diagnostic run. When
  `CURRENT_PRODUCTION_REQUIRE_PACKAGEABLE_EVIDENCE=true` (the default), any
  baseline or full-acceptance run automatically includes this suite because the
  final production evidence package requires it.
- Set `CURRENT_PRODUCTION_RUN_BASELINE=true` only after smoke passes and the
  account file/conversation inputs are ready; this runs the resumable
  `normal-product-baseline` production profile.
- Set `CURRENT_PRODUCTION_RUN_FULL_ACCEPTANCE=true` only after the baseline is
  ready to graduate into the long-term ladder; with packageable evidence enabled,
  this automatically includes baseline and product scenario suite evidence unless
  those runs are explicitly enabled already.

To re-check a generated readiness receipt in automation, set
`CURRENT_PRODUCTION_READINESS_JSON` and run
`make verify-current-production-readiness`. For the long-term production claim,
prefer the stricter wrapper `make run-production-acceptance`. It forces
packageable evidence, cloud security
group evidence, operator-network preflight, smoke, recommended ordinary-product
scenario suite, baseline, and the `production-full-acceptance` campaign from one
entrypoint. The wrapper rejects raw IP/http targets before starting load, so use
`run_current_production_readiness.sh` directly only for diagnostics or rescue.
Start from `production-acceptance.env.example`, copy it to
`production-acceptance.env`, fill real DNS targets, account CSV, conversation
UUID, and Aliyun security-group evidence, then source it from the repository
root. The filled `.env` file is ignored by git; keep secrets in the operator
secret store and inject them into the shell before sourcing the file.

```bash
cp IMServer/LoadTests/production-acceptance.env.example IMServer/LoadTests/production-acceptance.env
$EDITOR IMServer/LoadTests/production-acceptance.env
export PRODUCTION_ACCEPTANCE_BASE_URL="https://chat.prod.company.com"
export PRODUCTION_ACCEPTANCE_TCP_HOST="tcp.prod.company.com"
export PRODUCTION_ACCEPTANCE_TCP_PORT=9000
export PRODUCTION_ACCEPTANCE_ACCOUNT_FILE="IMServer/LoadTests/accounts/load-10000.csv"
export PRODUCTION_ACCEPTANCE_CONVERSATION_ID="<real-conversation-uuid>"
export IM_INTERNAL_SECRET="<from-secret-store>"
set -a
. IMServer/LoadTests/production-acceptance.env
set +a
make validate-production-acceptance-env
make run-production-acceptance

# After the run finishes, uncomment and fill PRODUCTION_ACCEPTANCE_RECEIPT_JSON
# and PRODUCTION_EVIDENCE_PACKAGE with the generated paths. Also point
# PRODUCTION_TOPOLOGY_SMOKE_RECEIPT_JSON at the latest production-smoke receipt,
# and PRODUCTION_DEPLOY_READINESS_RECEIPT_JSON at
# /var/lib/imserver/readiness/latest.json from the successful readiness gate,
# keep PRODUCTION_STATIC_GATE_RECEIPT_JSON pointed at the latest
# IMServer/LoadTests/results/production-static/latest.json receipt from
# make validate-production-static,
# then re-source.
set -a
. IMServer/LoadTests/production-acceptance.env
set +a
PRODUCTION_ACCEPTANCE_ENV_MODE=verify make validate-production-acceptance-env
make production-readiness-status
make verify-production-static-receipt
make production-completion-status
make verify-production-acceptance
make assert-production-ready
make verify-production-ready-assertion
make package-production-ready-assertion
PRODUCTION_READY_ASSERTION_ARCHIVE_FILE=/path/to/archive.tar.gz make verify-production-ready-archive
```

Use `PRODUCTION_ACCEPTANCE_LEVEL=baseline` only when deliberately stopping at
the packageable non-large-group baseline. The default `full` level requires the
full-acceptance account scale and produces the final portable evidence package
under `results/production-acceptance/production-evidence/`. The wrapper also
writes `production-acceptance.json` and `production-acceptance.md` inside the
run directory. Treat `status=PASS`, `reason=accepted`, `packagePresent=true`,
and zero readiness/package exit codes in that receipt as the top-level operator
signal; then review the linked `current-production-readiness.json` and evidence
package manifest for the detailed proof. Before calling the deployment
production-ready, run `make production-readiness-status` to confirm the target,
topology smoke receipt, deploy readiness receipt, local static gate receipt,
current readiness receipt, acceptance receipt, evidence package, package
checksum, and receipt/package binding are all consistent. Then run
`make assert-production-ready`; it starts with the same readiness-status
preflight and then requires
`PRODUCTION_TOPOLOGY_SMOKE_RECEIPT_JSON`,
`PRODUCTION_DEPLOY_READINESS_RECEIPT_JSON`,
`PRODUCTION_STATIC_GATE_RECEIPT_JSON`,
`CURRENT_PRODUCTION_READINESS_JSON`, and the final production
`PRODUCTION_ACCEPTANCE_RECEIPT_JSON`/`PRODUCTION_EVIDENCE_PACKAGE` to pass their
strict verifiers against the same real public target and current runtime
evidence. The generated final assertion receipt includes a `productionClaim`;
`make verify-production-ready-assertion` requires it to be the only
`productionReady=true` claim, with
`basis=verified-final-production-evidence`.
When the production host is intentionally stopped, run
`make production-completion-status` from the repository root to generate a
planning-only maturity report. It writes
`IMServer/LoadTests/results/production-completion-status/latest.json` and
`IMServer/LoadTests/results/production-completion-status/latest.md`. The JSON is
the machine-readable gate input; the Markdown is the operator-readable handoff
record. `make verify-production-completion-status` verifies that the Markdown
still matches the JSON report exactly. `make validate-production-static` also
sha256-binds both files into the static receipt. Both carry separate
`localCompletionPercent`, `liveEvidenceCompletionPercent`, and
`productionCompletionPercent` fields. The report also carries
`readinessTiers`, which separates local engineering completion from verified
live production evidence and the final production-ready claim. The report
requires a fresh local static gate receipt from
`make validate-production-static` for a full local score.
`make validate-production-static` refreshes that static receipt, regenerates the
completion report, runs `make verify-production-completion-status`, and rewrites
the static receipt with a sha256-bound `completionStatus` summary before it
returns. The static receipt verifier requires the receipt's own
`schemaVersion` and `gate.command` contract to match
`make validate-production-static`. It also requires the bound completion status
to report the expected `kind`, `schemaVersion`, scoring weights,
`readinessTiers`, same absolute `repoRoot`, freshness window, and a
`generatedAtEpoch` no newer than the static receipt itself, so malformed
artifacts, artifacts from another checkout, old completion runs, or
post-receipt completion reports cannot be mixed into the current gate.
Generated account CSVs, result receipts, reports, login cache files, and token
cache files are local runtime artifacts, not source inputs. Login/token cache
files can contain access tokens, so keep them under `/tmp` or another ignored
path and never commit them or include them in Docker images. The repository-level
static workflow audit checks both `.gitignore` and `IMServer/.dockerignore`
behavior for `IMServer/LoadTests/accounts/`, `IMServer/LoadTests/results/`,
`IMServer/LoadTests/**/*login-cache*`, `IMServer/LoadTests/**/*token-cache*`,
`IMServer/LoadTests/**/*token_cache*`, and `IMServer/reports/`; it also rejects
negation rules that would re-include token cache files.
Use `make verify-production-static-receipt` and
`make verify-production-completion-status` to re-check those artifacts later.
The completion verifier checks freshness, summary counts, percentages,
missing-evidence list, required local/evidence item coverage, and local
completion invariants. The report summary tracks `localMissingCount`,
`liveEvidenceMissingCount`, and `evidenceRecoveryPlanCount` separately so a
full local score is not mistaken for complete live production evidence. The
report is useful for
tracking local implementation progress and the missing live-evidence checklist,
but it is not accepted as production evidence and does not replace
`make assert-production-ready`.
Every `recovery item=` line in the text output is an operator recovery step for
one missing live-evidence item. Execute its `run=` command, execute its
`verify=` command, then regenerate the report with
`make production-completion-status`.
Do not count a recovery line itself as evidence. Only the verified receipt,
package, or archive produced by that step can move
`liveEvidenceCompletionPercent`.
Before executing those recovery commands, export the required evidence paths
and target variables and run `make validate-production-evidence-recovery-env`.
That target is a non-mutating recovery preflight: it first verifies the local
static receipt is still fresh, then verifies the recovery plan and generated
`evidence-recovery-run.sh` still match the bound completion status, then runs
the generated script with `PRODUCTION_EVIDENCE_RECOVERY_VALIDATE_ONLY=true`.
That final dry-run validates the required variables and the same shared public
production target policy used by production acceptance, including
placeholder-domain, raw-IP/local-host, URL path/query, and TCP port rejection,
then exits before any recovery command is executed.
The default `make production-evidence-recovery-plan` path is strict: local
engineering must already be complete. If you only need a diagnostic recovery
plan while fixing local blockers, run
`make production-evidence-recovery-plan-diagnostic`.
That diagnostic output includes a `Local Gate First` section, writes
`diagnostic-latest.*`, `diagnostic-evidence-recovery-plan.*`, and
`diagnostic-evidence-recovery-run.sh`, and is not production evidence. Verify it
with `make verify-production-evidence-recovery-plan-diagnostic`. The diagnostic
targets fail fast if any diagnostic output path is configured to the same path
as a strict artifact.
When `Local Gate First` reports `git_binding_mismatch`, inspect the attached
diagnostic fields such as `field=dirtyCount`, `currentTrackedModifiedCount=...`,
and `currentUntrackedCount=...`. That means the static receipt is bound to a
different git worktree state. Run `make production-worktree-inventory` for a
quick text summary, or `make production-worktree-inventory-json` to write
`IMServer/LoadTests/results/production-worktree-inventory/latest.json` for
comparison. To inspect one suggested commit group, pass
`PRODUCTION_WORKTREE_INVENTORY_ARGS='--group deploy-ops --paths-only'`. Use
`make production-worktree-plan` for a read-only commit-group review plan with
path-list, tracked diff review, source_change-only stageCommand, dry-run receipt command, validation commands, and suggested commitCommand. The
`make production-worktree-commit-runbook` target writes a reviewable shell runbook for the full group sequence; verify it with `make verify-production-worktree-commit-runbook` before running any command from it. The runbook is generated only; it is not executed by the target. If you execute the generated runbook after review, it refuses to run unless `IMSERVER_WORKTREE_RUNBOOK_CONFIRMED=reviewed` is set. The
same plan is available as machine-readable JSON with `make production-worktree-plan-json`; verify a saved plan with `make verify-production-worktree-plan-json` before using it. The JSON plan is bound to the current git status fingerprint.
stageDryRunCommand should be run before the real stageCommand, then run
stageDryRunReceiptCommand or `make production-worktree-stage-dry-run` with the same `--group` to write a machine-readable dry-run receipt, and `make verify-production-worktree-stage-dry-run` to prove the saved receipt is still bound to the current worktree. To preflight every source_change group at once, run `make production-worktree-stage-dry-run-batch` and `make verify-production-worktree-stage-dry-run-batch`. Then run
`make verify-production-worktree-staging` and
`make verify-production-worktree-staged-group` before committing. The staged-group check also rejects missing source_change paths from that group, extra staged paths, and files that still have unstaged worktree edits after staging. The stageCommand and commitCommand are not executed by the plan; review the paths first.
Untracked source_change files are listed separately because plain git diff does not show them.
Generated local artifacts and forbidden runtime artifacts are listed with separate
cleanup commands instead of being included in the suggested stageCommand. Commit
intended source changes, remove forbidden runtime artifacts, and ignore only
generated local artifacts before rerunning `make validate-production-static`.
If `make production-readiness-status` fails, use its `nextCommand` summary
instead of re-running the same check: missing target variables must be exported
first, missing current-readiness evidence should be regenerated with
`make run-current-production-readiness`, missing topology smoke evidence should
be regenerated with `make run-imserver-production-smoke`, and missing or
stale local static gate evidence should be regenerated with
`make validate-production-static`. Missing or inconsistent final
receipt/package evidence should be regenerated with `make run-production-acceptance`.
When `CURRENT_PRODUCTION_READINESS_JSON`, `PRODUCTION_ACCEPTANCE_RECEIPT_JSON`,
or `PRODUCTION_EVIDENCE_PACKAGE` are not set, the status script searches
`PRODUCTION_READINESS_RESULT_ROOT` (default `IMServer/LoadTests/results`) for the
newest matching readiness and acceptance receipts and then binds the package
from the acceptance receipt. Explicit paths still take priority and are not
silently replaced. `make assert-production-ready` uses the same discovery rule
before running its strict verifiers, so the final assertion can operate directly
from the latest production acceptance result directory.
On success, it writes an `imserver-production-ready-assertion` receipt to
`IMServer/LoadTests/results/production-ready/latest.json` by default. Set
`ASSERT_PRODUCTION_READY_RECEIPT_JSON` to place that final top-level proof in an
operator archive; the receipt records the exact target plus sha256/size records
for the topology smoke, deploy readiness, current readiness, acceptance, and
evidence package inputs. `make verify-production-ready-assertion` re-checks the
archived receipt target, the shared public production target policy, freshness,
and bound artifact hashes. This rejects placeholder domains, raw IP/local
hosts, URL path/query values, and TCP ports other than `9000` even when the
receipt and copied artifacts are otherwise self-consistent. If the evidence
files are copied into an audit archive, set
`PRODUCTION_READY_ASSERTION_ARTIFACT_ROOT=/path/to/archive`; the verifier can
resolve artifacts from either that flat directory or `artifactKey/fileName`
subdirectories instead of requiring the original host paths to still exist.
Use `make package-production-ready-assertion` after verification to create a
self-contained handoff package. The package directory contains
`production-ready-assertion.json`, `production-ready-archive-manifest.json`,
`SHA256SUMS`, `README.md`, and copied evidence under `artifacts/<artifactKey>/`;
the generated tarball can be extracted and re-verified with
`verify_production_ready_assertion.py --artifact-root artifacts`.
The package must also carry static gate support artifacts under
`artifacts/productionStaticGateReceipt/support/`: the production-completion
status JSON, evidence-recovery plan JSON, and evidence-recovery plan Markdown
bound by the static gate receipt. Portable production-ready verification uses
`--require-static-gate-support-root`, which forces the verifier to read those
support copies from the archive instead of falling back to original host paths.
The generated manifest is intentionally portable: it must use archive-relative
paths and file names, and verification rejects original machine-path fields such
as `sourcePath`, `sourceReceipt`, or `archiveFile`. Manifest
`sourceReceiptFileName` and `archiveName` values must be plain file names, not
absolute or relative paths; the outer tarball may still be renamed by an
artifact store after packaging. `generatedAt` and `generatedAtEpoch` are
verified as matching UTC timestamps, and future-dated manifest metadata is
rejected using the verifier's future-skew window. The manifest timestamp must
also not be earlier than the archived `production-ready-assertion.json`
generation time. The archive README is also checked: its status, target, TCP
port, and archive name summary must match the archived assertion and manifest,
not just include the generic verification command.
The archived `production-ready-assertion.json` is rewritten the same way: its
artifact paths point at `artifacts/<artifactKey>/...` inside the archive instead
of the original host's receipt inputs.
The archived static gate receipt is also rewritten so `completionStatus.path`,
`recoveryPlan.path`, and `recoveryPlan.markdownPath` point at
`artifacts/productionStaticGateReceipt/support/...` copies in the archive.
The copied support JSON is normalized too: completion-status `repoRoot` uses
`/imserver-production-ready-archive/repo`, and recovery-plan `sourceStatusJson`
points at the copied completion-status file rather than the original host path.
Use `make verify-production-ready-archive` for a tarball received later; it
rejects unsafe archive members, missing required files, checksum drift,
manifest drift, assertion/evidence binding drift, and `productionClaim` drift
between the archive manifest and archived assertion. It also rejects runtime
artifacts such as `load-*.csv`, account CSVs, login/token cache files, and
non-example `.env` files, even when they are nested under `artifacts/`.
The same preflight also rejects stale or future-dated current-readiness and
final-acceptance receipts using the default `CURRENT_PRODUCTION_MAX_AGE_SECONDS=86400`,
`CURRENT_PRODUCTION_MAX_FUTURE_SKEW_SECONDS=300`,
`PRODUCTION_ACCEPTANCE_MAX_AGE_SECONDS=86400`, and
`PRODUCTION_ACCEPTANCE_MAX_FUTURE_SKEW_SECONDS=300` windows, so old accepted
runs cannot silently advance to `make assert-production-ready`.
Generated `productionAcceptanceCommand` values intentionally require
`PRODUCTION_ACCEPTANCE_BASE_URL`, `PRODUCTION_ACCEPTANCE_TCP_HOST`,
`PRODUCTION_ACCEPTANCE_TCP_PORT`, `PRODUCTION_ACCEPTANCE_ACCOUNT_FILE`, and
`PRODUCTION_ACCEPTANCE_CONVERSATION_ID`, then map them to the runtime
`BASE_URL`, `TCP_HOST`, `TCP_PORT`, `ACCOUNT_FILE`, and `IM_CONVERSATION_ID`
environment variables. Set the target variables to the real HTTPS/DNS production
entrypoints; do not reuse example domains, local targets, a `load-1000.csv` smoke
file, or a smoke fixture UUID for full acceptance.
`run_production_acceptance.sh` also checks account CSV size before starting the
long readiness/package flow: `baseline` requires at least `5000` usable
`email,password` rows, and `full` requires at least `10000`. It also rejects a
missing, malformed, or nil `IM_CONVERSATION_ID`; use a real conversation UUID
created for the production acceptance run, not `00000000-0000-0000-0000-000000000000`
or another placeholder fixture value. Final production acceptance always forces
`CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080=false` and
`PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_ALLOW_TEMP_HTTP_8080=false`; `8080/tcp`
is bootstrap-only and cannot be part of accepted long-term evidence. It also
forces the cloud security group snapshot policy to
`rulesMaxAgeSeconds=86400` and `rulesRequireRootOwner=true`, so copied or
workstation-owned snapshots cannot be accepted as final production proof.

To re-check the top-level receipt in automation:

```bash
python3 perf_production_acceptance_verify.py \
  --receipt-json results/production-acceptance/<run-id>/production-acceptance.json \
  --package-file results/production-acceptance/production-evidence/production-evidence-<run-id>.tar.gz \
  --max-age-seconds 86400 \
  --require-pass
```

To re-check only the portable evidence package before installing or attaching it
to a deployment gate:

```bash
python3 perf_production_acceptance_verify.py \
  --verify-package-archive \
  --package-file results/production-acceptance/production-evidence/production-evidence-<run-id>.tar.gz \
  --expect-base-url https://chat.prod.company.com \
  --expect-tcp-host tcp.prod.company.com \
  --expect-tcp-port 9000
```

This is the same archive-level verifier used by `make production-readiness-status`.
It checks the package target, `README.md`, `current-production-readiness.md`,
`production-evidence-manifest.json.files`, `SHA256SUMS`, unsafe tar members, and
forbidden runtime artifacts such as `load-*.csv`, `accounts.csv`,
login/token-cache files, and non-example `.env` files.

The verifier rejects stale acceptance receipts by default. Keep the default
`--max-age-seconds 86400` for release/deploy automation so an old accepted run
cannot be reused as fresh production proof; only raise it for an explicit
historical audit, not for a new deploy gate.
`run_production_acceptance.sh` applies the same check immediately after writing
the top-level receipt through `PRODUCTION_ACCEPTANCE_RECEIPT_MAX_AGE_SECONDS`
and `PRODUCTION_ACCEPTANCE_RECEIPT_MAX_FUTURE_SKEW_SECONDS`, and records those
values in the receipt policy for audit. The dashboard, readiness gate, state
summary, and optimization playbook all render their
`productionAcceptanceCommand` with those defaults pinned, plus
`PRODUCTION_ACCEPTANCE_CLOUD_SECURITY_GROUP_REPAIR_RECEIPT_MAX_AGE_SECONDS=86400`,
so the copied operator command keeps the same freshness policy as the verifier.
The deploy and recurring audit wrappers pass the same policy through
`PERF_PRODUCTION_ACCEPTANCE_MAX_AGE_SECONDS` and
`PERF_PRODUCTION_ACCEPTANCE_MAX_FUTURE_SKEW_SECONDS`; leave them at `86400` and
`300` for normal production gates.

```bash
cd IMServer/LoadTests
BASE_URL=https://chat.yourdomain.com \
TCP_PORT=9000 \
ACCOUNT_FILE="$PWD/accounts/load-5000.csv" \
IM_CONVERSATION_ID="<conversation-id>" \
IM_INTERNAL_SECRET="$IM_INTERNAL_SECRET" \
SSH_PRIVATE_KEY_PATH=/path/to/test01.pem \
./run_current_production_readiness.sh
```

After entrypoint rescue or a cloud-console fix, run the same command again. To
include the recommended ordinary-product scenario suite after a smoke-only run:

```bash
CURRENT_PRODUCTION_RUN_SCENARIO_SUITE=true \
CURRENT_PRODUCTION_SCENARIO_SUITE=recommended \
BASE_URL=https://chat.yourdomain.com \
TCP_PORT=9000 \
ACCOUNT_FILE="$PWD/accounts/load-5000.csv" \
IM_CONVERSATION_ID="<conversation-id>" \
IM_INTERNAL_SECRET="$IM_INTERNAL_SECRET" \
./run_current_production_readiness.sh
```

The current readiness verifier requires the suite JSON, markdown, stage coverage,
and coverage summary to pass `perf_product_scenario_suite_verify.py` with
`--require-pass --require-no-large-group`; missing or large-group-contaminated
suite artifacts make the whole readiness run invalid. When the run is blocked by
`local_operator_network_blocked`, the verifier requires `operator-network.log`
to be present in `current-production-readiness.json` as `operatorNetworkLog`.

To include the full ordinary-product baseline after smoke:

```bash
CURRENT_PRODUCTION_RUN_BASELINE=true \
BASE_URL=https://chat.yourdomain.com \
TCP_PORT=9000 \
ACCOUNT_FILE="$PWD/accounts/load-5000.csv" \
IM_CONVERSATION_ID="<conversation-id>" \
IM_INTERNAL_SECRET="$IM_INTERNAL_SECRET" \
./run_current_production_readiness.sh
```

Because `CURRENT_PRODUCTION_REQUIRE_PACKAGEABLE_EVIDENCE=true` by default, this
baseline command also runs the recommended product scenario suite even when
`CURRENT_PRODUCTION_RUN_SCENARIO_SUITE` is not set. Explicitly setting
`CURRENT_PRODUCTION_RUN_SCENARIO_SUITE=false` with baseline or full acceptance
fails before load starts; use `CURRENT_PRODUCTION_REQUIRE_PACKAGEABLE_EVIDENCE=false`
only for a controlled diagnostic run that will not be packaged as final
production evidence.

To run the full long-term acceptance ladder from the same stable entrypoint:

```bash
CURRENT_PRODUCTION_RUN_BASELINE=true \
CURRENT_PRODUCTION_RUN_FULL_ACCEPTANCE=true \
BASE_URL=https://chat.yourdomain.com \
TCP_PORT=9000 \
ACCOUNT_FILE="$PWD/accounts/load-10000.csv" \
IM_CONVERSATION_ID="<conversation-id>" \
IM_INTERNAL_SECRET="$IM_INTERNAL_SECRET" \
./run_current_production_readiness.sh
```

This full ladder includes the isolated `large-group` suite, so the account file
must contain at least `10000` usable rows. With
`CURRENT_PRODUCTION_REQUIRE_PACKAGEABLE_EVIDENCE=true`, explicitly setting
`CURRENT_PRODUCTION_RUN_SMOKE=false` or `CURRENT_PRODUCTION_RUN_BASELINE=false`
while running full acceptance fails before load starts.

## Scenario Breadth Suite

Use these groups when the goal is to understand the IM service as a product, not
only the large-group hot path. Large groups stay as a separate stress suite
because they can dominate CPU, relay payload, and fanout metrics.

- `normal-product-smoke`: quick breadth check for the full non-large-group
  product surface: auth/session, account lifecycle, sync/read, direct chat,
  small groups, group lifecycle, contacts/profile, governance, safety/moderation,
  media, AI/admin, hot writes, TCP online, reconnect, multi-device, and pair
  delivery.
- `normal-product-baseline`: release-quality non-large-group baseline. This
  is the preferred suite before judging whether the current server handles normal
  chat usage; it is intentionally aligned with `product-breadth-baseline` and
  the legacy `im-scenario-breadth-baseline` alias.
- `normal-product-capacity`: higher-pressure breadth run for capacity
  machines. It still excludes 1000/5000/10000 member large-group scenarios.
  The legacy `im-scenario-breadth-*` names remain valid aliases.

Recommended order when expanding coverage beyond large groups:

1. `NON_LARGE_GROUP_MODE=smoke`: proves the public HTTP/TCP entrypoints, auth,
   sync/read, direct chat, small groups, social/profile, media/admin, TCP
   online, reconnect, multi-device, and pair-delivery paths can all run.
2. `NON_LARGE_GROUP_MODE=acceptance`: runs the full normal-product acceptance
   campaign across real-world baseline, daily usage, account/security,
   sync/read, direct message workflows, ordinary groups, social/media/governance,
   recovery, realtime, and the aggregate `normal-product-baseline` profile. It
   intentionally excludes isolated `large-group-*` fanout stress.
3. `NON_LARGE_GROUP_MODE=campaign` with
   `NON_LARGE_GROUP_CAMPAIGN=product-scenario-regression`: runs the product
   domains independently and keeps going by default, so one weak area does not
   hide the rest of the system.
4. `NON_LARGE_GROUP_MODE=domain`: reruns only one focused non-large-group
   scenario group from `run_perf_scenarios.sh --list` while tuning that
   subsystem. The wrapper still rejects groups that expand to `large-group-*`.
5. `NON_LARGE_GROUP_MODE=baseline`: final normal-product baseline before any
   isolated large-group stress. This is the number to use for ordinary IM
   capacity, not a large-group-only result.
6. `SCENARIO_GROUPS=large-group`: isolated fanout stress only after the normal
   product baseline is understood.

The core domains are:

- `account-security`: login, session management, token rotation, auth recovery,
  push token, and account lifecycle.
- `daily-core-smoke` / `daily-core-baseline`: foreground login, session, push,
  sync, offline catch-up, inbox, direct chat, read state, small groups, contacts,
  TCP online, and pair delivery in one daily-use bundle.
- `daily-traffic-smoke` / `daily-traffic-baseline`: representative day-to-day
  traffic mix with user journey, mixed workload, inbox fanout, offline catch-up,
  direct message lifecycle, read state, small groups, online chat mix, pair
  delivery, and multi-device delivery.
- `sync-read`: conversation list/changes, offline catch-up, inbox fanout,
  timeline paging/history, domain events, cold start, and client health.
- `sync-recovery` / `sync-recovery-baseline`: cold start, offline catch-up,
  timeline paging/history, domain event replay, multi-device sync, client
  health, and reconnect recovery.
- `direct-chat`: direct convergence, message lifecycle, read state, preferences,
  visibility, forwarding, and pair delivery.
- `message-workflow` / `message-workflow-baseline`: direct and conversation
  convergence, offline catch-up, read state, search, governance, preferences,
  visibility, forwarding, small groups, ordinary group delivery, online chat mix,
  and pair delivery.
- `group-workflow`: small groups, group admin, membership, invites, governance,
  access control, and ordinary group delivery below large-group scale.
- `group-delivery-smoke` / `group-delivery-baseline`: ordinary group realtime
  delivery below large-group fanout scale.
- `contacts-social`: contacts, profile propagation, and safety block behavior.
- `social-profile` / `social-profile-baseline`: contacts, profile propagation,
  safety block behavior, and access-control enforcement.
- `media-ai-admin`: media file/recovery, AI stream, search, and admin report
  moderation.
- `reliability-recovery`: reconnect, token failure recovery, multi-device sync,
  cold start, offline catch-up, and media failure recovery.
- `realtime-direct`: TCP online, reconnect soak, multi-device delivery, online
  chat mix, and pair delivery.

The safest entry point for this suite is the root Makefile wrapper. From the
repository root, use `make run-non-large-group-regression-plan`,
`make check-non-large-group-regression`, and
`make run-non-large-group-regression`. The wrapper delegates to
`run_non_large_group_regression.sh`; by default that script runs the
production-gate `non-large-group-release` campaign, which executes the campaign
and can later be packaged as production evidence. It also validates that
selected ordinary-product scenarios do not include `large-group-*` or
`SCENARIO_GROUPS=large-group`. For `smoke`, `baseline`, `capacity`, and
`domain` modes, the runner writes `entrypoint-probe.log` and
`entrypoint-probe.json` before starting load. By default, public entrypoint
failures stop the run so cloud-edge 403/WAF/NAT issues do not get misread as IM
business latency. The probe samples the HTTP host from `BASE_URL` and also
samples `TCP_HOST` on `NON_LARGE_GROUP_PROBE_PROTOCOL_PORTS` so split HTTP/TCP
deployments do not skip the protocol entrypoint check. When an entrypoint probe
fails, the wrapper also attempts to generate the same node-access rescue
artifact used by the product-plan runner, controlled by
`NON_LARGE_GROUP_ENTRYPOINT_RESCUE_ARTIFACT`,
`NON_LARGE_GROUP_ENTRYPOINT_RESCUE_ARTIFACT_DIR`, and
`NON_LARGE_GROUP_ENTRYPOINT_RESCUE_ARTIFACT_PACKAGE`. If no
`SSH_AUTHORIZED_KEY` or `SSH_PRIVATE_KEY_PATH` is available, the run still fails
with the probe log and JSON, and records that rescue artifact generation was
skipped because the SSH key source is missing.

For a single-node deployment, set `BASE_URL` first. If `TCP_HOST` is empty, the
multi-scenario runners derive it from the `BASE_URL` hostname and keep
`TCP_PORT=9000` by default. Set `TCP_HOST` explicitly only when HTTP and TCP are
served by different public names or load balancers. Always run `--print-plan`
first on a new server and check the printed target before starting real load.

After a campaign run, the wrapper verifies `product-campaign-run.json` and
`product-campaign-runbook.md` by default. `release` mode additionally requires a
production-gate campaign and, when executed, a `PASS` receipt. Diagnostic
`campaign` mode still verifies the receipt shape even when one product domain
fails, so the failed run remains useful for finding whether the weak area is
login/session, sync/read, direct chat, ordinary groups, social/governance,
media/admin, or realtime delivery. Set `NON_LARGE_GROUP_VERIFY_ARTIFACTS=false`
only for local wrapper tests with fake campaign output. Executed `release` runs
refuse to continue without artifact verification unless
`NON_LARGE_GROUP_ALLOW_UNVERIFIED_ARTIFACTS=true` is also set; that escape hatch
is for wrapper self-tests, not production evidence.

Product campaign receipts and runbooks record the effective target
(`baseURL`, `tcpHost`, `tcpPort`, account file, and whether conversation/internal
secret inputs were present). This is intentionally the same target handed to each
stage command, so package review can prove the campaign was planned or executed
against the intended server. `perf_product_campaign_artifacts_verify.py
--require-pass` rejects PASS receipts with missing target fields or stage
commands whose `BASE_URL`/`TCP_HOST`/`TCP_PORT` do not match the recorded target.

```bash
BASE_URL=https://chat.yourdomain.com \
TCP_PORT=9000 \
ACCOUNT_FILE="$PWD/IMServer/LoadTests/accounts/load-5000.csv" \
IM_CONVERSATION_ID="<conversation-id>" \
IM_INTERNAL_SECRET="$IM_INTERNAL_SECRET" \
make run-non-large-group-regression
```

For focused debugging from inside `IMServer/LoadTests`, call the script
directly:

```bash
cd IMServer/LoadTests
./run_non_large_group_regression.sh --print-plan
```

Useful variants:

```bash
# Plan only, no network calls.
PERF_DRY_RUN=true ./run_non_large_group_regression.sh --print-plan

# Generate the release campaign receipt as a command plan instead of executing.
NON_LARGE_GROUP_EXECUTE=false ./run_non_large_group_regression.sh

# Run the broad smoke suite.
NON_LARGE_GROUP_MODE=smoke ./run_non_large_group_regression.sh

# Run the full normal-product scenario acceptance campaign.
NON_LARGE_GROUP_MODE=acceptance ./run_non_large_group_regression.sh

# Run the domain-by-domain diagnostic regression campaign.
NON_LARGE_GROUP_MODE=campaign \
NON_LARGE_GROUP_CAMPAIGN=product-scenario-regression \
./run_non_large_group_regression.sh

# Same diagnostic campaign, but keep running stages so the receipt maps all weak areas.
NON_LARGE_GROUP_MODE=campaign \
NON_LARGE_GROUP_CAMPAIGN=product-scenario-regression \
PRODUCT_CAMPAIGN_STOP_ON_FAILURE=false \
./run_non_large_group_regression.sh

# Run one weak domain after a scorecard points to it.
NON_LARGE_GROUP_MODE=domain \
NON_LARGE_GROUP_DOMAIN=direct-chat \
./run_non_large_group_regression.sh

# Run focused recovery/read-sync or daily traffic groups without touching large groups.
NON_LARGE_GROUP_MODE=domain \
NON_LARGE_GROUP_DOMAIN=sync-recovery-baseline \
./run_non_large_group_regression.sh

NON_LARGE_GROUP_MODE=domain \
NON_LARGE_GROUP_DOMAIN=daily-traffic-smoke \
./run_non_large_group_regression.sh

# Keep entrypoint diagnostics but do not fail the run on probe errors.
NON_LARGE_GROUP_MODE=baseline \
NON_LARGE_GROUP_FAIL_ON_ENTRYPOINT_ERROR=false \
./run_non_large_group_regression.sh

# Override protocol sampling for split gateway deployments.
NON_LARGE_GROUP_PROBE_ADDITIONAL_HOSTS="tcp-gateway.example.com" \
NON_LARGE_GROUP_PROBE_PROTOCOL_PORTS="22 9000 9443" \
NON_LARGE_GROUP_MODE=smoke \
./run_non_large_group_regression.sh
```

Example:

```bash
cd IMServer/LoadTests
SCENARIO_GROUPS=normal-product-baseline \
BASE_URL=https://chat.yourdomain.com \
TCP_PORT=9000 \
ACCOUNT_FILE="$PWD/accounts/load-5000.csv" \
IM_CONVERSATION_ID="<conversation-id>" \
IM_INTERNAL_SECRET="$IM_INTERNAL_SECRET" \
./run_perf_scenarios.sh
```

`run_perf_scenarios.sh` performs a scenario-requirement preflight before the
first scenario starts, including `PERF_DRY_RUN=true` runs. If the selected
profile contains TCP online, reconnect, pair delivery, group delivery,
multi-device delivery, or large-group scenarios, set `ACCOUNT_FILE` to a readable
`email,password` CSV with at least as many usable rows as the largest selected
online/delivery target. TCP delivery scenarios also require
`IM_CONVERSATION_ID`. A missing file, undersized file, or missing conversation ID
fails before any partial HTTP scenarios are started. The run directory still gets
a standard `preflight-scenario-requirements` artifact plus `report.*`,
`triage.*`, and `evidence.*`; the evidence outcome is
`BLOCKED_PREREQUISITES`, which means fix test inputs before investigating server
performance.

For a production gate using the same scenario set:

```bash
cd IMServer/LoadTests
PERF_PRODUCTION_GATE_PROFILE=normal-product-baseline \
PERF_PRODUCTION_GATE_MAX_AGE_SECONDS=604800 \
SCENARIO_GROUPS=normal-product-baseline \
BASE_URL=https://chat.yourdomain.com \
TCP_HOST=tcp.yourdomain.com \
TCP_PORT=9000 \
ACCOUNT_FILE="$PWD/accounts/load-5000.csv" \
IM_CONVERSATION_ID="<conversation-id>" \
IM_INTERNAL_SECRET="$IM_INTERNAL_SECRET" \
./run_perf_scenarios.sh
```

For the long-running product-plan workflow, use the same suite as a phase. This
adds entrypoint gating, prerequisite audit, resumable receipts, and a generated
operator runbook around the same scenarios:

```bash
cd IMServer/LoadTests
PRODUCT_TEST_PHASES="entrypoint normal-product-baseline" \
BASE_URL=https://chat.yourdomain.com \
TCP_HOST=tcp.yourdomain.com \
TCP_PORT=9000 \
ACCOUNT_FILE="$PWD/accounts/load-5000.csv" \
IM_CONVERSATION_ID="<conversation-id>" \
IM_INTERNAL_SECRET="$IM_INTERNAL_SECRET" \
./run_product_test_plan.sh
```

For a single product-plan preset that is broader than a smoke run but still
excludes isolated large-group fanout stress, use:

```bash
cd IMServer/LoadTests
PRODUCT_TEST_PRESET=normal-acceptance \
BASE_URL=https://chat.yourdomain.com \
TCP_HOST=tcp.yourdomain.com \
TCP_PORT=9000 \
ACCOUNT_FILE="$PWD/accounts/load-5000.csv" \
IM_CONVERSATION_ID="<conversation-id>" \
IM_INTERNAL_SECRET="$IM_INTERNAL_SECRET" \
./run_product_test_plan.sh
```

Read these outputs first:

- `results/<RUN_ID>/slo.md`: per-scenario latency and error outcome.
- `results/scenario-status.md`: latest status for every scenario.
- `results/slo-domain-scorecard.md`: domain-level view, useful for seeing
  whether the bottleneck is auth/session, sync/read, direct realtime, group
  realtime, media, or reconnect.
- `results/optimization-playbook.md`: prioritized next optimization area.

## One-command Baseline

```bash
cd IMServer
./scripts/staging_baseline.sh --profile staging-baseline --env-file LoadTests/staging-baseline.env
```

Create `LoadTests/staging-baseline.env` from `LoadTests/staging-baseline.env.example`. Do not commit real credentials.

For the full multi-device release gate, including service tests, client tests, optional Redis integration, TCPDriver build, and optional staging baseline:

```bash
cd IMServer
./scripts/multidevice_release_gate.sh --env-file LoadTests/staging-baseline.env --staging-baseline
```

## Load-Test Gate Self-Test

Run this after changing TCP ladder metrics, gates, message-send wrappers, or
shell helpers. It does not open network connections or run the Swift TCP driver;
it sources the ladder functions and verifies the release-gate behavior for
metrics snapshots, timeline/since P95/P99, visibility scan limits, and
message-send production defaults.

```bash
cd IMServer
./LoadTests/tcp_capacity_ladder_test.sh
```

## HTTP k6

```bash
cd IMServer/LoadTests/k6
k6 run -e PROFILE=local-smoke -e BASE_URL=http://127.0.0.1:8080 http-small-group.js
```

Required environment:

- `BASE_URL`
- `IM_EMAIL`
- `IM_PASSWORD`
- `IM_MEMBER_EMAILS` as a comma-separated list

Optional environment:

- `IM_CONVERSATION_ID` to reuse an existing conversation
- `IM_INTERNAL_SECRET` to exercise `/internal/im/messages/send`

## HTTP Login Capacity

Use this profile to test `/api/auth/login` by itself. Do not mix this result with
TCP online capacity; it measures the HTTP auth/database/session path only.

```bash
cd IMServer/LoadTests/k6
k6 run \
  -e PROFILE=login-baseline \
  -e BASE_URL=https://chat.yourdomain.com \
  -e ACCOUNT_FILE="$PWD/../accounts/load-10000.csv" \
  http-auth-login.js
```

Profiles:

- `login-smoke`: 1 VU for 20 seconds.
- `login-baseline`: 200 VUs for 10 minutes.
- `login-capacity`: 1000 VUs for 20 minutes.

Optional environment:

- `ACCOUNT_FILE` or `IM_ACCOUNT_FILE`: local `email,password` CSV.
- `IM_ACCOUNT_PREFIX`, `IM_ACCOUNT_DOMAIN`, `IM_ACCOUNT_PASSWORD`,
  `IM_ACCOUNT_START_INDEX`, and `IM_ACCOUNT_COUNT`: generate account emails
  without a CSV.
- `IM_LOGIN_SLEEP_MS`: add per-iteration pacing.

Go/no-go:

- `im_auth_login_errors` below the profile threshold.
- `im_auth_login_latency` P95/P99 below the profile threshold.
- Report login throughput separately from TCP online capacity.

## Hot Conversation HTTP k6

Use this profile when validating a single high-frequency conversation. It sends all writes to the same conversation through the internal message endpoint, so it stresses sequence allocation, owner routing, the single-conversation write queue, outbox creation, projection lag, and fanout side effects without mixing in conversation creation noise.

```bash
cd IMServer/LoadTests/k6
k6 run \
  -e PROFILE=local-hot-smoke \
  -e BASE_URL=http://127.0.0.1:8080 \
  -e IM_EMAIL="$IM_EMAIL" \
  -e IM_PASSWORD="$IM_PASSWORD" \
  -e IM_CONVERSATION_ID="$IM_CONVERSATION_ID" \
  -e IM_INTERNAL_SECRET="$IM_INTERNAL_SECRET" \
  http-hot-conversation-write.js
```

Profiles:

- `local-hot-smoke`: 50 VUs for 1 minute.
- `staging-hot-baseline`: 500 VUs for 10 minutes.
- `capacity-hot-target`: 2k VUs for 20 minutes; run only against isolated capacity infrastructure.

Optional environment:

- `IM_MEMBER_EMAILS` when the script should create a fresh group conversation.
- `IM_SEND_INTERVAL_MS` to add per-VU pacing.
- `IM_METRICS_URL` to sample a non-default metrics endpoint.
- `IM_METRICS_SECRET`, `IM_METRICS_INTERNAL_SECRET`, or `IM_INTERNAL_SHARED_SECRET` to sample `/internal/metrics`.
- `IM_METRICS_SAMPLE_EVERY` to control metrics sampling frequency for VU 1.

Hot conversation go/no-go:

- `im_hot_write_errors` below 0.1%.
- `im_hot_write_send_latency` P95 below 500 ms and P99 below 1s for `staging-hot-baseline`.
- `im_conversation_write_queue_depth` does not stay above 100 for more than 5 minutes.
- `im_outbox_backlog_events` drains after load stops.
- `im_projection_lag_millis` returns below 10s after load stops.
- `im_message_write_queue_rejected_total`, `im_sequence_block_reserve_failures_total`, and `im_conversation_owner_forward_failures_total` remain at zero.

### Local hot-conversation stage report

For a local IMServer only, use the wrapper below to capture Prometheus snapshots
before and after the k6 run. It writes command, persistence-stage, outbox,
projection, relay, and `timeline/since` window deltas to one JSON report. The
wrapper rejects non-loopback URLs and never starts services or resets a
database.

```bash
cd IMServer/LoadTests
LOCAL_HOT_CONVERSATION_INTERNAL_SECRET="$IM_INTERNAL_SECRET" \
  ./run_local_hot_conversation.sh check
LOCAL_HOT_CONVERSATION_INTERNAL_SECRET="$IM_INTERNAL_SECRET" \
  ./run_local_hot_conversation.sh run
```

The output is stored under `results/local-hot-conversation/<run-id>/`. All
averages use counter deltas from that run window. `processLifetimeMaxMillis`
fields are explicitly not window-scoped and must not be compared as a per-run
maximum. A local combined runtime can legitimately have no relay or stream
work, so its output is a regression diagnostic, not a production capacity
claim.

To include this stage in the local PostgreSQL acceptance flow, opt in explicitly:

```bash
cd IMServer/LoadTests
LOCAL_ACCEPTANCE_RUN_HOT_CONVERSATION=true \
  LOCAL_ACCEPTANCE_HOT_CONVERSATION_SEND_INTERVAL_MS=100 \
  ./run_local_acceptance.sh run
```

The acceptance runner starts the local combined runtime, runs its HTTP smoke,
runs the hot-conversation profile against that same loopback process, writes the
stage report under `results/local-acceptance/hot-conversation/`, then stops the
runtime. It resets only databases whose name begins with
`imserver_local_acceptance` unless the unsafe-reset override is explicitly set.
When this stage starts the local Swift/PostgreSQL runtime, it enables the
production message-write batching profile by default (`true`, size `32`, delay
`10ms`) so the development-only serial coordinator is not reported as the
hot-write baseline. Set `LOCAL_ACCEPTANCE_HOT_CONVERSATION_BATCH_ENABLED=false`
for the serial comparison; override size or delay with
`LOCAL_ACCEPTANCE_HOT_CONVERSATION_BATCH_MAX_SIZE` and
`LOCAL_ACCEPTANCE_HOT_CONVERSATION_BATCH_MAX_DELAY_MS`.
The acceptance default paces each VU at 100 ms to keep this local regression
check bounded; standalone k6 runs remain unpaced unless `IM_SEND_INTERVAL_MS`
is set explicitly. The wrapper also writes its stage report when a k6 threshold
fails, so failed local runs retain diagnostic evidence.

### Local multi-node fault contracts

The following runner verifies code-level multi-node failure policy without
starting a service or using any remote infrastructure. It records a combined
Swift test log and a per-invariant summary under
`results/local-multinode-fault-contracts/<run-id>/`.

```bash
cd IMServer/LoadTests
./run_local_multinode_fault_contracts.sh check
./run_local_multinode_fault_contracts.sh run
```

To make it an explicit stage of the umbrella local acceptance runner without
starting PostgreSQL or IMServer, use:

```bash
cd IMServer/LoadTests
LOCAL_ACCEPTANCE_START_STACK=false \
LOCAL_ACCEPTANCE_BACKEND=none \
LOCAL_ACCEPTANCE_RUN_MULTINODE_FAULT_CONTRACTS=true \
  ./run_local_acceptance.sh run
```

It covers Redis fail-closed behavior, outbox recovery, duplicate client retries,
and replay idempotency for projections and owner delivery. A passing run is local
contract evidence only; it is not multi-node availability or capacity evidence.
See [multi-node-fault-validation.md](../docs/multi-node-fault-validation.md) for
the invariant mapping and the later isolated-environment drills.

## Message Convergence HTTP k6

Use this profile to measure the HTTP compensation path end to end. Each iteration sends one message, polls `messages/since` until the canonical message is visible, then polls the conversation list until the summary projection catches up to that message.

```bash
cd IMServer/LoadTests/k6
k6 run \
  -e PROFILE=local-convergence-smoke \
  -e BASE_URL=http://127.0.0.1:8080 \
  -e IM_EMAIL="$IM_EMAIL" \
  -e IM_PASSWORD="$IM_PASSWORD" \
  -e IM_CONVERSATION_ID="$IM_CONVERSATION_ID" \
  -e IM_INTERNAL_SECRET="$IM_INTERNAL_SECRET" \
  http-message-convergence.js
```

Profiles:

- `local-convergence-smoke`: 10 VUs for 1 minute.
- `staging-convergence-baseline`: 100 VUs for 10 minutes.

Optional environment:

- `IM_CONVERGENCE_TIMEOUT_MS`, default `10000`.
- `IM_CONVERGENCE_POLL_INTERVAL_MS`, default `250`.

Convergence go/no-go:

- TCPDriver ack success rate remains above 99.9%.
- TCPDriver canonical message success rate remains above 99.9%.
- `im_message_convergence_errors` below 0.1%.
- `im_message_accept_latency` P95 below 300 ms for `staging-convergence-baseline`.
- `im_message_timeline_latency` P95 below 2s for `staging-convergence-baseline`.
- `im_message_summary_latency` P95 below 5s for `staging-convergence-baseline`.
- Outbox backlog and projection lag drain back under alert thresholds after the run.

## TCPDriver

```bash
cd IMServer/LoadTests/TCPDriver
swift run IMTCPLoadDriver \
  --profile local-smoke \
  --base-url http://127.0.0.1:8080 \
  --tcp-host 127.0.0.1 \
  --tcp-port 9001 \
  --email "$IM_EMAIL" \
  --password "$IM_PASSWORD" \
  --conversation-id "$IM_CONVERSATION_ID" \
  --connections 5 \
  --devices-per-user 5 \
  --messages 1 \
  --hold-seconds 0
```

Required options:

- `--email`
- `--password`
- `--conversation-id`

Useful TCP scenarios:

- Idle online capacity ladder: run with `--profile custom --messages 0 --hold-seconds 30`
  to authenticate connections and keep them open while remote CPU, memory, TCP
  connection count, and Kafka lag are sampled. This is the baseline for "how many
  users can stay online".
- `1 user x 5 devices`: `--connections 5 --devices-per-user 5 --messages 1`
- Custom capacity ladder: use `--profile custom` so `--connections` is not capped by
  `local-smoke` or raised by `staging-baseline`; run `100`, `500`, `1000`, `2000`,
  `5000`, then `10000` connections from a separate load generator.
- `100 users x 2 devices`: pair HTTP/k6 user load with TCP `--devices-per-user 2`; use more load generator accounts for true multi-user TCP pressure.
- `1 group x 500 members x 2 devices`: create the group through staging fixtures, then run TCPDriver against the target `IM_CONVERSATION_ID` while k6 drives HTTP changes/history reads.
- `AI stream concurrency`: covered by `scripts/staging_baseline.sh`; tune with `IM_AI_STREAM_ATTEMPTS` and `IM_AI_STREAM_CONCURRENCY`.
- `logout all storm`: run TCPDriver continuously, then repeatedly call `DELETE /api/auth/sessions/all` for load accounts.
- `reconnect storm`: covered by `scripts/staging_baseline.sh` when `IM_RECONNECT_STORM_COMMAND` is set to a gateway restart/failover command that validates `messages/since` convergence.

TCPDriver reports:

- ack success rate and ack latency percentiles
- canonical message success rate and canonical latency percentiles
- total fanout message count
- reconnect count
- server error count

Add `--connection-log-file /path/to/tcp-driver.jsonl` when diagnosing TCP lifecycle
issues. The file is JSONL and records `login_start`, `login_ok`, `connection_start`,
`login_attempt_failed`, `login_retry_scheduled`, `nw_ready`, `auth_send_ok`,
`packet_received`, `auth_ok_received`, `heartbeat_send_ok`,
`heartbeat_ack_received`, `connection_disconnected`, `reconnect_scheduled`,
`reconnect_start`, `hold_complete`, `connection_finish`, `connect_timeout_fired`,
`preauth_timeout_fired`, `hold_timeout_fired`, and related failure events per
connection.
Use this when server metrics show `auth_ok` but the driver still reports missing or
closed connections.

Use `--login-cache-file` to separate HTTP login cost from TCP online-capacity tests.
The driver reuses cached access tokens when they are still valid long enough for the
connect ramp; otherwise it falls back to HTTP login and rewrites the cache. Use
`--login-only true` to prewarm the cache without opening TCP connections.
Use `--require-login-cache true` for TCP online-capacity runs where HTTP login must
not be part of the result. In that mode, a missing, undersized, or nearly expired
cache fails fast instead of falling back to HTTP login. Summary output includes
`loginCacheHit`, `loginCacheRecords`, and `loginCacheValidForSeconds`.
JIT HTTP login retries transient failures by default. Use `--login-retries` or
`IM_TCP_LOGIN_RETRIES` and `--login-retry-delay-ms` or
`IM_TCP_LOGIN_RETRY_DELAY_MS` to tune it. `login_failed` is logged only after all
attempts fail.

Use `--connection-queue-pool-size` when the local load generator becomes the
bottleneck. A larger pool reduces timer and send-completion tail latency for
thousands of `NWConnection` instances. Track `heartbeat_send_start.scheduleDriftMs`
and `heartbeat_send_ok.sendCompletionMs` from the JSONL log; if these tails reach
many seconds, split the run across multiple load generators before blaming the
server.

Use `--max-reconnects` for long idle-online hold tests. Reconnect is limited to
`--messages 0` scenarios so message-send tests cannot hide duplicate-send behavior.
Reconnect attempts log `connection_disconnected`, `reconnect_scheduled`, and
`reconnect_start`, then authenticate again and restart heartbeat on the new TCP
connection.

```bash
cd IMServer/LoadTests/TCPDriver
.build/release/IMTCPLoadDriver \
  --profile custom \
  --base-url https://chat.yourdomain.com \
  --tcp-host tcp.yourdomain.com \
  --tcp-port 9000 \
  --account-file ../accounts/load-1000.csv \
  --connections 1000 \
  --messages 0 \
  --login-concurrency 20 \
  --timeout-seconds 120 \
  --login-cache-file /tmp/imtcp-login-cache-1000.json \
  --login-only true

.build/release/IMTCPLoadDriver \
  --profile custom \
  --base-url https://chat.yourdomain.com \
  --tcp-host tcp.yourdomain.com \
  --tcp-port 9000 \
  --account-file ../accounts/load-1000.csv \
  --conversation-id 00000000-0000-0000-0000-000000000001 \
  --connections 1000 \
  --messages 0 \
  --hold-seconds 180 \
  --connect-ramp-seconds 120 \
  --timeout-seconds 120 \
  --heartbeat-interval-seconds 30 \
  --connection-queue-pool-size 256 \
  --max-reconnects 3 \
  --reconnect-delay-ms 1000 \
  --login-retries 2 \
  --login-cache-file /tmp/imtcp-login-cache-1000.json \
  --connection-log-file /tmp/imtcp-driver-1000-online.jsonl
```

Example 1000-connection idle diagnostic run. Use heartbeat for hold windows longer
than the server TCP idle timeout.

```bash
cd IMServer/LoadTests/TCPDriver
swift run IMTCPLoadDriver \
  --profile custom \
  --base-url https://chat.yourdomain.com \
  --tcp-host tcp.yourdomain.com \
  --tcp-port 9000 \
  --account-file ../accounts/load-1000.csv \
  --conversation-id 00000000-0000-0000-0000-000000000001 \
  --connections 1000 \
  --messages 0 \
  --hold-seconds 180 \
  --login-concurrency 20 \
  --connect-ramp-seconds 60 \
  --timeout-seconds 20 \
  --heartbeat-interval-seconds 30 \
  --connection-queue-pool-size 256 \
  --max-reconnects 3 \
  --connection-log-file /tmp/imtcp-driver-1000-heartbeat.jsonl
```

Capacity ladder helper:

```bash
cd IMServer/LoadTests
IM_CONVERSATION_ID="$IM_CONVERSATION_ID" \
SSH_HOST=root@<server-public-ip> \
LADDER="100 500 1000 2000 5000 10000" \
MESSAGES=0 \
HOLD_SECONDS=30 \
TIMEOUT_SECONDS=90 \
./tcp_capacity_ladder.sh
```

Provision a realistic multi-account pool before running online-capacity tests:

```bash
cd IMServer/LoadTests
COUNT=1000 \
PREFIX=load \
DOMAIN=example.com \
PASSWORD="<same-password-as-source-account>" \
SOURCE_EMAIL=demo@example.com \
SSH_HOST=root@<server-public-ip> \
./provision_load_accounts.sh
```

`SSH_HOST` is intentionally required; the script no longer defaults to an old
test server. Use `PROVISION_REMOTE=false` to generate only the local CSV without
writing users into the remote database.

Then run the ladder with that account file:

```bash
cd IMServer/LoadTests
IM_CONVERSATION_ID="$IM_CONVERSATION_ID" \
SSH_HOST=root@<server-public-ip> \
ACCOUNT_FILE="$PWD/accounts/load-1000.csv" \
LADDER="500 1000" \
MESSAGES=0 \
HOLD_SECONDS=60 \
CONNECT_RAMP_SECONDS=60 \
TIMEOUT_SECONDS=300 \
HEARTBEAT_INTERVAL_SECONDS=30 \
CONNECTION_QUEUE_POOL_SIZE=256 \
MAX_RECONNECTS=3 \
LOGIN_RETRIES=2 \
LOGIN_MODE=just-in-time \
CONNECTION_LOG_DIR=/tmp/imtcp-driver-logs \
./tcp_capacity_ladder.sh
```

### Online Capacity With Login Cache

This is the primary online-user capacity workflow. It prewarms access tokens first,
then the TCP run requires `login_cache_hit`; if the formal run logs any HTTP
`login_start`, the step is invalid.
Treat the generated login cache as a sensitive token cache. Prefer `/tmp` for
`LOGIN_CACHE_DIR`/`LOGIN_CACHE_FILE`; if you place cache files under the
repository during local debugging, they must remain covered by the enforced
`IMServer/LoadTests/**/*login-cache*` ignore rules and must not be copied into a
Docker build context.

The server access-token TTL must cover
`CONNECT_RAMP_SECONDS + HOLD_SECONDS + TIMEOUT_SECONDS + LOGIN_CACHE_TTL_GUARD_SECONDS`.
For the 10000-online example below, set `AUTH_ACCESS_TOKEN_TTL_SECONDS=3600` on the
server before prewarming cache.

For high TCP fan-in, set the gateway listen backlog and host SYN backlog above
the target ramp burst before starting the gateway:

```bash
sudo tee /etc/sysctl.d/99-imserver-tcp-capacity.conf >/dev/null <<'EOF'
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_synack_retries = 5
net.ipv4.tcp_abort_on_overflow = 0
EOF
sudo sysctl -p /etc/sysctl.d/99-imserver-tcp-capacity.conf
sudo sed -i 's/^IM_TCP_LISTEN_BACKLOG=.*/IM_TCP_LISTEN_BACKLOG=8192/' /etc/imserver/common.env
grep -q '^IM_TCP_LISTEN_BACKLOG=' /etc/imserver/common.env \
  || echo 'IM_TCP_LISTEN_BACKLOG=8192' | sudo tee -a /etc/imserver/common.env
sudo systemctl restart imserver-gateway
```

Verify that `ss -ltn sport = :9000` shows `Send-Q` at the configured backlog.

For a 10000-online target with two load generators, provision at least 10000
accounts, copy the same CSV to both load generators, then run one command per
machine.

Load generator 1:

```bash
cd IMServer/LoadTests
IM_CONVERSATION_ID="$IM_CONVERSATION_ID" \
SSH_HOST=root@<server-public-ip> \
ACCOUNT_FILE="$PWD/accounts/load-10000.csv" \
LOAD_GENERATOR_ID=1 \
LOAD_GENERATOR_COUNT=2 \
LADDER="5000" \
MESSAGES=0 \
HOLD_SECONDS=1800 \
CONNECT_RAMP_SECONDS=900 \
TIMEOUT_SECONDS=30 \
HEARTBEAT_INTERVAL_SECONDS=15 \
CONNECTION_QUEUE_POOL_SIZE=256 \
MAX_RECONNECTS=3 \
PREWARM_LOGIN_CACHE=true \
LOGIN_CACHE_DIR=/tmp/imtcp-login-cache \
LOGIN_CACHE_TTL_GUARD_SECONDS=60 \
LOGIN_MODE=upfront \
CONNECTION_LOG_DIR=/tmp/imtcp-driver-logs \
./tcp_capacity_ladder.sh
```

Load generator 2 uses the same command with `LOAD_GENERATOR_ID=2`.

### Fast Offline Login Cache

For a single 8 vCPU / 16 GiB load-test server, keep HTTP login outside the
online-capacity run and prewarm the cache in parallel. This avoids repeating the
old 10-minute connection ramp for every message test. On the 5000-account
Shenzhen test server, `CONCURRENCY=96` generated a 5000-record login cache in
about 3 minutes; adjust it down if the command API CPU saturates or login errors
appear.

Generate a 5000-account cache:

```bash
cd IMServer/LoadTests
./prewarm_login_cache_parallel.py \
  --base-url https://chat.yourdomain.com \
  --account-file /tmp/load-5000.csv \
  --connections 5000 \
  --login-cache-file /tmp/imtcp-login-cache-new-5000.json \
  --concurrency 96 \
  --request-timeout-seconds 30 \
  --login-retries 2
```

Then run the online check in strict cache-only mode. This profile has been
validated with 5000/5000 `authOK`, zero failures, and normal heartbeat ACKs
using a 180-second ramp:

```bash
python3 /opt/imserver/IMMonorepo/IMServer/LoadTests/tcp_online_driver.py \
  --tcp-host 127.0.0.1 \
  --tcp-port 9000 \
  --connections 5000 \
  --connect-ramp-seconds 180 \
  --hold-seconds 1200 \
  --timeout-seconds 240 \
  --heartbeat-interval-seconds 30 \
  --barrier-keepalive-seconds 15 \
  --barrier-batch-size 500 \
  --login-cache-file /tmp/imtcp-login-cache-new-5000.json \
  --login-cache-ttl-guard-seconds 30 \
  --suppress-packet-received-log \
  --progress-file /tmp/tcp-5000-msgtest-progress.json \
  --progress-interval-seconds 1
```

Use a longer ramp only when the load generator itself is saturated or when
auth/connect timeout counters increase. If the cache is still valid, do not
prewarm again; reuse it for repeated message-rate tests.

### Slow Offline Login Cache

On small servers, do not prewarm hundreds or thousands of HTTP logins inside the
same ladder step. Generate the login cache first with low pressure, then run the
TCP test in strict cache-only mode.

Generate a 1000-account cache with small batches:

```bash
cd IMServer/LoadTests
ACCOUNT_FILE="$PWD/accounts/load-1000.csv" \
CONNECTIONS=1000 \
BASE_URL=https://chat.yourdomain.com \
LOGIN_CACHE_FILE=/tmp/imtcp-login-cache-slow/tcp-login-cache-lg1-1000.json \
BATCH_SIZE=50 \
BATCH_PAUSE_SECONDS=5 \
REQUEST_TIMEOUT_SECONDS=30 \
LOGIN_RETRIES=2 \
./prewarm_login_cache_slow.sh
```

Then run online capacity without any HTTP login fallback:

```bash
cd IMServer/LoadTests
IM_CONVERSATION_ID="$IM_CONVERSATION_ID" \
SSH_HOST=root@<server-public-ip> \
ACCOUNT_FILE="$PWD/accounts/load-1000.csv" \
LADDER="1000" \
MESSAGES=0 \
HOLD_SECONDS=1800 \
CONNECT_RAMP_SECONDS=120 \
TIMEOUT_SECONDS=30 \
HEARTBEAT_INTERVAL_SECONDS=15 \
PREWARM_LOGIN_CACHE=false \
REQUIRE_LOGIN_CACHE=true \
LOGIN_CACHE_FILE=/tmp/imtcp-login-cache-slow/tcp-login-cache-lg1-1000.json \
LOGIN_CACHE_TTL_GUARD_SECONDS=600 \
CONNECTION_LOG_DIR=/tmp/imtcp-driver-logs \
./tcp_capacity_ladder.sh
```

For message-send tests, reuse the same cache:

```bash
cd IMServer/LoadTests
IM_CONVERSATION_ID="$IM_CONVERSATION_ID" \
SSH_HOST=root@<server-public-ip> \
ACCOUNT_FILE="$PWD/accounts/load-1000.csv" \
ONLINE_LADDER="1000" \
MESSAGE_RATES="5 10" \
MESSAGE_COMPLETION_MODE=ack-only \
MESSAGE_HOLD_SECONDS=60 \
MESSAGE_CONNECT_RAMP_SECONDS=120 \
PREWARM_LOGIN_CACHE=false \
REQUIRE_LOGIN_CACHE=true \
LOGIN_CACHE_FILE=/tmp/imtcp-login-cache-slow/tcp-login-cache-lg1-1000.json \
LOGIN_CACHE_TTL_GUARD_SECONDS=600 \
MESSAGE_METRICS_GATE_MODE=fail \
MESSAGE_COLLECT_REMOTE_METRICS=true \
MESSAGE_COLLECT_IM_METRICS=true \
MESSAGE_COLLECT_IM_METRICS_DELTA=true \
./tcp_message_send_ladder.sh
```

If the cache is missing, too small, or too close to expiry, the strict TCP run
fails before it can perform HTTP login. That failure is intentional: it keeps
HTTP login capacity separate from TCP online or message-delivery conclusions.

Single-machine local sharding is available when you cannot use two load
generators. It runs multiple TCPDriver processes on the same host so one process
does not become the bottleneck:

```bash
cd IMServer/LoadTests
IM_CONVERSATION_ID="$IM_CONVERSATION_ID" \
SSH_HOST=root@<server-public-ip> \
ACCOUNT_FILE="$PWD/accounts/load-5000.csv" \
CONNECTIONS=5000 \
LOCAL_DRIVER_SHARDS=5 \
MESSAGES=0 \
HOLD_SECONDS=1800 \
CONNECT_RAMP_SECONDS=900 \
TIMEOUT_SECONDS=30 \
HEARTBEAT_INTERVAL_SECONDS=15 \
HEARTBEAT_LOG_MODE=errors \
CONNECTION_QUEUE_POOL_SIZE=256 \
MAX_RECONNECTS=3 \
PREWARM_LOGIN_CACHE=true \
LOGIN_CACHE_DIR=/tmp/imtcp-login-cache-local-shards \
LOGIN_CACHE_TTL_GUARD_SECONDS=60 \
CONNECTION_LOG_DIR=/tmp/imtcp-driver-logs-local-shards \
./tcp_capacity_local_shards.sh
```

`tcp_capacity_local_shards.sh` passes the same active-room controls as the main
ladder, including `ACTIVE_CONVERSATION_USERS` and
`GLOBAL_HOLD_BARRIER_MIN_RATIO`, so single-machine sharding can still model
"all users authenticated before hold" and "N users actively viewing this
conversation" scenarios. It also uses the same remote `/internal/metrics`
delta and `IM_METRICS_GATE_MODE` checks as the main ladder; in `fail` mode a
local-shards run is invalid without `SSH_HOST`, remote metrics collection, and
before/after IM metrics deltas. Use `LOCAL_SHARDS_DRY_RUN=true` to print the
per-shard TCPDriver arguments without building or opening network connections.
`LOCAL_DRIVER_SHARDS` must be less than or equal to `CONNECTIONS`; each shard
must own at least one connection.

Acceptance for each generator:

- `loginCacheHit=true`, `loginCacheRecords >= connections`, and no HTTP
  `login_start` in the formal TCP run JSONL.
- `successes / connections >= 99.9%`.
- `connect_timeout_fired + preauth_timeout_fired < 0.1%`.
- `heartbeat_send_ok.sendCompletionMs` P99 below 10s; if this exceeds 10s while
  server CPU and memory are low, split into more load generators.
- Server `established_9000`, gateway CPU/memory, and Kafka lag are recorded during
  the run.

### Multi-Scenario Performance Matrix

Use `run_perf_scenarios.sh` as the top-level entry point when validating more
than one product scenario. It delegates to the existing k6, TCP online, and TCP
message-send scripts, writes every scenario into a separate result directory,
and generates a single Markdown report with pass/fail notes.

Always dry-run a matrix first:

```bash
cd IMServer/LoadTests
PERF_DRY_RUN=true \
RUN_ID=matrix-dry-run \
BASE_URL=https://chat.yourdomain.com \
TCP_HOST=tcp.yourdomain.com \
ACCOUNT_FILE="$PWD/accounts/load-5000.csv" \
IM_CONVERSATION_ID="$IM_CONVERSATION_ID" \
SCENARIO_GROUPS="http-smoke tcp-smoke" \
./run_perf_scenarios.sh
```

Then run a baseline matrix:

```bash
cd IMServer/LoadTests
RUN_ID="$(date +%Y%m%d-%H%M)-baseline" \
BASE_URL=https://chat.yourdomain.com \
TCP_HOST=tcp.yourdomain.com \
ACCOUNT_FILE="$PWD/accounts/load-5000.csv" \
IM_CONVERSATION_ID="$IM_CONVERSATION_ID" \
IM_INTERNAL_SECRET="$IM_INTERNAL_SECRET" \
SCENARIO_GROUPS="http-baseline tcp-baseline" \
STOP_ON_FAILURE=false \
./run_perf_scenarios.sh
```

Use `SCENARIOS="..."` when you need an exact hand-picked list. Use
`SCENARIO_GROUPS="..."` when you want the runner to expand a stable preset:

```bash
./run_perf_scenarios.sh --list

PERF_DRY_RUN=true \
SCENARIO_GROUPS="http-smoke" \
./run_perf_scenarios.sh
```

The HTTP matrix includes `user-journey-smoke`, `user-journey-baseline`, and
`user-journey-capacity` for mixed real-user behavior. These scenarios combine
login, `/api/me`, conversation list/changes, contacts, domain-events, optional
timeline reads, optional internal message writes, and client-health reports in
one flow. Use them after single-domain smoke tests pass to catch cross-module
latency and payload regressions.

For broader coverage that is not dominated by large-group delivery, start with
the real-world presets:

```bash
SCENARIO_GROUPS="real-world-smoke" ./run_perf_scenarios.sh
SCENARIO_GROUPS="real-world-baseline" ./run_perf_scenarios.sh
SCENARIO_GROUPS="real-world-capacity" ./run_perf_scenarios.sh
```

The same real-world presets can be run through the product plan runner when you
want entrypoint gating, prerequisite auditing, resumable phase receipts, and
eventual evidence packaging:

```bash
# Fast cross-product smoke before drilling into a specific domain.
PRODUCT_TEST_PHASES="entrypoint real-world-smoke" ./run_product_test_plan.sh

# Baseline user journey plus TCP online/message checks, still excluding
# large-group compact delivery.
PRODUCT_TEST_PHASES="entrypoint real-world-baseline" ./run_product_test_plan.sh
```

If you want to expand beyond large-group testing without immediately running the
entire matrix, use these focused product presets:

```bash
# Normal daily IM path: login/session, foreground sync, offline catch-up,
# inbox fanout, direct chat, read state, small group, contacts, online idle,
# and point-to-point TCP delivery.
SCENARIO_GROUPS="daily-core-smoke" ./run_perf_scenarios.sh
SCENARIO_GROUPS="daily-core-baseline" ./run_perf_scenarios.sh

# Daily traffic path: real user journey, weighted active-user HTTP mix,
# inbox fanout, offline catch-up, direct chat, read state, small group,
# 5000 online with low-rate chat traffic, and multi-device delivery.
SCENARIO_GROUPS="daily-traffic-smoke" ./run_perf_scenarios.sh
SCENARIO_GROUPS="daily-traffic-baseline" ./run_perf_scenarios.sh

# Message spike path: direct-message convergence, lifecycle reads, hot-write
# HTTP pressure, and point-to-point TCP bursts. This is useful when normal
# online capacity is stable but message-send latency spikes.
SCENARIO_GROUPS="message-spike-smoke" ./run_perf_scenarios.sh
SCENARIO_GROUPS="message-spike-baseline" ./run_perf_scenarios.sh

# Recovery path: token rotation, auth failure recovery, offline catch-up,
# multi-device convergence, cold start, timeline paging/history, domain events,
# media retry behavior, and TCP reconnect soak.
SCENARIO_GROUPS="reliability-recovery-smoke" ./run_perf_scenarios.sh
SCENARIO_GROUPS="reliability-recovery-baseline" ./run_perf_scenarios.sh

# Lifecycle/governance path: account lifecycle, session management, contacts,
# profile propagation, group admin/membership/invites, governance, visibility,
# block enforcement, access control, and admin report moderation.
SCENARIO_GROUPS="lifecycle-governance-smoke" ./run_perf_scenarios.sh
SCENARIO_GROUPS="lifecycle-governance-baseline" ./run_perf_scenarios.sh
```

The same focused baselines are available as production profiles when you want a
resumable run with prerequisite auditing and deployable evidence:

```bash
PERF_PRODUCTION_GATE_PROFILE=daily-core-baseline ./run_production_profile.sh
PERF_PRODUCTION_GATE_PROFILE=daily-traffic-baseline ./run_production_profile.sh
PERF_PRODUCTION_GATE_PROFILE=reliability-recovery-baseline ./run_production_profile.sh
PERF_PRODUCTION_GATE_PROFILE=lifecycle-governance-baseline ./run_production_profile.sh
PERF_PRODUCTION_GATE_PROFILE=sync-recovery-baseline ./run_production_profile.sh
PERF_PRODUCTION_GATE_PROFILE=message-workflow-baseline ./run_production_profile.sh
PERF_PRODUCTION_GATE_PROFILE=social-profile-baseline ./run_production_profile.sh
PERF_PRODUCTION_GATE_PROFILE=realtime-direct-baseline ./run_production_profile.sh
```

When the explicit goal is "test more than large groups", use the non-large-group
presets. They intentionally exclude `large-group-*` and focus on the normal
product surface: auth, client sync, direct chat, small groups, contacts, media,
online idle, reconnect, multi-device, and pair delivery.

```bash
SCENARIO_GROUPS="non-large-group-smoke" ./run_perf_scenarios.sh
SCENARIO_GROUPS="non-large-group-baseline" ./run_perf_scenarios.sh
SCENARIO_GROUPS="non-large-group-capacity" ./run_perf_scenarios.sh
```

For the broadest non-large-group evidence, use the `product-breadth-*` presets.
These include every HTTP product baseline scenario plus the non-large-group TCP
online/reconnect/direct-delivery checks. Use them when the question is "does the
whole IM product behave acceptably", not "how big can one group get".

```bash
# Short broad smoke. Good after deployment or before a longer baseline.
SCENARIO_GROUPS="product-breadth-smoke" ./run_perf_scenarios.sh

# Full product breadth without large-group delivery.
PERF_PRODUCTION_GATE_PROFILE=normal-product-baseline \
./run_production_profile.sh

# It writes production-profile-run.json/plan JSON and packages verified evidence when complete.

# Heavy broad run. Keep this for isolated capacity windows.
SCENARIO_GROUPS="product-breadth-capacity" ./run_perf_scenarios.sh
```

`non-large-group-baseline` matches the same-named scenario group and covers the
normal product surface without isolated `large-group-*` stress.
`normal-product-baseline` is the stricter release-gate variant: it adds
`hot-write-baseline` on top of `non-large-group-baseline` so hot conversation
writes stay visible in production evidence. It still excludes `large-group-*`, so
large-group capacity remains an independent domain. `product-breadth-baseline`
is kept as a compatibility alias for the same scenario set.

`run_production_profile.sh` reads the required scenario list from
`perf_production_profiles.json`, runs it in resumable batches, skips scenarios
that already have fresh SLO `PASS` evidence, regenerates the production gate, and
packages the verified evidence when the profile is complete. Tune
`PRODUCTION_PROFILE_BATCH_SIZE`, `PRODUCTION_PROFILE_RESUME_PASS`,
`PRODUCTION_PROFILE_STOP_ON_FAILURE`, and `PERF_PRODUCTION_GATE_MAX_AGE_SECONDS`
when you need smaller batches or a stricter freshness window. Before running the
first batch, it writes `production-profile-prereq-plan.json` and runs a strict
`perf_prereq_audit.py` gate for the selected profile scenarios. Leave
`PRODUCTION_PROFILE_PREREQ_GATE=true` for production evidence runs so missing
`ACCOUNT_FILE`, `IM_CONVERSATION_ID`, internal secret, or auth-code source
configuration fails before a long profile run starts. Each run also writes
`production-profile-run.json`, a receipt containing the final status, skipped
fresh-pass count, prereq summary, and per-batch scenario/run IDs; deployed
evidence requires this receipt to be non-dry-run and consistent with the
selected production profile. Failed receipts include `blockerType` so operators
can route the incident without reading every nested artifact:
`prerequisites`, `entrypoint`, `product-plan-evidence`, `scenario-batch`, or
`evidence-package`. Production profile runs default
`PERF_STATUS_FILTER_TARGET=true`; keep it enabled so resume/skipped PASS
decisions and the production gate only use evidence recorded for the current
`BASE_URL`/`TCP_HOST`/`TCP_PORT`. When `TCP_HOST` is not set, the evidence
package step derives it from the public/base URL hostname; set `TCP_HOST`
explicitly for split HTTP/TCP gateways. After the evidence tarball is created, the package
step records `package.status=PACKAGED`, the package path, and the package file
name back into this receipt so the retained evidence can be traced to the exact
artifact that was generated. The package step verifies that this path matches
the actual tarball it is writing. Deployment verification allows the tarball to
be copied to a different host/path, but still requires the package metadata to be
self-consistent.

The generated production gate can also enforce freshness directly:

```bash
python3 perf_production_gate.py \
  --slo-status-json results/slo-status.json \
  --profile normal-product-baseline \
  --require-run-artifacts \
  --max-evidence-age-seconds 604800
```

When this option is enabled, `production-gate.json` records
`requirements.maxEvidenceAgeSeconds`, evidence age counters, and explicit
`evidence_stale` or `evidence_time_in_future` failure kinds. This catches stale
PASS evidence before the deployment verifier runs the same policy as a final
installation gate.
When `PRODUCTION_PROFILE_PACKAGE=true` and the run is not a dry-run, standalone
profile runs also require a PASS product-plan receipt before the first profile
batch starts. This mirrors the evidence-package rule and prevents long profile
runs from failing only at the final packaging step. Run `run_product_test_plan.sh`
first, or set `PRODUCTION_PROFILE_REQUIRE_PRODUCT_PLAN_ARTIFACTS=false` only for
a controlled diagnostic profile that will not be used as production evidence.
Each profile run also writes `production-profile-runbook.md` and
`production-profile-runbook.json`. The runbook records the preferred
`run_production_profile.sh` command, every generated batch command, prerequisite
status, target settings, `blockerType`, and expected evidence paths. Use it as
the operator handoff when a long run is resumed on another terminal or when
auditing how a production evidence package was produced.

For product-domain coverage, use the named domain groups. These are easier to
reason about than raw script names and keep large-group delivery as just one
domain instead of the whole test strategy:

```bash
# Broad product smoke: auth, sync/read, direct chat, group workflow,
# contacts/social, media/AI/admin, online idle, and reconnect soak.
SCENARIO_GROUPS="product-smoke" ./run_perf_scenarios.sh

# Run one domain when triage points to a specific area.
SCENARIO_GROUPS="account-security" ./run_perf_scenarios.sh
SCENARIO_GROUPS="sync-read" ./run_perf_scenarios.sh
SCENARIO_GROUPS="direct-chat" ./run_perf_scenarios.sh
SCENARIO_GROUPS="group-workflow" ./run_perf_scenarios.sh
SCENARIO_GROUPS="contacts-social" ./run_perf_scenarios.sh
SCENARIO_GROUPS="media-ai-admin" ./run_perf_scenarios.sh
SCENARIO_GROUPS="sync-recovery" ./run_perf_scenarios.sh
SCENARIO_GROUPS="message-workflow" ./run_perf_scenarios.sh
SCENARIO_GROUPS="social-profile" ./run_perf_scenarios.sh
SCENARIO_GROUPS="realtime-direct" ./run_perf_scenarios.sh

# Move to baseline only after the smoke domain is stable.
SCENARIO_GROUPS="product-baseline" ./run_perf_scenarios.sh
SCENARIO_GROUPS="sync-recovery-baseline" ./run_perf_scenarios.sh
SCENARIO_GROUPS="message-workflow-baseline" ./run_perf_scenarios.sh
SCENARIO_GROUPS="social-profile-baseline" ./run_perf_scenarios.sh
SCENARIO_GROUPS="realtime-direct-baseline" ./run_perf_scenarios.sh
```

Recommended non-large-group order:

1. `real-world-smoke`: prove login, session, sync, user journey, direct
   convergence, unread/read state, contacts, media recovery, 1000 online,
   multi-device delivery, ordinary group delivery, and pair delivery in one
   compact cross-product pass.
2. `daily-core-smoke`: prove the normal chat path is usable before broader
   capacity work.
3. `daily-traffic-smoke`: add mixed daily-user traffic, low-rate online chat,
   and multi-device delivery without moving into large-group fanout.
4. `message-spike-smoke`: isolate send-path burst behavior for direct chat and
   hot conversations after steady daily traffic is healthy.
5. `reliability-recovery-smoke`: prove reconnect, cold start, paging, offline
   catch-up, and retry behavior before longer soaks.
6. `lifecycle-governance-smoke`: prove account, contacts, group lifecycle,
   visibility, moderation, and safety gates.
7. `account-security`: login, session lifecycle, token rotation, auth failure
   recovery, push-token lifecycle, and account lifecycle.
8. `sync-read`: foreground sync, mixed daily-active traffic, offline catch-up,
   inbox fanout, multi-device sync, cold start, timeline paging/history,
   domain-events, and client health.
9. `direct-chat`: direct message convergence, direct lifecycle, read state,
   conversation preferences/visibility, forwarding, point-to-point TCP delivery,
   and multi-device delivery.
10. `group-workflow`: small groups, group convergence, group admin,
   membership, invites, governance, access-control enforcement, and ordinary
   group realtime delivery up to 500 active users.
11. `contacts-social`: friend requests, contact changes, profile propagation,
   block/report/unblock, and block enforcement.
12. `media-ai-admin`: file/media upload-download, media failure recovery,
   AI stream lifecycle, admin report moderation, and search visibility.
13. `large-group`: only after the normal product workflows are green.

### More-Than-Large-Group Test Plan

Use this sequence when the goal is to understand the whole IM product instead of
only one large group fanout path. Keep the run target fixed with
`PERF_STATUS_FILTER_TARGET=true` so previous evidence from another host cannot
hide a new deployment problem.

The long-term campaign definitions live in `perf_product_campaigns.json` and are
validated by `perf_product_campaign_audit.py`. Treat this file as the source of
truth for production scenario coverage:

- `non-large-group-release`: the normal release gate for auth/session, sync,
  direct chat, ordinary groups, contacts/profile, media, AI/admin, recovery,
  governance, online, reconnect, multi-device, and pair delivery. It must not
  include `large-group-*` scenarios.
- `product-scenario-regression`: a domain-by-domain regression campaign for the
  same normal IM product surface. Use it when you need to test more scenarios
  and identify whether the weak area is account/security, sync/read,
  direct-message workflow, group workflow, social/governance, media/AI/admin, or
  reliability/realtime. It also excludes `large-group-*` and defaults
  `stopOnFailure=false`, so one failed required domain does not hide the rest of
  the product surface.
- `production-acceptance`: runs `non-large-group-release` first, then runs
  large-group stress as a separate isolated stage. Do not use large-group results
  as a substitute for normal product readiness.
- `production-full-acceptance`: the long-term production ladder. It runs
  `normal-product-smoke`, a packageable `normal-product-baseline` product-plan
  stage, `normal-product-baseline`, `normal-product-capacity`,
  message/realtime capacity, and finally isolated `large-group` stress. Use this
  when you need the full production picture rather than only a release gate.
- `incident-triage`: smaller domain-focused stages for entrypoint, sync/message,
  social/governance, realtime direct, and ordinary group delivery.

Audit the campaign catalog locally after changing phases, profiles, or scenario
groups:

```bash
python3 perf_product_campaign_audit.py --strict
```

`validate_load_tests.sh` runs both `perf_product_profile_gate.py` and
`perf_product_campaign_audit.py`. The final validation summary prints
`productProfileGate=...` and `productCampaignAudit=...`, so ordinary product
coverage drift is visible in the same gate as matrix, route, SLO, and production
readiness checks. The validation self-test also injects a bad large-group stage
into `non-large-group-release` and requires the campaign audit to reject it.
It also removes `sync-read` from the normal release campaign and requires the
audit to fail with a missing required phase, so the release gate cannot silently
drop ordinary product domains while still keeping the same stage count.
`perf_product_campaign_audit.py` writes those required phase policies into both
JSON and Markdown under `requiredPhasePolicies` / `Required Phase Policies`, and
the validation summary includes the required phase policy count.
Production evidence packages also include `perf_product_campaigns.json` and the
campaign audit input SHA-256 values; manifest verification rejects a package if
the packaged campaign catalog no longer matches the audit input.

Generate the exact production campaign command plan without touching the target
server:

```bash
python3 run_product_campaign.py \
  --campaign non-large-group-release \
  --result-dir results/non-large-group-release-plan
```

For the explicit "test more than large groups" workflow, plan or execute the
domain-by-domain campaign instead:

```bash
python3 run_product_campaign.py \
  --campaign product-scenario-regression \
  --result-dir results/product-scenario-regression-plan
```

After the entrypoint is healthy, execute it with the same target inputs:

```bash
BASE_URL=https://chat.yourdomain.com \
TCP_HOST=tcp.yourdomain.com \
TCP_PORT=9000 \
ACCOUNT_FILE="$PWD/accounts/load-10000.csv" \
IM_CONVERSATION_ID="$IM_CONVERSATION_ID" \
IM_INTERNAL_SECRET="$IM_INTERNAL_SECRET" \
python3 run_product_campaign.py \
  --campaign product-scenario-regression \
  --result-dir results/product-scenario-regression-$(date +%Y%m%d-%H%M%S) \
  --execute
```

Read `product-campaign-runbook.md` first after this campaign. It shows each
domain stage separately, so a slow or failing result points to a concrete area
instead of collapsing everything into a large-group-only conclusion. Unlike the
final `production-acceptance` campaign, this regression campaign continues after
required stage failures by default. The final status is still `FAIL` when any
required domain fails, but the later domains are attempted so the receipt can
show the full weak-area map.

The command above writes `product-campaign-run.json` and
`product-campaign-runbook.md` with `finalStatus=PLANNED`. A planned receipt is
only an operator runbook; it is not runtime evidence. Executed receipts include
`attemptedStageCount`, `skippedStageCount`, `failureCount`, and
`requiredFailureCount`. When a fail-fast campaign stops after a required failure,
later stages are still written with `status=SKIPPED` and
`skipReason=stopped_after_required_failure`, so the receipt distinguishes
"planned but skipped" from "missing from the campaign". Production evidence
packaging copies these campaign counters into the manifest and verifies they
match `product-campaign-run.json`. To execute the campaign after the public
entrypoint is healthy and all prerequisites are present, add `--execute`:

```bash
BASE_URL=https://chat.yourdomain.com \
TCP_HOST=tcp.yourdomain.com \
TCP_PORT=9000 \
ACCOUNT_FILE="$PWD/accounts/load-10000.csv" \
IM_CONVERSATION_ID="$IM_CONVERSATION_ID" \
IM_INTERNAL_SECRET="$IM_INTERNAL_SECRET" \
python3 run_product_campaign.py \
  --campaign non-large-group-release \
  --result-dir results/non-large-group-release-$(date +%Y%m%d-%H%M%S) \
  --execute
```

Executed campaigns materialize complete production-profile and product-plan
artifacts from their stage directories into the campaign result root by default.
When a campaign marks `packageEvidenceProfile` or `packageEvidenceProductPlan`,
those marked stages are used instead of a newest-directory heuristic. That makes
the result directory directly usable by
`package_production_evidence.sh` together with the top-level
`product-campaign-run.json` and `product-campaign-runbook.md`. Production gate
campaigns (`non-large-group-release`, `production-acceptance`, and
`production-full-acceptance`) also require
that materialized evidence by default; a would-be `PASS` becomes `FAIL` when the
packageable root artifacts cannot be produced. Set
`PRODUCT_CAMPAIGN_REQUIRE_MATERIALIZED_EVIDENCE=false` only for a controlled
diagnostic run. Set `PRODUCT_CAMPAIGN_MATERIALIZE_EVIDENCE_ROOT=false` or pass
`--no-materialize-evidence-root` only when you intentionally want to keep stage
artifacts isolated and are not producing final production evidence from that
campaign run.

For the long-term final production acceptance ladder, run
`production-full-acceptance`. It keeps ordinary product breadth, capacity,
message/realtime delivery, and large-group fanout as separate stages, while also
materializing product-plan artifacts for evidence packaging. Its packageable
product-plan evidence is pinned to `normal-product-plan`; packageable
production-profile evidence is pinned to `normal-product-baseline`, while
`normal-product-capacity` remains a required separate capacity stage:

```bash
BASE_URL=https://chat.yourdomain.com \
TCP_HOST=tcp.yourdomain.com \
TCP_PORT=9000 \
ACCOUNT_FILE="$PWD/accounts/load-5000.csv" \
IM_CONVERSATION_ID="$IM_CONVERSATION_ID" \
IM_INTERNAL_SECRET="$IM_INTERNAL_SECRET" \
python3 run_product_campaign.py \
  --campaign production-full-acceptance \
  --result-dir results/production-full-acceptance-$(date +%Y%m%d-%H%M%S) \
  --execute
```

Use an account file with at least `10000` usable rows for this campaign; the
large-group stage intentionally fails preflight with a smaller file.

For a shorter release-only gate, run `production-acceptance`. It executes the
normal non-large-group release campaign first and only then runs the isolated
large-group stage:

```bash
python3 run_product_campaign.py --campaign production-acceptance --execute
```

Prefer the plan runner for normal operations. It records every phase command and
status in `results/product-test-plan-run.json` and fails fast on the entrypoint
probe by default. The default phase list intentionally excludes `large-group-*`
and covers the core product surface, including direct-message spikes and the
full lifecycle/governance path:

```text
entrypoint daily-core account-security sync-read direct-chat group-workflow
contacts-social media-ai-admin message-spike reliability-recovery
lifecycle-governance realtime-direct
```

For an even faster first pass across the product, override the phase list with
`entrypoint real-world-smoke`. Use `entrypoint real-world-baseline` when you
want a single broad baseline before the detailed domain phases.

The plan runner treats the public HTTP entrypoint as a hard prerequisite by
default. `PRODUCT_TEST_REQUIRE_ENTRYPOINT=true` prepends `entrypoint` to the
effective phase list when it is omitted, and moves it to the first phase when it
appears later. Keep this enabled for production evidence; set it to `false` only
for a controlled offline/dry-run check where public HTTP is intentionally not
available.

When the entrypoint probe fails and `SSH_PRIVATE_KEY_PATH` or
`SSH_AUTHORIZED_KEY` is available, the product plan automatically writes a
node-access rescue package under `results/current-node-access-rescue/` by
default. The package contains a redacted external probe, a cloud-console rescue
script, post-rescue verification, and a resumable product-validation command.
Use `PRODUCT_TEST_ENTRYPOINT_RESCUE_ARTIFACT=false` only when the run must avoid
writing rescue artifacts.

Before a long run, list and validate the requested phases locally. This catches
typos without touching the target server. Use `--print-plan` when you want to
see the exact phase expansion and unique scenario count before starting k6/TCP
load. Use `--print-plan-json` for CI, release gates, or any place that should
persist a machine-readable plan receipt:

```bash
cd IMServer/LoadTests
./run_product_test_plan.sh --list-phases

PRODUCT_TEST_PRESET=normal-breadth \
./run_product_test_plan.sh --validate-plan

PRODUCT_TEST_PRESET=normal-breadth \
./run_product_test_plan.sh --print-plan

PRODUCT_TEST_PRESET=normal-breadth \
./run_product_test_plan.sh --print-plan-json > product-test-plan.preview.json

PRODUCT_TEST_PHASES="entrypoint daily-core sync-read direct-chat realtime-direct" \
./run_product_test_plan.sh --validate-plan
```

Use product-plan presets when the goal is to test more of the IM product instead
of manually assembling phase names:

```bash
# Fast broad signal across login/session, sync, direct chat, ordinary groups,
# contacts, media/recovery, and realtime paths.
PRODUCT_TEST_PRESET=normal-smoke ./run_product_test_plan.sh

# Recommended default for "not only large groups". It adds daily traffic,
# account/security, message spike, lifecycle/governance, ordinary group
# delivery, and realtime-direct coverage while still excluding large-group-*.
PRODUCT_TEST_PRESET=normal-breadth ./run_product_test_plan.sh

# Baseline-pressure version for release evidence after smoke is understood.
PRODUCT_TEST_PRESET=normal-baseline ./run_product_test_plan.sh

# Capacity-pressure breadth run. Keep large-group fanout isolated even here.
PRODUCT_TEST_PRESET=normal-capacity ./run_product_test_plan.sh

# Focused reruns after a broad failure.
PRODUCT_TEST_PRESET=workflow-regression ./run_product_test_plan.sh
PRODUCT_TEST_PRESET=realtime-focused ./run_product_test_plan.sh
```

For a focused product-plan run, use the root Makefile wrappers:
`make run-product-test-plan-plan`, `make check-product-test-plan`, and
`make run-product-test-plan`. They delegate to `run_product_test_plan.sh`.
For the broader operator-facing suite, use `make run-product-scenario-suite-plan`,
`make check-product-scenario-suite`, and `make run-product-scenario-suite`. The
suite wrapper delegates to `run_product_scenario_suite.sh`, which composes the
same product-plan and campaign runners without creating a second scenario
definition source. The default suite is `recommended`, which runs normal smoke,
breadth, workflow regression, realtime-focused regression, and normal baseline
while still excluding isolated `large-group-*` stress:

```bash
make run-product-test-plan-plan
make check-product-test-plan
make run-product-test-plan

make run-product-scenario-suite-plan
make check-product-scenario-suite
make run-product-scenario-suite
```

For focused debugging from inside `IMServer/LoadTests`, call the script
directly:

```bash
cd IMServer/LoadTests
# Inspect the exact stages and commands first.
./run_product_scenario_suite.sh --print-plan

# Default broader product pass: smoke -> breadth -> workflow -> realtime -> baseline.
PRODUCT_SCENARIO_SUITE=recommended ./run_product_scenario_suite.sh

# Run only one focused suite when debugging a weak area.
PRODUCT_SCENARIO_SUITE=workflow ./run_product_scenario_suite.sh
PRODUCT_SCENARIO_SUITE=realtime ./run_product_scenario_suite.sh
PRODUCT_SCENARIO_SUITE=capacity ./run_product_scenario_suite.sh
```

Every suite run writes a top-level receipt in
`results/<PRODUCT_SCENARIO_RUN_ID_PREFIX>-suite/`:

- `product-scenario-suite-run.json`: machine-readable suite status, target,
  dry-run/execute flags, per-stage result directories, per-stage status, and
  exit codes. It also includes `coverageSummary` and `stageCoverage`, which
  record the expected unique scenario count, covered product domains, missing
  required domains, and whether any stage includes isolated `large-group-*`
  stress. Failed stages also include promoted `failureSummary` entries with the
  nested product-plan/campaign reason, blocker type, failed phase, entrypoint
  diagnosis, recommended action, entrypoint rescue artifact status, and the
  exact artifact to inspect.
- `product-scenario-suite-run.md`: operator summary for the same data,
  including a `Coverage` table and a `Failure Summary` table when any stage
  fails.

Use this receipt as the first file when reviewing "more than large group"
results. It prevents a failed smoke, workflow, realtime, or baseline stage from
being hidden inside a nested product-plan/campaign directory. When
`PRODUCT_SCENARIO_EXECUTE=false`, the receipt status is `PLANNED`; when
`PRODUCT_SCENARIO_STOP_ON_FAILURE=true`, the receipt records the failing stage
before the wrapper exits. If the first failure is an entrypoint blocker such as
`cloud_edge_http_403_intercept`, fix public routing/security exposure before
rerunning the broader suite; do not treat the failed receipt as product
performance evidence. If the rescue status is
`SKIPPED:missing_ssh_key_source`, rerun with `SSH_PRIVATE_KEY_PATH` or
`SSH_AUTHORIZED_KEY` so the runner can package the cloud-console/SSH repair
artifact into `entrypoint.rescueArtifact`.

Validate the receipt before treating it as production evidence:

```bash
python3 perf_product_scenario_suite_verify.py \
  --suite-run-json results/<run-id>-suite/product-scenario-suite-run.json \
  --markdown results/<run-id>-suite/product-scenario-suite-run.md \
  --require-pass \
  --require-no-large-group
```

The verifier rejects receipts that are missing coverage data, have coverage
preview errors, claim a non-large-group run while coverage includes large-group
stress, or lose the human-readable `Coverage` section. When a failed suite
promoted `entrypointRescueStatus=PASS`, the verifier also checks that the
referenced rescue tarball and its `.verify.sh`, `.sha256`, and `.receipt.json`
sidecars are present. A receipt that claims a rescue package but lost the
package files is not valid production evidence.

`PRODUCT_SCENARIO_SUITE=full` intentionally runs the
`production-full-acceptance` campaign, where large-group stress is isolated as
the final stage. It requires explicit opt-in so a broad normal-product test does
not accidentally become a large-group capacity conclusion:

```bash
PRODUCT_SCENARIO_SUITE=full \
PRODUCT_SCENARIO_INCLUDE_LARGE_GROUP=true \
./run_product_scenario_suite.sh
```

Recommended order when expanding beyond large-group testing:

1. `PRODUCT_TEST_PRESET=normal-smoke ./run_product_test_plan.sh`
2. `PRODUCT_TEST_PRESET=normal-breadth ./run_product_test_plan.sh`
3. `PRODUCT_TEST_PRESET=workflow-regression ./run_product_test_plan.sh` if a
   business workflow is weak.
4. `PRODUCT_TEST_PRESET=realtime-focused ./run_product_test_plan.sh` if message
   delivery, reconnect, multi-device, or ordinary group delivery is weak.
5. `PRODUCT_TEST_PRESET=normal-baseline ./run_product_test_plan.sh` after smoke
   and focused reruns are understood.
6. Run `SCENARIO_GROUPS=large-group ./run_perf_scenarios.sh` separately only
   after the normal product surface is green.

`PRODUCT_TEST_PHASES` still wins over `PRODUCT_TEST_PRESET`; use explicit phases
when you need a one-off subset. Product-plan receipts and runbooks record the
selected preset so later evidence shows whether the run was a breadth, baseline,
capacity, workflow, or realtime-focused test.

For ordinary group realtime delivery without entering the large-group
compact/pull path, run the dedicated group-delivery presets:

```bash
SCENARIO_GROUPS="group-delivery-smoke" ./run_perf_scenarios.sh
SCENARIO_GROUPS="group-delivery-baseline" ./run_perf_scenarios.sh
SCENARIO_GROUPS="group-delivery-capacity" ./run_perf_scenarios.sh

PRODUCT_TEST_PHASES="entrypoint group-delivery group-delivery-baseline" \
./run_product_test_plan.sh
```

The plan runner also performs a local prerequisite gate before it touches the
target server. It expands the requested phases into exact scenarios, writes
`results/product-test-prereq-plan.json`, audits required inputs into
`results/product-test-prereq-audit.{md,json}`, and fails before the entrypoint
probe when required inputs are missing. Keep `PRODUCT_TEST_PREREQ_GATE=true` for
production-style runs. Disable it only for controlled script diagnostics:

```bash
PRODUCT_TEST_PREREQ_GATE=false \
PERF_DRY_RUN=true \
./run_product_test_plan.sh
```

Failed product-plan receipts include `blockerType`. Use `prerequisites` for
missing `ACCOUNT_FILE`, `IM_CONVERSATION_ID`, internal secret, or auth-code
source; `entrypoint` for public HTTP probe failures; `scenario-groups` for a
runtime scenario batch failure; `production-profile` for the optional full
profile phase; and `evidence-package` for packaging failures.

After a product plan run, verify the receipt and prereq artifacts before using
the result as operator evidence:

```bash
python3 perf_product_plan_artifacts_verify.py \
  --product-run-json results/product-test-plan-run.json \
  --require-prereq
```

Use `--allow-dry-run` only for local script diagnostics; production evidence
must come from a non-dry-run receipt.

Every product plan run also writes `results/product-test-plan-preview.json` and
`results/product-test-runbook.{md,json}`. The preview JSON records the exact
phase expansion, selected scenarios, unique scenario count, and whether any
`large-group-*` scenario is included. It also records required product-domain
coverage for the normal product surface: account/security, sync/read, direct
chat, ordinary group workflow, contacts/social, media/AI/admin, reliability
recovery, and realtime direct delivery. A production product-plan evidence item
should have `requiredProductDomainsCovered=true` and
`largeGroupIncluded=false`; large-group stress remains an isolated campaign
stage. The runbook records the requested phases, target, prereq status, phase
commands, `blockerType`, preview path, product-domain coverage, and the verifier
command needed to audit the receipt. Secret values such as
`IM_INTERNAL_SECRET` are not written in clear text. Generated commands use
fail-fast shell placeholders such as
`IM_INTERNAL_SECRET=${IM_INTERNAL_SECRET:?set-IM_INTERNAL_SECRET}` so a copied
command stops immediately unless the real secret is already present in the
operator shell. When a generated command also contains
`IM_INTERNAL_SHARED_SECRET`, it uses
`IM_INTERNAL_SHARED_SECRET=${IM_INTERNAL_SHARED_SECRET:-${IM_INTERNAL_SECRET:?set-IM_INTERNAL_SECRET}}`,
so operators can set only `IM_INTERNAL_SECRET` unless they intentionally need a
different shared-secret value.

If a product plan receipt exists when `package_production_evidence.sh` runs, the
production evidence package includes the product plan receipt, plan preview,
prereq audit, scenario catalog, phase TSV, and runbook. Set
`PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_PLAN_ARTIFACTS=false` only for a controlled
diagnostic package that intentionally contains production-profile evidence
without broader product-plan evidence.
The package manifest records the effective product-plan and product-campaign
artifact policy; by default manifest verification rejects packages that omit
either production evidence family.
For final production acceptance, pass
`PRODUCTION_EVIDENCE_CLOUD_SECURITY_GROUP_RULES_FILE=/etc/imserver/cloud-security-group.json`
when packaging. If `PERF_PRODUCTION_GATE_REQUIRE_PRODUCTION_TARGET=true`, the
`run_production_profile.sh` and `run_product_test_plan.sh` preflights also
reject local, IP-only, placeholder, non-HTTPS, or non-default HTTPS targets
before starting batches, even when `PRODUCTION_PROFILE_PACKAGE=false`. The
package step automatically requires this snapshot and rejects packages that omit
it. The package will include the audited snapshot as
`cloud-security-group.json`, and the manifest records its size and sha256.
Install and recurring verification can enforce the same policy with
`PERF_PRODUCTION_EVIDENCE_REQUIRE_CLOUD_SECURITY_GROUP=true`, so a performance
report is not accepted without the matching cloud security group evidence.
When `run_current_production_readiness.sh` is used for packageable production
acceptance, set
`CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_RULES_FILE=/etc/imserver/cloud-security-group.json`.
The readiness prereq gate audits that snapshot before starting load, and the
receipt records `requireCloudSecurityGroup=true`.
The final production evidence package requires
`product-scenario-suite-run.json`, `product-scenario-suite-run.md`, and
`product-scenario-suite-stages.tsv` by default. Set
`PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS=false` only for a
controlled diagnostic package that is meant to prove only a lower-level profile
or product-plan receipt. With the default
`PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_NO_LARGE_GROUP=true`,
manifest verification rejects suite evidence whose coverage includes isolated
`large-group-*` stress, so ordinary-product conclusions stay separate from
large-group fanout tests.
`package_production_evidence.sh` also requires current production readiness by
default. A final production evidence package must include
`current-production-readiness.json`/`.md` where `smoke`, `productScenarioSuite`,
`baseline`, and `fullAcceptance` were all requested and all four exit codes are
`0`, plus the full-acceptance campaign run JSON and runbook. Standalone
`run_production_profile.sh` and `run_product_test_plan.sh` diagnostic packages
explicitly set `PRODUCTION_EVIDENCE_REQUIRE_CURRENT_READINESS=false`; do not
treat those packages as final production acceptance evidence unless they are
repackaged with current readiness and product scenario suite evidence enabled.
The current readiness receipt, `current-production-dashboard.*`,
`current-production-state-summary.*`, evidence package manifest, install
summary, verify summary, and package `README.md` all expose the same final
product scenario suite and final acceptance fields:
`currentReadinessRequestedProductScenarioSuite`,
`currentReadinessProductScenarioSuiteExitCode`,
`currentReadinessProductScenarioSuiteExpected`,
`currentReadinessProductScenarioSuite`,
`currentReadinessProductScenarioSuiteStatus`,
`currentReadinessProductScenarioSuiteScenarios`, and
`currentReadinessProductScenarioSuiteLargeGroupIncluded`; plus
`currentReadinessFullAcceptanceExpectedCampaign`,
`currentReadinessFullAcceptanceCampaign`,
`currentReadinessFullAcceptanceStatus`, and
`currentReadinessFullAcceptanceFailures/required/attempted/skipped`. Treat the
package as non-production evidence if the actual campaign differs from
`production-full-acceptance`, the suite is not requested or does not pass, suite
coverage includes large-group stress, the final acceptance status is not `PASS`,
failure or required failure counts are nonzero, attempted stages are zero, or
skipped stages are nonzero. The local package verifier, install script, installed-evidence verifier,
operational audit, and production readiness gate enforce these same fields so a
partial or wrong campaign cannot be promoted by only copying a green
`production-gate.json`.
For production evidence, the product plan receipt must be non-dry-run and
`finalStatus=PASS`. A failed receipt, for example `entrypoint_failed` from a
public HTTP `403`, is valid diagnostic evidence but is rejected by evidence
packaging, package installation, and installed-evidence verification.

```bash
cd IMServer/LoadTests
BASE_URL=https://chat.yourdomain.com \
ACCOUNT_FILE="$PWD/accounts/load-5000.csv" \
IM_CONVERSATION_ID="$IM_CONVERSATION_ID" \
IM_INTERNAL_SECRET="$IM_INTERNAL_SECRET" \
PRODUCT_TEST_RUN_FULL_PROFILE=false \
./run_product_test_plan.sh
```

To focus a run, override `PRODUCT_TEST_PHASES`. Examples:

```bash
# Normal chat and sync only.
PRODUCT_TEST_PHASES="entrypoint daily-core sync-read direct-chat realtime-direct" \
./run_product_test_plan.sh

# User/account surfaces only.
PRODUCT_TEST_PHASES="entrypoint account-security contacts-social lifecycle-governance" \
./run_product_test_plan.sh

# Media, search, AI stream, admin report, and recovery.
PRODUCT_TEST_PHASES="entrypoint media-ai-admin reliability-recovery" \
./run_product_test_plan.sh
```

When the phase runs are green and you want a stronger diagnostic package for
the same product-plan surface, rerun the same plan with the full normal-product
profile enabled:

```bash
PRODUCT_TEST_RUN_FULL_PROFILE=true \
PRODUCT_TEST_FULL_PROFILE=normal-product-baseline \
./run_product_test_plan.sh
```

In this mode the product plan owns product-plan/profile diagnostic packaging.
The nested
`run_production_profile.sh` invocation runs with `PRODUCTION_PROFILE_PACKAGE=false`
because the product-plan receipt is not PASS until the outer plan finishes. After
the full profile passes, `run_product_test_plan.sh` writes
`product-test-plan-run.json` with `finalStatus=PASS` and then calls
`package_production_evidence.sh` with
`PRODUCTION_EVIDENCE_REQUIRE_CURRENT_READINESS=false` and
`PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_SCENARIO_SUITE_ARTIFACTS=false`. Set
`PRODUCT_TEST_PACKAGE_EVIDENCE=false` only when you want to collect raw run
artifacts without creating a diagnostic tarball. For final production acceptance
evidence, run `run_current_production_readiness.sh` with both
`CURRENT_PRODUCTION_RUN_BASELINE=true` and
`CURRENT_PRODUCTION_RUN_FULL_ACCEPTANCE=true`, then package the resulting
current readiness artifacts with current readiness and product scenario suite
evidence required. The stable readiness entrypoint automatically includes the
suite for this packageable path unless `CURRENT_PRODUCTION_REQUIRE_PACKAGEABLE_EVIDENCE=false`
is explicitly set for diagnostics.

Phase 0: entrypoint and prerequisites. This must pass before any performance
claim is meaningful:

```bash
cd IMServer/LoadTests
BASE_URL=https://chat.yourdomain.com \
ACCOUNT_FILE="$PWD/accounts/load-5000.csv" \
PROBE_FAIL_ON_ENTRYPOINT_ERROR=true \
./http_entrypoint_probe.sh
```

If this phase fails with `cloud_edge_http_403_intercept`, do not continue into
load testing. Use the generated `current-node-access-rescue` package first. A
standalone `run_production_profile.sh` run has the same default behavior via
`PRODUCTION_PROFILE_ENTRYPOINT_RESCUE_ARTIFACT=true`, so production gates still
leave a rescue package even when they are not launched through
`run_product_test_plan.sh`.

Phase 1: normal daily usage. This covers login/session, foreground sync,
conversation list, offline catch-up, inbox fanout, direct chat, read state, small
group, contacts, online idle, and point-to-point delivery:

```bash
BASE_URL=https://chat.yourdomain.com \
TCP_HOST=tcp.yourdomain.com \
ACCOUNT_FILE="$PWD/accounts/load-5000.csv" \
IM_CONVERSATION_ID="$IM_CONVERSATION_ID" \
SCENARIO_GROUPS="daily-core-smoke daily-traffic-smoke" \
STOP_ON_FAILURE=false \
./run_perf_scenarios.sh
```

Phase 2: state recovery and read pressure. This separates read/sync bottlenecks
from realtime fanout:

```bash
BASE_URL=https://chat.yourdomain.com \
TCP_HOST=tcp.yourdomain.com \
ACCOUNT_FILE="$PWD/accounts/load-5000.csv" \
IM_CONVERSATION_ID="$IM_CONVERSATION_ID" \
SCENARIO_GROUPS="sync-recovery message-workflow" \
STOP_ON_FAILURE=false \
./run_perf_scenarios.sh
```

Phase 3: user graph, governance, and safety. This validates surfaces that can
break real clients even when message latency looks good:

```bash
BASE_URL=https://chat.yourdomain.com \
TCP_HOST=tcp.yourdomain.com \
ACCOUNT_FILE="$PWD/accounts/load-5000.csv" \
IM_CONVERSATION_ID="$IM_CONVERSATION_ID" \
SCENARIO_GROUPS="social-profile lifecycle-governance-smoke" \
STOP_ON_FAILURE=false \
./run_perf_scenarios.sh
```

Phase 4: ordinary group realtime delivery. This validates 50/100/500 active
member groups with full realtime delivery, without entering the large-group
compact/pull path:

```bash
BASE_URL=https://chat.yourdomain.com \
TCP_HOST=tcp.yourdomain.com \
ACCOUNT_FILE="$PWD/accounts/load-5000.csv" \
IM_CONVERSATION_ID="$IM_CONVERSATION_ID" \
SCENARIO_GROUPS="group-delivery-smoke group-delivery-baseline" \
STOP_ON_FAILURE=false \
./run_perf_scenarios.sh
```

Phase 5: realtime direct delivery. This focuses on idle online, reconnect,
multi-device online, multi-device delivery, and pair delivery without large
group fanout:

```bash
BASE_URL=https://chat.yourdomain.com \
TCP_HOST=tcp.yourdomain.com \
ACCOUNT_FILE="$PWD/accounts/load-5000.csv" \
IM_CONVERSATION_ID="$IM_CONVERSATION_ID" \
SCENARIO_GROUPS="realtime-direct" \
STOP_ON_FAILURE=false \
./run_perf_scenarios.sh
```

Final phase: full non-large-group baseline. Run this only after the earlier
phases are green or understood, because it is intentionally broad:

```bash
BASE_URL=https://chat.yourdomain.com \
TCP_HOST=tcp.yourdomain.com \
ACCOUNT_FILE="$PWD/accounts/load-5000.csv" \
IM_CONVERSATION_ID="$IM_CONVERSATION_ID" \
PERF_STATUS_FILTER_TARGET=true \
PERF_PRODUCTION_GATE_PROFILE=normal-product-baseline \
./run_production_profile.sh
```

After each phase, open `results/dashboard.md` first, then drill into
`results/slo-domain-scorecard.md`, `results/next-actions.md`, and
`results/domain-backlog.md`. If a phase fails, rerun only that domain group at
baseline strength before changing server code.

For a new server or a new `BASE_URL`/`TCP_HOST`, treat old evidence as stale and
restart with target-scoped status. This prevents an old host's PASS result from
masking a new deployment or reverse-proxy problem:

```bash
cd IMServer/LoadTests

BASE_URL=https://chat.yourdomain.com \
ACCOUNT_FILE="$PWD/accounts/load-5000.csv" \
PROBE_FAIL_ON_ENTRYPOINT_ERROR=true \
./http_entrypoint_probe.sh

python3 perf_scenario_status.py \
  --results-dir results \
  --matrix-script ./run_perf_scenarios.sh \
  --filter-target \
  --base-url https://chat.yourdomain.com \
  --tcp-host tcp.yourdomain.com \
  --tcp-port 9000 \
  --output results/scenario-status-target.md \
  --json-output results/scenario-status-target.json

python3 perf_slo_status.py \
  --results-dir results \
  --matrix-script ./run_perf_scenarios.sh \
  --filter-target \
  --base-url https://chat.yourdomain.com \
  --tcp-host tcp.yourdomain.com \
  --tcp-port 9000 \
  --output results/slo-status-target.md \
  --json-output results/slo-status-target.json
```

Once the entrypoint probe passes, use this progression for broader coverage:

1. `SCENARIO_GROUPS="daily-core-smoke"`: minimal daily chat path.
2. `SCENARIO_GROUPS="daily-traffic-smoke"`: mixed daily usage without large
   group fanout.
3. `SCENARIO_GROUPS="sync-recovery"`: offline catch-up, cold start, pagination,
   domain events, and client health.
4. `SCENARIO_GROUPS="message-workflow"`: send, receive, summary convergence,
   read state, search, forward, governance, and small group.
5. `SCENARIO_GROUPS="social-profile"`: contacts, profile propagation, block,
   report, and access-control enforcement.
6. `SCENARIO_GROUPS="realtime-direct"`: online, reconnect, multi-device, and
   point-to-point delivery.
7. `PERF_PRODUCTION_GATE_PROFILE=normal-product-baseline ./run_production_profile.sh`:
   full non-large-group product evidence with
   prerequisite audit, target filtering, entrypoint probe, resumable batches,
   SLO gate, and evidence packaging.

`run_production_profile.sh` runs `http_entrypoint_probe.sh` before the first
batch by default. If `/nginx-health`, `/health`, or `/api/auth/login` indicate
that public HTTP traffic is not reaching IMServer, the profile fails immediately
with `reason=entrypoint_probe_failed`; fix deployment exposure before running
longer scenarios.

`http_entrypoint_probe.sh` also samples protocol banners on the public HTTP
port plus `PROBE_PROTOCOL_PORTS` (`22 9000` by default). If the probe reports
`diagnosis=cloud_edge_http_403_intercept`, SSH, HTTP, and IM TCP are all being
answered by the same empty HTTP `403` layer. Treat that as a cloud-console
access/routing issue, not an IMServer or capacity result. TCP connect success is
not valid IM evidence until the sampled IM TCP port stops reporting
`http_403_intercepted`. When `PROBE_JSON_OUTPUT` is set, the JSON artifact also
includes top-level `tcpStatus`, `edgeIntercept`, `additionalProtocolHosts`, and
`portProtocols` fields plus the legacy `signals` object. Failed entrypoint
probes set `type=entrypoint`, `severity=P0`,
`preventsPerformanceEvidence=true`, and an action such as
`cloud_console_rescue_required`, so runbooks and evidence gates can stop without
re-parsing the diagnosis text.
For production acceptance, `run_current_production_readiness.sh` enables
`PROBE_REQUIRE_PUBLIC_PORT_POLICY=true` automatically whenever cloud security
group evidence is required. The probe then requires
`CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_PUBLIC_CLIENT_PORTS` (`80 443 9000` by
default) to be reachable and rejects
`CURRENT_PRODUCTION_CLOUD_SECURITY_GROUP_DENY_PUBLIC_PORTS` (`3389 5432 6379
9092 8081 8082 18080 8080` by default) if any are reachable. If the operator
route is still a local TUN/proxy path such as `utun*` or `198.18.0.1`, the port
policy returns `public_port_policy_blocked_by_local_network` instead of trusting
possibly intercepted port results.

These presets add `mixed-workload-*`, `offline-catchup-*`, `inbox-fanout-*`,
and `multi-device-sync-*`:

- `mixed-workload-*`: weighted daily-active HTTP traffic across conversation
  list/changes, contacts, domain-events, timeline reads, optional internal
  message writes, client health, and `/api/me`.
- `offline-catchup-*`: messages are written while the client is logically
  offline, then the client foregrounds and pulls conversation list, changes,
  timeline, `messages/since`, and domain-events.
- `inbox-fanout-*`: writes across many conversations, then reads conversation
  list, changes, and multiple `messages/since` pages. This targets the normal
  inbox surface where one user has many active chats, which is a different
  bottleneck from a single hot group.
- `multi-device-sync-*`: logs the same account in on two devices, accepts a
  peer message, verifies timeline and conversation summary on both devices,
  then marks read on one device and waits for the other device's summary and
  `conversations/changes` feed to converge.

When a real-world run fails, narrow it with a domain preset instead of jumping
straight back to large-group tuning:

```bash
SCENARIO_GROUPS="sync-recovery" ./run_perf_scenarios.sh
SCENARIO_GROUPS="message-workflow" ./run_perf_scenarios.sh
SCENARIO_GROUPS="social-profile" ./run_perf_scenarios.sh
SCENARIO_GROUPS="realtime-direct" ./run_perf_scenarios.sh
SCENARIO_GROUPS="sync-recovery-baseline" ./run_perf_scenarios.sh
SCENARIO_GROUPS="message-workflow-baseline" ./run_perf_scenarios.sh
SCENARIO_GROUPS="social-profile-baseline" ./run_perf_scenarios.sh
SCENARIO_GROUPS="realtime-direct-baseline" ./run_perf_scenarios.sh
```

The realtime preset includes reconnect recovery coverage:

- `reconnect-soak-1000` and `reconnect-soak-5000` keep online users connected
  with `MAX_RECONNECTS=3`. These are steady-state soak runs; reconnect count may
  legitimately be `0` if the gateway and network stay stable.
- `reconnect-drill-1000` sets `MIN_RECONNECTS=1`. Run it while deliberately
  restarting/failing over the gateway or applying a controlled network disruption.
  It fails when no reconnect is observed, which makes it suitable for validating
  recovery behavior instead of only idle stability.

Example drill:

```bash
RECONNECT_HOLD_SECONDS=900 \
RECONNECT_DRILL_MIN_RECONNECTS=1 \
SCENARIOS="reconnect-drill-1000" \
./run_perf_scenarios.sh
```

Before trusting changes to the load-test matrix or report tooling, run the local
validator:

```bash
./validate_load_tests.sh
```

It checks shell syntax, Python syntax, k6 script metadata, coverage, route audit,
matrix audit, production gate/package self-tests, and a dry-run evidence bundle.
It clears its own `results/validate-load-tests` directory by default so stale
self-test artifacts cannot make a new validation pass. Set
`VALIDATE_CLEAN_RESULT_DIR=false` only when intentionally inspecting prior
validator output. Optional deeper checks:

```bash
VALIDATE_TCP_LADDER_TEST=true ./validate_load_tests.sh
VALIDATE_SWIFT_BUILD=true ./validate_load_tests.sh
```

The run directory is `results/<RUN_ID>/`. Each scenario contains:

- `scenario.json`: scenario metadata and target.
- `command.sh`: exact command line used for the scenario.
- `stdout.log`: raw command output.
- `exit-code.txt`: command exit code.
- `tcp-logs/**/*.jsonl`: TCPDriver lifecycle and `run_finish` summaries when
  the scenario uses TCP.
- `k6-summary.json`: k6 metrics when the scenario uses k6.

The run root also contains:

- `report.md`: human-readable summary.
- `report.json`: machine-readable summary with per-scenario status, reasons,
  selected metrics, and category totals.
- `report.csv`: flat per-scenario summary for spreadsheet comparison across
  runs.
- `triage.md`, `triage.json`, `triage.csv`: action queue for failed or unknown
  scenarios. Disable with `PERF_TRIAGE=false`.
- `slo.md`, `slo.json`, `slo.csv`: SLO evaluation for every scenario in this
  run. It turns raw k6/TCP metrics into `PASS`, `FAIL`, or `UNKNOWN` against the
  default IM latency, failure-rate, connection, heartbeat, and delivery targets.
  Disable with `PERF_SLO=false`.
- `evidence.md`, `evidence.json`: final evidence bundle that combines runtime
  results, triage, coverage, route audit, and matrix audit. Disable with
  `PERF_EVIDENCE=false`.
- `coverage.*`, `route-audit.*`, `matrix-audit.*`: per-run coverage and matrix
  consistency snapshots. Disable with `PERF_AUDITS=false`.
- `scenario-catalog.*`: product-domain catalog for the whole matrix. It groups
  scenarios by business domain, scenario family, maturity level, and latest
  runtime status when `scenario-status.json` exists.

The result root also contains global rollups refreshed after every run when
`PERF_GLOBAL_STATUS=true`:

- `dashboard.md`, `dashboard.json`: first page to open. It summarizes readiness,
  scenario status, priority counts, blockers, domain readiness, top actions, and
  the next command.
- `state-summary.md`, `state-summary.json`, `state-summary.csv`: compact current
  state for answering "what have we tested, what passed, what is blocked, and
  what should run next". It combines scenario status, SLO status, domain SLO
  readiness, readiness gate, top actions, and the next command into one report.
  When `PERF_CURRENT_READINESS_JSON` or
  `CURRENT_PRODUCTION_READINESS_JSON` points at an existing
  `current-production-readiness.json`, the summary also reports
  `currentReadinessFreshnessStatus`, `currentReadinessAgeSeconds`, and the
  max-age window. The default window is
  `PERF_CURRENT_READINESS_MAX_AGE_SECONDS=86400` with
  `PERF_CURRENT_READINESS_FUTURE_SKEW_SECONDS=300`, matching the production
  readiness status gate. If no explicit receipt path is set and the fixed
  default path is absent, the runner automatically attaches the newest matching
  `current-production-readiness.json` and `production-acceptance.json` under the
  result root, so run-id directories still appear in the global summary.
- `scenario-status.md`, `scenario-status.json`, `scenario-status.csv`: latest
  known status for every scenario in the matrix, including `NEVER_RUN`.
- `slo-status.md`, `slo-status.json`, `slo-status.csv`: latest known SLO status
  for every scenario in the matrix. This answers which scenarios are currently
  meeting targets, failing targets, missing runtime evidence, or never run.
- `slo-domain-scorecard.md`, `slo-domain-scorecard.json`,
  `slo-domain-scorecard.csv`: domain-level SLO readiness. It answers whether
  each product domain needs optimization, runtime evidence, or initial runs.
- `slo-domain-run-plan.md`, `slo-domain-run-plan.json`: next safe domain batches
  derived from SLO state. If extra/preflight SLO failures exist, it stops at the
  entrypoint probe.
- `production-gate.md`, `production-gate.json`, `production-gate.csv`: strict
  production evidence gate for required scenarios. It defaults to
  `PERF_PRODUCTION_GATE_PROFILE=normal-product-baseline`, so the full
  non-large-group product breadth must have latest real SLO `PASS` evidence
  before production readiness is claimed: auth/session, account lifecycle,
  sync/read, direct chat, group lifecycle, contacts/profile, governance,
  safety/moderation, media, AI/admin, hot writes, TCP online/reconnect,
  multi-device, and pair delivery. Use
  `PERF_PRODUCTION_GATE_PROFILE=non-large-group-baseline` only for the older
  compatibility gate, and set
  `PERF_PRODUCTION_GATE_PROFILE=product-breadth-baseline` only as the explicit
  alias for the same non-large-group product breadth gate. The JSON includes
  `generatedAt`, `requiredScenarios[].latestMtime`,
  and summary evidence time bounds; deployment verifiers use those content
  timestamps, not copied file mtimes, to reject stale production evidence.
  It also copies `slo-status.json.targetFilter` into
  `production-gate.json.targetFilter`. Final production evidence should be
  generated with `PERF_STATUS_FILTER_TARGET=true` so old runs from another
  `BASE_URL`/`TCP_HOST`/`TCP_PORT` cannot satisfy the current target gate.
  When `run_perf_scenarios.sh` generates this gate, it defaults
  `PERF_PRODUCTION_GATE_REQUIRE_RUN_ARTIFACTS=true` and
  `PERF_PRODUCTION_GATE_MAX_AGE_SECONDS=604800`, so every passing required
  scenario must still have fresh, real `latestRunDir` evidence with `slo.json`,
  `report.json`, and the per-scenario `scenario.json`, `command.sh`, and
  `exit-code.txt` artifacts. This keeps production claims tied to inspectable
  run output instead of summary-only JSON. Failed required scenarios include
  `requiredScenarios[].failureKind` and `summary.failureKindCounts`, with values
  such as `missing_runtime_evidence`, `slo_not_pass`, `artifact_missing`, and
  `missing_scenario`, so the next action is clear from the gate artifact itself.
  Required scenario membership is defined by `perf_production_profiles.json`; the
  deployment verifier rejects gate files that omit or add required scenarios for
  the selected profile. The gate JSON also stores the production profile catalog
  SHA-256, and deployment rejects evidence generated against a different catalog.
  The JSON records `source.gitCommit`, `source.gitBranch`, and `source.gitDirty`
  so production readiness checks can tie performance evidence to the exact code
  version that generated it. Deployment can require the evidence commit to match
  the checkout with `PERF_PRODUCTION_GATE_REQUIRE_CURRENT_GIT=true`, and can
  reject dirty-worktree evidence with `PERF_PRODUCTION_GATE_REQUIRE_CLEAN_GIT=true`.
  `validate_load_tests.sh` runs
  `perf_production_profiles_audit.py` to verify every production profile scenario
  is present in `run_perf_scenarios.sh --list`, so profile edits fail locally
  before a broken gate can reach deployment.
- `production-evidence/production-evidence-*.tar.gz`: deployable evidence
  package created by `package_production_evidence.sh` after the selected
  production gate passes. It verifies `production-gate.json`, copies the gate,
  dashboard, SLO, domain scorecard, state, scenario status, the required
  `perf_production_profiles.json` snapshot, and required
  `validation-inventory.*`, `docs-audit.*`, and `product-profile-gate.*`
  artifacts. It writes `production-evidence-manifest.json`, a structured
  manifest that records the profile, source commit, profile catalog SHA,
  product-profile gate status, and SHA-256 for every payload file in the package,
  and also retains production profile audit artifacts such as
  `production-profile-run.json`, `production-profile-plan.json`,
  `production-profile-entrypoint-probe.log`,
  `production-profile-entrypoint-probe.json`,
  `production-profile-runbook.*`, `production-profile-prereq-plan.json`,
  `production-profile-prereq-audit.*`, and
  `production-profile-scenario-catalog.json` when they were generated by
  `run_production_profile.sh`. When `run_product_campaign.py --execute` has
  generated `product-campaign-run.json` and `product-campaign-runbook.md`, the
  package requires them by default and verifies that the campaign receipt is a
  real executed production-gate `PASS`, not a `PLANNED` command plan, and that
  the packageable campaign root actually contains the materialized
  production-profile and product-plan evidence files named by the receipt. The
  manifest and package README also record the production-profile entrypoint
  diagnosis, TCP status, edge-intercept classification, sampled protocol count,
  blocker, product-plan scenario count, `largeGroupIncluded`,
  product-domain count, missing product domains, `requiredProductDomainsCovered`,
  and the product campaign effective target (`baseURL`, `tcpHost`, and
  `tcpPort`). Verification rejects packages where that target differs from
  `product-campaign-run.json` or from
  `production-gate.json.targetFilter`; final production evidence rejects empty,
  large-group-only, or partial-domain
  product-plan evidence even when all files are present. Set
  `PRODUCTION_EVIDENCE_REQUIRE_PRODUCT_CAMPAIGN_ARTIFACTS=false` only for a
  controlled diagnostic/profile package that is not final production acceptance
  evidence. Standalone `run_production_profile.sh` and
  `run_product_test_plan.sh` package paths explicitly opt out by default because
  they are lower-level runners; use `run_product_campaign.py --campaign
  non-large-group-release --execute` for final packageable evidence. The package
  step generates and verifies
  `validation-inventory.json` at packaging time so the evidence records the exact
  shell, Python, and k6 scripts used by the repository checkout. It also verifies
  that the validation inventory source commit and dirty flag match
  `production-gate.json`, so the packaged script hashes and run result cannot
  silently come from different checkouts. It verifies the packaged
  `docs-audit.json` at packaging time so README scenario-group commands and
  production-profile references are consistent with `run_perf_scenarios.sh
  --list` and `perf_production_profiles.json`. It verifies the packaged
  `product-profile-gate.json` at packaging time so `normal-product-smoke`,
  `normal-product-baseline`, and `normal-product-capacity` continue to cover
  the required product domains and do not include isolated `large-group-*`
  stress scenarios. It verifies the packaged
  `perf_production_profiles.json` snapshot against
  `production-gate.json.profileCatalog.sha256`, so the evidence remains
  auditable even if the repository profile catalog changes later. By default it
  also verifies the profile artifacts before writing the tarball, so missing run
  receipts, dry-run receipts, blocked prereq audits, partial selected/batch
  mismatches, profile mismatches, disabled target filtering, and mismatched
  gate/runbook targets fail locally before deployment. The packaged run receipt
  must also record `package.status=PACKAGED` and the package path before the
  target host will accept it; during packaging that path must match the actual
  tarball path. Before the tarball is written, `perf_secret_scan.py` scans the
  staged evidence for private-key markers, obvious token/password/secret fields,
  symlink artifacts, special file artifacts such as FIFOs/devices/sockets,
  non-example `.env`/`*.env` artifacts, forbidden login-cache/token-cache
  artifact paths, generated account CSV/account artifact paths, and any real
  secret values present in the operator shell, while allowing safe placeholders such as
  `${IM_INTERNAL_SECRET:?set-IM_INTERNAL_SECRET}`. A `login-cache/` directory,
  `tcp-login-cache*.json`, `tcp_login_cache*.json`, or
  `access-token-cache*.json` file fails even if its content is empty, because token
  cache files are runtime inputs and never production evidence. An `accounts/`
  directory, `load-*.csv`, `load-accounts.csv`,
  `provisioned-accounts.csv`, or `account-credentials.csv` file also fails even
  when the file is harmless-looking, because load-test account lists are
  sensitive runtime inputs and never production evidence. The package
  includes `secret-scan.log` as a required manifest file; installers reject
  packages that omit it or do not record `perf_secret_scan result=pass`.
  Installers and the post-install evidence verifier also rerun
  `perf_secret_scan.py` against the extracted evidence using the target host's
  current environment, so a forged scan log or target-secret leak still fails
  before the evidence is accepted. The package writes a short `README.md` and includes `SHA256SUMS`;
  installers verify both `SHA256SUMS` and `production-evidence-manifest.json`.
  Install it on the target host with
  `deploy/ubuntu/69_install_performance_evidence_package.sh`; that script
  verifies checksums, installs the gate JSON through the production verifier, and
  retains the full evidence directory for audits.
- `next-actions.md`, `next-actions.json`, `next-actions.csv`: cross-scenario
  priority queue derived from the latest status view.
- `scenario-catalog.md`, `scenario-catalog.json`, `scenario-catalog.csv`:
  business-domain and maturity catalog refreshed with latest status.
- `domain-backlog.md`, `domain-backlog.json`, `domain-backlog.csv`: domain-level
  optimization queue derived from the scenario catalog and next actions.
- `optimization-playbook.md`, `optimization-playbook.json`,
  `optimization-playbook.csv`: actionable work queue with code areas, metrics,
  and commands for the highest-priority blockers or missing evidence.
- `domain-scorecard.md`, `domain-scorecard.json`, `domain-scorecard.csv`:
  domain readiness summary that turns backlog state into a current go/no-go
  conclusion.
- `prereq-audit.md`, `prereq-audit.json`, `prereq-audit.csv`: planned scenario
  prerequisite audit for required account files, conversation IDs, internal
  secrets, and auth email code sources.
- `run-plan.md`, `run-plan.json`: next safe command to run. If `P0` blockers
  exist it stops at the entrypoint probe instead of proposing another matrix.

When running local dry-runs but planning against a remote host, keep the plan
target stable with:

```bash
PERF_PLAN_BASE_URL=https://chat.yourdomain.com
PERF_PLAN_TCP_HOST=tcp.yourdomain.com
PERF_PLAN_ACCOUNT_FILE="$PWD/accounts/load-1000.csv"
```

After any run, start with:

```bash
open results/dashboard.md
```

`dashboard.md` is the compact operations view. It does not replace the detailed
reports; it links to scenario status, next actions, catalog, backlog, run plans,
scorecard, prerequisite audit, readiness gate, and optimization playbook so you
can drill into the specific failing domain.

By default `PERF_PREFLIGHT=true` performs local scenario-requirement checks and,
for non-dry-run executions, one HTTP login before the matrix starts. If the HTTP
login fails, the script writes a `preflight-http-login` scenario and stops. Fix
the base URL, route exposure, credentials, or access control before treating any
performance number as valid. Use `PERF_PREFLIGHT=false` only when deliberately
testing a non-login scenario or reproducing a known broken environment.

The preflight login uses the same request shape as the normal clients:
`{"email":"...","password":"...","device":{"deviceID":"...","deviceName":"...","platform":"load-test","appVersion":"load-test"}}`.
If `/`, `/api/auth/login`, and other paths all return the same `403` with an
empty body, treat it as an HTTP entrypoint or deployment issue first: check the
process bound to `BASE_URL`, reverse proxy/access-control rules, stale service
containers, and whether the load-test accounts have actually been provisioned on
that environment. Do not continue to the scenario matrix until preflight login
returns `200`.

Use the lightweight entrypoint probe before a full matrix when the HTTP port
looks suspicious:

```bash
cd IMServer/LoadTests
BASE_URL=https://chat.yourdomain.com \
ACCOUNT_FILE="$PWD/accounts/load-1000.csv" \
./http_entrypoint_probe.sh
```

Expected healthy signals are `/health` returning `200` with the runtime role and
`POST /api/auth/login` returning `200` for a provisioned load account. A uniform
`403` with `bodyBytes=0` on `/`, `/health`, and `/api/auth/login` means the
request is not reaching the expected IM API route layer. The probe also prints a
TCP port check and response-header hints such as `server`, `via`, `location`,
`content-type`, and `x-request-id`; use these to identify whether Nginx, a WAF,
an upstream proxy, or the wrong process is answering before the Vapor IM API.
The probe also checks the local route and proxy environment before classifying a
uniform empty `403`. If it prints
`diagnosis=local_network_proxy_http_403_intercept`, the workstation route or
proxy is still intercepting the target, for example `utun*` with a
`198.18.0.1` gateway. Disable the local TUN/proxy or rerun from a clean network
before changing cloud security groups, Nginx, or IMServer.
Successful login response bodies are intentionally logged as
`<redacted_success_body>` because they can contain access or refresh tokens.
Non-2xx response bodies are summarized only after token/password/secret fields
are redacted. The probe also masks the account identifier in stdout and JSON
artifacts; the raw account is used only inside the login request. JSON artifacts
also include a `blocker` object so production automation can treat P0 entrypoint
failures as invalid performance evidence before any scenario matrix runs.

Regenerate the report after copying or editing artifacts:

```bash
python3 perf_report.py \
  --run-dir "results/${RUN_ID}" \
  --output "results/${RUN_ID}/report.md" \
  --json-output "results/${RUN_ID}/report.json" \
  --csv-output "results/${RUN_ID}/report.csv"
```

The report contains:

- a scenario table with pass/fail status, TCP rates, selected P99 latency, lag
  clear time, and concise failure notes.
- a category summary table that groups PASS/FAIL/UNKNOWN counts by scenario
  category.
- optimization hints for failed scenarios. These hints are category-specific and
  are meant to identify the next code path to inspect, not to replace service
  metrics or raw logs.
- JSON/CSV exports for regression tracking and quick filtering of failed or
  unknown scenarios.

Evaluate whether the run actually meets SLO:

```bash
python3 perf_slo_report.py \
  --report "results/${RUN_ID}/report.json" \
  --output "results/${RUN_ID}/slo.md" \
  --json-output "results/${RUN_ID}/slo.json" \
  --csv-output "results/${RUN_ID}/slo.csv"
```

`perf_slo_report.py` is the strict "did it meet the target?" view. It applies
default policies per category: HTTP paths are checked for failure rate, k6 check
failures, HTTP P99, and IM metric P99; TCP paths are checked for connection,
ack, delivery, heartbeat, delivery P99, and Kafka lag-clear time where those
metrics exist. Use `--strict` in CI or release gates when any SLO `FAIL` or
`UNKNOWN` should fail the command.

Summarize latest SLO state across all local runs:

```bash
python3 perf_slo_status.py \
  --results-dir results \
  --matrix-script run_perf_scenarios.sh \
  --output results/slo-status.md \
  --json-output results/slo-status.json \
  --csv-output results/slo-status.csv
```

`perf_slo_status.py` is the long-lived "what is our current level?" view for
SLOs. It uses the latest `slo.json` per scenario, includes `NEVER_RUN` for
matrix scenarios that have no SLO evidence yet, and groups results by category
so missing coverage and failing targets do not get mixed together. Matrix
scenario counts exclude preflight-only rows; entrypoint failures such as
`preflight-http-login` are preserved as extra observed scenarios.

Aggregate SLO state by product domain:

```bash
python3 perf_slo_domain_scorecard.py \
  --slo-status-json results/slo-status.json \
  --output results/slo-domain-scorecard.md \
  --json-output results/slo-domain-scorecard.json \
  --csv-output results/slo-domain-scorecard.csv
```

`perf_slo_domain_scorecard.py` is the quickest way to see whether auth/session,
client sync, message workflow, group lifecycle, social/profile, safety, media,
AI stream, TCP realtime, or hot/large-group needs optimization or simply lacks
runtime evidence.

Generate the next SLO-driven domain run plan:

```bash
python3 perf_slo_domain_run_plan.py \
  --slo-status-json results/slo-status.json \
  --slo-domain-scorecard-json results/slo-domain-scorecard.json \
  --base-url https://chat.yourdomain.com \
  --tcp-host tcp.yourdomain.com \
  --account-file "$PWD/accounts/load-1000.csv" \
  --conversation-id "$IM_CONVERSATION_ID" \
  --internal-secret "$IM_INTERNAL_SECRET" \
  --output results/slo-domain-run-plan.md \
  --json-output results/slo-domain-run-plan.json
```

`perf_slo_domain_run_plan.py` selects small domain batches from the SLO state.
By default it prefers smoke/custom/TCP starter scenarios and avoids baseline or
capacity until you pass `--include-baseline` or `--include-capacity`. This keeps
the next run focused on getting real evidence before expanding load.

Compare two completed runs after an optimization:

```bash
python3 perf_compare.py \
  --base "results/${BASE_RUN_ID}/report.json" \
  --current "results/${CURRENT_RUN_ID}/report.json" \
  --output "results/${CURRENT_RUN_ID}/compare-${BASE_RUN_ID}.md" \
  --csv-output "results/${CURRENT_RUN_ID}/compare-${BASE_RUN_ID}.csv"
```

`perf_compare.py` marks regressions when status gets worse, HTTP failure rate
increases, or the primary P99 grows by at least 10% by default. Override with
`--p99-regression-ratio 0.2` for a 20% threshold.

Compare two completed runs by product domain:

```bash
python3 perf_domain_compare.py \
  --base "results/${BASE_RUN_ID}/report.json" \
  --current "results/${CURRENT_RUN_ID}/report.json" \
  --scenario-catalog results/scenario-catalog.json \
  --output "results/${CURRENT_RUN_ID}/domain-compare-${BASE_RUN_ID}.md" \
  --json-output "results/${CURRENT_RUN_ID}/domain-compare-${BASE_RUN_ID}.json" \
  --csv-output "results/${CURRENT_RUN_ID}/domain-compare-${BASE_RUN_ID}.csv"
```

`perf_domain_compare.py` uses the same scenario-level classification as
`perf_compare.py`, then aggregates regressions, improvements, scope changes,
P99 deltas, and HTTP failure-rate deltas by business domain. Use it after an
optimization to answer whether the target domain improved without introducing
regressions in auth/session, client sync, message workflow, TCP realtime, or
hot/large-group paths.

Summarize all local runs:

```bash
python3 perf_history.py \
  --results-dir results \
  --limit 20 \
  --output results/history.md \
  --csv-output results/history.csv
```

`perf_history.py` scans every `results/*/report.json`, prints per-run
PASS/FAIL/UNKNOWN counts, marks runs blocked by entrypoint failures, includes
evidence outcomes such as `BLOCKED_ENTRYPOINT` or `NEEDS_OPTIMIZATION`, lists
failed categories for quick triage, and adds a category summary so a broad test
pass shows where failures or missing artifacts are concentrated. It displays the
latest runs first by default; use `--oldest-first` only when reconstructing a
timeline from the beginning.

Summarize the latest known status of every scenario across all local runs:

```bash
python3 perf_scenario_status.py \
  --results-dir results \
  --matrix-script run_perf_scenarios.sh \
  --limit 50 \
  --output results/scenario-status.md \
  --json-output results/scenario-status.json \
  --csv-output results/scenario-status.csv
```

`perf_scenario_status.py` answers a different question than history: it groups by
scenario name, shows each scenario's latest PASS/FAIL/UNKNOWN state, run count,
last reason, selected P99 values, and category summary. Use it after running a
large matrix to decide which scenarios are still not production evidence and
which category should be optimized first. When `--matrix-script` is provided,
scenarios listed by `run_perf_scenarios.sh --list` but absent from all reports
are marked `NEVER_RUN`, which prevents untested scenarios from disappearing from
the status view.

Generate a cross-scenario action queue:

```bash
python3 perf_next_actions.py \
  --scenario-status results/scenario-status.json \
  --limit 50 \
  --output results/next-actions.md \
  --json-output results/next-actions.json \
  --csv-output results/next-actions.csv
```

`perf_next_actions.py` converts the scenario status view into priorities:
entrypoint failures are `P0`, real failed scenarios are `P1`, missing artifacts
or never-run smoke/custom scenarios are `P2`, and never-run baseline/capacity
scenarios are `P3`. Use this as the working queue before changing service code
or expanding the next matrix run.

Catalog the matrix by product domain and maturity:

```bash
python3 perf_scenario_catalog.py \
  --script run_perf_scenarios.sh \
  --scenario-status results/scenario-status.json \
  --output results/scenario-catalog.md \
  --json-output results/scenario-catalog.json \
  --csv-output results/scenario-catalog.csv
```

`perf_scenario_catalog.py` is the planning view for “not only large groups”.
It shows whether auth/session, client sync, message workflow, group lifecycle,
social/profile, safety/moderation, media/file, AI stream, TCP realtime, and
hot/large-group paths are represented. It also reports HTTP maturity gaps, for
example a workflow that has `smoke` and `baseline` variants but no `capacity`
variant yet. Treat these gaps as backlog items, not runtime failures.

Gate the ordinary product production profiles against the required scenario
domains:

```bash
python3 perf_product_profile_gate.py \
  --profile normal-product-smoke \
  --profile normal-product-baseline \
  --profile normal-product-capacity \
  --require-no-maturity-gaps \
  --output results/product-profile-gate.md \
  --json-output results/product-profile-gate.json \
  --csv-output results/product-profile-gate.csv \
  --strict
```

`perf_product_profile_gate.py` is a configuration gate, not runtime evidence. It
prevents the default production profiles from drifting back to a narrow test set
or accidentally including isolated `large-group-*` stress scenarios. By default
it requires auth/session, client sync, message workflow, group lifecycle, normal
group realtime, social/profile, safety/moderation, media/file, TCP realtime, and
AI stream coverage before `validate_load_tests.sh` passes.

Aggregate the optimization backlog by product domain:

```bash
python3 perf_domain_backlog.py \
  --scenario-catalog results/scenario-catalog.json \
  --next-actions results/next-actions.json \
  --output results/domain-backlog.md \
  --json-output results/domain-backlog.json \
  --csv-output results/domain-backlog.csv
```

`perf_domain_backlog.py` is the optimization planning view. It keeps `P0`
entrypoint blockers visible globally, then groups open work by domain with
`P1/P2/P3` counts and a domain-specific optimization focus. Use it to decide
whether the next engineering work should target auth/session, client sync,
message workflow, group lifecycle, TCP realtime, or hot/large-group delivery.

Generate a concrete optimization playbook:

```bash
python3 perf_optimization_playbook.py \
  --dashboard-json results/dashboard.json \
  --domain-backlog-json results/domain-backlog.json \
  --run-plan-json results/run-plan.json \
  --domain-run-plan-json results/domain-run-plan.json \
  --prereq-audit-json results/prereq-audit.json \
  --readiness-gate-json results/readiness-gate.json \
  --output results/optimization-playbook.md \
  --json-output results/optimization-playbook.json \
  --csv-output results/optimization-playbook.csv
```

`perf_optimization_playbook.py` turns the domain backlog into an engineering
queue. Each item includes the priority, product domain, scenario, likely code
areas, metrics to inspect, and the next command to run. Use this after a
multi-domain run to avoid treating large-group delivery as the only performance
surface. When `slo-status.json` is available, SLO `FAIL` scenarios are also
added as `P1` optimization work even if the original command completed.

Generate domain-scoped run batches:

```bash
python3 perf_domain_run_plan.py \
  --domain-backlog results/domain-backlog.json \
  --base-url https://chat.yourdomain.com \
  --tcp-host tcp.yourdomain.com \
  --account-file "$PWD/accounts/load-1000.csv" \
  --conversation-id "$IM_CONVERSATION_ID" \
  --internal-secret "$IM_INTERNAL_SECRET" \
  --blocker-max-age-seconds 3600 \
  --ignore-blockers-for-different-target \
  --output results/domain-run-plan.md \
  --json-output results/domain-run-plan.json
```

`perf_domain_run_plan.py` keeps the same `P0` safety behavior as
`perf_run_plan.py`: if the entrypoint is broken, it only emits the probe command.
After the entrypoint is healthy, it emits small per-domain batches so you can run
one area, refresh status, then optimize only the domains that fail. Use
`--domain client-sync` to focus one area, `--include-p3` to include never-run
baseline/capacity work, and `--include-capacity` when the load generator and
server are ready for heavier capacity profiles. Account lifecycle confirm
scenarios are skipped by default because they require an auth email code source;
add `--include-auth-confirm` only after `IM_AUTH_EMAIL_WEBHOOK_SINK_URL` or fixed
verification/reset code envs are configured.
The default is fail-closed: every recorded `P0` entrypoint blocker remains
active. When you intentionally switch to a new target host or want old failed
preflight probes to stop blocking a fresh plan, set
`--blocker-max-age-seconds` or `PERF_PLAN_BLOCKER_MAX_AGE_SECONDS`. Reports now
record a run-level target fingerprint (`baseURL`, `tcpHost`, `tcpPort`) and
scenario status/next-actions preserve the latest target for each scenario. When
you intentionally move to a different target, set
`--ignore-blockers-for-different-target` or
`PERF_PLAN_IGNORE_BLOCKERS_FOR_DIFFERENT_TARGET=true` so old P0 preflight
failures from the previous host stop blocking the new host plan. Stale or
different-target blockers are not discarded; they are written to
`staleGlobalBlockers` in `domain-run-plan.json` and listed in the Markdown for
audit.
For production evidence on a specific host, also set
`PERF_STATUS_FILTER_TARGET=true` when running `run_perf_scenarios.sh`, or pass
`--filter-target --base-url ... --tcp-host ... --tcp-port ...` directly to
`perf_scenario_status.py` and `perf_slo_status.py`. This prevents successful or
failed runs from an older server from being counted as the current target's
latest evidence.

Summarize domain readiness:

```bash
python3 perf_domain_scorecard.py \
  --domain-backlog results/domain-backlog.json \
  --domain-run-plan results/domain-run-plan.json \
  --output results/domain-scorecard.md \
  --json-output results/domain-scorecard.json \
  --csv-output results/domain-scorecard.csv
```

`perf_domain_scorecard.py` is the answer to “what is the current level?” It
labels the overall state and each domain as `BLOCKED_BY_GLOBAL_P0`,
`NEEDS_OPTIMIZATION`, `NEEDS_RUNTIME_EVIDENCE`, `NEEDS_BASELINE_CAPACITY`, or
`READY`. Treat `READY` as valid only for the scenarios currently represented in
the matrix; use `scenario-catalog.md` to confirm scope before calling a domain
production-ready.

Run the global readiness gate:

```bash
python3 perf_readiness_gate.py \
  --coverage-json results/latest/coverage.json \
  --route-audit-json results/latest/route-audit.json \
  --matrix-audit-json results/latest/matrix-audit.json \
  --domain-scorecard-json results/domain-scorecard.json \
  --prereq-audit-json results/prereq-audit.json \
  --slo-status-json results/slo-status.json \
  --slo-domain-scorecard-json results/slo-domain-scorecard.json \
  --output results/readiness-gate.txt \
  --json-output results/readiness-gate.json
```

`perf_readiness_gate.py` is the strict go/no-go check for claiming performance
readiness. It fails if critical coverage, route audit, matrix audit,
prerequisites, domain scorecard, SLO status, or SLO domain scorecard are not
clean. For exploratory runs you can
temporarily pass `--allow-runtime-evidence-gap`,
`--allow-baseline-capacity-gap`, `--allow-no-planned-scenarios`, or
`--allow-entrypoint-blocker`. SLO-specific exploration can additionally pass
`--allow-slo-runtime-evidence-gap`, `--allow-slo-never-run-gap`, or
`--allow-extra-slo-failure`, but do not use those allowances as production
evidence.

Audit prerequisites before running a planned batch:

```bash
python3 perf_prereq_audit.py \
  --scenario-catalog results/scenario-catalog.json \
  --domain-run-plan results/domain-run-plan.json \
  --base-url https://chat.yourdomain.com \
  --tcp-host tcp.yourdomain.com \
  --account-file "$PWD/accounts/load-1000.csv" \
  --conversation-id "$IM_CONVERSATION_ID" \
  --internal-secret "$IM_INTERNAL_SECRET" \
  --output results/prereq-audit.md \
  --json-output results/prereq-audit.json \
  --csv-output results/prereq-audit.csv
```

`perf_prereq_audit.py` prevents configuration gaps from being misread as
performance regressions. TCP online/reconnect scenarios require `ACCOUNT_FILE`;
TCP delivery scenarios require `ACCOUNT_FILE` and `IM_CONVERSATION_ID`; internal
write/read convergence scenarios require `IM_INTERNAL_SECRET`; account-confirm
scenarios require either
`IM_AUTH_EMAIL_WEBHOOK_SINK_URL` or fixed verification/reset code envs. A
`BLOCKED` prereq audit means fix the test setup before treating the scenario as
failed.

Generate the next safe run plan:

```bash
python3 perf_run_plan.py \
  --next-actions results/next-actions.json \
  --base-url https://chat.yourdomain.com \
  --account-file "$PWD/accounts/load-1000.csv" \
  --output results/run-plan.md \
  --json-output results/run-plan.json
```

`perf_run_plan.py` refuses to propose a matrix command while `P0` entrypoint
blockers exist. After the entrypoint is healthy, it selects a bounded batch of
`P1/P2` scenarios and emits a `SCENARIOS="..." ./run_perf_scenarios.sh` command
for the next pass. `run_perf_scenarios.sh` refreshes this plan automatically when
`PERF_GLOBAL_STATUS=true` and `PERF_RUN_PLAN=true`. Use `PERF_PLAN_BASE_URL`,
`PERF_PLAN_TCP_HOST`, `PERF_PLAN_ACCOUNT_FILE`, `PERF_PLAN_CONVERSATION_ID`, and
`PERF_PLAN_INTERNAL_SECRET` to make the generated command target a different
environment than the current dry-run.

Audit whether the current scenario matrix covers the important HTTP/TCP-adjacent
API surface:

```bash
python3 perf_coverage.py \
  --output results/perf-coverage.md \
  --json-output results/perf-coverage.json \
  --csv-output results/perf-coverage.csv \
  --strict
```

`perf_coverage.py` is a route-to-scenario manifest. It does not prove runtime
performance by itself; it tells you whether a service endpoint has at least one
scenario assigned before you trust a matrix as product coverage evidence.
Optional gaps, such as account recovery or admin-only moderation routes, are
reported but do not fail `--strict`. Critical gaps should be resolved by adding a
scenario or explicitly downgrading the endpoint only after deciding it is outside
the current capacity scope.

Audit the manifest against the route inventory after adding server routes:

```bash
python3 perf_route_audit.py \
  --output results/perf-route-audit.md \
  --json-output results/perf-route-audit.json \
  --csv-output results/perf-route-audit.csv \
  --strict
```

`perf_route_audit.py` compares the performance coverage manifest with the
registered HTTP route inventory. It fails `--strict` when a product/internal
route is missing from coverage. Development sample routes such as `/hello*` are
tracked as ignored source routes so they do not dilute production capacity
coverage.

Audit the scenario matrix after adding or renaming load-test scenarios:

```bash
python3 perf_matrix_audit.py \
  --script run_perf_scenarios.sh \
  --k6-dir k6 \
  --output results/perf-matrix-audit.md \
  --json-output results/perf-matrix-audit.json \
  --csv-output results/perf-matrix-audit.csv \
  --strict
```

`perf_matrix_audit.py` verifies that `DEFAULT_SCENARIOS`, scenario groups,
`run_perf_scenarios.sh --list`, case branches, and referenced k6 scripts stay in
sync. Run it with `perf_coverage.py` and `perf_route_audit.py` before trusting a
new matrix as coverage evidence.

Scenarios that call internal routes, such as `admin-report-*`, require
`IM_INTERNAL_SECRET` or `IM_INTERNAL_SHARED_SECRET` to match the server-side
internal shared secret.

Before running a real matrix against a new host, classify the HTTP entrypoint:

```bash
PROBE_FAIL_ON_ENTRYPOINT_ERROR=true \
BASE_URL=http://host:8080 \
ACCOUNT_FILE=accounts/load-1000.csv \
./http_entrypoint_probe.sh
```

The probe prints `diagnosis=...`. `uniform_empty_403` means every probe returned
an empty 403, which is almost always a reverse proxy, WAF, firewall, IP allowlist,
or wrong process bound to the port. Check `tcpStatus`, `serverHint`, and
`viaHint` on the diagnosis line before changing IM application code. Do not run
k6/TCP capacity conclusions until this is fixed.

If SSH is also unavailable, generate a cloud-console rescue artifact from the
current key material. The artifact contains the public key only, a product-plan
failure receipt, a recovery runbook, checksums, and a self-contained script to
paste into the provider console:

```bash
SSH_PRIVATE_KEY_PATH=/path/to/private-key.pem \
PUBLIC_BASE_URL=https://chat.yourdomain.com \
BASE_URL=https://chat.yourdomain.com \
TCP_HOST=tcp.yourdomain.com \
ACCOUNT_FILE="$PWD/accounts/load-5000.csv" \
./generate_node_access_rescue_artifact.sh
```

Open `results/current-node-access-rescue/README.md`, then paste
`results/current-node-access-rescue/cloud-console-node-access-rescue.sh` into the
cloud console. The generator verifies the diagnostic receipt, runs `bash -n` on
the rendered script, writes checksums, and fails if private-key markers appear in
the artifact directory. The generated package verifier safely checks tar members
before extraction, and `verify-artifact.sh` validates every `SHA256SUMS` path
before running checksum verification, so tampered absolute, traversal,
duplicate, oversized, or missing file entries fail before any package file is
trusted.

When you have SSH access to the server, also run the read-only server-side
diagnosis. It gives the missing local view: listener process, internal gateway
health, Nginx proxy rules, service state, logs, Docker state, and firewall rules.

```bash
cd /opt/IMMonorepo
sudo HTTP_PORT=80 \
  PUBLIC_BASE_URL=https://chat.yourdomain.com \
  bash deploy/ubuntu/75_entrypoint_diagnose.sh
```

`account-lifecycle-*` covers registration, email verification resend, and
password reset request. `account-lifecycle-confirm-*` adds email verification
confirm and password reset confirm. It needs access to one-time codes. The
production-like path is to expose a webhook sink from the load generator and
point the server auth email sender at it:

```bash
cd IMServer/LoadTests
python3 auth_email_webhook_sink.py \
  --host 0.0.0.0 \
  --port 18080 \
  --secret "$AUTH_EMAIL_WEBHOOK_SECRET"
```

Server-side env for that run:

```bash
AUTH_EMAIL_DELIVERY_MODE=webhook
AUTH_EMAIL_WEBHOOK_URL=http://LOAD_GENERATOR_IP:18080/auth-email
AUTH_EMAIL_WEBHOOK_SECRET=...
AUTH_REQUIRE_EMAIL_VERIFICATION=true
```

Then run the confirm matrix from the load generator:

```bash
SCENARIO_GROUPS="auth-confirm" \
IM_AUTH_EMAIL_WEBHOOK_SINK_URL=http://127.0.0.1:18080 \
./run_perf_scenarios.sh
```

Use `IM_ACCOUNT_VERIFICATION_CODE` or `IM_ACCOUNT_PASSWORD_RESET_CODE` only for a
controlled test environment that deliberately issues fixed codes.

`timeline-pagination-*` covers the non-large-group client read path for opening a
chat, scrolling older history, reconnect catch-up with `timeline/since`, member
search, and conversation list filtering. It seeds messages through
`/internal/im/messages/send`, so it requires `IM_INTERNAL_SECRET`. Tune
`IM_TIMELINE_SEED_MESSAGES`, `IM_TIMELINE_PAGE_LIMIT`,
`IM_TIMELINE_SINCE_WINDOW`, and `IM_TIMELINE_CONVERSATION_KIND` when validating
longer history pages or direct chats.

`client-sync-mix-*` simulates normal foreground App sync traffic after login:
`/api/me`, contacts, contact changes, conversation list, conversation changes,
domain events, client health, and optional timeline reads when
`IM_CONVERSATION_ID` is set. Use it as the broad HTTP read-path signal before
digging into individual sync scenarios.

Gate a completed report before treating it as production evidence:

```bash
python3 perf_gate.py \
  --report "results/${RUN_ID}/report.json"
```

Turn a completed report into an action queue:

```bash
python3 perf_triage.py \
  --report "results/${RUN_ID}/report.json" \
  --output "results/${RUN_ID}/triage.md" \
  --json-output "results/${RUN_ID}/triage.json" \
  --csv-output "results/${RUN_ID}/triage.csv"
```

`perf_triage.py` reads failed or unknown scenarios, assigns `P0/P1/P2`
priorities, classifies the issue type such as `entrypoint`, `tcp-delivery`,
`k6-threshold`, or `missing-artifacts`, and emits the next optimization action.
Use it after every real run before changing service code or machine size.

Build a single evidence bundle that combines runtime results, triage, coverage,
route audit, and matrix audit:

```bash
python3 perf_evidence_bundle.py \
  --report "results/${RUN_ID}/report.json" \
  --triage-json "results/${RUN_ID}/triage.json" \
  --coverage-json results/perf-coverage.json \
  --route-audit-json results/perf-route-audit.json \
  --matrix-audit-json results/perf-matrix-audit.json \
  --output "results/${RUN_ID}/evidence.md" \
  --json-output "results/${RUN_ID}/evidence.json"
```

`perf_evidence_bundle.py` emits one outcome such as `PASS`,
`BLOCKED_ENTRYPOINT`, `NEEDS_OPTIMIZATION`, `INCOMPLETE_ARTIFACTS`, or
`AUDIT_FAILED`. Use it as the final artifact for each performance run.

The gate fails on any `FAIL`, any `UNKNOWN`, and entrypoint failures such as a
uniform HTTP `403` before the request reaches the IM API layer. For exploratory
or dry-run matrices, allow unknown scenarios explicitly instead of weakening the
default:

```bash
python3 perf_gate.py \
  --report "results/${RUN_ID}/report.json" \
  --allow-unknown-category tcp-online
```

To run the gate automatically after `run_perf_scenarios.sh` creates the report:

```bash
PERF_GATE=true \
SCENARIO_GROUPS="http-baseline tcp-baseline" \
./run_perf_scenarios.sh
```

Use `PERF_GATE_ALLOW_UNKNOWN=true`,
`PERF_GATE_ALLOW_UNKNOWN_CATEGORIES="category-a category-b"`, or
`PERF_GATE_ALLOW_ENTRYPOINT_FAILURE=true` only for controlled diagnostics. They
should not be used for final capacity conclusions.

Default report gates are intentionally strict enough for production evidence:

- connection success rate `>= 99.9%`
- TCP ack success rate `>= 99.9%`
- TCP delivery success rate `>= 99.9%`
- heartbeat ACK rate `>= 99.9%`
- heartbeat send-completion P99 `< 10s`
- pair-delivery P99 `< 3s`
- monitor lag-clear-after-send `<= 15s` when a monitor summary exists
- k6 HTTP failure rate `< 0.5%`

Start with these scenario groups:

```text
Presets: http-smoke, http-baseline, http-capacity, auth-confirm, account-security, account-security-baseline, direct-chat, direct-chat-baseline, daily-core-smoke, daily-core-baseline, reliability-recovery-smoke, reliability-recovery, reliability-recovery-baseline, lifecycle-governance-smoke, lifecycle-governance, lifecycle-governance-baseline, sync-read, sync-read-baseline, group-workflow, group-workflow-baseline, contacts-social, contacts-social-baseline, media-ai-admin, media-ai-admin-baseline, product-smoke, product-baseline, product-breadth-smoke, product-breadth-baseline, product-breadth-capacity, normal-product-smoke, normal-product-baseline, normal-product-capacity, daily-traffic-smoke, daily-traffic-baseline, message-spike-smoke, message-spike, message-spike-baseline, tcp-smoke, tcp-baseline, real-world-smoke, real-world-baseline, real-world-capacity, non-large-group-smoke, non-large-group-baseline, non-large-group-capacity, sync-recovery, sync-recovery-baseline, message-workflow, message-workflow-baseline, social-profile, social-profile-baseline, realtime-direct, realtime-direct-baseline, group-delivery-smoke, group-delivery, group-delivery-baseline, group-delivery-capacity, im-scenario-breadth-smoke, im-scenario-breadth-baseline, im-scenario-breadth-capacity, large-group, all-smoke, all-baseline
Login: login-smoke, login-baseline, login-capacity
Account lifecycle: account-lifecycle-smoke, account-lifecycle-baseline, account-lifecycle-capacity
Account lifecycle confirm: account-lifecycle-confirm-smoke, account-lifecycle-confirm-baseline, account-lifecycle-confirm-capacity
Auth session/device: auth-session-smoke, auth-session-baseline, auth-session-capacity
Auth session management: auth-session-management-smoke, auth-session-management-baseline, auth-session-management-capacity
Auth token rotation: auth-token-rotation-smoke, auth-token-rotation-baseline, auth-token-rotation-capacity
Auth failure/recovery: auth-failure-recovery-smoke, auth-failure-recovery-baseline, auth-failure-recovery-capacity
Push token lifecycle: push-token-smoke, push-token-baseline, push-token-capacity
Client health: client-health-smoke, client-health-baseline, client-health-capacity
Client foreground sync mix: client-sync-mix-smoke, client-sync-mix-baseline, client-sync-mix-capacity
Real user journey: user-journey-smoke, user-journey-baseline, user-journey-capacity
Weighted mixed workload: mixed-workload-smoke, mixed-workload-baseline, mixed-workload-capacity
Offline catch-up: offline-catchup-smoke, offline-catchup-baseline, offline-catchup-capacity
Multi-conversation inbox: inbox-fanout-smoke, inbox-fanout-baseline, inbox-fanout-capacity
Multi-device sync: multi-device-sync-smoke, multi-device-sync-baseline, multi-device-sync-capacity
Conversation convergence: direct-convergence-smoke, direct-convergence-baseline, direct-convergence-capacity, conversation-convergence-smoke, conversation-convergence-baseline, conversation-convergence-capacity
Cold start sync: cold-start-smoke, cold-start-baseline, cold-start-capacity
Timeline pagination/catch-up: timeline-pagination-smoke, timeline-pagination-baseline, timeline-pagination-capacity
Timeline history scroll: timeline-history-scroll-smoke, timeline-history-scroll-baseline, timeline-history-scroll-capacity
Domain event catch-up: domain-events-smoke, domain-events-baseline, domain-events-capacity
Read state sync: read-state-smoke, read-state-baseline, read-state-capacity
Direct message lifecycle: direct-message-lifecycle-smoke, direct-message-lifecycle-baseline, direct-message-lifecycle-capacity
Search sync: search-sync-smoke, search-sync-baseline, search-sync-capacity
Conversation preferences: conversation-preferences-smoke, conversation-preferences-baseline, conversation-preferences-capacity
Conversation visibility: conversation-visibility-smoke, conversation-visibility-baseline, conversation-visibility-capacity
Group admin sync: group-admin-smoke, group-admin-baseline, group-admin-capacity
Group membership lifecycle: group-membership-smoke, group-membership-baseline, group-membership-capacity
Group invite sync: group-invite-smoke, group-invite-baseline, group-invite-capacity
Conversation governance: governance-smoke, governance-baseline, governance-capacity
Message forward sync: message-forward-smoke, message-forward-baseline, message-forward-capacity
AI stream sync: ai-stream-smoke, ai-stream-baseline, ai-stream-capacity
Contact request moderation: contact-request-smoke, contact-request-baseline, contact-request-capacity
Contact sync: contact-sync-smoke, contact-sync-baseline, contact-sync-capacity
Profile sync: profile-sync-smoke, profile-sync-baseline, profile-sync-capacity
Safety block/report: safety-block-smoke, safety-block-baseline, safety-block-capacity
Safety block enforcement: safety-block-enforcement-smoke, safety-block-enforcement-baseline, safety-block-enforcement-capacity
Access-control enforcement: access-control-enforcement-smoke, access-control-enforcement-baseline, access-control-enforcement-capacity
Admin report moderation: admin-report-smoke, admin-report-baseline, admin-report-capacity
Media/file: media-file-smoke, media-file-baseline, media-file-capacity
Media failure/recovery: media-failure-recovery-smoke, media-failure-recovery-baseline, media-failure-recovery-capacity
Small group HTTP: small-group-smoke, small-group-baseline, small-group-capacity
Hot write HTTP: hot-write-smoke, hot-write-baseline, hot-write-capacity
Idle online: online-idle-1000, online-idle-5000, online-idle-10000
Reconnect recovery: reconnect-soak-1000, reconnect-soak-5000, reconnect-drill-1000
Multi-device TCP: multi-device-online-1x5, multi-device-online-100x2, multi-device-delivery-100x2-10
Pair delivery: pair-delivery-1000-10, pair-delivery-1000-50, pair-delivery-1000-100, pair-delivery-2000-50, pair-delivery-3000-50
Large group compact/timeline-pull: large-group-1000-10, large-group-1000-50, large-group-5000-50, large-group-10000-200
```

For broad testing beyond large groups, use the normal-product presets first:

```bash
# Fast cross-domain smoke: auth, sync, single chat, small groups, contacts,
# media, TCP online/reconnect, multi-device, and pair delivery.
SCENARIO_GROUPS="normal-product-smoke" ./run_perf_scenarios.sh

# Baseline breadth without isolated large-group fanout stress.
SCENARIO_GROUPS="normal-product-baseline" ./run_perf_scenarios.sh

# Capacity breadth without isolated large-group fanout stress.
SCENARIO_GROUPS="normal-product-capacity" ./run_perf_scenarios.sh

# Production profile form with resumable batches, production-gate filtering,
# and evidence packaging support.
PERF_PRODUCTION_GATE_PROFILE=normal-product-baseline ./run_production_profile.sh

# Product-plan form with entrypoint gate, prerequisite audit, runbook, and receipt.
PRODUCT_TEST_PHASES="entrypoint normal-product-baseline" ./run_product_test_plan.sh

# Run large-group only after the normal product surface has passed.
SCENARIO_GROUPS="large-group" ./run_perf_scenarios.sh
```

Do not optimize from a single failed number. First identify the failing category:

- login failures or high login P99: optimize HTTP auth, DB/auth-session cache,
  Redis, or account prewarm; do not mix this into TCP online capacity.
- account lifecycle failures: optimize registration password hashing, auth
  security challenge writes, email delivery/webhook latency, rate limiter
  configuration, and account lifecycle indexes. These tests create disposable
  accounts, so use a dedicated prefix/domain on shared environments.
- auth session/device failures: optimize refresh token rotation, session table
  indexes, auth-session validation cache, push token writes, and logout/kick
  side effects before changing TCP online capacity.
- auth session management failures: optimize session list indexes, per-user
  session invalidation, logout-all batch updates, revoked refresh rejection, and
  gateway kick fanout before changing TCP online capacity.
- auth token rotation failures: optimize refresh token rotation writes, old-token
  reuse rejection lookup, revoked-token indexes, auth token issuance latency, and
  session validation cache before changing TCP online capacity.
- auth failure/recovery failures: optimize failed-login rejection latency, auth
  error-path indexes, bad token parsing/validation, rate limiter overhead, and
  recovery login path isolation before changing normal login capacity.
- client-health failures: optimize client-health in-memory metrics aggregation,
  request body decoding, auth validation cache, and report sampling frequency
  before changing realtime delivery.
- client-sync-mix failures: split the failed requests first. Optimize auth
  validation cache and `/api/me` only if every request is slow; otherwise check
  contact changes, conversation list/changes, domain-events pagination, timeline
  latest/since indexes, or client-health writes based on the slow metric.
- online idle failures: optimize gateway accept/backlog, TCP auth lifecycle,
  heartbeat scheduling, load-generator capacity, or kernel limits.
- multi-device online failures: check same-account session policy, duplicate
  device kick rules, auth session indexing, and TCP session directory fanout.
- multi-device delivery failures: check same-account route fanout, device-level
  session registration, duplicate canonical merge behavior, and TCP write
  pressure before changing message persistence.
- pair-delivery ACK failures: optimize command-api write path, sequence
  allocation, Kafka publish/outbox, or hot conversation limiter.
- pair-delivery receive failures or high delivery P99: optimize realtime route
  lookup, gateway fanout, TCP write pressure, or client catch-up.
- conversation convergence failures: optimize summary projection, timeline/since
  cache, query-api read path, or projection lag.
- cold-start sync failures: optimize query-api conversations list,
  conversations/changes token scans, messages/since indexes, response payload
  size, and per-user read cache before touching realtime fanout.
- timeline pagination/catch-up failures: optimize timeline latest/history
  indexes, `timeline/since` target-sequence reads, member search indexes,
  conversation list filters, and read-model cache hit rate before changing
  realtime fanout.
- timeline history scroll failures: optimize timeline history pagination
  indexes, `beforeSequence` boundary handling, timeline/since cache correctness,
  duplicate page protection, and visibility scan limits before changing realtime
  fanout.
- domain-events catch-up failures: optimize owner domain event delivery writes,
  owner cursor allocation, summary-shard read indexes, deferred event page size,
  and client replay/backfill behavior before changing large-group realtime
  fanout.
- read-state sync failures: optimize mark-read command writes, summary
  projection/read overlay, conversations/changes propagation, and unread count
  consistency before changing realtime message delivery.
- direct message lifecycle failures: optimize direct conversation creation/reuse,
  command-api message writes, owner summary projection, timeline/since reads,
  unread/read-state propagation, and conversations/changes latency before
  changing large-group fanout.
- access-control enforcement failures: optimize membership permission checks,
  non-member query rejection, role update propagation, member-cache invalidation,
  and removed-member access denial before changing gateway or fanout settings.
- search sync failures: optimize search-index-consumer lag, search index write
  batching, query-api search adapter latency, and search index database/OpenSearch
  configuration before changing message fanout.
- group-admin sync failures: optimize membership command transactions,
  member-cache invalidation, summary projection for metadata/preferences,
  conversations/changes propagation, and member page indexes.
- group-membership lifecycle failures: optimize member profile writes, role
  update privilege checks, remove/leave membership transactions, member-cache
  invalidation fanout, member page indexes, and conversations/changes projection
  before changing large-group realtime delivery.
- group-invite sync failures: optimize invite table indexes, invite create/revoke
  command writes, invite join membership transactions, member-cache invalidation,
  and member page read paths.
- conversation governance failures: optimize conversation preference writes,
  message lifecycle command writes, favorite/visibility overlay indexes, receipt
  summary reads, and conversations/changes propagation before changing realtime
  delivery.
- message-forward failures: optimize source visible-message reads, target
  conversation command writes, sequence allocation, target timeline/since cache,
  summary projection, and message-created outbox processing before changing
  normal send fanout.
- ai-stream failures: optimize AI stream lease reservation, initial streaming
  message writes, provider chunk scheduling, stream snapshot writes, realtime
  stream-signal fanout, terminal finalization, and stale-stream repair.
- contact-request failures: optimize friend-request pending lookup indexes,
  incoming/outgoing request list scans, request status updates, contact outbox
  writes, and contact changes pagination before changing contact accept or direct
  conversation activation paths.
- contact sync failures: optimize friend request command transactions, contact
  outbox/change-log writes, contact changes pagination, contact realtime relay,
  and contacts list indexes.
- profile sync failures: optimize profile command writes, direct-peer summary
  projection, contact/domain event outbox processing, and conversations/changes
  propagation.
- safety block/report failures: optimize user block indexes, report writes,
  common-feature table access, and HTTP command latency before changing IM
  realtime delivery.
- admin report moderation failures: optimize report table status/target indexes,
  internal report pagination, moderation status updates, and internal
  secret/auth middleware overhead.
- media/file failures: optimize file storage I/O, media upload session storage,
  object-store/S3 latency, range download handling, and asset metadata reads.
- media failure/recovery failures: optimize auth rejection latency, invalid
  range handling, upload-session state transitions, missing asset lookup, and
  recovery upload/download path before changing media payload size.
- large-group drain failures: optimize compact hint coalescing, owner delivery
  batch writes, relay batch size, gateway local fanout batch/yield, and Kafka
  consumer lag.

### Message Send And Delivery Capacity

Use this workflow after online capacity is known. It keeps users online with
cached login tokens, then sends messages at a controlled global rate and verifies
that the paired receiver observes the realtime message event.

`tcp_message_send_ladder.sh` is fail-closed by default for production-style
runs: it prewarms login cache, requires the formal TCP run to use that cache,
collects remote `/internal/metrics` deltas, and sets
`IM_METRICS_GATE_MODE=fail` for the delegated `tcp_capacity_ladder.sh` step.
Override with `MESSAGE_METRICS_GATE_MODE=warn|off` only for local exploratory
runs whose results will not be used as production evidence.

Do not start with the server's maximum idle-online connection count. For the
current 2 vCPU / 2 GiB single-node server, use `1000`, `2000`, then `3000`
connections first; avoid `4000+` message tests until idle-online capacity has
headroom.

Single load generator example:

```bash
cd IMServer/LoadTests
IM_CONVERSATION_ID="$IM_CONVERSATION_ID" \
SSH_HOST=root@<server-public-ip> \
ACCOUNT_FILE="$PWD/accounts/load-3000.csv" \
ONLINE_LADDER="1000 2000 3000" \
MESSAGE_RATES="10 50 100" \
MESSAGE_HOLD_SECONDS=600 \
MESSAGE_CONNECT_RAMP_SECONDS=300 \
MESSAGE_METRICS_GATE_MODE=fail \
./tcp_message_send_ladder.sh
```

Message profile parameters:

- `MESSAGE_PROFILE=per-connection` makes each
  connection sends `MESSAGES` messages and expects its own ack/canonical event.
- `MESSAGE_PROFILE=pair-delivery` pairs sender `i` with receiver
  `(i + MESSAGE_RECEIVER_OFFSET) % connections` and records delivery latency when
  the receiver sees the matching `clientMessageID`.
- `MESSAGE_RATE_PER_SECOND` controls the global send rate in `pair-delivery`.
  When it is greater than zero, total messages are approximately
  `MESSAGE_RATE_PER_SECOND * HOLD_SECONDS`, spread evenly across senders.
- `MESSAGE_SENDER_EVERY=1` means every connection sends. Use `2`, `5`, or `10`
  to reduce the active sender population while keeping receivers online.
- `MESSAGE_PREWARM_LOGIN_CACHE=true` and `MESSAGE_REQUIRE_LOGIN_CACHE=true` are
  the production defaults. A formal message-send run must not perform JIT HTTP
  login.
- `ACCOUNT_DEVICES_PER_USER` controls how many consecutive TCP connections reuse
  the same account from `ACCOUNT_FILE`. For example, `ACCOUNT_DEVICES_PER_USER=2`
  with `200` connections uses the first `100` accounts with two distinct device
  logins each. The multi-device delivery scenario uses
  `MESSAGE_SENDER_EVERY=2` and `MESSAGE_RECEIVER_OFFSET=1`, so the first device
  sends and the second device for the same account receives.
- `MESSAGE_METRICS_GATE_MODE=fail` is the production default. It fails a step on
  active fanout route drops, gateway relay failures, timeline/since misses,
  visibility scan-limit hits, slow timeline reads, owner batch write stalls, or
  projection lag beyond the configured gate thresholds.
- `MESSAGE_SEND_LADDER_DRY_RUN=true` prints the delegated
  `tcp_capacity_ladder.sh` settings without opening network connections; this is
  used by the shell self-test.

Recommended ladder for the current single-node server:

```text
1000 online, 10 msg/s, hold 10m
1000 online, 50 msg/s, hold 10m
1000 online, 100 msg/s, hold 10m
2000 online, 10 msg/s, hold 10m
2000 online, 50 msg/s, hold 10m
2000 online, 100 msg/s, hold 10m
3000 online, 10 msg/s, hold 10m
3000 online, 50 msg/s, hold 10m
```

Latest verified single-node large-group result:

```text
2026-06-16, 8 vCPU / 16 GiB test node
10000 online, 10000-member conversation, 200 msg/s, 60s send window
connections=10000 successes=10000 authOK=10000
messageSent=12000 messageAck=12000 messageSendError=0 failures={}
messageReceived=13153557 heartbeatSent=165067 heartbeatAck=165067
lagClearAfterSendSeconds=14.539
Kafka consumer lag drained to 0 for domain, realtime, summary, notification
```

This result uses cached logins, `compact-only` active conversation fanout,
`pull-only` inactive hints, `IM_REALTIME_MESSAGE_CREATED_COALESCE_WINDOW_MS=100`,
`IM_REALTIME_ACTIVE_COMPACT_HINT_COALESCE_WINDOW_MS=100`,
`IM_GATEWAY_LOCAL_FANOUT_BATCH_SIZE=512`, and
`IM_GATEWAY_LOCAL_FANOUT_EVENT_LOOP_YIELD_CHUNKS=32`. It validates the large-group
compact/timeline-pull model, not full message-body fanout to every member.

Recent 200 msg/s drain tuning history:

```text
activeCompactMs  gatewayBatch  yieldChunks  lagClearAfterSendSeconds
50               64            64(default)  29.708
100              64            64(default)  24.609
100              128           64(default)  20.816
100              256           32           16.949
100              512           32           14.539
```

Use `monitor_tcp_drain.py` beside `tcp_online_driver.py` when validating drain
SLOs. It writes one JSONL sample per interval with driver progress, Kafka lag,
selected `/internal/metrics`, TCP established count, and container CPU/memory;
the summary file reports `lagClearAfterSendSeconds`.

Message send acceptance:

- `loginCacheHit=true` and no formal-run `login_start` events.
- `successes / connections >= 99.9%`.
- `ackSuccessRate >= 0.999`.
- `deliverySuccessRate >= 0.999`.
- `ackLatencyMs p95 < 300ms`, `ackLatencyMs p99 < 1000ms`.
- `deliveryLatencyMs p95 < 1000ms`, `deliveryLatencyMs p99 < 3000ms`.
- Kafka lag, outbox backlog, and projection lag do not grow without draining.
- TCP close/reconnect counters do not spike during steady state.
- Remote metrics snapshots include selected `/internal/metrics` values when
  `SSH_HOST` and `COLLECT_REMOTE_METRICS=true` are set. Use `IM_METRICS_URL`
  to override the remote endpoint and `IM_METRICS_SECRET`,
  `IM_METRICS_INTERNAL_SECRET`, or `IM_INTERNAL_SHARED_SECRET` for the
  `X-IM-Metrics-Secret` header. Override `IM_METRICS_NAMES` to sample a custom
  space-separated metric set. The default metric set includes TCP write pressure,
  local fanout, compact large-group hinting, timeline/since cache, timeline read
  latency and visibility scans, client timeline catch-up health, owner-delivery
  batch write, projection lag, and stream-consumer counters. Each ladder step
  also prints an `im metrics delta` section when `/internal/metrics` is
  reachable: counters ending in `_total` show the step delta, while gauges show
  the final value and change from the pre-step snapshot.
- Remote snapshots print service activity for `REMOTE_SERVICE_NAMES`. The
  default list includes gateway, outbox relay, generic stream-consumer, and
  split summary/domain/realtime/notification consumer service names. Missing or
  inactive services are reported but do not stop the snapshot, so Kafka lag and
  `/internal/metrics` collection still run on partially split deployments.
- Remote snapshots also describe Kafka lag for
  `KAFKA_CONSUMER_GROUPS`, defaulting to `domain-delivery-consumer`,
  `summary-projection-consumer`, `realtime-delivery-consumer`, and
  `notification-consumer`. Override `KAFKA_BOOTSTRAP_SERVER` when Kafka is not
  reachable at `127.0.0.1:9092`, and override `KAFKA_CONSUMER_GROUPS` when a
  deployment splits or renames stream-consumer groups. Override
  `KAFKA_CONSUMER_GROUPS_CMD` when `kafka-consumer-groups.sh` is installed
  somewhere other than `/opt/kafka/bin/kafka-consumer-groups.sh`, exposed on
  `PATH`, or wrapped by a container command. If the command is unavailable, the
  snapshot prints a warning and continues collecting service and `/internal/metrics`
  data. Treat realtime lag growth separately from domain/summary lag; a hot group
  can have healthy writes but still back up live delivery.
- `IM_METRICS_GATE_MODE=warn|fail|off` evaluates the same before/after metrics
  snapshot after each ladder step. Defaults are intentionally strict for
  correctness counters: client catch-up failures/deferred,
  timeline/since distributed invalidation errors, stream failed events, TCP
  write backpressure/drops, active-conversation route-drop counters,
  realtime async relay dropped dispatch/recipient counters, gateway HTTP relay
  skipped recipients/request failures/binary fallbacks/inbound failures, and
  `im_timeline_since_target_sequence_strong_misses_total` /
  `im_timeline_since_target_sequence_errors_total` /
  `im_timeline_read_visibility_scan_limit_exceeded_total` all default to max
  `0`. Targeted strong catch-up also fails when
  `im_timeline_since_target_sequence_strong_fallbacks_total` increases by at
  least `IM_GATE_TARGET_SEQUENCE_SINGLEFLIGHT_MIN_FALLBACKS` (default `10`) but
  `im_timeline_since_target_sequence_singleflight_joined_total` does not increase.
  It also fails when targeted strong fallback rate exceeds
  `IM_GATE_TARGET_SEQUENCE_STRONG_FALLBACK_RATE_MAX_PERCENT` (default `25`) after
  at least `IM_GATE_TARGET_SEQUENCE_STRONG_FALLBACK_RATE_MIN_REQUESTS` targeted
  pulls (default `20`), because strong catch-up is a bounded lag fallback, not
  the steady-state active-room read path.
  Gateway HTTP relay outbound and inbound max body gauges default to max
  `1048576` bytes so large realtime payload regressions fail release-candidate
  runs before they rely on JSON fallback or gateway body-limit errors.
  Step-level server-side `timeline/since` read latency is computed from the
  histogram delta for the current ladder step; P95 defaults to max `2000`, P99
  defaults to max `5000`, and the raw
  `im_timeline_read_latency_max_millis` gauge defaults to max `10000`. Use
  `fail` for release-candidate runs so a step exits non-zero on any violation;
  keep `warn` for exploratory tuning. In `fail` mode the script validates before
  building or opening TCP connections that `SSH_HOST`,
  `COLLECT_REMOTE_METRICS=true`, `COLLECT_IM_METRICS=true`, and
  `COLLECT_IM_METRICS_DELTA=true` are all set. A missing before/after
  `/internal/metrics` snapshot still fails the step instead of silently skipping
  the gate.
- Gate thresholds are configured with `IM_GATE_CLIENT_CATCH_UP_FAILURES_MAX`,
  `IM_GATE_CLIENT_CATCH_UP_DEFERRED_MAX`,
  `IM_GATE_TIMELINE_INVALIDATION_ERRORS_MAX`,
  `IM_GATE_STREAM_FAILED_EVENTS_MAX`,
  `IM_GATE_TCP_DROPPED_BACKPRESSURE_MAX`, `IM_GATE_TCP_BACKPRESSURE_MAX`,
  `IM_GATE_ACTIVE_FANOUT_ROUTE_SPLIT_DROPS_MAX`,
  `IM_GATE_REMOTE_ACTIVE_FANOUT_ROUTE_SPLIT_DROPS_MAX`,
  `IM_GATE_REALTIME_ASYNC_RELAY_DROPPED_DISPATCHES_MAX`,
  `IM_GATE_REALTIME_ASYNC_RELAY_DROPPED_RECIPIENT_DELIVERIES_MAX`,
  `IM_GATE_GATEWAY_HTTP_RELAY_SKIPPED_RECIPIENTS_MAX`,
  `IM_GATE_GATEWAY_HTTP_RELAY_REQUEST_FAILURES_MAX`,
  `IM_GATE_GATEWAY_HTTP_RELAY_BINARY_FALLBACKS_MAX`,
  `IM_GATE_GATEWAY_HTTP_RELAY_INBOUND_FAILURES_MAX`,
  `IM_GATE_GATEWAY_HTTP_RELAY_REQUEST_MAX_BODY_BYTES`,
  `IM_GATE_GATEWAY_HTTP_RELAY_INBOUND_MAX_BODY_BYTES`,
  `IM_GATE_TARGET_SEQUENCE_STRONG_MISSES_MAX`,
  `IM_GATE_TARGET_SEQUENCE_ERRORS_MAX`,
  `IM_GATE_TARGET_SEQUENCE_STRONG_FALLBACK_RATE_MAX_PERCENT`,
  `IM_GATE_TARGET_SEQUENCE_STRONG_FALLBACK_RATE_MIN_REQUESTS`,
  `IM_GATE_CATCH_UP_REQUEST_MAX_MS`,
  `IM_GATE_CATCH_UP_HINT_TO_APPLY_MAX_MS`,
  `IM_GATE_TIMELINE_READ_MAX_MS`,
  `IM_GATE_TIMELINE_SINCE_READ_P95_MAX_MS`,
  `IM_GATE_TIMELINE_SINCE_READ_P99_MAX_MS`,
  `IM_GATE_TIMELINE_VISIBILITY_SCAN_LIMIT_EXCEEDED_MAX`,
  `IM_GATE_TIMELINE_SINCE_NOTICE_BYPASSES_MAX`,
  `IM_GATE_TIMELINE_SINCE_VISIBILITY_NOTICE_BYPASSES_MAX`,
  `IM_GATE_OWNER_BATCH_WRITE_MAX_MS`, and
  `IM_GATE_PROJECTION_LAG_MAX_MS`.

Message fanout interpretation:

- `im_realtime_active_conversation_fanout_active_recipients_total` is the number
  of recipients who were actively viewing the conversation and received live
  message fanout.
- `im_realtime_active_conversation_fanout_inactive_hint_recipients_total` is the
  number of inactive recipients selected for lightweight conversation-list hints
  in `IM_REALTIME_INACTIVE_CONVERSATION_HINT_MODE=relay`. In production
  `pull-only` mode this should stay near zero because inactive online users use
  conversation changes and `timeline/since` catch-up instead of realtime fanout.
- `im_realtime_active_conversation_fanout_downgraded_active_recipients_total`
  is the number of active conversation viewers downgraded from full live message
  fanout to compact active realtime hints.
- `im_realtime_active_conversation_fanout_compact_active_recipients_total`
  is the subset of downgraded active viewers that received a lightweight
  `conversation_activity_hint` instead of the full `message_created` payload.
  These viewers are actively in the conversation but must use `timeline/since`
  to fetch the message body.
- `im_domain_relay_after_record_pre_split_compact_active_recipients_total`
  is the same compact-active signal on the domain-delivery relay-after-record
  path. It should rise with downgraded active viewers when owner delivery is
  skipped, while `im_domain_relay_after_record_pre_split_inactive_hint_recipients_total`
  should stay near zero in production `pull-only` mode.
- `im_realtime_active_conversation_fanout_backpressure_downgraded_active_recipients_total`
  is the subset downgraded because all local connections for that active user
  were non-writable when `IM_TCP_DROP_REALTIME_WHEN_NOT_WRITABLE=true`. These
  recipients are not converted into inactive `conversation_activity_hint`
  recipients; they recover through the normal selected-chat timeline catch-up
  or reconnect path instead of receiving a list-summary hint while active.
- `im_realtime_inactive_conversation_hint_recipients_total` shows how many hint
  recipients were actually flushed after debounce/coalescing in relay mode.
  Production `pull-only` runs should not depend on this metric for list
  freshness.
- `im_realtime_inactive_conversation_hint_suppressed_recipients_total` shows
  how many pending inactive hints were replaced before flush when relay mode is
  explicitly enabled for a local experiment.
- If active recipients dominate and TCP write latency/backpressure rises, the
  bottleneck is gateway live fanout or slow clients.
- If downgraded active recipients grow while backpressure downgrades stay flat,
  `IM_REALTIME_ACTIVE_CONVERSATION_FULL_FANOUT_LIMIT` or the payload byte budget
  is protecting full-message fanout. Compact active recipients receive a
  realtime activity hint and must catch up through `timeline/since`. If
  backpressure downgrades grow, the gateway/client network path is saturated;
  affected clients also catch up through `timeline/since`.
- If inactive hint recipients dominate in a production run, the deployment is
  not using `IM_REALTIME_INACTIVE_CONVERSATION_HINT_MODE=pull-only` everywhere.
  Fix the gateway/stream-consumer env before treating the result as a production
  capacity number.
- If `im_realtime_coalesced_*` and `im_realtime_async_relay_*` grow while
  active/inactive recipient counts are low, tune the stream-consumer relay
  dispatcher before raising message rate.

Realtime relay tuning:

- Keep `IM_REALTIME_DELIVERY_ASYNC_RELAY_ENABLED=false` for strict synchronous
  relay semantics.
- Use `IM_REALTIME_DELIVERY_ASYNC_RELAY_ENABLED=true` for realtime latency
  capacity tests. In this mode the realtime Kafka consumer commits after placing
  relay work into a bounded in-process dispatcher; durable owner delivery remains
  the catch-up source if the process exits before a best-effort live relay
  finishes.
- `IM_REALTIME_DELIVERY_ASYNC_MAX_IN_FLIGHT` caps concurrent gateway relay jobs.
  Start with `32`; if gateway CPU, relay errors, or TCP send completion latency
  spikes, lower it. If realtime Kafka lag grows while gateway has headroom, raise
  it cautiously.
- `IM_REALTIME_DELIVERY_ASYNC_MAX_QUEUED` caps relay jobs waiting for an async
  dispatcher slot. Start with `1024`; lower it if stream-consumer memory grows
  during hot-group bursts. When this queue is saturated, the server drops the
  best-effort live relay and relies on owner-delivery cursor or timeline catch-up;
  track `im_realtime_async_relay_*` metrics before increasing in-flight relay
  concurrency.
- `IM_REALTIME_REMOTE_DISPATCH_USER_BATCH_SIZE` caps the number of target users
  in one cross-node realtime packet. Start with `512`; lower it if gateway relay
  body size, Redis dispatch latency, or TCP local fanout latency spikes.
  Production gateway validation rejects values above `2048`.
- `IM_REALTIME_REMOTE_DISPATCH_MAX_IN_FLIGHT` caps concurrent cross-node dispatch
  requests from one process. Start with `8`; raise it only when remote gateway
  nodes have CPU/network headroom and dispatch queues stay flat. Production
  gateway validation requires `> 1` and rejects values above `64`.
- Metrics expose `im_realtime_remote_dispatch_config_user_batch_size` and
  `im_realtime_remote_dispatch_config_max_in_flight`; include them in every
  remote metrics snapshot so cross-node dispatch latency and body-size results
  can be interpreted against the actual runtime config.
- Use `im_cross_node_dispatch_latency_avg_millis` and
  `im_cross_node_dispatch_latency_max_millis` to separate remote gateway relay
  latency from local TCP fanout latency during multi-gateway large-group tests.
- `IM_GATEWAY_LOCAL_FANOUT_BATCH_SIZE` caps how many local TCP connections one
  fanout chunk writes to. Start with `64`; lower it if a single hot-room relay
  monopolizes gateway EventLoops. Production gateway validation rejects values
  above `1024` because one chunk is not preempted until all writes in that chunk
  have been queued.
- `IM_GATEWAY_LOCAL_FANOUT_EVENT_LOOP_YIELD_CHUNKS` caps how many local fanout
  chunks one EventLoop runner processes before rescheduling itself. Start with
  `64`; lower it if heartbeat/ACK latency rises during hot-room fanout, and
  raise it only when `im_local_fanout_event_loop_jobs_total` is high while TCP
  write latency is healthy.
- Local fanout metrics cover pre-split domain-event batches plus generic encoded
  single-packet fanout such as stream signals, so a spike in
  `im_local_fanout_event_loop_jobs_total` should be checked against packet type
  and active hot-room traffic before raising the yield or batch limits.
- Use `im_local_fanout_chunks_total` and
  `im_local_fanout_max_chunks_per_event_loop_job` with
  `im_local_fanout_event_loop_jobs_total` to tune
  `IM_GATEWAY_LOCAL_FANOUT_BATCH_SIZE` and
  `IM_GATEWAY_LOCAL_FANOUT_EVENT_LOOP_YIELD_CHUNKS`; if chunks/job stays pinned
  at the configured yield while ACK or heartbeat latency rises, lower the yield
  before increasing relay concurrency.
- `IM_TCP_WRITE_BUFFER_LOW_WATERMARK` and
  `IM_TCP_WRITE_BUFFER_HIGH_WATERMARK` configure NIO per-channel write-buffer
  watermarks on gateway TCP connections. Start with `524288` / `1048576`; lower
  them if slow clients retain too much memory, and raise them only when
  `im_local_fanout_*` metrics show gateway fanout is healthy but brief network
  bursts trigger unnecessary writability churn.
- `IM_TCP_DROP_REALTIME_WHEN_NOT_WRITABLE=true` drops best-effort realtime
  domain-event fanout for a connection that is already non-writable. ACK/kick
  control packets still use the normal write path. Keep this enabled for
  large-group tests so slow clients catch up through owner cursor or
  `timeline/since` instead of retaining unbounded gateway buffers.
- `im_tcp_write_completions_total`, `im_tcp_write_failures_total`,
  `im_tcp_write_backpressure_total`,
  `im_tcp_write_dropped_backpressure_total`, and
  `im_tcp_write_latency_*_millis` show whether fanout work is reaching the socket
  layer cleanly. Treat rising backpressure or write latency during steady load as
  a gateway/client-network bottleneck before increasing realtime relay
  concurrency.
- `IM_REALTIME_MESSAGE_CREATED_LIGHTWEIGHT_RECIPIENT_THRESHOLD` enables a
  large-conversation realtime optimization for `message_created`. When the
  recipient count is greater than or equal to the threshold, realtime relay sends
  a lightweight hint for non-full-fanout recipients while owner delivery or
  timeline reads remain the catch-up source for the message body. Inactive or
  list-only recipients receive `conversation_activity_hint`; production active
  chat viewers downgraded from full fanout also receive a bounded
  `conversation_activity_hint` message-lite payload. Start with `500` for
  production hot-group testing and keep it aligned with the summary
  activity-only and owner-delivery skip thresholds.
- `IM_REALTIME_MESSAGE_CREATED_LIGHTWEIGHT_PREVIEW_MAX_CHARS` caps the preview
  text used in inactive `conversation_activity_hint` payloads; the default is
  `120`.
- `IM_REALTIME_ACTIVE_COMPACT_HINT_PREVIEW_MAX_CHARS` must be `1...120` so
  active chat viewers can render a new hot-room message from the realtime hint
  while still reconciling through `timeline/since`.
- `IM_REALTIME_MESSAGE_CREATED_PREVIEW_LOOKUP_ENABLED=false` is the production
  setting for hot large-group realtime. New `message_created` events must carry
  an embedded preview, so the realtime consumer can build inactive conversation
  hints without reading the message row on the hot path. Track
  `im_domain_event_message_created_preview_embedded_total`,
  `im_domain_event_message_created_preview_message_lookup_total`, and
  `im_domain_event_message_created_preview_missing_total`; production hot-group
  tests should show embedded previews growing, message lookups staying flat, and
  missing previews at zero.
- When active-conversation route lookup or pre-split fanout fails, the system
  drops the best-effort realtime fanout. It does not fall back to full unsplit
  group fanout and does not convert active-chat delivery into inactive
  `conversation_activity_hint` semantics. Track
  `im_realtime_active_conversation_fanout_route_split_drops_total`,
  `im_realtime_active_conversation_fanout_route_split_drop_recipients_total`,
  `im_realtime_remote_active_conversation_fanout_route_split_drops_total`, and
  `im_realtime_remote_active_conversation_fanout_route_split_drop_recipients_total`.
- `IM_REALTIME_MESSAGE_CREATED_COALESCE_WINDOW_MS` coalesces large
  `message_created` inactive-list hints by conversation when relay mode is
  explicitly enabled. Production active chat viewers should use a short
  active compact window, for example
  `IM_REALTIME_ACTIVE_COMPACT_HINT_COALESCE_WINDOW_MS=100`, so hot rooms collapse
  repeated compact hints by recipient while keeping visible-message catch-up
  freshness bounded well below one second. Inactive online users are not realtime-fanout targets
  in production `pull-only` mode; they use conversation changes and
  `timeline/since` catch-up. This is the production path for hot large groups,
  not a per-message delivery guarantee. Track `im_realtime_coalesced_*` metrics
  to see how much hint fanout pressure is being collapsed. Domain-delivery
  `IM_DOMAIN_DELIVERY_RELAY_AFTER_RECORD=true` follows the same split: active
  compact hints use the active compact window, inactive hints use the inactive
  coalescing window.
- `IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_ENABLED=true` is required on
  production gateways. It splits active chat viewers from inactive online users;
  production `compact-only` plus `pull-only` keeps realtime delivery focused on
  active viewers, while inactive recipients advance conversation-list state via
  changes/timeline pull. This prevents a hot large group from forcing every idle
  client to receive every realtime message or list hint.
- `IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_RECIPIENT_THRESHOLD` controls when the
  active/inactive split starts. Keep it aligned with the large-group threshold
  used by owner-delivery skip and lightweight realtime payloads; start with
  `500` for production gateway tests.
- `IM_REALTIME_ACTIVE_CONVERSATION_FULL_FANOUT_LIMIT` caps how many active
  viewers of one conversation receive full live `message_created` fanout from a
  gateway split. The default `0` is only for local smoke checks.
  Production validation requires a value above `0`, less than or equal to
  `IM_REALTIME_ACTIVE_CONVERSATION_FANOUT_RECIPIENT_THRESHOLD`, and no higher
  than the hard cap `128`. For production hot-room tests, start with `128`;
  lower it if TCP write latency or backpressure grows. Overflow writable active
  viewers receive the configured active compact hint; production uses bounded
  `conversation_activity_hint` message-lite payloads. Inactive or non-writable viewers rely on timeline catch-up instead of
  realtime hint fanout in production `pull-only` mode. Do not raise this above
  `128` in a production load test; use a local/experimental branch if you need
  to compare unsafe upper bounds.
- `IM_REALTIME_ACTIVE_CONVERSATION_FULL_FANOUT_MODE=compact-only` is the
  production large-group mode. In this mode even active chat viewers receive a
  bounded active compact hint and use `timeline/since` to reconcile the
  message body. Keep `bounded` only for local A/B tests that intentionally
  measure limited full realtime fanout; production validation rejects bounded
  mode because it makes hot-room capacity depend on full-message socket fanout.
- `IM_REALTIME_ACTIVE_CONVERSATION_FULL_FANOUT_PAYLOAD_BYTE_BUDGET` caps the
  estimated full-payload bytes sent per hot-conversation message before fanout
  replication. When a message payload is large, the effective full fanout limit
  becomes `min(IM_REALTIME_ACTIVE_CONVERSATION_FULL_FANOUT_LIMIT,
  budget / encoded_payload_bytes)` and remaining writable active viewers receive
  compact-active message-lite hints. Inactive or non-writable viewers use
  timeline/since catch-up instead of realtime hint fanout in production
  `pull-only` mode. Start with `262144` and keep it at least `65536` in
  production; set `0` only for local A/B comparison. Track
  `im_realtime_active_conversation_fanout_payload_budget_applied_total`,
  `im_realtime_active_conversation_fanout_payload_budget_downgraded_active_recipients_total`,
  `im_realtime_active_conversation_fanout_payload_budget_max_payload_bytes`, and
  `im_realtime_active_conversation_fanout_payload_budget_max_effective_limit`
  together with `im_realtime_active_conversation_fanout_compact_active_recipients_total`
  to see whether large payloads, rather than active-room size alone, are moving
  users from full to compact realtime.
- `IM_REALTIME_INACTIVE_CONVERSATION_HINT_MODE=pull-only` is the production
  setting. It disables realtime fanout to inactive online users for hot groups;
  clients use conversation changes and `timeline/since` catch-up for list and
  message freshness. Keep `relay` only for local A/B experiments.
- `IM_REALTIME_INACTIVE_CONVERSATION_HINT_DEBOUNCE_SECONDS` only matters when
  `IM_REALTIME_INACTIVE_CONVERSATION_HINT_MODE=relay`. Production `pull-only`
  deployments should not tune this to improve hot-group list freshness.
- `IM_TIMELINE_SINCE_HOT_CACHE_TTL_MS` protects query-api from synchronized
	  `timeline/since` pulls after lightweight large-group hints. It is a short
	  in-process cache keyed by conversation, lower timeline bound, visible sequence
	  floor, and limit; it only serves pages that are safe to share, and bypasses
	  cache when notices or user-hidden messages require exact per-user visibility.
	  Start with `250`, keep production between `50` and `5000`, keep it below the
	  iOS selected-hint catch-up throttle, and
	  track `im_timeline_since_hot_cache_hits_total`,
	  `im_timeline_since_hot_cache_misses_total`, and
	  `im_timeline_since_hot_cache_unsafe_bypasses_total` during 1000-user hot-group
	  tests. When targeted catch-up uses `targetSequence`, also track
	  `im_timeline_since_hot_cache_target_sequence_bypasses_total`; a high value
	  means the exact hot-cache entry exists but is older than the hinted sequence,
	  so the request correctly falls through to shared strong catch-up instead of
	  returning a stale page.
- `IM_TIMELINE_SINCE_RECENT_CACHE_TTL_MS` adds a short per-conversation recent
  page cache for adjacent safe `timeline/since` cursors. The exact hot cache
  only helps when clients request the same `afterSequence`; the recent cache lets
  nearby cursors reuse the latest safe page suffix after compact large-group
  hints. It is checked only after the same shared-read safety gate as the hot
  cache, never serves pages containing notices, and is invalidated by the same
  local or Redis-distributed conversation invalidations. Start with `2000` and
  keep production between `1000` and `30000`.
- `IM_TIMELINE_SINCE_RECENT_CACHE_MAX_CONVERSATIONS` bounds the number of
  conversation/visible-floor recent entries kept by each query-api process. Start
  with `1024`; production must keep at least `512`, and should raise only when
  hot-group tests show useful hit rate but eviction pressure.
- `IM_TIMELINE_SINCE_RECENT_CACHE_MAX_ITEMS_PER_CONVERSATION` caps the cached
  latest timeline items per entry. Start with `512`; production must keep at
  least `128`, lower it if query-api memory grows during many concurrent hot
  conversations, and raise it only when
  `im_timeline_since_recent_cache_misses_total` stays high because client cursors
  are spread across a wider recent window.
- Track `im_timeline_since_recent_cache_hits_total`,
  `im_timeline_since_recent_cache_misses_total`,
  `im_timeline_since_recent_cache_target_sequence_bypasses_total`,
  `im_timeline_since_recent_cache_stores_total`,
  `im_timeline_since_recent_cache_invalidations_total`, and
  `im_timeline_since_recent_cache_invalidated_entries_total` together with the
  exact hot-cache counters. In a healthy 1000-user hot-group compact-hint run,
  recent-cache hits should rise when clients catch up from slightly different
  local cursors; zero hits means synchronized pulls are either already exact-key
  hits or still falling through to DB. A high target-sequence bypass count means
  the cached recent suffix does not extend far enough to the hinted sequence;
  raise `IM_TIMELINE_SINCE_RECENT_CACHE_MAX_ITEMS_PER_CONVERSATION` only if query
  memory and invalidation rates remain safe.
- Targeted `timeline/since` catch-up requests from realtime lightweight hints include
  `targetSequence`. Query-api passes that target through the eventual read path
  first, so target-aware hot/recent cache checks, target-sequence singleflight,
  and the short target-sequence coalescing window can satisfy active-viewer pulls
  before any strong read is attempted. Cached pages are used only when their
  latest timeline sequence reaches `targetSequence`; stale entries are counted as
  target-sequence bypasses and do not satisfy the request. If the eventual
  response still does not reach the target, query-api retries against the strong
  timeline source through the same target-aware shared path. This prevents a
  stale empty hot cache entry or replica lag from turning a delivered hint into a
  visible `target_not_reached` delay while still collapsing synchronized catch-up
  from many active viewers. Untargeted history/gap reads keep the normal
  eventual-read hot-cache path.
- `IM_TIMELINE_SINCE_HOT_CACHE_MAX_ENTRIES` bounds that query-api process cache.
	  Start with `4096`; raise it only when hit rate is low because many hot
	  conversations or cursor windows are active at once.
- iOS selected-conversation lightweight hints are micro-batched for a short
  window before issuing `timeline/since`; adjacent hints keep only the latest
  target timeline sequence. This keeps active viewers close to realtime while
  reducing synchronized hot-room pull amplification. During hot-group tests,
  track `im_client_timeline_catch_up_hint_queued_total`,
  `im_client_timeline_catch_up_since_requests_total`,
  `im_client_timeline_catch_up_since_successes_total`,
  `im_client_timeline_catch_up_since_failures_total`,
  `im_client_timeline_catch_up_deferred_total`,
  `im_client_timeline_catch_up_applied_items_total`,
  `im_client_timeline_catch_up_hint_to_request_max_millis`,
  `im_client_timeline_catch_up_hint_to_request_avg_millis`,
  `im_client_timeline_catch_up_request_max_millis`,
  `im_client_timeline_catch_up_request_avg_millis`,
  `im_client_timeline_catch_up_hint_to_apply_max_millis`, and
  `im_client_timeline_catch_up_hint_to_apply_avg_millis`. Avg gauges show the
  current reporting-client trend; max gauges catch individual client spikes. A high
  hint-to-request max points at client-side batching/rate-limit pressure; a high
  request max with healthy hint-to-request points at query-api/timeline read
  pressure; a high hint-to-apply max with low request max points at local client
  merge or UI-store pressure. Normal client-health reports remain rate-limited,
  but timeline catch-up `deferred`, `incomplete`, `failed`, and slow catch-up
  paths bypass the normal 60s interval with their own short cooldown so hot-room
  tests surface bad catch-up behavior quickly without flooding the health
  endpoint.
- iOS selected-conversation catch-up tuning can be overridden per build/run with
  `IM_SELECTED_HINT_CATCH_UP_INITIAL_JITTER_MS`,
  `IM_SELECTED_HINT_CATCH_UP_MIN_INTERVAL_MS`, and
  `IM_SELECTED_HINT_CATCH_UP_MICRO_BATCH_MS` through the process environment or
  matching `UserDefaults` keys. Explicit `0` is accepted for jitter; interval and
  micro-batch values are clamped to the client's minimum safe delay. The client
  includes the effective values in health reports; metrics expose
  `im_client_timeline_catch_up_config_selected_hint_initial_jitter_*_millis`,
  `im_client_timeline_catch_up_config_selected_hint_min_interval_*_millis`, and
  `im_client_timeline_catch_up_config_selected_hint_micro_batch_*_millis`.
  Always compare hint-to-request latency against these config gauges before
  treating slow selected-chat catch-up as a server-side timeline read issue.
- `IM_TIMELINE_SINCE_CACHE_INVALIDATION_MODE=redis` is required in production when
  any shared `timeline/since` cache is enabled. Command/stream nodes publish conversation invalidations
  after message and timeline-notice writes; query nodes subscribe and clear local
  hot cache, visibility-safety cache, and in-flight `timeline/since` singleflight
  work. Track `im_timeline_since_distributed_invalidations_published_total`,
  `im_timeline_since_distributed_invalidations_received_total`, and
  `im_timeline_since_distributed_invalidation_errors_total`. Any non-zero error
  count during hot-group tests means cache TTL must stay very short until Redis
  pub/sub connectivity is fixed.
- `IM_REDIS_ACTIVE_CONVERSATION_ROUTE_CACHE_TTL_SECONDS` controls the short
  in-process Redis presence cache used for active conversation user-set snapshots
  and per-user active route lookups. Cold misses use Redis-side membership
  probes against the conversation-node active user indexes, so the gateway only
  receives matched routes instead of full active-user sets for each node. Start
  with `2`; lower it if active-chat presence changes must be reflected faster,
  and raise it only when
  `im_redis_presence_active_conversation_node_index_*` metrics show hot groups
  are still repeatedly probing Redis node indexes.
- `IM_REALTIME_ACTIVE_CONVERSATION_ROUTE_CACHE_TTL_MS` controls the
  stream-consumer hot-conversation route cache. In production
  `IM_REALTIME_INACTIVE_CONVERSATION_HINT_MODE=pull-only`, it stores a short-lived
  active-room route snapshot for the conversation, so adjacent `message_created`
  relays query Redis by active viewers instead of probing every group member. In
  relay-hint comparison mode, it falls back to the per-recipient route cache,
  including negative inactive results, because inactive hint fanout still needs
  recipient-level routing. A 1000-member group at 5-10 msg/s should therefore
  avoid rebuilding the same active-room route query for every message even when
  recipient windows differ slightly. Start with `1000`; set `0` only for A/B
  comparison tests. Track
  `im_realtime_active_conversation_route_cache_hits_total`,
  `im_realtime_active_conversation_route_cache_partial_hits_total`,
  `im_realtime_active_conversation_route_cache_missed_users_total`,
  `im_realtime_active_conversation_route_cache_joined_in_flight_total`, and the
  matching domain relay-after-record route cache metrics together with Redis
  presence metrics to separate stream-consumer cache misses from Redis cache
  misses. A rising joined-in-flight counter means concurrent hot-group route
  misses were collapsed behind one Redis lookup instead of stampeding Redis.
- `IM_REALTIME_ACTIVE_CONVERSATION_ROUTE_CACHE_MAX_ENTRIES` bounds that
  stream-consumer cache. Each entry contains a conversation ID plus one cached
  user route result, including negative inactive results, so leaving it
  unbounded is unsafe for production hot-group tests with many active
  conversations or large recipient windows. Start with `4096`;
  lower it if stream-consumer memory grows, and raise it only when the hit ratio
  is low while memory remains flat.
- `IM_SUMMARY_PROJECTION_MESSAGE_CREATED_ACTIVITY_ONLY_RECIPIENT_THRESHOLD`
  makes `summary-projection-consumer` update a shared conversation activity row
  instead of writing one per-owner summary/change-log row for every large-group
  message. Production `summary-projection-consumer` deployments must set this
  above `0`; start with `500`. For omitted-recipient `message_created` events,
  the projection consumer uses the event snapshot's `recipient_count` hint to
  choose this path, so hot large-group summary projection does not need to decode
  the full shared recipient JSON before writing `ConversationActivitySummary`.
- `IM_SUMMARY_PROJECTION_ACTIVITY_COALESCE_WINDOW_MS` coalesces hot large-group
  `ConversationActivitySummary` writes by conversation. Within the window, only
  the latest activity row is written, while clients still use timeline/cursor
  catch-up for exact message history. Start with `500`; production must keep it
  between `50` and `1000`, lower it if conversation list freshness needs tighter
  bounds, and track
  `im_domain_event_summary_activity_coalesced_*` to confirm write pressure is
  actually collapsing.
- `IM_SUMMARY_RESPONSE_MEMBER_USER_IDS_LIMIT` caps summary/list/change response
  and realtime conversation summary member ID payloads. When `member_count` is
  greater than this value, summary responses keep the true `member_count` but
  return an empty `memberUserIDs` array, and clients must use the paged members
  API for member details. Start with `500` so 1000+ member group list/change
  reads and membership/settings realtime payloads do not repeatedly transfer or
  decode full member JSON.
- Track `im_realtime_payload_summary_member_ids_omitted_total` and
  `im_realtime_payload_summary_member_ids_omitted_members_total` during large
  membership/settings realtime tests. They should increase for 1000+ member
  groups; if `im_realtime_payload_summary_member_ids_emitted_members_total`
  grows at the same rate, realtime summaries are still carrying full member ID
  arrays.
- `IM_MESSAGE_CREATED_RECIPIENT_INLINE_THRESHOLD` keeps small-group
  `message_created` outbox events self-contained, but omits the full
  `recipientUserIDs` list at or above the threshold. Consumers expand large
  message-created recipients from the conversation membership read path, so
  Kafka/outbox payload size no longer grows linearly with large-group member
  count. Production command-api deployments must set this above `0`; keep it
  aligned with the other large-group thresholds and start with `500`.
- `IM_DOMAIN_EVENT_RECIPIENT_SNAPSHOT_DEDUP_THRESHOLD` stores large omitted
  recipient snapshots once per unique recipient hash, then lets per-event
  snapshot rows reference that shared set. Shared recipient sets also maintain a
  `conversation_domain_event_recipient_set_members` index; production
  `pull-only` realtime delivery uses that index to filter current active viewers
  without decoding the full UUID JSON for every hot-group message. Production
  command-api deployments must set this above `0` and no higher than
  `IM_MESSAGE_CREATED_RECIPIENT_INLINE_THRESHOLD`; start with `500`. This keeps
  hot 1000/2000 member groups from writing or decoding the same UUID list for
  every message.
- `IM_DOMAIN_DELIVERY_MESSAGE_CREATED_LARGE_GROUP_MODE=timeline-pull` is the
  production large-group delivery model. At or above
  `IM_DOMAIN_DELIVERY_MESSAGE_CREATED_OWNER_DELIVERY_SKIP_RECIPIENT_THRESHOLD`,
  `domain-delivery-consumer` does not write durable per-owner `message_created`
  copies; offline and gap catch-up come from the conversation timeline
  (`timeline/since`) instead of one owner-delivery protobuf per member per
  message. Keep `owner-delivery` plus threshold `0` only for small-group/full
  owner-delivery validation.
- `IM_DOMAIN_DELIVERY_MESSAGE_CREATED_OWNER_DELIVERY_SKIP_RECIPIENT_THRESHOLD`
  is the recipient count where `timeline-pull` starts. The iOS client treats
  active `conversation_activity_hint` events for the currently opened conversation
  as a `timeline/since` catch-up trigger, so active viewers can recover the real
  message body even when they receive a lightweight hint instead of an owner
  cursor event. Inactive users use conversation changes and `timeline/since`
  instead of realtime message fanout. The server timeline reader must scan past hidden or cleared
  candidate rows before deciding there are no visible items; otherwise large-group
  hint catch-up can stop on an empty filtered page. Start with `500`.
- `IM_TIMELINE_READ_VISIBILITY_SCAN_MAX_ROWS` and
  `IM_TIMELINE_READ_VISIBILITY_SCAN_MAX_PAGES` cap how far `timeline` and
  `timeline/since` scan through hidden or cleared candidate rows while searching
  for visible items. Start with `5000` rows and `50` pages on production
  command/query API nodes. The production schema validator requires
  `im_messages_conversation_timeline_server_sequence_idx` so these scans can use
  the conversation timeline cursor while checking the message server-sequence
  visibility floor. During hot-group tests, watch
  `im_timeline_read_visibility_scan_rows_total`,
  `im_timeline_read_visibility_scan_max_rows`,
  `im_timeline_read_visibility_scan_pages_total`,
  `im_timeline_read_visibility_scan_max_pages`, and
  `im_timeline_read_visibility_scan_limit_exceeded_total`. Any non-zero scan
  limit count means clients are protected from a misleading empty catch-up
  response, but the read path needs either a higher budget, better visibility
  indexes, or product cleanup of extreme hidden-message histories.
- `im_timeline_read_latency_millis_bucket{kind="since",...}` is the primary
  server-side tail-latency signal for large-group hint catch-up. Use
  `histogram_quantile(0.95, rate(im_timeline_read_latency_millis_bucket{kind="since"}[5m]))`
  and the matching P99 query to separate query-api/timeline read pressure from
  client-side hint batching or UI merge delays. The ladder scripts collect the
  histogram bucket/count/sum samples by default, print a step-level
  `timeline read latency summary`, and can gate the current step with
  `IM_GATE_TIMELINE_SINCE_READ_P95_MAX_MS` and
  `IM_GATE_TIMELINE_SINCE_READ_P99_MAX_MS`.
- Targeted `timeline/since` catch-up also reports
  `im_timeline_since_target_sequence_requests_total`,
  `im_timeline_since_target_sequence_eventual_satisfied_total`,
  `im_timeline_since_target_sequence_strong_fallbacks_total`,
  `im_timeline_since_target_sequence_strong_satisfied_total`, and
  `im_timeline_since_target_sequence_strong_misses_total`, and
  `im_timeline_since_target_sequence_errors_total`. Pair these with
  `im_timeline_since_hot_cache_target_sequence_bypasses_total`,
  `im_timeline_since_recent_cache_target_sequence_bypasses_total`, and
  `im_timeline_since_target_sequence_singleflight_joined_total`. The companion
  `im_timeline_since_target_sequence_window_joined_total` isolates the short
  target-sequence coalescing window that can merge active-viewer pulls even when
  their `afterSequence` cursors differ slightly. In a healthy active compact-hint
  run where the eventual read model keeps up, eventual-satisfied should rise and
  strong fallback should not grow linearly with active viewers. A high fallback
  rate with high
  target-sequence singleflight joins means the target-aware shared catch-up is
  absorbing synchronized active-viewer pulls. A high fallback rate with low
  target-sequence singleflight joins means clients are too spread out by cursor,
  limit, visible floor, target sequence, or query-api process locality to
  coalesce. A non-zero strong miss count means the strong timeline source also
  did not reach the hinted sequence, while
  target-sequence errors mean the targeted catch-up request failed before it
  could prove convergence. Investigate command write, sequence allocation, hint
  payload correctness, and query-api health before tuning caches.
  `im_timeline_since_visibility_notice_bypasses_total` and
  `im_timeline_since_response_singleflight_notice_bypasses_total` protect
  user-specific timeline notices from being shared through cached or in-flight
  catch-up. They should stay near zero in pure large-group message tests; high
  values mean the run includes membership/notice traffic and should not be used
  as a clean hot-message read-path benchmark.
  `IM_GATE_TIMELINE_SINCE_VISIBILITY_NOTICE_BYPASSES_MAX` and
  `IM_GATE_TIMELINE_SINCE_NOTICE_BYPASSES_MAX` default to `0` in fail mode for
  this reason.
  `IM_TIMELINE_SINCE_TARGET_SEQUENCE_COALESCE_WINDOW_MS` controls that short
  merge window; start with `5`, and only raise it after confirming P95/P99
  `timeline/since` latency still meets the gate.
  The ladder prints a `target-sequence catch-up summary` for each step. In
  `IM_METRICS_GATE_MODE=fail`, when strong fallbacks reach
	  `IM_GATE_TARGET_SEQUENCE_SINGLEFLIGHT_MIN_FALLBACKS` and
	  `im_timeline_since_target_sequence_singleflight_joined_total` does not
	  increase, the step fails because targeted strong catch-up is not coalescing.
	  The same fail-mode gate rejects a high targeted strong fallback rate through
	  `IM_GATE_TARGET_SEQUENCE_STRONG_FALLBACK_RATE_MAX_PERCENT` once
	  `IM_GATE_TARGET_SEQUENCE_STRONG_FALLBACK_RATE_MIN_REQUESTS` has been
	  reached. Raise that threshold only for a measured read-model lag experiment,
	  not for a production capacity claim.
- `IM_DOMAIN_DELIVERY_OWNER_RECORD_BATCH_MAX_REQUESTS` caps each Postgres owner
  delivery write/sequence allocation statement. The default is `1000`, which
  keeps 5000/10000 member runs from producing oversized single SQL statements
  while preserving per-owner cursor semantics. Production validation rejects
  values below `100` or above `5000`; keep the default unless database metrics
  show that larger chunks are safe. Track
  `im_domain_event_owner_delivery_batch_write_chunked_total` and
  `im_domain_event_owner_delivery_batch_write_chunks_total` during hot-group
  tests to confirm large owner-delivery writes are being split as expected.
  `im_domain_event_owner_delivery_batch_write_materialized_fast_paths_total`
  shows how often Postgres batch writes reused the rows already materialized for
  insert and avoided a follow-up owner-delivery row refetch.
- `IM_STREAM_CONSUMER_BATCH_FILL_WAIT_MS` gives the Kafka consumer a short
  in-process queue fill window after the first message in a processing batch.
  This helps adjacent same-partition `message_created` events enter the same
  run so summary/domain/realtime consumers can coalesce hot-conversation work.
  Start with `10`; production validation requires `1...100`, and values near
  the upper bound should be treated as a latency tradeoff, not a free throughput
  gain.
- The wait window is only applied when the first queued event is a valid
  `message_created` event with a message ID. Other event types bypass the wait
  and increment `im_stream_batch_fill_skipped_batches_total`, so membership,
  read-state, malformed, or dead-letter-bound events do not pay avoidable
  batch-fill latency. The consumer checks the Kafka `event-type` header before
  decoding the JSON payload; keep that header on custom producers so non-message
  events can skip batch-fill with minimal CPU overhead.
- This optimization assumes conversation events are produced to Kafka with the
  conversation ID as the message key, so one hot conversation remains partition
  ordered. The server has a regression test for this invariant; if a custom
  producer is introduced, keep the same keying strategy.
- Watch `im_stream_processing_batches_total`,
  `im_stream_processing_batch_events_total`,
  `im_stream_processing_batch_events_avg`,
  `im_stream_message_created_run_events_total`,
  `im_stream_message_created_run_events_avg`,
  `im_stream_batch_fill_waits_total`, and
  `im_stream_batch_fill_events_total` per `consumer_group` after changing the
  batch-fill wait. A healthy hot-conversation run should show processing batch
  events above `1`, message-created run events above `1`, and non-zero fill
  events without a matching increase in `im_stream_run_event_lag_*` or Kafka
  lag. Prefer the message-created run metrics over generic run averages when
  judging hot-group fanout, because non-message events can legitimately remain
  single-event runs. If fill waits rise but fill events stay near zero, the wait
  window is not helping; check Kafka partitioning, producer ordering, or lower
  the wait to reduce added latency.
- `tcp_capacity_ladder.sh` prints a `stream batch-fill summary` after each step
  when remote `/internal/metrics` snapshots are available. Treat
  `batchFillEffect=useful` as evidence that the wait window is improving
  `message_created` run coalescing, not merely generic queue batching. Treat
  `batchFillEffect=none` or `weak` as a signal to avoid raising
  `IM_STREAM_CONSUMER_BATCH_FILL_WAIT_MS` blindly; first verify that
  hot-conversation messages are landing on the same Kafka partition and arriving
  contiguously enough for the consumer to coalesce them. `generic-useful` means
  the queue batch got larger but no `message_created` run evidence was observed,
  so it should not be used as proof that hot-group fanout improved.

Use `MESSAGES`, `DEVICES_PER_USER`, `SEND_INTERVAL_MS`, `TIMEOUT_SECONDS`, and
`COOLDOWN_SECONDS` to tune each step. Set `MESSAGES=0` plus `HOLD_SECONDS` for
idle online capacity. Set `MESSAGES=1` or higher for a hot-conversation fanout
test; that is intentionally heavier and should not be interpreted as idle online
user capacity. Set `MESSAGE_COMPLETION_MODE=ack-only` when validating large-group
coalesced realtime mode; that mode measures send acknowledgement and observed
fanout without requiring every message to be pushed live to every receiver. When
`MESSAGES=0` and `DEVICES_PER_USER` is unset, the helper uses
one device session per connection because the server intentionally kicks duplicate
connections for the same session. `LOGIN_CONCURRENCY` defaults to `5` for device
session pre-warm; lower it if the auth/database path becomes the bottleneck.
`ACCOUNT_FILE` points to a local `email,password` CSV and makes TCPDriver round-robin
connections across real accounts.
`CONNECT_RAMP_SECONDS` staggers TCP connection startup; use it to separate steady
online capacity from a same-instant reconnect storm.
`LOGIN_MODE=just-in-time` logs in each virtual user immediately before its ramped
TCP connect. This better simulates real clients but can make the local generator's
HTTP stack part of the test. `LOGIN_RETRIES` retries transient HTTP login timeouts;
if `login_attempt_failed` grows but `login_failed` stays at zero, login jitter was
absorbed by retries.
For official online-capacity numbers, use cached tokens and `LOGIN_MODE=upfront`.
On larger load generators, `PREWARM_LOGIN_CACHE=true` is acceptable. On small
servers, prefer `prewarm_login_cache_slow.sh` followed by
`PREWARM_LOGIN_CACHE=false` and `REQUIRE_LOGIN_CACHE=true`. Reserve
`LOGIN_MODE=just-in-time` for combined login+TCP experiments.
`SAMPLE_DURING_SECONDS` controls remote metric sampling while the driver is still
running; set it to `0` to disable during-run samples.
`HEARTBEAT_INTERVAL_SECONDS` sends TCP heartbeat packets after auth succeeds. Keep
it lower than server `IM_TCP_IDLE_TIMEOUT` when `MESSAGES=0` and `HOLD_SECONDS`
is used to simulate long-lived online clients. `HEARTBEAT_LOG_MODE` defaults to
`errors` for capacity runs so heartbeat success traffic is aggregated in the
summary instead of written for every heartbeat. Use `sample` or `all` only for
diagnostic runs. The summary prints `heartbeatSendCompletionMs` p50/p95/p99; P99
above 10s usually means the load generator is overloaded.
`connect_timeout_fired` means the TCP connection did not reach `nw_ready` within
`TIMEOUT_SECONDS`. `preauth_timeout_fired` means TCP reached `nw_ready` and auth was
sent, but `authOK` did not arrive within `TIMEOUT_SECONDS`.
Use `--connection-queue-pool-size` or `IM_TCP_CONNECTION_QUEUE_POOL_SIZE` to control
how many DispatchQueues TCPDriver uses for NWConnection callbacks and timers.
The default is capped at 64 queues. This avoids one serial queue per connection,
which becomes expensive at thousands of connections. If `sendCompletionMs` stays
high, try `32`, `64`, and `128` before changing server settings.
On a single Mac load generator, observed signs of generator saturation are
`heartbeat_send_ok.sendCompletionMs` P99 above 10s, growing
`connect_timeout_fired`, and HTTP `login_attempt_failed` while the server gateway
CPU and memory remain low. Treat that as a load-generator limit and split the run
across multiple machines; do not treat it as the IM server's online-user limit.
`PROTOCOL_VERSION` defaults to the value in
`Protocol/im_realtime/v1/protocol_version.txt`. Override it only for a protocol
development smoke test. Run it from a load generator, not from the IMServer host.

## Go/No-Go

- HTTP/TCP error rate below 0.1%.
- TCP ack success rate above 99.9%.
- TCP canonical message success rate above 99.9%.
- `conversations/changes` convergence P95 below 2s.
- Outbox backlog returns to zero or continuously drains after load stops.
- Reconnect `messages/since` success above 99.9%.
- Cross-node dispatch failures and session-count query failures remain at zero.
- AI stream stale repair, finalize failure, and Redis lease heartbeat failure remain at zero during steady state.
- `capacity-target` is not a CI job; it must run in a dedicated environment with a capacity report.

## Production Dashboard

Track these counters or gauges together when reviewing release readiness:

- TCP connections and abnormal disconnect spikes.
- Outbox backlog, publish failures, and dead-letter events.
- Redis route cache hit/miss and stale route cleanup counts.
- AI active streams, lease reservations, lease rejections, lease heartbeat failures, chunk fanout count, snapshot writes, finalize retries, finalize failures, and stale repairs.

Recommended alerts:

- `ai_stream_stale_repair > 0` over a 5 minute window.
- `ai_stream_finalize_failure > 0` over a 5 minute window.
- Outbox backlog grows for 10 consecutive minutes.
- Redis lease heartbeat failures occur in production.
- TCP abnormal disconnects spike above the current baseline.
