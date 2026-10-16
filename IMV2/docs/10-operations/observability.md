# V2 可观测性基线

状态：部分实现；不是生产发布批准。

## 已实现的边界

房间恢复的持久责任由提交事务更新的 `realtime_dirty_room_heads` 记录。
Room Owner 的实时通知降低延迟，Host 的独立检查补齐丢失的通知；确认按精确修订、水位、
控制版本和激活令牌执行。确认响应丢失时，既有检查周期会唤醒 worker 重试保留的确认。
个人 `user_sync_wake_outbox` 仍由独立 relay 处理。
Gateway 按服务端成员覆盖向在线设备投递；Actor 成功返回表示对应协议的接收进度，
不代表客户端已经持久应用。设备游标与日志补拉继续决定客户端恢复。
旧房间 wake 表、触发器与 relay 已删除，当前 Schema 检查拒绝残留旧表的数据库。

候选版本已经移除 NATS 运行依赖。Actor 路由的登记/续租、覆盖失效、队列项数和字节、
远端接受/超时/拒绝、唤醒最老年龄与重试仍应接入部署级监控；未导出的指标不能当作健康。

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

## 物理连接占用与实时路由查询

`im_v2_database_loan_observation_*` 按封闭业务来源区分发送、准备读取、
房间日志拉取、订阅、恢复、同步、在线租约、生命周期与续租等工作。
`other` 保留尚未标明来源的实际工作，不能按猜测重新归类。标签不含用户、
房间、ActorID、SQL 或数据库地址；物理池别名只计一次。

- `active{source,stage}` / `oldest_ms{source,stage}`：当前排队、等待驱动、
  SQL 在途或 SQL 之间的占用及最老年龄。
- `stage_duration_{sum,count,max}{source,stage}`：已完成阶段间隔；单位为毫秒。
- `held_duration_{sum,count,max}{source}`：准入授予到实际数据库 Future 结束，
  包含驱动等待与事务收尾。取消调用方不提前结束这一观测。
- `sql_duration_{sum,count,max}{source,phase}`：实际 SQL Future 的完成耗时。
  日志读取区分 `fence`、`read_body`、`transaction_control` 与 `other`。
  包含驱动、网络和调度等待；并发 SQL 可以重叠，不能相加当作事务墙时。

嵌套事务与连接操作复用原借用句柄，观测不增加 SQL、连接或任务。
`awaiting_driver` 到实际借用回调的时间可能包括 Fluent 的 BEGIN，
`between_sql` 也可能包括未通过包装器执行的外层 Fluent COMMIT；不能直接
把它们命名为纯连接获取时间或纯应用空闲时间。

`im_v2_database_work_interactive_read_*{purpose}` 按普通读取 `ordinary` 和
必要覆盖授权 `coverage_authorization` 记录 `in_flight`、`queued`、
`admissions_total`、按固定 reason 分类的 `rejections_total`、
`cancellations_total` 和 `queue_wait_milliseconds` 直方图。这是原
interactiveRead 聚合指标的分区，两目的计数之和应与聚合一致，并不表示
额外连接或许可。真实授予、排队取消及原截止时间超时分别计数；等待时间
包含这些已离队请求，不能只按业务成功数作分母。客户端不能指定purpose。

旧 route-store 查询门及其 `im_v2_actor_realtime_route_query_*` 指标已经移除。
热路径验证须观察 `route_lookup`/`realtime_owner_snapshot` 实际SQL Future
以及ShardTransport缓存miss、前台/后台Receptionist lookup；后台发现仍计数。
`max` 均为进程生命周期高水位，不能冒充测量窗口内百分位。

压测分析必须披露计数基线与尾部采样缺口。缺报告、缺节点、缺基线不能补零，
未完成的压测不能作容量验收。实际复现与受控竞争证据见
[`actor-realtime-benchmark.md`](actor-realtime-benchmark.md)。

## 恢复链路的分段与实际占用

`im_v2_room_directory_recovery_*{stage}` 导出 active、oldest_milliseconds、
started_total、completed_total、items_started_total、duration_milliseconds_sum/max。
固定阶段为 cold_caller_wait、actual_resolution、host_caller_wait、settled_callback。
actual_resolution 跟踪共享解析任务，普通发送/读取也会触发，调用者取消不结束它；
cold_caller_wait 与实际解析可能重叠。host_caller_wait 包括 Transport 准入前拒绝，
Directory 的 recovery_host_cohorts/items_total 不能当成实际物理 RPC 次数。

