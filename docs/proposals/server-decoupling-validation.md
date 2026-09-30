# 服务端解耦 P6 验收矩阵

## 当前范围（2026-09-30）

代码改造、macOS 编译与受影响定向回归已通过；本机 Linux Release、四种一次性应用栈模式、G4/G6 及三数据库定向断链和 owner-a 整库重启专项也已通过。真实远端服务器已停机，验证只使用本机隔离环境。完整故障矩阵和性能对照仍待执行；不能用应用栈冒烟替代。此前 2026-09-28 暂停时中断的原生排空、媒体崩溃和 G4 构建不计为通过。

提交 `943697d7` 调整了 RoomWrite 提交后效果的结果校验顺序。该提交的 macOS 测试目标编译及 `V2RoomWriteCommitEffectsTests` 定向测试通过；当前提交 `e209dbd313317e9ac6a456a7591b578f4e7642bb` 的六个 Linux Release 产品及独立 Host 应用栈也已通过，证据分别为 `~/.codex/virtual-actor-builds/server-decoupling-20260930-current-six-release-r2/result.json` 和下述当前应用栈结果。此前其他模式及数据库故障证据对应更早源码，不能代替这处改动的完整运行验证。运行配置样例检查通过；Account/Gateway/Operator 配置测试 49 项通过，Actor 配置测试 3 项中 2 项通过、1 项因缺少生成的本地部署文件按条件跳过。

提交 `4a39bac9` 修复 Actor 启动后失败且节点排空未完成时的资源释放边界：Host/caller 清理失败统一报 `incompleteShutdown`，Gateway/Account 先终止进程，再由操作系统回收资源。`IMV2AccountServerApp` 和 `IMV2ServerApp` 的 macOS 产品构建通过；干净源码 `cffda8e53f8376e9992176084b7b9b022ff70dbf` 的这两个产品及 `VirtualActorBusinessProbe` 的 Linux Release 构建也通过，哈希与来源见 `~/.codex/virtual-actor-builds/server-decoupling-20260930-startup-drain-release/result.json`。尚未运行注入启动后故障并阻塞排空的进程级专项，因此旧的正常启动和 busy SIGTERM 结果不能证明该异常路径。


本文记录可复用的验收入口及其执行条件。下方命令是可复用入口，是否已执行以表格与实施记录为准；不能仅因命令存在就视为通过。分批结果见[实施进度](server-decoupling-progress.md)和[Virtual Actor 证据目录](../reviews/virtual-actor/README.md)；源码继续变化后，旧结果不能代替最终验收。每次运行需保存源码 SHA、命令、环境开关、实际 started/passed/skipped 数、退出码和日志。

## 环境与执行层次

当前环境：Apple Swift 6.4（arm64 macOS）及本地 PostgreSQL 可用。Linux 检查使用测试专属 `colima-imv2-va-capacity`（4 CPU / 16 GiB），不切换默认 Docker context；仅在本机专项运行期间启动，结束后停止。2026-09-28 的临时 DNS 改动已恢复，本轮未再修改 DNS。

本轮生产源码收尾提交为 `a235be4c2fa0db5f3898358eb0228e27260f7ffa`，独立进程探针修复提交为 `56e45bef53fc30a6e4a4a3e64e3af3d00e9a5f51`，提交后效果修复为 `943697d7`。macOS 全包测试目标编译、标量/资源 PostgreSQL 定向回归及 Gateway 队列测试已通过，详见[实施进度](server-decoupling-progress.md)。Linux 应用栈使用冻结快照 `3af2cbc29aec29806fe11227e393b8f4c8249abd`，与 `a235be4c` 的 Swift 和冒烟脚本内容相同；两者只差文档。当前六产品 Release 矩阵的源码及产物哈希见 `~/.codex/virtual-actor-builds/server-decoupling-20260930-current-six-release-r2/result.json`，源码为 `e209dbd3`；四种应用栈模式使用的四产品构建另见 `~/.codex/virtual-actor-builds/server-decoupling-20260930-local-release-r3/result.json`。2026-09-28 的六产品候选与基线构建仍作为历史证据。

