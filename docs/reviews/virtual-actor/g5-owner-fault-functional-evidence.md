# #19 单 owner 故障下的批查询

2026-09-24 的真实 Linux 应用/独立 PostgreSQL 功能验证通过。按用户最新要求，此轮只验证部分结果、恢复及持久效果，不做相对性能验收。结果明确记录 `mode=owner-fault-functional`、`formalSamplingEligible=false`、无 main calibration freeze，不能进入容量比较。

生产源码冻结为 `2772c8465a58ef4ca3c9eab44b685ab5753b78a9`，使用该源码已验证的七产品 Linux Release 与独立校验的 common loader。驱动源码为 `e7828d9d54a791b16f6903f9d43cb3e033248d14`；新增 `--functional-owner-fault` 显式模式保留源码、依赖锁、ELF、进程资源限制、SQL 对账及清理检查。正式容量模式仍要求原校准 freeze；本机 JSON 排序优化 `224b3943` 未集成。

## 实际结果

mixed fixture 中两个 owner 分别有 470、469 个房间，100 条连接完成认证。采用固定的低负载功能配置；warmup/steady/cooldown 为 120/300/60 秒。

| 断言 | 观测 |
| --- | --- |
| 实际 owner 故障 | owner00 PostgreSQL 容器确实停止，约 20.46 秒后发起原容器启动；停止退出码 0，非 OOM |
| `room_sync_state` 在停库期间 | 健康项 success 增加 278，故障项 retry 增加 313 |
| `room_latest_visible` 在停库期间 | 健康项 success 增加 241，故障项 retry 增加 320 |
| 恢复 | 重启后出现连续三个一秒观测区间：两类查询均成功且 retry 不再增长；观测恢复时间约 6.38 秒，仅是本次功能结果，不是 SLO |
| 最终结果 | 两类查询三阶段 `unavailableRooms=0`，workload failed 为 0；`batchRecoveryQueriesCovered=true` |
| 持久效果 | 发送尝试、ACK、durable messages 均为 0，房间总数和 owner 分配不变 |
| 退出与清理 | 驱动退出 0、`passed=true`；专属项目 `imv2-va-cap-e79ba1e4e38c4504` 的容器、网络、卷均已清理 |

本项关闭的是 #19：一 owner 不可用时，另一 owner 的批查询成功项得以保留，失败项可重试且恢复后成功。它与 [#17 数据库链路/重启验证](g5-database-edge-evidence.md)互补，不替代完整 Linux 回归，也不表示 fault 容量预算通过。

## 工件与复验

工件目录：`/Users/yyl/.codex/virtual-actor-builds/functional-owner-fault-2772c846-run01`。私有日志和结果权限为 0600；源 checkout 与 Release bundle 未变。入口为 `IMV2/scripts/test_v2_virtual_actor_capacity_canary.py --functional-owner-fault`；实际完整参数保存在外置计划 `/Users/yyl/.codex/virtual-actor-builds/functional-owner-fault-2772c846-plan.json`，该计划 SHA-256 为 `7f242957b6db30cfa78f8c883128848eeb7e019405808396481605afe00e769a`。重跑需使用新的空工件目录。

| 工件 | SHA-256 |
| --- | --- |
| `result.json` | `d05795793b6f58d4fcd0b30b97d59fb7435df45aa2241ff5e4bd86707c65c2dc` |
| warmup | `c56f42a49215fc43257dc098fef3ecb5d8b95ba0a620b2a6c875d1e039b6a0b6` |
| steady | `ad873bb16f9ed0d0233d222110e5cd913155a0e92f715234f73c56308819401f` |
| cooldown | `556ef93114692dc67dc8b31dac9f92c1c54379d625bdbc1455fdd5a31cae680d` |
| measurement snapshots | `7ee254a0a6c967e871b256780cf8a0c2db27e8b002cd1d64a6b4e63b6f68aa73` |
| load report | `e2979f10dbdbad1c8fdbd3067c944449208639c138b2d1162f993e6668cc26b3` |

根集成另行复核结果与三阶段哈希、源码/驱动 revision、两个 PID 1 limits 证据及 SQL 对账，未只凭驱动最后的 PASS 文本判断。
