# G5 Linux 回归记录

这些记录来自固定 checkout、只读源码挂载、Swift 6.4 Jammy 与三个独立 PostgreSQL 16 实例。使用本任务专属 `colima-imv2-va-capacity` 的随机隔离资源，未使用或重建用户原有服务。客户端 Apple 平台代码未改，不把其他线程的原生测试日志纳入本记录。

后续[事务上下文 SQL 复用](g5-sql-context-evidence.md)已改变生产源码，并有 10 项原生真实 PostgreSQL 聚焦测试通过；该改动仍须在最终候选上取得完整 Linux required run。下面 `d5623259` 的成功记录保留，不把它当成新 SQL 改动已通过全量验证。

## 既有冻结源码的完整 required run

冻结源码 `d56232592b05c94d6e933534a985159ec14ff673` 的一次完整 Linux 运行保存在 `/Users/yyl/.codex/virtual-actor-builds/final-linux-capability-d5623259/`。Swift 6.4 Jammy 以只读源码和 Git 元数据挂载执行 Core、Server、Contracts、Runtime、Cluster、Application 的全部测试及后置检查，使用独立的 control、primary、secondary PostgreSQL 16 和 NATS。原 `suite.log` 中完整 suite 退出码 **0**，Compose 配置、容器日志收集与项目清理也均退出 **0**；运行后 checkout HEAD 仍为指定 SHA、工作树干净、`Package.resolved` SHA-256 仍为 `3af1e16190f46bdd8fad3de86c6b386dc196443291463355bf36edb62b7fd15c`。有效 Compose 配置、镜像 ID 与 plugin SHA 保存在同目录的 `effective-compose.json`、`metadata.json`。

| 测试目标 | 同一次 Linux 日志中的通过数 |
| --- | ---: |
| Core | 129 tests / 41 suites |
| Server | 1279 tests / 204 suites |
| ActorContracts | 52 tests / 5 suites |
| ActorRuntime | 20 tests / 8 suites |
| ActorCluster | 32 tests / 5 suites |
| ActorApplication | 3 tests / 1 suite |
| 合计 | **1515 tests / 264 suites** |

本轮重点的 **11 个 suite / 21 个 case** 均有实际 started 与 passed 事件，不是只按测试源码或非零匹配推断。它们包括 Application 生成配置 3 项、direct credit 2 项、单房间及双房间成功 COMMIT ACK 丢失各 1 项、生产 Host 共享提交 ACK 丢失 1 项、慢 PG drain 1 项、Host 生命周期 3 项、pair/query 2 项、取消/maintenance/review/import 4 项、满队列与 pending shared batch 2 项、总事务期限 1 项。11 个重点 suite 并非全部都是 PostgreSQL suite。PostgresNIO vendor 校验与 7 项后置检查（protobuf 生成、local environment、schema readiness、Prometheus、runtime env examples、文档链接、文档结构）也在该次运行中通过。

原 `metadata.json` 仍记录 `passed=false`、`suiteGatePassed=false`：外置 parser 错把 `bash -x` 打印的 `+ echo` 当成真正的 package marker，且只接受复数 suites summary，漏掉 Application 的 1 suite。此为**结果解析错误**，不是 suite 失败。保留原 driver、metadata、gate 和日志不变；独立修正版 verifier 对原 `suite.log` 作离线重校验，结果 `suite-gate-revalidated.json` 的 `revalidatedGate.passed=true`、无 failures，且标记 `notANewSuiteExecution=true`。可复核的 SHA-256：原 `suite.log` 为 `f172ceeab8aaad951116ffa3f54f3ed90a47074ada039960d39b5e703271dc09`，修正版 verifier `/Users/yyl/.codex/virtual-actor-builds/run-final-linux-gate-markerfix.py` 为 `b8a765f3289097ec60ce0cd4eafe3c65c83a1f3e23b19f5ce46df751e92d124b`，重校验 JSON 为 `593044cd77ca839b94ad3e9abe9ee85c3b32d4f422a288da9b830db56ef49d47`。原 metadata 的失败标志应与这些原始退出码和可复核的离线重校验结果同时阅读，不能只取其一。

另有 `c2214c1c299e10e7c57ae6260ae232ef3385f7a3` 的七产品 Linux Release 构建：`/Users/yyl/.codex/virtual-actor-builds/candidate-release-local-capability-c2214c1c/result.json` 报 `passed=true`、`exitCode=0`。`git diff --exit-code c2214c1c d5623259 -- IMV2Server/Sources IMV2Server/Vendor IMV2Server/Package.swift IMV2Server/Package.resolved IMV2Core IMV2Compression IMV2/sql` 退出 0，说明这七产品的业务源码、依赖锁及 SQL 与该次全量测试冻结源码等价；这项构建不代替 full-suite 运行。完整 Linux required checks 已有直接证据，但 #19 单 owner 查询故障及五类正式相对性能仍未通过，不能据此标记 G5 或全部方案完成。

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

同一次最新 Linux 运行的协议生成、local environment 合同、schema 表关系、Prometheus 20 条规则及配置、运行环境样例、文档链接与结构均通过；Ubuntu Jammy 的 `protoc` 显式启用 proto3 optional 后，生成文件与仓库内容一致。文档链接脚本现对 Git 文件枚举失败直接报错；挂载 worktree 对应的 Git 元数据后重新运行通过。上述初始失败和聚焦复验属于较早的不同提交；本文件开头另登记了 `d5623259` 冻结源码的一次完整 Linux required run。不能将各轮测试数相加或改写早期实际失败。

真实应用与故障证据另见 [busy SIGTERM](g2-real-app-sigterm-evidence.md)、[caller-only Gateway](g3-caller-only-gateway-evidence.md)与[多 Host 故障](g6-multihost-evidence.md)。这些正确性记录不替代[容量对照](v1-baseline-protocol.md)。

## Compose 环境优先级检查

固定干净源码 `77831cceb3834790f2dd2ccbcce9536c90a45c00` 的 `IMV2/scripts/test_v2_local_compose_env_precedence.sh` 退出 0。按 CI 方式临时复制 `.env.local.example`，验证冲突的 shell 导出不能覆盖 Compose 中的持久配置；检查后移除临时文件，源码仍干净。证据在 `/Users/yyl/.codex/virtual-actor-builds/local-compose-77831cce/{check.log,result.json}`。此项仅渲染配置，没有启动应用或替代待执行的完整 Linux 测试。
