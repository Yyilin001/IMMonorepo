# IM V2 当前设计与实现问题总表

> **这是判断"哪些问题还开着"的唯一文档。**
> 逐批追加的验证过程已移出到 [历史时间线](archive/2026-09-05-remediation-timeline.md)；
> 某个主题当前生效的设计合同见 [合同索引](README.md)。
>
> **清单校正：2026-09-20；核对对象为 HEAD `90d93711` 加当前未提交工作区。**
> 本次核对清单、当前实现入口、schema/协议生成物及后续专题验收记录；不是一次新的全量代码审计。
> “已验证”沿用原问题已有的修复证据，不表示本次重新运行了业务测试，也不代表整个相关功能已完成。
> 后续验收的通过、失败、跳过及版本范围分别保留；没有完整关闭证据的项目继续开放。

原始审查日期：2026-09-05。范围：IMApp、ClientKit、Core、Server、协议、PostgreSQL schema、部署与运维证据。

**结论：公共内容统一房间日志的改造已完成；客户端会话恢复整体验收、认证生命周期、跨 owner 一致性和生产发布仍有缺口。**

保留原有 47 个编号：29 项实现问题（10 P1 / 17 P2 / 2 P3）、8 项设计风险和 10 项外部发布缺口。
问题编号保留用于追溯；B 类优先级统计保留原始分类，D07 已根据实际断连故障升为 P1。当前是否仍成立、剩余范围以最后一列为准。
已修复的历史触发条件不再当作现存故障，也不因原问题关闭而推断新恢复链路全部通过。

当前公共事件只走房间日志，个人流保存个人状态与单侧提示；以全新数据库和新版客户端为基线。
旧扇出积压、旧投递模式兼容和旧 schema 升级不再作为本次目标的关闭条件；
当前版本自身的重启、快照、裁剪、用户/房间归属迁移仍须验证。
房间日志改造与会话恢复是两个不同范围，分别见[已完成的改造记录](room-log-only-implementation.md)和[仍开放的恢复验收矩阵](client-owned-conversation-sync-acceptance.md)。

## 收敛审计（2026-09-20）

用户提出代码增长及过度设计问题后，当前执行顺序调整为先审计范围和复杂度，不继续扩展跨库生命周期探针或迁移执行器。此调整不删除已知风险、不把未实现能力标为已完成，也不修改既有关闭数量。

### 代码增长的实际口径

本次审计基线为 HEAD `90d93711`，统计已跟踪文件相对 HEAD 的差异，加上未跟踪文本文件；不含被忽略的构建产物。它覆盖整个工作区，不能全部归因于当前任务或当前服务端阶段。快照明细位于 `/tmp/imv2-convergence-line-audit-20260920.json`；下表是此次文档更新前的数字。

| 类别 | 新增行 | 删除行 | 净变化 |
| --- | ---: | ---: | ---: |
| 手写 Sources（全项目） | 12,105 | 17,252 | -5,147 |
| 测试 | 28,937 | 20,432 | +8,505 |
| 文档 | 6,540 | 1,037 | +5,503 |
| 生成代码 | 2,586 | 504 | +2,082 |
| 脚本 | 1,805 | 221 | +1,584 |
| SQL | 485 | 3,210 | -2,725 |
| 其他 | 491 | 288 | +203 |
| 合计 | 52,949 | 42,944 | +10,005 |

其中手写服务端 Sources 新增 8,592、删除 14,575，净减少 5,983 行；服务端测试净增 2,029 行。不能把“新增约 5 万行”描述为“净增加 5 万行业务实现”，也不能以净减少证明架构已经足够简单。

### 已确认的收敛点

- **测试维护成本：** `PostgresV2RoomWriteStoreIntegrationTests.swift` 现有 34,976 行，最近局部修改的编译耗时约 211–217 秒。后续应复用公共夹具并按职责拆分，避免继续在该文件添加巨型参数矩阵；拆文件本身不算业务缺陷关闭。
- **B27 范围扩大：** 原条目是邀请按房间归属路由，完整在线迁移属于更大的能力。当前 Sources 中迁移准备存储仅在其定义文件内部引用，没有 Gateway/Operator/HTTP 调用入口。是否需要首版在线搬迁尚缺业务依据；建议将完整迁移独立列为可延后能力，待范围明确后再调整验收。现阶段不删除保护既有写入的栅栏，也不声称迁移完成。
- **B11 范围扩大：** 原条目是编辑/撤回后的发送重放误报冲突，当前已改用不可变接受事实。安全 GC 需要另外的旧操作拒绝边界；永久保留记录与实现 GC 是不同策略。建议单列容量/保留决策，不为关闭原缺陷默认新增协议代次或复杂清理状态机；禁止直接删除幂等记录。
- **D07 收尾方式：** 持久授权解决的是已复现的跨库断连后迟到写入，应保留。剩余工作须逐项对应现存生产路径和不变量，不把所有未来迁移能力或任意故障组合自动作为此条目的关闭条件。已有同库真实 Gateway 生命周期证据；跨库扩展尚未实施。
- **发布条件：** E 类属于上线验收，客户端暂缓项也仍留在历史总数中。后续分别展示缺陷关闭、扩展能力和发布准备，避免用一个百分比混淆三者。拆分前保留原统计，不能通过移动条目制造完成率提升。

