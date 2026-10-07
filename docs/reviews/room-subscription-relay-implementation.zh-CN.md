# 房间订阅与在线 Relay 改造

## 目标与验收边界

本改造替换 Gateway 依赖跨来源分区快照来建立每个房间在线接收权限的结构。业务提交、房间成员权限、设备会话、在线投递和历史补齐分别拥有状态。新增用户或设备不得撤销无关订阅；慢 Gateway 不得阻塞房间事件推进；正文丢失与最后 H 丢失必须能通过游标与水位核对收敛。

发送 ACK 的成功边界是消息事务及持久发布责任提交。真实 TCP 链路已经使用同步有界 committed observer，后续发布不在 ACK 等待链中。消息 statement triggers 保留 dirty-room-head 发布责任；控制变更写 change outbox。这一点必须保留，不能用无责任 Task 来替换。

## 当前实现切片

- `V2RoomSubscriptionWire` 描述房间订阅的 ownerEpoch、独立 generation、baselineSequence、成员版本和有序 delivery。分区 interestGeneration 不进入该权限 fence。
- `V2RoomSubscriptionRelay` 显式按可信 owner 输入序号推进，原子建立订阅基线和后续事件；一个 Gateway 共享多用户订阅。慢 Gateway 单独暂停并要求新基线，最新 H 持续保留；正文受字节预算约束，已发布序号内容不能在重试时改变。
- `V2GatewayRoomSubscriptionAuthority` 用用户连接索引展开本地设备，实际 socket 提交同步复核权限与 lifecycle。撤权仅清理对应用户未提交数据；控制缺口暂停对应房间。RPC 不能安装截止时间或权限 fence。
- `V2GatewayRoomSubscriptionIngress` 将已认证 Actor RPC 接到该权威组件，检查可信 composition 安装的源分片；正文回调只做本地有界 offer，真实 writer 必须再次检查 permit。
- `V2GatewayRealtimeEndpoint` 的房间 delivery RPC 复用签名、目标身份、会话、重放保护和 service-to-shard 授权。调用返回实际权限处理位置，不代表客户端持久化。

## 尚未完成的生产集成

这些组件尚未替换 `GatewayJournalRuntime`、Registry 的旧恢复路径或生产房间 owner。组件与签名 RPC 测试通过也不能宣布迁移完成。

后续进展：Registry 已提供可配置的新真实写入路径，房间 scope 开启、Ready、H 和正文在配置该路径后绕过旧房间 Coordinator/Journal。默认 App composition 尚未配置，因此默认部署仍走旧 Runtime；不能将“已具备入口”表述为“已切换生产”。

1. 在业务房间 owner 的提交推进器中产生连续可信输入；成员控制与数据采用同一房间有序事实。订阅请求应进入明确串行提交/接入边界，不能依赖 Actor RPC 到达顺序。并发数据库事务不能用预分配 ID 最大值跳过尚未提交的事件。
2. 将提交后发布接到该输入源，保留持久恢复责任；正文跨 Gateway 批量投递，控制连续处理。全局和 peer 背压各有明确所有者，不把 socket 等待保留在房间槽中。
3. Registry 的连接认证/关闭维护 authority lifecycle；订阅服务返回可信 fence 与本地单调截止时间；ByteStream/NIO 实际写入使用 authority permit。
4. 将 Session Authority 的设备撤销接到连接生命周期，房间普通推送不再依赖全局用户控制水位。严格撤权成功语义需要相关 Gateway 屏障或截止时间隔离，不能靠 eventual event 伪称即时撤权。
5. Gateway 活跃房间批量水位核对服务所有本地设备，独立于授权重建；最后正文和 H 均丢失时仍要收敛。
6. 已验证的新路径替换旧投影/周期恢复，再删除重复生产机制；不通过同时运行两套路径掩盖未接通的问题。

## 验证要求

组件验证覆盖同用户双设备、新增用户不撤销旧 permit、单用户撤权、撤权后的旧排队载荷拒绝、同成员版本重新订阅、控制缺口、旧 owner、过期 lease、重复及冲突 RPC、慢 Gateway 隔离和最后 H 保留。集成测试必须贯穿 Relay 输出与 Gateway authority，而非只各自构造理想输入。

生产验证要求真实 TCP、多 Gateway、跨节点 Actor 调用、消息/控制丢失和节点重启。容量仍按冻结基线的 10k/1000、50k/1000、5000 阶梯推进；质量、最终游标和吞吐门槛保持不变。小规模功能失败时不能扩大压力。新结构的数量级收益尚未证明。

