> 历史过程记录：早期的运行中、待办和索引数量描述不代表当前状态。当前结论见 [验收状态](client-owned-conversation-sync-acceptance.md)。

# 会话同步当前验收状态

## 跨 Gateway 规模入口构建通过（2026-09-13）

当前源码 `xcodebuild build-for-testing -project IMApp/IMApp.xcodeproj -scheme IMAppLocalAccountE2E -configuration Debug -destination 'generic/platform=iOS Simulator' -disableAutomaticPackageResolution -jobs 2` 已退出 0，日志 `/tmp/imv2-cross-gateway-scale-build.log` 有 TEST BUILD SUCCEEDED。新增第二 Gateway 发送函数、共享认证所有者及成功标记均经过当前 Swift 构建；这是构建证据，不是跨 Gateway 行为通过。

确认原生 NATS 程序 `/tmp/imv2-nats-runtime/nats-server-v2.11.0-darwin-arm64/nats-server` 可执行。万房间原会话仍存活，曾读到 4,016 条正文和 5,984 个待办；尚无自然到期/最终完成结果。本轮编译与恢复同机并行，时间测量不作为隔离性能结论。待固定测试监听端口释放后继续执行 129 房间跨 Gateway，以及空目录和剩余故障门禁。

## 多房间跨 Gateway 验收入口（待执行，2026-09-13）

扩展规模 harness：非空 --room-recovery-scale 可组合 --multi-gateway-nats-binary，复用现有独立 NATS/第二 Gateway 启动及清理。在线阶段主连接完成全部房间覆盖后，使用同一认证所有者在第二 Gateway 发送目标房间消息；主连接不建立详细订阅、不手动补拉，要求实际通知驱动正文及游标更新后才发 CROSS_GATEWAY_PASSED。第二连接的成功与失败路径均显式断开。原单房间 private-hint 跨 Gateway 检查仍独立保留。

Python 语法与空白检查通过，新增 Swift 尚未构建/执行。当前万房间二进制早于此改动，不能从它推导跨 Gateway 规模通过。待当前固定端口测试释放后，计划以 129 房间执行该入口；NATS 重启/丢失尾通知/慢 TLS 仍是独立待验项，不能由正常跨 Gateway 投递替代。

## 实时与恢复非空正文合并验证（2026-09-13）

新增 realtimeAndRecoveryShareOneMessageWithoutDroppingNewWork，使用同一条真实 message.accepted 载荷，分别验证实时先提交、恢复先提交以及 async let 并发提交。旧恢复请求捕获 head=1 后，另一次通知把待办提高到 head=2；两条路径完成后正文恰好一份、实际游标为 1、新 requestRevision 的 head=2 待办仍存在。

`/tmp/imv2-recovery-realtime-race.log` 退出 0，18 项持久化测试通过（1.687 秒），含三个新参数场景。本测试调用真实 SQLite/投影入口，未经过 TLS 或网络故障，不替代完整系统实时/补拉并发验收。

万房间会话仍运行，已用只读 SQLite 观察到 1,165 条正文及 8,435 个待办，扫描和正文持续推进；这些计数不是完整恢复比例。当前轮执行过 ClientKit 编译，万房间耗时不能作为完全隔离的性能 SLO。完整目标保持未完成。

## 摘要事务真实强杀验证（2026-09-13）

新增 summary 事务提交前/后 SIGKILL：同一事务中的 v2_room_latest_visible 行与 requires_summary 标记必须同时可见或同时回滚；重开数据库后重放同一摘要，正文游标保持零、目标 head 为 1 的正文待办仍存在。使用空的最新可见候选验证“已观察到 head 不等于正文已应用”，不把摘要提交视作正文恢复。

`/tmp/imv2-recovery-summary-crash.log` 已退出 0：父测试 killedCommitRecoversAtomically 的 10 个参数场景全部通过（0.781 秒），覆盖正文、目录、正文待办完成、状态、摘要五类事务的提交前后。父宿主 crashChild 为条件跳过，十个子进程均实际执行并以 SIGKILL 结束。未据此宣称所有 SQLite/快照/成员撤销事务均已完成强杀验收。

万房间原会话仍已确认存活，日志 `/tmp/imv2-tls-recovery-scale-10000-v2-driver.log`，尚无终态；本轮小规模 ClientKit 编译发生于规模种子建立之前。完整目标保持未完成。

## 50 房间真实刷新整轮通过，万房间续连重跑（2026-09-13）

`/tmp/imv2-tls-recovery-scale-50-driver.log` 已终态退出 0，harness 的真实 HTTPS、HTTP 次数及数据库效果全部通过，专用模拟器 D99162BA-1B12-49CD-97A6-6367CB4251E1 已清理。两轮房间恢复完成；两轮之间主动执行一次真实凭据刷新，随后使用新凭据重新认证并在同一 SQLite 恢复；在线发送无详细订阅/手动补拉而自动落库。客户端刷新计数为 1，代理 scale-auth-summary.json 同样为 1，双方交叉校验通过。这不等同于自然到期验证。

新增 harness 失败诊断采集，仅保存已有两类 Password authentication 错误分类/类型日志，不导出任意 App 日志或凭据。Python 语法和空白检查通过，失败采集路径尚未触发验证。之前 129 房间注册激活失败仍不能因本轮成功而宣称根因已修复。

已启动保持生产令牌期限和限流的万房间重跑 `/tmp/imv2-tls-recovery-scale-10000-v2-driver.log`，输出 `/tmp/imv2-tls-recovery-scale-10000-20260913-02`；包含恢复中不重复扫描、认证刷新/续连以及在线变化阶段。尚无终态，不能计作万房间通过。空目录和其余完整方案门禁仍待完成。

## 第 129 房间在线行为通过，状态事务强杀补齐（2026-09-13）

`/tmp/imv2-tls-recovery-scale-129-20260913-06/app.log` 中规模 XCTest 成功完成：首次 12.067 秒、重连 0.380 秒，第 129 个房间没有详细订阅/手动补拉而自动落库新正文与游标；出现 ONLINE_PASSED、RECOVERY_SCALE_PASSED 和 AUTH_REFRESHES count=0。补齐 room_admission 后实际发送成功，关闭该规模夹具发送准入缺失的问题。

但 `/tmp/imv2-tls-recovery-scale-129-online-v4-driver.log` 整轮退出 1：独立 testGatewayDeviceRevocationReturnsToLoginAndSurvivesRelaunch 在注册激活时显示“账户服务暂不可用”，App summary 为 2 passed、1 failed、1 skipped。HTTP 观测只有预期 200/204/401，没有证据把该 UI 错误归因于服务端 503；失败原因仍待复核。harness 因 App 门禁失败没有执行后续数据库与刷新次数终验，所以不能宣称该次完整 harness 成功。专用模拟器 6127EDF6-CD11-4EB7-AC87-BEE72821E389 已清理。

新增 state 事务强杀参数，在 v2_room_sync_states 提交前后 SIGKILL，检查状态行和 requires_state 同步提交、正文游标仍为零，重开后可重放状态核对并保留正文待办。`/tmp/imv2-recovery-state-crash.log` 退出 0，killedCommitRecoversAtomically 的 8 个参数场景全部通过（0.680 秒）；父进程中的 crashChild 明确跳过，实际由八个子进程执行，不将跳过项当成额外通过用例。此前 617 项全量尚未包含新增两个参数。

已启动 50 房间真实刷新及在线检查：`/tmp/imv2-tls-recovery-scale-50-driver.log`，输出 `/tmp/imv2-tls-recovery-scale-50-20260913-01`，尚无终态。万房间、空目录及完整方案的剩余故障门禁仍未完成。

## 在线发送夹具缺少准入状态（2026-09-13）

129 房间第三轮在线驱动 `/tmp/imv2-tls-recovery-scale-129-online-v3-driver.log` 已退出 1。两轮恢复分别 11.997 秒、0.353 秒完成，但 send_message 连续返回 UNAVAILABLE，在线检查未通过。检查生产建群事务发现还会写 room_admission，将房间绑定到分片租约；规模种子此前只有 rooms/group_rooms/membership/messages，没有该状态。现按隔离分片池写入每房间的成员数、命令窗口及租约身份，不修改生产准入规则。此修正仍待真实发送结果验证，不能仅凭 SQL 增补断言问题已关闭。

50 房间用例新增两轮之间一次主动真实刷新，与同一 SQLite 上的后续重新认证结合；代理和客户端要求观察到恰好一次成功轮换。该场景不是令牌自然到期模拟，不替代万房间长恢复。

当前运行 `/tmp/imv2-tls-recovery-scale-129-online-v4-driver.log`，输出 `/tmp/imv2-tls-recovery-scale-129-20260913-06`，尚无终态。上一轮专用模拟器 C1F926A1-C053-482A-8A8E-E1CF2E37A8B8 已由 harness 清理。完整方案仍未完成。

## 规模认证边界与刷新观测修正（2026-09-13）

129 房间 `/tmp/imv2-tls-recovery-scale-129-online-v2-driver.log` 终态退出 1，认证阶段报告 Keychain unexpectedStatus(-34018)。XCTest runner 不具备应用的 Keychain access group；此前直接把应用 Keychain 实现放进 runner 是测试夹具错误。本次恢复测试使用 actor 保存原子的完整凭据记录，继续执行真实 V2AuthSession、HTTPS 刷新和 TLS 连接协调器。此夹具只证明同进程续连，不宣称 Keychain/重启恢复通过；应用 Keychain 仍由独立 App 生命周期验收覆盖。

新增客户端真实刷新成功次数与代理按规模账号识别的 HTTPS 成功次数交叉校验，生成不含身份或凭据的 scale-auth-summary.json。原认证场景固定成功次数仍单独保留，不因规模刷新而放宽为任意次数。Python 语法与空白检查通过；新增 Swift 边界和观测等待构建运行验证。

已启动 `/tmp/imv2-tls-recovery-scale-129-online-v3-driver.log`，输出 `/tmp/imv2-tls-recovery-scale-129-20260913-05`，尚无终态。当前目标仍未完成。

## 617 项全量通过，在线初始化限流与认证接入（2026-09-13）

当前 ClientKit `/tmp/imv2-client-no-overlap-full.log` 退出 0：617 项、105 套件通过，58.946 秒，显式启用当前宿主真实强杀检查，包含恢复中禁止周期重复扫描的修复。

129 房间在线首轮 `/tmp/imv2-tls-recovery-scale-129-online-driver.log` 已退出 1：两轮恢复分别 11.840 秒和 0.388 秒，但 online-change 阶段在进入在线发送前收到 retryable RATE_LIMITED，不能算在线覆盖成功。测试辅助 synchronizeInitialState 已加入最多 30 秒重试预算并遵守服务端退避，不修改生产限流。

规模测试现在保存完整签发凭据，使用隔离 Keychain、V2AuthSession 和 V2RealtimeSessionCoordinator 建立连接；正文恢复连接关闭时，在同一总时间预算内最多重连四次，保留原 SQLite，并由凭据所有者在过期后刷新。新增路径尚待实际验证；万房间仍未通过。接下来的长运行还需要让 harness HTTP 刷新次数断言精确计入规模账号的真实轮换，不能把原认证用例固定次数直接作为整个新增场景的次数。

已启动当前源码 129 房间重跑 `/tmp/imv2-tls-recovery-scale-129-online-v2-driver.log`，输出 `/tmp/imv2-tls-recovery-scale-129-20260913-04`，尚无终态。Python 语法与 git diff --check 通过。上述认证接入只修改测试路径，尚不等同于 App 前台完整生命周期端到端已验收。

## 恢复中重复扫描修复与万房间失败终态（2026-09-13）

发现 Runner 只检查目录已完成就允许周期核对重启；长时间正文恢复仍有待办时，会再次扫描并排队。现改为目录完成、待办为空且 engine 已达到 live 后才允许周期核对。新增受控时钟测试，在第二页房间正文限流时将时钟推进超过核对期限，验证完成个人流核对之前目录仍只扫描一轮。反向验证 `/tmp/imv2-recovery-no-overlap-before-v2.log` 在旧条件下明确失败；修复后 `/tmp/imv2-recovery-no-overlap-v2.log` 退出 0，22 项通过（1.795 秒），包含原有完成后周期核对及通知恢复检查。最初夹具在第一页失败，没有覆盖目录已结束的边界，已改到第二页；不把初版测试作为反向证据。

万房间 `/tmp/imv2-tls-recovery-scale-10000-driver.log` 已终态退出 1，不能计作通过。App 在首轮 room-recovery 阶段 902.665 秒时报 connectionClosed；Gateway 同时明确记录 V2GatewaySessionError.sessionExpired。原 harness 直接使用注册时的 access token，尚未将长恢复接入凭据刷新/续连生命周期。不能通过延长生产令牌期限规避此缺口；后续需在保持 SQLite 进度的条件下验证正常刷新、重新认证并继续恢复。该二进制也早于本节重复扫描修复和新增在线检查，不能证明这些新改动。

该轮专用模拟器 969675BA-1C9C-468E-88D3-76E3517961C9 已清理。资源文件有两角色各 858 个样本、无采样错误，窗口约 900.215 秒；Gateway 采样 RSS 峰值 52,084,736 字节，测试宿主 293,044,224 字节。这是失败恢复窗口的采样值，不是成功万房间恢复资源基线；窗口内还执行过小规模 ClientKit 编译/专项，耗时数据不作为隔离压测 SLO。

当前已启动含重复扫描修复与在线阶段的 129 房间真实 TLS 测试，日志 `/tmp/imv2-tls-recovery-scale-129-online-driver.log`，输出 `/tmp/imv2-tls-recovery-scale-129-20260913-03`，尚无终态。此前 616 项 ClientKit 全量早于本节修复，最终全量仍需更新。

## 当前 ClientKit 全量终态与在线覆盖补充（2026-09-13）

`/tmp/imv2-client-current-retry-full.log` 已取得终态：616 项、105 个套件通过，59.058 秒。该轮显式设置当前测试宿主的 IMV2_CLIENT_CRASH_BINARY，包含真实进程强杀检查，取代下文该轮“尚无终态”的描述。

真实 TLS 规模用例新增在线变化阶段：恢复完成后，对目录排序第 129 个房间（不足 129 时取最后一个）发送新消息，不建立详细房间订阅、不手动触发补拉，要求运行中的账号通知驱动正文与游标更新。发送重试复用同一 clientMessageID；测试专用 admission lease 由隔离 harness 提供。新增阶段尚未构建执行，不能计作在线覆盖通过。

10,000 房间原测试会话仍已确认运行；其构建早于上述在线阶段，因此该轮即使成功也只证明两轮恢复，不证明新增在线检查。完整方案仍待真实在线及剩余故障、规模和当前全量验收。

## 前台恢复各阶段退避回归（2026-09-13）

新增 listener/directory/state/summary/personal 五个阶段的单次 RATE_LIMITED 注入，确认按要求等待 2 秒后恢复；除监听建立失败需要第二次启动外，已建立监听保持一次，只有失败的目录页重复请求，正文游标最终正确、持久待办清空。`/tmp/imv2-recovery-retry-boundaries.log` 退出 0，21 项通过（2.121 秒），包含五个新参数场景及此前正文退避、取消、公平调度等用例。

已启动当前 ClientKit 完整回归并显式启用真实进程强杀，日志 `/tmp/imv2-client-current-retry-full.log`，尚无终态。10,000 房间 TLS 测试仍运行中，首批 20 行可读时间已记录为 0.259 秒；这不是全轮完成或首帧渲染证据。

