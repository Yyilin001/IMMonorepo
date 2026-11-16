# 服务端 Actor 运行时

| 要核对的行为 | 文档 |
| --- | --- |
| 房间寻址、Host 激活、执行顺序、旧代次退役与故障接管 | [房间 Actor 合同](../room-virtual-actor-contract.md) |
| 进程间 RPC、通道配额、截止时间、取消和关闭 | [自定义运行时合同](custom-runtime.md) |
| 请求与响应编码、跨模块 wire 类型 | [Protobuf 边界](../../architecture/actor-protobuf-boundaries.zh-CN.md) |
| 房间业务能力、写入入口和领域归属 | [能力目录](capability-catalog.md) · [写者台账](writer-ledger.md) |
| 进程配置、监督与恢复操作 | [服务端配置](../../../IMV2Server/README.md) · [Host 监督手册](../../../IMV2/docs/10-operations/room-host-supervision.md) |

## 尚未闭环

- **故障接管。** 2026-11-01 在同一 Linux 虚拟机内验证了 Host 强杀、Supervisor 重启和短暂断网。生产多机分区、物理主机失效和持续负载下接管仍需实测。节点部分启动后初始化失败且排空失败的进程级注入也仍待执行。[隔离演练记录](../../verification/native-host-crash-20261101.json) · [解耦验收记录](../../proposals/server-decoupling-validation.md)
- **发送结果恢复。** 数据库 COMMIT 确认丢失已有独立注入验证；真实客户端 TLS 连接丢失发送 ACK 的全链路演练仍待验证。双房间用例组合运行时出现过一次 `authorityLost`，单独复跑通过，原因待查。[发送与恢复合同](../message-send-contract.md)
- **容量和回归。** 固定负载对照测到了 Gateway 入口隔离的效果。运行时后续关闭、通道和同步 ACK 调整仍缺同条件 P99/CPU 对照；完整 Linux 回归及多机稳定容量需针对候选版本验证。旧方案的混合、冷启动、故障负载预算未完成，早期完整 Linux 回归曾停滞一次，原因未定位。[负载与版本边界](custom-runtime-benchmark.md)

运行 `python3 scripts/check_v2_virtual_actor_inventory.py` 核对文件归属、写者和 DTO 声明。旧 SQL 租约、DistributedCluster 的阶段记录及原故障矩阵可在[清理前的固定版本](https://github.com/Yyilin001/IMMonorepo/tree/9e31ff0c82a7b239b43f5a6efe2eb2cafb607b93/docs/reviews/virtual-actor)追溯。