## 本轮验证记录（2026-10-03）

统一执行 `swift test --package-path IMV2Server --jobs 8 --filter 'V2RoomSubscriptionRelayTests|V2GatewayRoomSubscriptionAuthorityTests|V2RoomSubscriptionIntegrationTests|V2GroupEventWakeRelayTests|V2RoomSubscriptionAuthenticationTests'`。最终日志 `/tmp/imv2-room-subscription-boundaries-20261003-r4.log`，退出码 0：Server 39 项、ActorCluster 2 项，共 41 项通过。

覆盖 Relay—Gateway 实际组件互操作、初始 epoch/member revision 0、乱序缓冲累计字节上限及填洞推进、固定大小去重指纹、慢 Gateway 隔离、已发布内容重试不变、撤权后 pending 清理和签名 RPC 认证边界。签名 RPC 测试调用 inbound 并验证报文，尚未启动真实多节点 Cluster 网络，不能代替跨节点生产验证。生产 Runtime 仍使用旧 Journal 路径，本轮没有容量结论。

## 后续接通与验证记录（2026-10-03）

新增 `PostgresV2RoomSubscriptionSource` 合并已提交 room_events 与 compact message rows，按历史成员区间恢复逐事件授权；初次真实 PostgreSQL 验证发现数据库 JSON 字符串 ID 与领域 Codable 不同，已通过数据库 DTO 转换修正。

新增 `V2RoomSubscriptionOwner` 串行接通 snapshot、连续 page、Relay 和 Gateway 订阅；新用户在精确 snapshot cut 加入，旧订阅 fence 不重置。空 Gateway 的最终 revoke 确认后才回收；无引用 tracked user 可移除。关闭停止新准入并等待在途数据库操作，不能靠逻辑取消丢弃实际责任。

新增 `V2RoomSubscriptionDeliveryPump` 拥有全局及 peer RPC 名额、失败重试、实际回执和关闭 join。慢 peer 不阻塞快 peer；正文/控制进度仍由 Relay 保留，而非发送 ACK 路径。

`V2RoomSubscriptionNetworkTests` 已启动真实两个 ClusterSystem，验证远程 Actor、活跃 TCP channel、签名 delivery、节点同端口重启及旧 incarnation 拒绝。Registry 的三个 ByteStream 测试使用真实编码/认证/写入门禁，明确令旧 Journal 与分区覆盖入口失败，验证新 Ready(S)、设备订阅隔离和撤权前置失效；它们不是完整部署的客户端 TCP 压测。

日志 `/tmp/imv2-room-subscription-source-network-20261003-r3.log`：构建成功；Server 34 项（含真实 PostgreSQL 及 Registry 写入）、ActorCluster 1 项真实网络测试通过，测试退出码 0。尚未运行新默认生产部署和容量阶梯。

生产组合仍需解决一个明确边界：Owner 实例内 generation 单调，但同业务 owner epoch 下实例重建不能从 1 向仍保留更高 floor 的 Gateway 重新安装。需要结合真实房间激活 fence 或可信握手恢复 generation 下界；当前代码安全拒绝，不应通过清空 Gateway floor 绕过。数据库 room data owner epoch 与分布式 Actor 激活 epoch 不能混为一谈。

补充验证日志 `/tmp/imv2-room-subscription-final-boundaries-20261003.log`：7 项集成、Registry 和 Pump 测试通过，包含源分片迁移要求更高 data-owner epoch 与新 baseline。该验证不包括后续正在实施的下列两项变更，二者完成后必须重新构建：

- 将 Source 的普通消息接收策略改为沿用 Relay 连续控制状态，只有成员控制及特定历史消息操作查询历史成员区间。现有每普通消息重建 tracked-viewer 历史权限的 SQL 成本不符合目标结构，需要消除，并用实际 EXPLAIN 验证普通消息不执行相关 membership 子查询。
- 将实际 `V2RoomActivationToken` 纳入订阅 fence，区分同 data owner epoch 下的新激活。Gateway 只能基于可信 composition 安装该 fence；旧激活、同激活 epoch 的冲突 host 不可视为新所有者。Owner 重建不能单靠重置内存 generation 解决。

## 生产订阅装配与批次验证（2026-10-03）

