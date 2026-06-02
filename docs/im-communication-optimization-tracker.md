# IM 通讯系统优化跟踪

本文档用于跟踪通讯系统的优化项。规则：修复一个就在状态列标记完成，并补充落地说明。

| 状态 | 优化项 | 当前问题 | 修复记录 |
| --- | --- | --- | --- |
| 已完成 | 客户端待发队列 flush 判定 | `QueuedMessageFlushCoordinator` 判断是否还有待发消息时读取正式消息集合，实际待发消息存放在 `pendingMessages`，可能导致重连后无法自动补发。 | 已将 flush 判定切换为扫描 `pendingMessages`。 |
| 已完成 | 服务端 outbox/projection 延迟观测 | outbox backlog、projection lag、search lag 需要有统一跟踪口径。 | 已确认 `/internal/metrics`、Prometheus alert、Grafana dashboard 覆盖核心服务端 lag 指标。 |
| 已完成 | 端到端消息延迟观测 | 发送 ACK、对端可见、summary 更新之间还缺少端到端耗时口径。 | 已补充 TCPDriver ACK/canonical 口径说明，并新增 HTTP convergence 脚本覆盖 accepted、timeline 可见、summary 可见延迟。 |
| 已完成 | 热点会话写入压测 | 大群/高频会话可能受 sequence 分配、单会话写队列、fanout、summary 投影影响。 | 已补充 `http-hot-conversation-write.js` 专项压测脚本、运行说明和 go/no-go 阈值。 |
| 已完成 | 客户端主线程 store 首轮降压 | `gapSyncTargets` 在重连后按 summary 逐个线性扫描 conversations，summary 多时会放大 MainActor 消耗。 | 已改为先构建本地 latest sequence 字典，再按 summary 顺序判断补洞目标。 |
| 已完成 | 批量 domain event 降压 | `applyDomainEvents` 批量补偿时每条事件都会重新扫描本地消息构造依赖快照。 | 已改为批次内复用并增量维护依赖快照，避免每条事件全量扫描。 |
| 已完成 | 批量 summary read-state 降压 | `applyServerSummaryReadStates` 批量应用 summary 时逐条扫描 conversations 和消息序列。 | 已改为批次内构建 conversation index 和 latest sequence 字典。 |
| 已完成 | 批量 summary upsert 降压 | summary 分页追加和增量 upsert 逐条扫描 conversations，页越大 MainActor 消耗越高。 | 已改为批次内构建 conversation index，分页/增量 upsert 复用索引；增量删除也改为批量 remove。 |
| 已完成 | 客户端 store 深度降压 | `IMConversationStore` 仍有较多数组查找、排序、合并和 defer replay 在 MainActor 上执行。 | 已完成 gap sync、domain event、summary read-state、summary upsert、deferred replay 五个热点的批量化/索引化；更大范围长期索引改造后续基于 Instruments/压测数据再决策。 |
| 已完成 | 模型边界收敛 | 写模型、summary、owner delivery、timeline notice、搜索、通知、客户端缓存较多，需要明确 critical/最终一致/可重建边界。 | 已在本文档补充模型边界和重建策略。 |
| 已完成 | 客户端补偿链路开发诊断 | domain event gap、deferred replay、cache drop 已有计数，但 DEBUG 诊断页不可见。 | 已在开发诊断页展示 `IMDomainEventDebugMetrics` 核心计数。 |
| 已完成 | 客户端补偿健康快照 | 客户端补偿状态缺少稳定的汇总读取口径。 | 已新增 `IMConversationHealthSnapshot`，包含 domain cursor、deferred 积压、全量刷新会话数和 domain event metrics。 |
| 已完成 | 补偿链路生产上报聚合 | 客户端 domain event gap、timeline gap、deferred replay、stream snapshot 恢复还缺少生产级上报后端和聚合看板。 | 已新增 `api/im/client-health` 上报、服务端 `IMClientHealthMetrics` 聚合和 `/internal/metrics` Prometheus 指标；App 在 domain event 补偿同步后节流上报。 |
| 已完成 | 一致性策略文档化 | 消息、会话摘要、搜索、通知、客户端 UI 的一致性等级目前散落在实现中。 | 已在本文档补充一致性等级和修改规则。 |

## 一致性策略