| 层次 | 当前批次最小回归 | 已有证据与剩余工作 |
| --- | --- | --- |
| 源码边界与模块 | `python3 scripts/check_v2_server_boundaries.py`；受影响 Server suite | 当前源码六个 Linux Release 产品及运行配置定向检查通过；protobuf 生成比对、schema readiness 在较早源码通过，仍需其余受影响检查 |
| HTTP、认证、运维和 Gateway | 下方定向 filter；只数实际执行测试 | 本机四种 Account/Gateway/Operator 栈均已通过；仍需核对未覆盖的定向 suite |
| 房间事务和恢复 | 下方真 PostgreSQL 精筛；独立 COMMIT ACK 丢失库 | G4/G6、三库定向断链及 owner-a 整库重启已通过；仍需完整受影响矩阵 |
| 性能 | 不在每次源码编辑后运行容量负载 | P0 对照与最终源码采用同一 Linux Release 构建模式、fixture、机器、连接池和负载，各至少三次 |

日常定向回归不需要运行完整 ClientKit；最终全量检查仍用 `bash scripts/run_v2_swift_tests.sh`。该脚本运行 Core、ClientKit、Server（后两者串行）及边界、protobuf、schema、配置和文档检查。CI 的 [verify.yml](../../.github/workflows/verify.yml) 还构建 `IMV2AccountServerApp`、`IMV2OperatorServerApp`、`IMV2ServerApp`、`IMV2LocalGatewayProbe`、`IMV2GatewayLoadGenerator` 的 Linux Release 产品，并在 PostgreSQL 服务下运行 Server 全量测试。最终必须核对本轮源码对应的实跑结果；进度文档中的定向通过只覆盖当时稳定点。

### 当前批次最小回归

从仓库根目录执行。`--filter` 为正则；过滤器匹配零项不能视为通过。第一条针对 HTTP/认证/指标，第二条针对 Gateway/Actor 接线。两条均不需要外部数据库：

```sh
swift test --disable-automatic-resolution --no-parallel --package-path IMV2Server \
  --filter 'V2PasswordAccountRoutesTests|V2PasswordLifecycleRoutesTests|V2AccountAssertionTests|V2VaporDeviceCredentialRoutesTests|V2VaporDeviceSessionRoutesTests|V2VaporAccountDisableOperatorRoutesTests|V2VaporDeviceSnapshotResetOperatorRoutesTests|V2VaporDurableWorkOperatorReplayRoutesTests|V2VaporMetricsRoutesTests|V2CachedDurableWorkMetricsSourceTests|V2VaporMediaEdgeRoutesTests'

swift test --disable-automatic-resolution --no-parallel --package-path IMV2Server \
  --filter 'V2GatewaySessionTests|V2GatewayDomainCommandHandlerTests|V2ProtobufFrameCodecTests|V2PreparedGroupEventPageCacheTests|V2GatewayRoomActorCompositionTests|V2AccountRoomGatewayTests'
```

Actor cluster 的现有 `V2RoomClusterBridgeTests`、`V2RoomLocalCapabilityIntegrationTests`、`V2RoomClusterDiscoveryTests` 位于 `IMV2ActorClusterTests`，最终 Actor 接线复验时单独执行：

```sh
swift test --disable-automatic-resolution --no-parallel --package-path IMV2Server \
  --filter 'V2RoomClusterBridgeTests|V2RoomLocalCapabilityIntegrationTests|V2RoomClusterDiscoveryTests'
```

## PostgreSQL 与故障 opt-in