上述普通消息 SQL 与实际 activation 围栏现已落盘并验证。Source 每次读取在真实 activation 租约围栏下读取同一事务快照；返回数据库时钟剩余期限，Gateway 从 RPC 开始前的本地时间预算该期限。普通消息的 EXPLAIN ANALYZE 验证不执行逐 viewer membership 子查询。

新增 subscribe → 可信安装 grant → activate 二阶段协议和共享房间 reset。ActorApplication 转发实际签名 client，并由配置中的唯一 host/service 映射确定接收 authority；Gateway incarnation 与实际调用 client 一致。默认 Actor Runtime 已配置 Factory 批次端口及 Registry 新订阅入口。失败回滚新增 Registry 恢复任务关闭，物理 owner 在 transport/数据库关闭前排空订阅 worker。

正常 pump 可一次发送有界连续批次，并按 exact fence 累计确认。测试预排队基线及 32 条事件，以 8 条上限在 5 次调用内完成，验证 1...33 连续控制序号全部确认。签名 transport 另验证整批 ACK 丢失后的重试不会重复正文入 socket。

生产 App 构建日志 `/tmp/imv2-room-subscription-production-build-20261003.log`，退出码 0，11.90 秒。最新统一测试 `/tmp/imv2-room-batch-boundaries-20261003-r3.log`，退出码 0：Server 29 项、ActorCluster 4 项，共 33 项通过；包括真实 PostgreSQL source/执行计划、双设备共享订阅、生命周期补偿、慢 peer 隔离及真实双节点 TCP 批次重试。测试构建 38.24 秒，测试分别 1.689 秒及 0.033 秒。

这些证据尚不能证明完整目标完成。尚需独立验证部署上的真实客户端连接、租约过期/Relay 溢出后的共享重建、最后一次提交通知丢失后的主动水位修复；正常提交直接事实供给、跨房间批次聚合、普通事件移除重复成员列表，以及旧房间 Journal 在线职责退出仍未完成。新容量阶梯尚未启动，不能声明数量级性能提升。

后续恢复验证 `/tmp/imv2-room-subscription-renewal-repair-20261003.log` 退出码 0，14 项通过：包含 Relay 溢出后仅在需要时刷新完整共享基线、同房间其他用户保留、物理 owner 独立周期核对恢复丢失的最终通知及首次瞬态读失败重试。这些是实际组件测试，仍不替代部署故障测试。默认装配和失败回滚改动也在此次测试构建中编译通过。生产已失效 Owner 的重新激活恢复分类仍在补充；容量测试未启动。

## 默认链路的结构替换验证（2026-10-03）

最新稳定验证 `/tmp/imv2-room-structural-boundaries-20261003-r5.log` 退出码 0：Server 69 项、App 装配 5 项、ActorCluster 4 项，共 78 项通过；构建 29.41 秒。前述 Journal head test 的失败来自旧独立投影 fixture 将其要求正值的 member revision 写成 0，已仅修 fixture 为合法 1；新 Owner 的合法 revision 0 语义未改变。

已完成此前列出的结构缺口：

- single、prepared batch、host-cohort 提交后使用真实 activation 的有界不可变事实 feed；连续普通消息零 Source 读取，缺口/富内容/溢出使用持久日志修复。默认 Actor 装配退出旧同步 Hybrid observer，避免其在 ACK 路径再次编码正文。
- Relay 普通广播通过已排序成员控制维护的 Gateway 订阅集合发送 `.broadcast`，不再每事件筛选/排序/附带完整成员表；特殊历史受众继续显式选择。
- Pump 按 Gateway/source 分组跨房间合批，每 fence 独立累计确认；实际 RPC 名额与 room prefix 名额分别记账。32 个房间共享的失败批次仅拥有一个重试任务，关闭实际 join；慢 peer 隔离仍验证通过。
- 默认 Journal 仅负责用户/账号/session/device 控制，不读取/发布 room heads，不安装房间授权、不推进 room Ready。普通消息仅写 dirty head、不写控制 Journal 的触发器证据见 `gateway-journal-control-only-audit.md`。
- 失效 Owner 经 Runtime 实际关闭、释放数据库租约并新 activation 恢复；真实 PostgreSQL 测试区分瞬态错误不换代与 source gap 后 cached closed Owner 真正退役。
- 独立周期核对按最多 256 个 actual token 批量只读房间水位和租约 metadata，无成员查询、无租约行锁、无授权 grant。256 个静止房间一批 probe、零事件读取；最终通知丢失仍能发现水位增长并修复。

