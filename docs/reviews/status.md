# IM V2 当前设计与实现问题总表

> **这是判断"哪些问题还开着"的唯一文档。**
> 逐批追加的验证过程已移出到 [历史时间线](archive/2026-09-05-remediation-timeline.md)；
> 某个主题当前生效的设计合同见 [合同索引](README.md)。
>
> **状态列已于 2026-09-10 对当前代码逐条复核，基准 HEAD `f591e2ed`。**
> 复核方式：对每一项沿原始触发点回到当前实现，确认缺陷条件是否仍成立，并记录
> 当前代码中的实现位置；同时在本次会话实测 Core 117 项／39 套件与 ClientKit
> 543 项／93 套件通过。**未重跑** Server package（需 Docker 与双 PostgreSQL）、
> App 单元与 UI 测试，因此标记为"已验证"表示代码已实现且仓库内存在对应验证记录，
> 不表示本轮重新执行了全部套件；"已实现待验证"表示代码存在但关闭条件需要真实
> 设备、网络或系统生命周期证据。

审查日期：2026-09-05；运行接线复核更新：2026-09-07。范围：IMApp、ClientKit、Core、Server、协议、PostgreSQL schema、部署与运维证据。

**结论：分层与持久化方向可以保留，但同步恢复、认证生命周期、审批一致性和跨 owner 执行尚未闭环，当前证据不足以宣称生产就绪。**

这是对既有 47 项审查结果的当前状态复核，不是新增 47 个现存缺陷，也不宣称穷尽所有潜在问题。原始 29 项实现问题为 10 P1 / 17 P2 / 2 P3；另有 8 项设计风险和 10 项外部发布缺口。表中优先级保留原始分类，已修复项不再当作现存故障。

状态在 2026-09-10 按当前代码重写：每行给出复核结论、当前实现位置与尚未满足的关闭条件。此前的逐批证据记录仍在[验证运行记录索引](verification-records.md)中，但状态判定不再依赖它们。

## 架构判断

- **模块边界基本合理。** SwiftUI App 负责交互，ClientKit 负责认证/SQLite/outbox，Core 保存领域规则，Gateway/Account 提供传输入口，PostgreSQL 保存权威提交。无需因为发现问题而整体重写。
- **可靠性取决于事件组合。** ACK、outbox 和持久游标是基础，但 accepted 与 mutation 分流后，消费者必须处理重复、乱序和缺基线；B03/B06 表明这一合同仍不统一。
- **授权应随内容版本绑定。** 当前成员身份不能证明能看到历史消息或某次编辑。B04 已补这一边界，但跨库授权凭证、交付结果、保留与迁移必须形成完整协议。
- **异步任务必须有唯一所有者和恢复步骤。** generation 能隔离迟到 UI 结果，却不能撤销已经发生的远端 PUT/DELETE。Push、退出和文件擦除要以持久用户意图驱动。
- **优化路径增加一致性成本。** planner/preplanned/room_log/hybrid 应共享授权、幂等结果和投影不变量；单条路径通过不代表模式组合正确。
- **运行入口与组件能力要分别验收。** 当前 PostgreSQL schema 为 30，协议为 27；Gateway 已配置跨库 export 入队和投递运行时，pending/paused 映射为可重试错误；真实双库路由与运行时恢复已通过最终回归。operator 暂停恢复已增加独立入口、审计事务与 owner 栅栏并通过最终双库组合回归；媒体 HTTP 已按消息 owner 路由，个人投影走 user store、设备检查留控制库，provider 返回后再次授权；owner 迁移、终态保留和生产媒体部署仍需闭环。

## 状态汇总

37 项代码与设计问题（B01–B29、D01–D08）在 2026-09-10 的复核结果：

