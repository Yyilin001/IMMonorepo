# V2 可观测性基线

状态：部分实现；不是生产发布批准。

## 已实现的边界

PostgreSQL durable-work 指标是 worker 健康和积压的权威观测面。Hybrid 群的
`group_event_wake_outbox` 也只在 room event 提交后发送最佳努力 wake hint；提示
发布失败不会改变 cursor、房间事件或个人事件 outbox 状态，因此不会产生“broker 成功
即投递成功”的指标语义。adapter 以 `PING`/`PONG` 确认命令并在断线后重放当前本机兴趣，
但尚未暴露 NATS connection、publish-confirmation latency、consumer lag、reconnect 或
broker availability 指标；启用 NATS 前不能把这些缺失指标误解为健康。

`V2TelemetrySink` 是 Server 的可注入边界。网关命令结果写入 `V2TelemetryEvent`；
生产应用使用 `V2ApplicationTelemetrySink`
输出结构化日志，测试使用 `V2InMemoryTelemetrySink` 断言事件内容。

当前结构化事件：

| 事件 | 字段 | 用途 |
| --- | --- | --- |
| `im_v2.gateway.command` | `trace_id`、有限 `command`、`outcome`、有限 `rejection`、`elapsed_ms` | 接受/拒绝/失败命令计数与延迟 |

`trace_id` 是每次网关请求或 pipeline 运行生成的随机 UUID，只用于日志关联；
它不能作为 Prometheus/StatsD 等指标的标签。

`V2PrometheusTelemetrySink` 会与结构化日志 sink 同时接收同一封闭事件词汇，
并聚合为稳定的
Prometheus 0.0.4 文本：按封闭命令、结果和拒绝码聚合的网关计数与累计耗时。
它丢弃 trace ID；
测试断言指标中不存在 trace ID、room/user 字段或任意输入文本。网关命令热路径使用短
`Mutex` 临界区做精确整数累加，不会像 actor 那样让每条命令产生一次 serial-executor hop；
scrape 只在锁内复制值快照，Prometheus 文本在锁外渲染。因此日志采样或限流不会丢失指标计数，
并发 scrape 也不会在格式化期间阻塞命令接纳。该 exporter
只通过独立的 `/metrics` HTTP listener 暴露：运行时强制
`IM_V2_METRICS_HOST` 为 `127.0.0.1` 或 `::1`，且要求显式端口。采集器因此
必须与服务在同一 host/pod 网络命名空间；该 endpoint 带 `no-store` 响应头，
绝不能挂到公开媒体边缘或 realtime TLS 端口。

结构化命令日志与精确指标是两个不同合同。低于慢命令阈值的成功命令按
`IM_V2_COMMAND_SUCCESS_LOG_SAMPLE_PERMILLE` 采样；慢命令、拒绝和失败不走该采样，但按封闭的
`(command, outcome, rejection)` 结果键由 `IM_V2_COMMAND_DIAGNOSTIC_LOG_MAX_PER_SECOND` 限制
日志 burst，默认每键每秒 20 条。该限制只保护日志 I/O，不能用日志条数计算请求量；请求量、结果和
累计延迟必须读 Prometheus 精确 counter。排障时可以在受控短窗口提高限制，但不能通过无限打印诊断
日志制造新的 Gateway 瓶颈。

三个服务端进程通过 `IM_V2_LOG_LEVEL` 调整首方 `imv2.` logger 的级别，
默认 `info`；其他依赖库仍保持 `info`，避免为排障打开其可能含敏感细节的调试输出。
启用 `debug` 后，HTTP 成功请求会记录方法和路由模板，不记录原始路径或查询串。
配置值不合法时进程拒绝启动。生命周期与后台工作器故障记录固定的
`stage`、`error_code`、`error_type`，工作器额外记录 `worker`；
`error_type` 来自编译期类型，日志不写入 `Error` 的描述文本。
后台工作器共用 `IM V2 background worker failed; retrying` 事件，
按固定的 `worker` 字段区分故障来源，而不是依赖不同的自然语言消息做检索。

同一私有 endpoint 还会在每次抓取时读取进程内
`V2DeviceConnectionRegistry` 的只读快照，并输出两个无标签 Gauge：
`im_v2_gateway_active_devices` 与
`im_v2_gateway_active_connections`。两者只计已认证且仍被注册的连接；认证、
EOF、协议错误和设备撤销都会走同一注销路径。它们仅描述当前 gateway
进程，不可直接当作整个集群的在线人数，集群级聚合应由采集系统完成。Hybrid
room wake 的 viewer/room 数同样是进程内短暂兴趣状态，必须单独补齐无标签 gauge；
它不能替代 PostgreSQL wake outbox 的积压、重试和租约指标。