[原生数据库脚本](../../scripts/test_v2_server_native_postgres.sh)需要可创建数据库的 PostgreSQL 用户；它创建并清理五个独立库，设置 primary、secondary、control、disposable、cross-store，以及取消/过载专项开关。它不自动启用 CI 的全部故障测试。先用受影响 filter，再在最终阶段执行完整 Server 集成矩阵；安装/删除共享 schema 的测试须串行。

```sh
PGHOST=127.0.0.1 PGPORT=5432 PGUSER=im_v2_test \
  bash scripts/test_v2_server_native_postgres.sh \
  --filter 'V2ActorRoomQueryExecutorIntegrationTests|V2RoomHostPostgresLifecycleTests|V2RoomHostPostgresDrainTests|V2RoomHostPostgresOverloadDrainTests|PostgresV2RoomWriteStoreIntegrationTests'
```

按本机账号配置 `PGPASSWORD`；不要把密码写入证据。此 filter 中某些 Host suite 仍会因独立开关缺失而 skipped，必须另用专属空库复跑。下表给出关键 opt-in；所有 URL 都必须指向**由本次运行独占、允许重装 schema 的空库**。

| 场景 | filter / 入口 | 必要环境 | 已有结果与本轮状态 |
| --- | --- | --- | --- |
| 单房间成功 COMMIT 丢 ACK | `V2RoomActivationCommitAckLossTests` | `IMV2_ACTOR_ACK_LOSS_DATABASE_URL`、`IMV2_ACTOR_ACK_LOSS_TEST_DATABASE_IS_DISPOSABLE=1` | 本轮原生 PostgreSQL 已执行通过，见下方证据 |
| 双房间成功 COMMIT 丢 ACK | `V2SharedRoomSendCommitAckLossTests` | `IMV2_SHARED_SEND_ACK_LOSS_DATABASE_URL`、`IMV2_SHARED_SEND_ACK_LOSS_TEST_DATABASE_IS_DISPOSABLE=1` | 本轮原生 PostgreSQL 已执行通过，见下方证据 |
| Host 排空与过载 | `V2RoomHostPostgresDrainTests` / `V2RoomHostPostgresOverloadDrainTests` | 分别 `IMV2_ACTOR_HOST_DRAIN_DATABASE_URL` / `IMV2_ACTOR_HOST_OVERLOAD_DATABASE_URL`，各自 `_IS_DISPOSABLE=1` | CI 已 opt-in；本轮未执行 |
| 授权及配额进程 SIGKILL（仅 macOS 编译） | `PostgresV2RoomWriteStoreIntegrationTests` 中 `directAuthorizationProcessCrash`、`groupJoinQuotaKilledRecovery` | primary/secondary **不同**；`IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE=1`；子进程 stage 由测试设置 | 本轮 macOS 实际执行授权 8 个与配额 6 个 SIGKILL 参数场景，通过；Linux CI 不会执行 |
| 本地媒体清理 SIGKILL（仅 macOS 编译） | `V2LocalMediaPurgeCrashTests` | 父测试无外部 opt-in；测试自行传 `IMV2_MEDIA_CRASH_*` 给子进程 | Linux CI 不会执行；本轮未执行 |

本轮原生故障回归：`/tmp/imv2-scope-fault-tests.log`，退出码 0，测试编译 182.75 秒，执行 33.801 秒。运行器报告 6 个 suite、19 项测试；其中 18 项实际通过，1 项仅供子进程调用的授权 crash 入口在父进程按设计 skipped。父测试实际启动并验证了 8 个授权与 6 个配额 SIGKILL 参数场景，不能将这个辅助入口的跳过误读为崩溃场景未执行。单房间/双房间 COMMIT ACK-loss 各 1 项、G2 Host 恢复 3 项、作用域构造 4 项及选定 owner fence/receipt/forward 场景均通过。所有数据库由本轮脚本创建并清理：通用五库之外，ACK、shared ACK 与 G2 各使用一个独占空库并显式设置对应 opt-in。

