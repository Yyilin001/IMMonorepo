# Local DistributedCluster patches

Base: `apple/swift-distributed-actors` revision
`50e789fbb6db9a9869a60b1915e659bd752e1d42` (see `UPSTREAM.json`).
The copied production source differs from upstream only in:

- `Cluster/Association.swift`, `Cluster/ClusterShell.swift`, and
  `Cluster/ClusterShellState.swift`: a physically inactive associated channel
  may atomically return to associating on the same Association object for
  outbound/inbound handshake. Active channels and permanent tombstones cannot
  reopen. Re-handshake with the same UID preserves membership; a different UID
  retains the original exact replacement/down behavior. Health timeout alone
  is not node death. The focused actual-channel-close/restart regression passed
  in r39. Production Actor-only blackhole/heal canary r54 also passed
  with the same live process/UID and physical clients: 120 clients, 348 TCP
  acknowledgements, zero missed heartbeats, complete final cursor/coverage
  proof. It used the original TTL/pool budget and production controller;
  this is functional evidence, not capacity or all network-fault acceptance.
- `Cluster/Reception/OperationLogDistributedReceptionist.swift`: pruning removes
  the retained peer by ActorID without resolving through a shut-down actor system.
  `V2ReceptionistShutdownTests` covers late and repeated pruning after shutdown.
- `ClusterSystemSettings.swift`: adds a validated, finite `ClusterInboundFrameLimit`
  and `maximumInboundFrameBytes` setting (16 MiB default).
- `Cluster/Transport/TransportPipelines.swift`: installs the same bounded reader
  and close-on-error handler in accepting and initiating pipelines, after TLS
  and protocol magic and before handshake/deserialization. Its initiating
  handshake handler also reports channel close/error and a ten-second missing
  response timeout exactly once after TCP activation. Inactive Happy Eyeballs
  candidates neither start that watchdog nor report a protocol failure when
  discarded; ClientBootstrap owns the aggregate resolution/connect failure.
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

The Server package's `discoversRestartedHost` regression closes the actual NIO
association channel, verifies a new active channel for the same live UID without
membership down, and then restarts the peer twice on the same port with new UIDs.
The focused r39 run passed; production silent network isolation remains a separate
integration gate (see `docs/reviews/actor-realtime-routing-evidence.md`).

The frame setting bounds an individual length-prefixed transport frame. The
handshake watchdog bounds one connected but silent peer; NIO's existing
connection timeout and finite retry backoff cover resolution/connect attempts.
Neither patch replaces the application's request/admission budget. The
application must configure enough envelope overhead above its request size.

- `ClusterSystem.withCallID`：远程调用截止时间使用已有 NIO EventLoop 定时队列，
  不再为每次调用创建休眠的 Swift Task。先登记 continuation 再注册超时；回复、
  超时和 EventLoop 关闭通过同一个 in-flight 字典互斥取出 continuation，并在锁外恢复。
  `V2RemoteCallDeadlineTests` 验证正常回复、超时、迟到回复及关闭时未完成调用的结算。

- `WireEnvelopeHandler`：在异步序列化完成后按连接合并 flush；最多 32 帧或 64 KiB，
  单独到达的帧安排下一次 EventLoop 执行即 flush，关闭/移除时处理已写入内容。
  不合并房间事务，不增加跨连接调度队列。
- `WireEnvelopeCodec`：保留 Envelope PB 字段号和格式，直接写入 NIO 缓冲；接收侧
  payload 使用 ByteBuffer 切片，路由/manifest 仍走生成的 PB 校验与模型转换。
  保留重复嵌套字段合并、bytes 后值覆盖、未知字段跳过，并限制未知 group 嵌套深度。
  Server 的 `V2ClusterWireTransportTests` 验证线格式一致性、切片存储、畸形输入、
  flush 合并、帧数/字节上限及关闭边界；真实远程认证与超时测试验证调用行为。