| 状态 | 数量 | 含义 |
| --- | --- | --- |
| 已验证 | 18 | 原缺陷在当前代码中不再成立，且仓库内有对应验证记录 |
| 已实现待验证 | 7 | 代码已落地，关闭条件需要真实设备、网络或系统生命周期证据 |
| 实施中 | 9 | 原缺陷的主要路径已修，仍有关闭条件未满足 |
| 待外部验收 | 2 | 代码完成，只差归档或人工验收 |
| 未开始 | 1 | 尚无实现 |

相比 2026-09-07 的记录：已验证 16 → 18，已实现待验证 1 → 7，实施中 14 → 9，未开始 14 → 1。
另有 10 项外部发布缺口（E01–E10）与代码问题分开计数，当前全部未关闭。

## 完整问题表

| ID | 原优先级 | 问题/风险 | 当前状态 | 当前判断与关闭要求 |
| --- | --- | --- | --- | --- |
| B01 | P1 | 幂等比较可因 revision 整数越界终止 Gateway | 实施中 | 三个原始崩溃点（编辑、成员变更、撤回）已在幂等重放前判定时间戳可编码；新增 `V2PostgresTimestampBounds` 与 `V2ServerClockBoundaryTests`，其他存储改用 `Int64(exactly:)`。剩余：恢复 DTO、计数与递增入口尚未逐条清点。 |
| B02 | P1 | 编辑旧消息绕过当前群写入权限 | 已验证 | 发送与编辑现共用 `v2AuthorizeContentWrite`（房间冻结、角色权限、禁言），`PostgresV2RoomWriteStore` 与 `PostgresV2MessageEditStore` 同源；24 个真实 PostgreSQL 提交顺序场景与 91 项回归通过。剩余：全局账号/设备与 owner 完整迁移按其他条目跟踪。 |
| B03 | P1 | room-log 消息的 mutation 缺少原始消息投影，阻塞恢复 | 实施中 | 变更分发改由 `message_send_completions` 的不可变接受记录决定；新 personal 变更按 VisibleAtAccepted ∩ MemberAtMutation 取受众，room pull 在分页前按当前/事件/接受三个成员区间过滤。剩余：旧积压缺基线恢复、独立内容撤销、完整快照。 |
| B04 | P1 | 转发源缺少消息提交时的成员可见性检查 | 实施中 | `v2ForwardSourceVisibility` 统一要求当前与历史成员区间并校验正文修订成员资格，被转发、导出、媒体、群能力与写库共用。剩余：完整 owner 迁移承接与终态 envelope 清理。 |
| B05 | P1 | 密码长度规则与 bcrypt 实际输入不一致 | 已验证 | 改为 Argon2id v19 完整 UTF-8 输入，拒绝 NUL、不截断，固定 worker 预算；认证成功后再用事务复核完整 PHC。剩余：生产可信恢复与 Linux 容量按 E 类跟踪。 |
| B06 | P1 | 同一编辑/撤回经两条事件流到达时不幂等 | 实施中 | 客户端 `v2_message_effects` 以 (source_event_id, projection_kind, entity_key) 加 canonical_digest 去重；服务端快照按源版本排序并保留空状态与取消负状态。剩余：逐成员离开/重入、完整保留窗口与代次栅栏。 |
| B07 | P1 | outbox 记录了重试时间，却没有到时唤醒任务 | 已实现待验证 | App runtime 已注入 `commandRetrySchedule`（13 条 lane）并在每轮前执行 `expireStalePendingCommands`；持久 nextAttemptAt 唤醒与真实 SQLite／网络组合已验证。剩余：真实设备后台与挂起恢复。 |
| B08 | P1 | 认证失效后退出流程依赖已删除的凭据 | 实施中 | 退出先写持久 pending 标记再完成本地退出，独立撤销队列在删除凭据前保存操作；签发取消与旧档案清理已接通。剩余：真机强杀/锁屏/系统后台、legacy 记录 GC。 |
| B09 | P1 | 刷新凭据的终止错误未映射成重新登录 | 已验证 | 业务 HTTP 统一接入认证代次与刷新判定，Gateway 的认证拒绝不再退化为裸 EOF。部署类证据按 E 类跟踪。 |
| B10 | P1 | 邀请预览与实际提交 token 可指向不同群 | 已验证 | 预览与 secret 绑定为同一 ready 状态，token 变化先撤销旧提交能力，joinGeneration 丢弃迟到结果。 |
| B11 | P2 | 编辑/撤回后重放原 SendMessage 被误判冲突 | 已实现待验证 | 发送指纹随接受结果持久化，重放按不可变指纹比较而不是当前正文。剩余：指纹记录 GC、owner 迁移与写放大。 |
| B12 | P2 | 房间追赶的一轮预算耗尽后不继续 | 已验证 | 房间追赶改由 `V2RoomLogCatchUpWorker` 驱动，剩余工作会请求下一轮而不是被丢弃。 |
| B13 | P2 | 并发 flush 同时取到同一 pending 命令 | 已验证 | 各 outbox 共用 `V2CommandFlushFlight` actor 单飞，终态结果幂等提交。 |
| B14 | P2 | 取消单个请求会把迟到响应升级为整条 TLS 失败 | 已验证 | `cancelRequest` 保留 cancelledOnWire 关联项（continuation 置空但不删除），迟到响应被匹配后清理，不再升级为整条连接失败。 |
| B15 | P2 | 擦除主 SQLite 时遗漏保存正文的独立搜索库 | 已实现待验证 | 新增 `V2AccountStorageScope` 统一主库、搜索库及两者 WAL／SHM，删除前显式关闭 pool。剩余：真实冷启动与旧媒体目录闭环。 |
| B16 | P2 | Push 关闭后，迟到的注册仍可重建远端端点 | 已实现待验证 | 服务端 `push_device_intents` 版本条件写（intent_revision／digest 加 FOR UPDATE），客户端持久意图、单飞 reconciler 与 App 开关/退出接线均已存在。剩余：真实网络、账号切换与退出组合。 |
| B17 | P2 | 连接恢复后，仍打开的会话不重建实时订阅 | 已验证 | runtime 持有房间订阅意图，连接代次变化后重订阅并清理旧任务。 |
| B18 | P2 | 800 条滑动窗口使更旧搜索命中无法定位 | 已验证 | 改为在同一 SQLite 快照内按目标主键与共同排序定位，取消 800 条数量增长循环。 |
| B19 | P2 | 搜索连续加载可重复追加同一页 | 已验证 | 搜索分页增加 `paginationOperation` 单飞、命中去重与 cursor 停滞检测。 |
| B20 | P2 | 搜索索引建好后页面仍停在 indexing | 已验证 | `observeIndexState` 订阅索引状态流，ready 时自动重跑搜索，仅 building 显示 indexing。 |
| B21 | P2 | 实时刷新把已加载会话/联系人分页重置为第一页 | 已验证 | 列表改为窗口化并配 `V2ListViewport` 读门，实时刷新不再重置到第一页。 |
| B22 | P2 | 文件时间戳 API 缺少 App 隐私清单声明 | 待外部验收 | `PrivacyInfo.xcprivacy` 已声明 FileTimestamp (C617.1) 与 UserDefaults。剩余：归档合并报告核对。 |
| B23 | P2 | 跨邀请并发申请可突破每人 20 条待审上限 | 实施中 | submit 先按 applicant 取 advisory lock，再在同一事务内重新统计 pending/approving。剩余：跨 owner 全局预留与终态释放。 |
| B24 | P2 | 待审批游标随着审批状态变化而失效 | 已验证 | 待审批游标改为绑定 (created_at, request_id) 不可变排序键，不再要求锚点仍处于 pending。 |
| B25 | P2 | 已耗尽链接不展示，却继续占满活跃链接额度 | 已验证 | 活跃链接计数条件改为与列表一致：state=active 且未耗尽且未过期。 |
| B26 | P2 | 审批冲突重试后未持久化实际 membership revision | 已验证 | approve 改为单事务完成成员、配额、事件与记账；旧 approving 一律返回 conflict，交 operator 按确切操作恢复，不再按申请人当前成员身份结算。 |
| B27 | P2 | 新增邀请链路没有按群所属数据库路由 | 实施中 | Account 已组装 `V2RoutedGroupInvitationStore` 与 room shard router，成员与回执在事务内校验 route/epoch，目录导入与历史绑定已接通。剩余：完整 owner 历史迁移。 |
| B28 | P3 | VoiceOver 筛选值朗读内部 UUID | 待外部验收 | 筛选值改为 `senderFilterDisplayName`，不再向 VoiceOver 朗读内部 UUID。剩余：真机人工无障碍验收。 |
| B29 | P3 | 当前协议版本文档已漂移 | 已验证 | 协议号由生成物与文档门禁共同校验，当前统一为 27。 |
| D01 | P2 | 旧 TLS reader 的迟到失败可能关闭新连接 | 已验证 | 连接引入 generation，`requireGeneration` 阻止旧 reader 回调影响新连接。 |
| D02 | P2 | Push handler 依赖页面出现，无 scene 冷启动不能恢复会话 | 已实现待验证 | 新增 `V2AppLaunchConfiguration` 与 `V2AppStore.launched(...)`，delegate 可在任何 scene 之前构造 store，共享恢复带截止时间。剩余：真机无 scene 与锁屏。 |
| D03 | P2 | 后台 Push 跑完整 runtime，缺总时间预算 | 已实现待验证 | `V2BackgroundSyncRunner` 默认 4 页／25 秒预算，后台唤醒不再运行完整前台 runtime。剩余：真实 Push 与系统期限。 |
| D04 | P2 | 媒体文件和缩略图缺账号/安装级生命周期 | 已实现待验证 | 媒体缓存移入 `V2AccountStorageScope.mediaCacheDirectory`，并有孤立临时文件清理与缓存策略维护。剩余：真实冷启动与跨账号验收。 |
| D05 | P2 | 原审批人失去权限后，孤立 approving 无接管路径 | 已验证 | 孤立 approving 由独立 operator 入口按确切操作与完整成员历史恢复，审计与旧操作阻断在同一事务。 |
| D06 | P2 | 待审申请缺少申请人取消或清理机制 | 未开始 | 仍无申请人取消入口，schema 无 cancelled 状态；待审申请只能等处理或链接到期。 |
| D07 | P2 | 不同消息路径重复实现授权、准入和投影规则 | 实施中 | 已提取共用的内容写入授权与转发来源可见性；planner／preplanned／room_log／hybrid 在集成套件中均有覆盖。剩余：万行级 RoomWriteStore 与模式合同矩阵仍未收敛。 |
| D08 | P2 | 关键状态机的组合测试不足，能力证据描述过宽 | 实施中 | 新增真实 PostgreSQL 集成套件（`PostgresV2RoomWriteStoreIntegrationTests`，需 IMV2_POSTGRES_TEST_DATABASE_URL）及邀请、审批、路由测试。剩余：把每项能力声明逐条绑定到具体用例，并补跨流／认证终止／冷启动组合。 |
| E01 | 发布验收 | 生产部署、密钥、证书与 operator 入口 | 未开始 | 生产拓扑、密钥管理/轮换、TLS、operator 权限及回滚需真实环境验收。 |
| E02 | 发布验收 | 生产 Passkey / WebAuthn | 未开始 | 生产 WebAuthn verifier/challenge/counter 与真实注册登录证据未闭环。 |
| E03 | 发布验收 | 生产媒体存储、扫描和 CDN | 未开始 | 本地文件/EICAR 适配器不是生产存储与扫描验收；需对象存储/CDN、扫描失败与保留策略验证。 |
| E04 | 发布验收 | 真机、多端、无障碍和签名 | 未开始 | 签名归档、真机多端、Keychain 锁屏/重启、相机与无障碍证据未闭环。 |
| E05 | 发布验收 | 真实 APNs | 未开始 | 真实 APNs 凭据/profile、失效 token、后台冷启动与用户开关组合未闭环。 |
| E06 | 发布验收 | NATS 生产安全和可观测性 | 未开始 | NATS 安全、指标和分区/重连长稳未闭环；需证明提示丢失后持久游标仍能恢复。 |
| E07 | 发布验收 | WAL/PITR、RPO/RTO 和灾备 | 未开始 | 逻辑备份不代表 WAL/PITR；需时间点恢复、密钥恢复、故障切换和 RPO/RTO 演练。 |
| E08 | 发布验收 | 远端 CI / 干净 checkout 证据 | 未开始 | 当前工作区有大量未提交变更；缺与最终代码一致的干净 checkout/远端统一门禁证据。本次未查询账户额度。 |
| E09 | 发布验收 | 完整混合负载、长期运行与多 Gateway/分片容量 | 未开始 | 容量数字只适用于原 workload；需同一 binary 的混合消息、热点、多设备、多 Gateway/owner 与长期故障验证。 |
| E10 | 发布验收 | ARM64 Linux 压力下历史 SIGSEGV 根因未关闭 | 未开始 | 历史 ARM64 Linux SIGSEGV 仍缺符号化根因；一次未复现不能关闭，需原始 core 与同版本长稳。 |