## 当前执行范围（2026-09-20）

按用户最新要求，后续修复只处理服务端。项目尚未上线，直接以当前协议、当前 schema 和全新数据库为基线，不新增历史版本兼容或旧数据升级路径。
客户端优化及客户端专项实现/验收暂不推进；原有未关闭记录保留，不视为已经完成，也不因调整范围改写关闭数量。
服务端优先继续核对整数与持久化边界、消息授权/幂等/准入一致性、转发与媒体终态清理，以及房间 owner 迁移的完整状态承接。验证围绕实际改动选择专项，不因局部变更运行全仓测试。

本轮优先处理 B01、B04、B11、B27、D07 的服务端剩余范围；B03、B06、B08、D08 只推进其中服务端可独立完成的部分。B07、B15、B16、B22、B28、D02–D04 的当前客户端/设备剩余验收暂缓。发布项中 E01–E03、E06–E10 继续作为服务端上线前条件，E04–E05 的真机与真实推送验收暂缓。

当前按原问题编号计算，代码/设计关闭率为 20/37（约 54%），含发布项为 20/47（约 43%）。这是问题关闭率，不是功能开发完成度；部分编号混合服务端与客户端要求，尚无独立服务端分母，不据此声称“服务端完成 54%”。

### 本轮未关闭项速览

| 本轮范围 | 数量 | 编号 | 剩余工作 |
| --- | --- | --- | --- |
| 服务端主要实现与审计 | 5 | B01、B04、B11、B27、D07 | 整数边界完整映射；转发/媒体故障与保留；幂等记录生命周期；完整房间迁移；持久授权的完整进程故障与迁移验收 |
| 混合条目中的服务端部分 | 4 | B03、B06、B08、D08 | 恢复与快照/裁剪、成员权限与迁移、凭据撤销记录保留、跨组件故障及同版验证；各编号的客户端要求继续保留 |
| 服务端发布验收 | 8 | E01–E03、E06–E10 | 生产部署与认证、媒体服务、NATS、安全恢复与灾备、同版 CI、容量长稳、Linux 崩溃根因 |
| 暂缓的客户端/设备剩余项 | 10 | B07、B15、B16、B22、B28、D02–D04、E04–E05 | 不纳入本轮执行，不计作关闭 |

本轮涉及 17 个仍开放编号（9 个代码/设计、8 个发布验收），不是“服务端总共只有 17 项”，也不能用原清单的 20 个已关闭项作为服务端完成率的分子。当前优先阻断是 D07 的进程级故障与迁移验证；B27 仍只到 freezing，未完成复制、路由发布与接管。


## 架构判断

- **模块边界基本合理。** SwiftUI App 负责交互，ClientKit 负责认证/SQLite/outbox，Core 保存领域规则，Gateway/Account 提供传输入口，PostgreSQL 保存权威提交。无需因为发现问题而整体重写。
- **公共内容已统一。** 旧 planner/preplanned/fanout/hybrid 投递分支已移除，单聊和两类群使用房间日志。仍需验证实时事件、恢复页、快照及权限撤销的组合，不能沿用旧多模式矩阵作为待办。
- **授权应随内容版本绑定。** 当前成员身份不能证明能看到历史消息或某次编辑。B04 已补源可见性检查，跨库转发的保留和迁移仍需闭环。
- **恢复工作已持久化。** `V2RoomRecoveryRunner` / `V2RoomRecoveryEngine` 管理目录、通知和恢复待办；自身成员授予与待办同事务提交，撤销时清理房间投影。B03/B06/D08 的剩余范围见下表。
- **异步任务必须有唯一所有者和恢复步骤。** Push、退出和文件擦除仍需以持久用户意图驱动；模拟器成功不能替代真机锁屏和系统后台期限证据。
- **组件通过与整轮通过分开计。** 当前 PostgreSQL 为 `im-v2-current-49`，协议为 30；源码/生成物可直接核对。会话恢复已有真实双 Gateway、PostgreSQL/NATS 和 App/TLS 分层记录，前台自动重连驱动漏计设备已修，三次断线、App 和数据库终验整轮通过；这不关闭剩余后台、迁移及多设备组合。

## 状态汇总

37 项代码与设计问题（B01–B29、D01–D08）的当前清单分类：

| 状态 | 数量 | 含义 |
| --- | --- | --- |
| 已验证 | 20 | 原缺陷在当前代码中不再成立，且仓库内有对应验证记录 |
| 已实现待验证 | 6 | 已有实现，尚需真实设备、网络或系统生命周期证据 |
| 实施中 | 9 | 主要路径已有修复，仍有实现、范围审计或组合验收缺口 |
| 待外部验收 | 2 | 代码完成，只差归档或人工验收 |
| 未开始 | 0 | 尚无实现 |

