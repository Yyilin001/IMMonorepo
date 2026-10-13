# Gateway 设备字节额度与恢复通道设计

> 归档说明（2026-10-13）：以下保留设备字节额度设计及 r8 时点的历史审计，不能作为当前房间续期实现说明。当前已取消逐房间授权续期及 Host 周期 head probe；权限由提交后的内存 cut 和有序控制事件主动推进，Host–Gateway 共享控制会话随原生节点可达性及宿主资格事件失效，已移除独立业务心跳。权限控制只在有未确认事件时维护 ACK 超时任务，不读取逐房间数据库，也不提供 H 或成员权限；断线恢复建立新会话并重新获取可信基线。H/G/C 与设备字节额度的职责边界仍适用，历史问题是否已修复应以当前代码和回归结果为准。

本文是当前实现的只读审计和下一阶段实现建议。没有修改生产代码、冻结 Loader 或数据库，也没有构建、启动服务或重新执行测试。第一阶段 H/G/C 心跳闭环已接入；本阶段尚未实现设备正文 credit。

## 边界与进度含义

- **H**：当前合法房间订阅已接收的可信最大提交头；只有 Owner/Relay 的有序投递或可信基线可推进它。H 提示可合并，不能替代授权控制事件。
- **G**：Gateway 实际 socket enqueue 的观测。它证明本地写入接纳，不证明客户端收到、应用或持久化。
- **C**：该认证连接所代表设备报告的本地持久提交游标。正确客户端只在投影与连续游标同一 GRDB 事务提交后报告。服务端 accepted C 仅表示接纳报告，无法证明远端磁盘事实；它不发权限、不续租、不代替其他设备。
- **Source control receipt**：Gateway 对 exact fence 连续控制前缀的接纳。它用于 Source 的有序责任结算，与设备 C 是两种不同的确认。

现协议每条物理连接只有一个 detail-room interest，Heartbeat 数组上限为 1。新增 credit 不应扩大这个边界，也不应允许客户端提交任意房间查询。账号/设备撤销、房间授权与 Ready 各自保持现有生命周期。

## 已有实现与真实接入点

| 边界 | 当前实现 | 结论 |
|---|---|---|
| Source → Gateway | `V2RoomSubscriptionDeliveryPump` 按 peer/shard 合批；限制实际 calls、批次条目和编码字节；active RPC 与 retry 由同一 owner 关停并 join | 已有跨节点有界窗口，未等待设备 C |
| 房间共享 | `V2RoomSubscriptionRelay` 按 Gateway 共享 fence、成员控制和 pending 前缀；普通广播不携带每设备成员表 | 不应改为每设备跨节点订阅 |
| Gateway ingress | `V2GatewayRoomSubscriptionIngress.applyRoomSubscription` 验签来源/fence，经 Authority 应用后同步 offer 本地工作并返回 cumulative receipt | ACK 是 Gateway admission，不是设备持久提交 |
| 正文 fanout | Registry 编码一次，按真实 room/user/device interest 选目标，调用 `prepareNIOGroupEventAvailable` 与 `submitBatch` | 不跨 await 等待慢 socket；慢设备当前不直接占住 Source RPC |
| 设备队列 | `V2NIOGatewayForegroundWriter` 默认普通队列 256 KiB/32 帧；单次 drain 默认 64 KiB/32 帧；按 EventLoop lane 批调度，非 writable 时等待 channel 通知 | 已有本地队列预算与调度，没有 C 驱动的正文 flight 额度 |
| 实际写入权限 | NIO drain 在 `channel.write` 前调用 `Authority.enqueueIfCurrent`；scoped writer 在 `writeAndFlush` 前同样执行同步 gate | exact room/user/connection lifecycle、interest nonce、授权代、期限检查与 enqueue 不跨 await |
| H 保留 | HeadWorker 有界保留每 room 最大 H；ByteStream 单 detail-room 保留最新 H、offer 身份、实际提交身份 | 新的可信同 H offer 能再次实际提交；失效 permit 暂停等待新 offer，不忙重试 |
| H 补齐 | Owner/Relay 有序投递、可信基线；设备心跳读取 Gateway 已接纳的 H | 无逐设备 SQL；原生节点存活检测不查询或推进房间 H |
| 设备 C | Session 复用 Heartbeat；Authority 按 connection O(1) 读取合法 interest；ByteStream 接纳同 scope 单调 C 且 C≤H，即使无报告也返回本地状态 | 已有进度交换，尚未用它结算正文 bytes 或控制慢端状态 |
| 客户端持久边界 | `GRDBV2LocalSyncStore.roomProgressAppliedSequence` 只读取已提交房间 cursor；排除 snapshot activation、明确撤权、`history_incomplete` | 正文接收、服务端 G、latest-visible 摘要均不能替代 C |

