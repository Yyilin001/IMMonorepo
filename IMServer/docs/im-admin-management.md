# IM Admin Management

后台管理采用 Web 管理台 + Admin API，不放进 iOS 客户端。iOS 客户端只承载普通用户与群管理能力，避免把高风险管理凭据和审核工作流带入用户端发布包。

## Runtime

- 管理后台只注册在 `command-api` 或本地 `combined` 角色。
- `gateway`、`query-api`、`outbox-relay`、`stream-consumer`、`ops` 不承载后台管理入口。
- 生产默认关闭：`IM_ADMIN_API_ENABLED=false`。

## Configuration

开发环境默认可打开 `/admin`，如果设置了 `IM_ADMIN_SHARED_SECRET`，所有 `/admin/api/*` 请求都必须带 secret。

生产开启后台时必须显式配置：

```env
IM_ADMIN_API_ENABLED=true
IM_ADMIN_SHARED_SECRET=<至少 32 字符的独立强随机密钥>
```

`IM_ADMIN_SHARED_SECRET` 必须和 `IM_INTERNAL_SHARED_SECRET` 不同。生产环境建议再叠加：

- 管理后台域名独立，例如 `admin.example.com`。
- 只允许 VPN、堡垒机或固定办公 IP 访问。
- 反向代理层增加 HTTPS、基础访问控制和审计日志。
- 不要把 `/admin` 暴露在客户端 API 域名的公网通配路径下。

## Routes

- `GET /admin`: 静态 Web 管理台页面。
- `GET /admin/api/overview`: 用户、在线 session、举报概览。
- `GET /admin/api/me`: 当前后台身份、角色和已授予权限。
- `GET /admin/api/users`: 用户列表，支持 `query`、`status`、`cursor`、`limit`。
- `GET /admin/api/users/:userID/security`: 用户会话与推送设备安全概览，仅 `super_admin`；不返回 refresh nonce 或完整推送 token。
- `PATCH /admin/api/users/:userID/status`: 更新用户状态；封禁会撤销该用户全部 session，必须携带 `Idempotency-Key`。
- `PATCH /admin/api/users/:userID/admin-role`: 授予、变更或移除后台角色，仅 `super_admin` 可用，必须携带 `Idempotency-Key`。
- `GET /admin/api/conversations/:conversationID`: 会话元数据和成员状态检查；使用会话 shard 的强一致读库，不返回消息正文。
- `GET /admin/api/conversations/:conversationID/messages`: 受控分页消息内容检查，仅 `super_admin`；每次读取都会审计，但审计 metadata 不含消息正文或媒体 URL。
- `GET /admin/api/reports`: 举报列表，支持 `status`、`targetType`、`cursor`、`limit`。
- `GET /admin/api/reports/queue`: 活跃举报队列，支持 `scope=unassigned|mine|all`、`status=pending|reviewing`、`cursor`、`limit`；返回积压数量与最早等待时长。
- `PATCH /admin/api/reports/:reportID`: 处理举报状态并记录不可变审核决策；必须携带 `Idempotency-Key`。
- `PATCH /admin/api/reports/:reportID/reviewer`: 领取、改派或取消举报审核人，必须携带 `Idempotency-Key`。
- `GET /admin/api/reports/:reportID/decisions`: 查看举报的审核决策历史。
- `GET /admin/api/reports/:reportID/evidence`: 查看受控审核证据。
- `POST /admin/api/reports/:reportID/evidence`: 新增不可变审核证据；必须携带 `Idempotency-Key`。
- `GET /admin/api/audit-events`: 后台审计日志，支持精确 `action`、`actor`、`targetType`、`targetID`、`requestID` 及 ISO-8601 `from`/`to` 时间范围过滤。

API 支持两种认证方式：

1. 管理员账号 access token。先使用普通登录链路获得 access token，服务端根据 `users.admin_role` 授权；该方式会以账号邮箱作为审计操作者。
2. 独立共享密钥。用于首个管理员授予、故障救援和自动化；该方式默认是 `super_admin`，审计操作者来自 `X-IM-Admin-Actor`。

管理员 access token：

```http
Authorization: Bearer <access-token>
```

共享密钥：

```http
X-IM-Admin-Secret: <IM_ADMIN_SHARED_SECRET>
X-IM-Admin-Actor: <operator-name>
```

