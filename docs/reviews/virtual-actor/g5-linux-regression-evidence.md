# G5 Linux 回归记录

这些记录来自固定 checkout、只读源码挂载、Swift 6.4 Jammy 与三个独立 PostgreSQL 16 实例。使用本任务专属 `colima-imv2-va-capacity` 的随机隔离资源，未使用或重建用户原有服务。客户端 Apple 平台代码未改，不把其他线程的原生测试日志纳入本记录。

当前功能冻结源码 `ee142084` 已在第二次完整无过滤运行中通过。首次测试进程停滞、此前断言/脚本失败及旧源码成功记录均按原时点保留；不能混用不同运行拼出通过结论。按用户要求，相对性能验收继续暂缓。

## 当前功能冻结源码的完整通过记录

源码 `ee14208495e269f75b28decda66b2ed8d574a195` 的第二次完整运行位于 `/Users/yyl/.codex/virtual-actor-builds/final-linux-functional-closeout-ee142084-run02/`。使用原 `run-final-linux-gate-allocation.py`（SHA-256 `91e26ff39ce7eba211d42b6f04fe19ae9a15c3b5871cd45a0349f63572ce9dab`）、同一冻结源码和新的私有 Compose 项目 `imv2-va-final-functional-ee142084-r2`，没有过滤测试，也没有修改生产代码、测试断言或依赖来绕过首次停滞。

| 测试目标 | 同一次 Linux 运行的最终通过汇总 |
| --- | ---: |
| Core | 129 tests / 41 suites |
| Server | 1283 tests / 204 suites |
| ActorRuntime | 58 tests / 5 suites |
| ActorContracts | 20 tests / 8 suites |
| ActorCluster | 36 tests / 5 suites |
| ActorApplication | 3 tests / 1 suite |
| 合计 | **1529 tests / 264 suites** |

**16/16 个必需 suite、41/41 个指定 case** 均有实际 started/passed 事件，包含新增单房间 fence、单条出队、真实完成追踪和修正后的本机排空用例。PostgresNIO vendor 校验以及 protobuf、local environment、schema readiness、Prometheus、runtime env examples、文档链接、文档结构七项后置检查均通过。驱动、测试、配置解析、日志收集和资源清理退出码均为 **0**。

原工作树始终干净，HEAD 保持指定 SHA，`Package.resolved` SHA-256 保持 `3af1e16190f46bdd8fad3de86c6b386dc196443291463355bf36edb62b7fd15c`。根集成另行读取 metadata/gate/有效 Compose，核对无过滤、全部精确用例与完整汇总，并独立检查项目容器、网络、卷均为空。最终交付在该冻结之上只同步验证和状态文档；生产代码、测试、脚本及依赖不变。

首次停滞的回执序号用例在本次完整运行中十个参数全部完成，整个 suite 约 0.001 秒通过。该结果关闭了当前源码完整回归的缺口；**首次停滞的根因仍未确定**，同产物的隔离复现和本轮通过不能解释其原因，原始诊断仍在下节保留。按用户调整后的范围，本轮功能收口完成；原方案中性能相关 Gate 仍暂缓，不宣告生产容量或 SLO。

| 工件 | SHA-256 |
| --- | --- |
| `metadata.json` | `9cc3d5c50d21a98fa299cf4b895e7a8b1f1c7eac32653067abb90534416f26e5` |
| `suite.log` | `eb723609a2bfa96cff89fca800ef10b122e92816b921c7cb9626fbbbb26d1c62` |
| `suite-gate.json` | `62546dd1b9ee78bb8b2d959957f8e3bbdd166b49ce1f67ebda0f98f92c7b9497` |
| `effective-compose.json` | `18b67243f1ad562615238d93762256ebe8753c2df2c3f8545026bf979a0a5f28` |

## 功能收口首次全量运行：Server 测试进程停滞

