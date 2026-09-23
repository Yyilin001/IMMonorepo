# G5 Linux 回归记录

这些记录来自固定 checkout、只读源码挂载、Swift 6.4 Jammy 与三个独立 PostgreSQL 16 实例。使用本任务专属 `colima-imv2-va-capacity` 的随机隔离资源，未使用或重建用户原有服务。客户端 Apple 平台代码未改，不把其他线程的原生测试日志纳入本记录。

## 完整运行与问题定位

`8231a0793e0b43108f49da4ffb270a69beb5c922` 的完整 Core + Server 运行保存在本机 `/Users/yyl/.codex/virtual-actor-builds/final-linux-20260923-r2`。整体退出 1，清理退出 0；不能把这一轮称为全绿。

| 测试目标 | 测试框架报告 |
| --- | --- |
| Core | 129 tests / 41 suites 通过 |
| Server | 1262 tests / 196 suites，3 issues |
| ActorContracts | 50 tests / 5 suites 通过 |
| ActorRuntime | 20 tests / 8 suites 通过 |
| ActorCluster | 22 tests / 3 suites，1 issue |
| ActorApplication | 3 tests / 1 suite，生成配置用例未启用；另两项通过 |

四个问题均定位到具体测试条件：group append/receipt fixture 缺第二个房间的 control route；forward fixture 在已有本地 route 上重复 INSERT；recovery batcher 用 100 次 `Task.yield()` 代替等待真实入队；假 TCP listener 未像生产 transport 一样配置 `SO_REUSEADDR`，导致 Linux 同端口重绑失败。修复分别补齐 fixture、只插入远端 route、有期限地等待入队、对齐假 listener socket 配置，没有修改这些业务合同。

## 修复与新增真实 PG 用例复验

`c366d0c27a404781d5add4567c0c533d41054b9f` 的聚焦运行保存在 `/Users/yyl/.codex/virtual-actor-builds/final-focused-linux-20260924`。

- Server 15 tests / 7 suites 通过，包括两个原 fixture 回归、2 个 metrics、3 个 recovery batcher，以及 8 个真实 Host/Factory/PG 测试：慢事务排空、恢复中失租、共享等待者取消、恢复容量/idle 回收、双房间预约与查询交错、对向预约取消、已派发命令取消、retention 与接管的完整事务 fence。
- Runtime 命令许可 4/4 通过；ActorApplication 3/3 通过，这次实际生成 Host 与 caller 的隔离证书配置，相关用例没有跳过。
- gossip 重启编解码回归与 stalled-peer 的两个参数通过。另一既有 discovery 用例因额外要求 membership 在 5 秒内由 `joining` 升为 `up` 失败，故该聚焦运行仍整体退出 1，清理退出 0。

后一用例已观察到签名 endpoint 和准确的旧 NodeID。`up` promotion 另需 leader election 与 gossip convergence，不是发现服务的 5 秒合同。后续修改保留签名 endpoint 对应的精确 NodeID、`joining/up` membership 和原有 incarnation 替换断言，移除这项无关前提；未延长超时或改变生产 membership。

## 最新聚焦与合同检查

`4739cfff44709eaf345ffa9f0f83ac2f50b9d7d9` 的 discovery / bridge / Directory / gossip 聚焦 Linux 运行整体退出 0、清理退出 0，证据在 `/Users/yyl/.codex/virtual-actor-builds/final-discovery-linux-20260924`。Directory 10/10、Cluster 12/12 通过，包含只读定位单跳 3 秒上界、真实重启发现、旧物理 RPC 追踪与 gossip 回归。激活和业务写仍使用原期限，旧在途 RPC 不会因调用者停止等待而提前释放。

同一次最新 Linux 运行的协议生成、local environment 合同、schema 表关系、Prometheus 20 条规则及配置、运行环境样例、文档链接与结构均通过；Ubuntu Jammy 的 `protoc` 显式启用 proto3 optional 后，生成文件与仓库内容一致。文档链接脚本现对 Git 文件枚举失败直接报错；挂载 worktree 对应的 Git 元数据后重新运行通过。初始全量运行与针对实际失败及后续变更的聚焦复验共同构成本记录；没有将它们描述为同一提交上的一次全量全绿运行。

真实应用与故障证据另见 [busy SIGTERM](g2-real-app-sigterm-evidence.md)、[caller-only Gateway](g3-caller-only-gateway-evidence.md)与[多 Host 故障](g6-multihost-evidence.md)。这些正确性记录不替代[容量对照](v1-baseline-protocol.md)。
