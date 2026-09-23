# Virtual Actor 实施与验证工件

本目录保存执行计划的清单和可复现证据，不另立“当前系统状态”入口。整体目标仍是 [完整 Room Virtual Actor](../../../IMV2/docs/00-foundation/virtual-actor-parallel-plan.md)；只完成公共类型或通信探针不能标记实施完成。

业务基线固定为 f1cdd78d6a21bf0ae23da627c0710c65115236aa，计划提交为 8839f6709e961853d377a2b60ba7231c325fc6b4。原工作目录的未提交 Distributed Actor 改动不参与本次实施。子代理统一 GPT-6 Sol / High。

## 执行状态

| Gate | 当前证据 | 状态 |
| --- | --- | --- |
| G0：Swift 6.4 / Vapor 5 / DistributedCluster 兼容 | [固定 revision 的 Linux Release 双进程探针及 ServerApp 构建通过](p0-evidence.md)；[vendor 帧上限与真实 mTLS 超限头重跑通过](p0-bounded-transport-evidence.md)，其他依赖 pin 不变 | 已通过兼容性探针 |
| G1：可编译完整公共契约与文件所有权 | 完整 wire/领域门面、Runtime/Cluster/Application 已编译并接线；[当前合同](../room-virtual-actor-contract.md)与文件归属已登记；[hot 预算已由三轮 main 实测冻结](v1-baseline-protocol.md)，其余四种负载的预算仍待校准 | 未完成 |
| G2：真实双 host + PostgreSQL 激活/接管/排空 | [真实 SQL activation fence 与 Host 单元测试](r1-d1-progress-evidence.md)，以及[独立进程被杀后接管探针](g4-business-probe-evidence.md)通过；[双 Host 原生进程竞争与旧实例恢复](g6-multihost-evidence.md)也通过；Linux 双 Host、仅 Actor 网络分区及旧 token 拒绝也已通过；[真实 Host/PG 生命周期](g2-host-pg-lifecycle-evidence.md)与[慢事务排空](g5-host-pg-drain-evidence.md)通过；[真实 Linux 应用 busy SIGTERM](g2-real-app-sigterm-evidence.md)在最终版本通过：原 Gateway 保留、唯一持久效果、epoch 接管；修正探针期限与只读定位后，2 次重放在测试端共约 4 秒完成，零 gossip 解码/连接上限错误 | 慢事务与接管通过；满队列及 pending batch 排空真实 PG 原生 2/2、[冻结源码 Linux required run](g5-linux-regression-evidence.md)同 suite 2/2 通过，信号与 Host 状态证据仍分层 |
| G3：真实远端 send/read 与领域合同 | [实际 Factory 与共享合批的 PostgreSQL 局部验证](i1-composition-progress-evidence.md)，以及[真实远端发送、日志、订阅与恢复](g4-business-probe-evidence.md)通过；[caller-only Gateway → 独立 Host 的 Linux TCP/HTTP 闭环](g3-caller-only-gateway-evidence.md)已通过；[独立 Host 的真实远程合批](g3-remote-batch-evidence.md)已通过：8 请求合为 4 原子批，序号/幂等/非成员拒绝同时验证；相对性能仍待验收 | 未完成 |
| G4：全部房间写者、查询和后台迁移 | Gateway 与 Account 生产入口已接入；[维护与投影压缩竞态验证](d6-maintenance-evidence.md)通过；[完整 Linux 应用协议及 Account 房间 HTTP 闭环](i1-application-smoke-harness.md)已通过；[Host 取消与 retention/review/import 临界接管](g2-pg-cancellation-maintenance-evidence.md)原生真实 PG 4/4、[冻结源码 Linux required run](g5-linux-regression-evidence.md)同 suite 4/4 通过；单 owner 故障另按 #19 验收 | 未完成 |
| G5：故障矩阵、Linux checks、相对性能 | [Linux 客户端先启动与 Host 重启恢复](g5-linux-functional-evidence.md)通过；[冻结源码一次完整 Linux required run](g5-linux-regression-evidence.md)的 suite/cleanup 退出 0、离线重校验 1515 tests / 264 suites 通过，原 metadata 的解析失败仍保留；完整[故障矩阵](v1-fault-harness.md)仍在收口；[真实 Host 共享提交 ACK 丢失](g5-host-shared-ack-loss-evidence.md)原生和同次 Linux 各 1/1 通过；[独立数据库链路故障与真实 PG 重启恢复](g5-database-edge-evidence.md)已通过 Linux 探针；[最新 `c221` hot 正式候选](g5-hot-performance-regression.md)业务零失败、SQL 已过，但 CPU 2.318061 ms/ACK 仍超过冻结 2.133047 ms/ACK，门禁在第 2 轮后停止；[先前 CPU 采样](g5-hot-cpu-profile-evidence.md)定位到逐调用签名与验签开销，[同进程 capability 实现及边界测试](r3-local-capability-evidence.md)已有原生与同次 Linux 证据，新候选 profile 尚无结论 | Linux required checks 已通过；#19 与五类相对性能未完成 |

## 核对出的基线差异

- 数据 ownerEpoch 在 canonical schema 和 V2RoomShardRoute 中允许零，不能复用从一开始的 activationEpoch 类型。公共契约保持该区别。
- 逻辑 shardID 沿用现有 trim 后非空的规则，不为内部 wire 类型增加新的字符限制。
- DistributedCluster 的最新发布 tag 不能直接视为兼容当前依赖；实际 resolver 结果决定固定提交，不能降级 Vapor/ServiceLifecycle 绕过。
- 早期 Linux 工作在显式 colima-imv2-vapor5 context 的任务资源中执行；容量校准与后续验证使用任务专用 colima-imv2-va-capacity VM。全局 context 及两个既有 VM 的用户服务保持不变，宿主 bind scratch/cache 复用依赖。

各子包的实际命令、退出码与工件在交付后登记。未执行、进行中和已通过必须明确区分，不能用宿主构建替代 Linux Release 双进程证据。

已完成的 [R2 FIFO/预约调度器测试](r2-scheduling-evidence.md)是局部运行时证据，不能替代 G2 的真实激活/接管验收。

## 并行开发输入

- [能力与完整方法签名目录](capability-catalog.md)：34 行能力分组与 219 个 DTO 的所属模块/字段记录；不是全部已经远程化。
- [房间写者台账](writer-ledger.md)：30 个 writer 分组、38 个源符号/表的静态证据。逐项迁移后仍需补真实 fence 和运行测试证据。
- [文件归属](file-ownership.md)：395 个既有与实施文件的唯一 owner；混合文件须先由 C0 抽取，再转交领域包。
- 静态一致性检查：python3 scripts/check_v2_virtual_actor_inventory.py。该脚本检查文件、符号和清单一致性，不证明没有其他 writer 或已具备运行时覆盖。
