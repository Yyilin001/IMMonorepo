# Direct preplanned fan-out rollout runbook

状态：current-2 已实现；启用前必须完成空库/故障/负载验证并保留可回滚 binary。

## 配置与范围

```text
IM_V2_DIRECT_FANOUT_MODE=planner     # 兼容基线
IM_V2_DIRECT_FANOUT_MODE=preplanned  # 仅 message.accepted 私聊快路径
IM_V2_DIRECT_FANOUT_MODE=room_log    # 私聊 message.accepted 以 room_events/cursor 可靠恢复
```

该开关不适用于群聊，不关闭 Delivery Worker，也不修改权限策略。内容审核是独立 durable lane；
关闭审核只减少该 lane 的工作，不能作为启用 fast path 的前置条件。

`room_log` 不创建该消息的 `room_outbox`、fanout plan/completion/delivery、共享投影引用或
`user_sync_log` message 行。其正确性审计应改为检查一条 canonical message 对应一条 room event，
并确认没有上述 fanout 工件；压测必须启用 `--room-log-reads 1`，让每个压测客户端按 cursor 拉取。
编辑、撤回、reaction 和 moderation mutation 尚未改走 room log，仍需按原 fanout 指标观察。

## 启用前门槛

1. 当前 schema readiness 通过，router configuration 恰有一行且 override 无无效 bucket；
   `fanout_deliveries_fresh_direct_user_microbatch_claim_idx` 与
   `fanout_deliveries_fresh_generic_target_lane_claim_idx` 已创建且有效；
2. `room_outbox`、fanout plan/delivery、completion release 无 paused/长期 leased backlog；
3. 备份可恢复，记录 gateway image digest、配置、数据库参数和基线压测结果；
4. 集成测试已覆盖 exact-two、route fallback、corrupt audience rollback、重试与 payload 等价；
5. 先单 gateway canary，再滚动其余 gateway，禁止同时改变数据库参数和 worker 并发。

## 灰度检查

新私聊在 route 健康时应满足：

```sql
SELECT COUNT(*) AS malformed_preplanned
FROM im_v2.fanout_plans AS plan
LEFT JOIN im_v2.fanout_completion_units AS unit
  ON unit.source_event_id = plan.source_event_id
LEFT JOIN LATERAL (
  SELECT COUNT(*) AS deliveries
  FROM im_v2.fanout_deliveries AS delivery
  WHERE delivery.source_event_id = plan.source_event_id
) AS delivery_count ON TRUE
WHERE plan.target_rule->>'planning_strategy' = 'direct_preplanned'
  AND (plan.target_count <> 2 OR plan.enumerated_target_count <> 2
       OR unit.target_count <> 2 OR delivery_count.deliveries <> 2);
```

必须为 0。抽样时间窗内 fallback 数量用以下查询观察；持续增长意味着 router 配置缺失或
读取异常，应先修路由，不要扩大 Planner 并发掩盖问题：

```sql
SELECT COUNT(*) AS direct_planner_fallback
FROM im_v2.fanout_plans AS plan
JOIN im_v2.rooms AS room ON room.room_id = plan.room_id
JOIN im_v2.room_outbox AS outbox ON outbox.source_event_id = plan.source_event_id
WHERE room.room_kind = 'direct'
  AND plan.target_rule->>'planning_strategy' IS DISTINCT FROM 'direct_preplanned'
  AND plan.created_at >= now() - interval '15 minutes';
```

单库 fresh delivery 排空后，每个 preplanned event 必须恰有一个 shared reference：

```sql
SELECT COUNT(*) AS missing_terminal_payload
FROM im_v2.fanout_plans AS plan
LEFT JOIN im_v2.fanout_sync_payloads AS payload
  ON payload.source_event_id = plan.source_event_id
 AND payload.projection_kind = 'message'
WHERE plan.target_rule->>'planning_strategy' = 'direct_preplanned'
  AND plan.state = 'terminal'
  AND plan.created_at >= now() - interval '15 minutes'
  AND payload.source_event_id IS NULL;
```