`im_v2_room_transport_recovery_*{stage}` 使用相同阶段量，区分
session_caller_wait 与 actual_dispatch。前者记录恢复批调用者等待共享会话，
不表示共享握手任务终止；后者从实际 dispatch 登记到其操作真实返回。
recovery_batch_caller_timeouts/cancellations_total 不提前清除 actual_dispatch；
recovery_batch_rejected_global/peer_total 只统计恢复批自己的实际槽位拒绝。
本地 dispatch 结束不证明远端独立任务已经结束。

`im_v2_room_recovery_batch_*{purpose}` 区分 states_cohort 与 scalar：
in_flight、items、oldest_milliseconds 记录实际批仍占用的槽位；
started_total/completed_total、duration_milliseconds_sum/max 覆盖从占位、
等待数据库准入、实际查询到结果处理。busy_before_acquire_total 表示未进入
数据库准入就被拒绝，不含内部延后 flush。物理 URL/schema 归属只聚合一次，
逻辑别名不会重复计算同一个批处理器。

这些指标不新增 SQL、后台轮询或执行任务。调用者等待与实际生命周期可能重叠，
不能相加；sum/completed 的差分是已完成工作均值，oldest 反映尚未完成工作，
max 是进程生命周期最大值，不能充当窗口 p99。未接入 Host 来源时不补零，
已接入的固定枚举阶段始终输出零值基线。

## 仍需交付

- 将结构化日志接入受控的集中采集和告警系统，并建立保留/访问策略；
- 补齐 Push、Actor 路由（登记/续租、队列预算、接受/拒绝/超时、覆盖失效）、
  shard lease 和容量利用率指标，并基于批准的负载报告为 durable-work
  ready/scheduled backlog 设定容量阈值；Redis 不属于当前 V2 correctness path；
- 将角色 owner `im-v2-platform-oncall` 映射到实际 Alertmanager receiver 并保留
  一次演练证据；受认证的单目标 replay 入口、事务审计与 runbook 已见
  [`durable-work-operator-replay.md`](durable-work-operator-replay.md)；
- 为各告警定义阈值、owner 和 runbook，并在故障演练中验证；
- 记录可用性、RPO/RTO、延迟和容量目标，形成有日期的压测与恢复报告。

在这些项目完成前，本文件只能证明代码提供了可测试的安全遥测入口，不能证明
生产监控或灾备能力已经建立。
# Physical Sync loan fairness

`im_v2_database_loan_{in_flight,queued,granted_total,rejected_total}` uses the fixed classes `ordinary`, `sync`, `activation`, and `renewal`. `ordinary` measures general work alone. Sum `ordinary + sync + activation` to measure the shared non-renewal budget; the benchmark retains9 such slots, activation capped2, plus2 renewal slots and11 total. The additional label creates no connections or queue capacity. When both Sync and general requests are eligible, actual grants alternate their FIFO heads; idle capacity remains available and submitted work holds its loan until actual completion.

These physical-loan gauges differ from `im_v2_database_work_*{class="sync"}`, which measures logical work admission and includes time awaiting physical borrowing. A logical Sync slot can be occupied without owning a driver connection. Diagnostic `source="sync"` observations and the trusted loan scheduling purpose are distinct; only the actual routed Sync operation establishes that purpose before its first route borrow. Missing source or component samples must not be filled with zero.

### Actor 实时分片倾斜与推送回调

`im_v2_actor_realtime_partition_retained_{bindings,topics}_max` 是本机分片中保留的已安装订阅负载最大值，不包括 staging；过期内容沿现有回收路径删除，因此不是实时 Ready 权限计数。`partition_publications_active_max` 统计实际尚未结算的发布占用。带 `peak_lifetime` 的值是进程生命周期峰值，不是当前阶段速率。跨节点比较这些最大值应取 MAX，不求和。

`publication_recipient_*{kind}` 记录验证后选中的 Gateway session 集合，包含空集合；成员不是客户端设备数，也不是成功收到消息的数量。`delivery_target_*{kind}` 的 active/oldest 及完成时延来自实际本地回调调用和返回，包括失败；调用方取消不提前释放。远端调用超时导致本地返回不能证明远端业务或客户端写入已结束。完成 count 是物理回调次数，可能与合并前的发布次数不同。