冻结源码 `ee14208495e269f75b28decda66b2ed8d574a195` 的首次完整功能回归位于 `/Users/yyl/.codex/virtual-actor-builds/final-linux-functional-closeout-ee142084/`，驱动 `run-final-linux-gate-allocation.py` SHA-256 为 `91e26ff39ce7eba211d42b6f04fe19ae9a15c3b5871cd45a0349f63572ce9dab`。本轮无过滤，但 **Server target 未完成，整体退出 1**；不能登记为完整通过。

Core 129 tests / 41 suites、Runtime 58 / 5、Contracts 20 / 8、Cluster 36 / 5、Application 3 / 1 通过。Server 的日志停在 `V2ReadReceiptServiceTests` 参数化用例中，最后观测为 `batched=true, sequence=1` 的 started 事件；参数没有逐项 passed 事件，不能由末行确定具体挂起的参数或 await 点。七项后置检查均未执行。

该用例的服务与内存 spy 相对业务基线没有修改，没有数据库、显式锁或 continuation 等待；旧完整运行中同一组十个参数约 0.001 秒通过。现场持续数分钟无日志，测试进程仍在、CPU 接近零、PG 无相关业务连接。保存的 LLDB 全线程栈显示线程等待，未定位已挂起的 Swift task；镜像没有 `swift-inspect`，没有安装工具或据此猜定生产根因。诊断后仅针对本次停滞的 test runner 发送 TERM；宽限后进程仍未退出，再对该 PID 发送 KILL。外层脚本继续执行其余 targets，最后保留失败结果并清理资源。

Compose 配置、日志收集和清理退出码均为 0；冻结 HEAD、工作树和依赖锁未变。后续须用同一测试产物隔离复现，并取得新的完整回归；单独 suite 通过不能替代这次未完成的 Server target。

| 原始工件 | SHA-256 |
| --- | --- |
| `metadata.json` | `f6f1060b54673b2dcb020e9665ed0cfa361802d6fcd98f88a3bee6286aa0a8e8` |
| `suite.log` | `98fc9089e544cd12b184746a207228e5890f768a3c205e8cc498c046061756b7` |
| `suite-gate.json` | `dbb6912b96d7bf68dc1c0d52a61e25ce341c804631063a6eadcb765c981084eb` |
| `server-stall-lldb-privileged.log` | `44aac67c164353cd457e8a43e4c64c843e2ca873513ece4fd83f04e910ed60e6` |

随后在相同现成测试产物上使用 `--skip-build` 作两次有界、无网络的隔离复现：`V2ReadReceiptServiceTests` **2 tests / 1 suite** 通过，序号检查的十个参数均实际运行；相邻 `PushWakeWorker`、`ReadReceiptBatcher`、`ReadReceiptService` **9 tests / 3 suites** 也通过。没有数据库或编译参与，也没有修改生产或测试代码。两次日志分别在 `final-linux-receipt-minimal2-ee142084/suite.log`（SHA-256 `f230320fd5d6b9f798b83f469d604e3c9a4f0c15758873c146821b064473d73b`）和 `final-linux-receipt-three-suites-ee142084/suite.log`（`5ddf54351d4a4921929975a7c667db38cc09e7cc843fa7c8e4dff2e8244a0b5a`），均位于上述本机工件根目录，退出码均为 0。首次最小复现命令误用了镜像默认 ENTRYPOINT，未运行目标用例，其独立 `final-linux-receipt-minimal-ee142084` 退出 1 工件保留并排除。现有证据只说明隔离运行未复现停滞，根因仍未确定，不能称为修复；最终仍需新的完整回归。 两次复现的 `metadata.json` 分别为 `19fbe38ab2f4b0058c921ea9ed18a29e8c0789d4958778c1540de13fb3e7ace2`、`693d00d3b2c88a57469b5d7340596b2764db155285d76ccf853455bd99831886`，记录实际命令及 runner/动态库运行前后相同的哈希。

## Cached-local 候选完整运行：排空测试观察点失败