## 1,000 房间真实恢复通过，10,000 房间运行中

`/tmp/imv2-tls-recovery-scale-1000-driver.log` 退出 0，App 日志有两轮及最终通过标记，HTTP/数据库效果检查通过并删除模拟器 `3AEBC3C1-8588-408F-A712-40617E7BAAA4`。

| 周期 | 首批 20 条列表行可读 | catchup | 逻辑请求/响应字节 | 主要请求数 |
| --- | --- | --- | --- | --- |
| 首次 | 0.262 s | 97.911 s | 156,328 / 756,663 | 正文拉取 1,080；目录 10；状态 81；摘要 81 |
| 重连 | 0.017 s | 2.246 s | 43,048 / 141,183 | 正文拉取 0；目录 10；状态 50 |

两轮均核验 1,000 个房间各一条正文、游标 1、目录完整与待办清空。正文请求数高于房间数，计数包含重试；未另行解码统计每个错误码，不将多出的 80 次全部归因于某一错误类型。字节只包含 protobuf 请求/响应逻辑帧，首批行可读不代表 UI 已渲染或完整摘要均可见。首次全量恢复耗时明显，不能把这些结果宣传为毫秒级恢复。

已启动 `/tmp/imv2-tls-recovery-scale-10000-driver.log`，输出 `/tmp/imv2-tls-recovery-scale-10000-20260913-01`，原进程继续执行。依据 1,000 房间实测，在保持生产限流不变的情况下，将规模测试每轮等待预算设为 max(600, roomCount/5) 秒，harness 总等待预算 max(900, 2*roomCount/5+300) 秒；这是测试等待预算，不是放宽产品 SLO。新增每秒采样专用 Gateway 与模拟器测试宿主的 RSS/累计 CPU，窗口从数据准备完成至 App 测试结束，结果将在 scale-resource-samples.json 保存；属于采样峰值，不能当作精确瞬时峰值。目前尚无 10,000 房间结果。

## 129 房间真实 TLS 恢复通过，1,000 房间已启动

`/tmp/imv2-tls-recovery-scale-129-driver-v2.log` 退出 0；当前代码经真实 HTTPS/TLS Gateway 和专用 PostgreSQL 完成两个恢复周期。App 日志：129 房间首次 catchup 12.243 秒、断线后第二轮 0.393 秒，每个房间正文恰好一条且游标为 1，目录结束/待办清空在 live 状态内核验。App summary 为 3 passed、0 failed、1 skipped；三个通过项包含本次规模用例及两项认证用例，可选未请求项的 skipped 不计作通过。harness 核验 HTTP/数据库效果及连接清理，删除模拟器 `FB4367FB-F76E-4270-AC9C-56F114A1E178`。这个结果关闭首次 RATE_LIMITED 直接终止导致的该场景失败；不代表所有限流位置或所有规模均已验收。

已启动 1,000 房间 `/tmp/imv2-tls-recovery-scale-1000-driver.log`，输出 `/tmp/imv2-tls-recovery-scale-1000-20260913-01`。测试新增按命令的请求计数、逻辑请求/响应字节统计及首批 20 条本地列表行可读时间；尚待本次构建验证。这些字节不含握手、主动通知、压缩及 TLS 开销，列表行可读也不等于 UI 实际首帧。首轮/重连的 catchup 计时在结果核验目录请求前结束，避免核验流量混入恢复统计。

## 真实规模验收发现限流退避缺口，已修复并重跑

首次 129 房间 TLS 用例实际构建执行，数据已准备，但收到 retryable RATE_LIMITED 后约 1.3 秒直接失败；日志 `/tmp/imv2-tls-recovery-scale-129-driver.log`、对应 app.log，harness 退出 1 并删除专用模拟器。不能作为规模通过证据，也未提高服务端限流阈值。

V2RoomRecoveryRunner 前台路径现对可重试服务端响应执行至少 1 秒、遵守 retryAfterSeconds 的可取消退避，保留监听及持久进度；普通变化通知不缩短冷却期。准备监听、目录/状态/摘要/正文轮次与最终个人证明中的可重试响应均可继续。通知消费者与恢复驱动改为共同 task group，任一失败取消并等待另一方，确保覆盖失效可打断长退避。后台有界任务仍向预算所有者报告错误，不转为无限重试。

新增 RATE_LIMITED/UNAVAILABLE × 0/3 秒四种确定性恢复检查，以及通知失败打断 3,600 秒退避的检查；当前 20 项恢复驱动测试通过（1.707 秒），日志 `/tmp/imv2-recovery-rate-limit-regression-v2.log`。首轮专项的 notStarted 来自测试在 runner 停止后读取本轮进度，已修正为停止前检查或直接查询持久待办。TLS 用例同样修正，并增加失败阶段标记。

已用当前代码重启 129 房间独立环境，日志 `/tmp/imv2-tls-recovery-scale-129-driver-v2.log`，输出 `/tmp/imv2-tls-recovery-scale-129-20260913-02`，尚无终态。首次失败的具体请求阶段未被旧测试标注；本次将验证退避修复是否覆盖实际失败位置。

## 真实 TLS 房间规模入口已接入，129 房间运行中

新增 IMAppRoomRecoveryScaleTests 与 harness `--room-recovery-scale {0,50,129,1000,10000}`（要求 --app-ui --gateway）。独立代理在专用测试账号注册提交后、响应返回前向专用 PostgreSQL 原子写入指定数量的当前成员房间、群资料、room_event 接受事实和非空消息投影。仅测试代理可触发，生产路由没有新增测试接口。测试通过 V2TLSFrameConnection、V2ProtobufSyncTransport、V2SyncEngine、V2RoomRecoveryRunner/Engine 和 SQLite 执行首次恢复及断开后第二轮恢复，每轮等待 live，确认目录完成与待办清空，逐房间检查正文唯一及游标为 1。额外目录遍历用于结果核验，与 catchup 耗时记录分开。

129 房间命令已启动，日志 `/tmp/imv2-tls-recovery-scale-129-driver.log`，输出目录 `/tmp/imv2-tls-recovery-scale-129-20260913-01`，当前正在构建实际服务端，尚无运行结果。Python 语法/帮助与变更空白检查通过；新 Swift 用例尚待本次 App 构建验证。这个入口准备验证真实恢复链路，不将数据库夹具写入视作生产创建/发送压测；首屏、网络字节、查询扫描量及进程资源仍需独立测量。

## 区间索引写成本与 Swift 漂移校验（2026-09-13）

新增独立 PostgresV2RoomSummaryIndexCostTests，在 fresh canonical schema 中分别保留/移除两项区间索引，以 EXPLAIN ANALYZE/BUFFERS/WAL 实际插入 10,000 条接受记录，断言最终消息数量。日志 `/tmp/imv2-summary-index-write-cost.log` 退出 0：4 项/2 套件通过（4.740 秒），包含四个写入参数组合及两项新索引的 Swift readiness 缺失/错误定义/恢复参数验证。

| 存储 | 不带区间索引 WAL | 带区间索引 WAL | 增量 | SQL 执行时间（无/有） |
| --- | --- | --- | --- | --- |
| message_row | 8,313,239 B | 9,577,216 B | 1,263,977 B，约 15.2% | 133.981 / 166.069 ms |
| room_event（事件+消息合计） | 11,944,367 B | 13,214,544 B | 1,270,177 B，约 10.6% | 172.770 / 194.938 ms |

实际使用的区间索引为 901,120 B（约 880 KiB/10,000 条）；另一种存储的空索引为 8,192 B。保留其余 canonical 索引，比较仅移除两项新索引的差异。此测试测量直接批量接受事实写入，未运行完整业务命令、outbox、网络和多用户并发；每种组合仅一次，UUID/B-tree 布局与缓存差异也影响结果。WAL 与时间应作为明确的写入代价基线，不能当作完整发送链路吞吐或稳定百分比回归结论。上线容量仍需代表性读写比例验证，不能只引用摘要读加速而忽略该成本。

## 完整摘要查询与区间索引已接入（2026-09-13）

PostgresV2RoomLatestVisibleStore 现使用单条最新候选权限探测；不满足时，在同一 SQL 快照按历史授权区间从 message_row / room_event 两种接受事实读取候选，最后加载完整当前消息投影、预览及媒体计数。保留当前成员、owner/head 与原始接受消息身份校验。新增 canonical 索引 messages_visible_membership_idx、room_events_accepted_membership_idx，Swift readiness 和 SQL contract 均检查有效状态与完整定义。当前新库仍为未上线 current-36，不引入历史迁移。

日志 `/tmp/imv2-production-interval-summary.log`：原生三库脚本退出 0，6 项/2 套件通过（11.933 秒），参数包含不可见长尾的 message_row、room_event、mixed，已撤回长尾双存储、1,000/10,000 非空房间批次、授权/修改及 schema 检查。不可见长尾生产完整查询分别为 25/489/178 shared buffer hits、0.103/0.219/0.157 ms；三个场景都先探测 1 条，补充读取合计 100 条授权接受事实。room_event 额外关联 100 次当前消息投影，不能与仅返回序号的原型成本混同。

`/tmp/imv2-interval-index-bootstrap-v2.log` 退出 0：canonical 建库/导出恢复及漂移门禁通过，两项新索引缺失和同名错误定义均拒绝；索引总数基线从 339 更新为 341。首次启动脚本因旧数量断言失败已修正，不能把首次失败计作通过。仍需补充索引写成本、复杂授权区间分布、完整系统规模与最终全量回归；此生产改动晚于此前 1,078 项全量结果。

## 有界探测加区间补充查询实验（2026-09-13）

在固定 message_row 夹具继续验证：先读取最新未撤回消息并检查历史权限，有授权结果则不执行区间补充查询；否则按区间寻找候选。64 条探测原型虽跳过普通场景补充查询，但增加读取量，未采用该预算。缩为最新 1 条的实验日志 `/tmp/imv2-single-probe-summary-plan.log` 退出 0，1 项通过（0.792 秒）：不可见尾部总 12 shared buffer hits、0.037 ms；全可见场景只探测 1 条，总 4 hits、0.026 ms，补充分支全部 never executed。移除历史授权后仍返回空，三种分布结果符合夹具预期。

这仍是只返回序号的查询实验，生产 SQL/schema 未改；完整摘要投影、room_event 混合来源、成员修订极值、授权区间较长时的补充排序、索引写放大与批量并发均待验证。实验支持继续评估“单条最新候选探测 + 必要时区间补充”的方向，不证明当前性能问题已经在生产实现中解决。

## 真实 NATS 专项与候选查询实验终态（2026-09-13）

冷热对照 `/tmp/imv2-interval-hot-cold-plan.log` 已退出 0，1 项通过（0.778 秒）。全部 10,000 条均可见时：生产 messages 索引读取 1 行，总 10 buffer hits、0.043 ms；授权候选方案读取并排序 10,000 行，总 612 buffer hits、1.974 ms。虽然候选只返回序号，仍明显增加常见可见历史场景的工作量。因此明确不把该实验 SQL/索引直接推广到生产。后续若优化长不可见尾部，应保留有界最新候选快速路径，再按需使用授权区间补充路径，并证明两种存储与完整摘要语义；当前长尾扫描问题仍未关闭。

修正执行顺序后，等待当前测试包成功构建，再以 `swift test --skip-build --filter V2RealNATSRoomWakeTests` 复用该包，显式启用两个真实 NATS 场景。日志 `/tmp/imv2-real-nats-current-gate-v2.log`：2 项实际执行并通过（0.385 秒），进程退出 0，独立临时 NATS 已终止清理。覆盖独立 Gateway 适配器收到同一房间 wake、服务重启触发覆盖失效并自动恢复订阅；没有再次调用 activate 修复订阅。关闭了本轮全量中这两项 opt-in 未执行的缺口，但不替代慢 TLS 客户端与完整恢复链路的故障负载验收。

`/tmp/imv2-interval-candidate-plan.log` 退出 0，1 项通过（0.583 秒），三个专用数据库 `imv2_acceptance_f6918bee1a75402e` 已确认清理。候选索引在固定 message_row 不可见尾部夹具中只产生 100 条授权候选、8 shared buffer hits、0.029 ms；同轮生产查询仍扫描 9,901 条、执行 3.558 ms。候选只返回序号，不是完整生产摘要，不能把这两个耗时当作完整接口性能比较。已追加全部 10,000 条均可见的相反分布对照，日志 `/tmp/imv2-interval-hot-cold-plan.log`，待取得结果后决定候选策略是否值得采用。

## 真实 headless App 恢复验收通过（2026-09-13）

原进程 `/tmp/imv2-headless-recovery-current-driver.log` 退出 0；实际 HTTPS 账号服务、TLS Gateway、PostgreSQL 及 iPhone 17/iOS 26.2 模拟器完成验收。`/tmp/imv2-headless-recovery-current-20260913-01/headless-summary.json`：1 passed、0 failed、0 skipped，结果包 `headless.xcresult`。同 harness 普通 App 账号用例 2 passed、0 failed，另一个未请求的可选 App 场景 skipped，不能将该跳过场景计作通过。驱动程序核验了预期 HTTP/数据库效果和 Gateway 连接清理，并删除专用模拟器 `460CA4C0-6046-43AB-95CA-37D22450D1D5`。

实际覆盖 V2HeadlessPushIntegrationTests：不建立根 View/不激活 scene 的 delegate 从隔离 Keychain 恢复凭据，调用真实同步栈，将个人游标持久化至 ready 且 applied=acknowledged；重复回调不重复推进；另一设备撤销后凭据清空，后续回调无工作。关闭了完整 App scheme 中该 opt-in 用例未执行的缺口。该测试没有种入多房间非空正文，不证明后台房间规模恢复；也未模拟 APNs 投递、OS 冷启动或设备掉电。

## 第二轮服务端全量与生成物终态（2026-09-13）

`/tmp/imv2-current-server-full-regression-v2.log` 已取得终态：1,078 项、153 套件通过，1615.413 秒，原生三库脚本退出 0。三个专用数据库前缀 `imv2_acceptance_17d91b8dea1943f0` 已查询确认全部删除。此结果取代下文第二轮“仍运行中”的阶段描述。真实 NATS 两个 opt-in 用例明确 skipped，不能计入本轮真实 NATS 验证。

本轮构建执行包括修复后的 HTTP 夹具与 Swift 索引漂移门禁；新增 invisibleHistoryPlan 写于本轮编译之后，未计入这次 1,078 项，仍等待单独执行。headless App harness 已获得构建锁并开始编译；其后排队的不可见历史专项沿用原进程。

当前协议文档检查、schema readiness 关系覆盖检查通过；`scripts/check_v2_protobuf_generated.sh` 重新生成到独立临时目录并比较两端生成物，退出 0，日志 `/tmp/imv2-current-protobuf-generated-gate.log`。这些结果不替代真实网络规模与剩余故障验收。

## 不可见历史专项：正确性通过，确认扫描成本问题

新增 PostgresV2RoomLatestVisibleStoreTests.invisibleHistoryPlan：当前成员已重新加入，前 100 条属于其历史授权区间，尾部 9,900 条属于退群期间。使用生产摘要 SQL 输出 EXPLAIN ANALYZE/BUFFERS，并断言最新可见序号为 100；移除历史授权区间后仍为当前成员，但摘要必须为空。该场景与已撤回尾部不同，不能由 messages_latest_visible_idx 的撤回过滤性能推断其扫描成本。