内部观测归属沿实际 Delivery worker 生命周期维护，使用其已有容量，不新增任务、SQL 或准入。`delivery_observation_owners` 和 `delivery_observation_capacity` 描述当前配置范围；`skew_observation_ownership_violations_total` 非零时不能宣称 active/oldest 归属完整。公开标签仅四种固定 topic kind，不输出 room/user/peer/session/partition IDs。采样是本机诊断快照，不是全局原子状态。

### Shared Host room-read collector

`im_v2_room_read_collector_*` exposes pending items, retained items and bytes,
ordinary retained items, actual batches, oldest queued/actual milliseconds,
and lifetime batches started/items selected/items settled. Physical URL/schema
owners are deduplicated before aggregation: occupancies and counters sum,
oldest ages take the maximum. A scrape is a set of component snapshots rather
than one atomic fleet snapshot. No room, user or request identifier is a label.

Retained items include queued callers and selected items whose actual work has
not settled. Streaming pure-pull settlement releases that item's retention
after its subgroup transaction completes; the actual batch remains occupied
until all remaining SQL and callbacks return. Queued cancellation/expiry does
not increment selected or settled counters. Thus selected minus settled counts
outstanding selected items, while actual batches can remain nonzero after the
last item settles briefly until the executor returns and releases its slot.

`im_v2_room_recovery_batch_*{purpose="pure_pull"}` records whole collector
batch lifetime, including logical admission and sequential SQL subgroups.
One collector batch is not one PostgreSQL transaction. Actual subgroup SQL
counts and holding time must be read from the existing `group_event_pull`
physical-loan observations. These overlapping timings must not be added.

### Gateway 房间恢复批次推进

`im_v2_gateway_registry_recovery_work_total` 使用固定 `kind=authorization|prepared` 和 `event=tasks_started|tasks_settled|scopes_started|scopes_settled`。这是进程生命周期累计值；取同一进程、同一观测窗口的差值，才能比较授权输入量与后续提示保留的推进量。一个任务可以依次处理多个作用域，任务数与作用域数不能互换。作用域 settled 包括成功、失败和过期后回授权队列；prepared settled 不等于客户端已应用消息。

`im_v2_gateway_registry_recovery_queued_prepared_expired_total` 仅累计排队期间因原权限观察期限到期而实际移除的准备证明。反复分类不会重复计数，token/session 变化也不计为权限期限到期。当前正在执行的证明过期不属于这个 queued 指标。

兴趣取得、房间/Presence 授权准备与 prepared/其他 scope 的短交接调度各有最多四个根任务名额。合计最多12个根任务，不等于12个查询；实际授权尝试另外计量，仍最多四个，下游物理 recovery RPC 四槽全局共享。已取得精确兴趣回执的 scope 可以直接查询，其他 scope 的冷激活等待不占查询槽；Presence 查询等待属于 query root，不能占 control。query root 是准备请求任务，不等于 SQL 次数，Presence 实际查询由其独立所有者指标计量。prepared 每个最多连续交接128个作用域，每次只领取当前一项；其余项仍可由其他任务推进。短交接任务在有界出站 offer 返回后释放名额，socket 实际等待属于 outbound_retention。原30秒权限期限不因排队、换批或等待 writer 延长。现有 desired/queued/actual_scopes/awaiting_retention 是当前 Gauge，不能以端点差值代替完成次数；最老需求年龄包含压测发送相位开始前的积压。

Presence 查询所有者使用独立的 `im_v2_gateway_presence_observation_work` 与 `im_v2_gateway_presence_observation_oldest_milliseconds`。`actual_queries` 单位为 query_batches，`queued_keys` 为 request_keys，`result_tickets`/`settling_tickets`/`retired_tickets` 为 target_tickets，`owned_jobs` 为 batch_jobs，`waiters` 为 waiters，`result_positions` 为 result_keys（按 batch/request 精确计量的交付责任）。退休票据是结果责任的失效代际子集，不能与其他阶段相加当作连接数量；查询批次数也不等于物理数据库会话数。所有年龄来自原始单调时间，不因重试重新开始。

`im_v2_gateway_registry_recovery_scopes{stage="authorization_returns"}` 统计实际授权任务持有的结果返回位。授权项出队时同步预留位置；结果返回时按任务、生命周期和作用域代次精确消费，再原子转移到有界轮转队列。权威总账本包括 queued、authorization_returns、selected_handoff 和 outbound，总数不超过原1024预算；这不是新增队列容量。部分回调只释放对应返回位，外层任务实际结束时才回收尚未消费的位置。关闭或取消不提前释放实际任务持有的返回位。对应 oldest 指标从选入授权任务时起算，与 actual_scopes 等阶段可能重叠，不能相加作为延迟。

