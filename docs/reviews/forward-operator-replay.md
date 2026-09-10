# 转发暂停任务的审计恢复

对应 B04；2026-09-06。本接口恢复调度，不修改已提交授权或 owner epoch。完整跨库媒体 HTTP 路由、owner 迁移、终态 envelope 清理仍单独跟踪。

## 运行前提

数据库必须为 schema 16。现有 schema 15 先停旧 writer，再执行 `IMV2/sql/migrations/20260906_forward_work_replay.sql`，验证 Swift 与 SQL readiness 后启动匹配服务；更早起点需先执行既有迁移链。迁移增加 `forward_work_replay_audit` 和不可变审计 trigger，不改已有 export、任务和媒体标识。未对用户数据库执行迁移或部署。

接口只注册在独立、loopback 绑定的 `IMV2OperatorServerApp`，复用现有 operator replay bearer 凭据和服务配置的审计 principal，不接受普通账户或群管理员身份。运维访问沿用受控的 operator 通道。

Operator 的 `IM_V2_ROOM_SHARD_STORES_JSON` 显式登记可操作 owner，格式与 Gateway 一致：`shard_id`、`database_url`、`schema: im_v2`。数据库连接预算包含控制库、user store 和 room owner 的去重物理连接池。省略 registry 时没有可恢复的 forward owner；未知 shard 返回 404，不扫描其他数据库或回退控制库。本地 Compose 为其登记 `rooms-primary`。

## 单次恢复请求

`POST /internal/v2/forward-work/replay`，使用既有 operator bearer 认证。下面字段需替换为本次故障的真实定位与新的操作 UUID；重试同一恢复动作始终保留 operationID。

```json
{
  "operationID": "<本次恢复操作 UUID>",
  "shardID": "<任务所在 owner 的 shard ID>",
  "kind": "delivery",
  "exportID": "<原 export UUID>",
  "reason": "dependency_recovered"
}
```

`kind: delivery` 恢复源端 `message_forward_delivery_jobs`，不得带 ordinal。`kind: media` 恢复目标端 `message_forward_media_imports`，必须带精确附件 ordinal（0–9，且存在于原 manifest）。reason 只允许 `dependency_recovered`、`data_repaired`、`false_positive`；自由文本事故经过保留在外部事故记录，不写入聊天数据库。

1. 从明确 owner 的暂停任务记录定位 export；目标媒体任务还需 ordinal。只检查该 export 的任务、inbox、源回执和相应审计，不跨库搜索替代 owner。
2. 修复实际依赖故障。若目标附件与源投递都已暂停，先在目标 owner 恢复各个已暂停附件，再在源 owner 恢复投递；两边分别使用独立 operationID。
3. 200 响应的 outcome 为 `requeued` 或 `not_paused`，wasIdempotent 表示返回先前审计结果。not_paused 是稳定记录，不代表消息已经完成；应检查源终态回执和目标 inbox。
4. HTTP 响应丢失或 503 时，以原 operationID 和完全相同字段重试。修改 shard、kind、export、ordinal 或 reason 后复用同一个已审计 operationID 返回 409。
5. 恢复后观察目标复制/扫描、目标 inbox 终态、源回执和源 delivery 完成。恢复动作自身不返回消息成功，不解除源 pin，也不绕过扫描、准入或当前成员权限。

400 表示非法目标形状；401 表示未通过 operator 认证；404 表示未知配置 owner 或目标不存在；409 表示幂等冲突或 owner 已变化；数据库异常统一 503，不返回 SQL、正文、对象路径或异常细节。成功响应包含 no-store/Pragma:no-cache。

## 事务与不变量

审计 insert、paused → pending、retry_count 重置和最终审计 outcome 在同一个 owner 事务提交。审计提交失败则任务恢复也回滚。相同操作并发提交只有一条审计；已经完成的审计结果先于当前 owner 状态检查返回，保证响应丢失后的重试稳定。

新恢复操作在房间锁下比较当前本地 shard/epoch 与 immutable export 的原 owner。媒体恢复按 inbox → room → import job 取得锁，与导入写入保持一致；inbox 已终态时不再恢复附件。owner 变化返回冲突，不能用恢复接口迁移或重签旧授权。

恢复清空租约、设置到期时间并重置重试计数，保留 export、目标 media/upload UUID、copied_digest、已复制时间和原扫描要求。旧 lease 的写回被 token/state 栅栏拒绝。并发的不同恢复操作最多有一个把同一 paused 行改为 pending，后续操作记录 not_paused。审计 identity 与终态禁止改写或删除。

## 验证

测试与结果以 `archive/2026-09-05-system-remediation-progress.md` 的本轮记录为准。覆盖包括双库源/目标恢复、审计回滚、相同操作 16 次并发、owner 冲突、旧 lease、摘要/目标 UUID 保留、真实双附件从暂停恢复至源回执完成、HTTP 认证/路由/错误和 schema 15→16 迁移。最终 104 tests / 11 suites 通过，日志与源码绑定见 [持久验证证据](../../docs/reviews/verification-records.md#20260906-forward-operator)。未把这些组件验证称为真实生产 operator 部署或设备端到端验收。