专项已实际构建执行并退出 0，1 项通过（0.641 秒），日志 `/tmp/imv2-invisible-history-plan.log`；三个专用数据库前缀 `imv2_acceptance_31a79b1db5614e09` 已确认清理。它不属于前述 1,078 项全量包。

执行计划确认当前性能问题：返回 1 条摘要，messages_latest_visible_idx 实际读取 9,901 行，成员区间 Join Filter 排除 19,800 个组合，375 shared buffer hits，执行 3.326 ms。此时间仅为本机热缓存单房间基线；扫描量证明长不可见尾部成本随历史增长，不能宣称索引使所有最新摘要查询接近常数。下一步需比较按授权区间取得候选的查询与索引方案，并覆盖 message_row/room_event 两种接受事实存储、撤回尾部和索引写入成本；不能用放宽历史权限过滤换取速度。

已在该测试的临时数据库加入候选索引与 MATERIALIZED 授权候选查询实验，生产 SQL 和 canonical schema 未改。该实验只比较固定 message_row 夹具的候选序号与扫描计划，尚不具备完整生产接口、权限边界和两种存储的替换条件。日志 `/tmp/imv2-interval-candidate-plan.log`，沿原进程等待当前 NATS 专项编译后执行，尚无结果。

真实 NATS 专项显式设置 IMV2_REAL_NATS_BINARY 与 IMV2_REAL_NATS_URL，使用独立临时服务和重启端口，日志 `/tmp/imv2-real-nats-current-gate.log`。该进程已退出 1：编译期间新增候选查询修改了共享测试文件，Swift 拒绝该构建；未进入测试，临时 NATS 服务已清理，不能计作通过。等待候选查询测试当前构建完成后，应复用同一份已构建测试包重跑，避免重复编译及源码变化竞态。headless harness 已完成，结果见本文开头。

## 静默尾部变化恢复专项（2026-09-13）

补强 V2RoomRecoveryEngineTests.runnerRechecksDirectoryAndWakesForNotifications：首轮两个房间追平至 5 后，只把第二个房间的源水位推进至 7，不发送任何通知，也不断开连接；确认本地仍为 5。推进注入时钟至完整性核对期限并唤醒 runner 后，目录重新扫描，本地水位追平至 7，待办清空，监听启动次数仍为 1。随后另一个房间的正常通知继续驱动恢复至 8。

当前恢复驱动套件 18 项通过（1.622 秒），日志 `/tmp/imv2-recovery-silent-tail-regression.log`。这是生产 runner/engine/SQLite 与受控传输的确定性验证；时钟到期由测试主动唤醒，不能替代真实定时器、数据库发布和 NATS 丢失尾通知的端到端验收。

另已启动实际账号/Gateway 的 headless App 专项，输出目录 `/tmp/imv2-headless-recovery-current-20260913-01`；当前构建等待正在执行的服务端全量释放 SwiftPM，尚无测试结果。

## 客户端恢复资源基线（2026-09-13）

直接运行当前已构建 Swift Testing host，显式启用 V2RoomRecoveryScaleTests，进程退出 0；两个参数用例均通过。日志 `/tmp/imv2-client-recovery-resource-baseline-v3.log`。1,000 房间完成 10 轮，17.727 秒；10,000 房间完成 100 轮，147.118 秒。验证使用生产恢复引擎与 SQLite，覆盖每房间非空正文、游标、待办清空以及数据库关闭重开后的结果。

`/usr/bin/time -l` 对整个测试进程记录：148.72 秒墙钟、89.78 秒 user CPU、8.64 秒 system CPU、85,377,024 字节最大 RSS（约 81.42 MiB）、19,989,224 字节 peak memory footprint。RSS 与 footprint 是不同指标，不能混用。两个规模用例由测试框架并行调度，资源值是整个 Debug 测试进程的合计峰值，包含夹具和测试框架；服务端全量回归同时运行，耗时受竞争影响。这不是单个规模的独立峰值、iOS App 资源上界或 TLS 网络规模验收，也不测 Gateway 成员索引。

新增复测入口 `scripts/measure_v2_client_recovery_resources.sh`：先构建当前测试，再仅对测试宿主计时，排除编译成本。脚本语法与帮助入口已验证；随后完整脚本也退出 0，两个规模参数均通过，日志 `/tmp/imv2-client-recovery-resource-script.log`。脚本复测为 17.296 / 131.898 秒，整个测试进程最大 RSS 85,737,472 字节、CPU user/system 90.27/7.74 秒、墙钟 132.48 秒；适用范围与上面的基线相同。此前两次启动在 Testing.framework 加载前失败，不作为性能证据；通过在系统 time 之后用 env 设置 DYLD_FRAMEWORK_PATH 修复运行环境。

服务端第二轮全量仍在原进程运行，尚未据此报告通过。