网关 NIO handler 还维护独立的进程内 transport 快照：
`im_v2_gateway_transport_active_connections` 包含认证前 socket，
`im_v2_gateway_inbound_queue_peak_bytes` 是进程启动以来的入站待处理字节峰值，
`im_v2_gateway_connection_closures_total` 只按固定原因
(`peer_disconnected`、`idle_timeout`、`inbound_queue_limit`、`frame_limit_violation`、`request_failure`、
`required_notification_backpressure`、`required_notification_write_timeout`、`device_revoked`) 分组。
其中两个 required_notification 原因分别表示必须送达的通知遇到不可写通道，
以及写入 promise 超过 10 秒未完成；它们不代表客户端已落库。
它用于定位 idle heartbeat、队列背压和撤销断连，
不保存或输出任意连接 ID、IP、用户、设备或请求 ID。

同一私有 endpoint 还在每次抓取时读取 PostgreSQL 的 durable-work 快照。
实际精确聚合会在并发抓取之间合并，并按
`IM_V2_METRICS_MINIMUM_REFRESH_INTERVAL_MS`（示例为 30 秒）缓存；该值必须不小于
刷新超时，避免高频 scraper 对 durable work 表形成持续扫描负载。
`im_v2_durable_work_metrics_available` 为 `0` 表示本次数据库快照失败或超过
`IM_V2_METRICS_REFRESH_TIMEOUT_MS`，但 `/metrics` 本身仍保持可抓取；该值必须被
单独告警。超时后如存在成功快照，endpoint 返回 last-known-good 数值并设置
`im_v2_durable_work_metrics_last_known_good=1` 与
`im_v2_durable_work_metrics_last_success_age_seconds`，而不是挂住所有后续 scrape；
下一次刷新仍可恢复。个人事件来源按配置中的实际房间数据库去重统计，计数相加、
最老年龄取最大；任一来源失败都不能作为完整零积压发布。快照包含
`im_v2_user_state_event_backlog`、`im_v2_user_state_event_oldest_unfinished_age_seconds`、
`im_v2_direct_profile_update_backlog`、
`im_v2_read_receipt_preference_propagation_backlog`、
`im_v2_content_review_backlog`、`im_v2_media_scan_backlog`、
`im_v2_media_purge_backlog`、
`im_v2_user_sync_log_estimated_rows`、`im_v2_user_sync_log_relation_bytes`、
`im_v2_user_projection_effects_estimated_rows`、
`im_v2_user_projection_effects_relation_bytes`、
`im_v2_user_projection_backlog`、`im_v2_user_projection_maximum_lag_records`、
`im_v2_snapshot_artifacts`、`im_v2_snapshot_oldest_building_age_seconds`、
`im_v2_projection_version_gc_backlog_estimated_rows`、
`im_v2_sync_uncompacted_projected_records`、
`im_v2_sync_pending_records_across_devices` 与
`im_v2_sync_reset_pending_devices`。当 gateway 启动配置提供 node ID 时，快照还包含
`im_v2_device_revocation_events_pending`：它只统计**当前 scrape 所在 gateway
节点**尚未消费的 device-revocation event，不含 node、user 或 device 标签。其非零
短暂出现是正常消费过程；若持续存在，可能有已撤销会话尚未断开，必须按账号禁用
runbook 处置。`im_v2_revoked_device_projection_cleanup_events_pending` 则统计集群共享
cursor 尚未完成的用户分片清理：该消费者从历史起点回放，在路由共享锁内清理当前
归属，并先写单调的 shard-local device tombstone；同步与手工
reset 以相同 advisory lock 检查该 tombstone，因此已在途请求也不能在清理后重建
cursor/token/receipt。它独立运行，远端 shard 故障不会阻塞本地 socket 撤销。
Gateway 在绑定 TLS listener 前只为此前未见过的 node ID 原子创建
cursor，并把它设为当时的 event watermark：新副本没有存活 socket，无需扫描历史；
已存在 cursor 绝不在启动时推进，以保留崩溃恢复和防止重复 node ID 跳过工作。
部署必须为同时运行的 gateway 使用不同、受限且稳定的 node ID；以 scrape target
而非指标标签区分副本。个人状态事件、房间 wake、回执隐私传播、content review、
media scan 和 media purge 只使用固定的
`ready`/`leased`/`scheduled`/`paused` 标签；`scheduled` 表示仍处于退避等待期，
`paused` 表示重试预算已耗尽、必须经受控
operator replay 才会再次入队的 durable row，绝不能将它当作已投递或已终态。
direct-profile outbox 只使用 `ready`/`leased`：资料投递 worker 每轮按接收者预算
推进 checkpoint，因而没有独立的退避或 paused 状态；`leased` 超时会重新变为
`ready`。它不含用户、room 或 shard 标签。
个人事件投递统计覆盖本副本部署 registry 显式配置的全部逻辑 user-shard bucket，
但不把 bucket 值作为标签。同步、projection、snapshot、GC、compaction 与 relation-size
指标会并发查询每个去重后的物理 `(database, schema)` user store 后无标签聚合；计数与
字节求和，最大 lag 和最老构建年龄取最大值。任一 store 查询失败时整组
`im_v2_durable_work_metrics_available` 为 `0`，不会把局部结果伪装成全局健康值。
同步积压按每个 ready device cursor 计算，故多设备
用户会被分别计入；这反映实际待同步工作量，而不是独立消息数。
`user_sync_log_estimated_rows` 读取 PostgreSQL planner statistics，不会为 scrape 执行
追加表的精确全表计数，因此允许短期滞后；`user_sync_log_relation_bytes` 使用 relation
size 元数据，包含 heap、index 与 TOAST。projection backlog/lag 区分可立即执行、退避和
poison-paused 用户；snapshot 指标区分正在构建与失败 artifact，并给出最老构建年龄；GC
使用 closed-version partial index 的 planner estimate，不为 scrape 扫描 MVCC 全表；
uncompacted records 表示 canonical checkpoint 与 retained floor 的聚合距离。它们共同定位
增长来自 projector、builder、GC 还是 compactor，不再只能看到最终 relation size。
个人快照不再运行公共消息回填，旧 missing-reference 和 inline-payload 指标与告警已删除。
房间消息状态仍保留行数、关系大小和可压缩正文估算，按主库与已配置房间库 URL 去重采集，用户分片不重复统计；这些估算用于容量观察，不能代替
数据完整性验证。个人快照排障见 [个人快照运维](personal-snapshot-runbook.md)。
`user_projection_effects` 是控制投影的稳定幂等结果，和 operation ledger 同类，不属于可仅按
retained floor 删除的增量历史。独立 housekeeping 只在首方重试窗口结束、projector 已物化、
原 sync-log 行已压缩且独立保留条件满足后按物理 store 分批删除；普通 operation ledger
采用同一服务端保留期轮转清理。estimate/bytes 仍用于验证实际操作速率与清理吞吐。默认告警在
总 relation size 超过 10 GiB 且持续 30 分钟后触发，上线前必须按磁盘预算重新校准，禁止由
sync-log compactor 跳过上述引用条件顺手删除。