`fb8a10478895f4b2d616f4bf7eb11eed51a84824` 的本次完整运行保存在 `/Users/yyl/.codex/virtual-actor-builds/final-linux-cached-local-fb8a1047/`。驱动 `run-final-linux-gate-cached-local.py` SHA-256 为 `f719ab7872c726e9a4710503013e7b75f74f641b7b563a643898bcd1efd456e5`。Core 129 tests / 41 suites、Server 1280 / 204、Runtime 58 / 5、Contracts 20 / 8、Application 3 / 1 均通过；Cluster 35 tests / 5 suites 中 **34 项通过、1 项失败**。14 个必需 suite 中 13 个通过，37 个必需 case 中 36 个有 started/passed；包括新增 SQL 上下文与 Directory 的六项边界用例。PostgresNIO vendor 检查通过；七项后置检查因测试阶段失败均未执行。

唯一失败是 `V2RoomLocalCapabilityIntegrationTests.localTimeoutAndDrain` 的 `trackedCalls == 1`，实际读到 0；执行 gate 仍关闭、调用返回 `outcomeUnknown`、首次 Node stop 未完成这些断言均通过。代码追踪表明 Host lane 的执行中 caller deadline 会先返回 `outcomeUnknown`，通信调用随之真实结束，Client 可以移除其 dispatch 记录；Host 的执行项、许可和 lease 则必须继续保留至 executor 完成。该测试把通信调用和 Host 执行的生命周期混同，不能把中间的 Client 计数强制固定为 1。修复应直接检查尚未完成的 Host 执行、许可、lease，以及放行后的排空和资源归零；不据此修改生产超时语义，也不将该失败轮改写成通过。

本轮 suite/驱动退出 1、清理退出 0，专属容器、网络和卷均已清理；冻结源码、HEAD 和依赖锁保持不变。原 `suite.log` SHA-256 为 `813f312d005deef0313aac6c653984a8dbee7064c6c2c1d1af50ab7bb3bc9303`，`suite-gate.json` 为 `e5863a4243b4f8771bc51c79aff499d54d858645150c16051fb8670b31f4584a`，`metadata.json` 为 `48e57bdffa7563b7c2f848926ca2ea8f357816353fcffe8e3d6c32a93813b4de`。这些失败工件原样保留，后续验证使用新工件目录。

随后只修改该测试：保留 250 ms 调用期限，先有界等待 Client quiesce，再直接断言 Host 执行 gate 未放行、预算一项且字节数大于零、精确 token 的 lease 仍在、再次短 stop 仍未完成；放行后 stop 完成、执行恰一次、预算和 lease 归零。生产代码未改。原生 `swift test -j 2 --no-parallel --disable-automatic-resolution --build-path /Users/yyl/.codex/virtual-actor-builds/p0/credit-fence-native/.build --filter IMV2ActorClusterTests` 退出 0，35 tests / 5 suites 通过；LocalCapability 的九项均实际 started/passed，修复用例用时 0.325 秒。日志 `/Users/yyl/.codex/virtual-actor-builds/p0/local-drain-observation-native/cluster.log` SHA-256 为 `a1288555794460f0e1c729fe692fef7de7e9ec7eff140a85d320287bacdb99bc`。下一步是独立 Linux 聚焦复验及七项后置检查；最终无过滤的完整 Linux 运行仍待所有代码收口后执行，不能由本次原生通过推定完成。

## 测试修复的 Linux 聚焦复验与文档脚本修复

干净冻结 checkout `60278c4975f55b264a404cb3a0fe671fb77235ec` 的 Linux 聚焦复验保存在 `/Users/yyl/.codex/virtual-actor-builds/local-drain-focused-linux-60278c49/`。独立驱动 `run-local-drain-focused-linux.py` SHA-256 为 `0ff831b8b8347d1a8597f8012b022c08ad1602ae0e3eaae2b2517bab17bad3e6`，仅筛选 LocalCapability suite，九项均实际 started/passed，汇总 **9 tests / 1 suite**。vendor 校验和前六项后置检查通过，但第七项文档结构检查误报历史归档缺少标记，因此本轮仍为 **suite/驱动退出 1**，清理退出 0，冻结源码与依赖锁未变、无项目残留。`suite-gate.json` 的 `passed=true` 只说明要求的测试事件和七项检查的启动标记都在日志中；它必须与整体退出 1 一起读取，不能把“检查已启动”当成“检查通过”。原 `suite.log` SHA-256 为 `509c60073fb2c7e0d70b5362510e2c9995b98040bbaaed242b09e01e0a231d81`，`suite-gate.json` 为 `8c747d56cdf3612f12b53d67c810227218d1c1e798847393a74bef84996c8f1a`，`metadata.json` 为 `571755a73ce6d55f9fceeaa99186de8615498c92891a69dfdf7b9d46c7f8a30d`。