更新：2026-09-13。目标仍未完成。设计要求见 [实施方案](client-owned-conversation-sync-plan.md)，阶段性日志见 [历史证据](https://github.com/Yyilin001/IMMonorepo/blob/21fb3cc8/docs/reviews/archive/client-owned-conversation-sync-progress-2026-09-13.md)。历史记录中的“待完成”只代表对应阶段；以下未验证项仍是交付门禁。

## 已有实现及证据范围

| 要求 | 当前实现与证据 | 证据限制 |
| --- | --- | --- |
| 客户端排序、服务端按 ID 提供事实 | GRDBV2ListWindows、本地活动索引、目录/状态/摘要协议；ClientKit 当前回归 613 项/105 套件通过，显式启用进程强杀；日志 `/tmp/imv2-client-full-with-crash.log` | 全量命令中的 opt-in 网络与规模用例不算本次已执行 |
| 删除旧同步路径 | 本轮扫描生产 Sources/App 和 canonical schema：无 RoomSummaryList/Page、V2RoomLogCatchUpWorker、旧后台表；旧排行索引名称仅用于 readiness 拒绝检查 | 仍需整个配置、运维文档与生成代码最终一致性门禁 |
| 协议与 schema 文档一致 | 当前协议 30；修正 implementation-status.md 的过时协议/旧恢复路径说明；协议文档检查、schema readiness 表覆盖检查通过；canonical schema 为 current-36 | 本轮另行通过 native PostgreSQL 建库/导出恢复/漂移门禁，见下文；不代表灾难恢复全流程 |
| Core 合同 | 本轮 Core 125 项/41 套件通过，日志 `/tmp/imv2-core-current-acceptance.log` | 不证明跨服务运行行为 |
| 客户端 1000/10000 非空房间 | 生产引擎+SQLite，每房间一条消息，关闭重开验证；约 9.0/98.7 秒，日志 `/tmp/imv2-client-recovery-scale-v3.log` | Debug、替身网络；不证明首屏、峰值内存或线上耗时 |
| 持续热点下冷房间进展 | 40 轮单房间预算；冷房间五页最迟第 20 轮完成，热点仍推进；引擎 18 项通过 | 两房间确定性调度，不是大规模热点负载 |
| 慢设备隔离和溢出 | 2/4096 待发容量；慢设备挂起，正常设备收到全部 4099 个有序变化；仅慢设备重置，共享订阅保留；26 项通过 | 受控 writer，尚未测真实 TLS 背压与 RSS |
| 服务端数据库规模 | 本轮实际启用 PostgreSQL，目录/状态/摘要/schema/拓扑 10 项、4 套件通过（9.660 秒），包含 10000 房间/100000 消息；日志 `/tmp/imv2-current-recovery-postgres-acceptance.log` | 单库、低历史深度，缺并发和执行计划负载分析 |
| 真实链路 | 历史证据包含双 Gateway/NATS、离线消息补齐、App 三轮前后台单侧提示恢复 | 单房间闭环，不能外推为完整 10000 房间端到端 |

## 未完成的交付门禁

逐项对应实施方案第 9 节，不能用较窄的测试替代：

1. 真实 TLS、生产服务及持久客户端共同执行 0/50/129/1000/10000 房间恢复，记录首屏、追平、查询数量、网络量和资源峰值。
2. 热冷偏斜、长历史及并发用户查询计划，记录实际 rows/buffers 和分片并发；解释成本随自身房间数与缺口增长。
3. 监听安装、扫描、个人流追平期间提交及最后一条通知丢失的全链路完成证明。
4. 扫描中的入群、退出重入、房间/用户迁移与单分片失效组合验收。
5. SQLite 各关键事务边界的进程强杀、重启恢复；现有关闭重开与受控取消证据不能替代。
6. 快照、裁剪、首次安装与真实实时投递并发的跨层一致性验收。
7. 多设备已读、排序、单侧提示与失败发送的组合场景，严格检查有效活动与未读语义。
8. 真实慢 TLS 连接、NATS 故障、Gateway 切换、账号切换后的资源释放和恢复；量化任务/连接/RSS 上限。
9. 最终 Server/Core/ClientKit/App、真实 PostgreSQL、TLS/App、配置/协议/schema/文档门禁，记录哪些用例实际启用及运行所用当前构建。

## 本轮文档维护

原主方案混入大量早期进度描述，已完整移到历史文件，主方案保留设计要求。状态页修正协议 28、旧排行榜恢复接口和兼容 fanout 的当前能力声明。未因此把任何未验证的系统要求标为完成。

## 当前 PostgreSQL 门禁复验

- `IMV2_SCHEMA_BOOTSTRAP_NATIVE=1 PGHOST=127.0.0.1 PGPORT=55439 PGUSER=im_v2_test bash scripts/test_v2_postgres_schema_bootstrap.sh` 退出 0；日志 `/tmp/imv2-current-bootstrap-acceptance.log`。脚本创建唯一临时数据库，从 canonical SQL 建库，导出 schema 与拓扑单例，恢复并比较结构；重新引入旧活动索引及删除所需关系会被合同拒绝。完成后查询系统目录，确认没有遗留 bootstrap/restore 临时数据库。
- `IMV2_POSTGRES_TEST_DATABASE_URL=postgres://im_v2_test@127.0.0.1:55439/im_v2_test IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE=1 swift test --package-path IMV2Server --jobs 4 --no-parallel --filter 'PostgresV2Room(Recovery|LatestVisible)'` 退出 0。10 项测试实际执行，包含参数化的规模和消息存储形式用例。
- 本轮 10000 空房间目录/状态读取约 0.742 秒；10000 非空房间、100000 消息的目录/状态/摘要读取约 1.378 秒。不含造数，单库低深度分布；不能外推真实网络、长历史或并发用户性能。
- 拓扑测试覆盖路由事务、导入/截断/部署变更、缺失拓扑栅栏及禁用触发器。它们不能替代客户端扫描过程中真实跨分片迁移的系统验收。

## 真实前台完成证明

2026-09-13 扩展真实断线恢复 App 用例，使用 `V2RoomRecoveryRunner.run`，并发等待生产引擎 `.live`，检查目录完成且待办为零；取消后要求引擎回到 `.idle`。消息身份/文本、正文游标、列表预览、按 ID 摘要及单侧提示隔离断言保留。脚本强制要求 `IMV2_FOREGROUND_RECOVERY_COMPLETION_PASSED`，不存在未执行而静默通过的路径。

执行：`python3 scripts/verify_v2_live_account_authorization.py --output /tmp/imv2-foreground-proof-live-20260913-01 --app-ui --gateway --private-hint --multi-gateway-nats-binary /tmp/imv2-nats-runtime/nats-server-v2.11.0-darwin-arm64/nats-server`。脚本退出 0，真实 App 场景、HTTPS 与数据库副作用检查通过，专用模拟器及服务按脚本清理。驱动日志 `/tmp/imv2-foreground-proof-driver.log`；App 日志与结果在上述 output 目录。

该轮同时出现前台完成、跨网关在线通知、三轮前后台恢复标记。新增完成证明是单房间真实链路证据，不能替代安装监听期间并发提交、最后通知丢失、多房间规模或任务泄漏量化验收。原后台预算路径继续由 ClientKit 专项覆盖；该 App 场景本轮改为前台路径。

## 长撤回历史摘要索引

2026-09-13 新增生产 SQL 的执行计划集成测试。单房间 10000 条消息，末尾 9900 条撤回，授权摘要必须回退至第 100 条。为防止测试 SQL 与生产 SQL 漂移，将查询构造抽为同一内部 SQLQueryString，正常读取和 EXPLAIN ANALYZE 使用同一表达式。

基线扫描全部 10000 条消息（过滤 9900 条）并执行 top-N 排序，整条计划约 277 次共享缓冲区命中。新增 `messages_latest_visible_idx(room_id, room_sequence DESC, message_id DESC) WHERE withdrawn_at IS NULL` 后，消息索引扫描返回 1 行，排序消失，整条计划约 9 次缓冲区访问；该轮执行时间由约 0.416 ms 变为 0.027 ms。此为单房间本机热缓存示例，不能作为通用延迟 SLO。

索引已写入 canonical schema；Swift readiness 与共享 SQL 合同检查索引归属、完整定义、valid/ready。当前 canonical 索引数从 338 更新为 339。bootstrap 增加索引缺失、同名错误定义和恢复正确定义的漂移测试。未增加旧库自动迁移或兼容路径。

验证：`/tmp/imv2-latest-visible-index-regression.log`，真实 PostgreSQL 11 项/4 套件通过（10.552 秒）；`/tmp/imv2-latest-visible-index-drift.log`，空库建库、导出恢复和漂移检查通过。前后计划证据为 `/tmp/imv2-long-history-index-plan.log`。大量不可见成员区间、room_event 长历史、并发查询及新增索引写入成本仍需测量。

## 双存储长历史计划门禁

2026-09-13 将长历史场景参数化为 message_row 和 room_event。后者真实插入 10000 条接受事件并使用其成员修订做授权。两种形式均验证第 100 条为摘要候选、索引前后结果一致、陌生用户 unavailable、消息索引节点实际只返回一行且只执行一次、无消息序号候选排序。room_event 计划通过事件复合索引定位对应事件。

首次加强断言误把空事件关联上的排序也视为消息排序退化；修正为禁止消息候选排序，保留单行扫描及授权断言。最终 `/tmp/imv2-summary-storage-history-gate-v2.log`：真实 PostgreSQL 3 项参数化测试通过（含双存储长历史、1000/10000 规模及双存储成员可见性），共 6.399 秒。此项不证明大量不可见成员区间的扫描上界，仍需另测。

## 服务端全量回归运行中

2026-09-13 已启动当前 Server 全量串行测试，显式启用 disposable PostgreSQL，分别创建本轮专用 primary/secondary/control 数据库（前缀 imv2_acceptance_28738）。运行脚本 `/tmp/imv2-run-current-server-regression.sh` 在退出时清理三个数据库；日志 `/tmp/imv2-current-server-full-regression.log`。当前仅确认进程仍在执行且数据库测试持续产生进展，尚无终态，不能视为通过。额外 opt-in 外部服务测试是否执行应在结束后核对。

## 当前运维入口清理

2026-09-13 修正 docs/current-system-map.md 的旧 planner/preplanned 数据流和三模式说明，当前图描述统一公共房间日志、个人状态流、账号通知与持久恢复队列。IMV2/docs/README.md 的当前投递入口改为本方案；旧 direct-preplanned-fanout-runbook.md 明确标为仅用于旧 current-2 二进制的历史记录，禁止用于当前部署。当前 command-credit 手册移除已删除的模式选择环境变量。

固定旧 image tag 的 benchmark-hot-baseline-9c8de4fb 配置是历史实验复现，不改写为当前模式，避免破坏历史结果含义。协议文档门禁与本轮文件 diff whitespace 检查通过。服务端全量回归仍在原进程执行，尚无终态；不记录为通过。

## 待执行的 Swift 索引漂移回归

新增 PostgresV2RoomRecoverySchemaTests.currentSchemaRequiresTheExactLatestVisibleIndex，直接调用生产 V2SchemaReadiness，检查缺失索引、同名错误定义均被拒绝，恢复正确定义后通过。该文件在当前全量测试包编译完成后修改，因此不能声称被本轮已运行的二进制覆盖；待全量回归结束后单独构建执行。原全量回归进程仍活跃，日志继续推进，无终态。

## 可复现的原生服务端回归入口

新增 `scripts/test_v2_server_native_postgres.sh`。显式提供 PGHOST/PGPORT/PGUSER 后，脚本创建唯一 primary/secondary/control 数据库，设置 disposable 与三库 URL，执行串行 swift test，退出时仅清理本轮拥有的数据库；保留测试失败退出码，清理失败也返回失败。支持传入 `--filter` 等测试参数。不得把外部服务 opt-in 用例的跳过视为通过。

语法、帮助入口及真实数据库失败清理验证通过。清理验证以临时 swift 替身返回 7，确认脚本仍返回 7，系统目录中三个数据库均已删除；日志 `/tmp/imv2-native-runner-cleanup-check.log`。这仅验证包装脚本生命周期，不替代实际服务端测试。当前原始全量回归继续运行，待其终态后使用新入口执行新增索引漂移用例。

## 房间正文事务的真实进程强杀

2026-09-13 新增 macOS opt-in V2RoomRecoveryCrashTests。父测试通过当前 SwiftPM 宿主加载独立子测试进程；子进程调用生产 applyGroupEventPageReportingChanges，GRDB 事务观察器仅在涉及消息投影的事务 willCommit/didCommit 位置发送 SIGKILL。父进程要求终止原因确为信号、信号为 SIGKILL，再重开 SQLite。

提交前强杀：消息数和游标均为 0；提交后强杀：均为 1。重放相同事件后均只有一条正确正文且游标为 1。测试载荷使用 sortedKeys 保证跨进程重放为相同字节。最初直接执行 macOS 测试 bundle 导致 exec format error，已改为 SwiftPM host；第二轮发现测试生成 JSON 字节顺序不稳定，已修正夹具后重跑。

复现：设置 IMV2_CLIENT_CRASH_BINARY 为当前已构建 IMV2ClientKitPackageTests.xctest/Contents/MacOS/IMV2ClientKitPackageTests 的绝对路径，执行 swift test --package-path IMV2ClientKit --jobs 4 --no-parallel --filter V2RoomRecoveryCrashTests。证据 `/tmp/imv2-room-body-crash-v3.log`，父测试两个阶段通过（0.207 秒）；child 用例只在子进程启用，父进程中的 child skip 不表示缺少强杀验证。此项覆盖正文/游标原子事务，不覆盖全部目录、个人快照、恢复待办事务，也不等同于设备断电与磁盘故障。

## 目录事务崩溃与全量回归发现

2026-09-13 将真实子进程 SIGKILL 测试扩展到目录页提交。目录 cursor 与恢复待办在提交前均不落库、提交后一起落库；新连接重扫后只保留一个房间待办，状态/摘要需求仍存在。正文与目录、提交前/后的四个参数组合通过，日志 `/tmp/imv2-room-directory-crash.log`（1.029 秒）。这是两个事务边界的验证，不代表个人快照等全部提交边界已覆盖。

当前服务端全量运行发现 registrationCancellationHTTP 和 deviceCredentialHTTPRetriesReplayPersistedResult 失败：签发返回 403，继而缺少预期撤销/重放副作用。检查生产 V2DeviceCredentialService 确认签名断言的 credentialRevision 必须匹配持久 account_password_credentials 行，两旧夹具没有该记录。已补齐两个夹具的 revision=1 记录，未放宽认证规则。修改发生于全量测试包构建之后，等待原运行结束后重测；当前全量结果已存在失败，不能报告通过。新增 Swift 索引漂移用例也仍待构建执行。

## 服务端首次全量终态与修复复验

首次全量 `/tmp/imv2-current-server-full-regression.log` 结束：1077 项/153 套件，1464.796 秒，11 条失败断言均属于两个缺少持久凭据修订记录的 HTTP 夹具；不能报告该轮全量通过。三个专用数据库已确认删除。真实 NATS 两个 opt-in 用例明确 skipped，本轮不作为 NATS 证据。

补齐夹具后，使用仓库原生脚本执行 registrationCancellationHTTP、deviceCredentialHTTPRetriesReplayPersistedResult 与 PostgresV2RoomRecoverySchemaTests：4 项/2 套件全部通过（1.847 秒），日志 `/tmp/imv2-server-repaired-gates.log`，脚本退出 0。新增 Swift 索引漂移门禁已实际构建执行；前述“待执行”状态由此关闭。

随后已用当前测试包启动第二轮完整原生三库回归，日志 `/tmp/imv2-current-server-full-regression-v2.log`。该轮仍运行中；需要等待终态，不能将首次全量与修复专项拼成一次无失败全量。

## 恢复待办完成事务强杀与当前客户端全量

2026-09-13 增加 recovery 事务变体：先持久化目标水位 1 的待办和授权状态，再通过生产 applyRoomRecoveryPage 写入正文、游标并完成待办。willCommit SIGKILL 后：正文与游标为零，待办仍有一项；didCommit SIGKILL 后：正文与游标为一，待办为零。新 scope 下继续未完成待办，随后重放同一事件，验证待办清空且消息不重复。

正文、目录、恢复完成三个事务各前/后共六种真实强杀组合通过，专项日志 `/tmp/imv2-room-work-crash.log`。随后显式设置 IMV2_CLIENT_CRASH_BINARY 跑完整 ClientKit：613 项/105 套件通过（59.897 秒），日志 `/tmp/imv2-client-full-with-crash.log`；六个强杀组合确实执行。父进程的 crashChild 入口跳过符合设计，子进程必须以 SIGKILL 终止才算对应组合通过。未启用的其他网络/规模 opt-in 用例仍不能计作此次已执行。

第二轮 Server 全量仍在原进程运行，尚无终态。

## 当前 App scheme 完整回归

2026-09-13 在专用 iPhone 17 / iOS 26.2 模拟器执行 IMApp scheme（IMAppTests + IMAppUITests），当前构建使用 ad-hoc simulator signing，未限制 only-testing。xcodebuild 退出 0，TEST SUCCEEDED；结果包 `/tmp/imv2-app-full-current-20260913-01.xcresult`，日志 `/tmp/imv2-app-full-current-20260913-01.log`。

xcresult summary：240 passed、0 failed、1 skipped（包含参数展开时设备级运行数量不同，不混为测试数量）。Swift Testing 日志报告 235 项/37 套件通过。唯一未启用项是 Live headless Push entry，需要真实账户/Gateway 环境，不能算已验证；它仍需通过对应 live harness 单独执行。普通 UI 场景包括密码登录/注册、大字体 RTL 和暂停撤销恢复。专用模拟器 FEB5A08A-70E3-49AF-860C-2F986021B7AF 已确认删除。

第二轮服务端全量回归仍活跃，继续跟踪原句柄，不重复启动。


## 验收页整理前的完整记录（慢 TLS 第四轮启动后）

以下为整理前验收页的原文快照，仅保留过程证据；其中运行状态以当前验收页为准。

# 会话同步当前验收状态

慢 TLS 第三轮已退出 1，明确 `PRESSURE_EXHAUSTED committed=8192`，目标关闭指标仍为零；专用模拟器 A0EDFB62-B021-4663-9BB1-A99FBB914C24 已清理。审查发现测试新建账号通知连接后未读取目录，遗漏安装目标房间覆盖；Ready 本身不保证房间已覆盖。新增真实目录读取及暂停前探测消息，必须从账号通知消费者读到目标房间 head=3 才允许开始压力，恢复期预期正文/游标相应加一。第四轮 `/tmp/imv2-tls-recovery-slow-129-v4-driver.log`、输出 `/tmp/imv2-tls-recovery-slow-129-20260913-04` 已启动，尚未通过；前三轮均不证明完整背压恢复。

慢 TLS 第二轮 `/tmp/imv2-tls-recovery-slow-129-v2-driver.log` 已退出 1，未进入 App 测试：隔离租约预算改为 10000，但运行配置仍为 1000，真实 readiness 报 `persistedLimitsMismatch(profileID: "standard")`。已同步隔离 Account 与两个 Gateway 的 `IM_V2_MAX_COMMANDS_PER_WINDOW`，保持 readiness 校验。第三轮 `/tmp/imv2-tls-recovery-slow-129-v3-driver.log`、输出 `/tmp/imv2-tls-recovery-slow-129-20260913-03` 已启动；不计为行为通过。

慢 TLS 首轮真实驱动已退出 1，专用模拟器 4DB9D45F-F183-4376-900B-4BE0B244A0EB 已删除。正常恢复/跨 Gateway 在线通过，慢连接阶段未出现目标关闭指标而失败；转发确实暂停。首轮发送上限 512，群事件通知可能仅携带水位，不能用消息正文大小推断推送字节数。专项改为 128 字节独立正文、最多 8192 条/600 秒，并在预算耗尽或观测关闭时记录已提交数；仅该隔离数据库的命令租约调整为 10000，生产限制不变。重跑 `/tmp/imv2-tls-recovery-slow-129-v2-driver.log`、输出 `/tmp/imv2-tls-recovery-slow-129-20260913-02` 已启动，尚无通过结果。

慢 TLS App 专项已接入 `IMAppRoomRecoverySlowTLSTests.swift`，构建 `/tmp/imv2-slow-tls-app-build.log` 已退出 0、TEST BUILD SUCCEEDED。真实账号双 Gateway 场景通过透明转发器暂停主连接服务端读取，另一 Gateway 提交独立 4096 字节正文，限定发送数量与截止时间；要求主 Gateway 必需通知关闭指标增加一次，恢复转发后重新连接，同一本地库完整正文集合与游标必须一致。真实驱动 `/tmp/imv2-tls-recovery-slow-129-driver.log`、输出 `/tmp/imv2-tls-recovery-slow-129-20260913-01` 已启动，当前仍在构建服务端，尚无行为通过结果。该场景显式编排重新连接，不能扩大为生产 App 生命周期自动重连证明。

最新增量：隔离驱动已接入 `--room-recovery-slow-tls`，主 Gateway 使用独立上游端口，由透明 TLS 转发器保持 App 的 7443 入口；测试专用 HTTPS 固定路由支持暂停、恢复和读取主 Gateway 两种明确关闭原因指标，保存 `tls-relay-events.json`。开关在模拟器启动前传入，终验必须有专项 App 成功标记及完整暂停/恢复周期，缺少专项执行不能通过。清理转发器失败会延后到其他进程和数据库清理完成后报告。Python 编译、差异空白检查及非法参数在创建资源前拒绝已通过。**App 慢连接场景尚未接入，因此完整专项仍未通过。**

目标：按 [实施方案](client-owned-conversation-sync-plan.md) 完整落地；不保留历史兼容路径。**目标尚未完成。** 本页按方案十项验收要求组织，局部通过不等于整项完成。

过程、失败和实验原始记录完整保留于 [2026-09-13 证据记录](client-owned-conversation-sync-evidence-2026-09-13.md) 与 [早期实施记录](https://github.com/Yyilin001/IMMonorepo/blob/21fb3cc8/docs/reviews/archive/client-owned-conversation-sync-progress-2026-09-13.md)。历史“运行中”不能覆盖本页终态。

## 当前正在执行

当前 canonical schema 原生建库/导出恢复/漂移校验 `/tmp/imv2-schema-final-bootstrap.log` 已退出 0，成功标记完整；随后查询 PostgreSQL 系统目录，确认没有遗留 imv2_bootstrap / imv2_restore 临时数据库。该结果不替代服务端全量及实际分片故障验收。

当前 App 完整 scheme 已退出 0，驱动 `/tmp/imv2-app-final-current-driver.log`，构建/测试日志 `/tmp/imv2-app-final-current.log`，结果 `/tmp/imv2-app-final-current-20260913.xcresult`。使用另一个专用 iPhone 17 / iOS 26.2 模拟器，驱动已确认专用模拟器 BE14CAE7-0ED4-4BD9-9266-F24F7CB0ED73 清理；结果为 240 passed、0 failed、1 个 headless opt-in skipped，不把跳过项视为通过，也不替代真实账号/TLS opt-in 场景。

当前 Core 全量 `/tmp/imv2-core-final-current-20260913.log` 已退出 0，125 项/41 套件通过。当前 ClientKit 全量 `/tmp/imv2-client-final-current-20260913.log` 已退出 0，618 项/105 套件通过（90.813 秒），显式启用真实强杀，包含最近的状态/摘要强杀参数与非空正文并发测试。

当前 Server 全量已退出 0，日志 `/tmp/imv2-server-final-current-20260913.log`：1081 项/154 套件，1725.285 秒；两个真实 NATS opt-in 测试跳过，不算通过。使用原生 PostgreSQL 的三个独立临时数据库，随后查询系统目录确认 `imv2_acceptance_cefe54f498764cf9` 前缀数据库全部清理。与 App 测试有并行时段，不将耗时视作隔离压测。

129 房间跨 Gateway 整轮已退出 0，日志 `/tmp/imv2-tls-recovery-scale-129-cross-driver.log`，输出 `/tmp/imv2-tls-recovery-scale-129-cross-20260913-01`。两轮恢复及第 129 房间经真实 NATS 的在线更新通过，HTTP/数据库效果终验通过，专用模拟器 9F55AE2B-5A08-435A-AA81-927B73897CFE 已清理。该测试不含 broker 故障。

0 房间空目录测试已退出 0；日志 `/tmp/imv2-tls-recovery-scale-0-driver.log`，输出 `/tmp/imv2-tls-recovery-scale-0-20260913-01`。两轮恢复分别 0.075/0.039 秒，无正文请求，客户端与代理成功刷新计数均 0；3 passed、0 failed、1 未请求可选项 skipped，HTTP/数据库终验通过，专用模拟器 C85BF363-2AAD-4957-9B73-E43CA99121DB 已清理。

129 房间双 Gateway/broker 故障整轮已退出 0，日志 `/tmp/imv2-tls-recovery-broker-129-driver.log`，输出 `/tmp/imv2-tls-recovery-broker-129-20260913-01`。停止真实 NATS 后收到 coverageLost，重启并重新建立连接/覆盖后，另一 Gateway 发送的第三条消息及游标自动落库。broker-fault-events.json 验证一次 stop/start、不同 PID；HTTP/数据库终验通过，专用模拟器 52F5A3DF-A9EF-49BD-AC4A-2F7362BFB30C 已清理。该证据不覆盖静默尾通知丢失或慢 TLS。

修正计量器后的万房间完整流量复测已退出 0，日志 `/tmp/imv2-tls-recovery-scale-10000-v3-driver.log`，输出 `/tmp/imv2-tls-recovery-scale-10000-20260913-03`。首次 1014.733 秒，跨自然到期刷新/重连一次，循环级计量器覆盖两次连接：逻辑发送 2002147 B、接收 8983205 B，正文请求 10822 次（含重试）；第二轮 23.387 秒，发送 432864 B、接收 1413089 B，无正文请求。第 129 房间在线更新、HTTP/数据库终验通过，刷新计数两侧均 1；专用模拟器 10ADE970-1E53-48A1-9147-D4504C6F836B 已清理。

129 房间跨 Gateway 静默尾通知首轮退出 1：常规恢复通过，但故障开关未传入测试宿主，缺少专项成功标记，驱动拒绝通过。模拟器 9513344F-1B37-4A37-9A61-5ADB23D4377B 已清理。已将开关移到模拟器启动前，并同时传入 TEST_RUNNER 环境；重跑日志 `/tmp/imv2-tls-recovery-silent-tail-129-v2-driver.log`，输出 `/tmp/imv2-tls-recovery-silent-tail-129-20260913-02`，已退出 0。真实 TLS 消费边界丢弃目标通知一次，无其他通知转发，测试专用 5 秒周期核对自动补齐第三条正文和游标；App 3 passed、0 failed、1 未请求可选项 skipped，HTTP/数据库终验通过，专用模拟器 59AFD5D0-FE74-403A-B924-01D68860A29E 已清理。

万房间 `/tmp/imv2-tls-recovery-scale-10000-v2-driver.log` 已退出 0：首轮 1015.162 秒，第二轮 23.156 秒；自然到期后刷新一次、续连并完成全部正文恢复，目录第 129 房间在线更新通过。3 passed、0 failed、1 未请求可选项 skipped；HTTP/数据库终验通过，专用模拟器 A67E8A98-964E-4040-87C9-9FC0D9159699 清理。此轮是单 Gateway，不证明跨 Gateway 故障恢复。

资源采样无错误，两角色各 1009 个样本：Gateway RSS 峰值 56,819,712 字节，测试宿主 296,861,696 字节。期间同机编译，不能作为隔离性能 SLO。发现首轮计量器随重连重建，打印的请求/字节只包含最后一次连接；第二轮无重连的数据完整。已将计量器移至整个周期作用域，修正尚待构建执行，首轮完整流量仍缺证据，不能把已打印的 994 次正文请求当成万房间总数。

## 逐项验收矩阵

| 方案条目 | 已有证据及范围 | 尚缺的完成证据 |
| --- | --- | --- |
| 1. 0/50/129/1000/10000 房间及超过 128 的在线覆盖 | 五档恢复通过；129 房间跨 Gateway 在线通过；万房间完整跨重连计量及资源范围已汇总至规模结果文档 | 1000 房间既有结果早于在线专项，不扩大为该档在线证明 |
| 2. 冷热分布、分页与查询扫描成本 | 真实 SQL 长撤回尾部、不可见历史及双接受存储检查；索引漂移和写成本专项通过 | 混合/冷热偏斜/并发用户的实际查询数量、rows/buffers、分片并发和资源 |
| 3. 监听安装、扫描与通知缺失时的一致性 | 129 房间真实跨 Gateway 的监听前、目录响应和旧状态响应交错通过；TLS 消费边界丢弃最后通知后周期核对恢复 | 服务端安装监听内部竞争窗口；上游 broker 丢失等其他故障边界 |
| 4. 扫描中成员变化、迁移、分片不可用 | 分层成员栅栏、拓扑、owner 与状态测试 | 真正跨组件的加入已扫描区间、退出重入、房间/用户迁移及单分片失效组合 |
| 5. 事务强杀、预算与旧任务晚到 | 十三种场景提交前后共 26 个真实 SIGKILL 参数，含成员撤销、快照初始化/分页/准备/激活和重置开始/取消；持久公平队列与旧任务保护测试 | 其余持久队列提交边界覆盖审计；真实后台期限组合 |
| 6. 快照重置、裁剪与首次安装 | 分层快照/裁剪；摘要不推进正文游标的强杀证据 | 快照、裁剪、首次安装与实际实时投递并发的跨层验收 |
| 7. 实时/恢复并发、多设备已读与旧状态 | 真实 SQLite 非空消息三种到达顺序均幂等且保留新目标；状态比较检查 | 真实网络并发、跨设备已读和旧状态延迟组合 |
| 8. 有效活动规则与多设备排序 | 本地 reducer、撤回/摘要/单侧提示分层检查；单侧提示实际 App 证据 | 撤回、编辑、失败发送、单侧提示与多设备排序组合 |
| 9. 慢消费者、NATS 故障、Gateway/账号切换 | 双 Gateway 真实 broker 停止/重启恢复通过；真实 TLS 写阻塞和明确关闭原因专项通过；缓冲区溢出分层测试 | 完整 App 慢 TLS 重连恢复尚在执行；Gateway/账号切换后恢复与资源上界 |
| 10. 当前全量和部署合同 | 历史全量、生成物、schema 及真实 PostgreSQL 记录见下 | 所有最后改动后的 Server/Core/ClientKit/App 和协议/schema/配置最终统一门禁 |

## 最近通过与失败的准确范围

- **50 房间整轮通过**：`/tmp/imv2-tls-recovery-scale-50-driver.log` 退出 0，3 passed、0 failed、1 个未请求可选项 skipped。首次恢复 3.852 秒、第二轮 0.162 秒；真实主动刷新一次，客户端和代理计数一致，在线自动落库及数据库终验通过。不是自然到期模拟。
- **129 早期在线行为通过、同轮认证失败**：`/tmp/imv2-tls-recovery-scale-129-20260913-06/app.log` 显示两轮恢复及目录第 129 个房间在线更新通过；驱动退出 1，原因是另一个 App 注册激活场景失败。该失败未取得根因，不因 50 房间重跑通过而宣称已修复。此前仅两轮恢复的整轮成功见历史记录。
- **1000 两轮恢复通过**：`/tmp/imv2-tls-recovery-scale-1000-driver.log` 退出 0；首次 97.911 秒、重连 2.246 秒，后者无正文拉取。早于新增在线阶段，不能计作规模在线通过。
- **首次万房间失败**：`/tmp/imv2-tls-recovery-scale-10000-driver.log` 退出 1，Gateway 明确 sessionExpired；测试旧路径持有初始 access token。当前重跑改用现有 AuthSession/连接协调器并保留 SQLite 续连，没有延长生产令牌期限。
- **ClientKit 全量**：`/tmp/imv2-client-final-current-20260913.log`，618 项/105 套件通过，包含状态/摘要强杀及非空并发检查；随后只新增成员移除强杀参数，专项 12 个参数通过，见下方记录。
- **强杀专项**：`/tmp/imv2-recovery-summary-crash.log`，10 个参数通过，覆盖正文、目录、正文待办完成、状态、摘要。父宿主 crashChild 跳过，实际由十个子进程执行并被 SIGKILL；不把跳过项另算通过。
- **持久化专项**：`/tmp/imv2-recovery-realtime-race.log`，18 项通过，含实时先到、恢复先到、并发三种非空消息顺序；不是网络故障验收。
- **跨 Gateway 规模入口构建**：`/tmp/imv2-cross-gateway-scale-build.log`，TEST BUILD SUCCEEDED。真实 129 房间跨 Gateway 已取得整轮通过，见本页当前状态。
- **Server 历史全量**：`/tmp/imv2-current-server-full-regression-v2.log`，1078 项/153 套件通过，但早于最新摘要 SQL/索引修改；真实 NATS opt-in 当时跳过，后由 `/tmp/imv2-real-nats-current-gate-v2.log` 两项实际执行补验。
- **Core/App 历史门禁**：Core `/tmp/imv2-core-current-acceptance.log` 125 项/41 套件；App `/tmp/imv2-app-full-current-20260913-01.xcresult` 240 passed、0 failed、1 headless opt-in skipped，随后独立 headless harness 实际通过。均不替代最终当前源码全量。

## 接下来的执行顺序

1. 完成当前已启动的完整 App 慢 TLS 场景，按明确关闭原因和重连数据核对判定结果。
2. 补齐服务端安装监听内部竞态、成员/拓扑变化和多设备组合；既有三个扫描边界通过不能替代这些范围。
3. 补齐冷热偏斜和并发用户的实际查询成本。万房间完整计量与静默尾通知整轮已完成，不重复列为待执行。
4. 对照上表补齐全部证据，最后执行所有当前版本门禁。不得把测试入口存在、构建通过或局部绿色替代对应行为要求。

## 观测边界

新增 `--room-recovery-broker-outage` 真实故障入口，要求非空规模和独立双 Gateway/NATS。测试先等 live，再通过仅存在于隔离代理的固定控制路径停止专用 broker；必须收到 coverageLost，随后重启 broker、重新建立覆盖，并验证第三条正文和游标自动到达。未增加生产控制接口。`/tmp/imv2-room-broker-outage-build.log` 已 TEST BUILD SUCCEEDED、退出 0；Python 语法及空白检查通过。该故障场景整轮已通过，证据见本页顶部；第 9 项仍缺慢 TLS 及切换组合，不能整项标记完成。

故障驱动进一步记录 `broker-fault-events.json`：停止前确认专用进程存活，停止后记录退出码，重启后确认端口可连接；终验要求恰好一次停止/启动、不同 PID 且新进程仍存活。Python 语法和空白检查通过；真实故障整轮的记录与客户端标记现已共同通过驱动终验。

持久化强杀新增成员移除事务：真实子进程分别在提交前/后 SIGKILL，重新打开 SQLite 检查状态、摘要、待办和个人 applied_sequence 原子变化；提交前重放移除事件，随后确认旧成员修订摘要无法重新写入。`/tmp/imv2-recovery-removal-crash.log` 已退出 0，六种事务各两个边界共 12 个参数通过（1.123 秒）；父进程的 crashChild 入口按设计跳过，参数子进程实际终止信号均验证为 SIGKILL。该证据不替代快照重置及后台期限组合验收。

上述验收说明更新后，文档链接与结构门禁均退出 0，日志分别为 `/tmp/imv2-document-links-broker-evidence.log` 和 `/tmp/imv2-document-structure-broker-evidence.log`。Server 全量及数据库清理已通过，准确终态见本页顶部。

首批本地列表行可读不等于 UI 首帧渲染。请求字节为 protobuf 逻辑帧，不含 TLS 开销、认证和非请求通知。RSS 为每秒采样峰值，非精确瞬时峰值。规模凭据使用测试 actor 原子存储，实际认证/刷新/连接使用生产组件；不证明 Keychain 冷启动，后者由独立 App 测试覆盖。诊断采集仅限既有安全错误分类日志。

当前协议文档与版本、schema 关系覆盖及 protobuf 独立生成比对全部通过，日志分别为 `/tmp/imv2-protocol-final-docs.log`、`/tmp/imv2-schema-final-tables.log`、`/tmp/imv2-protobuf-final-generated.log`。文档门禁发现读取合同仍描述旧活动排行接口，已改为当前目录/状态/摘要及客户端排序职责，补上索引登记和历史归档标记；重跑文档结构与链接门禁的日志为 `/tmp/imv2-final-document-structure-v2.log` 和 `/tmp/imv2-final-document-links-v2.log`。

快照激活强杀专项 `/tmp/imv2-recovery-snapshot-crash.log` 已退出 0，七种事务各两个边界共 14 个真实 SIGKILL 参数通过（1.812 秒）。新增场景从非空旧正文、房间状态和摘要切换到空快照：提交前保留旧正文/resetPending，提交后正文清空且 generation=2、applied/serverAcknowledged=10 同时成立；重新打开 SQLite 后可完成待激活事务，旧代际摘要不可读，并清理 retired tables。本证据针对空快照激活事务，不证明导入分页、非空快照或实时网络并发。

非空快照激活扩展 `/tmp/imv2-recovery-nonempty-snapshot-crash.log` 已退出 0，八种场景各两个边界共 16 个 SIGKILL 参数通过（2.391 秒）。非空快照使用真实 V3 编码/摘要和 applySnapshotPage 导入；激活事务提交前保留旧消息，提交后仅保留快照消息，个人游标与代际同事务切换，旧摘要不可读。这里仍只在激活事务边界强杀，不将正常执行的导入分页算作分页强杀证明。

快照分页强杀专项 `/tmp/imv2-recovery-snapshot-page-crash.log` 已退出 0，九种场景各两个边界共 18 个真实 SIGKILL 参数通过（2.784 秒）。分页提交前/后重新打开 SQLite，核对 next_page_index、rolling_digest、applied_items、applied_bytes 原子变化，旧 live 正文在激活前保持不变；提交前重放该页、提交后跳过已提交页，最终激活得到唯一快照正文和正确个人游标。尚不覆盖快照初始化/准备事务及真实后台期限。

静默尾通知入口 `--room-recovery-drop-tail` 已实现：在真实 TLS 解码后的测试消费者丢弃指定房间目标 head 的全部通知副本，进入 live 后才启用丢弃计数，要求实际丢弃数大于零且无其他通知触发；不调用手动补拉，以测试专用 5 秒核对间隔恢复第三条正文。真实服务端提交、拉取和 SQLite 保持原实现。故障点在消费者边界，不证明 broker 丢帧检测。最终构建 `/tmp/imv2-silent-tail-build-final.log` 已 TEST BUILD SUCCEEDED、退出 0，Python 语法及空白检查通过；尚未执行真实场景，等待当前万房间驱动释放固定测试端口。

规模证据汇总工具 `scripts/summarize_v2_room_recovery_evidence.py` 已读取 0/50/129/1000/10000 既有通过结果，生成 `/tmp/imv2-recovery-scale-evidence-summary-01.json`。输出首轮/重连耗时、逻辑流量、采样进程峰值 RSS 与采样范围；缺数据保留 null/空集合，旧万房间跨连接流量明确标记待核实。使用已知失败的 129-06 App 结果验证拒绝收录且不创建输出。汇总仅证明 App/恢复证据，HTTP/数据库终验仍分别核对；跨 Gateway 资源采样仅含主 Gateway，不能当作整套系统峰值。

快照初始化/准备强杀专项 `/tmp/imv2-recovery-snapshot-setup-crash.log` 已退出 0，十一种场景各两个边界共 22 个 SIGKILL 参数通过（4.176 秒）。导入初始化检查 manifest 与可继续导入的影子表一起提交；激活准备检查 activation_prepared 与可激活状态一致，提交前重做及提交后幂等重做均完成，最后正文和游标正确。仍未把重置开始/取消、后台期限与实际网络并发计入本专项覆盖。

重置开始/取消强杀首次 `/tmp/imv2-recovery-reset-crash.log` 失败：SIGKILL 后回调可能继续执行，使提交前边界不可靠；另有取消后误调用要求 resetPending 的读取接口。测试注入器改为发出 SIGKILL 后永不返回，取消后直接核对导入行清理。`/tmp/imv2-recovery-reset-crash-v2.log` 已退出 0，全部 26 个参数通过（5.093 秒），同步游标/回滚行原子变化，取消后旧正文保留且可再次重置。生产实现未修改。

当前规模测量和边界已整理至 [规模验收结果](client-owned-conversation-sync-scale-results.md)，万房间复测资源采样无错误，主 Gateway/测试宿主峰值分别 54.61/284.97 MiB。文档链接及结构门禁在修复新文件生成失败后通过，日志 `/tmp/imv2-scale-results-doc-links-v2.log`、`/tmp/imv2-scale-results-doc-structure-v2.log`。

最新 ClientKit 全量 `/tmp/imv2-client-full-26-crash.log` 已退出 0，618 项/105 套件通过（69.345 秒），包含最新全部 26 个实际 SIGKILL 参数（4.608 秒）。此前强杀注入器的问题修复后，已在完整套件中重新验证。

新增真实扫描竞态入口 `--room-recovery-scan-race before-listener|directory|state`，独立测试文件 `IMAppRoomRecoveryRaceTests.swift` 包装实际 TLS 读取：在所选边界通过第二 Gateway 提交第三条消息，再交还真实响应。保持原通知消费和 3600 秒核对间隔，要求无需手动补拉即达到 live、三条正文与游标 3。`/tmp/imv2-scan-race-build.log` 构建退出 0，Python 语法及空白检查通过；目录边界整轮已退出 0，日志 `/tmp/imv2-tls-recovery-directory-race-129-driver.log`、输出 `/tmp/imv2-tls-recovery-directory-race-129-20260913-01`，专项 marker、HTTP/数据库终验通过，专用模拟器 C989DBDE-1EAA-41C4-9B51-7EC511D6A54F 已清理。该入口不证明服务端安装路由过程内部的事务竞态，后者仍需专门证据。

旧状态交错场景新增明确前置断言：必须读取到目标房间 head=2 的真实成功响应，再经第二 Gateway 提交第三条消息，不能用 unavailable/retry 响应替代。`/tmp/imv2-scan-race-state-proof-build.log` 构建退出 0；实际 state 场景已退出 0，日志 `/tmp/imv2-tls-recovery-state-race-129-driver.log`，输出 `/tmp/imv2-tls-recovery-state-race-129-20260913-01`。专项 marker 与 HTTP/数据库终验通过；App 3 passed、0 failed、1 未请求可选项 skipped，专用模拟器 0461AD08-3FB3-4730-94D8-43E6F45B8267 已清理。

监听建立前提交场景已退出 0，日志 `/tmp/imv2-tls-recovery-before-listener-129-driver.log`、输出 `/tmp/imv2-tls-recovery-before-listener-129-20260913-01`，专项 marker 及 HTTP/数据库终验通过，专用模拟器 A88244DB-5885-4251-87BE-A7B4187AF546 已清理。下一步慢 TLS 验收需在 V2TLSByteConnection 底层暂停真实网络读取，并观测 V2NIOGatewayChannelHandler 的不可写处理；停止业务通知消费仍会让 TLS reader 持续排空网络，不能替代真正背压。

慢 TLS 代码审查确认 requiredNotificationWriter 在通道不可写时关闭连接，写 promise 超过 10 秒时也关闭；实际压力验收必须证明触发这类关闭原因并恢复，不能仅凭客户端暂停或请求超时判为背压处理通过。当前三个真实扫描边界（监听前、目录响应、旧状态响应）均已整轮通过，仍不覆盖服务端安装监听内部的竞争窗口。

慢通知关闭原因新增固定指标标签 required_notification_backpressure / required_notification_write_timeout，分别在真实通道不可写和通知写入 10 秒超时路径记录，维持原关闭策略；避免压力验收只能看到泛化 request_failure。现有 NIO 通道测试增加原因和只计数一次的断言。专项日志 `/tmp/imv2-required-notification-reasons.log` 已退出 0，30 项/2 套件通过（0.135 秒），包括四种通知写入模式和 Prometheus 渲染。该分层验证不算真实慢 TLS 通过。这次修改涉及 Server 源码，之前 1081 项全量不覆盖新增原因标签，需后续当前版本门禁。

真实慢 TLS 传输专项已实现于 `V2GatewaySlowTLSTests.swift`：临时自签证书作为显式信任根、TLS 1.3 握手后关闭客户端 autoRead，双方套接字缓冲限制为 4096，再经生产 NIO required notification writer 连续发送。要求至少一次成功写入后出现且仅出现一个背压/写超时关闭原因，排除通用 request_failure。认证使用本地替身，尚不证明 PostgreSQL/App 重连恢复。专项最终 `/tmp/imv2-real-slow-tls-v4.log` 已退出 0，真实 TLS 写阻塞及关闭指标通过；具体范围与失败修正见下。

慢 TLS 过程：首轮因构建期间修改输入被拒绝，第二轮补齐 NIOTLS 测试依赖后继续；第三轮确实停止读取并触发写失败，但关闭计数等待刚好等于 NIOSSL 默认 5 秒关闭握手期限，边界断言失败。最终按配置 shutdownTimeout 加 2 秒调度余量等待，仍要求 activeConnections=0、背压或写超时原因总计恰好 1、request_failure=0。`/tmp/imv2-real-slow-tls-v4.log` 真实传输专项通过；没有修改生产关闭期限，仍不将该认证替身传输测试视为完整 App/数据库重连恢复。

完整 App 慢 TLS 验收的透明 TCP 转发器已实现：`scripts/imv2_tls_backpressure_proxy.py` 只转发密文字节，暂停上游读取，单方向最多保留 4096 B 待发送块，保留部分发送进度，关闭时清理套接字及线程。真实证书校验的 TLS 检查已通过：暂停后客户端应用读取超时，恢复后 262144 B 载荷 SHA-256 一致，退出后 activeSockets=0 且工作线程结束。Python 语法/空白检查通过。该转发器尚未接入真实账号 App 驱动，不作为完整慢客户端恢复验收通过。


## 2026-09-14 慢 TLS 与查询优化过程记录

下段保留中间阶段原文，最终结果以当前验收页为准。

## 当前执行与最近结果

参数化成员查询新增异常回归已在真实 PostgreSQL 通过：`/tmp/imv2-recovery-duplicate-membership.log` 退出 0。同一用户同一房间两条有效成员修订会明确报 corruptPersistence，证明优化未用 LIMIT 1 隐藏重复授权状态；临时数据库前缀 81636c8c9cd14455 已查询确认清理。

慢 TLS 第八轮已启动：`/tmp/imv2-tls-recovery-slow-129-v8-driver.log`，输出 `/tmp/imv2-tls-recovery-slow-129-20260913-08`。发送预算仍为 8192 条/600 秒，改为轮换最多 129 个实际读取并安装覆盖的房间，减少单热房间水位合并对压力的影响；恢复后逐房间核对完整正文集合、原有消息数量与游标。未增加生产队列或放宽关闭通过条件，尚无本轮通过结果。

第二版查询优化已通过真实 PostgreSQL 回归：`/tmp/imv2-recovery-query-cost-native-v3.log` 退出 0，4 项/2 套件，包括 1000/10000 目录规模、授权与分页。16 条捕获的生产查询均无 rooms/room_memberships 全表扫描；目录暖计划执行约 0.070–0.084 ms，状态约 0.113–0.126 ms。该结果只适用于此 10000 房间、四类成员且无正文负载的数据集，不是线上 SLO。Server 源码发生改变，最终全量门禁仍待执行。

冷热查询专项 `PostgresV2RoomRecoveryQueryCostTests` 已在真实临时数据库执行，`/tmp/imv2-recovery-query-cost-native.log` 退出 0：四类成员、10000 房间、16 条真实生产查询、峰值同时发起 4 条。原执行计划暴露每页关联扫描全 rooms 表，广覆盖状态扫描全成员表；不能据行为通过判定成本合格。第一版优化目录关联后，`/tmp/imv2-recovery-query-cost-native-v2.log` 因两个成员全表扫描断言失败，既有目录/授权/规模测试通过。第二版使用按房间参数化的成员关联，保留重复记录检测，重跑 `/tmp/imv2-recovery-query-cost-native-v3.log` 正在执行。该专项测量调用并发和暖缓存计划，不声称物理分片并发或冷磁盘性能。初轮临时数据库前缀 d2fc9671b8984a78 已查询确认无遗留。

完整 App 慢 TLS 第七轮已退出 1，驱动 `/tmp/imv2-tls-recovery-slow-129-v7-driver.log`，输出 `/tmp/imv2-tls-recovery-slow-129-20260913-07`，8192 条预算耗尽未出现目标关闭，专用模拟器 BD9183C6-BE39-445D-927D-6A8D69B70E1D 已清理。第六轮同样退出 1，专用模拟器 911B845D-9933-409C-BC8F-34D25DCB9050 已清理。当前没有运行中的慢 TLS 驱动。

第七轮实际快照显示暂停后接收缓冲增长到 526720 字节，说明短时转发器回归不能证明持续压力下的内核缓冲上界。当前不将 4096 设置值当成持续上界，也不据此宣称背压条件充分。

第六轮通知覆盖探测通过，但暂停后 TCP 接收队列仍超过 4096 字节，因此转发器在 pause 故障边界重新设置接收缓冲，并将实际 `upstreamReceiveBuffers` 写入快照。独立套接字检查将缓冲扩大后调用 pause，确认恢复为 4096、清理后连接为零；该检查不替代 TLS 全链路，也不属于第六轮结果。

转发器新增可重复 TLS 回归 `scripts/test_imv2_tls_backpressure_proxy.py`，`/tmp/imv2-relay-tls-regression.log` 已退出 0。使用临时证书并验证 localhost，握手后暂停时实际接收缓冲为 4096；暂停期间应用读取超时，恢复后 262144 字节逐字节一致，并确认线程及套接字清理。这证明测试转发器行为，不替代 Gateway/App/数据库重连验收。

第五轮已退出 1：`PRESSURE_EXHAUSTED committed=8192`，空闲关闭与必需通知关闭计数均为零；专用模拟器清理已完成。该轮使用旧转发器，接收缓冲问题的修正从第六轮开始生效。

第五轮通过通知覆盖探测，压力期间空闲关闭为零。只读 TCP 检查发现转发器接收队列超过预设 4096 字节；独立本机探测确认 SO_RCVBUF 在 connect 前为 4096、connect 后变为 326640，连接后重新设置恢复 4096。转发器已补上连接后设置，针对实际转发器套接字的检查确认值为 4096，关闭后 owned sockets 为零。不能将该修正计入第五轮结果。

第四轮已退出 1：暂停前目标账号通知验证通过，但 8192 条预算耗尽仍无背压关闭。运行期间主 Gateway 指标出现 `idle_timeout=1`，TCP 检查只剩监听端口，说明需要排除空闲期限提前关闭的干扰。第五轮仅将隔离 Gateway 空闲期限设为 700 秒，长于 600 秒压力阶段，并记录、比较空闲关闭计数；空闲关闭增加立即判失败。生产空闲期限与通知写入 10 秒期限不变。

前三轮均失败：第一轮 512 条发送预算内未出现目标关闭指标；第二轮隔离数据库与运行配置预算不一致，被 readiness 拒绝；第三轮 8192 条仍无目标关闭指标。第三轮后发现测试未在新账号通知连接上读取目录安装覆盖。第四轮补齐目录读取，并要求暂停前收到探测消息对应的目标房间 head=3 通知。不能用“暂停成功”或“消息提交成功”替代必需通知背压关闭证明。

测试只提高隔离环境的命令预算，生产配置不变。恢复阶段显式编排重连，核对同一本地库的完整正文集合与游标；即使通过，也不能扩大为生产 App 生命周期自动重连证明。


## 2026-09-14 摘要队列与独立完成强杀

`/tmp/imv2-recovery-summary-queue-crash.log`：40 个实际 SIGKILL 参数通过（6.528 秒）。随后 `/tmp/imv2-recovery-finish-crash.log` 退出 0：42 个参数通过（5.399 秒），新增实时正文已落库后的独立待办完成边界。生产代码未因此修改。此前当前页记录存档如下：

强杀专项最新为 17 类事务、34 个实际提交前后参数：`/tmp/imv2-recovery-directory-unavailable-crash.log` 退出 0（6.129 秒）。新增目录重扫验证游标、拓扑及轮次一起重置且待办保留；明确 unavailable 处理验证待办/状态清理与读取权限撤销原子提交，正文游标保持原值。重启后均可继续对应操作。尚不代表全部持久事务及实际后台期限完成。

恢复队列强杀专项已扩展到 15 类事务、30 个提交前后参数，`/tmp/imv2-recovery-queue-crash.log` 退出 0（8.738 秒）。新增入队和重试延期验证目标水位、next_attempt_at、last_served_order 与扫描 service_sequence 的原子提交，重启后退避仍有效且可继续调度，正文游标始终不被队列操作推进。父进程 crashChild 跳过不算额外通过；30 个实际子进程均验证 SIGKILL。该结果仍不覆盖所有持久事务和真实系统后台期限。


当前 Server 全量 `/tmp/imv2-server-full-after-query-optimization-20260914.log` 最终 1084 tests / 156 suites passed，1622.528 秒。成员竞态驱动随后自动进入构建；未重复启动。

## 2026-09-14 扫描创建与替换强杀

`/tmp/imv2-recovery-scan-crash.log` 退出 0，46 个实际 SIGKILL 参数全部通过（6.763 秒）。新增 beginScan / replaceScan，验证扫描首次提交及替换的原子性、既有待办保留、旧 scope 拒绝写入以及重启可继续。账号绑定切换与系统生命周期组合仍不在此项证据范围。

## 2026-09-14 成员竞态第一轮与 ClientKit 全量

第一轮 App 3 passed、0 failed、1 未请求可选项 skipped，实际成员竞态标记通过；驱动因群主新增设备漏计而退出失败，观测 13|3|0|0|3。已仅按成员竞态开关增加一个预期设备，整轮重新执行 `/tmp/imv2-tls-recovery-membership-129-v2-driver.log`。第一次清理完成，不以 App 局部绿色代替整轮终验。

`/tmp/imv2-client-full-46-crash.log` 退出 0：618 tests / 105 suites，64.030 秒，包含 46 个实际 SIGKILL 参数。

## 2026-09-14 成员竞态第二轮与目录分页强杀

第二轮驱动退出 0，App 标记及 HTTP/数据库终验均通过，观察 13|3|0|0|3，清理完成。第一轮历史：

成员竞态第一轮 App 行为通过：真实旧状态响应延迟期间，经另一 Gateway 移除成员、发送缺席消息、重新加入并发送，最终 live、正文/游标和缺席消息不可见检查通过，标记 `IMV2_TLS_ROOM_MEMBERSHIP_RACE_PASSED`。但驱动终验失败：新增群主设备未计入预期，实际 `13|3|0|0|3`；第一轮不能记为整轮通过。已修正专用场景的设备计数，第二轮 `/tmp/imv2-tls-recovery-membership-129-v2-driver.log`、输出 `/tmp/imv2-tls-recovery-membership-129-20260914-02` 正在执行。第一轮服务、数据库与模拟器 F8134D0A-EBFA-472A-A4EB-C6C3144D7743 已清理。

目录分页新增测试初次构建因嵌套 #require 宏展开失败，拆为两个语句后 `/tmp/imv2-recovery-directory-pages-crash-v2.log` 退出 0，50 个 SIGKILL 参数通过（6.403 秒）。emptyDirectory 验证空页续游标及原待办，finalDirectory 验证新房间待办与终页标记原子提交。

## 2026-09-14 目录终页后加入真实链路

第三轮 `/tmp/imv2-tls-recovery-membership-129-v3-driver.log` 退出 0，两个成员场景标记均通过，App 3 passed / 0 failed / 1 可选项 skipped；HTTP/数据库通过，清理完成。新增目录终页已捕获后加入，原终页不包含目标房间；不显式重连、不等待周期核对，最终 live、正文/游标一致且缺席消息不可见。复用既有房间，未扩大为首次未知房间加入覆盖。

当前 ClientKit 全量 `/tmp/imv2-client-full-50-crash.log` 退出 0，618 tests / 105 suites，73.051 秒，包含全部 50 个强杀参数。此前 46 参数全量为 64.030 秒，保留历史范围。

第四轮成员驱动退出 1：已知房间目录加入阶段 connectionClosed，耗时约 120 秒，未知房间阶段未执行。第三轮曾通过不能代表稳定性已证明。第四轮模拟器 E324A13F-5EFE-4DB7-B839-CB757CCEB50F 已删除，驱动正常进入清理。新增诊断后原语义复现，不添加兜底重连。

第五轮诊断复现 connectionClosed：终页、成员加入及 head=10 消息提交标记齐全，恢复未完成，未知房间未执行。专用服务/数据库/模拟器清理完成。第六轮保留原行为，增加状态变化日志。

第六轮因新增诊断在 prepare 前读取 progress 而触发 notStarted，不能作为原故障复现证据。修正诊断：只将未启动状态显示为空，其他错误保留。第七轮 `/tmp/imv2-tls-recovery-membership-129-v7-driver.log` 启动。

第七轮 `/tmp/imv2-tls-recovery-membership-129-v7-driver.log` 退出 0：3 个成员场景标记、HTTP/数据库终验通过，清理完成。已知房间 live/cursor10/authorizedtrue/待办0；首次未知房间 live/cursor4/authorizedtrue/待办0。只增加诊断、未修改生产代码，不宣称第4/5轮故障修复。

第八轮驱动退出 0、HTTP/数据库与三个阶段通过，专用模拟器 C7FAAA1A-0807-489A-87BD-44D3A6C2E5C4 清理完成。为减少诊断扰动，第九轮去除轮询中的额外数据库读，仅在 runner 失败后记录游标、授权和消息现场。不能以第7/8轮成功解释第4/5轮失败。

## 2026-09-14 个人成员加入漏调度修复

第九轮真实驱动退出 0（成功取消任务的 CancellationError 日志不算故障），原间歇性 connectionClosed 尚未归因。独立固定顺序测试 `/tmp/imv2-personal-grant-recovery.log` 退出 1：目录结束后应用个人加入事件，工作数0、完成候选非空，5条断言失败。修复让新的自身成员授予与恢复待办同事务提交，限 live 投影与当前匹配扫描，不对旧成员修订重复入队。`/tmp/imv2-personal-grant-recovery-fixed.log` 退出0，19个持久化测试通过；补充相同批次重放断言后继续全量与真实链路。

修复后 ClientKit 全量 `/tmp/imv2-client-full-personal-grant.log` 退出0：619 tests / 105 suites，58.509秒。新增 personalGrant 强杀首轮 after 参数因跨进程 JSON 对象编码字节顺序不同导致严格重放拒绝，固定测试编码 sortedKeys 后 `/tmp/imv2-personal-grant-crash-v2.log` 退出0：52参数6.709秒。未放宽生产幂等检查。

第十轮 `/tmp/imv2-tls-recovery-membership-129-v10-driver.log` 退出0，修复后三个真实成员场景、HTTP/数据库终验通过，专用模拟器43EFBA68-B7D5-4EB8-A4F0-4971D8B3684C及临时资源清理完成。该证据支持个人授予漏调度修复，不将此前 connectionClosed 自动归因为同一根因。

## 2026-09-14 成员授予边界与 App 当前全量

`/tmp/imv2-personal-grant-boundaries.log` 退出0，20 tests / 1 suite，1.540秒。新增无扫描、旧安装绑定、其他成员事件不创建恢复任务；保留个人流水提交和正文游标。

App 当前完整 IMApp scheme（含 IMAppTests / IMAppUITests）`/tmp/imv2-app-personal-grant-full.xcresult` 摘要240 passed / 0 failed / 1 skipped；动态参数设备执行总计292不作额外测试函数数。专用模拟器 EB498F12-C9CF-4DFF-A821-BFC073A7594A 已清理，驱动退出0。

## 2026-09-14 当前 headless Push 专项

`/tmp/imv2-headless-recovery-grant-driver.log` 退出0；headless-summary.json 确认1 passed / 0 failed / 0 skipped，真实 HTTP/数据库终验通过。当前生产 delegate、Keychain、HTTPS/TLS、SQLite 冷恢复/重放/撤销实际执行；测试直接调用回调，不等同操作系统真实 APNs 投递或后台超时。专用模拟器796220FF-C014-408D-A671-CE2E104F1847和服务/数据库/证书清理完成。

## 2026-09-14 已有任务新目标合并强杀

`/tmp/imv2-recovery-merge-target-crash.log` 退出0：54参数通过，5.857秒。新增 mergeTarget 提交前后目标1/7、原高优先级2、新请求身份及新需求调度时间原子变化；重启接收目标9后旧请求延期不会推迟新请求，正文游标始终0。生产代码未修改。

## 2026-09-14 摘要入队剩余分支强杀

`/tmp/imv2-summary-branches-crash.log` 退出0，58参数5.927秒。ensureFreshSummary 首次无任务分支和 enqueueExistingSummary 已有正文目标分支，在提交前后强杀均保持原子性；重启恢复单个摘要任务，正文目标保留且正文游标0。生产代码未改动。

## 2026-09-14 不关联恢复任务的摘要提交强杀

`/tmp/imv2-summary-independent-crash.log` 退出0，60参数7.786秒。summaryWithoutWork 验证只提交缓存时，提交前后摘要需求都保留，正文游标0；重启后正常关联任务的摘要提交可以完成摘要待办，但仍不推进正文。陈旧摘要拒绝路径无写入，单独分层测试覆盖，不伪造 SIGKILL 提交证据。

## 2026-09-14 独立 PostgreSQL 分片读取故障

`/tmp/imv2-routed-recovery-postgres-fault.log` 退出0，PostgresV2RoutedRecoveryFaultTests 1测试0.765秒。两个独立数据库，固定路由夹具，生产 V2RoutedRoomStateStore + PostgresV2RoomRecoveryStore；第二分片真实查询错误不会隐藏健康状态或返回 unavailable，恢复后重新可读。临时数据库前缀imv2_acceptance_cd63097f2c1a43e3已查询无残留。此项不是App/TLS级故障或物理主机故障证据。

摘要分片故障扩展 `/tmp/imv2-routed-recovery-summary-fault.log` 退出0，1测试0.733秒。真实第二库成员表查询失败时，生产摘要聚合返回retry而非empty snapshot/unavailable；恢复后两个分片snapshot。数据库前缀imv2_acceptance_234aa7d775504f6a查询无残留。路由测试夹具仍固定，未证明迁移竞态。

## 2026-09-14 状态读取归属竞态修复

读取依赖增加与摘要读取一致的内部测试注入入口；原结果语义下 `/tmp/imv2-state-route-race-before.log` moved/state与moved/unavailable两个参数失败。生产状态读取增加读后权威路由复核，变化返回retry；`/tmp/imv2-state-route-race-fixed.log` 四参数通过。生产main.swift的recoveryRouter为V2PostgresRoomShardRouter，非缓存路由。`/tmp/imv2-state-route-postgres-regression.log` 退出0：5测试3套件0.814秒，临时数据库前缀5784d5eb6e674d8b无残留。须继续当前Server全量及真实迁移验收。

## 2026-09-14 有限恢复取消后续跑

有页数上限的恢复取消后续跑已通过：`/tmp/imv2-bounded-recovery-cancel-resume.log`，1 测试、2.434 秒。已提交目录待办后，在下一次目录请求处取消 runner，确认 CancellationError、引擎 idle、正文游标仍为 0、待办仍为 1；新 runner 在 4 页预算内恢复两个房间至游标 5 并清空待办。此测试使用受控传输和真实 SQLite，正文页为空，不等同系统后台期限耗尽或非空消息恢复。

当前 ClientKit 全量 `/tmp/imv2-client-full-cancel-resume.log` 退出 0：621 tests / 105 suites，85.660 秒。文档链接和结构检查均通过，证据为 `/tmp/imv2-cancel-resume-doc-links.log` 与 `/tmp/imv2-cancel-resume-doc-structure.log`。Server 全量会话仍存活，不将未结束执行记为通过。

更正上述 ClientKit 全量覆盖说明：`/tmp/imv2-client-full-cancel-resume.log` 明确显示 killedCommitRecoversAtomically、真实账户和 durableNonemptyRooms 等条件专项跳过；621 是工具报告，不能据此声称强杀或真实服务专项在这一轮执行。此前 60 个强杀参数仅由独立日志证明。本轮显式设置 IMV2_CLIENT_CRASH_BINARY 执行新增快照旧表回收专项，结果待确认。

## 2026-09-14 快照旧表回收强杀

首次 `/tmp/imv2-snapshot-cleanup-crash.log` 退出 1：错误地将 .xctest 目录作为加载二进制，子进程没有正常执行，不能归因为产品缺陷。修正为 Contents/MacOS/IMV2ClientKitPackageTests 后重新执行。

快照旧表回收新增提交前/后 SIGKILL 验证通过：`/tmp/imv2-snapshot-cleanup-crash-v2.log` 退出 0，31 类场景、62 参数，9.960 秒。非空快照先完成激活，再单独在生产清理事务提交边界强杀；重开 SQLite 后，提交前保留旧表、提交后旧表清空，当前消息和已确认游标保持一致，重复清理安全。DDL 不提供普通行变更回调，因此该场景在事务外安装 observer，只观察接下来的清理事务。仍不替代系统后台期限或真实 TLS 快照重置验收。

## 2026-09-14 千房间跨 Gateway 在线补验

1000 房间当前代码双 Gateway/NATS 专项已启动：`/tmp/imv2-tls-recovery-scale-1000-online-driver.log`，输出 `/tmp/imv2-tls-recovery-scale-1000-online-20260914-01`。测试在两轮正文恢复之后等待 runner live，再从第二 Gateway 发送；目标为目录第 129 个房间，不创建详细订阅、不手动补拉，核对消息和正文游标。完整结果及资源清理待确认，不能计作通过。与服务端全量同机并行，因此后续耗时不作为隔离性能结论。

## 2026-09-14 监听安装窗口下一步定位

只读核对：V2GatewayByteStream 的目录响应经 updateHybridGroupSubscription → registry.installAccountRoomDirectory → service.install，等待共享 broker interest.activate 完成；V2AccountRoomChangeService 先登记索引再等待订阅。接下来的验收必须控制实际订阅建立过程中的提交，并在恢复结束核对正文/游标；现有客户端目录响应拦截发生在服务端安装之后，不能替代该窗口。此处只是明确测试切入点，不是已通过证据。

千房间双 Gateway 专项会话仍存活，其 build.log 显示正在等待服务端 .build；持有者 PID 71646 为仍存活的当前全量 swift-test。未重启或修改正在验收的源文件。

## 2026-09-14 当前 Server 全量完成

状态读取归属复核修复后的 Server 全量已退出 0：`/tmp/imv2-server-full-route-revalidation.log`，1086 tests / 158 suites，1552.964 秒。临时数据库前缀 `imv2_acceptance_50566e7e123c438b` 已查询确认无残留。该结果替代修复前 1084 项记录作为当前 Server 全量证据；仍不替代独立 App/TLS 迁移等尚未完成场景。

千房间双 Gateway/NATS 专项会话 4235 保持存活，服务端构建目录释放后已自动开始编译，未重复启动。

## 2026-09-14 千房间在线第一轮结果

千房间跨 Gateway 第一轮已终态退出 1：`/tmp/imv2-tls-recovery-scale-1000-online-driver.log`。App 2 passed / 1 failed / 1 skipped；失败为 testGatewayDeviceRevocationReturnsToLoginAndSurvivesRelaunch 的首次注册 networkFailure，根因未明。房间专项本身通过：首轮 97.908226625 秒、重连 2.549822916 秒；第 129 个房间在线与跨 Gateway 标记均通过，刷新 0 次，第二轮无正文请求。整轮 HTTP/数据库终验未执行，不能计为全部通过。专用模拟器 9749B403-1F6B-4275-AFFF-8A39B1593427 已由驱动删除。

## 2026-09-14 千房间在线第二轮完成

千房间双 Gateway/NATS 第二轮整轮通过：`/tmp/imv2-tls-recovery-scale-1000-online-v2-driver.log` 退出 0，输出 `/tmp/imv2-tls-recovery-scale-1000-online-20260914-02`。App 3 passed / 0 failed / 1 未请求可选项 skipped；HTTP/数据库终验通过，专用模拟器 BE43C962-8E48-40F1-83E1-D1BFA78C79A8 已删除。首轮正文恢复 97.834473 秒、重连 2.294513625 秒，第二轮无正文请求；目录第 129 房间跨 Gateway 在线更新通过，无详细订阅或手动补拉。首轮注册 networkFailure 未复现但仍未归因，不用这次成功抹去失败历史。

## 2026-09-14 千房间资源复核

千房间资源与流量复核：`/tmp/imv2-recovery-1000-online-summary.json` 由现有汇总工具从通过的 App 结果生成。主 Gateway / 测试宿主各 99 样本、约 104.426 秒，峰值 RSS 分别 44,433,408 B（42.375 MiB）和 292,814,848 B（279.25 MiB），采样错误 0。首轮逻辑发送/接收 156,328 / 756,663 B，正文请求 1080 次含重试；第二轮 43,048 / 141,183 B，无正文请求。两轮均无连接内重连。采样不包含第二 Gateway、NATS、PostgreSQL 或模拟器系统，逻辑字节不包含 TLS 和异步通知，不能当作整机资源上界或网卡流量。

## 2026-09-14 网关安装期间通知交错

网关字节流安装交错专项通过：`/tmp/imv2-gateway-install-window.log` 退出 0，1 测试、2 参数、0.009 秒。新增参数暂停末页首个 broker interest.activate，确认仅前 100 个房间完成安装；暂停期间向目录第 129 个房间投递变化，收到正确 epoch/sequence/room 的通知，再释放安装并完成目录响应和关闭清理。使用生产 byte stream/registry/account service，受控 broker 与状态读取夹具；不包含真实 NATS、PostgreSQL 提交或客户端正文收敛，不能替代完整安装窗口验收。生产代码未修改；Server 全量 1086 项记录早于这一测试参数新增。

## 2026-09-14 目录响应安装屏障

安装响应顺序补强通过：`/tmp/imv2-gateway-install-response-fence.log` 退出 0，2 参数、0.009 秒。直接记录 byte stream 的目录响应回调，在安装暂停及通知到达之后都断言尚未收到目录响应，释放后断言收到。此项补足上一版仅间接观察安装状态的证据，夹具范围不变；真实 NATS/数据库/App 组合仍未验收。

## 2026-09-14 真实 NATS 安装返回窗口

真实 NATS 安装返回窗口已通过：`/tmp/imv2-real-nats-install-window.log` 退出 0，2 测试/1 套件，0.179 秒；其中 realNATSInstallationWindow 实际执行 0.169 秒。第 129 个房间的真实 broker 订阅确认后，在兴趣安装返回前设置屏障；经真实 broker 发布 wake，生产 registry/service/byte stream 收到通知，目录响应仍未发出，释放后正常完成。独立 NATS PID 7795 已正常退出，日志 `/tmp/imv2-real-nats-install-broker.log` 确认 Server Exiting。状态/目录读取仍为夹具，不包含 PostgreSQL 消息提交、真实 App/TLS 或订阅确认之前的丢失窗口；这些要求仍未完成。

## 2026-09-14 PostgreSQL 与真实 NATS 安装返回窗口

真实 PostgreSQL + NATS 安装返回窗口专项通过：`/tmp/imv2-postgres-nats-install.log` 退出 0，1 测试、0.587 秒。生产 PostgresV2RoomRecoveryStore 读取实际成员和房间水位；真实订阅确认后暂停兴趣安装返回，提交 PostgreSQL room_sequence=8，再通过真实 NATS 发布，生产 service 在安装返回前生成 epoch/sequence/room/head 正确的 changed 通知。临时数据库前缀 imv2_acceptance_d4b0fda86db8479f 已查询无残留；NATS PID 13538 正常退出。此测试直接更新水位元数据，不插入消息正文，也不走 App/TLS，不能作为完整消息提交、客户端游标/正文一致性或订阅确认前窗口的证明。

## 2026-09-14 真实消息安装窗口初次结果

`/tmp/imv2-postgres-nats-message-install.log` 退出 1：原水位测试通过，新增真实消息场景在恢复初始状态读取时报 invalidState。复用的 seedRoom 写入夹具将 rooms.membership_revision 与成员 joined_revision 设为 0，与恢复模型要求非零成员修订不符。仅在新场景将初始修订设为 1，未放宽生产校验；再次执行 `/tmp/imv2-postgres-nats-message-install-v2.log`，结果待确认。首次数据库前缀 imv2_acceptance_0df1b206bd294d7d 已查询无残留。

## 2026-09-14 真实消息写入与 NATS 安装窗口通过

真实消息写入安装窗口复测通过：`/tmp/imv2-postgres-nats-message-install-v2.log` 退出 0，2 测试/2 套件、1.459 秒；真实发送场景 0.901 秒。安装返回被暂停期间，生产 V2SendMessageService/PostgresV2RoomWriteStore 接受消息，SQL 核对正文及序号；随后显式经真实 NATS 发布 wake，生产状态读取与通知返回相同水位。修订为 1 的新夹具通过，生产校验未变。临时数据库前缀 imv2_acceptance_1994c804a7a541ff 已查询无残留，独立 broker 正常退出。发布仍由测试显式编排，未走生产发送后通知调度；尚不证明 App/TLS 正文恢复或订阅确认之前提交的窗口。

## 2026-09-14 relay 场景路径修正

`/tmp/imv2-postgres-nats-relay-install.log` 退出 1：标准群场景没有预期的 relay 发布，随后通知等待超时。源码 schema 明确只有 capacity_class=large 才进入 group_event_wake_outbox，先前把该 relay 当作所有房间的发送后通知路径是错误判断，不能归为生产缺陷。测试调整为 standard/large 两参数；标准群保持已验证的显式发布，大群使用生产持久化 relay，并核对 claimed/published/retryScheduled 与发件箱清理。新日志 `/tmp/imv2-postgres-nats-relay-install-v2.log` 待确认。失败轮数据库前缀 imv2_acceptance_2e80183743b34e97 已查询无残留。

## 2026-09-14 大群生产 relay 安装窗口通过

标准/大群安装窗口联合复测通过：`/tmp/imv2-postgres-nats-relay-install-v2.log` 退出 0，2 测试/2 套件，2.337 秒。真实消息测试包含 standard/large 两参数；大群实际通过 PostgresV2GroupEventWakeStore + V2GroupEventWakeRelay 认领和发布，断言 claimed=1、published=1、retryScheduled=0 且发件箱清空，再确认安装暂停期间收到正确水位通知。标准群仍使用显式 NATS 发布，不扩大为标准群生产通知调度证明。数据库前缀 imv2_acceptance_c5856ca86e334ed2 已查询无残留，独立 NATS 正常退出。真实 App/TLS 与订阅确认之前提交的窗口仍未完成。

## 2026-09-14 标准群 dispatcher 与大群 relay 联合通过

标准群生产通知路径联合专项通过：`/tmp/imv2-postgres-nats-dispatch-install.log` 退出 0，2 测试/2 套件，2.294 秒。standard 参数改为实际协议命令 → V2GatewayDomainCommandHandler → 真实发送/SQL 正文核对 → V2ForegroundGroupEventHintDispatcher → 真实 NATS → 生产状态读取与通知；不再手动发布标准群 wake。large 参数继续走生产持久化 relay 并核对待办清除。安装屏障均设在真实订阅确认后、安装返回前；尚不包含订阅确认之前的提交、App/TLS 和客户端正文收敛。数据库前缀 imv2_acceptance_c22a89d69efe4fc8 已查询无残留，独立 NATS 正常退出。

## 2026-09-14 大群订阅前提交与正文补拉

大群订阅前提交窗口专项通过：`/tmp/imv2-postgres-nats-before-subscribe.log` 退出 0，2 测试/2 套件、3.091 秒；真实消息测试包含 standard-after / large-after / large-before 三参数。large-before 在真正 broker.activate 之前暂停，真实消息写入与持久化 relay 发布确认先完成；断言无通知，随后完成订阅，生产状态读取和 PostgresV2GroupEventLogStore 补拉取得同一水位、单条事件及 installation-body 正文，仍无通知。临时数据库前缀 imv2_acceptance_c05f1dbe316b44da 已查询无残留，独立 NATS 正常退出。此项是服务端真实 DB/NATS + 显式权威读取，不包含 App/TLS、客户端 SQLite 提交或标准群订阅前窗口。

## 2026-09-14 普通群与大群订阅前后四窗口通过

普通群/大群订阅前后四窗口联合专项通过：`/tmp/imv2-postgres-nats-all-install-windows.log` 退出 0，2 测试/2 套件、3.929 秒，真实消息测试四参数通过。标准群订阅前场景等待生产 dispatcher 完成真实 NATS 发布，再通过同一连接的独立房间确认消息建立顺序屏障；大群走生产持久化 relay。订阅前发布未收到通知，完成订阅后通过生产状态读取和事件补拉取得正确水位与单条 installation-body 正文；订阅后、安装返回前发布收到正确通知。临时数据库前缀 imv2_acceptance_c1d92e4ea9f94737 已查询无残留，独立 NATS PID 28109 正常退出。此项覆盖服务端真实数据库和 broker，不包含 App/TLS 或客户端 SQLite 收敛；Server 全量 1086 项早于这些测试新增。

## 2026-09-14 安装窗口新增后的服务端全量

已启动 `/tmp/imv2-server-full-install-windows.log`，包含三个独立 PostgreSQL 数据库、真实 NATS URL 和独立端口的 broker 重启专项；数据库前缀 imv2_acceptance_0f584a537ca64707。终态待确认，运行中不改动服务端源码或测试。验收表同步更正 ClientKit 621 项、独立 62 个强杀参数和此前 Server 1086 项的版本边界，未将条件跳过算为通过。

## 2026-09-14 App 自动重连验收入口核对

源码核对：V2AppStore.startRealtimeIfApplicationActive 在 runtime.waitUntilStopped 后按 1–30 秒退避再次 start；停止前台任务时取消 gate 和任务并 await runtime.stop。现有 V2AppStoreTests 只验证启动代际 gate，不能证明网络断开后的实际自动恢复。IMAppRoomRecoverySlowTLSTests.verifySlowTLS 在代理恢复后显式 disconnect/connect 并新建 V2RoomRecoveryRunner，因此此前慢 TLS 通过只证明显式恢复。第 9 项需要以真实 App 的 V2AppStore 前台任务作为被测入口，在断开代理后不调用 connect/start、不切换 scene，等待消息正文与游标恢复，并核对旧连接退出；不能仅把现有 helper 的显式恢复改名为自动恢复。当前没有据此宣布生产自动重连缺陷或完成；服务端全量仍独立运行。

## 2026-09-14 自动重连断线夹具

测试代理增加 disconnect_current 和仅在拥有该代理时可用的 /__fixture__/tls-disconnect 控制：关闭现有代理 socket、释放读取暂停，保留监听入口接收后续连接。没有增加生产 HTTP 路由，也不在夹具中调用客户端 connect/start。代理专项 unittest 2 项通过（0.682 秒）：新增场景确认暂停中的旧连接 EOF、转发线程退出、socket 清空及新连接可正常收发；既有真实 TLS 握手后暂停/恢复与完整载荷校验仍通过。驱动 Python 语法解析通过。此处只验证故障注入基础设施，真实 App 自动重连尚待接入和执行。

## 2026-09-14 真实 App 自动重连专项启动

新增 --room-recovery-app-reconnect 独立故障选项，复用独立代理与第二 Gateway。场景使用随机 scope 登录真实 App，在聊天页连续三次由代理关闭连接，再由第二 Gateway 发送唯一正文；等待真实 App 显示正文，期间不刷新、不切换 scene，也不调用接收侧 connect/start。测试终验要求三次断线操作及成功标记，结束清理 scoped Keychain/SQLite。驱动语法及参数入口检查通过；实际执行 `/tmp/imv2-app-auto-reconnect-driver.log`（输出目录 `/tmp/imv2-app-auto-reconnect-20260914-01`）已启动，尚无终态。该场景即使通过也仅证明前台聊天页自动恢复，不直接证明所有后台期限、所有房间游标或完整资源上界。

## 2026-09-14 安装与自动重连验收文档门禁

本轮文档链接及废弃引用合同检查退出 0，日志 `/tmp/imv2-install-reconnect-document-links.log`；文档结构检查退出 0，日志 `/tmp/imv2-install-reconnect-document-structure.log`。检查针对当前文档，不扩大为正在执行的服务端全量或待运行 App 自动重连已通过。

## 2026-09-14 当前服务端 1089 项全量通过

安装窗口新增后的服务端全量已退出 0：`/tmp/imv2-server-full-install-windows.log`，1089 测试/159 套件、1410.597 秒。真实 PostgreSQL、NATS 订阅安装与 broker 重启专项实际执行，无 skipped 记录。临时数据库前缀 imv2_acceptance_0f584a537ca64707 已查询无残留，独立 NATS PID 30289 正常退出。该结果覆盖当前服务端源码及新增安装测试；真实 App 自动重连专项已开始搭建环境，尚无终态，不能并入此通过结论。

## 2026-09-14 App 自动重连首次编译失败

`/tmp/imv2-app-auto-reconnect-driver.log` 终态退出 1；App 测试未执行，Swift 6 报 sending self risks causing data races，位于非隔离测试向 @MainActor 实例辅助方法的调用。将该方法改为 static，使用 Self 调用，不跨隔离传递 XCTest 实例；未放宽并发检查。驱动报告已停止测试服务及 PostgreSQL 并尝试移除专用模拟器。复测 `/tmp/imv2-app-auto-reconnect-v2-driver.log`、输出 `/tmp/imv2-app-auto-reconnect-20260914-02` 已启动，结果待确认。

## 2026-09-14 App 自动重连第二轮目标群聊未出现

`/tmp/imv2-app-auto-reconnect-v2-driver.log` 退出 1，App 2 passed / 1 failed / 1 optional skipped。静态方法修正后编译通过；129 房间基础恢复通过，新增真实 App 阶段等待目标群聊 60 秒后抛 unexpectedResponse，尚未执行代理断线。现有失败无可导出的页面附件，不能推断为自动重连缺陷。新增辅助方法 catch 在 scoped App 清理前保存截图和控件层级，保持原判定和等待期限，下一轮用于定位登录、数据或元素定位边界。

## 2026-09-14 App 第三轮页面诊断

第三轮 `/tmp/imv2-app-auto-reconnect-v3-driver.log` 退出 1，再次未进入断线阶段。导出全部 xcresult 附件（仅导出 failures 不含嵌套诊断活动附件）取得清理前控件树 `/tmp/imv2-app-reconnect-v3-all-attachments/2CA786DB-E718-4617-A6A1-4BABEB348F03.txt`：App 已登录，列表显示预置正文，但可见行均为 v2.conversation.unknown 且标题为“会话”；测试请求的目标 group 行不存在于可见层级。V2ConversationDataSource 仅在 roomProfile 存在时映射 group。需要继续核对 SQL 预置与个人资料恢复来源，不能改成 unknown 定位后宣称群资料恢复完成。真实自动重连仍未执行。

## 2026-09-14 规模夹具缺失群发现记录

源码核对 PostgresV2GroupMessagingStore：生产建群将 room.created 资料写入所有初始成员的 user_state_event_outbox；规模 SQL 原先只写房间、成员和 message.accepted。因此规模恢复绿色不包含真实 App 群资料发现。仅自动重连场景为预置房间补齐个人 room 资料发件箱，沿生产 worker/用户流恢复到 App；保留原消息数量和 roomSequence 断言，未直接写客户端投影或把 UI 断言放宽为 unknown。该数据仍是规模预置，不冒充通过生产建群 API 的证据。第四轮待实际确认。

## 2026-09-14 群资料夹具修正后的第四轮

`/tmp/imv2-app-auto-reconnect-v4-driver.log` 退出 1，仍在等待目标群聊时失败、未断线。页面附件 `/tmp/imv2-app-reconnect-v4-attachments/86429E3F-80BB-42CE-B6FC-11723FBAD23D.txt` 显示可见行已为 group，标题 Recovery scale，确认补齐个人资料事件后资料可达真实 App。目录末尾目标 room 不在当前可见层级；仍需核对列表分页/滚动和初始消息排序。不能据此扩大为自动重连失败或通过。

## 2026-09-14 目标群聊的列表窗口定位

第四轮控件层级明确包含 load-earlier 和 return-to-latest，当前视窗保留旧锚点，不能把目标未出现在可见层级当作消息未同步。测试初始化改为在 60 秒期限内通过已有“回到最新会话”入口定位目标，成功打开并核对初始正文后才开始注入断线；三次故障阶段仍不刷新、导航或调用接收侧重连。第五轮 `/tmp/imv2-app-auto-reconnect-v5-driver.log`（输出 `/tmp/imv2-app-auto-reconnect-20260914-05`）已启动，结果待确认。

## 2026-09-14 App 第五轮进入真实断线阶段

`/tmp/imv2-app-auto-reconnect-v5-driver.log` 退出 1。初始化回到最新列表后成功进入目标群聊；前三次 tls-disconnect 均记录于 tls-relay-events.json，前两次唯一正文已进入 UI 控件树，第三次等待 90 秒未找到。失败附件 `/tmp/imv2-app-reconnect-v5-attachments/D8060445-2E3E-4065-95D7-4C8AFC0D1547.txt` 显示第二条正文 y=874.7，已排到屏幕下方；第三条是否已落库尚缺证据，不能归因为网络恢复失败，也不能放宽为两轮通过。需核对视窗跟随和独立 SQLite 正文/游标证据。

## 2026-09-14 自动恢复与懒加载可见性区分

源码 V2ConversationDetailView 的 ScrollView/LazyVStack 只在 focusedMessageID 存在时程序滚动；普通滚动没有网络请求/刷新回调，历史与返回最新操作为独立按钮。第五轮仅靠 staticTexts.exists 将视窗外未实例化正文混入网络判断。测试仍在每轮真实断线后保留 90 秒截止和唯一正文断言，只增加普通向上滚动以实例化本地行；不点击 load-older/return-latest，不调用接收侧 connect/start 或补拉。第六轮 `/tmp/imv2-app-auto-reconnect-v6-driver.log`（输出 `/tmp/imv2-app-auto-reconnect-20260914-06`）已启动。此项证明范围为自动网络恢复后正文可读，不证明聊天页自动跟随滚动或独立 SQLite 游标审计。

## 2026-09-14 App 第六轮终态

第六轮 `/tmp/imv2-app-auto-reconnect-v6-driver.log` 终态退出 1：App 测试显示 TEST SUCCEEDED，但驱动最终数据库数量断言失败，实际为 13|3|0|0|3。因此不能计为整轮通过；需后续核对新增 scoped App 登录对预期设备数量的影响及实际副作用。驱动已结束，原测试服务按 cleanup.log 清理。未继续修改判定或重跑。