源码依据：

- [共享 Pump](../../IMV2Server/Sources/IMV2ServerApplication/V2RoomSubscriptionDeliveryPump.swift)、[Relay](../../IMV2Server/Sources/IMV2ServerApplication/V2RoomSubscriptionRelay.swift)
- [Registry](../../IMV2Server/Sources/IMV2ServerGateway/V2DeviceConnectionRegistry.swift)、[NIO writer 与 queue](../../IMV2Server/Sources/IMV2ServerGateway/V2NIOGatewayChannelHandler.swift)
- [Authority](../../IMV2Server/Sources/IMV2ServerGateway/Gateway/V2GatewayRoomSubscriptionAuthority.swift)、[Ingress](../../IMV2Server/Sources/IMV2ServerGateway/Gateway/V2GatewayRoomSubscriptionIngress.swift)
- [ByteStream](../../IMV2Server/Sources/IMV2ServerGateway/V2GatewayByteStream.swift)、[HeadWorker](../../IMV2Server/Sources/IMV2ServerGateway/Gateway/V2GatewayRoomSubscriptionHeadWorker.swift)
- [客户端 heartbeat](../../IMV2ClientKit/Sources/IMV2ClientKit/V2ProtobufSyncTransport.swift)、[GRDB 提交游标](../../IMV2ClientKit/Sources/IMV2ClientKit/GRDBV2LocalSyncStore.swift)

## 尚缺的机制

### 溢出槽并非纯恢复提示

`V2GatewayForegroundWriteQueue.recoveryFrame` 保存的是调用者传入的完整 `ByteBuffer`，没有把正文转成 metadata-only H。普通队列满后，下一帧进入额外单槽；后续帧替换该槽。因此当前内存上界是普通 queue 预算加一个经上游 frame limit 验证的完整帧，不能声称所有 bytes 都包含在 256 KiB 内，也不能声称溢出已完成纯 H 降级。

普通队列保存帧与 permit closure；它没有 room/授权代/body sequence 的显式类型化索引。Authority 自己的 `stage/commit` pending 有索引、byte accounting 和撤权 purge，但真实 Registry NIO 快路径不经过这个 pending。撤权后的 NIO 旧帧会被实际 gate 拒绝；尚未具备在 room/授权代退休时立即移除它们并结算设备 credit 的实际接线。这里已保证权限拒绝，不能把它描述成已实现及时释放所有 queue 内存。

### 没有正文 flight credit 与慢设备状态机

当前 queue 限制待写 bytes，不限制 G 已推进而 C 长时间未推进的设备。正文 drain 使用可写性和批次预算，没有按该设备 C 释放的正文 flight spans，也没有明确 `body → head-only → catching-up → body` 状态。

当前共享 RPC ACK 已不等待 socket，这是正确边界。新 credit 必须完全在 Gateway 设备侧管理；不能让某设备未上报 C 占住 Pump 的 peer/global call credit，更不能把 Source cumulative receipt 改成等待所有设备 C。

### 恢复通道优先级仍须完整分配

Heartbeat 响应走原请求/响应预算，能在所有正文和 H notifications 被客户端丢弃后提供 H。它不新增轮询任务、不查 SQL、不续租。scoped Ready/H writer 会因 request 正在处理、pending response、foreground queue 非空等返回 busy，ByteStream 保留并重试；这与慢端 bytes 状态尚未联动。

需要明确正文、回复、授权控制/Ready/H 的分别预算及优先级。仅提高 socket queue 容量、缩短重试 sleep，或新增第二个周期 H writer，都不形成完整恢复通道。

已完成的通知丢失 canary（由 root 运行）包含真实丢帧、心跳 H 触发恢复和最终游标追平；它没有证明设备 credit 公平性、常驻内存上界或慢设备容量。这里不把 Loader 的模拟 cursor 当成 GRDB 持久化证据。

## 建议的最小完整实现

### 一个 Gateway 本地 credit owner

新增 `V2GatewayDeviceDeliveryCredit`，以 authenticated connection lifecycle 为键，每 connection 仅保留当前 detail-room scope。它管理两类本地责任：

