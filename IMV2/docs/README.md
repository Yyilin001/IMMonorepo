# IM V2 文档入口

V2 是一条没有历史兼容层的 从零构建的运行路径。本文档只描述当前实现和未验证边界；它不构成生产发布或容量批准。

## 先读什么

| 目标 | 文档 |
| --- | --- |
| 了解当前组件、数据流与群聊边界 | [当前架构](../../docs/current-system-map.md) |
| 构建 Vapor 5 beta 服务与理解资源生命周期 | [Vapor 5 迁移](00-foundation/vapor5-migration.md) |
| 房间 Virtual Actor 合同与实施验收 | [当前合同](../../docs/reviews/room-virtual-actor-contract.md) · [验证状态](../../docs/reviews/virtual-actor/README.md) |
| 判断能力、证据等级与当前实施路线 | [实施状态](implementation-status.md) |
| 查看仍需部署、设备、容量或审批闭环的风险 | [开放风险登记表](10-operations/residual-risk-register.md) |
| 查找已接受或待批准的设计决定 | [设计决定登记册](ADR-REGISTER.md) |
| 使用 100k 成员配置或准备压测 | [十万成员容量合同](09-capacity/standard-100k.md) |
| 发布服务、回退配置或镜像、分流 Host 和数据库故障 | [部署与回滚手册](10-operations/single-node-performance-rollout-runbook.md) |
| 处理已暂停的持久任务 | [运维重放手册](10-operations/durable-work-operator-replay.md) |
| 执行已批准的单账号禁用 | [账户禁用手册](10-operations/account-disable-runbook.md) |
| 查看指标、告警与尚缺运行证据 | [可观测性说明](10-operations/observability.md) |
| 配置静态用户分片 | [用户分片部署范围](10-operations/user-shard-migration-runbook.md) |
| 个人快照构建与恢复 | [个人快照运维](10-operations/personal-snapshot-runbook.md) |
| 当前会话同步与恢复 | [客户端排序与房间恢复](../../docs/reviews/client-owned-conversation-sync-plan.md) |
| 公共消息房间日志恢复决策 | [ADR-017](00-foundation/ADR-017-direct-room-event-log.md) |
| 核对发送权限服务的启动与恢复 | [私聊发送策略缓存运维手册](10-operations/direct-send-policy-cache-runbook.md) |
| 用本地文件系统卷验证附件上传/扫描/下载 | [本地文件系统媒体测试](10-operations/local-filesystem-media-test.md) |
| 消息发送、成功记录及结果恢复 | [当前发送合同](../../docs/reviews/message-send-contract.md) |
| 当前 Actor 发送链路的性能测量 | [运行与优化记录](../../docs/reviews/send-throughput-5000-20261008.zh-CN.md) |

## 容量与压测入口

| 要测什么 | 复现方法与结果 | 读数边界 |
| --- | --- | --- |
| 固定 10,000 在线，增加业务节点 | [横向扩展实验](09-capacity/horizontal-scaling-2026-10-16.md) | 对照同一物理宿主机上的 1、2、4 节点，使用共享 PostgreSQL。 |
| 固定每用户活跃度，增加用户和服务器 | [用户增长与在线扩容](09-capacity/horizontal-user-growth.md) | 已测规模及扩容过程；独立物理服务器的用户上限仍待测量。 |
| 认证连接上的业务负载、恢复突发与 Actor 路由 | [高活跃场景](09-capacity/high-active-10000-load-test.md) · [恢复突发](09-capacity/gateway-recovery-burst-driver.md) · [Actor 压测手册](10-operations/actor-realtime-benchmark.md) | 按场景分别记录发送 ACK、前台追平和队列积压。 |
| TLS 写队列中的慢读者隔离 | [正常、部分暂停与全部暂停对照](09-capacity/gateway-10000-slow-reader-transport-2026-09-26.md) | 原始字节传输；全暂停后完整积压排空仍未通过。 |

## 阅读约定

- **已实现**：源码中存在对应运行路径，并有至少相应层级的测试或本机验证。它不自动等于生产可用。
- **部分实现 / 尚未验证**：可能已有协议、存储或测试边界，但仍缺真实设备、部署、故障、容量或审批证据。
- **ADR 待批准**：当前代码遵循候选方向，但容量、运维或安全负责人尚未确认最终政策。
- **本地验证**：只证明明确记录的本机自动化环境；不能外推为真实 WebAuthn、APNs、Alertmanager、PITR、容量或生产发布结论。

所有 V2 配置、运行入口和本机隔离栈以 [服务端说明](../../IMV2Server/README.md) 与 `IMV2/` 下脚本为准。
已完成的演进记录只保留在 Git 历史中，不在当前运行文档内维护重复时间线。
