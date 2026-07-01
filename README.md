# IM Monorepo

This repository contains the iOS client, reusable client SDK package, and Vapor backend for the IM system.

## Projects

| Path | Purpose |
| --- | --- |
| `IMApp/` | iOS application. Keeps SwiftUI screens, TabView, app lifecycle, and app-level orchestration such as `AuthManager`. |
| `IMClientKit/` | Swift Package SDK used by `IMApp`. Contains authentication/session models, HTTP/TCP networking, contacts, friend requests, IM conversation state, SwiftData cache, and file transfer clients. |
| `app/` | Android application. Uses Gradle-injected IM network config and release-time production host validation. |
| `IMClientKitAndroid/` | Android client SDK used by `app/`. |
| `IMServer/` | Vapor backend. Provides authentication, contacts/friend requests, conversation APIs, TCP IM server, message persistence, read state, and file APIs. |

## Local Development

The app layer owns environment injection through `AppNetworkConfiguration`. The default local values currently used by `IMApp` are:

- HTTP API: `http://127.0.0.1:8080`
- IM TCP: `127.0.0.1:9000`

Client local address rules:

- iOS Simulator: use `http://127.0.0.1:8080` and `127.0.0.1:9000`.
- Android Emulator: use `http://10.0.2.2:8080` and `10.0.2.2:9000`.
- Physical phone on the same Wi-Fi: override the debug build settings with your Mac LAN IP, for example `http://192.168.x.x:8080` and `192.168.x.x:9000`. `127.0.0.1` on a physical phone points to the phone itself, not the Mac.

Print the current local client settings:

```sh
make print-local-client-config
```

Build an iOS Debug app for a physical phone on the same Wi-Fi using the detected Mac LAN IP:

```sh
make build-app-local-device
```

Run the backend:

```sh
make local-server-start
make local-server-health
```

When the cloud server is stopped, use the local-only entrypoint:

```sh
make local-dev
```

This starts or reuses the local IMServer, checks `http://127.0.0.1:8080/health`,
validates that the iOS Debug build defaults to `127.0.0.1`, runs the local
acceptance prerequisite check, and prints the LAN-IP overrides needed for a
physical iPhone. It does not run production acceptance or use any public server.

Or run the local Docker stack when Docker is available:

```sh
cd IMServer
docker compose up --build app
```

Run package tests:

```sh
cd IMClientKit
swift test
```

Build the iOS app for testing:

```sh
xcodebuild \
  -project IMApp/IMApp.xcodeproj \
  -scheme IMApp \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  build-for-testing
```

Validate Android network configuration policy without requiring a full Android SDK build:

```sh
make validate-android-network-config
```

Run backend tests:

```sh
cd IMServer
swift test --no-parallel
```

## Production Gates

Run the local production static gate before changing deploy, production
environment, or app network configuration:

```sh
make help
make validate-production-static
make verify-production-static-receipt
```

This runs the iOS network-config gate self-test, audits the production GitHub
Actions workflow wiring, self-tests the production acceptance env and evidence
verifiers, runs the production operations self-tests through
`make check-production-ops`, validates the Docker production-smoke topology
configuration through `make check-imserver-production-smoke`, and runs the full
IMServer production env preflight self-test. It
catches placeholder domains, raw IP production targets, insecure public URLs,
weak production env templates, missing split-role settings, production
fanout/config limits, production acceptance env drift, and production workflow
trigger drift. It is
static, but not tiny: the server preflight intentionally runs many positive and
negative production configuration cases. CI runs the same command through the
`Production Static Gate` workflow for production-facing config, deploy, and
runbook changes.
When the command reaches the end successfully, it writes a local static gate
receipt at `IMServer/LoadTests/results/production-static/latest.json`. Re-check
that receipt with `make verify-production-static-receipt`; it proves the local
gate completed recently and binds the latest production completion status
summary by sha256 plus the current repository root, commit, branch, dirty count,
and dirty status hash, but it is not runtime production evidence.
Generated load-test accounts, results, login cache files, and token cache files
are local runtime artifacts. Account CSVs can contain reusable login
credentials, and login/token cache files can contain reusable access tokens, so
they must stay out of Git, Docker build contexts, and production evidence
packages. The static gate enforces `.gitignore` and `IMServer/.dockerignore` behavior for
`IMServer/LoadTests/accounts/`, `IMServer/LoadTests/results/`,
`IMServer/LoadTests/**/*login-cache*`, `IMServer/LoadTests/**/*token-cache*`,
`IMServer/LoadTests/**/*token_cache*`, and `IMServer/reports/`, and it rejects
rules that re-include token cache files.

