# Durable-work operator replay runbook

状态：单目标和按事件重放已改为可靠个人事件词表；旧房间发件箱和公共消息扇出不再接受重放。
个人事件队列已接入独立来源库指标与暂停/停滞告警规则；实际告警接收配置和演练仍需验证。

`IMV2OperatorServerApp` 是独立的 loopback-only 进程。它只监听
`127.0.0.1` 或 `::1`，不复用公网 TLS gateway、账户服务或任意终端用户 token。
部署者必须在受管 bastion 或 mTLS-authenticated operator proxy 后访问它；不得把
`9445` 或任何 operator listener 直接发布到互联网或集群业务入口。

## 认证与最小权限

从受控 secret manager 注入
`IM_V2_OPERATOR_REPLAY_BEARER_TOKEN_BASE64`（至少 32 个随机字节的 Base64）和
稳定的 `IM_V2_OPERATOR_REPLAY_PRINCIPAL`。该值只能用于这个 operator process；
它不是用户 access token、refresh credential 或 gateway HMAC key。使用模板
[`operator-replay.env.example`](../../../IMV2Server/operator-replay.env.example) 配置。

两个操作：`POST /internal/v2/durable-work/replay`（单目标）与
`POST /internal/v2/durable-work/replay-event`（按来源事件的批量）。单目标一次请求最多
重放一条已暂停 durable row，且必须带新的 UUID `operation_id`、封闭的原因码和精确目标；
批量只回放**指定的那一个事件**下的暂停行，并且强制行数上限。两者都不提供 SQL、自由文本、
按 room/user 扫描或查询任意消息的能力。
服务在同一 PostgreSQL 事务中写入 audit 记录、将 `paused` 行重置为 `pending`、
清理 lease/退避字段并将 retry budget 归零。若行并未暂停，则返回
`not_paused` 并同样记录结果；它绝不会把工作标为 terminal/skipped。

## 按来源事件批量重放

同一个事件可能对应多条暂停行（例如一次成员变化通知多个用户）。逐行重放会让
"修好根因"之后的收尾变成大量人工调用，因此提供按事件的有界批量：

```json
{
  "operationID": "new-uuid-per-drain-step",
  "targetKind": "user_state_event",
  "sourceShardID": "room-a",
  "sourceEventID": "source-event-uuid",
  "reason": "dependency_recovered",
  "limit": 64
}
```

响应是 `{ operationID, requeued, notPaused, hasMore }`。

- **选择面精确**：只有这一个事件；顺序稳定（个人事件按目标用户、投影类型排序），没有扫描、
  筛选、正则或自由文本。`limit` 落在 `1...500`。
- **排空语义**：`hasMore=true` 表示该事件还有超出本批上限的暂停行，用**同一个**
  `operationID` 继续调用即可推进；已经重放过的行由派生的行级审计挡住，不会重复重放。
  直到 `hasMore=false` 且 `requeued=0` 即为取尽。
- **逐行审计**：每一行都有自己的审计记录（操作标识由批量标识与目标身份稳定派生），
  形状与单目标重放完全一致，因此 `source_event_id` + `requested_at` + `operator_principal`
  即可把一次事故对应的重放全部找回来。
- **类型限制**：只接受按事件定位工作的类型（`user_state_event`、
  `content_review`、`media_scan`、`media_purge`）。`read_receipt_preference_propagation`
  与 `user_projection` 是按用户定位的，批量语义不明确，必须继续走单目标接口。
- **同样的边界**：批量不会跳过损坏数据、不会把工作标为终态，也不绕过 admission。
  它只是把"同一个事件下的多行"一次推进有界的一批。

## 触发条件与处置

1. 确认来源库 `user_state_event_outbox` 的暂停事件及持续未完成事件。
   瞬时故障继续退避重试；确定性数据错误进入暂停。队列计数、最老未完成年龄的
   对应告警分别为 `IMV2PausedUserStateEvent` 和 `IMV2StalledUserStateEvent`，参见 [`observability.md`](observability.md)。
   内容审核、媒体扫描/清理、回执偏好传播和用户投影继续使用各自的暂停告警。
2. 先修复根因（PostgreSQL、broker、路由或依赖服务），并确认没有正持续失败；
   replay 不是跳过损坏数据或绕开 admission 的工具。
3. 从受控数据库调查或既有 incident evidence 获取**精确**的 source event，及
   个人事件所需的来源分片、target user / projection kind。不要把数据库查询结果、用户 ID
   或 bearer token 粘贴进工单公开字段。
4. 经 bastion/mTLS proxy 调用 loopback service。示例 body（token 仅从 secret
   manager 注入 shell，禁止回显、记录或放进历史）：

```json
{
  "operationID": "new-uuid-per-attempt",
  "targetKind": "user_state_event",
  "sourceShardID": "room-a",
  "sourceEventID": "source-event-uuid",
  "targetUserID": "target-user-uuid",
  "projectionKind": "membership",
  "reason": "dependency_recovered"
}
```

`user_state_event` 必须携带 `sourceShardID`，其值必须是
`IM_V2_ROOM_SHARD_STORES_JSON` 中已配置的来源房间分片。单目标还必须携带用户和
个人事件类型（例如 `membership`、`timeline_activity`）；公共 `message` 等类型无效。
省略或指定未知分片返回 400，不会回退控制库。其他工作类型不允许传 `sourceShardID`。
来源库内的暂停恢复与审计属于同一个事务，重放后仍由正常 worker 完成目标路由和投影。

`targetKind` 为 `content_review`、`media_scan` 或 `media_purge`
时只能传 `sourceEventID`（媒体类型中该字段承载 opaque media UUID）；不得附带
target user 或 projection kind。`targetKind` 为
`read_receipt_preference_propagation` 时，`sourceEventID` 必须是偏好操作 UUID，
`targetUserID` 必须是该操作的 actor，且不得附带 projection kind。可用原因码仅为 `dependency_recovered`、`data_repaired`、
`false_positive`。

`targetKind` 为 `user_projection` 时，必须先修复/恢复 checkpoint 的精确
`failed_sequence` 所指向 payload；`sourceEventID` 必须匹配该 log row，`targetUserID`
必须是 paused checkpoint 的用户，且不得附带 projection kind。该 replay 只清零失败预算并
恢复 ready，不会跳过 poison sequence。

5. 记录 `operationID` 和来源分片于 incident。个人事件的审计与幂等范围是来源库；
   网络重试必须保持 `sourceShardID` 和 UUID 不变：服务返回同一
   outcome 并标记 `wasIdempotent: true`。同一 UUID 搭配不同目标/原因返回冲突，
   必须停止并调查，不能改写审计历史。
6. `requeued` 后观察 paused gauge 下降、scheduled/ready 工作重新流动，以及最终
   个人事件投影与来源确认的正常完成。`not_paused` 表示操作当时无 paused 行；先刷新
   调查证据，切勿循环提交新 UUID。

## 审计与发布控制

每个提交的请求在 `im_v2.durable_work_replay_audit` 中保留 operation ID、配置的
operator principal、目标种类/标识、封闭原因、时间和结果。operator proxy/bastion
必须另外保留已认证的人或工作负载身份及审批记录；该身份不接受客户端 JSON，避免
伪造或把 PII 写入业务审计表。

发布前必须验证：operator service 仅绑定 loopback；其 bearer secret 与 gateway /
account secrets 不同；mTLS/bastion policy 已生效；paused-gauge 告警已路由到
`im-v2-platform-oncall` 的实际 receiver；以及
至少一次受控 replay 演练使用了本 runbook。该演练和告警阈值仍是 ADR-010 的发布
证据，不因代码存在而自动通过。
