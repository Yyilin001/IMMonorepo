# IM V2 文档入口

V2 是一条没有历史兼容层的 greenfield 路径。本文档只描述当前实现和未验证边界；它不构成生产发布或容量批准。

## 先读什么

| 目标 | 文档 |
| --- | --- |
| 了解当前组件、数据流、群聊和 NATS 边界 | [当前架构](../../docs/current-system-map.md) |
| 构建 Vapor 5 beta 服务与理解资源生命周期 | [Vapor 5 迁移](00-foundation/vapor5-migration.md) |
| 房间 Virtual Actor 合同与实施验收 | [当前合同](../../docs/reviews/room-virtual-actor-contract.md) · [验证状态](../../docs/reviews/virtual-actor/README.md) · [并行实施方案](00-foundation/virtual-actor-parallel-plan.md) |
| 判断能力、证据等级与当前实施路线 | [implementation status](implementation-status.md) |
| 查看仍需部署、设备、容量或审批闭环的风险 | [residual risk register](10-operations/residual-risk-register.md) |
| 查找已接受或待批准的设计决定 | [ADR register](ADR-REGISTER.md) |
| 使用 100k 成员配置或准备压测 | [standard 100k contract](09-capacity/standard-100k.md) |
| 处理 paused durable work | [operator replay runbook](10-operations/durable-work-operator-replay.md) |
| 执行已批准的单账号禁用 | [account-disable runbook](10-operations/account-disable-runbook.md) |
| 查看 metrics、告警与尚缺运行证据 | [observability](10-operations/observability.md) |
| 配置静态用户分片 | [用户分片部署范围](10-operations/user-shard-migration-runbook.md) |
| 个人快照构建与恢复 | [个人快照运维](10-operations/personal-snapshot-runbook.md) |
| 当前会话同步与恢复 | [客户端排序与房间恢复](../../docs/reviews/client-owned-conversation-sync-plan.md) |
| 公共消息房间日志恢复决策 | [ADR-017](00-foundation/ADR-017-direct-room-event-log.md) |
| 配置私聊 room-log command credit 与原子微批 | [command-credit runbook](10-operations/direct-room-log-command-credit-runbook.md) |
| 灰度 direct-send policy cache | [direct-send policy cache runbook](10-operations/direct-send-policy-cache-runbook.md) |
| 用本地文件系统卷验证附件上传/扫描/下载 | [本地文件系统媒体测试](10-operations/local-filesystem-media-test.md) |
| 查看旧版私聊 room-log 的限定容量实测 | [2026-08-27 R34：50k 在线共享帧 A/B](09-capacity/direct-room-log-50000-shared-frame-ab-r34-2026-08-27.md) |
| 查看更早的 room-log 梯度基线 | [2026-08-27 R29：50k 在线、500–5,000 msg/s](09-capacity/direct-room-log-50000-gradient-r29-2026-08-27.md) |
| 查看早期直聊 room-log 基线 | [2026-08-19 benchmark](09-capacity/direct-room-log-benchmark-2026-08-19.md) |
| 查看被取代的历史压测记录 | [容量归档目录](09-capacity/archive/README.md) |

## 阅读约定

- **已实现**：源码中存在对应运行路径，并有至少相应层级的测试或本机验证。它不自动等于生产可用。
- **Partial / Unproven**：可能已有协议、存储或测试边界，但仍缺真实设备、部署、故障、容量或审批证据。
- **ADR 待批准**：当前代码遵循候选方向，但容量、运维或安全负责人尚未确认最终政策。
- **本地验证**：只证明明确记录的本机自动化环境；不能外推为真实 WebAuthn、APNs、Alertmanager、PITR、容量或生产发布结论。

所有 V2 配置、运行入口和本机隔离栈以 [IMV2Server README](../../IMV2Server/README.md) 与 `IMV2/` 下脚本为准。
已完成的演进记录只保留在 Git 历史中，不在当前运行文档内维护重复时间线。