Before treating a branch as production-ready, run the broader local gate:

```sh
make validate-production-gates
```

This adds the LoadTests validation suite, including production profile/catalog
audits, production evidence packaging self-tests, security-group documentation
guards, readiness/playbook command generation, and scenario coverage checks. CI
runs this heavier command through the `Production Gates Validation` workflow for
production evidence, LoadTests, deployment, and runbook changes, and uploads the
validation artifacts for review.

For the IMServer release build/test gate, use the fixed Makefile entrypoints:

```sh
make check-imserver-production-release-gate
make check-imserver-production-smoke
make run-imserver-production-smoke
make verify-imserver-production-smoke
make install-production-smoke-receipt
make run-imserver-production-release-gate
make verify-imserver-production-release-gate
```

`check-imserver-production-release-gate` is a lightweight CLI-contract self-test
for the release gate and is included in `make validate-production-static`.
`check-imserver-production-smoke` is a local static check for the Docker
production-smoke topology: it shell-checks `production_smoke.sh` and verifies the
compose file's smoke-only credentials, local MinIO wiring, and explicit insecure
endpoint override before any Docker runtime is required.
`run-imserver-production-smoke` is the Docker runtime topology proof: it builds
the smoke image, runs migrations through the `ops` role, starts `gateway`,
`command-api`, `query-api`, `outbox-relay`, and every `stream-consumer-*` role,
waits for container health plus HTTP `/health`, then exercises auth,
conversation creation, message write, summary/changes projection, metrics
protection, and outbox recovery. A passing static check is not a substitute for
this runtime smoke when claiming production readiness. The runtime smoke writes
`IMServer/reports/latest-production-smoke.json`, and
`verify-imserver-production-smoke` validates that receipt, required checks, and
runtime artifacts. `install-production-smoke-receipt` installs that verified
receipt plus its referenced artifacts into the production readiness location,
defaulting to `/var/lib/imserver/production-smoke/latest-production-smoke.json`.
`run-imserver-production-release-gate` runs `IMServer/scripts/production_release_gate.sh`,
including production env preflight checks, protobuf drift checks, release builds,
and full Swift tests by default, then verifies the generated JSON receipt before
the target can pass. The release gate writes both a Markdown report and a
machine-readable JSON receipt under `IMServer/reports/`; the receipt records the
final status, source git metadata, whether Swift tests ran, and every gate step
with its log file and exit code. The latest receipt is also copied to
`IMServer/reports/latest-production-release-gate.json`, and
`make verify-imserver-production-release-gate` re-verifies that receipt by
default with `--require-pass --require-release-run --require-swift-tests`.

For ordinary IM product coverage beyond isolated large-group fanout, use the
operator-facing wrappers instead of calling LoadTests scripts by path:

```sh
make run-non-large-group-regression-plan
make check-non-large-group-regression
make run-non-large-group-regression

make run-product-test-plan-plan
make check-product-test-plan
make run-product-test-plan

make run-product-scenario-suite-plan
make check-product-scenario-suite
make run-product-scenario-suite
```

These targets still require the same runtime environment as the underlying
scripts (`BASE_URL`, `TCP_HOST`, `TCP_PORT`, `ACCOUNT_FILE`,
`IM_CONVERSATION_ID`, and `IM_INTERNAL_SECRET`) when they execute real traffic.

For long-running production operations, use the fixed make wrappers so backup,
restore-drill, audit, and alert checks stay discoverable:

```sh
make check-production-ops
make run-production-readiness-gate
make run-operational-audit
make create-backup-single-node
make verify-backup
make run-restore-drill
```

