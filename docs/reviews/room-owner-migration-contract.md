# 房间 owner 迁移实施合同

2026-09-20。对应 B27，关联 B03/B04/B06/B11/D07/D08。当前只有用户分片迁移执行器；本文定义房间迁移的实现与验收要求，不代表已具备搬迁能力。项目未上线，以 schema 49 新库为基线，不实现旧 schema 或旧协议兼容。

## 当前事实与必须补齐的边界

- `V2RoomOwnerTransactionFence.swift` 持有房间行锁并检查 shard/epoch 及迁移标记，但仅对调用它的事务生效，不能证明后台审核、清理、转发和个人投影任务全部停止。
- `V2RoomShardRouter.swift` 提供查询和创建时登记；当前没有迁移切换 API。显式目录缺失时仍读本地 rooms 并硬编码 epoch 0，这条旧回退不能作为迁移中的定位或恢复依据。
- `V2UserShardMigration.swift` 和 `PostgresV2UserShardMigrationStore.swift` 属于用户分片；其复制集、转发模式、路由和回滚规则不能直接当成房间迁移能力。
- schema 44 已增加 room_owner_migrations 任务与进行中房间唯一约束、身份不可变触发器；当前 schema 46 已实现准备、冻结意图及源房间持久标记。完整写入排空、复制检查点、校验清单、切换回执和运行入口仍未完成；当前任务仍停留在 freezing。

## 执行顺序与恢复要求

1. **准备。** 在 control 保存不可变 migrationID、roomID、源/目标 shard、源 epoch 和目标 epoch；目标必须已注册且不同于源。以房间为单位排除并发迁移，拒绝 epoch 上溢和操作改参。不能发布目标路由。
2. **冻结并排空。** 持久保存源房间迁移冻结事实；等待此前写入提交，后续源写入明确拒绝或进入可恢复等待。覆盖前台写入、业务回执重放中的后处理、后台 worker 和清理入口。普通 frozen_at 是业务冻结，不能充当所有入口的迁移屏障。开始复制前必须证明这些入口都受屏障约束。
3. **有界复制。** 以稳定主键分页，记录每张表的检查点、行数和内容摘要；重试同页不得重复业务效果或把冲突当作已完成。目标尚未对外服务。复制范围必须包括保留历史和未完成工作，不能只复制当前消息/成员投影。
4. **校验。** 源写入仍被冻结；逐类比较复制集、约束和不可变事实。清理后的空载荷是合法终态，不能重新生成或要求读取已经删除的正文。源、目标在校验结束前均不能提前删除恢复依据。
5. **发布。** 目标先持久确认数据与新 epoch 可用，再在 control 事务中比较源路由并写入切换回执、房间目录和私聊用户对目录。目录拓扑变化须使旧扫描游标失效。控制提交失败重试同一操作；不得反向覆盖已变化的路由。
6. **承接与保留。** 新 owner 承接未完成审核、转发、通知和个人效果投递；旧 owner 继续拒绝迟到操作。复制 claim_token/lease 的字节不等于任务已被安全接管，必须明确租约失效与重领规则。源清理须等待目标和切换证据齐全，并保留必要回执；切换后不支持未经反向同步就直接切回旧库。

每个阶段均须可被进程重建后读取恢复。失败不得由“找不到本地记录”推断另一个 owner 未提交，也不得用新 operationID 绕过原操作。任一步的状态表、SQL 与运行时入口未实现时，保持 B27 开放。

## 数据归属与复制闭包

以下分组来自当前 schema 和既有合同。它是实现时必须逐表核对的清单，尚未作为通过验收的复制 manifest。

| 类别 | 必须处理的当前状态 | 边界 |
| --- | --- | --- |
| 房间与成员 | rooms、group_rooms、room_memberships、room_member_mutes、room_member_nicknames、角色策略/权限、公告、置顶、已读、room_timeline_activities | 保留完整成员历史区间与版本，不只复制当前成员 |
| 内容与接受事实 | messages、room_events、message_send_completions、message_content_versions、message_projection_states、message_projection_state_values、mentions/media 引用、reactions | 子表需按消息/投影键闭包选择；接受指纹与成员修订不能随正文清理丢失 |
| 操作回执与审计 | 创建、成员、角色、权限、公告、置顶、昵称、编辑、撤回、反应、已读、moderation、特殊账号操作及审计 | 按所属房间选择，并保留来源/操作身份；重放不得再扣额度或产生新事件 |
| 邀请与申请 | group_invite_links、group_join_requests、group_join_submission_receipts、group_join_approval_recovery_audit、room_membership_operation_fences | 保留申请、批准中状态、历史回执与旧操作阻断；control 全局配额不复制为 owner 配额 |
| 转发源端 | message_forward_operations、message_forward_exports、message_forward_export_receipts、message_forward_delivery_jobs | 按源/目标字段的实际持有语义核对，不能仅按任一 room_id 命中整行搬走；已压缩载荷保持终态身份/摘要/结果 |
| 转发目标端 | message_forward_inbox、message_forward_inbox_media、message_forward_media_imports、关联重放审计 | accepted 后处理与 completed 分开承接；既有 envelope/receipt epoch 不能通过改 JSON 伪造为新操作 |
| 后台工作 | content_review_jobs/decisions/findings/cases、group_event_wake_outbox，以及由房间事务产生的个人事件待投递状态 | 需查明间接键及 payload 归属；必须处理正在执行的 claim 和已提交的去重回执 |
| 私聊 | direct_room_pairs、direct_room_operations、direct_message_denials、支持会话及相关特殊账号状态 | control 的 direct_room_owner_routes 必须与 room_owner_routes 一致；用户对创建建议锁需纳入切换锁顺序 |
| 准入 | room_admission 与旧 shard lease/进程信用额度 | 不复制整个 shard_admission_pools；显式失效旧额度并按目标策略重新建立，不能重复使用源端余额 |
| 媒体 | message_media_references、转发媒体映射、对象删除/复制任务及存储提供方状态 | media_objects 等状态可能跨房间共享；仅复制消息引用不等于对象可用，不能误删除共享对象 |
| 控制面保留 | room_owner_routes、direct_room_owner_routes、room_recovery_topology、邀请目录/创建恢复、全局申请 quota intents/aliases、创建 intents/pages | 由 control 协调更新，不整表复制到目标 owner；未完成创建/批准与迁移之间需要独立交错验证 |
| 用户分片保留 | user_room_preferences、user_message_favorites 及对应操作、个人同步日志/快照/效果回执 | 存在 room_id 不表示属于 room owner；通过现有用户路由承接，不能移动整份用户状态 |