1. **queued bytes**：持有实际 ByteBuffer 的本地待写正文；写入、丢弃、撤权或关闭时精确结算。
2. **body flight bytes**：已实际 enqueue、尚未被该设备 C 覆盖的正文范围；只保留有界 sequence/bytes spans，不再复制正文。C 或设备降级退休旧 flight 时结算。

建议接口形状如下，字段与值由真实组成层提供，不能由客户端填 authorization：

```swift
struct DeviceScope: Sendable, Hashable {
    let connectionID: UUID
    let lifecycle: UUID
    let roomID: RoomID
    let scopeGeneration: UInt64
    let authorizationID: UUID // 由 Authority 安全生成/提供的 opaque key
}
struct BodySpan: Sendable {
    let firstSequence: UInt64
    let lastSequence: UInt64
    let encodedBytes: Int
}
enum BodyAdmission: Sendable {
    case admitted(Reservation)
    case headOnly
    case retired
}
func offerBody(scope: DeviceScope, span: BodySpan) -> BodyAdmission
func didEnqueue(_ reservation: Reservation)
func discard(_ reservation: Reservation)
func reportCommittedProgress(scope: DeviceScope, applied: UInt64)
func retire(scope: DeviceScope)
```

这些是实现提案，不是现有 API。Reservation 必须 exactly-once settle。Ledger 不能同步重入 Authority；先取得 bounded 本地 reservation，再在 EventLoop 的实际写入点执行现有同步 permit gate。成功才 `didEnqueue`，失败 `discard`。若锁顺序难以保证，统一使用固定 `credit → authority` 顺序并禁止 enqueue closure 再进入 credit；不能在两个 mutex 中互相回调。

每设备 queued/body-flight bytes 和 spans 数量有硬上限；可增加 Gateway 本地总 queued bytes 的独立预算来限制实际持有内存。这个本地预算不能合并到跨节点 RPC semaphore。满额只停止受影响设备的正文 accelerator，并保留其最大 H；Source 仍可 ACK Gateway 已接纳的控制/H。

编码共享不改变计费：按该设备准备实际写出的 wire bytes 计 flight；全局物理内存预算应依据实际共享 frame 生命周期，避免假称同一 ByteBuffer 的每设备逻辑 bytes 等同独立分配。第一阶段可以使用保守的独立本地 queued 计费，但必须明确它会影响公平性与峰值利用率。

### 设备状态机

| 状态 | 正文行为 | H/心跳/控制 | 转移 |
|---|---|---|---|
| `installing` | 不接正文 | Recovering 与原基线 Ready；心跳显式 ready=false | exact 新授权 Ready 实际 admission → `body` |
| `body` | 仅在设备 bytes/spans 额度内接纳 | H=max；控制事件独立连续应用 | queued/flight 额度耗尽、持续慢端 → `headOnly` |
| `headOnly` | 拒绝新正文 accelerator；按 scope 清掉尚未实际提交正文 | 保留一个最大 H；heartbeat 返回合法 H；继续授权控制 | 同 scope C 覆盖记录的恢复目标且队列/transport 可写 → `catchingUp` |
| `catchingUp` | 只经现客户端 pull/持久提交恢复；不反复尝试写历史正文 | 保持最新 H；C 不能由 G 或 server acceptedC 提升 | C≥当前 H、无未解决历史缺口且满足一次明确可写资格 → `body` |
| `retired` | 原 permit 永久拒绝、queued 与 flight 责任清理 | terminal control ACK 仍由共享 Source 责任结算；不返回合法 scope 状态 | 仅可信新授权代/基线安装创建新 scope |

降级只改变 acceleration，不撤销合法成员权限，不触发 Source generation reset；授权控制缺口、terminal invalidation、期限失效才需要现有可信 baseline 重建。新设备不会替其他设备解除慢端状态；新增用户不会更换无关用户的权限代。

恢复资格不能仅凭客户端任意数字释放共享权限。服务端最多接纳同连接/同 scope、单调且不超可信 H 的报告；恶意设备最多放松自己的本地 accelerator 限制，所有业务权限仍由 actual enqueue permit 决定。没有 C 的客户端安全停在 head-only，仍能通过心跳/pull恢复；没有报告不能被当成 C=H。

### 实际接线与退出重复机制

