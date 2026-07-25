# IM V2 文档入口

V2 是一条没有历史兼容层的 greenfield 路径。本文档只描述当前实现和未验证边界；它不构成生产发布或容量批准。

## 先读什么

| 目标 | 文档 |
| --- | --- |
| 了解当前组件、数据流、群聊和 NATS 边界 | [当前架构](../../docs/current-system-map.md) |
| 判断某项能力是否已实现及其验证等级 | [implementation status](implementation-status.md) |
| 查找已接受或待批准的设计决定 | [ADR register](ADR-REGISTER.md) |
| 使用 100k 成员配置或准备压测 | [standard 100k contract](09-capacity/standard-100k.md) |
| 处理 paused durable work | [operator replay runbook](10-operations/durable-work-operator-replay.md) |
| 查看 metrics、告警与尚缺运行证据 | [observability](10-operations/observability.md) |
| 执行用户分片迁移 | [user-shard migration runbook](10-operations/user-shard-migration-runbook.md) |

## 阅读约定

- **已实现**：源码中存在对应运行路径，并有至少相应层级的测试或本机验证。它不自动等于生产可用。
- **Partial / Unproven**：可能已有协议、存储或测试边界，但仍缺真实设备、部署、故障、容量或审批证据。
- **ADR 待批准**：当前代码遵循候选方向，但容量、运维或安全负责人尚未确认最终政策。
- **本地验证**：只证明明确记录的本机/CI 环境；不能外推为真实 WebAuthn、APNs、Alertmanager、PITR、容量或生产发布结论。

所有 V2 配置、运行入口和本机隔离栈以 [IMV2Server README](../../IMV2Server/README.md) 与 `IMV2/` 下脚本为准。
