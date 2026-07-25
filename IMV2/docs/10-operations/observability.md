# V2 可观测性基线

状态：部分实现；不是生产发布批准。

## 已实现的边界

PostgreSQL durable-work 指标是 worker 健康和积压的权威观测面。可选 NATS 只会在
durable publication 之后发送最佳努力 wake hint；提示发布失败不会改变 outbox、plan
或 delivery 状态，因此不会产生“broker 成功即投递成功”的指标语义。当前 adapter
也没有 NATS connection、publish-confirmation、consumer lag、reconnect 或 broker
availability 指标；启用 NATS 前不能把这些缺失指标误解为健康。

`V2TelemetrySink` 是 Server 的可注入边界。网关命令和一次 fan-out pipeline
进度分别写入 `V2TelemetryEvent`；生产应用使用 `V2ApplicationTelemetrySink`
输出结构化日志，测试使用 `V2InMemoryTelemetrySink` 断言事件内容。

当前结构化事件：

| 事件 | 字段 | 用途 |
| --- | --- | --- |
| `im_v2.gateway.command` | `trace_id`、有限 `command`、`outcome`、有限 `rejection`、`elapsed_ms` | 接受/拒绝/失败命令计数与延迟 |
| `im_v2.fanout.progress` | `trace_id`、outbox/delivery 的 claimed/published/committed/released/**paused** 聚合数、`stale_route_deliveries`、`elapsed_ms` | durable fan-out 进度、重试、暂停与路由切换异常；纯空轮询不发事件，避免高频日志噪声 |
| `im_v2.fanout.failure` | `trace_id`、有限 `stage`、`elapsed_ms` | relay/delivery/pipeline 失败告警 |

`trace_id` 是每次网关请求或 pipeline 运行生成的随机 UUID，只用于日志关联；
它不能作为 Prometheus/StatsD 等指标的标签。

`V2PrometheusTelemetrySink` 会与结构化日志 sink 同时接收同一封闭事件词汇，
并聚合为稳定的
Prometheus 0.0.4 文本：网关命令计数/耗时、fan-out run 耗时、outbox/delivery
进度及按 stage 的失败计数。它丢弃 trace ID，并对意外的负聚合数按零处理；
测试断言指标中不存在 trace ID、room/user 字段或任意输入文本。该 exporter
只通过独立的 `/metrics` HTTP listener 暴露：运行时强制
`IM_V2_METRICS_HOST` 为 `127.0.0.1` 或 `::1`，且要求显式端口。采集器因此
必须与服务在同一 host/pod 网络命名空间；该 endpoint 带 `no-store` 响应头，
绝不能挂到公开媒体边缘或 realtime TLS 端口。

同一私有 endpoint 还会在每次抓取时读取进程内
`V2DeviceConnectionRegistry` 的只读快照，并输出两个无标签 Gauge：
`im_v2_gateway_active_devices` 与
`im_v2_gateway_active_connections`。两者只计已认证且仍被注册的连接；认证、
EOF、协议错误和设备撤销都会走同一注销路径。它们仅描述当前 gateway
进程，不可直接当作整个集群的在线人数，集群级聚合应由采集系统完成。

网关 NIO handler 还维护独立的进程内 transport 快照：
`im_v2_gateway_transport_active_connections` 包含认证前 socket，
`im_v2_gateway_inbound_queue_peak_bytes` 是进程启动以来的入站待处理字节峰值，
`im_v2_gateway_connection_closures_total` 只按固定原因
(`peer_disconnected`、`idle_timeout`、`inbound_queue_limit`、`frame_limit_violation`、`request_failure`、
`device_revoked`) 分组。它用于定位 idle heartbeat、队列背压和撤销断连，
不保存或输出任意连接 ID、IP、用户、设备或请求 ID。

同一私有 endpoint 还在每次抓取时读取 PostgreSQL 的 durable-work 快照。
`im_v2_durable_work_metrics_available` 为 `0` 表示本次数据库快照失败，但
`/metrics` 本身仍保持可抓取；该值必须被单独告警。快照包含
`im_v2_room_outbox_backlog`、`im_v2_fanout_plans_open`、
`im_v2_fanout_delivery_backlog`、
`im_v2_sync_pending_records_across_devices` 与
`im_v2_sync_reset_pending_devices`。room outbox 和投递只使用固定的
`ready`/`leased`/`scheduled`/`paused` 标签；`scheduled` 表示仍处于退避等待期，
`paused` 表示重试预算已耗尽、必须经受控
operator replay 才会再次入队的 durable row，绝不能将它当作已投递或已终态。
投递统计覆盖本副本部署 registry 显式配置的全部逻辑 user-shard bucket，
但不把 bucket 值作为标签。同步积压按每个 ready device cursor 计算，故多设备
用户会被分别计入；这反映实际待同步工作量，而不是独立消息数。

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
CI 通过 `scripts/check_v2_prometheus_rules.sh` 用 `promtool` 校验二者。
本地账号栈的 `verify_v2_local_account_stack.sh` 还从 gateway 容器内部探测
loopback `/metrics`，断言 `no-store`、未发布 9464 端口及 ready/leased/scheduled/paused
完整状态词汇；它由此拒绝使用旧镜像的“健康但缺指标”状态。

所有 durable-work 告警使用角色 owner `im-v2-platform-oncall`：部署 Alertmanager
必须将这个标签路由至已批准的 V2 平台值班轮值，不能把具体个人或 token 写进规则。

| 告警 | 阈值 / 持续时间 | 严重度 | 处置 |
| --- | --- | --- | --- |
| `IMV2DurableWorkMetricsUnavailable` | scrape 值为 `0` 或指标缺失，5 分钟 | critical | 恢复 PostgreSQL metrics source 后确认 backlog；不能据此执行 replay |
| `IMV2PausedRoomOutbox` | paused outbox 大于 `0`，2 分钟 | critical | 按 replay runbook 先修复根因再单目标回放 |
| `IMV2PausedFanoutDelivery` | paused delivery 大于 `0`，2 分钟 | critical | 按 replay runbook 先修复根因再单目标回放 |
| `IMV2FanoutFailureRate` | 任意 fan-out failure 持续 10 分钟 | warning | 调查依赖、路由与失败 stage，避免演变为 paused |

paused 阈值刻意为零；它代表重试预算已耗尽的正确性事件，不能依靠容量基准把它
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