部署级 120 用户 TCP canary 正使用冻结 Debug 二进制运行（目录 `/tmp/imv2-room-subscription-production-tcp-canary-20261003-r1`）。它不属于 Release 容量证据，也未注入丢 ACK 故障；场景文件名不能替代实际故障注入。仍需部署故障验证、Release 构建与冻结容量阶梯，目标未完成。

周期批量 probe 最终稳定验证 `/tmp/imv2-room-structural-boundaries-20261003-r5.log`：78 项通过，构建 29.41 秒（r4 因测试遗漏 Synchronization 导入未运行，已修复）。

120 TCP canary 已终止，runner 退出码 1。六个 Gateway 就绪、120 连接预热后运行；720 条发送全部确认，无 workload/队列失败，所有 loader 退出码 0。最终 120 个前台 viewer 全部等于数据库 committed head（missing/behind/ahead 均 0，foregroundDelivery.passed=true）。质量门槛仍失败：coverageProofRequired=true、coverageProofConnections=120、coverageProofPassed=false。保留该失败，不将数据完整性结果替代全部质量门槛。正在审计旧分区覆盖证明与新房间 authority 的 wire/验证关系；尚不能将此 canary 记为通过，更不构成性能结论。

进一步审计 Loader 原有 coverageProof 条件并汇总 12 份连接报告：该门槛要求各 requested scope 为 Ready 且 appliedCursor >= highWatermark，不绑定旧分区所有者。room scope 120/120 Ready 并满足游标；account scope 仅 17 Ready，103 Recovering。实际失败是账号/session/userSync 控制基线恢复，不是测试语义不兼容；必须修服务端控制链路，不修改或禁用 Loader 质量门槛。


## 默认 TCP 功能验证及第二阶段结构改造（2026-10-03）

UUID TopicKey 与账号 scope 规范化修复后，`/tmp/imv2-room-subscription-production-tcp-canary-20261003-r2/candidate/result.json` 的 runner 退出码为 0。120 个连接、720 条 TCP 发送全部确认，账号/房间各 120 Ready，coverageProofPassed、qualityPassed 为 true；120 前台 viewer 全部追平 committed head，missing/behind/ahead 均为 0。本次使用 Debug 二进制，无实际丢 ACK 或节点故障注入，不能作为 Release 容量或故障恢复验收。

本次结构审查确认：旧续期周期按 (room,user) 重新走 subscribe/snapshot/grant/activate，Source 读取又使用业务写入的房间和激活租约行锁。第二阶段移除稳定订阅的重复成员授权，Gateway 按共享房间与 peer 合批续期；Owner 只接受已激活 exact fence、连续控制确认和可信新鲜 committed H/lease proof。续期仍有批量轻量只读 SQL，不能宣称零查询。读-only Source 使用一致 MVCC cut 与独立新鲜 token 复查，保留业务写入围栏及物理事务 watchdog/join。证明边界见 `room-subscription-readonly-proof.md`。这些新增改动尚待 root 编译与真实 PostgreSQL 验证。

新增独立 `--room-host-restart-canary` 和 `room-host-production-restart-canary.json`：先取得每连接真实 Ready，再 SIGKILL 实际持有前台房间 activation 的宿主；保持客户端在存活 Gateway，观察自然租约过期、新 activation/incarnation、物理客户端连接连续、恢复 Ready 和故障后应用序号增长。该 witness 不用 Journal 分区恢复替代房间恢复；明确不证明客户端断线重连或直接迟到旧 fence 注入。正式故障执行尚未开始。

第二阶段统一构建 `/tmp/imv2-shared-renewal-readonly-boundaries-20261003-r1.log` 成功（91.53 秒）；r1 的五项 PG 失败来自 root 填写不存在的测试角色。修正有效角色后以相同二进制复验 `/tmp/imv2-shared-renewal-readonly-boundaries-20261003-r2.log`，退出码 0：Server 64、App 3、Cluster 4，共 71 项通过，包括真实 PG 并发无写锁读取、读取中退役拒绝、共享房间/peer 续期、控制缺口拒绝、RPC ACK 丢失与物理交付 join。