代码与设计项已关闭 20 项、开放 17 项；外部发布缺口 E01–E10 另计，全部未关闭，合计开放 27 项。
B11 改为“实施中”：指纹记录保留/GC 与 owner 迁移仍有缺口，不能描述为只差验证。
D06 已按申请人取消的完整功能范围关闭；原审批与客户端隔离回归同轮通过，生产发布仍由 E 类跟踪。
E 类“未开始”表示尚无对应生产发布验收的关闭证据，不否定已有本机准备和测试。

## 完整问题表

| ID | 原优先级 | 问题/风险 | 当前状态 | 当前判断与关闭要求 |
| --- | --- | --- | --- | --- |
| B01 | P1 | 幂等比较可因 revision 整数越界终止 Gateway | 实施中 | 已补 Core/响应边界、服务端计数与配置、客户端命令/搜索/投影、已识别快照及恢复入口保护；各批次范围与证据集中见[逐入口核对](message-projection-integer-boundaries.md)。恢复待办读取/合并/重试已有时间校验；最新进度检查同时校验重试时间最小/最大值，发现被到期筛选或正常行掩盖的异常时间，59 项恢复专项通过，见[证据](verification-records.md#20260920-recovery-progress-dates)。前台/后台遇错停止及修复后重启的 4 场景、24 项运行器回归通过，见[生命周期验证](verification-records.md#20260920-recovery-invalid-date-runner)。剩余：其他普通表/派生查询及跨文件转换、计数、递增、恢复入口的完整映射；未被选中待办的其他字段与查询前排序仍需核对，本机专项不代替真机容量或全范围关闭。 |
| B02 | P1 | 编辑旧消息绕过当前群写入权限 | 已验证 | 发送与编辑现共用 `v2AuthorizeContentWrite`（房间冻结、角色权限、禁言），`PostgresV2RoomWriteStore` 与 `PostgresV2MessageEditStore` 同源；24 个真实 PostgreSQL 提交顺序场景与 91 项回归通过。剩余：全局账号/设备与 owner 完整迁移按其他条目跟踪。 |
| B03 | P1 | room-log 消息的 mutation 缺少原始消息投影，阻塞恢复 | 实施中 | 公共 accepted 与 mutation 已统一进入房间日志；持久恢复、通知补拉和自身成员授予已有实现。已补恢复结果的资格/个人流代次栅栏，最新目录页也绑定扫描轮次、代次及游标，65 项回归、真实快照七入口专项及 8 个目录 SIGKILL 参数通过，见[目录复验](verification-records.md#20260920-directory-flight-fence)与[成员/代次合同](member-role-snapshot-contract.md)。旧 personal 公共积压不属支持范围。剩余：快照重置、裁剪、首次安装与实际实时投递并发，以及跨分片/权限变化的完整恢复验收，见[恢复矩阵](client-owned-conversation-sync-acceptance.md)。 |
| B04 | P1 | 转发源缺少消息提交时的成员可见性检查 | 实施中 | `v2ForwardSourceVisibility` 统一要求当前与历史成员区间并校验正文修订成员资格，被转发、导出、媒体、群能力与写库共用。跨库已提交终态新增身份/源修订/摘要预查，命中后无需解码完整载荷；终态回执改为 ID/摘要/结果，目标生成与源端记录不再读正文，26 个双库场景通过；目标 receive/status 与导入终态重放也已解除存量正文依赖，未完成任务继续读取和校验正文；源端 prepareForDelivery 同一 SQL 快照选择回执或载荷，已覆盖预查后回执提交的窗口；schema 40 独立保存目标归属，operator 媒体重放不再读正文，缺字段启动拒绝与重放专项通过；schema 41/42 已接入目标 inbox 与源 export 终态正文的有界清理，身份/摘要/结果保留；源清理要求投递完成和匹配回执，双端实际清理/回滚/并发重放专项通过；本地媒体复制完成后成功/拒绝、清理及迟到回调组合通过。已修复本地文件删除后迟到上传/转发重新落盘，持久删除标记与对象锁专项通过。本地文件三个、清理事务提交前后八个真实 SIGKILL 与新进程恢复已通过。18 组 SQL 成本测量发现并修复源端小批清理扫描历史回执，1 万条记录下按候选主键查询；本机测量不替代生产容量。真实导入工作器复制前/回执返回前与媒体过期及清除的两种交错通过，18 场景回归保持终态和删除栅栏。本地提供方并发初始化会重复清理暂存目录的问题已复现并修复，32 并发初始化和失败重试专项通过。完整媒体投递运行器的回执丢失、目标正文清理及注入不可达重试组合通过，19 场景保持原结果和附件。剩余：跨进程运行器强杀、生产复制/存储故障、长期保留/生产容量及完整 owner 迁移承接；[载荷清理边界](forward-terminal-payload-retention.md)列出未完成的 schema、读者和并发栅栏。 |
| B05 | P1 | 密码长度规则与 bcrypt 实际输入不一致 | 已验证 | 改为 Argon2id v19 完整 UTF-8 输入，拒绝 NUL、不截断，固定 worker 预算；认证成功后再用事务复核完整 PHC。剩余：生产可信恢复与 Linux 容量按 E 类跟踪。 |
| B06 | P1 | 同一编辑/撤回经两条事件流到达时不幂等 | 实施中 | 已修复旧正文响应借用重入后新状态授权的缺口：正文提交绑定请求捕获的成员资格与 owner，64 项恢复回归通过，见[正文资格栅栏](verification-records.md#20260920-recovery-body-authorization-fence)。消息效果去重及本人资格恢复已有实现；反应快照已修复新旧状态分离复制导致移除复活/新状态丢失，按房间序号合并并重建可见反应，同源冲突回滚、撤回抑制及重开重放共 11 个新增场景通过，143 项同步/成员回归通过，见[反应快照证据](verification-records.md#20260919-reaction-snapshot-order)；已修复较新本人状态导致其他成员历史移除被跳过、角色残留的问题，目标角色按自身修订删除；UUID统一、房间/序号校验及逐成员 add/remove/role 来源摘要持久化已补齐，快照合并、重开与冲突回滚专项通过；App 名录失效清理和刷新期间迟到响应已修。成员名录已按 owner/控制库拆分读取，归属与资格复核、受控三库裁剪/重入专项通过。剩余：首次安装/裁剪 App 整链、运行中完整 owner 迁移、本人重入代次组合与来源记录保留/容量，见[成员合同](member-role-snapshot-contract.md)。 |
| B07 | P1 | outbox 记录了重试时间，却没有到时唤醒任务 | 已实现待验证 | App runtime 已注入 `commandRetrySchedule`（13 条 lane）并在每轮前执行 `expireStalePendingCommands`；持久 nextAttemptAt 唤醒与真实 SQLite／网络组合已验证。剩余：真实设备后台与挂起恢复。 |
| B08 | P1 | 认证失效后退出流程依赖已删除的凭据 | 实施中 | 退出持久标记、独立撤销队列、签发取消及旧档案清理已接通；已有真实 HTTPS、Keychain 和受控 App 进程中断恢复记录。剩余：真机强杀/锁屏/系统后台、退出/换号全部检查点、冲突与记录保留/GC；后续一般登录成功不替代这些组合验收。 |
| B09 | P1 | 刷新凭据的终止错误未映射成重新登录 | 已验证 | 业务 HTTP 统一接入认证代次与刷新判定，Gateway 的认证拒绝不再退化为裸 EOF。部署类证据按 E 类跟踪。 |
| B10 | P1 | 邀请预览与实际提交 token 可指向不同群 | 已验证 | 预览与 secret 绑定为同一 ready 状态，token 变化先撤销旧提交能力，joinGeneration 丢弃迟到结果。 |
| B11 | P2 | 编辑/撤回后重放原 SendMessage 被误判冲突 | 实施中 | 发送重放按不可变接受指纹比较，当前普通发送/转发统一 v3 指纹，已移除旧 targetRule；修改/撤回/清理正文后重试有回归记录；超过 35 天运行真实维护后重放与改参冲突专项通过。同库转发绑定曾被通用清理删除，导致迟到重试重复发送；现已移出过期清理，见[复现与回归](verification-records.md#20260920-forward-operation-retention)。剩余：完成记录的保留/GC 与重试窗口、owner 迁移承接及写入成本证据；当前没有旧发送的服务端过期拒绝边界，来源授权也依赖接受成员修订，35 天不能直接作为删除期限，见[保留合同](send-completion-retention.md)。不以恢复旧指纹版本为关闭条件。 |
| B12 | P2 | 房间追赶的一轮预算耗尽后不继续 | 已验证 | 原单轮预算耗尽后丢弃剩余工作的触发点已修；当前由 V2RoomRecoveryRunner/Engine 和持久待办接替已删除的 V2RoomLogCatchUpWorker，前台继续调度，后台有界运行留待下次恢复。受控取消续跑已有 SQLite 记录；系统后台期限仍由 D03 跟踪。 |
| B13 | P2 | 并发 flush 同时取到同一 pending 命令 | 已验证 | 各 outbox 共用 `V2CommandFlushFlight` actor 单飞，终态结果幂等提交。 |
| B14 | P2 | 取消单个请求会把迟到响应升级为整条 TLS 失败 | 已验证 | `cancelRequest` 保留 cancelledOnWire 关联项（continuation 置空但不删除），迟到响应被匹配后清理，不再升级为整条连接失败。 |
| B15 | P2 | 擦除主 SQLite 时遗漏保存正文的独立搜索库 | 已实现待验证 | 新增 `V2AccountStorageScope` 统一主库、搜索库及两者 WAL／SHM，删除前显式关闭 pool。剩余：真实冷启动与旧媒体目录闭环。 |
| B16 | P2 | Push 关闭后，迟到的注册仍可重建远端端点 | 已实现待验证 | 服务端 `push_device_intents` 版本条件写（intent_revision／digest 加 FOR UPDATE），客户端持久意图、单飞 reconciler 与 App 开关/退出接线均已存在。剩余：真实网络、账号切换与退出组合。 |
| B17 | P2 | 连接恢复后，仍打开的会话不重建实时订阅 | 已验证 | runtime 持有详细房间订阅意图，连接代次变化后重新安装并清理旧任务。账号级目录覆盖与新恢复链路的生产 App 自动重连验收仍由 D08 跟踪，不用原订阅修复结论代替。 |
| B18 | P2 | 800 条滑动窗口使更旧搜索命中无法定位 | 已验证 | 改为在同一 SQLite 快照内按目标主键与共同排序定位，取消 800 条数量增长循环。 |
| B19 | P2 | 搜索连续加载可重复追加同一页 | 已验证 | 搜索分页增加 `paginationOperation` 单飞、命中去重与 cursor 停滞检测。 |
| B20 | P2 | 搜索索引建好后页面仍停在 indexing | 已验证 | `observeIndexState` 订阅索引状态流，ready 时自动重跑搜索，仅 building 显示 indexing。 |
| B21 | P2 | 实时刷新把已加载会话/联系人分页重置为第一页 | 已验证 | 列表改为窗口化并配 `V2ListViewport` 读门，实时刷新不再重置到第一页。 |
| B22 | P2 | 文件时间戳 API 缺少 App 隐私清单声明 | 待外部验收 | `PrivacyInfo.xcprivacy` 已声明 FileTimestamp (C617.1) 与 UserDefaults。剩余：归档合并报告核对。 |
| B23 | P2 | 跨邀请并发申请可突破每人 20 条待审上限 | 已验证 | schema 39 已接入 control 全局预留、重复操作绑定、owner 原子回执与 Account 有界后台恢复。真实双 owner 40 次提交只接受 20 条；旧操作取消重放、全部终态释放、6 个 SIGKILL 检查点及 operator 恢复/归属失败专项通过，见[合同](group-join-global-quota-contract.md)与[证据](verification-records.md#20260919-group-join-global-quota)。完整房间迁移仍按 B27 跟踪，生产容量按 E 类验收。 |
| B24 | P2 | 待审批游标随着审批状态变化而失效 | 已验证 | 待审批游标改为绑定 (created_at, request_id) 不可变排序键，不再要求锚点仍处于 pending。 |
| B25 | P2 | 已耗尽链接不展示，却继续占满活跃链接额度 | 已验证 | 活跃链接计数条件改为与列表一致：state=active 且未耗尽且未过期。 |
| B26 | P2 | 审批冲突重试后未持久化实际 membership revision | 已验证 | approve 改为单事务完成成员、配额、事件与记账；旧 approving 一律返回 conflict，交 operator 按确切操作恢复，不再按申请人当前成员身份结算。 |
| B27 | P2 | 新增邀请链路没有按群所属数据库路由 | 实施中 | Account 邀请路由、持久 route/epoch、control 身份、token 目录与创建恢复已接通。房间迁移已实现准备/读取/安全取消、冻结意图与持久源端标记；发送、回执、成员变更、邀请存储、同库/跨库转发、媒体数据库回写、后台投递、运维重放、转发正文压缩、房间日志、直接归属的操作回执、审核审计清理及审核任务数据库回写、内容处置、审核运维恢复及特殊账号操作/审计后处理及房间额度持久预扣已加入相应屏障，见[迁移合同与各批证据](room-owner-migration-contract.md)、[正文清理](verification-records.md#20260920-room-migration-compaction-fence)、[日志裁剪](verification-records.md#20260920-room-migration-log-retention-fence)、[操作回执清理](verification-records.md#20260920-room-migration-housekeeping-fence)。剩余：其他写入/清理入口完整覆盖、在途 I/O 排空与承接、有界复制及校验、路由发布、任务接管、运行入口与故障恢复。个人事件队列已按显式来源房间保护认领/确认/重试及运维重放/过期清理，见[维护证据](verification-records.md#20260920-user-event-maintenance-fence)。房间唤醒的认领、确认删除与重试也已接入屏障，见[唤醒证据](verification-records.md#20260920-room-wake-migration-fence)。复用私聊房间新增操作回执也已在房间锁下拒绝冻结，见[私聊复用证据](verification-records.md#20260920-direct-open-migration-fence)。当前任务仍只到 freezing，不代表完整冻结或搬迁完成；原有用户分片迁移执行器不能替代房间迁移。 |
| B28 | P3 | VoiceOver 筛选值朗读内部 UUID | 待外部验收 | 筛选值改为 `senderFilterDisplayName`，不再向 VoiceOver 朗读内部 UUID。剩余：真机人工无障碍验收。 |
| B29 | P3 | 当前协议版本文档已漂移 | 已验证 | 当前协议源文件与 Server/ClientKit 生成物均为 30；本表旧值 27 已校正。协议文档门禁核对 implementation-status，尚不自动覆盖所有专题文档中的历史版本叙述。 |
| D01 | P2 | 旧 TLS reader 的迟到失败可能关闭新连接 | 已验证 | 连接引入 generation，`requireGeneration` 阻止旧 reader 回调影响新连接。 |
| D02 | P2 | Push handler 依赖页面出现，无 scene 冷启动不能恢复会话 | 已实现待验证 | App delegate 可在 scene 之前构造 store 并恢复会话；后续 headless 专项已有真实 Keychain、HTTPS/TLS/SQLite 和设备撤销整轮通过记录。剩余：系统实际 APNs 无 scene 冷启动、真机锁屏；直接调用 delegate 不等同系统投递。 |
| D03 | P2 | 后台 Push 跑完整 runtime，缺总时间预算 | 已实现待验证 | 后台同步有页数/时间预算，并接入 V2RoomRecoveryRunner.runBounded；受控取消后重新执行可恢复持久待办。剩余：真实 APNs、系统期限耗尽与非空多房间后台收敛；空正文页的取消续跑不替代这些证据。 |
| D04 | P2 | 媒体文件和缩略图缺账号/安装级生命周期 | 已实现待验证 | 媒体缓存移入 `V2AccountStorageScope.mediaCacheDirectory`，并有孤立临时文件清理与缓存策略维护。剩余：真实冷启动与跨账号验收。 |
| D05 | P2 | 原审批人失去权限后，孤立 approving 无接管路径 | 已验证 | 孤立 approving 由独立 operator 入口按确切操作与完整成员历史恢复，审计与旧操作阻断在同一事务。 |
| D06 | P2 | 待审申请缺少申请人取消或清理机制 | 已验证 | 申请人取消已贯通 owner 事务、HTTPS、ClientKit 和 App。cancelled 释放本 owner 待审配额，旧提交/取消重放保持终态，新操作可重新申请；到期/撤销后仍可取消原 pending。真实 PostgreSQL 审批竞态、跨库路由/epoch、HTTP 和 App 隔离专项通过，见[取消合同](group-join-cancellation-contract.md)与[证据](verification-records.md#20260919-group-join-cancellation)。跨 owner 全局配额仍按 B23 跟踪。 |
| D07 | P1 | 不同消息路径重复实现授权、准入和投影规则 | 实施中 | 普通、原子批量和转发入口现统一先提交持久控制授权，再在 owner 消息事务中校验代次并写入不可变回执；转发在媒体就绪后才登记，旧 withControlPolicies 应用回调已移除。Gateway/Operator 已接独立处理池、撤权协调器及 Gateway 有界恢复；确认失败保留授权，不归还已消耗额度。原普通发送断连故障已在冷/预热下修复并复验，20 个受影响场景通过，见[自动发送证据](verification-records.md#20260920-direct-automatic-authorization)。转发新增 14 个无附件/真实附件场景通过，加上相关 25 个回归，覆盖媒体等待、权限拒绝、准入、收尾/确认失败、正文清理后补确认及既有迁移边界，见[自动转发证据](verification-records.md#20260920-forward-automatic-authorization)。历史断连失败见[原复现](verification-records.md#20260920-direct-control-connection-loss)，当前协议与运行边界见[持久授权合同](room-owner-migration-contract.md)。当前应用权限写者已按六张控制表核对：四类撤权入口均排空授权，展示资料不改权限，特殊账号表没有在线应用写者。转发控制后端断开与真实并发拉黑已补冷/预热两场景，并与普通发送两场景同轮通过，见[写者清点与转发断连证据](verification-records.md#20260920-forward-control-connection-loss)。普通、批量、转发在登记前、登记后、owner 提交后、确认后四个时点的真实 SIGKILL 与新进程恢复共 12 场景通过，见[进程恢复证据](verification-records.md#20260920-direct-authorization-process-crash)。准入等待后撤权先完成、旧授权迟到及新代次拒绝的两个场景已通过，见[撤权证据](verification-records.md#20260920-forward-revocation-first)。预检后媒体状态/有效期变化的两个精确窗口通过，见[媒体窗口证据](verification-records.md#20260920-forward-media-window)。实际 Gateway 后台启动恢复、强杀重启及在途正常停机已通过本机同库探针，见[生命周期证据](verification-records.md#20260920-authorization-gateway-lifecycle)。剩余：前台网络发送与跨库部署的进程故障矩阵、其他在途撤权/媒体维护竞争、完整迁移承接；管理员直接 SQL 和外部特殊账号配置不在当前应用接口证据内；继续核对发送/转发/编辑/管理路径的授权、幂等及准入一致性，收敛大型写入存储。旧多模式矩阵不再是待办；局部接线与专项通过不关闭整个 D07。 |
| D08 | P2 | 关键状态机的组合测试不足，能力证据描述过宽 | 实施中 | 服务端清理轮转已改为持久事务轮次，解除固定调度周期与时钟的耦合；时钟不变/每分钟/10分钟/每小时、并发清理和失败回滚专项通过，schema 43 建库/恢复及启动检查通过，见[持久轮转证据](verification-records.md#20260920-housekeeping-durable-rotation)。启动检查与执行入口的有效轮次上界已统一，越界拒绝和合法边界恢复通过，见[边界补验](verification-records.md#20260920-housekeeping-readiness-bound)。已有0/50/129/1000/10000房间恢复、双 Gateway 在线、真实 NATS 安装窗口和62个提交前后强杀参数记录。剩余：前台自动重连整轮失败已由漏计设备修复及严格终验闭环；仍需间歇性网络失败归因、跨组件迁移/分片故障/多设备/后台期限及所有最后改动后的统一门禁，见[恢复矩阵](client-owned-conversation-sync-acceptance.md)。 |
| E01 | 发布验收 | 生产部署、密钥、证书与 operator 入口 | 未开始 | 生产拓扑、密钥管理/轮换、TLS、operator 权限及回滚需真实环境验收。 |
| E02 | 发布验收 | 生产 Passkey / WebAuthn | 未开始 | 生产 WebAuthn verifier/challenge/counter 与真实注册登录证据未闭环。 |
| E03 | 发布验收 | 生产媒体存储、扫描和 CDN | 未开始 | 本地文件/EICAR 适配器不是生产存储与扫描验收；需对象存储/CDN、扫描失败与保留策略验证。 |
| E04 | 发布验收 | 真机、多端、无障碍和签名 | 未开始 | 签名归档、真机多端、Keychain 锁屏/重启、相机与无障碍证据未闭环。 |
| E05 | 发布验收 | 真实 APNs | 未开始 | 真实 APNs 凭据/profile、失效 token、后台冷启动与用户开关组合未闭环。 |
| E06 | 发布验收 | NATS 生产安全和可观测性 | 未开始 | 本机真实 NATS 安装窗口、broker 重启及提示丢失后恢复已有记录。仍缺生产 TLS/NKey、指标、分区/重连长稳与部署验收；局部故障恢复通过不关闭本项。 |
| E07 | 发布验收 | WAL/PITR、RPO/RTO 和灾备 | 未开始 | 逻辑备份不代表 WAL/PITR；需时间点恢复、密钥恢复、故障切换和 RPO/RTO 演练。 |
| E08 | 发布验收 | 远端 CI / 干净 checkout 证据 | 未开始 | 工作区包含大量未提交变更，缺与最终代码一致的干净 checkout/远端统一门禁证据。历史各模块通过不等于最终同版门禁；本次未查询 CI 额度，不沿用历史“额度耗尽”作为当前事实。 |
| E09 | 发布验收 | 完整混合负载、长期运行与多 Gateway/分片容量 | 未开始 | 当前房间日志有20在线连接/800消息的有界 Release 负载与重启记录；房间恢复有五档规模和双 Gateway 记录。仍缺同版混合消息、热点、大历史缺口、多设备/分片、完整资源与长稳故障验收；旧50k容量数字不能外推当前改造。 |
| E10 | 发布验收 | ARM64 Linux 压力下历史 SIGSEGV 根因未关闭 | 未开始 | 历史 ARM64 Linux SIGSEGV 仍缺符号化根因；一次未复现不能关闭，需原始 core 与同版本长稳。 |

## 复核入口与证据范围

源码链接对应当前工作区；专题记录中的测试数量和临时日志路径属于原运行，不是本次新执行结果。
部分旧专题合同仍描述已删除的扇出/升级路径，只能用于追溯；当前架构范围以本表及房间日志改造为准。

| 事项 | 当前实现入口 | 证据与关闭边界 |
| --- | --- | --- |
| B01 整数边界 | [时间戳转换](../../IMV2Server/Sources/IMV2Server/V2PostgresTimestampBounds.swift)、[变更结果边界测试](../../IMV2Core/Tests/IMV2CoreTests/MessageMutationResultBoundsTests.swift)、[恢复 DTO 测试](../../IMV2ClientKit/Tests/IMV2ClientKitTests/V2ProjectionRecoveryBoundsTests.swift) | 已有多层边界保护；[消息投影专项与入口核对](message-projection-integer-boundaries.md)记录当前修复，快照计数、Core 发送序号、私聊缓存及部分 worker 已对应；其余 worker、客户端 outbox 计数及分页/响应转换仍需完成映射 |
| B03/B12 房间恢复 | [Runner](../../IMV2ClientKit/Sources/IMV2ClientKit/V2RoomRecoveryRunner.swift)、[Engine](../../IMV2ClientKit/Sources/IMV2ClientKit/V2RoomRecoveryEngine.swift)、[持久待办](../../IMV2ClientKit/Sources/IMV2ClientKit/GRDBV2RoomRecoveryStore.swift) | [验收矩阵](client-owned-conversation-sync-acceptance.md)、[事务边界](client-owned-conversation-sync-transaction-audit.md)、[规模结果](client-owned-conversation-sync-scale-results.md)；原单轮预算问题已修，完整恢复目标仍开放 |
| B06 成员与角色 | [本地 reducer](../../IMV2ClientKit/Sources/IMV2ClientKit/GRDBV2LocalSyncStore.swift) 的 applyMembershipAwareRoomProjection / applyGroupCapability | 本人 membership 状态保留撤销版本，新的授予同时创建待办；其他成员 add/remove/role 按独立持久来源历史归并，快照保留撤销事实并拒绝冲突；缺失历史时的权威基线与代次组合仍开放 |
| B04/B11 转发与接受记录 | [转发路由](../../IMV2Server/Sources/IMV2Server/V2RoutedForwardMessagesService.swift)、[接受记录](../../IMV2Server/Sources/IMV2Server/PostgresV2SendCompletion.swift)、[清理器](../../IMV2Server/Sources/IMV2Server/V2ControlPlaneHousekeepingWorker.swift) | [房间日志改造](room-log-only-implementation.md)记录 v3 指纹和接受回执验证；完整 owner 迁移及终态保留/清理不由这些记录替代 |
| B08 退出与凭据恢复 | [App Store](../../IMApp/IMApp/V2/V2AppStore.swift)、[撤销恢复测试](../../IMV2ClientKit/Tests/IMV2ClientKitTests/V2DeviceRevocationRecoveryTests.swift) | [受控进程中断](legacy-registration-app-process-contract.md)、[撤销状态](device-revocation-status-contract.md)保留真机、系统后台及 GC 边界 |
| B15/B16/D02–D04 生命周期 | [App runtime](../../IMApp/IMApp/V2/V2AppRealtimeRuntime.swift)、[Push reconciler](../../IMV2ClientKit/Sources/IMV2ClientKit/V2PushIntentReconciler.swift) | 后续 headless 整轮通过见[恢复验收](client-owned-conversation-sync-acceptance.md)；不等同真实 APNs、磁盘擦除或账号切换全组合通过 |
| B23/B24/B25/B26/D06 邀请与审批 | [申请存储](../../IMV2Server/Sources/IMV2Server/PostgresV2GroupInvitationStore.swift)、[服务接口](../../IMV2Server/Sources/IMV2Server/V2GroupInvitationService.swift)、[schema](../../IMV2/sql/schema.sql) | owner 内锁串行申请；schema 39 的 control 账本承担跨 owner 配额并保存重复操作绑定，owner 保存原子提交回执；B23 全局配额专项已通过。分页使用不可变键，审批单事务提交；申请人可取消旧 pending，终态保留重放记录 |
| B27 owner 路由 | [Account 组装](../../IMV2Server/Sources/IMV2AccountServerApp/main.swift)、[邀请路由](../../IMV2Server/Sources/IMV2Server/V2RoutedGroupInvitationStore.swift) | 路由实现存在不等于迁移过程中的全量状态承接验收 |
| B29 版本 | [协议版本源](../../Protocol/im_realtime/v2/protocol_version.txt)、[客户端生成物](../../IMV2ClientKit/Sources/IMV2ClientKit/Generated/IMV2ProtocolVersion.swift)、[服务端生成物](../../IMV2Server/Sources/IMV2Server/Generated/IMV2ProtocolVersion.swift) | 均为30；schema 为 im-v2-current-49，不再沿用旧表的27/30组合 |
| D07/D08 新架构与组合证据 | [已完成改造](room-log-only-implementation.md)、[当前有界运行验收](room-log-current-runtime-2026-09-13.md)、[会话恢复矩阵](client-owned-conversation-sync-acceptance.md) | 旧流水线移除已完成；新恢复矩阵仍开放。自动重连漏计设备已修，三次断线、13台设备总数及该账号2台设备终验通过；历史失败保留，见[治理专项](verification-records.md#20260919-governance-recovery) |

## 修复顺序与验收要求

1. **先完成服务端实现与范围审计：B01、B04、B11、B27、D07。** 聚焦整数边界、授权/幂等/准入、终态保留和运行时 owner 迁移；不增加旧模式或旧 schema 兼容。
2. **核对混合条目的服务端部分：B03、B06、B08、D08。** 推进快照/裁剪、成员权限、撤销记录保留及跨分片故障中可独立验证的服务端行为；客户端组合未验收时，原编号保持开放。
3. **完成服务端发布准备与可执行验收：E01–E03、E06–E10。** 生产接入、同版 CI、容量、灾备及 Linux 故障按证据关闭；缺少外部环境的条件保持待验收。
4. **暂缓客户端优化、真机及客户端发布专项。** B07、B15、B16、B22、B28、D02–D04 和 E04–E05 的剩余要求保留在表内，本轮不推进、不计作关闭。

本轮治理修复自动重连验收计数、运行时选择及强杀测试的并发编译边界；62 个强杀参数和真实 PostgreSQL/HTTPS/双 Gateway/NATS/App 前台重连专项通过，见[证据](verification-records.md#20260919-governance-recovery)。
成员角色恢复已修改 ClientKit 生产 reducer 和当前本地 schema，148 项同步/恢复/schema 定向回归通过，见[成员持久版本证据](verification-records.md#20260919-member-ledger)；此前 App/TLS 通过早于此修改，不能充当修改后的全量证明。未重跑全仓业务套件、真实 APNs 或容量验收，未提交或部署。文档链接、结构、协议及差异检查独立执行。
已有通过记录按其原场景和版本保留；当前未提交源码不能直接继承全部历史全量结果。

详细原始触发条件见[原始审查](archive/2026-09-05-system-design-implementation-audit.md)；历史实施与运行见[修复进度](archive/2026-09-05-system-remediation-progress.md)和[验证记录](verification-records.md)。历史文档的旧路径、版本与行号不作为当前实现事实。

2026-09-19 后续：D06 申请取消已关闭，D06 引入 schema 37；取消、审批、配额、跨库路由及 App 定向测试通过。最后新增历史索引后仅补跑对应 schema 约束门禁，详见[取消验证记录](verification-records.md#20260919-group-join-cancellation)。

2026-09-19 后续：B23 全局待审配额已关闭；schema 39 的提交、回执、重复操作绑定及恢复验收见[全局配额验证记录](verification-records.md#20260919-group-join-global-quota)。当前开放 27 项，未提交或部署。