1. Registry 的 `submitRoomSubscriptionEvent` 保持一次编码与目标 interest 索引。对每设备调用 credit admission；仅成功 reservation 进入类型化 NIO queue。额度不足只 `offerHead(maxH)`，同步结束该设备 fanout，不等待 C。
2. NIO queue Entry 增加 scope/span/reservation，支持 exact scope targeted retirement。真实写入 gate 与 bytes accounting 接到同一次 drain；不能只在 queue append 时检查权限。
3. 删除 room body 使用的通用 `recoveryFrame` 完整帧溢出机制，替换为现 HeadWorker/ByteStream 的纯最大 H 状态。其他独立通知若仍使用通用 queue，应明确 separate owner，不混入房间 credit。
4. ByteStream 继续只拥有一套 Ready/H worker、现 heartbeat exchange 和一个 credit scope。移除“每重复 H offer 都为已跟上的 C 设备制造相同网络提示”的责任：仍保留 H=max 和 scope wake，但在 **合法同 scope C≥H** 时无需重复 accelerator H；不能用 G≥H 做这个决定。C<H 时可复用现 Host 5 秒 probe 和心跳 H，不另造周期 loop。
5. Session 接纳进度后仅通知同设备 ledger；不触碰 lease、Source control receipt、其他设备 C 或房间权限。GRDB 本地提交接口保持唯一来源，`history_incomplete` 不恢复 credit。
6. close/unsubscribe/device revoke/terminal control 先退休 Authority permit，再 targeted retire NIO queued bytes 和 device credit，最后等待实际 owned writer 结束。晚到 write completion 必须幂等结算旧 reservation，不能扣新生命周期余额。
7. Authority 的 `stage/commit` 不能继续成为与真实 NIO queue 并行的第二套正文存储/额度。完成实际接线后，删除未使用的生产 pending API或将其变成同一 reservation owner 的适配层，并迁移对应测试。
8. Actor 默认路径继续退出 legacy room wake/outbox publication。userSync/device control 独立保留；不能让 local-only 与 Actor 各自生成一套 room credit/H 状态。

## 必需测试与实证

### 单元与实际边界测试

- 每设备 queued/flight bytes 和 span 数量满额，在预算内接纳、超额立即 head-only；连续溢出只保留一个最大 H，不持有完整额外正文。
- 同一个 room/user 两设备，一端拒绝/不可写/不报告 C，另一端仍获得正文与 H；Source peer/global actual call slot 正常结算。
- 写入点持有旧 queue frame，随后 revoke/terminal/generation/activation/close，真实 socket gate拒绝；queued 与 reservation 及时归零；晚 completion 不影响新 scope。
- G 到 H 而 C 不动，不能恢复 body；真实客户端投影+cursor事务 commit 后 C 推进，释放 covered spans；acceptedC 不改本地 store。
- out-of-order/duplicate C、旧 scope、其他设备、超过 H、非法 UUID、超过数组上限；不扩权、不续租、不跨连接结算。
- 在同 scope H 持续升高时 latest target 更新；C 只追到旧 H 不得误判恢复。未报告或历史不完整时保持安全恢复通道。
- Ready/H/control 有独立预算；填满正文 queue 时仍可完成合法 heartbeat response与基线恢复，不能 busy retry 无界堆任务。
- shutdown join 真实 submitted 工作；丢弃 reservation exactly-once；固定低基数 metrics，不记录 room/user/device IDs。

### 故障与容量验证

复用共同冻结 Loader、原 persona/等待/质量门槛。新 slow-device canary 应使一部分实际 socket 非 writable 或不提交 C，证明 healthy devices 与跨节点 call budgets 不被拖住；通知全丢 canary继续验证 H/C补齐。宿主重启与慢设备/丢通知分开运行，避免混淆失败原因。

结果必须同时给出：实际 bytes/flight/spans峰值与固定预算、slow-device降级/恢复次数、Source actual calls峰值与结算、healthy-device最终游标、全设备有界恢复、GRDB C 提交边界测试。enqueue计数、丢帧计数、heartbeat成功或场景名称单独都不构成最终交付证明。未完成上述实际验证前，不声明慢端容量或长期公平性已通过。

## r8 宿主故障只读定位：共享授权重建不完整

本节根据 r8 运行产物与当前代码只读分析，不改变实现，也不把推断写成已验证根因。

### 已观察事实

该轮 120 条 TCP 连接、348 个消息 ACK；实际宿主终止、自然租约到期、更高 activation 和 takeover 后流量的故障证明通过。最终仍有 1 个前台 viewer 的 C 比 DB H 低 1。该 viewer 的 announced H 比 C 低 1；最后接受的普通 hint 为 H=0，距最后 snapshot 约 161 秒；没有 pull/retry/grace pending。房间 Ready 仍为 ready，基线 H=0。同房间另一 viewer 到达 DB H，且末尾收到新的 H。