Timer and offsite operations use the same entrypoint style:

```sh
make install-operational-audit-timer
make install-backup-timer
make install-restore-drill-timer
make sync-offsite-backup
make send-operational-alert
```

`make check-production-ops` is local and runs the production operations
self-tests. The other targets execute the underlying deploy scripts; run them on
the production host with the same root privileges and environment variables
documented in [deploy/ubuntu/README.md](/Users/yyl/Desktop/Code/IMMonorepo/deploy/ubuntu/README.md).

These local gates prove that the code, templates, scripts, and runbooks enforce
the production policy. They do not replace real production evidence. A final
production claim still requires a real DNS HTTPS target, public TCP gateway,
fresh Aliyun security-group JSON plus verified repair receipt, current
production topology-smoke receipt, current production readiness artifacts, and
production acceptance/load-test evidence generated for the actual target.
When `make run-production-readiness-gate` succeeds on a host, it also writes the
operator-facing readiness receipt at `/var/lib/imserver/readiness/latest.json`
by default. Keep that file with the production evidence bundle; it records which
hard gates were actually enforced by the successful node-readiness run.

Current production readiness status:

- Code, templates, local service helpers, production config guards, workflow
  audits, acceptance env validators, evidence package verifiers, and the final
  `assert-production-ready` wrapper are present and covered by static gates.
- This repository state is not itself production-ready until live evidence is
  generated for the real public target. Local runs, simulator builds,
  `127.0.0.1`, LAN IPs, placeholder domains, old temporary server IPs, smoke
  account files, and screenshots do not satisfy the production claim.
- The only acceptable final assertion is `make assert-production-ready` with
  `BASE_URL`, `TCP_HOST`, `TCP_PORT`,
  `PRODUCTION_TOPOLOGY_SMOKE_RECEIPT_JSON`,
  `PRODUCTION_DEPLOY_READINESS_RECEIPT_JSON`,
  `CURRENT_PRODUCTION_READINESS_JSON`, `PRODUCTION_ACCEPTANCE_RECEIPT_JSON`,
  and `PRODUCTION_EVIDENCE_PACKAGE` pointing at the same real HTTPS/DNS/TCP
  deployment and current topology/deploy/runtime evidence.
- Use `make production-readiness-status` to report missing production target
  and evidence inputs before the final assertion. This status command is a
  preflight only; it confirms the topology smoke receipt is fresh and passing,
  the deploy readiness and local static gate receipts are fresh and passing,
  the readiness/receipt target matches the configured public target, and the
  evidence package target matches too, but it does not run traffic and does not
  replace `make assert-production-ready`.