单、双房间 ACK 丢失可分别这样执行；每次将 `OWNED_EMPTY_PG_URL` 换为不同的可丢弃空库：

```sh
IMV2_ACTOR_ACK_LOSS_DATABASE_URL="$OWNED_EMPTY_PG_URL" \
IMV2_ACTOR_ACK_LOSS_TEST_DATABASE_IS_DISPOSABLE=1 \
swift test --disable-automatic-resolution --no-parallel --package-path IMV2Server \
  --filter V2RoomActivationCommitAckLossTests

IMV2_SHARED_SEND_ACK_LOSS_DATABASE_URL="$OWNED_EMPTY_PG_URL" \
IMV2_SHARED_SEND_ACK_LOSS_TEST_DATABASE_IS_DISPOSABLE=1 \
swift test --disable-automatic-resolution --no-parallel --package-path IMV2Server \
  --filter V2SharedRoomSendCommitAckLossTests
```

CI 另外显式配置 `IMV2_ACTOR_TRANSACTION_*`、`ACTOR_HOST_G2_*`、`ACTOR_PAIR_INTERLEAVE_*`、`ACTOR_CANCEL_MAINT_*`、`ACTOR_CREDIT_FENCE_*`、`ACTOR_D2_*`、`ACTOR_D4_*`、`ACTOR_D5_*` 及各自 disposable 标志，详见 [verify.yml](../../.github/workflows/verify.yml)。`IMV2_ACTOR_HOST_SHARED_ACK_LOSS_*` 也在 CI 配置中，但当前测试/生产源码没有读取它；不能据此声称该专项被执行。最终全量 Server 运行需记录每个 opt-in suite 实际执行数。

## 真实进程与服务入口

历史候选 Linux Release 证据：`~/.codex/virtual-actor-builds/server-decoupling-20260928-candidate-release/result.json` 记录源码 SHA `c1944b1a103b121cc73b36beceb5348cc465fc88`、固定 Swift 6.4 Jammy 镜像、lockfile SHA-256 `3af1e16190f46bdd8fad3de86c6b386dc196443291463355bf36edb62b7fd15c`、退出码 0，以及 Account、Gateway、Operator、LocalGatewayProbe、GatewayLoadGenerator、ResourceImageWorker 六个产品的 SHA-256。`~/.codex/virtual-actor-builds/server-decoupling-20260928-baseline-compatible-release/result.json` 记录相同镜像与 lockfile 下基线 `b01bb09338ddde61374af9d19f031173bab06b07` 的 Gateway/LoadGenerator 成功构建。两份构建成功不构成当前源码的服务或性能验收。

当前本机应用栈证据位于 `~/.codex/virtual-actor-builds/server-decoupling-20260930-local-runs/`。以下四次 `result.json` 均为 `passed=true`，每次 `smoke.log` 覆盖账户 HTTPS/凭据、Gateway direct chat、密码限流、Push 端点、Operator 禁号、TLS 1.3 与私有指标，`actor-http-smoke.log` 均记录昵称、邀请、媒体发送及签名下载通过：

| 模式 | 证据目录 |
| --- | --- |
| Gateway 内置 Host | `run-2263830457474205a37c587881435f8f` |
| Gateway 调用独立 Host | `run-2582c665d3714d719c3ab381449a2f39` |
| 独立 Host 阻塞写入时收到 SIGTERM | `run-d6669f25fdce4242bb1532754cae9219` |
| 独立 Host、两条旧连接跨入口停用账号 | `run-4259400b5da549de8421ab4c4eb3ce96` |

初次运行因冒烟脚本仍要求旧 `/v2/local-media/download/` 路径而失败。服务端签发现行 `/v2/resource-bytes/`，脚本修正后四种模式均重跑通过。该结果不代替 G4/G6 网络分区、全量故障矩阵或性能对照。

