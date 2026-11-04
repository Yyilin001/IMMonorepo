# PostgreSQL message-write profiles

`2g-message-write.conf` targets the 2 GiB PostgreSQL container on the 4-vCPU
capacity-test host. It is separate from the larger database profile in the
server Compose override. Keep `fsync`, `synchronous_commit` and
`full_page_writes` enabled. The checkpoint interval remains five minutes.

## Optional allocator override

`allocator.override.yml` preserves the PostgreSQL image and data volume and
preloads a verified jemalloc library. It is opt-in and requires a controlled
database restart. The measured target is PostgreSQL 16.15, Alpine 3.24.2,
x86_64, with a 2 GiB database memory limit. Do not reuse this binary on a
different architecture or libc/image without checking compatibility.
The override pins the measured image digest so a moving `16-alpine` tag cannot
silently change the library's runtime dependencies on a later deployment.

Artifact used in the capacity experiment:

- Official package: `https://dl-cdn.alpinelinux.org/alpine/v3.24/main/x86_64/jemalloc-5.3.0-r6.apk`
- Verify the package using `apk verify` and the matching image's trusted Alpine
  keys before extracting `usr/lib/libjemalloc.so.2`.
- Extracted library SHA-256:
  `e1f34e6f54786492bb91eb4865130df4768be3f4bec7c6db32decac772b22ead`.
- Verify dependencies with `ldd` and launch `postgres --version` with the
  proposed `LD_PRELOAD` and `MALLOC_CONF` before deployment.

Set `IM_V2_POSTGRES_ALLOCATOR_LIBRARY` to the absolute host path of that library
and add this override to the existing Compose invocation. It mounts the library
read-only. Preserve the existing Compose project, image, environment, database
volume and resource limits. Never use `down -v` for this change.

The profile uses one arena per process, a one-second dirty-page decay, immediate
muzzy-page decay, and no allocator background thread. This limits retained
memory while allowing repeated allocations to reuse pages. Observe actual
container memory, reclaim, OOM counters and throughput; a lower page-fault count
alone is not sufficient validation.

Drain/stop front-end writers before recreating PostgreSQL, wait for database
readiness, restart front-end services, and verify health and end-to-end message
completion. In deployments where Caddy shares the account container's network
namespace, stop/start the pair together. Verify the library in the postmaster's
`/proc/<pid>/maps` and confirm all three durability settings remain `on`.

Rollback removes the allocator mount and both environment entries from the
previously saved Compose configuration, then follows the same controlled restart
procedure. It does not restore or replace the database contents.

The CPU/WAL experiment also tested `commit_delay=1000` microseconds. That reduced
flush frequency but worsened throughput, so the deployment retains the default
`commit_delay=0` and `wal_sync_method=fdatasync`. Cross-room transactions and
per-room ordering are unchanged. This profile makes no general capacity promise;
use the recorded load-test results for the measured deployment.

## File-cache allowance

The 2 GiB allocator trial reduced CPU consumption but still encountered cache
reclaim and queue overflow during the 630-second load test. The separate
`4g-capacity.override.yml` raises the database container limit to 4 GiB on the
measured 8 GiB host; it does not increase `shared_buffers` beyond 512 MiB.
Check host memory headroom before applying it. `memswap_limit: 5g` is the combined
memory-plus-swap allowance, not 5 GiB of RAM; the measured host had no swap.

Persist both memory settings in the deployment configuration when using
`docker update` to apply them without a restart. Record the previous limits for
rollback. Verify memory events, cache refaults, checkpoint overlap and message
completion under sustained load rather than relying on an idle-memory reading.

## Larger shared buffer pool

`4g-message-write.conf` is the database profile for the 4 GiB container. Use it
instead of `2g-message-write.conf` when testing the larger buffer pool; the
resource override alone does not load either PostgreSQL configuration file.
It sets `shared_buffers=1536MB` and retains the other write-profile settings.
The remaining container allowance must cover backend memory and file cache;
check host memory, cgroup reclaim and OOM events during the full workload.

The measured 512 MiB pool produced far more background-writer pages than
checkpoint pages as message indexes grew. Increasing the pool tests whether
cache eviction and repeated dirty writes are driving storage contention.
Do not treat this as proof that a cloud disk is or is not throttled. Compare
cloud-side IOPS/latency with PostgreSQL I/O counters, WAL sync latency and
message completion over checkpoint cycles. Kernel disk requests and cloud
metering need not have identical IOPS counts.