- Use `make production-completion-status` when you need a repeatable completion
  estimate while the production host is unavailable. It writes
  `IMServer/LoadTests/results/production-completion-status/latest.json` and
  `IMServer/LoadTests/results/production-completion-status/latest.md`. The JSON
  is the machine-readable gate input; the Markdown is the operator-readable
  handoff record. `make verify-production-completion-status` verifies that the
  Markdown still matches the JSON report exactly. `make validate-production-static`
  also sha256-binds both files into the static receipt. Both report
  `localCompletionPercent` for code/scripts/docs/workflows and
  `productionCompletionPercent` with live production evidence included. This is
  a planning report only. It requires a fresh local static gate receipt for a
  full local score, but it does not replace real runtime evidence,
  `make assert-production-ready`, or `make verify-production-ready-archive`.
  The JSON also includes `readinessTiers`: `localEngineering` is the local
  code/script/workflow maturity tier, `liveProductionEvidence` is the current
  verified runtime-evidence tier, and `productionReady` is blocked until the
  final assertion plus archive both verify against the same public target.
  The text summary splits `localMissing`, `liveEvidenceMissing`, and
  `recoveryPlan` counts so local engineering gaps cannot be confused with
  missing live production proof.
  Each `recovery item=` line in the text output is the command-level recovery
  checklist for missing live evidence: run the listed `run=` command, then the
  listed `verify=` command, and re-run `make production-completion-status`.
  Recovery lines are operator instructions, not proof; only the verified
  receipts and archives they produce can satisfy live production evidence.
  Before executing recovery commands on a live target, export the required
  evidence paths and target variables, then run
  `make validate-production-evidence-recovery-env`. That target runs the
  non-mutating recovery preflight: it first verifies the local static receipt is
  still fresh, then verifies the recovery plan and generated
  `evidence-recovery-run.sh` still match the bound completion status, then runs
  the generated script in `PRODUCTION_EVIDENCE_RECOVERY_VALIDATE_ONLY=true`
  mode. That final dry-run validates required variables and the same shared
  public production target policy used by production acceptance, including
  placeholder-domain, raw-IP/local-host, URL path/query, and TCP port rejection,
  then exits before any recovery command is executed.
  By default `make production-evidence-recovery-plan` is strict and refuses to
  generate a live-evidence recovery plan while local engineering is incomplete.
  For operator diagnostics only, run
  `make production-evidence-recovery-plan-diagnostic`
  to render the same plan with a `Local Gate First` section that lists local
  blockers such as a dirty static gate receipt. It writes `diagnostic-latest.*`,
  `diagnostic-evidence-recovery-plan.*` and `diagnostic-evidence-recovery-run.sh`
  so diagnostic output cannot overwrite the strict completion-status or
  evidence-recovery artifacts. Verify diagnostic output with
  `make verify-production-evidence-recovery-plan-diagnostic`. Do not use that
  diagnostic plan as production evidence. The diagnostic targets fail fast if a
  diagnostic output path is configured to the same path as a strict artifact.
  If the local blocker is `git_binding_mismatch`, read the diagnostic fields
  such as `field=dirtyCount`, `currentTrackedModifiedCount=...`, and
  `currentUntrackedCount=...`: the static receipt was generated for a
  different git worktree state. Run `make production-worktree-inventory` for a
  quick text summary, or `make production-worktree-inventory-json` to write
  `IMServer/LoadTests/results/production-worktree-inventory/latest.json` for
  comparison. To inspect one suggested commit group, pass
  `PRODUCTION_WORKTREE_INVENTORY_ARGS='--group deploy-ops --paths-only'`.
  Use `make production-worktree-plan` for a read-only commit-group review plan
  with path-list, tracked diff review, source_change-only stageCommand, dry-run
  receipt command, validation commands, and suggested commitCommand.
  Use `make production-worktree-commit-runbook` to write a reviewable shell
  runbook for the full group sequence; verify it with
  `make verify-production-worktree-commit-runbook` before running any command
  from it. The runbook is generated only; it is not executed by the target.
  If you execute the generated runbook after review, it refuses to run unless
  `IMSERVER_WORKTREE_RUNBOOK_CONFIRMED=reviewed` is set.
  Use `make production-worktree-plan-json` to write the same plan as machine-readable JSON, and
  `make verify-production-worktree-plan-json` before using a saved plan. The JSON plan is
  bound to the current git status fingerprint.
  Run the stageDryRunCommand before the real stageCommand, then run
  the stageDryRunReceiptCommand or `make production-worktree-stage-dry-run`
  with the same `--group` to write a machine-readable dry-run receipt, and
  `make verify-production-worktree-stage-dry-run` to prove the saved receipt is
  still bound to the current worktree. To preflight every source_change group
  at once, run `make production-worktree-stage-dry-run-batch` and
  `make verify-production-worktree-stage-dry-run-batch`. Then run
  `make verify-production-worktree-staging` and `make verify-production-worktree-staged-group`
  before committing. The staged-group check also rejects missing source_change
  paths from that group, extra staged paths, and files that still have
  unstaged worktree edits after staging. The stageCommand and commitCommand are not executed by the plan; review the paths first.
  Untracked source_change files are listed separately because plain git diff does not show them.
  Generated local artifacts and forbidden runtime artifacts are listed with separate
  cleanup commands instead of being included in the suggested stageCommand.
  Commit intended source changes, remove forbidden runtime artifacts, and ignore
  only generated local artifacts before rerunning `make validate-production-static`.

