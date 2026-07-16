# Admin Cross-Shard Governance Commands

## Purpose

后台对群的强制操作，例如全员禁言、恢复发言、冻结、解冻和解散群，不能把会话写入
conversation shard、幂等记录和 `admin_audit_events` 当作一次跨数据库事务。主库和
conversation shard 在多 shard 部署中是独立数据库，直接同步写会留下“群已变更但没有
审计”或“审计已记录但群没有变更”的不可恢复状态。

本设计将强制群治理建模为一个可查询、可重放的异步命令。当前实现操作是
`group.mute_all.set`、`group.member.remove` 与 `group.lifecycle.set`。

## Invariants

1. API 受理、请求幂等和 `command.accepted` 审计在主库的同一事务内完成。
2. 会话变更、shard 内去重记录和全部用户可见 Outbox 事件在目标 shard 的同一事务内完成。
3. 命令在受理时绑定 `cell_id`、`shard_id` 与 `route_version`；执行前必须重新校验三者，路由变化时以 `route_changed` 失败，不能把旧命令执行到迁移后的会话路由。
4. 任一阶段失败可安全重试；同一管理命令不会重复变更群状态，也不会重复发出用户可见的 Outbox 事件。
5. 中心命令状态是 shard 事实的可恢复投影，而不是唯一事实来源。
6. 管理原因只存入受控命令记录和审计；不得写入群公告、消息 payload、Prometheus label 或实时事件。

## Data Model

主库增加 `admin_conversation_governance_commands`：

- `id`：UUID，命令关联键。
- `action`：例如 `group.mute_all.set`。
- `conversation_id`、`target_cell_id`、`target_shard_id`、`target_route_version`：命令受理时的不可变目标路由绑定。
- `actor`、`actor_user_id`、`actor_role`、`authentication_method`。
- `request_digest`、`idempotency_key`、`reason`。
- `requested_mute_all`：全员禁言治理目标值，不保存消息正文。
- `requested_group_lifecycle_state`：群生命周期治理目标值：`active`、`frozen` 或
  `dissolved`。`dissolved` 必须显式确认，且一旦 shard 应用后不可恢复为其他状态。
- `target_member_user_id`、`destructive_confirmed`：成员移除目标与二次确认事实；移除群主和移除后少于两人的群会被拒绝。
- `status`：`pending`、`applying`、`applied`、`failed`。
- `attempt_count`、`last_error_code`、`processing_token`、`processing_started_at`、`accepted_at`、`applied_at`。

唯一键为 `(actor, action, idempotency_key)`；重复键必须比对目标会话和请求摘要，输入不同返回 `409`。

每个 conversation shard 使用现有 `conversation_domain_event_side_effects` 作为持久化
inbox/应用回执，键为 `admin-governance:<command-id>`，值为本次变更产生的
`outbox_event_id`。该记录与群状态变更、`metadata_updated` domain event 在同一 shard
事务中创建；重试先读取该键并复用既有 Outbox 事件，不会再次 mutation 或投递。
它不复制管理原因或消息内容。

## Execution Flow

```text
Admin API
  -> primary transaction:
       governance_command(pending) + admin_audit_event(command.accepted)
  -> 202 Accepted + command status URL

Governance worker / ops command
  -> atomically claim pending or expired-applying primary command with a 5 minute lease
  -> resolve current conversation route
  -> compare cell/shard/version with accepted route binding
       mismatch -> command(failed, route_changed) + command.failed audit, no shard write
       remote cell -> command(failed, remote_cell) + command.failed audit, no local shard write
  -> shard transaction:
       lock/read inbox application
       mutate Conversation
       create inbox application
       enqueue action-specific Outbox events with a side-effect key
  -> primary transaction, only when the processing token still matches:
       command(applied) + admin_audit_event(command.applied)
```

当前本地运维入口为：

```bash
swift run --package-path IMServer IMServer --role ops --process-admin-governance-commands --limit 200
```

该命令会处理 `pending` 和处理租约过期的 `applying` 命令。每次领取写入不可预测的处理令牌；只有
当前令牌持有者可以把命令收敛到 `applied` 或 `failed`，迟到 worker 不得覆盖新的处理结果。`failed` 命令保留错误码和失败审计供人工
排查，不能在未知失败原因下自动无限重试；确认故障原因后可显式再次调用对应处理器或
在后续运维界面中提供受审计的重试动作。

若 worker 在 shard 提交后、主库状态回写前崩溃，下一次重试先读取 shard inbox，取得
已应用的 `outbox_event_id`，再补写主库 `applied` 状态和审计。若 worker 在主库受理后
崩溃，pending 命令可被重新 claim。不会以“重试时重新执行 mutation”的方式恢复。

## Authorization And API Shape

