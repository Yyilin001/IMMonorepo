# P0/R3 bounded inbound transport evidence

This patch closes the pre-deserialization frame-size gap identified in
[`p0-evidence.md`](p0-evidence.md). The production dependency is a local,
auditable copy of `apple/swift-distributed-actors` at revision
`50e789fbb6db9a9869a60b1915e659bd752e1d42`. The vendor's `UPSTREAM.json`
records the original package and source tree hashes; `PATCH.md` describes the
two changed upstream source files and the one added framing source. The copied
production targets, license, notice, and attribution are in
`IMV2Server/Vendor/swift-distributed-actors`. Upstream tests, tools, plugins,
and docs were not copied into the shipping package. The root SwiftPM lockfile
removes only the remote actor revision entry; every other dependency pin stays
unchanged.

`ClusterSystemSettings.maximumInboundFrameBytes` now has a validated finite
`ClusterInboundFrameLimit` value (16 MiB default; valid bytes 1 through
`Int32.max`). The same bounded decoder is installed in incoming and outgoing
cluster pipelines after TLS and protocol magic, before handshake and envelope
deserialization. It reads the four-byte big-endian length header and rejects a
declared payload larger than the configured bound as soon as that header is
complete, without waiting for body bytes. NIO's cumulation limit is payload
limit plus four header bytes; a framing error closes the channel. The P0 probe
sets a 1 MiB transport bound above its 64 KiB application request limit.

The local vendor regression tests run with Linux Swift 6.4 and pinned root
dependencies in a writable scratch copy. `swift test --jobs 2 --filter
BoundedFramingTests` exited **0**: three tests covered validation, a fragmented
oversized header with no body and channel closure, an exact-boundary frame,
and consecutive frames through both accepting and initiating framing paths.
The test log is
`/Users/yyl/.codex/virtual-actor-builds/transport-vendor/test-pinned.log`.

The full P0 Linux Release two-process rerun exited **0** and printed
`P0_PROBE_OK`. It used the isolated Compose project `imv2-va-p0`, source
read-only, and host-bind scratch under
`/Users/yyl/.codex/virtual-actor-builds/p0`. The actual command was:

```sh
VA_EVIDENCE_DIR=/Users/yyl/.codex/virtual-actor-builds/p0/bounded-evidence \
VA_BUILD_DIR=/Users/yyl/.codex/virtual-actor-builds/p0 \
IMV2Server/Tests/VirtualActorCompatibilityProbe/run-linux-release.sh
# exit 0
```

`release-build.log` records `swift build --scratch-path /build -c release
--product VirtualActorCompatibilityProbe -j 2` finishing in 141.68 seconds,
with the local actor package in the real Vapor/PostgreSQL dependency graph.
The pre-existing local/remote `postgres-nio` identity warning remains. The
real transport negative probe completed mTLS with a trusted client certificate,
sent only protocol magic plus a four-byte header declaring 1,048,577 bytes
against the configured 1,048,576-byte cap, and received connection close
without sending a body (`oversized-tls-header.log`: `TLS_ESTABLISHED`,
`OVERSIZED_HEADER_CLOSED`). The source for that probe is
`IMV2Server/Tests/VirtualActorCompatibilityProbe/oversized-tls-header.py`.

The same run retained P0's two-process assertions: `client.log` has
`REMOTE_OK`, signed call/tamper/false-service checks, typed domain errors,
`STALE_REF_FAILED`, `NEW_REF_OK`, and `CLIENT_STOPPED`. A separate client with
the wrong CA emitted `UNTRUSTED_TLS_REJECTED`. Both host incarnations emitted
`DB_READY`, `HOST_READY`, `HOST_DRAIN`, `HTTP_STOPPED`, and `ALL_STOPPED`; the
failed database startup exited nonzero with `PROBE_FAILURE`. The probe removed
its own containers, network, and database after completion. Saved logs are
under `/Users/yyl/.codex/virtual-actor-builds/p0/bounded-evidence`; the
driver transcript is `/Users/yyl/.codex/virtual-actor-builds/p0/bounded-run.log`.

This is a per-frame bound. It does not bound the number of authenticated peer
connections, TLS handshake memory, CPU for valid frames, or application work.
The host admission and encoded outbound-size checks remain separate controls.
