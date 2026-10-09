# Virtual Actor 实施与验证工件

2026-09-24 按用户要求先完成功能、暂缓性能调优，**Room Virtual Actor 本轮功能落地已完成**。业务入口、生命周期与房间写者已接入；[#19 单 owner 故障批查询](g5-owner-fault-functional-evidence.md)和[最新冻结源码的完整 Linux/Vapor 5 回归](g5-linux-regression-evidence.md)通过。首次完整回归曾出现未定位的测试进程停滞，同产物隔离复现及第二次完整回归均通过；原失败与诊断保留，不称根因已修复。

业务基线固定为 `f1cdd78d6a21bf0ae23da627c0710c65115236aa`（Vapor 5 beta.2 / Swift 6.4）；原工作目录未提交的 Distributed Actor 改动不参与。子代理统一 GPT-6 Sol / High。整体设计见[并行实施方案](https://github.com/Yyilin001/IMMonorepo/blob/21fb3cc8/IMV2/docs/00-foundation/virtual-actor-parallel-plan.md)，当前行为以[房间 Virtual Actor 合同](../room-virtual-actor-contract.md)为准。

## 功能实现与验证

| 范围 | 当前结果与证据 |
| --- | --- |
| Swift / Vapor / DistributedCluster 兼容 | [固定 revision 的 Linux Release 双进程探针及 ServerApp 构建](p0-evidence.md)、[有界传输与真实 mTLS](p0-bounded-transport-evidence.md)通过；生产源码 `2772c846` 的七产品 Linux Release 也已通过，见[构建记录](g5-same-owner-performance.md#allocation-candidate-2772c846) |
| 逻辑寻址与公共契约 | Contracts、Runtime、Cluster、Application 及 typed clients 已接线；业务使用 RoomID，由 Directory/RoomRef 处理物理位置。见[当前合同](../room-virtual-actor-contract.md)、[能力目录](capability-catalog.md)与[本机调用边界](r3-local-capability-evidence.md) |
| 激活、恢复、回收与接管 | [真实 Host/PG 生命周期](g2-host-pg-lifecycle-evidence.md)、[双 Host 分区及旧实例恢复](g6-multihost-evidence.md)、[慢事务和队列排空](g5-host-pg-drain-evidence.md)、[实际应用 SIGTERM](g2-real-app-sigterm-evidence.md)通过 |
| 远端调用与领域接线 | [caller-only Gateway → 独立 Host](g3-caller-only-gateway-evidence.md)、[远程共享合批](g3-remote-batch-evidence.md)、[Account/Operator Linux 应用栈](i1-application-smoke-harness.md)通过 |
| 房间写者与后台工作 | [写者台账](writer-ledger.md)已逐项登记入口与持久边界；[维护/压缩竞态](d6-maintenance-evidence.md)、[取消与 retention/review/import 接管](g2-pg-cancellation-maintenance-evidence.md)通过。最新只读接线复核未发现新的已确认缺口 |
| 故障与持久结果 | [成功 COMMIT 丢 ACK](g5-host-shared-ack-loss-evidence.md)、[数据库链路和真实停启](g5-database-edge-evidence.md)、[跨入口撤权](g5-cross-entry-disable-evidence.md)、[#19 部分 owner 查询和恢复](g5-owner-fault-functional-evidence.md)均有直接证据；其余分层边界见[故障入口](v1-fault-harness.md)及[审查处置](final-coverage-audit.md) |
| 当前源码完整 Linux 回归 | 冻结 `ee142084` 的第二次无过滤运行通过：**1529 tests / 264 suites**，16 个必需 suite / 41 个指定 case 均实际启动并通过，vendor 与 7 项后置检查通过，退出及清理均为 0。见 [Linux 回归记录](g5-linux-regression-evidence.md)；首次停滞与所有历史失败仍保留 |

单项通过的验证层级以各证据文件为准，不将进程内测试、真实 PostgreSQL、独立进程和 Linux 应用栈混为同一等级。所有脚本只操作本次显式可丢弃资源；用户既有服务及全局 Docker context 保持不变。

## 暂缓的性能验收

原方案 G1–G5 中包含性能预算和相对容量要求，**这些原始 Gate 尚未整体完成**。当前用户要求先完成功能，不把性能结果改写为通过，也不据此承诺生产 SLO。

- [基线协议](v1-baseline-protocol.md)：hot 与 same-owner 预算已由三轮 main 实测冻结；mixed/cold/fault 的正式预算和比较仍待执行。
- [hot 历史记录](g5-hot-performance-regression.md#cached-local-candidate-fb8a1047)：`fb8a1047` 六轮通过仅属于该冻结候选，不转记到当前 `2772c846`。
- [same-owner 历史记录](g5-same-owner-performance.md)：两个候选的 CPU 超限仍记为失败；原阈值、工件和未执行轮次保持不变。
- 当前源码的后续相对比较和调优暂缓；本机 JSON 排序优化 `224b3943` 仅保存在独立分支，未集成、未验证。

## 并行开发输入

- [能力与方法签名目录](capability-catalog.md)：领域能力及 DTO 的所属模块。
- [房间写者台账](writer-ledger.md)：W01–W30 的生产入口、fence 与合法控制域/投影例外。
- [文件归属](file-ownership.md)：并行工作包的编辑边界。
- 静态检查 `python3 scripts/check_v2_virtual_actor_inventory.py` 核对文件、符号及清单一致性；它不替代运行时证据。

## 基线约束

- 数据 ownerEpoch 在 canonical schema 和 route 中允许零，与从一开始的 activationEpoch 分开建模。
- 逻辑 shardID 沿用 trim 后非空的规则；不额外收紧业务身份。
- DistributedCluster 使用已验证的固定 revision，不靠降低 Vapor/ServiceLifecycle 版本绕过兼容问题。
- Actor 换 Host 不等于房间迁移数据库；PostgreSQL 继续决定数据 owner、写入资格和持久结果。