## 关闭证据

- 逐入口证明源端冻结屏障，覆盖正常请求和迟到响应；检查后台任务及清理器的锁顺序，不能只验证路由层拒绝。
- 真实 control、源 owner、目标 owner 三库迁移普通群、大群、私聊；源端复制前后指纹以及目标内容、历史、邀请、申请、回执、待办逐项一致。
- 复制页重试、冲突、中断、目标不可达、校验不一致、发布竞争及进程强杀后恢复；所有状态推进使用同一 migrationID。
- 迁移后原发送/编辑/转发/审批/管理操作重放不新增效果；改参冲突；旧 owner 迟到操作被拒绝；成员移出/重入不扩大历史可见性。
- 准入额度、审核/转发租约、个人投影去重和媒体共享/删除状态有专项证据；控制面目录更新与私聊用户对一致。
- 复制与校验使用有界页和可恢复检查点，测量大房间历史的锁、WAL、内存与恢复成本。局部存储测试不能代替完整执行器与运行组装。

原有受控路由切换和用户分片测试保留为各自范围的证据，不用于关闭上述条目。


## 准备阶段当前实现

[准备存储](../../IMV2Server/Sources/IMV2Server/V2RoomOwnerMigrationPreparation.swift)要求源/目标分片已注册且不同，目标 epoch 为源加一并拒绝溢出。新任务锁定显式 room_owner_routes 行核对源位置，不使用 rooms 的历史回退；按 migrationID 建议锁串行化相同身份请求，按源目录行锁串行化同房间不同任务，并以部分唯一索引兜底。精确重试返回数据库原记录，不改变时间或阶段，不写房间路由。