## 隐私与基数约束

以下数据不得出现在此遥测边界的日志字段或指标标签中：room/user/device/message
ID、access/refresh token、正文、原始 frame、附件 URL、对象 key、关系状态或
异常文本。命令、结果、拒绝码和 stage 均为封闭枚举。聚合计数不带 room 或 user
维度。

## 已固化的 durable-work 告警基线

可部署的 Prometheus 规则位于
[`observability/prometheus/imv2-alerts.yml`](../../observability/prometheus/imv2-alerts.yml)，
配置模板位于
[`observability/prometheus/prometheus.yml.example`](../../observability/prometheus/prometheus.yml.example)。
本机隔离验证通过 `scripts/check_v2_prometheus_rules.sh` 用 `promtool` 校验二者。
单机压测还可叠加
[`docker-compose.postgres-exporter.yml`](../../docker-compose.postgres-exporter.yml)，
它固定使用 postgres_exporter `v0.20.1`，只把 `9187` 发布到主机 loopback，并开启
statement、WAL、checkpoint、autovacuum、锁、长事务与 user-index I/O collector。
Prometheus 模板已包含该 target。该本机 overlay 为方便 disposable 环境复用应用账号；
正式环境必须创建独立登录并授予 PostgreSQL `pg_monitor`，密码用 secret file 注入，不能
写入 Compose、命令行、工单或指标标签。官方 exporter 的 collection timeout 设为 5 秒，
避免数据库变慢时监控连接反向堆积。
本地账号栈的 `verify_v2_local_account_stack.sh` 还从 gateway 容器内部探测
loopback `/metrics`，断言 `no-store`、未发布 9464 端口及 ready/leased/scheduled/paused
完整状态词汇；它由此拒绝使用旧镜像的“健康但缺指标”状态。

