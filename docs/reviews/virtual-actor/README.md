# Virtual Actor 实施与验证工件

本目录保存执行计划的清单和可复现证据，不另立“当前系统状态”入口。整体目标仍是 [完整 Room Virtual Actor](../../../IMV2/docs/00-foundation/virtual-actor-parallel-plan.md)；只完成公共类型或通信探针不能标记实施完成。

业务基线固定为 f1cdd78d6a21bf0ae23da627c0710c65115236aa，计划提交为 8839f6709e961853d377a2b60ba7231c325fc6b4。原工作目录的未提交 Distributed Actor 改动不参与本次实施。子代理统一 GPT-6 Sol / High。

## 执行状态

| Gate | 当前证据 | 状态 |
| --- | --- | --- |
| G0：Swift 6.4 / Vapor 5 / DistributedCluster 兼容 | [固定 revision 的 Linux Release 双进程探针及 ServerApp 构建通过](p0-evidence.md)；[vendor 帧上限与真实 mTLS 超限头重跑通过](p0-bounded-transport-evidence.md)，其他依赖 pin 不变 | 已通过兼容性探针 |
| G1：可编译完整公共契约与文件所有权 | 新 ActorContracts/ActorRuntime 基础类型与两级容量限制已加入；[11 项基础测试通过](c0-foundation-evidence.md)，完整业务 DTO、executor/transport 端口与所有权仍在整理 | 未完成 |
| G2：真实双 host + PostgreSQL 激活/接管/排空 | [真实 SQL activation fence 与 Host 单元测试](r1-d1-progress-evidence.md)，以及[独立进程被杀后接管探针](g4-business-probe-evidence.md)通过；双 host 竞争及完整排空矩阵尚未验收 | 未完成 |
| G3：真实远端 send/read 与领域合同 | [实际 Factory 与共享合批的 PostgreSQL 局部验证](i1-composition-progress-evidence.md)，以及[真实远端发送、日志、订阅与恢复](g4-business-probe-evidence.md)通过；完整领域合同尚未验收 | 未完成 |
| G4：全部房间写者、查询和后台迁移 | Gateway 与 Account 生产入口已接入；[维护与投影压缩竞态验证](d6-maintenance-evidence.md)通过；全部 writer 覆盖及完整应用协议闭环仍在检查 | 未完成 |
| G5：故障矩阵、Linux checks、相对性能 | [隔离工具/故障拓扑](v1-fault-harness.md)与[基线协议](v1-baseline-protocol.md)已合入，静态检查通过；尚未执行候选验收 | 未完成 |

## 核对出的基线差异

- 数据 ownerEpoch 在 canonical schema 和 V2RoomShardRoute 中允许零，不能复用从一开始的 activationEpoch 类型。公共契约保持该区别。
- 逻辑 shardID 沿用现有 trim 后非空的规则，不为内部 wire 类型增加新的字符限制。
- DistributedCluster 的最新发布 tag 不能直接视为兼容当前依赖；实际 resolver 结果决定固定提交，不能降级 Vapor/ServiceLifecycle 绕过。
- 当前默认 Docker context colima-imv2-tests 的磁盘不足；Linux 工作使用显式 colima-imv2-vapor5 context 及本任务专用资源，保持全局 context 和原有服务不变。宿主 bind scratch/cache 避免继续挤占 VM 磁盘。

各子包的实际命令、退出码与工件在交付后登记。未执行、进行中和已通过必须明确区分，不能用宿主构建替代 Linux Release 双进程证据。

已完成的 [R2 FIFO/预约调度器测试](r2-scheduling-evidence.md)是局部运行时证据，不能替代 G2 的真实激活/接管验收。

## 并行开发输入

- [能力与完整方法签名目录](capability-catalog.md)：34 行能力分组与 219 个 DTO 的所属模块/字段记录；不是全部已经远程化。
- [房间写者台账](writer-ledger.md)：30 个 writer 分组、38 个源符号/表的静态证据。逐项迁移后仍需补真实 fence 和运行测试证据。
- [文件归属](file-ownership.md)：351 个既有与实施文件的唯一 owner；混合文件须先由 C0 抽取，再转交领域包。
- 静态一致性检查：python3 scripts/check_v2_virtual_actor_inventory.py。该脚本检查文件、符号和清单一致性，不证明没有其他 writer 或已具备运行时覆盖。