此前七套更大 PG 集合也已定位并复验。`/tmp/imv2-postgres-fixture-resource-proof-20261003.log` 记录并发安装完整 schema 时 SQLSTATE 53200、sharedMemoryExhausted=true、lockBudgetHint=true；本机 max_locks_per_transaction=64、max_connections=100。未修改共享数据库配置，逐套运行全部 24 项通过。此结论属于测试 fixture DDL 并发资源预算，不能外推为生产压测热点已经解决。安全诊断仅输出固定分类与 SQLSTATE，不输出 SQL、参数或服务器消息。

新增真实房间宿主故障运行目录 `/tmp/imv2-shared-renewal-room-host-restart-20261003-r1`。本次冻结 Debug 新链路二进制，沿用共同 Loader，生产 TTL 不变，尚在运行；不预先报告通过，也不代替后续 Release 容量阶梯。

故障 runner r1 在启动阶段使用了 root 错误选择的遗留 `.build/arm64-apple-macosx/debug` 产物；当前 SwiftPM 产物位于 `.build/debug`（指向 out/Products/Debug）。r2 使用新冻结产物，120 个实际 TCP channel account/room 均 Ready，但 witness 误把 `gateway-0` 名称当物理 Room host UUID，未触发 SIGKILL 并在 arming deadline 失败。现从本次 actors 配置读取真实 hostID，新增回归测试；4 项 room witness 与 4 项 benchmark summary Python 测试通过。实际 fault r3 运行目录 `/tmp/imv2-shared-renewal-room-host-restart-20261003-r3`，尚待完成。r1/r2 均不计故障恢复通过。

r3 witness 仍未触发 kill：配置 UUID 小写而域 V2Identifier/persistence 使用大写，字符串比较未选中宿主。现按 UUID 身份比较，不修改业务 ID；回归测试使用真实大写 persistence/小写配置组合，4 项通过。arming 阶段新增有界只读 lease snapshot 保留，避免下一次无法解释未武装。r4 `/tmp/imv2-shared-renewal-room-host-restart-20261003-r4` 正在执行，仍不预先记通过。

r4 已终止，runner exit 1。房间故障 witness 通过：120 实际连接 Ready 后真实 SIGKILL、自然激活租约接管且 incarnation 更换、存活 TCP 连续、新 Ready 和故障后序号应用。348/348 TCP ACK，workloadFailed/failed/heartbeatMissed 均 0，coverageProofPassed=true。最终质量失败：120 foreground viewers 中 8 behind committed head（missing/ahead 均 0），qualityPassed=false。因此不能宣布恢复完整或进入容量验收；Owner/Host 水位修复与 Gateway authority/head/cursor 正并行定位，保持原最终游标门槛和等待预算。

## 最终水位自愈修复（2026-10-03）

r4 八个落后 viewer 均差最终一条，同房间另一 viewer 已到 H，且没有 pull/grace/retry backlog。客户端接受 H 会单调更新 announcedH；本地连续发送 ACK 可仅推进 applied cursor，因此 cursor>announced 不代表回退。Artifact 证明最终 H 未被接受，尚不能证明每例具体在哪一层丢失。

修复确定的结构缺口：既有 Host 每 5 秒批量 head probe 即使 DB H==Owner 已消费 cursor，也对已 activate 的共享 Gateway fence 刷新 H；pending 同等或更高 body/H 合并，控制缺口仍 failclosed，使用原 Relay/Pump peer 批次，无新增 SQL 或 scheduler。Gateway HeadWorker 保留有界最大 H；ByteStream 对失效 permit 保留未提交 H 并等待新可信 offer，同一 room/scope 可继承待提交提示，Ready(S)和submitted进度重建，不复活旧权限。稳定 lease renew 保持 expiry−2s 调度，不改成每 2 秒查库。renewed 携带可信 proofH 作为额外更新，但自愈不依赖该续期频率。

新增固定 stage head/socket 交付计数输出至 /metrics 和快速 /metrics/recovery-scheduling；明确 enqueue acceptance 不是客户端收到，socket stages 包含所有 scoped notifications。无用户/设备/房间标签，无SQL参数或正文。

## 进度闭环与持久变化源阶段（2026-10-03）

同 H 周期提示不能仅因 H 已提交而去重；ByteStream 现按本次 offer 的实际提交状态判断。Host 忙碌时的最终水位责任保留在原有 Pending 中。统一验证 `/tmp/imv2-final-head-repair-boundaries-20261003-r2.log`：构建 36.78 秒，Server 68、App 3、Cluster 4，共 75 项通过，包括真实 PostgreSQL。此结果只证明所覆盖组件与 transport 边界。

