# 单节点性能优化上线与回滚 Runbook

本文用于同一 Gateway + PostgreSQL 单机环境，不要求拆库。先保持审核关闭：
`IM_V2_CONTENT_REVIEW_MODE=disabled`。

## 推荐起始配置（4 event loops，单物理数据库，8 vCPU / 16 GiB）

| 项目 | 值 |
| --- | ---: |
| 共享 pool ceiling / event loop | 16 |
| workload pool isolation | `false` |
| foreground write / interactive read reservation（共享 foreground ceiling 32） | 24 / 8 |
| Sync admitted in-flight | 16 |
| foreground write / interactive read / Sync 短队列 | 288 / 96 / 128 |
| Projection concurrency / unique user schema | 2 |
| Delivery concurrency ceiling / foreground-safe level | 8 / 4 |
| Projection busy-drain pass / time budget | 16 / 50 ms |
| Backlog maintenance idle poll | 1,000 ms |
| Backlog maintenance busy pass / time budget | 4 / 100 ms |
| admission timeout | 200 ms |
| Sync hint window | 40 ms |
| pending hint users | 50,000 |
| Sync hint delivery concurrency | 64 |
| 快速成功日志采样 | 10‰ |
| 慢命令阈值 | 250 ms |
| 慢/拒绝/失败诊断日志 burst | 每个封闭结果键 20 条/秒 |

当前 Gateway 数据工作池 ceiling 为 `4 × 16 = 64`；个人事件路由围栏另使用控制库每 EventLoop 1 条专用连接，因此单物理库总 ceiling 为 `64 + 4 = 68`，连接按需建立。该专用池即使关闭 workload isolation 也保留，以保证源端独立提交时仍持有迁移路由围栏；所有连接仍受 `IM_V2_DATABASE_MAX_TOTAL_CONNECTIONS` 约束。历史性能记录中的 64 条预算属于添加该池之前的版本。Account、Operator 也各自按其 EventLoop 数乘每 loop ceiling 计算，不能再按一个长期 `app.db` 句柄估算。其他环境必须把所有进程、物理数据库 URL 和运维连接预算相加；不要让理论最大值等于 PostgreSQL `max_connections`。

配置中保留的 foreground/Sync/Delivery/Projection/Maintenance 每-loop 数值只在显式启用 workload isolation 时生效。当前默认不启用；固定角色池在相同负载下不能借用空闲连接，曾出现总吞吐回退。写入和交互读取在同一 foreground pool 上各有 24/8 的准入保留额：空闲保留额可被另一类暂借，但一旦对端出现排队，后续释放的 permit 优先归还给对端；两个保留额之和仍不得超过 foreground pool。若实验启用，多个 schema 共用同一数据库 URL 时，Projection pool 至少覆盖每个 schema 的 `projector concurrency + 1 snapshot builder`。

表中 `288 / 96 / 128 / 200 ms` 是正常业务流量的起始保护值。压测工具若在连接完成后一次释放 1,000 个初始化命令和 Full Sync，可仅在 load-test Compose overlay 中保持 write/read/Sync in-flight 不变，将短队列临时调为 `1,152 / 384 / 1,536`、等待时间调为 5,000 ms。这样仍限制数据库并发，只吸收已知的有界测试突发；不能把这组值直接当作生产默认值。

单机吞吐上限测试可以在 load-test overlay 中暂时关闭 workload pool isolation，让空闲角色把连接借给当前热点角色；admission、worker concurrency 和队列上限仍须开启。该结果代表吞吐 ceiling，不代表具备故障隔离的生产 SLO。若共享池下出现 Sync/foreground 相互饿死，应恢复上述固定角色预算。

一次 1,000 连接、1,000 msg/s、no-sync ceiling A/B 中，关闭 admission 仅把 ACK 从 28,611 提高到 30,981，同时 p95 变差，仍未达到旧版延后投影排空时的 34,240。标准压测和生产配置因此保持 admission 开启；只有明确接受数据库排队失控风险的短时诊断才关闭它，并必须在测试后恢复。