所有 durable-work 告警使用角色 owner `im-v2-platform-oncall`：部署 Alertmanager
必须将这个标签路由至已批准的 V2 平台值班轮值，不能把具体个人或 token 写进规则。

| 告警 | 阈值 / 持续时间 | 严重度 | 处置 |
| --- | --- | --- | --- |
| `IMV2DurableWorkMetricsUnavailable` | scrape 值为 `0` 或指标缺失，5 分钟 | critical | 恢复 PostgreSQL metrics source 后确认 backlog；不能据此执行 replay |
| `IMV2PausedUserStateEvent` | paused personal event 大于 `0`，2 分钟 | critical | 按 replay runbook 先修复根因再单目标回放 |
| `IMV2StalledUserStateEvent` | 最老未完成个人事件超过 30 分钟，持续 15 分钟 | critical | 调查来源队列、目标路由和数据库；修复后只重放已暂停事件 |
| `IMV2PausedContentReview` | paused content review 大于 `0`，2 分钟 | critical | 按 replay runbook 先修复审核依赖或策略错误，再单目标回放 |
| `IMV2PausedMediaScan` | paused media scan 大于 `0`，2 分钟 | critical | 修复扫描 provider 后按 runbook 单目标回放 |
| `IMV2PausedMediaPurge` | paused media purge 大于 `0`，2 分钟 | critical | 修复对象清理 provider 后按 runbook 单目标回放 |
| `IMV2PausedReadReceiptPreferencePropagation` | paused 隐私传播大于 `0`，2 分钟 | critical | 优先恢复当前用户分片的投影投递依赖，再按 runbook 精确回放该偏好操作 |
| `IMV2PausedUserProjection` | paused user projection 大于 `0`，2 分钟 | critical | 修复精确 poison event 后，按 runbook 使用 `user_projection` 单目标回放 |
| `IMV2UserProjectionLag` | 最大单用户 lag 超过 10,000，10 分钟 | warning | 检查 projector worker、数据库锁与写入速率 |
| `IMV2SnapshotBuildStalled` | 最老 building artifact 超过 15 分钟，5 分钟 | critical | 检查 builder lease、checkpoint fence 和页尺寸失败 |
| `IMV2SnapshotBuildFailures` | failed artifact 大于 `0`，5 分钟 | warning | 按 failure code 调查尺寸/编码/存储，再确认过期清理 |
| `IMV2ProjectionGCBacklog` | closed-version estimate 超过 1,000,000，30 分钟 | warning | 检查活跃 building baseline 和 GC cadence |
| `IMV2SyncCompactionBacklog` | projected-retained 差值超过 10,000,000，30 分钟 | warning | 检查未过期 capability、低 cursor reset 与 compactor cadence |
| `IMV2DeviceRevocationBacklog` | 任一 gateway 的未消费撤销事件大于 `0`，2 分钟 | critical | 按账号禁用 runbook 调查 worker、数据库与连接关闭；不得 replay 或忽略该事件 |
| `IMV2RevokedDeviceProjectionCleanupBacklog` | 集群分片清理未消费撤销事件大于 `0`，2 分钟 | critical | 按账号禁用 runbook 检查 route fence、当前/fallback user store 与 tombstone 写入；不得手工推进 cursor |

paused 阈值刻意为零；个人事件暂停表示确定性错误，瞬时故障继续退避重试，不能依靠容量基准把它
延后告警。规则用 `max` 而不是跨副本求和，因为每个 gateway replica 都可能读取
同一份 PostgreSQL 聚合快照。ready/scheduled backlog 的容量阈值仍必须由经批准的
拓扑和负载报告决定，不能由此模板伪造生产 SLO。

## 仍需交付

- 将结构化日志接入受控的集中采集和告警系统，并建立保留/访问策略；
- 补齐 Push、NATS hint（连接、publish-confirmation、consumer lag、reconnect、broker
  availability）、shard lease 和容量利用率指标，并基于批准的负载报告为 durable-work
  ready/scheduled backlog 设定容量阈值；Redis 不属于当前 V2 correctness path；
- 将角色 owner `im-v2-platform-oncall` 映射到实际 Alertmanager receiver 并保留
  一次演练证据；受认证的单目标 replay 入口、事务审计与 runbook 已见
  [`durable-work-operator-replay.md`](durable-work-operator-replay.md)；
- 为各告警定义阈值、owner 和 runbook，并在故障演练中验证；
- 记录可用性、RPO/RTO、延迟和容量目标，形成有日期的压测与恢复报告。

在这些项目完成前，本文件只能证明代码提供了可测试的安全遥测入口，不能证明
生产监控或灾备能力已经建立。
