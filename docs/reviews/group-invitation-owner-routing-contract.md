# 群邀请 owner 路由与 control 身份合同（B27 第二阶段）

2026-09-06。本批已替换 Account 的固定 control 库组装，接入持久 room route、owner epoch 与 control 身份读取。**B27 仍为实施中**：完整房间迁移及其历史覆盖验收尚未闭环，独立 owner 旧链接已接通[审计导入](group-invite-directory-import-contract.md)；后续持久创建恢复见[恢复合同](group-invite-creation-recovery-contract.md)；跨 owner 全局申请配额仍由 B23 跟进。

## 运行组装

`V2RoutedGroupInvitationStore` 作为现有 `V2GroupInvitationService` 的存储边界。Account 为配置中的各物理 owner 初始化池、检查 session/schema/capacity，再注册邀请 HTTP 路由；与本地媒体共用已创建的同 URL 连接池。本地媒体关闭也会初始化邀请 owner。

Account 必须显式提供 `IM_V2_ROOM_SHARD_STORES_JSON`；既有 user store 配置要求保留。单库部署也须列出实际逻辑 shard，不允许空注册表时回退到 control。仓库 local Compose 已提供 rooms-primary 的显式映射。额外数据库连接纳入既有总预算；本批没有部署或修改运行中的生产配置。

每个操作读取持久 route，再按注册表解析唯一数据库。未知 shard 抛出明确错误，没有广播、哈希重选或单物理库捷径。当前实现仅接受 `im_v2` schema，配置也拒绝其他 schema。

## Owner 事务边界

创建、撤销、提交、批准和拒绝在原有操作锁顺序内取得 room 行锁，并核对 `room_shard_id` 与 `owner_epoch`。**包括成功操作的重放，也必须先通过 owner fence**。读列表、预览和待审批页在独立只读工作事务中持有 room 共享锁，直到授权及结果读取完成；迁移/角色变更的 room 写锁不能越过这个读点。

创建前先在 owner 预检查当前角色或原创建操作，避免无权限/不存在房间的请求占用持久 intent。随后 prepare → owner commit → finalize，实际 owner 提交再次授权并检查 epoch，不把预检查当作授权凭证。原操作的匹配重放仍保持原链接 ID/时间。独立 owner 已有旧链接但缺目录时也沿用原绑定，失败恢复及冲突边界见[兼容合同](group-invite-legacy-binding-contract.md)。

仅 token 的 preview/submit 先查 control ready 目录，得到 inviteID/roomID，再路由到当前 owner；owner 同时核对目录的 invite 与 room 绑定。管理列表只返回 ready 目录已有的链接，采用一次有界批量读取；owner 已提交而目录 finalize 失败的链接不会提前返回可用 token，创建重试负责完成它。

目录成功不是有效性证明；撤销、过期、成员状态和额度全部由 owner 当前记录判断。错误 owner、旧 epoch 和已过期缓存均失败，不向另一数据库重试业务写入。Account 的生产路由器直接读取 PostgreSQL 目录；缓存路由器仅用于验收 stale route 的阻断。

## Control 身份与展示

`PostgresV2GroupInvitationIdentityReader` 一次读取至多 100 个身份，返回 public identity 与 active 状态。active 要求 profile.state=active 且无 account_disables。创建/撤销/列表/提交等操作在 owner 事务开始前取当前 actor 状态；批准先读取不可变 applicant ID，再从 control 读取 reviewer/applicant 状态，进入 owner 事务后核对 applicant ID 并传给共享成员变更函数。

Owner 仍在真实事务内执行成员、角色、权限、revision、容量和旧 operation fence 校验。身份快照不代表跨数据库全局可串行化：停用发生在快照之后的竞态仍依赖既有账号认证/会话阻断合同；本批没有声称跨库原子账号停用。

Owner SQL 不再 JOIN public_user_profiles 或 account_disables。申请行只有 applicant UUID；事务提交后再到 control 取展示资料，待审批页批量取资料，避免持有 owner 连接再请求 control 连接池。后置资料读取失败可能发生在业务已经提交之后，客户端须按原 operation 重试；决策事实仍由 owner 持久回执决定。

新审批拒绝已停用目标且不产生任何成员/事件效果；已提交审批的精确重放可读取原结果，不重新加人。新操作仍要通过当前 reviewer 状态与角色。账号禁用不会删除 owner 申请历史。

## Schema 23

`20260906_group_invitation_owner_identity.sql` 要求 current-22，事务内删除链接 creator/revoker、申请 applicant/reviewer 指向 public_user_profiles 的四个外键，再推进到 23。不复制或删除历史数据，room/invite/request 的本地关系约束保留。迁移前停止旧邀请写进程；旧程序仍依赖 owner profile JOIN，不能在本迁移后混合运行。

Swift 与 SQL readiness 除完整旧合同外，还拒绝 invite/request 对 profile 或 account_disables 的外键依赖，包含 NOT VALID 外键。物理 owner 目前仍使用统一 schema（空身份表存在），无需复制身份行。

## 验证及剩余范围

见[路由证据](../../docs/reviews/verification-records.md#20260906-routed-invitation)：最终 29 项测试 / 3 套件通过，22→23 数据保留迁移及完整 readiness 负例通过。三库测试将 control 与两个 room owner 分开，control 没有 rooms/memberships/requests，两个 owner 的 public_user_profiles 均为空；同时覆盖 standard fanout 和 large-group hybrid。正常流程、创建 finalize 中断、控制资料更新、停用目标/审核人、原决策重放、未知或错误物理 owner、真实持久 epoch 不一致、缓存 stale 及 Vapor 状态边界均纳入测试。

Vapor 测试使用确定的测试 authenticator，**不是**真实 TLS/账号登录端到端验证。测试中的 epoch 改变也**不是**完整房间在线迁移。启用跨物理迁移前仍须转移完整成员历史区间、D05 不可变审计/旧 operation 阻断、邀请/申请/成员回执及相关事件与 outbox，并验证旧 owner 的迟到操作无法重新落地。历史覆盖不足时不得依靠缺失记录释放 legacy approving。

B23 的 20 条申请配额目前仍是单 owner 事务保护；不能把本批多 owner 功能通过视为全局配额已完成。prepared intent 已接入持久后台恢复，见[恢复合同](group-invite-creation-recovery-contract.md)；历史目录的分页导入已接通独立 operator，见[导入合同](group-invite-directory-import-contract.md)。

普通成员变更已补路由 epoch 传递和回执重放前的事务栅栏，含单库组装；完整迁移执行器及其他房间写入栅栏仍开放，见[成员栅栏合同](room-membership-owner-fence-contract.md)。