当前 `e209dbd3` 六产品构建又运行一次独立 Host 模式：`~/.codex/virtual-actor-builds/server-decoupling-20260930-current-app-run/run-52a09bafb5b342388590a4877cec5802/result.json` 为 `passed=true`，`revision` 与 `productSourceRevision` 均为 `e209dbd3`；`smoke.log` 确认 Gateway 直聊接受与收件方房间日志交付，`actor-http-smoke.log` 确认昵称、邀请、媒体发送及签名下载。Gateway 仅作为 caller，独立 Actor Host 持有实际房间 lease；本次未重复其余三种模式或 G4/G6。一次性容器已由 runner 清理，专用 Colima profile 已停止。

### P6 worker 与共享资源静态归属审查

下表只记录源码能证明的构造、启动与关闭关系；实际进程故障验证仍按本节下方的独立入口执行。

| 能力 | 实现与启动所有者 | 关闭及资源顺序证据 |
| --- | --- | --- |
| 同步与个人状态 | `IMV2Server/Sources/IMV2ServerApplication/V2SyncService.swift` 处理同步用例；`IMV2Server/Sources/IMV2ServerApp/GatewayCommandAssembly.swift` 76–86 行注入 `V2RoutedSyncStore`。`GatewayUserShardWork.swift` 21–64 行按物理分片去重构造投影、压缩和同步清理 worker；`GatewayProjectionWorkers.swift` 20–74、130–151 行及 `GatewayMaintenanceWorkers.swift` 93–134、208–215 行注册轮询。 | `GatewayRuntime.swift` 111–116 行在 HTTP 监听器绑定后启动统一监督器；215–225 行取消并排空任务，随后 132–136 行关闭辅助服务、TLS 与 Actor，`GatewayInfrastructure.swift` 35–39 行最后关闭应用、数据库和事件循环。 |
| 账户与邀请恢复 | `IMV2Server/Sources/IMV2AccountServerApp/main.swift` 51–67 行创建账户专属数据库资源、任务监督器、密码哈希 worker；132–147 行登记边缘限流清理，191–198 行登记授权恢复，236–243 行登记转发计划恢复，456–488 行登记邀请创建及入群配额恢复。 | 同文件 513–525 行先 `runtimeTasks.cancelAndWait`、关闭密码 worker 和 HTTP，再关闭资源资料服务与房间 Actor，最后关闭数据库和事件循环；526–547 行异常路径同样排空。`RuntimeTaskSupervisor` 588–602 行持有所有已登记任务，取消后等待，超时直接退出以保留底层资源。 |
| 推送与内容审核 | `GatewayMaintenanceAssembly.swift` 85–108 行只在 APNS 配置下构造推送 worker；`GatewayCommandAssembly.swift` 29–61 行只在审核启用且配置安全身份时按房间归属库构造审核 worker。`GatewayDeliveryWorkers.swift` 52–106 行为二者各登记独立循环。Account 的推送端点路由在 `IMV2Server/Sources/IMV2AccountServerApp/main.swift` 412–418 行登记，不持有发送循环。 | 二者都由同一个 `GatewayWorkerSupervisor` 管理，走上述 Gateway 停机排空路径；禁用配置下对应循环立即返回。 |
| 媒体与资源恢复 | `IMV2Server/Sources/IMV2AccountServerApp/main.swift` 244–250、370–400 行只在本地媒体配置存在时，为每个物理归属构造资源恢复、导入、扫描、保留和清理 worker，并登记一个可取消循环。`IMV2Server/Sources/IMV2ServerInfrastructure/Resources/Infrastructure/V2ResourceRecoveryWorker.swift` 执行过期事务并读取候选；`IMV2Server/Sources/IMV2ServerApplication/Resources/Application/V2ResourceRecoveryWorker.swift` 逐项重试 finalize。 | 这些循环登记在账户 `RuntimeTaskSupervisor`，因此在数据库资源关闭前按 513–525 或 526–547 行排空；资源资料服务也在 517/532 行显式关闭。 |
| Gateway 共享资源 | `GatewayComposition.swift` 51–58 行记录逐阶段已创建的 broker、共享唤醒兴趣、账号房间变更服务、Actor 与作者资料运行时；65–82 行准备资源并启动 Actor，185–197 行把唯一实例装入组合结果。 | 装配失败由 199–211 行逆序回滚；正常关闭由 `GatewayRuntime.swift` 121–136 行排空连接和 worker，再关闭共享服务及 Actor；`GatewayComposition.swift` 215–227 行显式关闭 broker、兴趣与账号变更服务。底层数据库/事件循环由 `GatewayInfrastructure.swift` 35–45 行统一关闭。 |