必须为 0。planned/pending event 尚未投影时缺少 reference 属正常状态；terminal event 缺失
表示一致性损坏，必须停止推进并调查，不能人工补写未知正文或推进 checkpoint。

同时观察 ACK/s、端到端 p95/p99、DB CPU、WAL、transaction rate、lock wait、ready/leased/
scheduled/paused delivery、terminal completion release 与连接池等待。日志和报告只能保存聚合，
不得记录 room/user/message ID 或正文。

新建的 direct-preplanned delivery 必须同时标记 `fresh_direct_eligible=true`；该标记只决定
无 lease 快路径的领取方式，不参与授权。普通 Planner 生成的工作必须保持 false。历史行或滚动
升级期间由旧 binary 写入的 false 行会安全回落到 lease-fenced 路径，不能批量修改 terminal
历史数据来“提高命中率”。

`IM_V2_FANOUT_DELIVERY_CLAIM_BATCH_SIZE` 只是一次 claim pass 的上限；fresh direct 的单事务
上限仍由 `IM_V2_FANOUT_DELIVERY_COMMIT_BATCH_SIZE` 控制（当前最大 128）。压测时不要为了追求
瞬时 ACK/s 放大单事务，优先通过互不重叠的 target-user lane 并行扩展，并同时观察 lock
wait、WAL burst 和 p99。target user 映射到固定 8 个数据库 lane，同一用户的 fresh delivery
必须归属同一 lane；跨副本由非阻塞用户 advisory lock 再次仲裁。同一私聊事件的两条 delivery
可以位于不同 lane，正文通过唯一键和等值校验只物化一次。worker 对已取得 user lock 的多条
source event 做有界微批；每事务最多选 8 个 user，并按 user 精确分配总 Delivery 配额，未取得
user lock 的副本不得先持有对应 delivery row lock。禁止修改 SQL hash 常量、user 微批上限或
配额算法而不重建对应索引并完成相同数据快照的 A/B。

同库 fresh delivery 正常排空后应保持 `retry_count=0`；非零表示它按设计进入了恢复协议：

```sql
SELECT COUNT(*) FILTER (WHERE state = 'terminal' AND retry_count = 0) AS fresh_fast,
       COUNT(*) FILTER (WHERE retry_count > 0) AS lease_recovery
FROM im_v2.fanout_deliveries AS delivery
JOIN im_v2.fanout_plans AS plan USING (source_event_id)
WHERE plan.target_rule->>'planning_strategy' = 'direct_preplanned';
```

## 回滚

出现 malformed cardinality、权限异常、持续 fallback、paused delivery、错误率或 p99 超预算时：

1. 将新 binary 配置改回 `IM_V2_DIRECT_FANOUT_MODE=planner` 并滚动重启；
2. 保持 Planner、Delivery、completion release 运行，让两类存量工作自然排空；
3. 禁止删除 plan/outbox/delivery，禁止手工把 plan 标成 terminal；
4. 执行一致性审计并保存不含业务标识的计数、版本、时间窗和恢复证据。

无需 schema 回退或数据转换。若 exact-two 断言失败，按数据损坏事件处理：停止消息写入、保留
事务日志/备份、调查 direct pair 与 membership revision 来源，不能将断言改成“取前两条”。

## 性能验证矩阵

用 `v2_profile_snapshot.sh capture/restore` 在每组前恢复同一 disposable 数据快照，并用
`capture_v2_postgres_profile.sh baseline/report` 以非破坏性前后快照保存 query/WAL/I/O 增量证据。在同一快照依次测试
planner 基线与 preplanned：500、1k、2k 在线连接爬坡；随后固定连接
执行 5 分钟消息阶梯与 30 分钟 soak。每级至少保存 accepted、rejected、timeout、ACK p50/p95/
p99、端到端投影 p95/p99、DB CPU/IO/WAL、gateway CPU/RSS、表/索引增量和一致性计数。只有错误
率为 0、审计为 0 且资源曲线可解释，才提高下一级；理论百分比不得代替实测。