phase 定义为后续状态推进保留名称；当前提供 prepared → aborted 的取消操作，以及 prepared → freezing 的控制意图登记，不能直接修改 phase 当作完成冻结、复制或发布。任务身份由数据库触发器保护，控制检查点及执行器仍待实现。专项与建库证据见[准备阶段验证](verification-records.md#20260920-room-migration-preparation)。


准备记录现在支持按 migrationID 读取；读取不依赖进程原分片注册集合，也不代表具有下一阶段执行资格。abortPreparation 校验完整请求身份，仅允许 prepared 原子变为 aborted，已 aborted 精确重放返回原记录。取消不会改目录；新任务可使用新的 migrationID，旧 ID 重试保持 aborted。后续冻结执行器必须先在同一任务行锁下离开 prepared，再触碰源 owner，不能先在源端产生效果而仍让控制记录保持可取消。

读取/取消及非法阶段拒绝的[专项证据](verification-records.md#20260920-room-migration-abort)只覆盖控制记录，不替代进程重启、源端冻结或完整迁移恢复。


schema 45 增加 freezing 阶段；beginFreezing 在任务锁与源目录行锁下重新核对不可变请求和源路由，再把 prepared 原子改为 freezing。重复调用保持原记录，source 已变化则拒绝。此时 abortPreparation 必须拒绝；后续执行器可读取同一个任务继续源端屏障，但不能把 freezing 当作已经排空源写入。取消/启动并发互斥和恢复重试证据见[冻结意图专项](verification-records.md#20260920-room-migration-freezing-intent)。


## 源房间写屏障当前实现

schema 46 在 rooms 增加可空 migration_fence_id。[源端屏障安装器](../../IMV2Server/Sources/IMV2Server/PostgresV2RoomMigrationWriteFence.swift)仅接受 freezing 控制记录，持有源房间行锁并复核源 shard/epoch 后保存迁移 ID；相同 ID 可重试，不同 ID 拒绝。它与共用归属检查的事务争用同一房间行锁；共用检查在标记存在时拒绝后续写入。安装不改变 owner epoch、房间序号、控制阶段或路由。

当前覆盖调用共用 v2RequireRoomOwner 的路径；发送存储的独立 requireSelectedOwners 也已读取迁移标记，路由发送在业务提交和回执重放前拒绝迁移中的房间。其余独立归属检查、非路由写入、后台工作与清理入口尚未逐一接入；没有完整排空证明，控制任务仍保持 freezing，不能推进 frozen 或开始复制。运行入口、解除屏障及完整搬迁执行器仍未实现。验证范围见[源端标记专项](verification-records.md#20260920-room-migration-owner-marker)。


发送独立检查的专项见[发送屏障验证](verification-records.md#20260920-room-migration-send-fence)。`v2RequireForwardOwners` 及 `PostgresV2ReadReceiptStore` 的标量、读者查询与 prepared-statement 归属检查现已读取并拒绝迁移标记，见[回执和同库转发专项](verification-records.md#20260920-room-migration-receipt-forward-fence)。跨库新导出、新收件箱、接受/拒绝与完成阶段的 owner 检查现已覆盖迁移标记，见[跨库转发专项](verification-records.md#20260920-room-migration-cross-forward-fence)。原导出/已存在接收的只读重试和不可变终态回执保留；媒体导入认领与统一 mutate 已复用目标归属屏障；operator 重放现已拒绝迁移中的房间，见[媒体与运维重放专项](verification-records.md#20260920-room-migration-media-operator-fence)。清理、其他非路由写入和后台任务仍须逐入口覆盖。发送前预取的准入信用额度不属于消息接受事务，本轮内容与接受事实对比不证明额度池已冻结；额度失效/重建仍是迁移执行器的必要条件。


源端投递任务现在按 [PostgreSQL 16 加锁语义](https://www.postgresql.org/docs/16/sql-select.html#SQL-FOR-UPDATE-SHARE)同时锁候选任务与源房间，跳过被锁或已有迁移标记的房间；完成和重排在房间共享锁持有期间复核归属及迁移标记，源端首次保存终态回执也拒绝迁移标记。旧租约的 isCurrent 包含同一归属条件，精确旧回执重放仍只读。证据见[后台投递屏障](verification-records.md#20260920-room-migration-delivery-fence)。

isCurrent 仍是网络请求前后的瞬时检查，不能证明检查后已经发出的远程 I/O 被撤销或排空。旧任务回写源库会被阻止，但完整迁移仍须定义目标已接受、源回执未保存的承接流程；不能把任务不再认领等同于端到端排空。


媒体导入屏障覆盖数据库中的对象状态、复制摘要、媒体映射及任务处置；不代表已经停止进行中的对象 I/O。本机专项在实际文件复制后安装屏障，验证随后数据库回写拒绝、已复制对象保留。运维精确旧操作只返回原审计结果，不重新激活暂停任务；新操作的审计预占与任务改变在同一事务中拒绝并回滚。


转发 source/export 与 target/inbox 正文压缩现在逐候选按房间主键取得共享锁，排除 migration_fence_id 非空的房间，房间或正文候选被其他事务占锁时跳过。锁保留到同一清理语句提交；缺少本地房间的记录不清理，后续旧 owner 回收应使用明确的迁移完成证据，不能凭房间缺失推断安全。只约束当前正文压缩入口，其他清理仍需核对。[专项与 SQL 成本证据](verification-records.md#20260920-room-migration-compaction-fence)保留逐步修正结果。


房间日志保留裁剪的正向扫描和回绕扫描均排除迁移标记，并使用 FOR UPDATE SKIP LOCKED。房间锁持有到下界更新与事件删除提交，和源端标记安装互斥；忙碌房间本轮跳过，后续轮转重试。该变更不改变读者下界和保留窗口语义。证据见[房间日志清理专项](verification-records.md#20260920-room-migration-log-retention-fence)。其余维护入口仍待逐一核对。

控制维护器对 14 类 room_id 直接归属的操作回执（私聊创建、群创建、成员、昵称、角色、权限、公告、置顶、编辑、撤回、反应、已读、moderation、特殊账号）以及 content_review_jobs 终态清理，逐候选锁定房间并要求迁移标记为空，见[操作回执清理专项](verification-records.md#20260920-room-migration-housekeeping-fence)。共享房间锁保持至清理事务提交，被占锁或缺少本地房间时保留；原审批/审计依赖保留条件和总删除预算不变。用户偏好回执仍归用户分片，不因关联房间迁移而冻结。message_forward_operations 的源/目标跨房间归属、共享媒体及其他审计/后台清理仍须单独完成。


message_forward_operations 已移出通用过期清理。真实复现表明删除固定目标客户端标识后，旧转发可被接受为新消息；因此仅增加迁移标记筛选不足以守住正常运行时的幂等边界。来源/目标关联的迁移承接与可回收期限仍未实现，详见[发送及转发保留合同](send-completion-retention.md#转发操作绑定也属于接受屏障)。

审核审计过期清理也按 room_id 查询并共享锁定未标记迁移的房间，审计候选行继续跳锁且受 limit 限制；缺少本地房间时保留。专项把审计和操作回执一并纳入完整行快照：迁移或房间占锁时保留，正常房间先删除到期审计后才能清理对应 moderation_operations，见[审核审计屏障](verification-records.md#20260920-room-migration-moderation-audit-fence)。此项仅覆盖审计删除，不证明所有审核任务写入或在途外部审核已排空。

内容审核存储的任务认领现在按候选房间主键取得共享锁并跳过迁移标记；续租/失效结算、违规暂存、结论与派生发现/人工复核记录、重试/暂停均在事务内取得房间共享锁后检查标记。修改任务时还要求 room_id 与被锁房间一致。见[审核任务数据库屏障](verification-records.md#20260920-room-migration-content-review-fence)。外部审核请求取消、其他运维类型及完整审核排空和迁移承接仍待完成。

审核内容处置的 redact、mute、removeMember、controlRoom 现在从既有 FOR UPDATE 房间查询读取迁移标记，新操作在任何领域修改前拒绝。覆盖普通审核撤回、禁言、移除成员以及 trusted-safety 撤回、冻结和解冻；不依赖调用方是否提供 owner 路由。非路由入口的已完成精确重放仍只读，路由入口继续先检查 owner/标记再返回回执。普通群/大群六种处置和十表不变证据见[内容处置屏障](verification-records.md#20260920-room-migration-moderation-write-fence)。外部审核响应与迁移执行器的完整交错仍需验收。

通用运维重放的 contentReview 分支现已按实际任务关联的房间取得共享锁并检查迁移标记，锁顺序为房间后任务；标记存在则拒绝，外层事务回滚本次审计预占。单目标与按事件恢复共用此分支，已完成单目标操作仍只返回原审计结果。证据见[审核运维恢复屏障](verification-records.md#20260920-room-migration-review-replay-fence)。媒体等其他类型并未因此获得房间冻结保护。

成员变更的独立归属检查已包含 migration_fence_id，路由入口在业务变更和回执重放前拒绝标记。无路由的直接调用及邀请审批使用的同事务原语，在新成员效果提交前从既有房间 FOR UPDATE 查询检查标记；旧本地精确回执仍只读。证据见[成员变更屏障](verification-records.md#20260920-room-migration-membership-write-fence)。邀请存储自身使用另一套检查，覆盖情况单列如下。

PostgresV2GroupInvitationStore 的共用 fence 现对 scoped 与直接调用都锁定房间并检查 migration_fence_id；scoped 调用继续校验 shard/epoch。无 scope 的新申请先通过摘要读取不可变房间绑定，再锁房间，最后锁邀请，保持房间先于邀请的顺序。本地精确提交重放仍可走只读回执，其他已接 fence 的管理读取在标记后也拒绝。普通群/大群的[邀请存储专项](verification-records.md#20260920-room-migration-invitation-fence)覆盖新申请及创建、撤销、决定、取消等事务。control 目录/配额恢复与源冻结的跨库交错及最终迁移承接仍需独立验证。

审批异常恢复的 assertOwner 现从既有房间 FOR UPDATE 查询读取迁移标记；新恢复及候选分页在标记存在时拒绝，防止修改申请、邀请使用次数、成员操作阻断记录和恢复审计。已提交恢复操作的精确重放仍只读返回原审计。范围与验证见[审批恢复屏障](verification-records.md#20260920-room-migration-approval-recovery-fence)，不代表迁移全链路完成。

邀请创建与全局申请配额的后台恢复已有[跨库冻结专项](verification-records.md#20260920-room-migration-invitation-recovery-fence)：仅预留、owner 已提交、owner 已终结但 control 尚未确认三类状态，在标记提交后由新工作器重试两轮，均延期并保留配额，不修改源数据或发布未完成目录。control 的认领租约与重试时间继续推进；这些记录不属于源房间复制集。本证据尚不覆盖正在返回的 owner 响应与冻结安装/control 确认的并发窗口，以及迁移发布后的恢复承接。

消息编辑、撤回与反应的独立房间 FOR UPDATE 查询也已读取迁移标记，因此无 ownerRoute 的新写入同样拒绝。原本地精确回执保持只读，路由重放先检查迁移标记。普通群/大群、三种操作与消息/投影/事件/额度不变的验证见[消息变更屏障](verification-records.md#20260920-room-migration-message-mutation-fence)。此项不替代发送、群管理等其他直接入口的逐项核对。

群置顶、公告、角色权限与成员角色的共用 prepare 已在房间行锁下检查迁移标记，覆盖无 ownerRoute 的实际新写入；本地原回执及本人角色的无效果分支保持只读。普通群/大群四类操作和十四表快照见[群管理屏障](verification-records.md#20260920-room-migration-group-capability-fence)。发送、昵称和其他独立写入检查仍需逐项核对。

群昵称的新操作现在先取得房间共享锁并检查迁移标记，再读取成员资格和更新昵称；旧直接调用的精确回执保持只读。普通群/大群的真实安装事务锁等待与数据不变验证见[昵称屏障](verification-records.md#20260920-room-migration-nickname-fence)。Account 现已接入 V2RoutedProfilePresentationStore：群昵称查询和更新选择 room owner，在同一事务复核 shard/epoch/标记，路由旧回执也先检查归属；联系人备注委派原配置存储。双库隔离和旧路由拒绝见[昵称路由专项](verification-records.md#20260920-room-migration-nickname-routing)。完整复制、发布及切换后承接仍未完成。

发送的 requireSelectedOwners 现对未提供 ownerRoutes 的直接调用也锁房间并检查迁移标记；有路由时仍校验完整位置与 epoch。大群快速 conditional append 在既有原子 SQL 的 eligible/batch_gate 中拒绝标记，零写入诊断返回归属错误，正常路径仍为单条 SQL。六类发送及批量回归见[直接发送屏障](verification-records.md#20260920-room-migration-direct-send-fence)。预取信用额度仍可能在接受事务之前变化，其失效/退还和目标重建不由本批覆盖。

回执 recordGroups 现对无 ownerRoutes 的直接入口也取得稳定顺序的房间共享锁，标记非空的输入按项拒绝；私聊探测后的实际写入事务从既有房间行锁再次读取标记。群/私聊新旧直接回执、混合合法项和个人事件不变范围见[直接回执屏障](verification-records.md#20260920-room-migration-direct-receipt-fence)。此项未覆盖个人事件队列工作器的认领/确认或完整排空。

schema 47 的 user_state_event_outbox.source_room_id 显式区分 room owner 源事件与 control 等其他源事件。owner 生产路径写入源房间；control 已读隐私传播即使载荷含 room_id 仍保持空来源。数据库约束验证非空来源与载荷一致，enqueue 精确重试还比较来源；索引供后续按房间有界处理。见[来源归属专项](verification-records.md#20260920-user-event-source-room)。

个人事件队列的认领、确认和重试现按显式来源房间取得共享锁，并要求迁移标记为空。认领跳过占锁房间；确认/重试等待房间锁后复核。缺失来源房间时不修改队列；空来源事件继续正常处理，即使载荷指向冻结房间。冻结后已认领事件的确认返回 false，重试/暂停不修改原行；租约过期和重建存储后仍不能再次认领。见[队列冻结专项](verification-records.md#20260920-user-event-migration-fence)。运维重放与已确认事件清理的后续保护见下段；在途投影写入排空/承接仍待完成，本项不证明完整冻结。

个人事件运维重放先读取显式来源，非空来源必须在共享房间锁下通过迁移标记检查；来源缺失或冻结时拒绝，外层事务回滚审计预占。空来源事件继续处理，已经完成的精确重放只读原结果。已确认事件清理按候选主键共享锁定未冻结的来源房间，跳过占锁和缺失房间，保留原确认时间与批量上限。见[队列维护专项](verification-records.md#20260920-user-event-maintenance-fence)。这两项保护源队列修改，不代表在途用户投影、外部通知或完整迁移已经排空。

房间唤醒队列的 claimPending、markPublished 和 scheduleRetry 现按房间主键取得共享锁，并要求迁移标记为空。认领跳过占锁房间；确认与重试等待锁后复核，标记存在时保留原行。认领继续使用同一事务内的两条 READ COMMITTED 语句读取最新水位，不退回旧候选快照。见[房间唤醒屏障](verification-records.md#20260920-room-wake-migration-fence)。已取得租约的外部通知发布仍可能完成，数据库保护不等同外部 I/O 排空；目标承接及完整迁移仍待完成。

复用已有私聊房间时，PostgresV2DirectMessagingStore.open 从既有 FOR SHARE 房间查询读取迁移标记，新操作在插入 direct_room_operations 前拒绝冻结。直接与路由调用共用此实现；原操作精确重放保持只读。实际冻结事务提交交错、七张 owner 表及三张 control 目录表不变范围见[私聊复用屏障](verification-records.md#20260920-direct-open-migration-fence)。本项不完成私聊目录迁移发布，也不覆盖其他特殊账号写入或创建中间状态承接。

特殊账号发送后的 record 新写入现先验证接受回执的房间、发送者和操作编号与输入一致，再共享锁定房间并检查迁移标记；操作与审计仍同事务写入。既有操作精确重放还比较房间，保持只读。系统/客服账号在消息接受与后处理之间冻结的证据见[特殊账号后处理屏障](verification-records.md#20260920-special-account-migration-fence)。消息已接受但审计未写入仍是必须随迁移承接的状态；此项没有新增自动恢复执行器，也不证明特殊账号跨 owner 路由已完整接通。

房间命令额度的持久预扣 reserveBatch 现先物化并以 FOR KEY SHARE 锁定未被冻结的房间，再按原租约和窗口条件锁定/递增 room_admission，发送预检使用 FOR NO KEY UPDATE，冻结安装保留 FOR UPDATE，避免同一发送流程在独立预扣连接上互相等待。遵循房间先于准入行的顺序；拒绝诊断区分迁移标记与额度耗尽。见[房间额度预扣屏障](verification-records.md#20260920-room-credit-migration-fence)。此项保护持久预扣，不使已在内存中的额度自动失效；发送接受检查仍承担最终拒绝，源额度清退、分片额度与目标重建继续开放。

控制面社交变更的本地 direct_room_pairs.direct_policy_revision 现先取房间共享锁，仅对 migration_fence_id 为空的副本递增；冻结安装持房间排他锁，社交请求等待后重新检查标记。正常同库版本围栏及整数上限保持，冻结副本不变（即使版本已达上限），控制关系/拉黑仍可提交。目标发送依靠已接线的控制权限范围撤权，不能再用目标本地旧好友版本作权威。见[社交冻结副本专项](verification-records.md#20260920-social-frozen-source-policy)。此项不证明全量复制、目录切换、控制连接失效或所有后台写者均已闭环。

### 私聊控制权限接入的后续要求

Gateway 的社交服务写控制库，跨物理库不能用 owner 本地版本证明控制库权限仍有效。当前 Gateway 已将所有房间写存储绑定独立 direct-send-control 池，单条、原子批量、同库前台转发和后台转发导入在 owner 事务前登记持久控制授权；群聊保留现有 owner 授权。社交版本递增已避开冻结的源副本，控制连接失效及完整迁移承接仍待闭环，不能只凭接线关闭此问题。

已增加内部 V2DirectSendControlPolicyFence 基础入口：在控制库依次取得按用户稳定排序的 account-state 共享咨询锁、用户对共享咨询锁、陌生人偏好共享咨询锁，随后锁定现有账号资料与特殊账号行；回调期间持有锁，供后续房间提交使用。它输出控制事实，不包含 room owner 的回复标记、成员、限额，不替代完整授权判断。见[控制权限基础专项](verification-records.md#20260920-direct-control-policy-fence)。该回调本身不能作为持久授权依据；当前正式 accept、acceptAtomically 和 importForwardExport 已改为在控制事务内登记授权、提交后再进入 owner。应用以 usingControlDatabase 绑定独立控制与确认池；批量最多 128 条，完整用户/规范用户对统一排序加锁。已有[单条专项](verification-records.md#20260920-direct-send-control-authority)与[批量专项](verification-records.md#20260920-direct-batch-control-authority)，本轮接线见[运行接入专项](verification-records.md#20260920-control-policy-runtime)。**后续普通发送断连复验已通过；完整转发进程故障及迁移矩阵仍未完成，B27/D07 继续开放。**

完整关闭仍须核对以下要求：在 owner 房间锁之前进入控制权限范围；覆盖普通发送、标量/批量快速路径及转发使用的目标发送；将控制事实和 owner 当前回复/成员/额度共同用于领域授权，不能继续让 owner 旧好友状态或缓存覆盖控制事实。多房间批量必须先按完整用户/用户对集合统一排序加锁，不能任意嵌套单对入口。改写社交版本递增时保留同库缓存的撤销安全，并使被冻结/保留的旧房间不再阻塞控制面的拉黑。控制连接和 owner 提交均须有界超时/取消；离开控制事务后的权限事实必须绑定已提交的持久授权，不能裸用临时快照。需以实际消息发送验证权限变更与接受的两种提交顺序，以及跨库不可达、取消、缓存命中、账号停用和迁移切换后的行为。


应用组装已独立注册 direct-send-control 池，与 foreground/owner 及 user-state-route 均分开；每个 EventLoop 的容量等于当前 foreground 配额，额外连接经溢出检查计入总预算，全部句柄验证会话策略并随 Application 关闭。固定指标 direct_send_control 报告连接上限。小池及同物理库验证见运行接入专项；生产容量与故障恢复不由此替代。


### 控制连接中断的持久授权方案（实施中）

当前跨库回调只持有控制事务锁；锁寿命不能替代 owner 的持久接受/拒绝凭据。故障专项见[断连复现记录](verification-records.md#20260920-direct-control-connection-loss)，该专项的已知问题标记不能当成修复通过。

后续按项目已有“持久意图 + owner 回执”方式补充授权协议，保留本合同的撤权要求：

1. 控制库按原操作固定授权意图：room、发送者/接收者、client message ID、请求摘要、owner 位置与 epoch、代次及控制事实。每条命令各有意图，批量统一排序预留；不能因重试重新生成身份。用户和用户对上的 held 意图不能因超时、断连或进程退出自动释放。
2. owner 在同一接受事务内锁定该意图身份，检查永久拒绝标记，再原子记录消息结果与不可变授权回执。批量的消息和对应回执全部同事务；拒绝也有确定回执。任何重试、快速追加及转发都必须走同一授权身份，不允许绕过或复用其他代次。
3. 拉黑、关系撤销、陌生人权限、账号停用和特殊账号权限写者，在修改控制事实前统一阻止新意图并处理受影响 held 意图：取得 owner 已提交回执，或在 owner 以相同操作锁写入持久拒绝标记。仅查询不到回执不足以证明旧请求不会随后提交。
4. owner 拒绝标记必须阻止尚未开始、等待锁、事务重试或重启后恢复的旧请求再落库。若 owner 已接受，先记录该终态；若 owner 不可达，控制撤权不能假报完成或凭超时丢弃 held。失败返回可重试状态，保留恢复任务。
5. 控制库恢复任务与意图原子创建，支持有界认领、重启、响应丢失和重复执行。只有 owner 确切终态才能释放；旧 worker、旧代次和旧 owner 的结果不能释放新意图。区分业务接受/拒绝与授权代次中止：前者按原回执重放，后者只能在重新校验当前权限、保持原操作与摘要绑定后开启新代次；旧代次拒绝标记永久阻止其迟到写入。
6. 意图与 owner 回执/拒绝标记的保留、搬迁、垃圾回收必须纳入 B11/B27；不得按任意时间直接删除标记，让迟到请求重新成为新授权。

关闭前需验证断连发生于预留前后、owner 加锁前后/提交前后、控制确认前后，以及批量和转发、SIGKILL、撤权与恢复竞争、owner 不可达、代次/epoch 切换。不得用一次提交前连通性检查或取消信号代替上述持久拒绝证明。

PostgreSQL 的 [PREPARE TRANSACTION](https://www.postgresql.org/docs/16/sql-prepare-transaction.html) 也能持久保留事务和锁，但官方要求事务管理器及时完成其状态；[COMMIT PREPARED](https://www.postgresql.org/docs/16/sql-commit-prepared.html) 必须在事务块外执行。当前服务没有该管理器。本方案沿用既有入群配额的持久意图/回执结构，不在本轮临时开启 prepared transactions，也不声称该授权协议已经实现。


schema 48 的房间侧原语为 `PostgresV2DirectAuthorizationReceiptStore`，新增 `direct_authorization_receipts`：以房间/发送者/客户端消息 ID/授权代次为主键，绑定接收者、owner shard/epoch 和当前 v3 请求摘要。`prepare` 与现有单条发送共用操作锁；新记录必须复核当前私聊成员对、owner 与未冻结状态。`finish` 只从同事务可见的不可变接受记录或业务拒绝记录生成证明，没有结果就拒绝；已有中止标记会使 finish 抛错。`abort` 等待相同操作锁，已有接受/拒绝结果则记录该终态，否则持久写入 aborted。精确终态可只读重放，跨代次仍不能改变请求摘要或接收者。

数据库触发器禁止这些证明更新或删除，启动检查与独立 schema 合同检查主键、字段、约束、索引和触发器函数内容。当前无自动过期；此表属于房间迁移与保留清单，后续复制/校验必须承接。原语与 schema 验证见[房间侧回执证据](verification-records.md#20260920-direct-authorization-owner-receipts)。房间写入存储现已提供授权绑定并在普通/批量/转发导入事务中检查和记录证明；schema 49 已补控制意图和有界撤权/恢复协调原语。权限写者现已调用撤权排空；协调器、独立处理池与 Gateway 后台任务已组装，普通/批量/转发自动登记/绑定/确认已接通；完整进程生命周期及剩余故障组合仍需验证。后续普通发送断连复验见自动授权章节；转发和完整迁移仍开放，不能把原语验证当作整体故障已修复。


schema 49 的 `PostgresV2DirectAuthorizationIntentStore` 在控制权限锁范围内原子登记整批操作及其恢复任务，提交后才返回授权。相同操作重试保持原 owner、epoch、代次与控制事实；仅在 owner 已持久中止、控制库确认该终态后，新的前台重试才可更新权限事实并递增代次，保留最初创建时间与命令摘要。恢复任务不能通过重新 reserve 开启新代次。数据库触发器保护 held 身份和终态，拒绝删除；字段与约束不允许无终态的事件 ID、残缺租约或非法时刻。意图是控制数据，owner 回执是房间数据，保留和迁移仍需协调。

`V2DirectAuthorizationCoordinator.drain` 必须在权限写者取得既有排他锁后、实际改变控制事实前调用。每批最多处理 128 个 held 意图，以确切 owner 中止/接受/拒绝证明解除约束；确认使用独立控制连接，使外层撤权事务回滚也不丢失已完成的排空进度。超出本轮上限或 owner 不可达时不能报告撤权成功。`recover` 每批最多认领 100 项，租约过期只允许重新认领，不能释放授权；失败退避，只有确切代次终态才可解除 held。恢复可中止仍在途的同一授权代次，必须依靠 owner 操作锁与持久标记保护，不能依赖原调用者已经退出。

原语专项与证据边界见[控制授权登记验证](verification-records.md#20260920-direct-authorization-control-intents)。权限写者已有排空调用及未配置协调器时的拒绝保护，正式 Gateway/Operator 的协调器组装、自动登记/确认和后台生命周期仍未完成。正式入口接通并完成原 D07 断连故障复验前，不把上述原语视为系统级修复，也不关闭 D07。


房间写入接线集中在 `PostgresV2RoomWriteStore.usingAuthorizationGrants` 与 `withRoomWriteTransaction`：绑定已提交的授权后，普通单条、标准/快速批量和导入事务在操作锁下先检查持久中止；保留现有源/目标房间排序加锁，取得房间锁后才复核授权绑定的 owner/epoch。命令摘要必须与授权一致，工作负载连接池切换保留绑定。消息或业务拒绝的授权回执在同一事务返回前落库，回执写失败会使整个事务失败；没有接受/业务拒绝事实的准入失败继续保持 held，不能生成虚假的业务终态。单条、原子批量及转发导入的迟到旧代次均必须拒绝。

授权检查分为只取得操作锁的 `checkAttempt` 和取得房间锁后的完整 `prepare`。这是为了避免同库转发尚未按顺序锁定源房间时，提前取得目标房间锁。正式写入专项见[接受事务验证](verification-records.md#20260920-direct-authorization-owner-entry)。普通/批量/转发运行入口已自动登记并调用绑定入口；转发先结束媒体就绪预检事务，再登记授权。后台恢复、完整进程生命周期和迁移组合仍需继续验证。


权限写者接线：PostgresV2SocialRelationshipStore 的关系变更和拉黑、PostgresV2DirectMessagingStore 的陌生人权限，以及 V2PostgresAccountDisableService 的账号停用，在既有排他用户对/偏好/账号状态锁范围内调用 `v2DrainDirectAuthorizations`，取得确切 owner 终态后才修改权限与登记操作。精确操作重放在排空之前返回，不取消之后创建的授权。未配置协调器时仍读取对应 held 意图，存在未完成授权则拒绝改变权限；不能以配置缺失绕过约束。组装层必须使用独立于权限写者和授权预留的控制确认连接池。预留可能占着连接等待撤权持有的权限锁，若撤权又等待同池的确认连接，就会相互等待；owner 中止连接也不能与可能持有控制事务的同物理库写者共用已耗尽的池。需要分别做最小连接池与同物理库的实际组装验证，当前多连接夹具不能代替。

网关把撤权未完成、owner 不可达及授权代次中止映射为可重试 UNAVAILABLE，命令身份冲突映射为不可重试 IDEMPOTENCY_CONFLICT；这些异常不能升级为认证连接故障。账号停用将排空失败映射为既有 unavailable 领域错误，继续返回不可缓存的服务不可用响应，取消信号原样传播。实际写者与协议补验见[撤权写者验证](verification-records.md#20260920-direct-authorization-policy-writers)。运行协调器与普通/批量/转发自动授权已组装；完整权限写者覆盖、进程故障及迁移组合仍未关闭，不能据此关闭整个 D07。


### 授权协调器运行组装

Gateway 和 Operator 按控制库与 room owner 的不同 URL 各注册一套处理池，每 event loop 1 条连接，与预留、前台权限写者及 owner 业务池隔离。逻辑分片别名复用同一物理池；同库 owner 中止事务结束后再执行控制确认，不嵌套借用这条连接。Gateway 把协调器注入社交/陌生人权限写者，Operator 注入账号停用服务。Gateway 恢复任务每轮最多处理 8 条，按 worker 轮询间隔重试；退出时取消并加入既有有界排空步骤。

配置预算、两个应用编译及同库/双库下占满三个单连接业务池后的撤权/恢复已通过，见[专项记录](verification-records.md#20260920-direct-authorization-runtime-pools)。测试直接组装数据库角色并调用协调器，尚未模拟实际预留任务等待权限锁，也不代替完整 Gateway 启停、故障强杀或正式发送自动登记的验证。


### 普通与批量发送自动持久授权

accept 和 acceptAtomically 在只读发现房间类型、接收者及 owner/epoch 后，按完整命令 v3 摘要和操作身份登记控制授权；登记提交返回后才进入房间事务。群聊不登记单聊授权，继续现有 owner 判断。原子批量提前拒绝重复操作，控制身份冲突交既有标量回退；不适用的批量留下 held 供重试或有证据的恢复，不推断未执行。

发送操作完成本地缓存和额度记账后，读取不可变 owner 回执，通过 Gateway 独立确认池结算控制记录。回执不存在时不确认；确认故障映射可重试 UNAVAILABLE，不归还已经消费的额度。同操作重试仍得到同一消息并补确认，改参仍冲突。确认过程不持有 owner 事务。

原断连探针改为终止确切的测试预留池后端：owner 已等待房间锁时，控制授权必须已提交；撤权等待 owner 操作锁，期间拉黑不能先提交。释放房间锁后，消息先完成且被撤权确认，随后拉黑提交；之后新请求拒绝。冷/预热都通过，普通发送的 known issue 已移除，原失败日志保留。详见[自动授权证据](verification-records.md#20260920-direct-automatic-authorization)。这不证明转发的完整断连矩阵、登记提交前强杀、全进程启停或迁移组合。转发自动登记的当前实现见下一节。


### 转发导入自动持久授权

导入先幂等接收收件箱，再用短 owner 事务锁定 inbox 与媒体映射，检查原导出摘要和载荷。媒体未就绪时直接返回 pending，不登记发送授权；已就绪时按稳定目标媒体 ID 构造命令身份，结束预检事务后才登记控制授权。实际接受事务重新读取 inbox/媒体并校验命令指纹与归属。预检使用覆盖原文长度的命令限制来固定身份，实际接受仍按当前限制拒绝新的过长文本；已有 accepted 记录的恢复不因后来缩小限制失效。

完整转发返回后通过既有确认步骤读取 owner 证明。完成标记成功但控制确认失败时，后续 terminal 重放按操作主键读取原授权、用不可变 owner 证明补确认，不重新预留代次，也不解码已清理的 inbox 正文。没有接受/业务拒绝证明的终态（如 INVALID_ARGUMENT）保留 held，待后台恢复在 owner 保存持久 aborted 后结算。控制身份冲突返回转发幂等冲突，不开启新代次。

PostgresV2RoomWriteStore 的 withControlPolicies 和其旧发现 DTO 已移除；正式单条、批量与转发均使用 withDurableAuthorizations。没有把整个 owner 提交放进控制事务的应用回调。新增无附件/真实附件 14 场景与相关 25 个回归已通过，见[转发接入证据](verification-records.md#20260920-forward-automatic-authorization)。完整转发断连/强杀、登记与媒体状态变化的并发窗口、owner 迁移承接仍需进一步验收。


### 当前控制权限写者清点（2026-09-20）

本次按 V2DirectSendControlPolicyFence 实际读取的六张控制表核对应用写者、修改字段及运行组装；范围为当前 IMV2Server/Sources，不把测试夹具或管理员直接 SQL 视为已接入的应用接口。

| 控制事实 | 当前应用写者 | 锁与持久排空 |
| --- | --- | --- |
| 拉黑、好友关系 | [PostgresV2SocialRelationshipStore](../../IMV2Server/Sources/IMV2Server/PostgresV2SocialRelationshipStore.swift) 的 changeUserBlock / changeRelationship | 用户对排他锁内 drain(pair)，再变更关系/拉黑；Gateway 注入协调器 |
| 陌生人权限 | [PostgresV2DirectMessagingStore](../../IMV2Server/Sources/IMV2Server/PostgresV2DirectMessagingStore.swift) 的 setStrangerMessagePermission | 偏好排他锁内 drain(user)，再写偏好；分片路由交 controlStore，不交 owner store |
| 账号停用与 profile.state | [V2AccountDisableService](../../IMV2Server/Sources/IMV2Server/V2AccountDisableService.swift) | account-state 排他锁内 drain(user)，再写停用记录、暂停资料及吊销凭据；Operator 注入协调器 |
| 新账号资料 | [V2PasswordAccountStore](../../IMV2Server/Sources/IMV2Server/V2PasswordAccountStore.swift) | 服务端生成新 UUID 并插入资料；不是既有账号权限撤销入口 |
| 展示资料更新 | [PostgresV2ProfileUpdateStore](../../IMV2Server/Sources/IMV2Server/PostgresV2ProfileUpdateStore.swift)、[V2PublicIdentityAccountStore](../../IMV2Server/Sources/IMV2Server/V2PublicIdentityAccountStore.swift) | 修改名字/头像/资料修订，不修改 state、special 状态或收发权限，无需为展示变更撤销发送授权 |
| 特殊账号类型、状态及收发开关 | 当前应用无写入 special_accounts 的入口；[V2SpecialAccountMessagingService](../../IMV2Server/Sources/IMV2Server/V2SpecialAccountMessagingService.swift) 读取设置、写消息操作与审计 | 不能把“当前没有应用写者”解释成该表不可变或支持管理员在线直接修改 |

上述应用撤权入口的实际排空/缺失协调器/owner 不可达测试见[写者证据](verification-records.md#20260920-direct-authorization-policy-writers)。特权 SQL、外部部署系统对特殊账号设置的修改不在这批证据内；若增加在线管理入口，必须先阻止对应账号的新授权登记、排空 held，再修改控制事实。完整进程故障、恢复与迁移组合仍单独验收，不因写者清点完成而关闭 D07。


### 转发控制连接中断与并发撤权

正式 importForwardExport 已加入原独立子进程断连探针。先持久接收 inbox，再阻塞目标房间；导入在 owner 等锁时必须已有已提交 held 授权。探针仅终止自有单连接预留池的确切后端，随后真实拉黑通过协调器等待 owner 操作锁；房间阻塞期间不能出现 block。解除阻塞后，原转发先被接受、授权结果确认，拉黑随后提交；新普通发送拒绝，原转发缩小文本上限重放仍返回终态，消息数量与授权代次均不增加。

冷/预热转发与原普通发送共 4 场景通过，见[断连记录](verification-records.md#20260920-forward-control-connection-loss)。这是“已登记、owner 正在接受、撤权等候”这一提交顺序的证据，不代表进程 SIGKILL、登记提交之前的中断、撤权先持久中止、附带媒体状态变化或完整迁移矩阵全部通过。


### 授权提交边界的进程强杀与恢复（2026-09-20）

普通发送、双房间批量及无附件转发分别在控制登记前、登记提交后、owner 提交后控制确认前、确认完成后遭遇真实 SIGKILL，共 12 场景通过。前三个检查点由父进程持有数据库锁并确认实际等待，再终止子进程；确认后检查点由子进程写入标记后自杀。随后启动全新进程，调用实际协调器恢复，再用原 room/client 身份和转发载荷重放。

登记前中断不留下授权或消息；登记后尚未接受的授权先持久中止，重放使用第二代；owner 已提交则恢复原接受证明，保持第一代；确认后重放无需领取恢复任务。所有场景最终消息各一条、授权 accepted、恢复 deferred=0，证明数量与代次一致。批量沿用生产的原子接受及允许的标量回退策略，并在 owner 提交后检查两条消息均已落库。

详见[本轮验证记录](verification-records.md#20260920-direct-authorization-process-crash)。这是实际存储组件和数据库连接的独立进程恢复，不是完整 Gateway 网络服务的启动/强杀验收；没有覆盖附件变化、撤权先完成的相反顺序或迁移接管。D07 仍开放。


### 转发撤权先完成与迟到授权（2026-09-20）

准入等待后，真实拉黑通过协调器中止旧授权并提交。恢复准入时，旧授权迟到导入被拒绝，正式入口的新代次读取拉黑事实并返回持久拒绝。无附件及真实附件两场景通过，消息和媒体引用为零；原有 14 个场景同轮回归通过，见[验证记录](verification-records.md#20260920-forward-revocation-first)。这是确定提交顺序的证据，任意在途竞争、媒体状态变化及完整迁移仍开放。


### 转发预检后的媒体状态变化（2026-09-20）

正式导入已完成 owner 预检、等待 control 权限锁时，目标媒体被注入 expired 状态或到期时间。放行后实际接受重新检查媒体，拒绝写入，消息与媒体引用为零；控制 held 授权由到期恢复中止，双端 aborted。两个场景及原有 16 个场景通过，见[窗口验证](verification-records.md#20260920-forward-media-window)。这是精确窗口的数据库状态注入，实际媒体维护工作器与其他并发顺序仍需分别验证。


### 实际 Gateway 后台恢复生命周期（2026-09-20）

[进程探针](../../scripts/test_v2_authorization_gateway_lifecycle.py)已启动真实 IMV2ServerApp 并绑定 TLS/metrics 监听，验证启动恢复、owner 锁等待期间 SIGKILL 后重启、在途 SIGTERM 后重启恢复；正常关闭均观察到 drained=true，三个授权最终中止且消息为零。见[验证记录](verification-records.md#20260920-authorization-gateway-lifecycle)。控制与 owner 共用本机物理库、授权通过夹具预置，前台网络发送及跨库部署的进程矩阵仍未覆盖。