真实故障复验 r6 `/tmp/imv2-shared-renewal-room-host-restart-20261003-r6` 已终止，runner exit 1。120 个前台 viewer 的 missing/ahead 均 0，但 7 个 behind committed head，qualityPassed=false。房间宿主 witness 通过：实际 SIGKILL、自然租约接管、旧连接连续、新激活和故障后序号推进；不证明客户端断线重连或迟到旧 fence 注入。不得将 witness 通过代替全部设备最终收敛。

新方案第一阶段已写入真实 TCP Heartbeat/HeartbeatAck：设备上报本地事务提交后的 C，服务端无报告也返回合法当前 scope 的 H；按 connection/scopeGeneration 隔离，不授权、不续租、不把 enqueue 或 acceptedC 当本地持久化证明。App 注入同账户 GRDB localStore，复用现有 heartbeat loop 和补拉路径。仍需统一编译、协议/持久边界测试，以及实际最后正文和 H 丢失验证。裁剪历史缺口尚无完整房间快照恢复基线，保守不报告此类房间 C，属于未完成项。

第二阶段复用现有 realtime_dirty_room_heads，不新增正文 outbox。初版 exact-token dirty 查询仍枚举活动房间，只减少无变化正文读取，不能宣称已经按 pending 变化规模消费；pending partial index、公平领取和 Host exact pin 正在补齐。权限控制、空房间 H=0、CAS 不清新提交及宿主崩溃恢复必须验证。逐房间新鲜租约证明仍保留，删除它需要完成分片 fencing 迁移。Actor 默认旧 room-wake worker 及数据库 legacy wake 写入仍需一起退出；仅停止 worker 会造成永久积压。

新阶段首轮验证发现两个编译缺口：Server dirty store 缺 Application import；ClientKit 新协议测试误用已被自定义初始化器替代的成员初始化器。测试尚未运行，不报告新增阶段通过。现有共同 Loader 不消费新心跳水位；更新后必须对 A/B 使用同一冻结 Loader，并记录新算法版本，原 persona、等待预算和最终游标门槛保持不变。

后续统一验证 `/tmp/imv2-progress-durable-boundaries-20261003-r2.log` 构建 76.59 秒，Server 72、App 3、Cluster 4，共 79 项通过。ClientKit `/tmp/imv2-client-progress-boundaries-20261003-r3.log` 构建 30.99 秒，26 项通过，包括真实本地事务游标资格与心跳水位补拉协议。App runtime 注入尚未通过 iOS 构建/部署验证。新 Loader 已接心跳协议，算法 SHA256 为 `391f85e5a90c0c7e626b1f5b59f99f8d91137e77cf25aa5a67ad04c951cc45b3`，尚未冻结运行新完整故障场景。

单独实际 PostgreSQL `/tmp/imv2-dirty-head-postgres-boundaries-20261003-r1.log` 11 项、4 个 issue，旧测试固定 revision 数字与新增 control-only UPSERT 不一致，需按真实增量/CAS语义修正并复验，不能隐藏失败。另有代码审计确认的安全缺口：同 H 控制版本只参与 dirty CAS，尚未进入 Owner/Relay 消费证明；不能以 H 刷新确认撤权，也不能允许同 H 旧权限继续续租。子代理正在补可信 control cut、版本不连续时失效订阅及旧 permit 拒绝集成测试。上述 79 项通过不覆盖此缺口；持久源第二阶段仍未完成。

## 控制 cut 与真实通知丢失验收（2026-10-03）

Source snapshot 和新鲜租约 proof 现携带 roomControlVersion，broker 不丢弃该版本。Owner 对可由连续历史证明的正常成员变更继续推进；缺少连续证明时，以完整可信 cut 发出签名有序 authorizationInvalidated。Gateway 实际应用该 terminal 后清除旧成员和待提交载荷，旧权限不得续租；Host 等真实回执后才允许 dirty CAS。没有更新授权 cut 的业务日志缺口仍关闭 Owner，不以当前成员快照掩盖丢失日志。

首轮 `/tmp/imv2-control-cut-progress-boundaries-20261003-r1.log` 构建成功（44.47 秒），但 4 个 issue：Host 同批 drain 与 catchUp 重复 signal 多读一次；同 H PG fixture 缺真实 headProbe 导致 dirty 未消费；Lifecycle core-only fixture 缺新控制版本表。均已修复并保持原读取次数与等待预算，正在执行 r2，不预先宣布通过。