Production target contract:

- `BASE_URL` must be the public HTTPS origin only, after replacement for
  example `https://chat.prod.company.com`. Do not include `/api`, query
  strings, fragments, username/password, raw IPs, local/LAN hosts, wildcard
  hosts, trailing dots, surrounding whitespace, placeholder domains, or a
  non-default HTTPS port.
- `TCP_HOST` must be a real public DNS host only, after replacement for example
  `tcp.prod.company.com` or the same host as `BASE_URL`. Do not include
  `:9000`, raw IPs, local/LAN hosts, wildcard hosts, underscores, trailing dots,
  surrounding whitespace, or placeholder domains.
- `TCP_PORT` must be `9000` for final production acceptance. Temporary
  bootstrap ports or alternate public TCP ports are rejected by the production
  readiness, acceptance, verification, and final assertion wrappers.
- Check the same shared policy locally with
  `python3 IMServer/LoadTests/production_target_policy.py --self-test`; it is
  also exercised by `make validate-production-static`.

For a live target, use the current production readiness entrypoint before
starting final acceptance. It validates the operator network path, probes the
public HTTPS/TCP entrypoints, records rescue artifacts when the entrypoint is
blocked, and writes the current readiness/dashboard/state artifacts:

```sh
set -a
. IMServer/LoadTests/production-acceptance.env
set +a
make run-current-production-readiness
CURRENT_PRODUCTION_READINESS_JSON=IMServer/LoadTests/results/current-production-readiness/current-production-readiness.json \
  make verify-current-production-readiness
```

After `run_production_acceptance.sh` generates the final receipt and evidence
package, verify the package against the exact public target before calling the
deployment production-ready:

