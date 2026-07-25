# Durable-work operator replay runbook

状态：已实现受认证的单目标 replay 控制面；paused/metrics-unavailable/fan-out-failure
告警规则已入库，实际 Alertmanager receiver、审计保留策略和容量阈值仍需由运维负责人批准。

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

唯一的操作是 `POST /internal/v2/durable-work/replay`。一次请求最多重放一条已
暂停 durable row，且必须带新的 UUID `operation_id`、封闭的原因码和精确目标。
它不提供批量 replay、SQL、自由文本、按 room/user 扫描或查询任意消息的能力。
服务在同一 PostgreSQL 事务中写入 audit 记录、将 `paused` 行重置为 `pending`、
清理 lease/退避字段并将 retry budget 归零。若行并未暂停，则返回
`not_paused` 并同样记录结果；它绝不会把工作标为 terminal/skipped。

## 触发条件与处置

1. `IMV2PausedRoomOutbox` 或 `IMV2PausedFanoutDelivery`（对应
   `im_v2_room_outbox_backlog{state="paused"}` / 
   `im_v2_fanout_delivery_backlog{state="paused"}` 大于零）持续两分钟时创建 incident。
   规则和 role owner 见
   [`observability.md`](observability.md)；不能静默、snooze 后忘记或以容量理由提高该零阈值。
2. 先修复根因（PostgreSQL、broker、路由或依赖服务），并确认没有正持续失败；
   replay 不是跳过损坏数据或绕开 admission 的工具。
3. 从受控数据库调查或既有 incident evidence 获取**精确**的 source event，及
   delivery 所需的 target user / projection kind。不要把数据库查询结果、用户 ID
   或 bearer token 粘贴进工单公开字段。
4. 经 bastion/mTLS proxy 调用 loopback service。示例 body（token 仅从 secret
   manager 注入 shell，禁止回显、记录或放进历史）：

```json
{
  "operationID": "new-uuid-per-attempt",
  "targetKind": "fanout_delivery",
  "sourceEventID": "source-event-uuid",
  "targetUserID": "target-user-uuid",
  "projectionKind": "message_created",
  "reason": "dependency_recovered"
}
```

`targetKind: "room_outbox"` 时只能传 `sourceEventID`；不得附带 target user 或
projection kind。可用原因码仅为 `dependency_recovered`、`data_repaired`、
`false_positive`。

5. 记录 `operationID` 于 incident。网络重试必须复用同一 UUID：服务返回同一
   outcome 并标记 `wasIdempotent: true`。同一 UUID 搭配不同目标/原因返回冲突，
   必须停止并调查，不能改写审计历史。
6. `requeued` 后观察 paused gauge 下降、scheduled/ready 工作重新流动，以及最终
   fan-out plan/outbox 的正常完成。`not_paused` 表示操作当时无 paused 行；先刷新
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