ClientKit `/tmp/imv2-client-progress-boundaries-20261003-r4.log` 构建 5.97 秒，44 项通过。新增实际 GRDB 事务中途失败的游标/投影回滚及重开数据库验证，server acceptedC 不推进本地游标，真实 connection/scope 更换时迟到 H 隔离，ready=false 不触发未授权补拉。

新增明确 `--room-notification-loss-canary`：仅 owned candidate、小于等于 500 用户，与宿主重启/分区/其他故障互斥。Loader 在实际当前房间通知入口丢弃正文和 H 整帧，独立计 discarded，不更新收到/应用/水位；心跳状态沿原补拉调度恢复。runner 要求实际丢弃、心跳恢复信号和原最终游标门槛同时成立。6 项 Python 证明/约束测试通过；尚未执行该真实故障。新共同 Loader SHA256 为 `9fba2062b3ac8dfe869f25fb69e1690dd4eda9fc7eacdb1be694719a5625a380`，冻结与 A/B 必须使用同一实际产物。Loader 的应用游标属于模拟客户端，不替代 App SQLite 持久化故障证明。

仍需完成：Actor 模式显式数据库发布迁移（转移 legacy 持久责任后停止旧 trigger 写入与 worker，并按实际模式做 readiness 校验）；分片所有权/fencing 与租约聚合；裁剪缺口的可信房间恢复基线；真实通知丢失/宿主重启/客户端重连与丢 ACK/App 多端；Release 原容量阶梯和共同 Loader 质量/吞吐门槛。当前目标保持完整，组件通过不能替代这些部署与容量要求。

控制 cut 复验 `/tmp/imv2-control-cut-progress-boundaries-20261003-r2.log` 构建 31.52 秒，Server 75、App 3、Cluster 4，共 82 项通过；独立 `/tmp/imv2-dirty-head-postgres-boundaries-20261003-r2.log` 12 项真实 PG 通过（6.064 秒）。新增控制 cut 的部署验证仍需实际运行。

通知丢失 r1 `/tmp/imv2-room-notification-loss-20261003-r1` 终止于 startup，无 Loader、无故障注入：新 UPSERT 函数的 readiness 精确 hash 仍为旧值，Gateway 安全拒绝启动。更新唯一变更函数的归一化 prosrc MD5，并新增真实安装及破坏 CAS revision 后必须拒绝的测试。`/tmp/imv2-journal-installed-readiness-20261003-r2.log` 构建 31.15 秒，2 项真实 PG 测试通过。

冻结 Loader 还发现 earlier agent 报告的 SHA 与真实 runner 规范不一致，服务启动前即被校验拦下。按 runner 同一 `ALGORITHM_SOURCE_SHA256` 占位规则修正并重建（6.51 秒），当前真实源码/编译产物匹配 SHA256 `8071c07d32bb4bd53ad18ab26458b0b4ddce2f7c17940f735447d39dd5023b2a`。Debug Server/Account/Loader 冻结目录 `/tmp/imv2-control-cut-progress-debug-binaries-20261003-r2`。

真实通知丢失 r2 `/tmp/imv2-room-notification-loss-20261003-r2` 已实际启动，6 个 Gateway ready，120 连接开始建立。原 30 秒发送、30 秒 drain、10 秒 post-hold 及 persona 不变；仅场景名称区别于旧 lost-ACK 名称，故障由明确注入 flag 实施。尚待 terminal 结果，不预先报告收敛通过。

通知丢失 r2 已 terminal exit 0：12 份报告、120 authenticated、720/720 TCP ACK、heartbeatMissed=0，实际 discardedNotificationFrames=2906、heartbeatRecoverySignals=34。最终 120 foreground viewers missing/behind/ahead 均 0，coverage 和 qualityPassed 为 true，明确 loss witness 通过。使用冻结 Debug 产物，属于真实 TCP Loader 模拟应用恢复，不证明 App SQLite 落盘故障，不属于容量证据。

同一冻结版本启动宿主重启 r7 `/tmp/imv2-shared-renewal-room-host-restart-20261003-r7`，原生产 TTL、120 秒自然接管窗口、发送/drain/post-hold 与最终全追平门槛保持不变。尚待 terminal；r4/r5/r6 的失败保留。并行推进下一阶段显式 publication 迁移与 Actor legacy worker 退出，不修改本次冻结产物或实际数据库。