**模块归属。** 推送、审核、同步维护、邀请创建、入群配额及资源 finalize 恢复的协议和业务编排现位于 `IMV2Server/Sources/IMV2ServerApplication/`；对应的 PostgreSQL store、审核任务事务、资源过期事务和具体 Actor 构造入口保留在 `IMV2Server/Sources/IMV2ServerInfrastructure/`。资源恢复的基础设施端口先在同一事务中过期会话，再读取待恢复项；应用层随后调用 `V2ResourceService.status/finalize`。这是源码层职责核查，尚不能代替下方独立进程故障验收。

以下专项入口会自行建立临时 PostgreSQL、网络和身份；Linux 模式需要可用 Docker context，scratch 与证据目录须为源码外不同目录。当前源码的 G4/G6 已在本机固定 Swift 6.4 Linux 镜像下通过：

| 专项 | 实际结果 | 证据目录 |
| --- | --- | --- |
| G4 caller 先启动、首 Host SIGKILL、租约后接管和同 ID 重放 | `G4_BUSINESS_PROBE_OK`；`result.json` 中 `messageRows=1`、`firstActivationEpoch=1`、`replacementActivationEpoch=2`、`staleBusinessWriteRejected=true` | `~/.codex/virtual-actor-builds/server-decoupling-20260930-g4/imv2-va-g4-1790729287-48034-evidence/` |
| G6 双 Host、peer 分区、租约竞态和旧 token 围栏 | `G6_MULTIHOST_OK`；`result.json` 中 `uniqueMessageRows=1`，旧 token 的业务写入、续约和释放均被拒绝 | `~/.codex/virtual-actor-builds/server-decoupling-20260930-g6/imv2-va-g6-48701-758f80f2-evidence/` |

两项最终运行的 `source-sha.txt` 均为 `56e45bef53fc30a6e4a4a3e64e3af3d00e9a5f51`。G4 首次构建遇到 SwiftPM 依赖缓存获取错误，未进入业务场景；测试入口改为锁定依赖版本后构建通过。随后探针 Host 因缺少测试邀请密钥在启动前失败，修正后又发现调用 helper 将日志与订阅响应误判为发送回执；两项探针问题修正后重新运行，最终结果见表格。CI 已有 G4/G6 Linux job；真实应用栈目前不在 required CI gate 中。

三数据库定向断链使用[DB-edge runner](../../IMV2/scripts/test_v2_virtual_actor_database_edges.py)及与源码提交 `f65b19cdcec33f3c2ca60567a56890151bc30ac7` 匹配的 Linux Release `VirtualActorBusinessProbe`。首次通过的 `~/.codex/virtual-actor-builds/server-decoupling-20260930-db-edge-run-r4/result.json` 为 `passed=true`、`cleanupErrors=[]`，记录了 Host A 到 control、owner-a 的两次独立网络断开，并确认只终止目标链路上的 PostgreSQL 会话。runner 实际验证未受影响的 Host/数据库仍可用、故障期间无持久业务副作用、恢复后 edit 回执及 message/completion 各恰好一份，三个 Actor 进程均正常关闭。构建来源及产品哈希在 `~/.codex/virtual-actor-builds/server-decoupling-20260930-db-edge-probe-release-r4/result.json`。此前失败分别来自探针未提供隔离邀请密钥、查询已删除的编辑 operation 表、以及将安全退休后租约过期误判为 owner 数据库不可用；修正后重跑通过。首次通过时未启用 runner 的 `--database-restart` 可选阶段，整库重启证据来自下述复跑。