- 新权限：`conversations.write_governance`，仅 `super_admin`。
- API：`POST /admin/api/conversations/:conversationID/governance-commands`。
- `Idempotency-Key` 和非空 `reason` 必填；reason 最大 500 字符。
- 禁言请求示例：`{ "action": "group.mute_all.set", "muteAll": true, "reason": "abuse containment" }`。
- 移除成员请求示例：`{ "action": "group.member.remove", "memberUserID": "<uuid>", "confirmed": true, "reason": "abuse containment" }`。
- 冻结请求示例：`{ "action": "group.lifecycle.set", "groupLifecycleState": "frozen", "confirmed": true, "reason": "incident containment" }`；解冻将目标改为 `active`，不需要二次确认。
- 解散请求示例：`{ "action": "group.lifecycle.set", "groupLifecycleState": "dissolved", "confirmed": true, "reason": "permanent closure" }`；解散是不可逆操作，API 不接受之后的 `active` 或 `frozen` 请求。
- `group.member.remove` 必须带 `confirmed: true`，不允许移除群主；执行时为被移除者写入 `conversation_removed_for_user`，并为剩余成员写入 `membership_removed`。
- 冻结是可逆的隔离状态，不是删除：成员仍可读取时间线、执行已读和个人可见性操作、离开群，以及撤销既有邀请。普通用户不能发送、转发或启动 AI 流消息，也不能编辑、撤回、添加表情回应、修改群资料/成员资料、创建邀请、加入群、添加/移除成员或修改角色。管理员治理命令可解除冻结或移除成员。
- 解散是不可逆的只读历史归档：不删除既有消息、媒体或成员关系，现有成员仍可读取历史并执行个人隐藏、收藏或清空；不能离开、重新加入、发送、转发、启动 AI 流、修改资料/成员/邀请，也不能再调整全员禁言或移除成员。恢复、保留期到期的物理删除和媒体清理不属于该命令，必须由独立的数据保留流程执行。
- 生命周期变化写入 `metadata_updated`。TCP 事件只作为失效提示；客户端必须随后从 HTTP 会话摘要读取 `groupLifecycleState`，不得依赖实时 payload 携带完整生命周期状态。
- 仅群聊可接受该操作；私聊返回 `400`。
- API 不同步声称变更已生效；只有命令状态为 `applied` 才表示 shard 已提交并已写入 Outbox。

## Local Verification

1. 受理命令后，主库有一条 pending 命令和一条 accepted 审计。
2. worker 应用后，群 `mute_all` 已变更，shard side-effect 回执只存在一条记录，且只有一条
   `metadata_updated` domain event。
3. 同键同输入重试返回同一 command；同键不同输入返回 `409`。
4. 模拟 shard 提交后主库回写失败，再次执行 worker 必须收敛为 applied，且不重复 Outbox。
5. `support`、`moderator` 不能受理或查询其他高风险命令；审计 metadata 不含 reason 正文以外的敏感 payload。
6. 配置两个本地 SQLite conversation shard，验证命令准确路由至目录记录指定 shard。
7. 在命令受理后递增 `conversation_directory.route_version`，worker 必须以 `route_changed` 失败，且不能创建 shard side-effect 或 Outbox。
8. 将命令标记为带有未过期处理令牌的 `applying` 后，新的 worker 必须跳过；令牌超过 5 分钟后，下一次扫描必须安全接管并依靠 shard side-effect 回执收敛为 `applied`。
9. `group.member.remove` 未带确认必须被 API 拒绝；确认后只删除目标成员一次，并产生一条被移除者的会话删除事件和一条剩余成员的 membership 事件。
10. 设置 `IM_POSTGRES_SMOKE_DATABASE_URL` 后运行 Postgres smoke；两个独立 worker 必须只能有一个领取同一 pending 命令，命令最终只失败一次并只有一条 failed 审计。该检查覆盖生产使用的 `FOR UPDATE SKIP LOCKED` 路径。
11. `group.lifecycle.set` 冻结必须带 `confirmed: true`；冻结后摘要投影返回 `groupLifecycleState=frozen`，普通消息、转发和 AI 流消息均被拒绝。解冻后这些入口恢复可用。
12. `group.lifecycle.set` 解散必须带 `confirmed: true`；解散后摘要投影返回 `groupLifecycleState=dissolved`，历史和成员关系保留为只读，任何恢复、禁言或成员移除命令必须拒绝。

仓库中的 `adminGovernanceCommandRoutesToIndependentLocalConversationShard` 覆盖第 6 项：
主库只保存命令和审计，目标群、side-effect 回执与 Outbox 事件只存在第二个 SQLite
数据库。它验证路由和事务边界，不代表已完成生产多库数据复制。

`adminGovernanceCommandFailsWhenAcceptedRouteVersionChanges` 覆盖第 7 项。它模拟会话迁移
开始后目录版本变化，证明已受理的旧命令会停止而不是写入一个未经重新确认的路由。

## Rollout Constraint

所有 conversation shard 必须已经完成其既有 `conversation_domain_event_side_effects`、
`conversation_domain_events` 与 sequence migration，并通过 schema validator，才允许开启
写接口。当前仓库只自动注册主库和 summary shard migrations；conversation shard migration
的运行与验证需要在部署编排中明确覆盖，不能依赖单 shard 本地模式的偶然成功。

仓库中的跨 shard 回归使用不含 `users` 表的 SQLite conversation shard，覆盖后台会话检查、
用户成员列表和直聊摘要。 `conversation_members.user_id` 与 `im_messages.sender_user_id`
已定义为逻辑用户引用：用户存在性、状态与资料只从主库用户目录解析，conversation shard
不复制密码或用户资料。

新建 conversation shard 的建表迁移不再创建这两个外键；已有 PostgreSQL shard 通过
`RemoveConversationUserForeignKeys` 发现并移除指向 `users` 的旧外键。该迁移不会自动注册到
conversation shard，部署编排必须在每个 shard 上由 `ops` 显式执行，并在切换路由前完成 schema
validator、回归和备份验证。
