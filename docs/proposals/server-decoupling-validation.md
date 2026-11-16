# 服务端解耦验收记录

本页记录 2026-09-30 解耦阶段的验证范围。当前模块职责见[系统架构](../current-system-map.md)，发布状态见[实施与发布证据](../../IMV2/docs/implementation-status.md)。

| 环境与基线 | 已验证的范围 |
| --- | --- |
| macOS 与本机 Linux Release | macOS 产品和测试目标编译通过。提交 `2b98177d` 的六个 Linux 产品编译通过，构建结果及产物哈希记录在 `~/.codex/virtual-actor-builds/server-decoupling-20260930-delivery-six-release/result.json`。 |
| 本机隔离应用栈 | 分别验证了 Gateway 内置 Host、Gateway 调用独立 Host、SQL 写入期间关闭 Host、跨入口禁用账号。提交 `e209dbd3` 单独复验了独立 Host 模式。 |
| 多进程与数据库故障 | 提交 `56e45bef` 的 G4/G6 覆盖 Host 被强杀后接管、旧令牌失效和同一发送身份重放。提交 `f65b19cd` 的三数据库专项覆盖定向断链和 owner-a 数据库重启。 |

该阶段仍缺完整故障矩阵、节点部分启动后排空失败的进程级注入，以及完整服务器组的同配置性能对照。后续故障证据见 [Actor 验证索引](../reviews/virtual-actor/README.md)，容量测量见[发送压测记录](../reviews/send-throughput-5000-20261008.zh-CN.md)。

依赖分析脚本使用[模块清单](server-module-inventory.json)并输出[依赖图](server-dependency-graph.json)。历史快照的文件数只适用于采集时的源码。逐阶段方案、原始矩阵及复现命令可从提交 `9e31ff0c82a7` 的 `docs/proposals/server-decoupling-*.md` 查阅。