共享密钥也支持 `Authorization: Bearer <IM_ADMIN_SHARED_SECRET>`。内置 Web 管理台默认使用管理员 access token，可切换为应急密钥。
管理台只在当前页面内存中保留所填凭据，不会写入浏览器存储。

## Roles

| Role | Granted permissions | Intended operator |
| --- | --- | --- |
| `super_admin` | All management actions, including user status, role assignment, security inspection, conversation/message inspection and audit export | Platform owner / security operator |
| `moderator` | Read and process reports | Content moderation operator |
| `support` | Read overview, users and conversation metadata/member state; cannot read message bodies | Customer support operator |

角色变更会使该用户所有活跃会话的认证缓存失效；下一次后台请求会重新从数据库读取角色。服务端始终做权限检查，Web 管理台的按钮隐藏只用于减少误操作，不能作为安全边界。

## Audit

后台写操作会落 `admin_audit_events`：

- `user.status.update`
- `report.status.update`
- `report.reviewer.assign`
- `report.evidence.add`
- `user.admin_role.update`

审计记录包含操作者、动作、目标类型、目标 ID、请求 ID、来源 IP、简短 metadata 和创建时间。
处理说明保存在受权限保护的举报决策历史中；通用审计 metadata 只记录说明是否存在及长度，不复制说明正文。

## Moderation Workflow

举报从 `pending` 可以进入 `reviewing`、`resolved` 或 `rejected`；`reviewing`
只能进入 `resolved` 或 `rejected`。终态不能回退，避免覆盖已经完成的审核
结论。

完成处理时必须提供不超过 500 字符的处理说明，以及一个受限分类：

- `action_taken`
- `duplicate`
- `escalated`
- `no_violation`
- `other`

每次合法转换都会写入 `report_moderation_decisions`，包含前后状态、审核人、
管理员角色、认证方式、请求 ID、分类、说明和时间。管理员 API 与内部审核入口
共用同一状态机，因此不会出现只有当前状态被更新而没有历史的路径。

审核员可领取尚未分配的举报，但不能抢占其他审核员的任务，也不能把任务改派给
其他账号。`super_admin` 可以分配、改派或取消分配；目标账号必须是状态正常的
`moderator` 或 `super_admin`。终态举报不可改派。当前负责人直接写入举报读模型，
每次分配变动同时写入 `report.reviewer.assign` 审计事件。

## Operations Queue And Audit Search

举报页默认展示未分配的活跃待办，可切换到当前审核员的待办或全部活跃举报；
`history` 才会访问包含终态的普通举报列表。队列只接受 `pending`、`reviewing`
状态，按创建时间从早到晚返回，并给出待处理、审阅中、未分配数量以及最早待处理
时长，便于按积压和等待时间安排审核。

共享密钥没有具体账号身份，不能访问 `scope=mine`。审计查询使用精确字段和有索引的
时间范围，不提供通用 metadata 模糊搜索，避免后台页面触发无界扫描或意外检索出敏感
内容。

## User Security Inspection

`super_admin` 可以查看用户的设备会话和推送设备状态，用于排查异常登录、设备切换和
推送问题。返回内容仅包括设备名称、平台、版本、最后活跃时间、会话撤销状态，以及
推送 token 的最后 8 个字符；`current_nonce`、`previous_nonce`、refresh token 和完整
APNs token 永远不会进入响应、管理台 DOM 或审计 metadata。每次查看会写入
`user.security.inspect` 审计事件，记录数量而非设备凭据。

证据必须是无用户名和密码的 HTTPS URL，最长 2048 字符，标签最长 120 字符。
完整链接保存在受权限保护的证据表中；通用审计只保留链接主机和标签长度，避免
把临时签名参数复制到日志。

## Conversation And Message Inspection

会话检查用于支持排障和审核关联定位。`conversations.inspect` 返回会话类型、标题、
公告、禁言状态、成员角色、账号状态、可见范围和已读序列，并以会话 ID 路由至对应
conversation shard 的强一致读库。会话事实、成员关系和消息时间线读取 shard；成员和
发送者身份资料统一由主库用户目录补齐，不信任 shard 内可能陈旧的用户副本。分页成员
检查不会依赖用户侧 summary 投影，因此不受异步投影延迟影响。

