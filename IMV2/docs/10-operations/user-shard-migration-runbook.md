# User-shard migration runbook

状态：代码提供单用户 copy/verify、cutover、retention-window rollback 与到期
source cleanup；真实独立数据库拓扑、网络故障演练、read fallback 和容量批准仍是
发布前证据，不能由本 runbook 替代。

所有迁移请求只可经 `IMV2OperatorServerApp` 的 loopback listener，通过受管
bastion 或 mTLS operator proxy 发起。不得发布该端口、复用用户 token，或在请求
body 中携带数据库 URL、SQL、批量 user 范围或事件内容。

## 准备与准入

1. 为 gateway 和 operator 配置同一份 `IM_V2_USER_SHARD_STORES_JSON`。每项仅含
   逻辑 `bucket`、`database_url` 和受限格式的 `schema`；启动会验证各 schema，
   映射不得写入工单、日志或 API body。
2. 确认 operator listener 为 `127.0.0.1` 或 `::1`，bearer secret 与 gateway/
   account secret 独立，且 access proxy 的人/工作负载审计已启用。
3. 选定**一个** user、source bucket、target bucket、当前 router epoch 和新的
   migration UUID。先取得变更审批与 rollback 决策人；不得以批量脚本替代。
4. 目标 store 必须已通过 schema readiness，且复制窗口内没有未处置的 target
   数据库故障。仓库已覆盖双 PostgreSQL 连通与崩溃恢复；目标部署的权限、分区、
   容量和备份恢复仍需单独验收。

示例中的 bearer 仅由 secret manager 注入，不应回显、写 shell history 或贴到
incident 公共字段。网络重试一律重用相同 operation/migration UUID。

## Copy 与 verify

调用 `POST /internal/v2/user-shard-migrations/copy-verify`：

```json
{
  "migrationID": "new-migration-uuid",
  "userID": "user-uuid",
  "sourceBucket": "users-primary",
  "targetBucket": "users-next",
  "sourceRouterEpoch": 17
}
```

响应只返回 migration ID、phase 和 `wasIdempotent`。初次相等的 fingerprint 会进入
`forwarding`，而不是 `verified`：source owner 的新 fan-out 投影，以及关系、block
和陌生人消息接收设置的已提交 sync record，都会在此阶段以原 source sequence shadow
写入 target；cutover 后的新控制面投影由 target 自主分配后续 sequence。相同
forwarding 请求可安全重试；`409` 表示另一个 attempt 正在进行或
请求与已有迁移冲突，必须先调查 durable migration record。

在 forwarding 已运行并观察到目标健康后，调用
`POST /internal/v2/user-shard-migrations/verify-forwarding`：

```json
{ "migrationID": "existing-migration-uuid" }
```

只有这次 fingerprint 再次相等才转为 `verified`。若 source/target 在比较期间继续
变化而不相等，服务保持可观测失败，operator 必须修复 forwarding 后重试；不得绕过
该终态校验直接调用 cutover。

## Cutover

在 verified 后调用 `POST /internal/v2/user-shard-routes/cutover`：

```json
{
  "operationID": "new-cutover-operation-uuid",
  "userID": "user-uuid",
  "expectedRouterEpoch": 17,
  "writeBucket": "users-next",
  "readFallbackBucket": "users-primary"
}
```

控制面锁定 migration、验证 source/target/epoch，写入新的 write owner 与 epoch，
并进入默认 24 小时 retention。fan-out worker 对每条 delivery 重新读 route；过期
route 只 fenced handoff 到新 bucket，绝不在旧 owner 写入。新 route 的 target
projection 先由 `consumer_inbox` 去重提交，再完成控制库 delivery 计数。

记录 operation ID 和返回 epoch。`409` 必须停止：表示 epoch 已变、迁移证据不匹配
或相同 operation ID 被用于不同语义；不得换 UUID 绕过该栅栏。

## Retention、观测与 rollback

在 retention 内观察目标同步、fan-out backlog、paused durable work、数据库错误率及
用户可见序列单调性。source cleanup 只会在截止后由 leased worker 执行；不要手工
删除 source 数据。

若审批决定回切，且 migration 仍在 retention 内，调用
`POST /internal/v2/user-shard-routes/rollback`：

```json
{
  "operationID": "new-rollback-operation-uuid",
  "userID": "user-uuid",
  "expectedRouterEpoch": 18
}
```

请求没有 bucket 字段。服务从 durable migration 推导 target→source，只在当前 owner
仍为 target、fallback 仍为 source、epoch 匹配且 retention 未过期时执行。成功后
source 变为 write owner、target 成为 read fallback、migration 变为 `rolled_back`，
并取消 source-cleaner lease。相同 rollback operation ID 幂等返回；过期或 cleanup
后的 migration 不能回滚，必须走新的经过批准的迁移。

## Cleanup 与收尾

不回滚时保持监控直至 retention 到期和 worker 将 migration 标为 `completed`。清理
失败只保留可过期 lease，后续 worker 可重试；禁止为了“完成迁移”手动标记 completed。
记录 migration/cutover/rollback operation ID、审批、实际阶段、router epoch、目标
schema readiness、告警与演练结果。不得记录 token、连接串或用户同步 payload。

## 当前限制

- sync read 始终使用当前 write owner；`readFallbackBucket` 只支持受控 rollback，
  不作为任意读取错误的自动降级，避免返回旧序列破坏单调性；
- 集成测试验证了两个独立 PostgreSQL 实例之间的投影/完成崩溃恢复，尚未证明目标
  部署的网络分区、跨 region 延迟、长时间 forwarding 或 100k 容量；
- operator access 的 bastion/mTLS、审批、实际告警 receiver 与灾备恢复演练必须在
  目标部署中单独验收。