```sh
cp IMServer/LoadTests/production-acceptance.env.example IMServer/LoadTests/production-acceptance.env
# Export real DNS targets, account CSV, conversation UUID, and secrets, or
# replace the fail-fast assignments in production-acceptance.env directly.
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
# keep PRODUCTION_STATIC_GATE_RECEIPT_JSON pointed at
# IMServer/LoadTests/results/production-static/latest.json from the successful
# local static gate,
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

This checks the receipt target, freshness, package checksum, package contents,
production topology-smoke receipt, deploy readiness receipt, current production
readiness artifacts, local static gate receipt, cloud security-group snapshot,
and verified repair receipt.
`PRODUCTION_EVIDENCE_PACKAGE` is required so the final verification never falls back to a stale package path
embedded in a local receipt. `make assert-production-ready` is the final
no-shortcut assertion: it requires the topology smoke receipt to pass with its
artifacts present, requires the deploy readiness receipt to show production hard
gates were enforced, requires a fresh `PRODUCTION_STATIC_GATE_RECEIPT_JSON`,
and requires both `CURRENT_PRODUCTION_READINESS_JSON` and the production
acceptance receipt/package to verify against the same real public target.
On success, `make assert-production-ready` writes a final machine-readable
`imserver-production-ready-assertion` receipt to
`IMServer/LoadTests/results/production-ready/latest.json` by default. Override
`ASSERT_PRODUCTION_READY_RECEIPT_JSON` when archiving the final proof elsewhere.
Use `make verify-production-ready-assertion` to re-check that receipt's target,
freshness, `productionClaim`, and sha256/size records for the bound evidence
files. The verifier also re-runs the shared public production target policy, so
an archived or copied assertion is rejected if it points at a placeholder
domain, raw IP/local host, URL path/query, or a TCP port other than `9000`. The
final claim must be `productionReady=true`, `claimAllowed=true`, and
`basis=verified-final-production-evidence`; local/static receipts are not
allowed to make that claim.
If the bound evidence files have been copied into an audit archive, set
`PRODUCTION_READY_ASSERTION_ARTIFACT_ROOT=/path/to/archive` so the verifier can
resolve artifacts from the archive instead of the original host paths.
`make package-production-ready-assertion` creates a self-contained archive under
`IMServer/LoadTests/results/production-ready/archive/` by default, with
`production-ready-assertion.json`, copied evidence under `artifacts/`, a
manifest, `SHA256SUMS`, and a tarball suitable for handoff.
`make verify-production-ready-archive` verifies an existing tarball's member
safety, required files, `SHA256SUMS`, archive manifest, and final assertion
evidence binding before it is accepted as a handoff artifact. The archive
manifest must carry the same final `productionClaim` as the archived assertion;
`make verify-production-ready-archive` rejects claim drift or a missing final
claim. The final archive must include static gate support artifacts under
`artifacts/productionStaticGateReceipt/support/`, including the bound
production-completion status and evidence-recovery plan files. Portable
verification uses `--require-static-gate-support-root` so the archive is checked
against its own support copies instead of any original host paths.
The archive manifest must stay portable: it records archive-relative paths,
file names, sizes, and hashes, and must not include original machine paths such
as `sourcePath`, `sourceReceipt`, or `archiveFile`. Its
`sourceReceiptFileName` and `archiveName` fields must be plain file names, not
absolute or relative paths; the tarball itself may still be renamed by an
external artifact store after packaging. Its `generatedAt` UTC timestamp and
`generatedAtEpoch` must also parse and agree with each other, and verification
rejects manifest timestamps that are beyond the allowed future-skew window or
earlier than the archived `production-ready-assertion.json` generation time.
The archive README is checked as part of verification too: its status, target,
TCP port, and archive name summary must match the archived assertion and
manifest, not merely contain generic verification instructions.
The archived `production-ready-assertion.json` is also rewritten to bind its
artifact records to `artifacts/<artifactKey>/...` paths inside the archive, so
the handoff artifact does not depend on or reveal the original build host.
The archived static gate receipt is rewritten as well: its completion-status
and recovery-plan bindings point at
`artifacts/productionStaticGateReceipt/support/...` copies in the same archive.
The copied static support JSON is portable too: completion-status `repoRoot`
uses the archive placeholder `/imserver-production-ready-archive/repo`, and the
recovery plan points `sourceStatusJson` at the copied completion-status file.
The final archive
also rejects runtime artifacts such as `load-*.csv`, account CSVs, login/token
cache files, and non-example `.env` files, even when they are nested under
`artifacts/`.

Manual local text IM testing:

- See `docs/LOCAL_TEXT_IM_TESTING.md` for the two-account checklist covering contacts, direct chats, two-member groups, stranger limits, retries, and restart recovery.
- See `docs/core-implementation-guide.md` for the core server/client runtime flow before changing timeline, outbox, store merge, cache restore, or AI stream behavior.

## Architecture Boundary

`IMClientKit` is the reusable client SDK boundary. It should not import SwiftUI and should not depend on app-only constants. App-specific configuration is injected from `IMApp`.

`IMApp` owns UI and application orchestration. Views and `AuthManager` consume public SDK APIs from `IMClientKit`.

`IMServer` remains the protocol and persistence authority. Client package extraction must not change HTTP/TCP protocol semantics unless a backend change is planned in the same phase.

## Protocol Notes

Message payloads now use a typed `content` object instead of `kind` plus arbitrary string dictionaries. The current text shape is:

```json
{
  "type": "text",
  "text": "hello"
}
```

Conversation summaries no longer rely on a single full-list endpoint:

- `GET /api/im/conversations?limit=&cursor=` returns `items`, `nextCursor`, `hasMore`, and `snapshotToken`.
- `GET /api/im/conversations/changes?afterToken=&limit=&cursor=` returns `upserts`, `removedConversationIDs`, `nextCursor`, `hasMore`, and `targetToken`.

## Monorepo Rules

- Keep cross-project changes in one branch when a feature requires client SDK, app, and server changes together.
- Do not reintroduce copied SDK source files into `IMApp`; shared client logic belongs in `IMClientKit`.
- Keep generated build outputs out of git.
- Prefer adding tests in the layer that owns the behavior:
  - SDK/network/store tests in `IMClientKit/Tests`.
  - App orchestration/UI-adjacent tests in `IMApp/IMAppTests`.
  - API/service/database tests in `IMServer/Tests`.