随后使用同一源码和探针增加 `--database-restart` 复跑，证据 `~/.codex/virtual-actor-builds/server-decoupling-20260930-db-edge-restart-run/result.json` 为 `passed=true`、`cleanupErrors=[]`。owner-a PostgreSQL 容器在保留数据和三个 Actor 进程的条件下实际停止、重启，`pg_postmaster_start_time()` 改变；故障期间另一 owner 继续处理，恢复后的 caller 重放只有一份持久结果，原租约保持有效。该轮也重跑并通过 control/owner 两次断链。专用 Colima profile 在运行后关闭。

```sh
# G4：caller 先起，独立 Host SIGKILL、租约到期、替代 Host 接管与幂等重放。
mkdir -p "$HOME/.cache/imv2-g4/swiftpm" "$HOME/.cache/imv2-g4/evidence"
DOCKER_CONTEXT=default VA_G4_MODE=linux VA_G4_LINUX_CLIENT_FIRST=1 \
VA_G4_LINUX_SCRATCH_DIR="$HOME/.cache/imv2-g4/swiftpm" \
VA_G4_LINUX_RUN_ROOT="$HOME/.cache/imv2-g4/evidence" \
bash IMV2/scripts/test_v2_virtual_actor_business_probe.sh

# G6：双 Host、peer-only 网络分区和旧 token 围栏。
mkdir -p "$HOME/.cache/imv2-g6/swiftpm" "$HOME/.cache/imv2-g6/evidence"
DOCKER_CONTEXT=default VA_G6_MODE=linux \
VA_G6_LINUX_SCRATCH_DIR="$HOME/.cache/imv2-g6/swiftpm" \
VA_G6_LINUX_RUN_ROOT="$HOME/.cache/imv2-g6/evidence" \
python3 IMV2/scripts/test_v2_virtual_actor_multihost_probe.py
```

[应用栈 runner](../../IMV2/scripts/test_v2_virtual_actor_application_stack.py)使用 Linux Release 产品和独立 Compose project，包含 Account HTTPS、Gateway TLS/protobuf、Operator 与房间 HTTP 冒烟。`--scratch-dir` 为源码外独占目录；如使用预编译产品，需同时传 `--products-dir`、`--products-metadata`，runner 会核对源码、lockfile 和各产品 SHA-256。

```sh
# 真实本地 Host / Gateway / Account / Operator。
python3 IMV2/scripts/test_v2_virtual_actor_application_stack.py \
  --context default --scratch-dir "$HOME/.cache/imv2-app/swiftpm"

# 独立远端 Host；Gateway 与 Account 只作为 caller。
python3 IMV2/scripts/test_v2_virtual_actor_application_stack.py \
  --context default --scratch-dir "$HOME/.cache/imv2-app/swiftpm" --remote-gateway

# 两条已认证 Gateway 会话跨 Operator 禁号，验证旧连接关闭及零新持久效果。
python3 IMV2/scripts/test_v2_virtual_actor_application_stack.py \
  --context default --scratch-dir "$HOME/.cache/imv2-app/swiftpm" \
  --remote-gateway --cross-entry-disable

# 繁忙 Host 的真实 SIGTERM、退出、接管和同 ID 重放；与上一模式互斥。
python3 IMV2/scripts/test_v2_virtual_actor_application_stack.py \
  --context default --scratch-dir "$HOME/.cache/imv2-app/swiftpm" \
  --remote-gateway --busy-sigterm
```