## 本次复核的直接代码证据

以下行号对应本次工作区，不沿用原始审查时的旧行号。

| 事项 | 当前证据 | 结论 |
| --- | --- | --- |
| B03/B06 缺基线/重复变更 | [GRDBV2LocalSyncStore.swift](../../IMV2ClientKit/Sources/IMV2ClientKit/GRDBV2LocalSyncStore.swift) 与 V2LocalMessageEffect 共用消息效果记录 | 重复消息效果与旧编辑已有处理；新完整编辑可建立合法基线并跨版本，旧文本 delta 的缺基线/缺版本仍拒绝，旧积压需 B03 持久恢复；reaction 已有顺序与负状态，其他对象未统一 |
| B04 跨库主路径 | [V2RoutedForwardMessagesService.swift](../../IMV2Server/Sources/IMV2Server/V2RoutedForwardMessagesService.swift) 已配置跨 owner service；[Gateway 组装](../../IMV2Server/Sources/IMV2ServerApp/main.swift) 使用该 router 并启动、取消和排空投递运行时 | 真实双库 router/runtime 已验证；主程序编译通过，尚未启动真实 Gateway/App 做端到端验收 |
| B04 媒体导入 | [V2ForwardMediaImportWorker.swift](../../IMV2Server/Sources/IMV2Server/V2ForwardMediaImportWorker.swift)、[PostgresV2ForwardMediaImportStore.swift](../../IMV2Server/Sources/IMV2Server/PostgresV2ForwardMediaImportStore.swift)、[本地复制器](../../IMV2Server/Sources/IMV2Server/V2LocalFilesystemForwardMediaCopier.swift) | 有复制、扫描、lease、重试及 fencing 实现；后续批已重新验证 13 种媒体场景，见持久日志 |
| B04 媒体下载 | [V2RoutedMediaDownloadService.swift](../../IMV2Server/Sources/IMV2Server/V2RoutedMediaDownloadService.swift) 与 Account room/user registry | schema 17；消息 owner、用户投影和控制库设备分别授权；15 个下载场景与实际转发附件读回通过，仍需生产媒体和 owner 清理验收 |
| B04 保留释放 | [PostgresV2ForwardExportStore.swift](../../IMV2Server/Sources/IMV2Server/PostgresV2ForwardExportStore.swift)、[PostgresV2MediaRetentionStore.swift](../../IMV2Server/Sources/IMV2Server/PostgresV2MediaRetentionStore.swift) | export 配额与源媒体 pin 必须配套终态回执/释放，不能只增加不可变记录 |
| B05 密码边界 | [V2PasswordHashWorker.swift](../../IMV2Server/Sources/IMV2Server/V2PasswordHashWorker.swift) 与 [V2PasswordAccountStore.swift](../../IMV2Server/Sources/IMV2Server/V2PasswordAccountStore.swift) | 完整输入 Argon2id、有界 worker、旧记录限制及认证后事务复核已验证；修复前 HTTP 反例 9 issues 与最终 39 项回归分别留证 |
| B16 Push 竞态 | [V2PushWakeSettings.swift](../../IMApp/IMApp/V2/V2PushWakeSettings.swift)、[V2PushIntentReconciler.swift](../../IMV2ClientKit/Sources/IMV2ClientKit/V2PushIntentReconciler.swift) 及服务端版本条件写 | 旧 register/remove 链路已替换；持久最终意图、单飞和版本拒绝已分层验证，真实网络与 App 账号生命周期组合仍待验收 |
| B18 历史定位 | [V2ConversationDetailStore.swift](../../IMApp/IMApp/V2/V2ConversationDetailStore.swift) 的 loadTimeline 与 SQLite conversationTimelineWindow | 数量增长循环已删除；直接按消息和活动共同排序定位，800 条保留上限不再阻断导航；真实 SwiftUI 滚动已验证 |
| B23 配额 | [PostgresV2GroupInvitationStore.swift](../../IMV2Server/Sources/IMV2Server/PostgresV2GroupInvitationStore.swift) 的 submit | 单库已改为 applicant 事务锁，等待后重新计数；各 owner 仍须共同使用 control 的唯一配额预留 |
| B26 审批恢复 | [PostgresV2GroupInvitationStore.swift](../../IMV2Server/Sources/IMV2Server/PostgresV2GroupInvitationStore.swift) 的 approve | 新请求单事务提交；旧 approving 通过独立 operator 按确切操作和完整历史证据恢复，审计及旧操作阻断同事务 |
| B27 owner 路由 | [Account 主入口](../../IMV2Server/Sources/IMV2AccountServerApp/main.swift) 的 groupInvitations 组装 | 已组装 V2RoutedGroupInvitationStore；持久 route/epoch、control 身份及 token 目录已接入 |