对应 loader 分片报告有 60 次 progress reports、45 个 accepted states、0 个 ignored states、0 次 progress recovery signals。报告未给每设备 heartbeat state/空数组原因，不能将 15 个未返回的 states 唯一归属到落后设备。但“TCP heartbeat 正常”并不证明 Gateway 返回了该设备的合法房间 H；空数组既不会增加 accepted，也不会增加 ignored。

末尾服务端固定计数没有 permitRejected/writeFailed/expired-unsent，不能据此把问题归因于实际权限写入拒绝；这些聚合计数也没有设备归属。Ready 基线 H=0 只证明早先 Ready，不证明后来该成员已在新 activation 重新授权，更不证明当前 H=DB H。

### 确定存在的代码路径缺口

`V2GatewayRoomSubscriptionCoordinator.prepare` 在代表用户取得新 fence 并 activate 后，遍历 `keysByRoom`，把其他本地用户 relation 的 receipt 与 acquisition 直接替换成新 fence。该循环没有为这些用户向新 Owner 重新调用 subscribe。

而 `V2RoomSubscriptionOwner.subscribe` 在新 activation 没有旧 Gateway 状态时，创建 `Gateway(users: [:])`，只加入本次请求的用户。Relay 的新 Gateway subscribe 分支也明确创建 `members: [user: revision]`，baseline 只带这个 member。新 Owner 不会因为 Gateway 本地替换了其他用户 receipt，就自动获得这些用户的订阅关系。

因此发生 activation 重建时，“同 activation 既有共享 Gateway 的 full-member reset”与“新 activation 首次 Gateway subscribe”是两种不同情况。当前 Coordinator 对二者都执行同样的本地 receipt replacement，可能产生：

1. 代表用户进入新 Relay baseline，正常接收 H 与正文。
2. 同 Gateway 其他本地用户仍有活跃 device interest，却不在新 Authority.members。
3. `capturePermits` 不选择这些设备，`progressSnapshot(connectionID:)` 返回 nil，heartbeat ACK 的 scope states 为空。
4. Loader/客户端旧 Ready 观测可以仍显示 ready；同房间只剩代表用户接收的新 H，其他设备靠自己的 MessageAccepted 偶尔推进 C，最终少一条 peer 事件时暴露落后。
5. Coordinator 后续按共享代表用户轻量续期，不重新 acquire 这些缺失用户，状态可长期维持。

这是代码可确认的授权重建缺口；它与 r8 现象一致，但当前聚合产物不足以证明该落后 viewer 必然经过了上述每一步。不能用延长等待、提高 heartbeat/leaseSQL频率或让客户端伪造 Ready 来解决它。

### 后续最小修复与证明范围

后续如获得实施授权，应在 **activation 替换** 时保持未重新授权用户的 acquire 责任；不能仅凭旧 receipt 把其标记为新 fence 已授权。通过现有有界 call owner 为仍有引用的各 room/user 重新 subscribe（每用户一次，设备共享），新 Source fresh authorization 后经已安装 fence 的 ordered grant 生效；全程维持实际 enqueue permit。当前存活检查由 Host–Gateway 共享控制会话承担；恢复必须重新验证各仍有引用的成员。

同 activation 的 Source reset 若明确返回所有当前授权共享用户，则可以采用 full baseline 同步；不能假定新 activation 首次 subscribe 也有这些用户。若选择新的批量 acquire 接口，应共享房间初始化快照读取，但仍明确验证每用户授权与当前引用，不能把 Gateway 声称的用户名单当权限。

必要回归应使用真实 Owner/Relay + Gateway：同 room/Gateway 两个不同用户，各至少一设备；重建更高 activation，代表用户先完成 acquire，确认另一用户未被本地 receipt replacement 伪造授权；随后受控完成其 fresh acquire，确认新的 ordered grant、实际 H/正文、heartbeat 同 scope状态和最终持久 C 都恢复。增加撤权用户不重新附着、关闭引用不重新附着、await 后 scope/lifecycle 改变补偿、实际任务名额与 close join 测试。

新增观测只需固定原因计数，例如 `progress_no_interest`、`progress_no_member`、`progress_expired`、`progress_control_gap`、`activation_reattach_pending/completed`。不打印房间、账号、设备标识或 SQL 参数。已有 H/G/C 门槛继续保留；r8 失败不能被新的观测或文档视为通过。