应用栈当前脚本没有 `--remote-batch`：它属于已退役的 TCP 发送入口，其[历史记录](../reviews/virtual-actor/g3-remote-batch-evidence.md)不能作为现行发送路径验收。跨入口禁号 runner 验证两条会话、独立 Host、Operator 提交及 SQL 无新效果；它不等同于多数据库控制链路分区。

## 性能对照

可复用入口为 [容量 runner](../../IMV2/scripts/test_v2_virtual_actor_capacity_canary.py)、[固定 fixture](../../IMV2/scripts/prepare_v2_virtual_actor_capacity_fixture.py)、[评估器](../../IMV2/scripts/assess_v2_virtual_actor_capacity.py)和[历史协议](../reviews/virtual-actor/v1-baseline-protocol.md)。容量 runner **不负责构建产品**：需两份干净源码 checkout 与各自独立 Linux Release 产品/`result.json`，另用同一份经验证的 corrected Release loader、固定 fixture、非 `default` 的显式 Docker context，以及源码外全新 artifact 目录。先对两版输入分别做只读预检：

```sh
python3 IMV2/scripts/test_v2_virtual_actor_capacity_canary.py \
  --source-checkout "$CHECKOUT" --source-sha "$SHA" \
  --release-dir "$RELEASE_DIR" --build-result "$BUILD_RESULT" \
  --loader-products-dir "$COMMON_LOADER_DIR" \
  --loader-build-result "$COMMON_LOADER_RESULT" \
  --fixture-dir "$FROZEN_FIXTURE_DIR" --layout hot \
  --docker-context "$NONDEFAULT_DOCKER_CONTEXT" \
  --artifact-dir "$NEW_ARTIFACT_DIR" --preflight-only
```

正式运行增加 `--measurement-workload hot --measurement-connections <固定值>`；候选再传 `--measurement-freeze-file <main-calibration-freeze.json>`。其他 workload 为 `same-owner`、`mixed`、`cold`、`fault`，其中 fault 使用 mixed layout。每次运行固定 120 秒预热、300 秒稳态、60 秒冷却；同机、同镜像、同 PostgreSQL 版本/数据/连接池/负载，以 `main,candidate,candidate,main,main,candidate` 顺序各取至少三次，执行评估器 `freeze` 与 `assess`。观察 accepted throughput、P95/P99、SQL/ACK、CPU/ACK、RSS、批次和队列。实施方案建议先调查吞吐下降超过 5% 或 P95/P99 上升超过 10%；最终预算须先按 P0 噪声与容量要求冻结。

**当前性能准备状态**：原仓库容量 runner 仍绑定历史 SHA `f1cdd78d6a21bf0ae23da627c0710c65115236aa`，不直接用于本轮对照。独立干净 harness 已生成真实 snapshot `a8dcae1faf999a94d24b5451ff94e184bf6a88c6`，绑定 `524716ef` 加相同三入口 stderr 兼容补丁后的实际基线 `b01bb093`，保留校准、产物及来源检查，并要求两版均有 Actor 指标。该 harness 的 100 连接、1 个热点房间、125 次发送/秒配置已通过只读预检；当前候选 `e209dbd3` 的匹配 Linux Release Gateway/LoadGenerator 已构建并通过 `VA_CAPACITY_CANARY_PREFLIGHT_OK` 的只读来源及 fixture 预检。尚未运行三次基线校准或候选测量。新 fixture 为 `~/.codex/virtual-actor-builds/server-decoupling-20260928-performance-hot-fixture`，独立 harness 及 provenance 位于同级目录。性能结论仍待真实样本；热点单条负载另外配合 direct atomic batch 测量，不能相互替代。

`V2GatewaySlowFanoutBenchmarkTests` 可用 `IMV2_RUN_SLOW_FANOUT_BENCHMARK=1` 单独观测 10k 连接慢读者传输，但只覆盖局部传输；`IMV2/scripts/run_v2_gateway_load_guarded.sh` 使用 macOS `caffeinate`，不是 Linux 容量入口。