| 链路 | 一致性等级 | 说明 | 修改规则 |
| --- | --- | --- | --- |
| 消息写入 | 强一致 | `ConversationMessage` 与对应 `ConversationDomainEvent` 必须在同一写事务边界内完成或失败。 | 不要把消息落库和 outbox 入库拆成两个无补偿的独立步骤。 |
| 单会话 timeline | 强顺序 | `serverSequence` / `timelineSequence` 是会话内排序和补洞依据。 | 所有新事件必须维护单会话单调序列，不允许客户端自行推断最终序号。 |
| 用户级事件投递 | 至少一次 + 有序补偿 | `OwnerDomainEventDelivery.ownerCursor` 是客户端断线补偿游标。 | TCP 只是低延迟通道，不能替代 `domain-events` HTTP 补偿接口。 |
| 会话摘要 | 最终一致 | 列表、未读、最后消息、置顶等来自 `ConversationUserSummary` 投影。 | 不要让发送 ACK 等待摘要投影完成；客户端应接受短暂滞后。 |
| 搜索索引 | 最终一致，可重建 | 搜索索引由 outbox side effect 或 worker 更新。 | 搜索结果必须能容忍延迟和陈旧命中，必要时回查主消息表过滤。 |
| 通知 | 最终一致，可丢弃重试 | 通知不应影响消息写入成功。 | APNS 或通知写入失败只能进入重试/告警，不应回滚消息。 |
| 客户端 UI | 本地乐观 + 事件对账 | pending 消息用 `clientMessageID` 与服务端 `messageCreated` 对账。 | 不要把 ACK 当作最终消息，最终状态必须由 domain event 或 HTTP 补偿收敛。 |

## 模型边界

| 模型 | 角色 | 是否事实来源 | 可重建性 |
| --- | --- | --- | --- |
| `ConversationMessage` | 消息写模型和 timeline 主数据。 | 是 | 不应依赖其他派生模型重建。 |
| `ConversationDomainEvent` | 写后事件 outbox，驱动投影、投递、通知、搜索。 | 是，事件事实来源 | 不应随意删除；失败状态可重试或 dead-letter。 |
| `ConversationUserSummary` | 用户维度会话列表读模型。 | 否 | 可从会话、成员、消息、读状态重建。 |
| `OwnerDomainEventDelivery` | 用户维度有序补偿流。 | 是，客户端补偿事实来源 | 可从 domain event 重放生成，但需要保留 cursor 单调性。 |
| `ConversationTimelineNotice` | 系统通知 timeline 投影。 | 否 | 可由对应 domain event 重建。 |
| 搜索索引 | 消息搜索读模型。 | 否 | 可由消息表重建。 |
| 通知队列 / APNS | 离线提醒副作用。 | 否 | 可重试，但不要求完全重建历史提醒。 |
| `IMConversationStore` / GRDB cache | 客户端本地读模型和离线快照。 | 否 | 可由 HTTP summary、domain-events、timeline 补偿恢复。 |

## 服务端观测落点

| 观测项 | 指标 / 面板 | 落点 |
| --- | --- | --- |
| outbox 处理量 | `im_outbox_processed_events_total` / `im_outbox_failed_events_total` | `/internal/metrics` |
| outbox backlog | `im_outbox_backlog_events` / `im_outbox_oldest_pending_age_millis` | `/internal/metrics`、Prometheus `IMServerOutboxBacklog`、Grafana `Outbox Backlog` |
| projection lag | `im_projection_lag_millis` | `/internal/metrics`、Prometheus `IMServerProjectionLag`、Grafana `Projection and Search Lag` |
| search lag | `im_search_lag_millis` / `im_search_stale_hits_total` | `/internal/metrics`、Prometheus `IMServerSearchLag`、Grafana `Projection and Search Lag` |
| replay 积压 | `im_replay_pending_events` / `im_replay_failed_events` | `/internal/metrics` |
| 热点会话保护 | `im_conversation_write_queue_depth` / `im_message_write_queue_rejected_total` / `im_hot_conversation_rejections_total` | `/internal/metrics`、Prometheus `IMServerConversationWriteQueueBacklog` |
| 客户端补偿健康 | `im_client_health_reports_total` / `im_client_deferred_domain_events` / `im_client_domain_event_cursor_gap_total` / `im_client_domain_event_sync_stopped_total` | 客户端 `api/im/client-health` 上报，服务端 `/internal/metrics` 聚合 |

## 客户端开发诊断落点

| 观测项 | 计数来源 | 落点 |
| --- | --- | --- |
| 补偿健康快照 | `IMConversationStore.healthSnapshot` | ClientKit 生产 telemetry 接入点 |
| 生产健康上报 | `SessionClient.reportIMClientHealth(...)` | `api/im/client-health`，App domain event 补偿同步后按 60s 最小间隔上报 |
| domain event cursor gap | `IMDomainEventDebugMetrics.catchUpCursorGap` | 我的 -> 开发诊断 -> IM 补偿链路 |
| 补偿中断 | `IMDomainEventDebugMetrics.catchUpStoppedBeforeCursorAdvance` | 我的 -> 开发诊断 -> IM 补偿链路 |
| deferred event 入队 / 回放 / 过期 | `deferredStored` / `deferredReplayApplied` / `deferredExpired` | 我的 -> 开发诊断 -> IM 补偿链路 |
| 触发全量刷新 | `deferredFullRefreshRequested` | 我的 -> 开发诊断 -> IM 补偿链路 |
| 非法事件 / DTO | `invalidDomainEventMetadata` / `invalidProjectionDTOs` | 我的 -> 开发诊断 -> IM 补偿链路 |
| 本地缓存丢弃 | `cacheDroppedCanonicalMessages` / `cacheDroppedTimelineNotices` | 我的 -> 开发诊断 -> IM 补偿链路 |

