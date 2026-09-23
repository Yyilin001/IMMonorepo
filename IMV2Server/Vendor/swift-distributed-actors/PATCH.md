# Local DistributedCluster patches

Base: `apple/swift-distributed-actors` revision
`50e789fbb6db9a9869a60b1915e659bd752e1d42` (see `UPSTREAM.json`).
The copied production source differs from upstream only in:

- `ClusterSystemSettings.swift`: adds a validated, finite `ClusterInboundFrameLimit`
  and `maximumInboundFrameBytes` setting (16 MiB default).
- `Cluster/Transport/TransportPipelines.swift`: installs the same bounded reader
  and close-on-error handler in accepting and initiating pipelines, after TLS
  and protocol magic and before handshake/deserialization. Its initiating
  handshake handler also reports channel close/error and a ten-second missing
  response timeout exactly once.
- `Cluster/Transport/BoundedInboundFraming.swift`: new four-byte big-endian
  decoder. It rejects an over-limit declared length as soon as the header is
  complete, caps NIO's cumulation buffer at payload limit plus four bytes,
  and closes the channel on framing errors.
- `Cluster/HandshakeStateMachine.swift` and `Cluster/ClusterShell.swift`: add
  closed/timeout failure reasons and remove an outbound handshake from the
  in-flight state after failure or rejection. Discovery's next bounded join
  can then reach a new process incarnation after a peer dies mid-handshake.
- `Cluster/MembershipGossip/Cluster+MembershipGossip+Serialization.swift`:
  omit seen-table rows whose node incarnation is no longer in the encoded
  membership, and tolerate those rows from older peers on decode. The owner
  must still be in membership and have a seen row; current-member versions
  remain intact. The Server package's `V2MembershipGossipRestartTests` covers
  this patch in its regular test target.

`Package.swift` retains the upstream production target dependency products,
Swift language mode, platform runtime requirements (including Linux's nil
platform list), and remote dependency version ranges. It omits upstream
non-shipping tests, tools, plugins, docs, and their `swift-argument-parser`
dependency. This vendor includes license, notice, and contributor attribution.
`Tests/DistributedClusterBoundedFramingTests` are local regression tests.

The frame setting bounds an individual length-prefixed transport frame. The
handshake watchdog bounds one connected but silent peer; NIO's existing
connection timeout and finite retry backoff cover resolution/connect attempts.
Neither patch replaces the application's request/admission budget. The
application must configure enough envelope overhead above its request size.