`/tmp/imv2-final-head-repair-boundaries-20261003-r1.log` 构建 87.76 秒，测试 exit 0：Server 68、App 3、Cluster 4，共 75 项通过；含实际 held socket/失效 gate/新可信授权重投 retained H、Host 无额外 Source.read 的最终 H 刷新及真实 PG 读写隔离。4 项 room witness + 4 项 benchmark summary Python 测试通过。相同故障场景 r5 `/tmp/imv2-shared-renewal-room-host-restart-20261003-r5` 正在运行，仍保留 120 最终游标全追平门槛与原等待预算，不预先报告通过。


## 2026-10-04 暂停交接

用户要求“这次修复后先暂停”。当前 App canary 验证接线和测试 target 链接修复已完成，不启动下一轮压测或分区实现。

- Actor 发布模式迁移边界验证：3 项真实 PostgreSQL readiness/迁移测试与 5 项 App 组装测试通过，日志 `/tmp/imv2-publication-mode-boundaries-20261003-r1.log`。这不证明整体容量或 App 端到端故障通过。
- r8 实际宿主重启验证已经终止，runner exit 1。`/tmp/imv2-shared-renewal-room-host-restart-20261003-r8/candidate/result.json` 证明 120 连接、348/348 TCP ACK、0 心跳丢失、实际 SIGKILL、自然租约过期、高 activation 接管及后续消息应用。最终 1 个设备 C9 < DBH10，qualityPassed=false，不能放宽门槛或宣称通过。相关服务 cleanup settled=true。
- 只读代码审查发现 Coordinator 新 activation 的共享重建缺口：代表用户 subscribe/activate 后，其他用户的 receipt 被替换成新 fence，但未向新 Owner 重新 subscribe；新 baseline 缺少这些用户，可能导致 Ready 表面存在而合法 progress H 缺失。现有聚合指标不能唯一证明 r8 的全部根因；该缺口尚未修复，后续应先写准确回归再修复。详细证据见 `gateway-device-credit-design.zh-CN.md`。
- 新真实 App 通知丢失 canary 与中央 benchmark 的模式互斥、preflight、源码哈希、独立数据库事实检查及清理门槛已接线。新增 App 测试直接使用 GRDB；首轮构建在 IMAppTests 链接缺 GRDB 符号失败。已为测试 target 声明现有 GRDB package product 和 Frameworks 依赖，不清缓存、不修改生产网络路径。第二轮 `xcodebuild build-for-testing` exit 0，日志 `/tmp/imv2-app-room-progress-build-20261003-r2.log`。root 实际运行新 canary 两组 Python 测试 11 项通过；代理相关回归共 21 项通过，diff 检查通过。真实 App 故障测试尚未执行，不能以构建或模拟 Loader 替代 SQLite 持久化验收。
- 分区所有权设计与设备额度设计已冻结为文档，生产分区 ownership/替代逐房间租约尚未实现。分区 epoch 必须通过事务锁排序防止接管后旧 writer 提交；执行所有权不能替代用户授权或控制版本证明。

恢复顺序：先修复共享订阅接管时漏授权并回归；执行真实 App canary；按分区规格实施所有权和直接 pending 寻址；再做慢端额度、完整快照恢复与原 Release 容量门槛。没有把目标缩小为当前已经通过的组件验证。


## 2026-10-04 已替代路径清理

删除未装配的 OnlineHeadDispatcher 与专属测试、JournalPublisher 的 room head discovery/ApplyHeads/ACK 分支及专属测试、Fanout 未使用的兼容回调、Host 的周期水位恢复兜底与 token-list dirty callback，以及 Postgres dirty store 的旧 token-list 查询。Host 的重复 consumedThrough 状态移除，Owner 保持唯一游标；dirty discovery 为必需构造依赖。原 fence/CAS、丢通知/瞬态恢复测试改用生产 host 查询，未取消正确性断言。Local-only 发布、独立租约检查和权限控制仍有实际使用，未删除。

本轮代码和测试净减少约 522 行（文档修正前）；这不代表三万行生产增量全部已经审计。r2 25 项通过，其中 12 项真实 PostgreSQL，日志 `/tmp/imv2-obsolete-path-cleanup-20261004-r2.log`；删除 Journal 重复调度后的 r3 14 项通过，日志 `/tmp/imv2-obsolete-path-cleanup-20261004-r3.log`。构建和 diff 检查通过，未启动容量压测。先前共享接管漏授权问题仍待独立修复，本轮不宣称解决。