## 热点会话压测落点

| 内容 | 落点 | 说明 |
| --- | --- | --- |
| 专项脚本 | `IMServer/LoadTests/k6/http-hot-conversation-write.js` | 所有 VU 写同一个 conversation，覆盖 sequence、写队列、outbox、projection 和 fanout 压力。 |
| 运行说明 | `IMServer/LoadTests/README.md` | 包含 `local-hot-smoke`、`staging-hot-baseline`、`capacity-hot-target` 三档 profile。 |
| 环境变量模板 | `IMServer/LoadTests/staging-baseline.env.example` | 补充 metrics secret、metrics sample frequency、send interval 等配置。 |
| 验收阈值 | `IMServer/LoadTests/README.md` | 错误率、写入延迟、写队列、outbox backlog、projection lag、拒绝/转发失败等 go/no-go 条件。 |

## 端到端延迟压测落点

| 内容 | 落点 | 说明 |
| --- | --- | --- |
| TCP ACK / canonical 延迟 | `IMServer/LoadTests/TCPDriver` | 已输出 `ackLatencyMs`、`canonicalLatencyMs` 和成功率。 |
| HTTP 补偿收敛延迟 | `IMServer/LoadTests/k6/http-message-convergence.js` | 新增 accepted、timeline 可见、summary 可见三段延迟。 |
| 运行说明和阈值 | `IMServer/LoadTests/README.md` | 补充 `local-convergence-smoke`、`staging-convergence-baseline` profile 和 go/no-go 条件。 |
| 环境变量模板 | `IMServer/LoadTests/staging-baseline.env.example` | 补充 convergence timeout 和 poll interval。 |

## 客户端 MainActor 降压落点

| 内容 | 落点 | 说明 |
| --- | --- | --- |
| 补洞目标计算 | `IMConversationStore.gapSyncTargets(from:)` | 从 O(summary * conversation) 改为 O(summary + conversation)，保留服务端 summary 顺序。 |
| 批量事件依赖快照 | `IMConversationStore.applyDomainEvents(...)` | 批次内复用 `DependencySnapshot`，消费事件后增量维护 processed ID、owner high-watermark 和 message key。 |
| 批量 summary read-state | `IMConversationStore.applyServerSummaryReadStates(...)` | 批次内复用 conversation index 和 latest sequence 字典，避免逐条扫描。 |
| 批量 summary upsert | `IMConversationStore.applyConversationSummaryPage(...)` / `appendConversationSummaryWindow(...)` / `applyConversationSummaryChanges(...)` | 批次内复用 conversation index，避免每条 summary upsert 线性扫描；删除列表改为 Set + `removeAll`。 |
| deferred replay 降压 | `IMConversationStore.replayDeferredDomainEvents(...)` | 单次收集 deferred 事件，批内复用 `DependencySnapshot`，避免 replay 每条事件重新扫描本地消息。 |

## 客户端补偿生产上报落点

| 内容 | 落点 | 说明 |
| --- | --- | --- |
| 上报端点 | `POST api/im/client-health` | 登录用户上传 `IMConversationHealthSnapshot`、reason 和 reportedAt。 |
| ClientKit API | `SessionClient.reportIMClientHealth(...)` | 复用授权请求执行器，失败不影响 IM 同步主链路。 |
| App 触发点 | `ConversationRuntimeController.reportClientHealthIfNeeded(...)` | domain event 补偿同步后上报，默认 60s 节流。 |
| 服务端聚合 | `IMClientHealthMetrics` | 按 user 保存最近一次快照；累计类客户端计数按 delta 聚合，避免重复上报放大。 |
| Prometheus 指标 | `im_client_health_*` / `im_client_deferred_*` / `im_client_domain_event_*` | 通过 `/internal/metrics` 输出，可接 Grafana/Prometheus 告警。 |

## 修复顺序建议

1. 先修 correctness 问题，例如待发队列、游标推进、重复事件幂等。
2. 再补观测指标，拿到 ACK 延迟、投递延迟、outbox lag、projection lag、客户端补洞次数。
3. 基于压测结果处理热点会话写入和客户端 MainActor 压力。
4. 最后做架构级重构，避免在没有指标前扩大改动面。

## 后续基准驱动优化

当前已完成无长期状态一致性风险的批量化降压。若 Instruments 或压测仍显示 `IMConversationStore` 是主线程热点，再考虑引入长期维护的 conversation/message index；该类改造会扩大所有插入、删除、排序、cache restore 的一致性责任，不应在没有基准数据时继续扩大改动面。