Save the current configuration before changing the pool. Stop front-end writers,
apply the setting, restart PostgreSQL, then restart the front-end services and
verify health, the effective buffer size and all durability settings. The tested
rollout uses `ALTER SYSTEM SET shared_buffers='1536MB'`; remember that
`postgresql.auto.conf` overrides settings in an included profile. Roll back with
`ALTER SYSTEM SET shared_buffers='512MB'` and the same controlled restart.
Neither operation replaces database contents. Timing instrumentation is temporary
and must be disabled after collecting the diagnostic results.

For WAL tail analysis, distinguish interval averages from individual sync-call
percentiles. A sampled `fdatasync` duration includes process scheduling as well
as storage waiting. Classify descriptors as WAL/data only when their category
matches before and after the trace; retain unknown descriptors separately.
Cloud minute averages cannot establish millisecond throttling, and a monitoring
API returning only zeroes must not be used as evidence of an idle disk.

## Additional file-cache headroom (5 GiB capacity profile)

`5g-capacity.override.yml` raises only the PostgreSQL container allowance to
5 GiB (combined memory-plus-swap allowance: 6 GiB). It keeps the measured
1536 MiB `shared_buffers`, checkpoint settings and durable commit settings.
Use it only after checking the co-located services and host memory headroom;
it is not a universal sizing rule or a substitute for CPU capacity.

The November 2 tail-latency diagnostic observed a 4737 MiB peak with no
`memory.events.max` or OOM increments, versus 6121 max-limit events in the
previous 4 GiB long run. File-page refault and global reclaim remained. The
profiled run still overflowed its client send queue, so eliminating the cgroup
limit events alone did not establish 1000 messages/second capacity. Diagnostic
profiling also perturbs performance; use the separate unprofiled verification
and its complete queue/receipt/receiver evidence for acceptance.

Persist resource changes in the active Compose configuration when applying
`docker update`. The online 4→5 GiB adjustment does not require a database
restart. A rollback can restore the previous 4 GiB profile, but reducing the
limit below current usage may cause reclaim; do it after load drains and verify
health, memory pressure and the actual container limit. Do not disable vacuum,
fsync, synchronous commit, or full-page writes to meet a benchmark.

## Pace large-table maintenance

`paced-maintenance.sql` is an opt-in operational profile for the measured small
shared-disk host. It sets a per-table autovacuum cost limit of 20 with a 2 ms
cost delay on `messages` and `message_send_completions`. The previous defaults
used the global limit of 200 and 2 ms delay. This reduces the cost budget per
maintenance work cycle; it is not a hard disk bandwidth or IOPS limit.

The aim is to spread VACUUM/ANALYZE work when random maintenance reads compete
with synchronous WAL commits. Autovacuum stays enabled, with unchanged analyze,
insert-vacuum and freeze thresholds; the settings do not alter message content,
ordering, visibility or transactions. Small tables retain their existing
settings. Per-table cost overrides are excluded from global worker cost
balancing, so reassess the aggregate budget if more tables receive overrides.
See the PostgreSQL 16 [cost delay](https://www.postgresql.org/docs/16/runtime-config-resource.html#RUNTIME-CONFIG-RESOURCE-VACUUM-COST)
and [autovacuum](https://www.postgresql.org/docs/16/runtime-config-autovacuum.html)
documentation.

Record existing `pg_class.reloptions` before applying the SQL, then verify actual
VACUUM/ANALYZE completion, dead tuples, insert counts since vacuum and long-run
latency. Slower maintenance is a tradeoff: do not retain this profile if it
allows maintenance backlog to grow. The companion rollback script resets only
these two options and is suitable only when they were originally unset;
otherwise restore the recorded original values. Both scripts bound lock and
statement waits and apply the two table changes atomically.

The 630-second unprofiled trial with this per-table profile sent, acknowledged
and delivered all 630,000 scheduled messages: zero queue overflows, zero queued
messages at phase end and zero missed heartbeats. The preceding 5-GiB trial
with default maintenance pacing overflowed 6,899 scheduled messages. Send-to-ACK
P99 fell from 409 to 253 ms; scheduled-to-ACK P99 from 5138 to 695 ms. Completion
ANALYZE took 20.22 seconds instead of 9.75; message-table VACUUM completed in
130.50 seconds, and both tables completed automatic ANALYZE. This trial did
not cover a complete completion-table VACUUM under the new cost settings.
CPU averaged 84.52%, and memory-limit reclaim still occurred; neither CPU nor
memory pressure is eliminated. Dataset growth, cache state and checkpoint
phase differ between runs, so retain ongoing maintenance/capacity monitoring
instead of treating this one pass as a permanent guarantee.