归档文件第三行实际含有标记。旧 `head -20 | grep -q` 在 `pipefail` 下会因 grep 提前退出而令 head 收到 SIGPIPE，误判为缺标记。`scripts/check_v2_document_structure.sh` 改用单进程 awk 仅读取前 20 行，检查范围和拒绝规则保持不变。Linux 专项验证 `/Users/yyl/.codex/virtual-actor-builds/document-structure-pipefail-20260924-run03/` 实际确认：当前仓库通过；旧管道在长行 fixture 中返回 head=141/grep=0；新脚本接受长行中的标记及第 20 行标记，拒绝无标记及仅第 21 行有标记。六个执行标记均核对、进程退出 0、容器已移除；被测脚本 SHA-256 为 `c6f63dc8a9d8a4ac2779e5f8607a985765770adb2e1ffa7851e939ad74d2abda`。该专项的首个尝试误用了镜像入口而未执行检查；第二个尝试未接通 Docker stdin、虽退出 0 但实际没有执行命令，已由其 `execution-revalidation.json` 明确排除，不能作为通过证据。

本轮修复只涉及测试、文档检查脚本和文档。`git diff --exit-code fb8a1047 60278c49 -- IMV2Server/Sources IMV2Server/Vendor IMV2Server/Package.swift IMV2Server/Package.resolved IMV2Core IMV2Compression IMV2/sql` 退出 0，因此已测 hot 和后续容量仍使用原 `fb8a1047` Release 产物；这不代表全量 Linux 已通过。最终完整无过滤运行安排在其余四类性能及必要生产修复收口后，原失败和分层复验工件均保留。

## 既有冻结源码的完整 required run

冻结源码 `d56232592b05c94d6e933534a985159ec14ff673` 的一次完整 Linux 运行保存在 `/Users/yyl/.codex/virtual-actor-builds/final-linux-capability-d5623259/`。Swift 6.4 Jammy 以只读源码和 Git 元数据挂载执行 Core、Server、Contracts、Runtime、Cluster、Application 的全部测试及后置检查，使用独立的 control、primary、secondary PostgreSQL 16 和 NATS。原 `suite.log` 中完整 suite 退出码 **0**，Compose 配置、容器日志收集与项目清理也均退出 **0**；运行后 checkout HEAD 仍为指定 SHA、工作树干净、`Package.resolved` SHA-256 仍为 `3af1e16190f46bdd8fad3de86c6b386dc196443291463355bf36edb62b7fd15c`。有效 Compose 配置、镜像 ID 与 plugin SHA 保存在同目录的 `effective-compose.json`、`metadata.json`。

| 测试目标 | 同一次 Linux 日志中的通过数 |
| --- | ---: |
| Core | 129 tests / 41 suites |
| Server | 1279 tests / 204 suites |
| ActorContracts | 20 tests / 8 suites |
| ActorRuntime | 52 tests / 5 suites |
| ActorCluster | 32 tests / 5 suites |
| ActorApplication | 3 tests / 1 suite |
| 合计 | **1515 tests / 264 suites** |

这里仅修正 Contracts 与 Runtime 的**目标归属**，总测试数、suite 数、退出码和通过结论均未变化。原 `suite.log` 第 9076–9193 行的 52/5 执行段包含 `Room activation host owns restore, lease and retirement`、`Bounded room and host command admission` 等 Runtime suite；第 9194–9253 行的 20/8 执行段包含 `V2 actor creation wire contract`、`Closed room capability envelope` 等 Contracts suite。冻结源码的 `IMV2Server/Tests/IMV2ActorRuntimeTests`、`IMV2Server/Tests/IMV2ActorContractsTests` 及 `Package.swift` target 声明也对应这些名称。原始日志与离线 gate 工件未修改。