### Gateway recovery phase ownership

Recovery pressure distinguishes `actual` permission/control tasks from
`outbound_retention` connection-owned handoffs. `inline_retention` remains the
actual ingress-consumer path. A blocked connection writer can keep an outbound
handoff retained while query `actual` is zero; this does not mean shutdown has
finished. Inspect stage age together with desired H, proof expiry, scope
lifecycle and write-admission outcome. Connection close revokes admission first;
actual SQL and outbound cleanup are drained separately. Counts must not be
added across stages as if they were distinct connections.

连接恢复尝试使用 `im_v2_gateway_recovery_attempts` 与 `im_v2_gateway_recovery_attempt_oldest_milliseconds`：interest_activation、query_root、control 单位 root_tasks，authorization_query 单位 query_attempts。query_root 包括 Presence 准备等待，实际 Presence SQL 使用其独立 query_batches 指标。旧 scope actual / actual_scopes 是同一组根任务持有的 scope 别名，不能相加；出站接管后的工作属于 outbound_retention。

`im_v2_gateway_retired_recovery_writer_work` 与 `im_v2_gateway_retired_recovery_writer_oldest_milliseconds` 分别报告 retained_streams（streams）和 actual_drains（worker_tasks）。已注销流仍占连接 Directory 操作预算，实际 drain worker 最多16个；计数重叠且单位不同，不可相加。原退休/实际开始时间不因等待重置；归零须基于实际 worker 退出，不能凭取消或从活跃连接索引删除。

Presence 总位置上限1024覆盖排队键、实际查询键与已返回的结果位置。实际查询结束后，旧结果按 batch/request 保留位置直至目标票据真实结算；同键新设备可在剩余容量内查询。旧回调不能释放后继的 active 查询键，旧 socket 不再通过键占用堵住查询入口。

### Recovery position ledger

`im_v2_gateway_recovery_positions_occupied` is the authoritative admission total;
`im_v2_gateway_recovery_positions_capacity` is its fixed1024 limit.
`im_v2_gateway_recovery_positions{stage}` partitions it into queued,
authorization_returns, selected_handoff and outbound. Prepared queued proofs
remain queued. Scope/root metrics overlap and must not be added to this total.
`im_v2_gateway_recovery_position_oldest_milliseconds{stage}` retains original
position age; all is the maximum stage age. Empty fixed stages report zero.
A control root can process128 scopes: its age is cohort age, not one offer delay.
Load-side drained is not sufficient when server shutdown reports drain_timeout.

### Recovery scheduling diagnostics

`/metrics/recovery-scheduling` renders a fixed synchronous snapshot without
awaiting unrelated Registry or provider metrics. The optional benchmark flag
`--recovery-scheduling-metrics` samples it separately; load and quality gates
remain unchanged.

`im_v2_gateway_recovery_scheduling_observations_total{phase}` counts completed
spans. Duration total/max families report cumulative elapsed milliseconds and
the process-lifetime maximum, respectively. Fixed phases are pump pass, short
offer, interest provider, query provider and control cohort. Pump measures
synchronous scheduling work; short offer includes actor round trips; interest
provider is a logical shared-interest call that may cache or join; room query
provider includes callee queuing and callbacks, not pure SQL/RPC. Presence SQL
has separate execution metrics. Control cohort covers the entire root. These
spans overlap and must not be summed as independent latency or CPU time.

`im_v2_gateway_recovery_scheduling_scan_entries_total{source}` counts actual
visits to desired and queued entries, including repeated visits. Compare
interval deltas with completed spans and stage ages. Completed-duration metrics
do not expose an operation that is still stuck; retain the ownership/oldest
age metrics and report sampling failures explicitly.

### Physical send-owner root stages

Supporting providers expose im_v2_send_operation_owner_batch_roots{stage}
with fixed stages acquiring_connection, awaiting_quota, and quota_turn.
This partitions retained roots through actual settlement and cleanup, and
must sum to the provider's in_flight_batches. Quota turn is an exclusive
owner lifecycle, not an SQL transaction count: isolation/fallback can execute
several original transactions under one turn.

Unsupported providers omit this family rather than claiming zero stages.
Aggregates emit it only if every provider supplies stage ownership.
Preparation-owner snapshots do not acquire send-owner pipeline semantics.
Standby roots remain inside existing root/item/byte/deadline budgets.
