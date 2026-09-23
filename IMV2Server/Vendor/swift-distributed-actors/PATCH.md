# Bounded inbound framing patch

Base: `apple/swift-distributed-actors` revision
`50e789fbb6db9a9869a60b1915e659bd752e1d42` (see `UPSTREAM.json`).
The copied production source differs from upstream only in:

- `ClusterSystemSettings.swift`: adds a validated, finite `ClusterInboundFrameLimit`
  and `maximumInboundFrameBytes` setting (16 MiB default).
- `Cluster/Transport/TransportPipelines.swift`: installs the same bounded reader
  and close-on-error handler in accepting and initiating pipelines, after TLS
  and protocol magic and before handshake/deserialization.
- `Cluster/Transport/BoundedInboundFraming.swift`: new four-byte big-endian
  decoder. It rejects an over-limit declared length as soon as the header is
  complete, caps NIO's cumulation buffer at payload limit plus four bytes,
  and closes the channel on framing errors.

`Package.swift` retains the upstream production target dependency products,
Swift language mode, and remote dependency version ranges. It omits upstream
non-shipping tests, tools, plugins, docs, and their `swift-argument-parser`
dependency. This vendor includes license, notice, and contributor attribution.
`Tests/DistributedClusterBoundedFramingTests` are local regression tests.

The setting bounds an individual length-prefixed transport frame. It does not
limit concurrent trusted-peer connections, TLS handshake state, CPU spent on
valid framed payloads, or the application's request/admission budget. The
application must configure enough envelope overhead above its request size.