`messages.inspect` 是更高风险权限，只授予 `super_admin`。它按 timeline sequence
倒序分页返回 canonical message 内容和派生状态，以便处理合规事件；普通 support 和
moderator 永远不能调用。`conversation.inspect` 与 `conversation.messages.inspect` 都会
写入 `admin_audit_events`，只记录目标会话、页大小和游标，不记录消息正文、媒体 URL、
访问 token 或完整推送凭据。

跨 conversation shard 的强制群治理操作遵循
[admin-cross-shard-governance.md](admin-cross-shard-governance.md) 的异步命令与回执模型；
不能使用主库审计表和 shard 会话表之间的伪事务同步写入。

当前可用的群治理操作均仅限 `super_admin`：`group.mute_all.set` 可设置或解除全员禁言，
`group.member.remove` 可强制移除非群主成员，`group.lifecycle.set` 可冻结或解冻群。三者都通过
`POST /admin/api/conversations/:conversationID/governance-commands` 必须携带
`Idempotency-Key` 和非空 `reason`；禁言操作携带目标 `muteAll`，成员移除还必须携带
`memberUserID` 与 `confirmed: true`，冻结携带 `groupLifecycleState: "frozen"` 与
`confirmed: true`，解冻携带 `groupLifecycleState: "active"`，解散携带
`groupLifecycleState: "dissolved"` 与 `confirmed: true`。接口只返回 `202 Accepted`；使用
`GET /admin/api/conversations/:conversationID/governance-commands/:commandID` 查询最终状态。
由 `IMOpsCommand --process-admin-governance-commands` 将命令路由到目标 shard，写入唯一的
action-specific Outbox 事件后再回写 `applied` 审计。管理原因不会出现在响应、Outbox payload
或通用审计 metadata 中。

冻结是可逆的群隔离状态：成员仍能读取、同步已读、离开群和撤销既有邀请；普通用户不能发送、
转发或启动 AI 流消息，也不能修改群资料、成员、邀请或消息内容。解散是不可逆的只读历史归档：
消息、媒体和成员关系不会由该命令删除，现有成员可继续读取和执行个人隐藏/收藏/清空，但不能
离开、重新加入或恢复群。客户端从会话摘要的 `groupLifecycleState` 收敛状态；实时
`metadata_updated` 仅触发刷新。

### Write Idempotency

对外可重试的用户状态、角色、举报审核人、举报决策和证据写入必须提供
`Idempotency-Key` 请求头。键只允许
ASCII 字母、数字、`-`、`.`、`:` 和 `_`，最长 128 字符；通用管理写操作的唯一范围是
同一操作者、动作和键，举报决策与证据则在对应举报内独立去重。
同一个操作者在同一动作中以完全相同的请求重试时，服务端返回已保存的结果，不再
新增状态变更或审计事件。若同一键携带不同的状态、角色、审核人、说明、分类、链接
或标签，服务端返回 `409 Conflict`。管理端通用命令只保存请求的 SHA-256 摘要，避免把
说明正文等敏感输入复制到幂等记录；内置 Web 管理台会为每次写操作自动生成键，API
调用方必须在网络超时重试时复用原键，而不是生成新键。

## Current Scope

第一版覆盖最小生产闭环：

- 管理入口和用户客户端分离。
- 独立 admin secret。
- 用户查询、封禁、恢复。
- 封禁自动撤销登录 session。
- 举报查询和状态处理。
- 举报状态机、处理分类与不可变审核决策历史。
- 审核人领取和超级管理员改派控制。
- 受控 HTTPS 审核证据与可重试写操作的幂等键。
- 活跃举报队列、积压年龄摘要和可定位的审计事件检索。
- 仅超级管理员可访问的用户设备与会话安全概览，含凭据脱敏和审计。
- 支持人员可检查会话元数据与成员状态；消息正文检查仅限超级管理员，并走会话 shard 强一致读取和审计。
- 写操作审计。
- 管理员账号角色和最小权限矩阵；共享密钥只作为应急根权限。

后续再补：

- 管理员 MFA、短会话和设备/IP 风险校验。
- 更细粒度 RBAC、组织/租户边界及审批流。
- SLA 队列和审核工作负载视图。
- 更完整的消息、群组、设备、推送和风控管理页。