本轮重点的 **11 个 suite / 21 个 case** 均有实际 started 与 passed 事件，不是只按测试源码或非零匹配推断。它们包括 Application 生成配置 3 项、direct credit 2 项、单房间及双房间成功 COMMIT ACK 丢失各 1 项、生产 Host 共享提交 ACK 丢失 1 项、慢 PG drain 1 项、Host 生命周期 3 项、pair/query 2 项、取消/maintenance/review/import 4 项、满队列与 pending shared batch 2 项、总事务期限 1 项。11 个重点 suite 并非全部都是 PostgreSQL suite。PostgresNIO vendor 校验与 7 项后置检查（protobuf 生成、local environment、schema readiness、Prometheus、runtime env examples、文档链接、文档结构）也在该次运行中通过。

原 `metadata.json` 仍记录 `passed=false`、`suiteGatePassed=false`：外置 parser 错把 `bash -x` 打印的 `+ echo` 当成真正的 package marker，且只接受复数 suites summary，漏掉 Application 的 1 suite。此为**结果解析错误**，不是 suite 失败。保留原 driver、metadata、gate 和日志不变；独立修正版 verifier 对原 `suite.log` 作离线重校验，结果 `suite-gate-revalidated.json` 的 `revalidatedGate.passed=true`、无 failures，且标记 `notANewSuiteExecution=true`。可复核的 SHA-256：原 `suite.log` 为 `f172ceeab8aaad951116ffa3f54f3ed90a47074ada039960d39b5e703271dc09`，修正版 verifier `/Users/yyl/.codex/virtual-actor-builds/run-final-linux-gate-markerfix.py` 为 `b8a765f3289097ec60ce0cd4eafe3c65c83a1f3e23b19f5ce46df751e92d124b`，重校验 JSON 为 `593044cd77ca839b94ad3e9abe9ee85c3b32d4f422a288da9b830db56ef49d47`。原 metadata 的失败标志应与这些原始退出码和可复核的离线重校验结果同时阅读，不能只取其一。

另有 `c2214c1c299e10e7c57ae6260ae232ef3385f7a3` 的七产品 Linux Release 构建：`/Users/yyl/.codex/virtual-actor-builds/candidate-release-local-capability-c2214c1c/result.json` 报 `passed=true`、`exitCode=0`。`git diff --exit-code c2214c1c d5623259 -- IMV2Server/Sources IMV2Server/Vendor IMV2Server/Package.swift IMV2Server/Package.resolved IMV2Core IMV2Compression IMV2/sql` 退出 0，说明这七产品的业务源码、依赖锁及 SQL 与该次全量测试冻结源码等价；这项构建不代替 full-suite 运行。完整 Linux required checks 已有直接证据，但 #19 单 owner 查询故障及五类正式相对性能仍未通过，不能据此标记 G5 或全部方案完成。

## 完整运行与问题定位

`8231a0793e0b43108f49da4ffb270a69beb5c922` 的完整 Core + Server 运行保存在本机 `/Users/yyl/.codex/virtual-actor-builds/final-linux-20260923-r2`。整体退出 1，清理退出 0；不能把这一轮称为全绿。

| 测试目标 | 测试框架报告 |
| --- | --- |
| Core | 129 tests / 41 suites 通过 |
| Server | 1262 tests / 196 suites，3 issues |
| ActorContracts | 20 tests / 8 suites 通过 |
| ActorRuntime | 50 tests / 5 suites 通过 |
| ActorCluster | 22 tests / 3 suites，1 issue |
| ActorApplication | 3 tests / 1 suite，生成配置用例未启用；另两项通过 |

早期 `final-linux-20260923-r2/suite.log` 同样由 Runtime Host suite 起始，第 9629 行汇总 50/5；其后的 Contracts wire suite 到第 9689 行汇总 20/8。这里只改目标标签，不改那次整体退出 1 或任何失败记录。

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