## 上线顺序

1. 使用明确的新库安装 `IMV2/sql/schema.sql`，运行当前 SQL contract 与服务端 readiness。
   不执行历史 expand、回填或旧模式切换。确认房间内容版本、不可变事件与接受台账约束存在，
   这些约束在当前快速发送和历史读取中仍然必需。
2. 部署 binary，保持 workload isolation 为 `false`，确认每个 pool 的 EventLoop handle 数、连接 ceiling、readiness 和基本链路。
3. 启用 database work admission。客户端必须把 `SERVER_BUSY` 当作可重试错误并使用带 jitter 的指数退避；取消的请求不得记作过载。
4. 分别观察个人事件队列、用户投影和房间维护任务。调整并发时固定其他变量，仅在积压和
   前台尾延迟同时改善后继续增加；不能使用旧公共消息 fanout worker 的并发经验作为当前结论。
5. 启用 Sync wake coalescing。比较 Pull 平均 records、Pull QPS、hint delivered/drop 和消息可见延迟。
6. 最后开启成功日志采样，并保持慢/拒绝/失败日志的有界 burst。两者都只控制结构化日志，
   Prometheus 计数不受采样或限流影响。workload isolation 只作为单变量 A/B 实验，不作为默认上线步骤。
7. 压测使用当前配置与可丢弃夹具，记录完整参数、构建版本和结果。旧 shared/preplanned
   模式及 backfill 审计不属于当前启动条件，历史性能数字只能与其原始版本关联。

## 必看指标与告警

- `im_v2_database_work_in_flight{class=...}`：持续贴顶表示对应预算不足或 SQL 变慢；
- `im_v2_database_work_queued{class=...}`：连续 1 分钟大于 0 告警；
- `im_v2_database_work_rejections_total{class=...,reason=...}`：5 分钟增量大于总命令 0.5% 告警，并区分 queue-full 与 timeout；
- `im_v2_database_work_cancellations_total{class=...}`：客户端取消单独计数，不属于过载；
- `im_v2_database_work_queue_wait_milliseconds{class=...}`：先看 write 与 interactive-read 的 P95；它升高而 PostgreSQL SQL mean 未升高时，说明瓶颈是前台准入/数据库竞争，不应仅靠加大队列掩盖；
- `im_v2_database_pool_event_loop_handles{pool=...}` 与 `im_v2_database_pool_connection_ceiling{pool=...}`：必须与部署预算一致；
- `im_v2_sync_wake_pending_users`：持续接近 ceiling 告警；
- `im_v2_sync_wake_in_flight_users`、`im_v2_sync_wake_delivered_total`：判断 downstream 是否停滞；
- `im_v2_sync_wake_dropped_total`：任何持续增长都要求检查在线用户数和 flush 延迟；
- `im_v2_user_projection_maximum_lag_records`、ready/scheduled/paused projection backlog；
- Gateway p50/p95/p99、`SERVER_BUSY`、`UNAVAILABLE`、PostgreSQL CPU、WAL bytes/s、commit latency、lock wait 和连接数。

在 PostgreSQL 启用 `pg_stat_statements` 的环境中，按 total execution time、calls 和 mean time 检查 Top SQL。不要只凭一次 `EXPLAIN` 增加索引；候选索引必须在与生产数据分布相近的副本上用 `EXPLAIN (ANALYZE, BUFFERS, WAL)` 验证，并同时计算写放大和 relation size。

旧的无 credit 路径保持“大数据修改 CTE + 最终窄 shard 预留 UPDATE”两个语句；不要把共享 shard
行预留直接合入每条消息的主 CTE：历史单机 A/B 中，这会使主 CTE mean time 从约 7.4 ms 增到
24.6 ms，350 msg/s 的消息 p95 从约 312 ms 回退到 1,994 ms。启用 shard credit 后，Gateway 以
有界批次预扣 durable 额度，普通消息事务只验证当前 lease/profile fence 并消费本地已扣额度；R29
进一步把本地 credit actor 交互收敛为每个 micro-batch 一次。两种路径都不允许 ACK-before-commit，
也不能靠取消 durable fence 换吞吐。当前证据见
[`R29 50,000 在线梯度记录`](../09-capacity/direct-room-log-50000-gradient-r29-2026-08-27.md)。

