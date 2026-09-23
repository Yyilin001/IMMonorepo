# Room Virtual Actor 故障验证入口

使用下面已经实际运行的专项入口。最初 W0 的未实现 `IMV2VAFaultProbe` / `file-v1` 脚手架已移除；它的退出码 78 从来不是故障验收证据。完整 21 项范围仍以[任务卡](../../../IMV2/docs/00-foundation/virtual-actor-task-cards.md#v1-验证与证据)和[逐项审查](final-coverage-audit.md)为准，不把某一个脚本等同于整个矩阵。

| 入口 | 实际边界 | 证据 |
| --- | --- | --- |
| `IMV2/scripts/test_v2_virtual_actor_business_probe.sh` | 独立 caller/Host、真实发送/读取、客户端先启动、Host 强杀、租约到期后恢复和幂等重放；`VA_G4_MODE=linux` 使用 Linux 容器 | [Linux 恢复](g5-linux-functional-evidence.md) |
| `IMV2/scripts/test_v2_virtual_actor_multihost_probe.py` | 双 Host 并发 acquire，Actor 网络独立于每个进程的 DB 网络；断开 peer TLS 后保持 DB 访问，pause/接管/unpause 后旧 token 拒绝 | [双 Host 与分区](g6-multihost-evidence.md) |
| `IMV2/scripts/test_v2_virtual_actor_application_stack.py` | 真实 Account/Gateway/Operator Linux Release、HTTPS/TLS/protobuf 与房间 HTTP 路径 | [应用栈](i1-application-smoke-harness.md) |
| `V2RoomActivationCommitAckLossTests`、`V2SharedRoomSendCommitAckLossTests` | PG wire proxy 看到实际成功 COMMIT 后截断 ACK；单/双房间持久结果与稳定 operation ID 重放 | [事务证据](i1-composition-progress-evidence.md) |
| `V2RoomHostPostgresDrainTests` | 生产 Host/turn lane、实际 SQL fence 与慢事务跨 drain 截止，close 完成前不得释放租约 | [Host 排空](g5-host-pg-drain-evidence.md) |
| `V2RoomHostPostgresLifecycleTests` | 生产 Host/Server factory 和 PG lease；恢复中失租、共享等待者取消、容量隔离与 idle 回收重入 | [生命周期](g2-host-pg-lifecycle-evidence.md) |
| `V2RoomCreditRefillFencePostgresTests` | 生产 direct append 暖额度耗尽、跨连接 refill/业务 fence、回滚和旧 epoch；原生与 Linux PG 均已执行 | [额度与 fence](g5-credit-refill-fence-evidence.md) |
| `test_v2_virtual_actor_application_stack.py --cross-entry-disable` | 已认证的两条 Gateway 会话跨 Operator/Account 禁用提交，主动撤销连接、零新持久效果，原 Host/Gateway 保留 | [跨入口撤权](g5-cross-entry-disable-evidence.md) |

Linux 多 Host 复跑示例；scratch 由该次运行独占且位于源码之外：

```sh
DOCKER_CONTEXT=colima-imv2-vapor5 \
VA_G6_MODE=linux \
VA_G6_LINUX_SCRATCH_DIR="$HOME/.cache/imv2-va-g6/swiftpm" \
VA_G6_LINUX_RUN_ROOT="$HOME/.cache/imv2-va-g6/evidence" \
python3 IMV2/scripts/test_v2_virtual_actor_multihost_probe.py
```

G4/G6 分别创建自己的随机容器/网络及私有身份，只清理本次资源；不切换全局 Docker context，也不操作默认本地账户栈。各次 evidence 记录源码/锁文件、镜像、room/operation/epoch、故障阶段和独立 SQL 结果，不包含消息正文或私钥。

Server 的真实 PG suites 通过明确的 disposable 环境开关启用。CI 与 `docker-compose.isolated-tests.yml` 已登记相应 URL 和开关，所有重装 schema 的测试串行执行。没有数据库、故障未触发或测试过滤器匹配零项都不能登记为通过。Host/PG 用例没有发送实际 OS SIGTERM；这与已有进程 SIGKILL/网络分区证据是不同验证边界。

通用 Linux build/test wrapper 继续使用 `run_v2_virtual_actor_linux.sh`，并保留源目录只读挂载。VM 存储不足时可显式指定独立的 `IMV2_VA_LINUX_CACHE_DIR` 与 `IMV2_VA_LINUX_SCRATCH_DIR`；不能从不同容器内 scratch 路径直接复制已编译 Clang module cache。冷编译时仅复用 dependency checkouts/repositories，或保持完整挂载路径一致。