## 修复顺序与验收要求

1. **优先关闭仍然开着的代码问题：B01、B03、B04、B06、B08、B23、B27、D06、D07、D08。** 其中 B03/B04/B06 必须按同一份合同矩阵收口：一个事实重复到达不得回滚同步，缺基线恢复不得泄漏入群前历史。
2. **把"已实现待验证"推到已验证：B07、B11、B15、B16、D02、D03、D04。** 这些只差真实设备、真实网络或系统生命周期证据，验收时要观察磁盘与远端状态，不能只断言界面。
3. **完成两项外部验收：B22 归档隐私清单合并报告、B28 真机 VoiceOver。**
4. **完成发布证据：E01–E10。** 用同一最终版本验证各投递模式和实际环境，记录测试范围与未覆盖项，避免用历史容量数字外推当前部署。

本轮复核实际完成：对 37 项沿原始触发点逐一回到当前实现核对，本次会话实测 Core 117 项／39 套件与 ClientKit 543 项／93 套件通过，并运行文档链接与结构门禁。**未重跑** Server package（需 Docker 与双 PostgreSQL）、App 单元与 UI 测试、真实 HTTPS/APNs，未修改业务源码，未部署。

详细原始触发条件、影响、历史实验和建议见 [原始审查](archive/2026-09-05-system-design-implementation-audit.md)；逐批实现与证据见 [修复进度](archive/2026-09-05-system-remediation-progress.md)；执行依赖见 [修复方案](archive/2026-09-05-system-remediation-plan.md)。原始审查的代码行号对应审查基准，不保证与已修改文件一致。