本仓库 server/profile Compose 已启用 normalized query、I/O 和 WAL timing。每个 A/B 阶段使用
同一统计纪元的前后快照计算差值，不要清空共享数据库统计：

```bash
IM_V2_PROFILE_DATABASE_URL=... IMV2/scripts/capture_v2_postgres_profile.sh baseline /tmp/profile-A-before
# 执行固定时长负载
IM_V2_PROFILE_DATABASE_URL=... IMV2/scripts/capture_v2_postgres_profile.sh report /tmp/profile-A-after /tmp/profile-A-before
```

报告目录中的 `delta_database.csv`、`delta_wal.csv`、`delta_io.csv`、
`delta_statements.csv` 和 `delta_relations.csv` 才是该负载窗口的增量。若期间任何统计计数器被
重置，脚本会拒绝生成差值。`reset` 仅用于完全隔离的一次性数据库，并强制要求
`IM_V2_PROFILE_DATABASE_IS_DISPOSABLE=1`；禁止在共享测试库或生产库执行。

恢复快照会删除 disposable 数据库的 `im_v2` schema，脚本因此同时要求显式
`IM_V2_PROFILE_DATABASE_IS_DISPOSABLE=1` 且确认没有其他数据库 session；禁止对生产库执行。

## 每阶段正确性审计

暂停压测写入并等 worker drain 后验证：

```sql
SELECT state, count(*)
FROM im_v2.user_state_event_outbox
WHERE state <> 'delivered'
GROUP BY state;
SELECT state, count(*)
FROM im_v2.group_event_wake_outbox
GROUP BY state;
SELECT count(*) FROM im_v2.user_projection_checkpoints WHERE state = 'paused';
SELECT max(sequence.next_sequence - checkpoint.projected_sequence)
FROM im_v2.user_projection_checkpoints checkpoint
JOIN im_v2.user_sync_sequences sequence USING (user_id);
SELECT count(*)
FROM im_v2.user_projection_versions
WHERE projection_kind = 'message'
  AND valid_to_sequence IS NULL;
```

个人事件 outbox 的 `pending`/`leased` 应在排空后为 0，`paused` 必须为 0；
`delivered` 是保留的终态，不要求删除。房间 wake 是可丢失的提示工作，
按配置和租约检查 `pending`/`leased` 是否持续增长，不能将其数量当作正文缺失。
projection 的 paused、最大 lag 与仍活动的旧个人 `message` 投影应为 0。
再随机抽取多设备用户做完整 Snapshot reset 与增量 Pull/ACK 回放。

## 压测门槛

采用至少三段测试：10 分钟预热、30 分钟目标负载、10 分钟停止写入后的 drain。
记录连接建立速度、稳定在线数、send ACK/s、端到端可见延迟、Pull 平均 records、错误码分布和 drain 时间。通过标准：

- 非注入故障下无数据丢失、重复当前投影或 checkpoint gap；
- `UNAVAILABLE` 为 0；`SERVER_BUSY` 在目标负载下小于 0.5%，且客户端退避后成功；
- p99 和 worker drain 符合产品 SLO；
- PostgreSQL 不发生 swap、OOM、持续 lock queue 或 WAL/磁盘饱和。

## 回滚顺序

出现投影一致性问题，先关闭 accepted-message batch 并保持 worker drain；出现提示风暴或可见延迟异常，关闭 wake coalescing；出现客户端重试风暴，关闭 admission；若实验开启的 role pool 发生容量闲置或饥饿，恢复默认共享池。每次只改一个开关并保留指标证据。加法索引无需在应用回滚时删除。
