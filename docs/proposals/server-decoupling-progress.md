# 服务端解耦实施状态

目标及完成条件见[实施方案](server-decoupling-plan.md)。代码改造和 macOS 编译已完成；完整运行与性能验收尚未完成。当前验证只使用本机隔离环境，不连接已停机的真实远端服务器。

## 本轮收尾与验证（2026-09-30）

- Host PostgreSQL 排空定向验证实际通过三项：普通排空 1 项、过载及双房间共享批次排空 2 项。证据分别为 `~/.codex/virtual-actor-builds/server-decoupling-20260930-host-drain-r2/` 与 `server-decoupling-20260930-host-drain/`；运行后数据库均清理。首轮普通排空测试因共享 helper 的通用 disposable 开关缺失而提前返回，不计为通过；测试现要求该开关，补齐后重新执行 SQL 并通过。生产源码为 `22e05061`，复跑仅增加此测试守卫。启动失败且节点未排空的进程级注入仍未执行。
- 混合群批次的提交后额度结算与保序结果映射移入 `V2RoomWriteCommitEffects.finalizeHybridBatch`，Store 继续拥有 SQL 事务、回滚/结果不明分类及失败时额度退役。保留 SQL 已提交后先结算持久预扣令牌、再转换响应的顺序；共用结果数量、下标及时间转换检查。macOS 产品和测试目标编译通过（`/tmp/imv2-hybrid-effects-build-20260930.log`）；跨房间和同一热房间的两项真实 PostgreSQL 原子批次测试通过、无跳过（`/tmp/imv2-hybrid-effects-tests-20260930.log`），本轮独占数据库已清理。
- 删除只服务历史调用方式的资源导入构造器、Messaging 中被忽略的参数和 Gateway 的 `Data` 提交重载；生产接线及测试改用现行接口。RoomWrite 的三个事务闭包直接调用标量接受路径，移除仅作转发的 Store 包装。HTTP 冒烟脚本只接受现行资源下载 header 数组结构。
- macOS/Swift 6.4 下 `swift build --build-tests --disable-automatic-resolution --jobs 4 --package-path IMV2Server` 通过，产品和测试目标均编译成功（日志 `/tmp/imv2-no-legacy-native-build-20260930-r2.log`）。边界检查、Actor 台账与差异空白检查通过。
- 本机 PostgreSQL 定向回归通过：标量写入 3 项测试、15 组参数场景（`/tmp/imv2-postpush-scalar-targeted-20260930.log`）；资源上传及逻辑身份 2 项测试、4 组参数场景（`/tmp/imv2-current-resource-targeted-20260930.log`）。Gateway 队列 8 项测试通过（`/tmp/imv2-no-legacy-queue-tests-20260930.log`）。资源测试使用新建且结束后删除的独立数据库。
- 固定 Swift 6.4 Linux 镜像下，Account、Gateway、Operator、LocalGatewayProbe 四个 Release 产品构建通过；最终产物和源码快照 `3af2cbc29aec29806fe11227e393b8f4c8249abd` 的哈希见 `~/.codex/virtual-actor-builds/server-decoupling-20260930-local-release-r3/result.json`。
- 探针修复后的提交 `56e45bef53fc30a6e4a4a3e64e3af3d00e9a5f51` 又构建了完整六产品 Linux Release 矩阵：上述四个服务/探针产品加 `IMV2GatewayLoadGenerator`、`IMV2ResourceImageWorker`。构建成功和逐产品哈希见 `~/.codex/virtual-actor-builds/server-decoupling-20260930-final-six-release/result.json`；本批修改只涉及独立进程探针及验证脚本，四种应用栈模式对应的生产源码未变。
- 一次性本机 Docker 应用栈的四种模式均通过：Gateway 内置 Host（`run-2263830457474205a37c587881435f8f`）、Gateway 调用独立 Host（`run-2582c665d3714d719c3ab381449a2f39`）、独立 Host 在阻塞 SQL 写入时收到 SIGTERM（`run-d6669f25fdce4242bb1532754cae9219`）、跨入口停用账号（`run-4259400b5da549de8421ab4c4eb3ce96`）。每次都通过通用冒烟和 Actor HTTP 昵称、邀请、媒体发送及签名下载；证据位于 `~/.codex/virtual-actor-builds/server-decoupling-20260930-local-runs/` 对应目录。实际运行前，冒烟脚本对下载路径的旧假设导致两次失败；服务端签发现行 `/v2/resource-bytes/{placementID}`，脚本修正后重跑通过。
- 本机 Linux 独立进程 G4/G6 专项也已通过，并在测试代码提交 `56e45bef53fc30a6e4a4a3e64e3af3d00e9a5f51` 上各复跑一次。G4 的 caller 先启动、首 Host SIGKILL、租约后接管与同 ID 重放结果为单行消息、激活 epoch 从 1 到 2、旧业务写入被拒绝；G6 的双 Host/peer 分区与租约竞态结果为单行消息，旧 token 的续约、释放和业务写入均被拒绝。最终证据分别位于 `~/.codex/virtual-actor-builds/server-decoupling-20260930-g4/imv2-va-g4-1790729287-48034-evidence/` 与 `~/.codex/virtual-actor-builds/server-decoupling-20260930-g6/imv2-va-g6-48701-758f80f2-evidence/`，各自 `source-sha.txt` 与该提交一致。首轮 G4 构建因未锁定的 SwiftPM 缓存获取失败；修正后探针又暴露缺失的测试邀请密钥和将非发送响应误作发送回执的校验错误，均已修复并重跑通过。失败运行不计为业务通过。
- 本机跨数据库断链专项在测试代码提交 `f65b19cdcec33f3c2ca60567a56890151bc30ac7` 上通过；证据 `~/.codex/virtual-actor-builds/server-decoupling-20260930-db-edge-run-r4/result.json` 记录三库、双 Host、一个 caller、control 与 owner-a 两次定向断链、`passed=true` 和 `cleanupErrors=[]`。脚本验证未受影响链路可用、失败操作无持久副作用、恢复后的编辑回执与消息完成各只有一份，以及三个 Actor 进程正常关闭。此前失败暴露测试探针缺少独立邀请密钥、使用已删除的编辑 operation 表、以及将安全退休后的租约过期误作 owner 数据库故障；修正后重新构建匹配源码的 Linux Release 探针并重跑。该次未启用可选的 owner-a PostgreSQL 整库重启阶段。
- 同一源码及探针的本机三库复跑包含 `--database-restart`，`~/.codex/virtual-actor-builds/server-decoupling-20260930-db-edge-restart-run/result.json` 为 `passed=true`、`cleanupErrors=[]`。owner-a PostgreSQL 在保留数据和 Actor 进程的条件下实际停止并重启；另一 owner 在停机期间继续处理，恢复后的 caller 重放只产生一份结果，原 lease 仍有效。此结果覆盖该 runner 的三种定向数据库故障，不代表完整故障矩阵。
- RoomWrite 提交后收尾现先校验单条或整批持久结果，再发布缓存、结算额度与记录热度；修复了结果转换或批量下标异常时先产生进程内效果、随后报告结果不明的顺序问题。提交 `943697d7` 的两条错误路径回归、`V2RoomWriteCommitEffectsTests` 定向测试及 macOS 全包测试目标编译通过。运行配置样例检查和 Account/Gateway/Operator/Actor 配置定向测试也通过；配置测试中一项需生成本地部署文件的用例按条件跳过。
- 当前提交 `e209dbd313317e9ac6a456a7591b578f4e7642bb` 在干净源码 checkout 中完成六个 Linux Release 产品构建，`~/.codex/virtual-actor-builds/server-decoupling-20260930-current-six-release-r2/result.json` 为 `passed=true`，记录锁文件及每个产品哈希。首次使用空 SwiftPM scratch 的构建在依赖获取阶段因容器缓存目录缺失失败，未进入源码编译；复用已锁定依赖的 scratch 后通过。此构建不替代当前提交的运行与性能验收。
- 同一 `e209dbd3` 源码与六产品构建在本机一次性独立 Host 应用栈通过，`~/.codex/virtual-actor-builds/server-decoupling-20260930-current-app-run/run-52a09bafb5b342388590a4877cec5802/result.json` 为 `passed=true`，模式为 `remote-gateway`。Gateway 仅作为 caller，直聊接受与收件方房间日志交付通过；Account HTTPS、Operator 禁号、TLS、私有指标及 Actor HTTP 昵称、邀请、媒体发送/下载均通过。该运行只覆盖当前源码的这一种模式，其他故障与性能结果仍按各自源码版本解释。
- 启动后失败的资源归属修复见 `4a39bac9`：若 Host/caller 节点清理抛错或排空未完成，`V2RoomActorApplication.start` 统一返回 `incompleteShutdown`；Gateway/Account 在此情况下直接以失败状态退出进程，不会提前关闭节点仍可能使用的数据库和事件循环。两种受影响 macOS 产品编译通过，未执行该异常路径的进程级故障注入；先前应用栈结果不覆盖此提交。
- 该修复的 Linux Release 编译已补齐：干净源码 `cffda8e53f8376e9992176084b7b9b022ff70dbf` 的 `IMV2AccountServerApp`、`IMV2ServerApp`、`VirtualActorBusinessProbe` 均通过，证据 `~/.codex/virtual-actor-builds/server-decoupling-20260930-startup-drain-release/result.json` 记录源码、锁文件、固定镜像与三个产物哈希。专用 Colima profile 在构建后停止；此结果只证明编译。
- 真实远端服务器已停机，不属于本轮验证。性能基线对照与完整故障矩阵仍未执行，因此 P6 整体验收尚未完成。

## 代码收尾结果（2026-09-29）

- 标量接受和持久化改由 `V2RoomWriteScalarAcceptancePath`、`V2RoomWriteScalarPersistencePath` 承担，共享围栏与授权检查归 `V2RoomWriteSelectedOwnerGuard`。Store 保留事务及提交后责任；审核模式显式传入，热度观察仅传布尔值，事务内组件不持有 Store、缓存发布器或额度池。
- 单条 direct projection 使用借连接组件；删除无调用的 `acceptHotDirectRoomLog`。当前 Infrastructure 与冻结候选的 743 段多行 SQL 文本哈希多重集一致。该源码对照不代替行为验证。
- 清理 worker 自导入、冗余访问修饰符，以及邀请查询路由遗留的私有写入 DTO、响应辅助类型、未调用 helper 和过期说明；现行路由保持不变。
- 昵称、邀请 operation admission/submit、resource upload/finalize/status 和下载 plan 冒烟脚本已适配现行合同；Python/Shell 语法检查通过，未运行脚本。

最终执行 `swift build --build-tests --disable-automatic-resolution --jobs 4 --package-path IMV2Server`，在当前 macOS/Swift 6.4 工作区退出 0，耗时 81.07 秒，产品及测试目标均编译通过，未执行测试。日志为 `/tmp/imv2-decoupling-code-final-build-v2-20260929.log`。标量迁移首次增量编译发现审核模式参数遗漏，补齐显式参数后取得该通过结果。仍有既有依赖 identity、deprecated 和测试诊断警告，本轮未升级依赖。

架构静态结果：删除仅供旧资源导入构造 API 使用的 shim 后，当前清单为 575 个文件、1951 个唯一声明、1941 条符号边，零分类例外、零越层依赖、零跨 target 循环。Actor 台账通过：416 个归属文件、31 个 writer ID、46 条声明、36 个 catalog row、235 个 DTO；相关写入证据已随标量路径迁移更新。文档链接及结构检查通过。

此前 Linux Release 产品对应 `c1944b1a`，不覆盖本轮标量收尾后的源码。本轮未启动 Docker、未执行 PostgreSQL/故障测试、未采集性能样本；如恢复整体验收，应从当前代码重新构建受影响的 Linux 产品。

## 当前工作范围（2026-09-29）

按用户最新要求，本轮完成代码收尾并确认编译，不恢复完整业务测试、独立进程故障测试或性能采样。2026-09-28 暂停时运行中的构建和测试已终止，本轮创建的临时数据库已清理，专用 Colima profile 的临时 DNS 已恢复且虚拟机已停止。下文按时间保留的启动、失败及通过记录均为历史证据。

本轮复核资源、入口、房间执行、RoomWrite、SwiftPM 与 worker 的实际边界，并完成上述代码收尾。统一编译产品与测试目标，不执行测试；最终结果见上方记录。

## 基线与验证环境

- 开始源码版本：`524716ef2204992270bd0439984a97aab47dc5a5`。
- 开始时业务源码无未提交修改；规划文档及 `.swiftpm/` 为已有工作区内容。
- 工具链：Apple Swift 6.4，arm64 macOS；版本输出为 `swiftlang-6.4.0.34.1`。
- 本地 PostgreSQL socket `/tmp:5432` 可连接；所有变更验证只使用脚本创建的独立可丢弃数据库。
- 测试专用 Colima Docker 环境曾用于 Linux Release 构建及应用栈冒烟，结果见下方历史记录；暂停后已停止，本轮不启动。
- 性能基线尚未采集，当前不宣称性能改善或 P6 完成。

## 当前实现

| 阶段 | 当前状态 | 剩余工作 |
| --- | --- | --- |
| P0 | 源码边界检查、初始违规基线和逐文件迁移清单已建立 | 可比较的性能基线尚未实测 |
| P1 | 资源生命周期/导入/迁移/展示依赖接口和强类型快照；SQL 与数据库接线分离；定向资源 PostgreSQL 回归通过 | 完整受影响矩阵仍待最终验收 |
| P2 | HTTP operation 与文件流入口依赖能力接口；Gateway 按命令族分派；四种本机应用栈模式通过 | 其余受影响路由 suite 待最终验收 |
| P3 | 房间业务执行与 PostgreSQL 适配分离，工厂组装五类能力；本机 G4/G6 接管与围栏通过；启动失败后未排空的节点不会触发共享资源关闭 | 其余生命周期/取消矩阵及启动故障注入待最终验收 |
| P4 | scalar/direct fast/rich batch/hybrid/forward 路径、授权与事务协调、提交后处理及组合状态已收拢；提交后效果先校验结果；原生故障定向回归通过 | 扩展故障矩阵与热点性能对照尚未完成 |
| P5 | Contracts/Application/Infrastructure/Gateway/HTTP 已独立；旧 Server 收敛为 15 个组装/配置文件；当前源码的六个 Linux Release 产品和运行配置定向检查通过 | 完整受影响测试仍待最终验收 |
| P6 | 原生跨库、Host 恢复、COMMIT ACK-loss、SIGKILL 定向场景，本机四种应用栈模式、G4/G6、独立 control/owner 链路断开及 owner-a PostgreSQL 重启已通过；当前源码另通过独立 Host 应用栈 | 完整故障矩阵与性能对照按此前要求暂缓，整体验收未完成 |

源码边界脚本 `scripts/check_v2_server_boundaries.py` 已接入 `run_v2_swift_tests.sh`。初始版本的 33 项资源应用层与 HTTP 具体 Store 依赖已消除，当前例外清单为空。该脚本是源码模式检查；它不替代编译器依赖约束、行为测试或事务一致性验证。

## 实施与验证方式

使用三个 GPT-6 Sol、medium 子任务分别实施资源层、传输入口、房间执行；主任务负责 RoomWrite、集成、模块迁移及统一验证。并行编辑期间各子任务只做语法/差异检查。统一构建前冻结生产源码编辑；类型诊断集中处理后再构建。

早期两次构建遇到了并行文件拆分的中间状态，报缺失类型，未用作最终验证证据。冻结文件拆分后的 macOS 全包构建通过（32.92 秒）。

首批针对性测试编译发现资源测试中旧的 `.init(database:)` 闭包无法推断协议返回类型，已改为明确的 PostgreSQL 实现。资源端鉴权错误映射、非法 UUID 的抛错行为及终态 session JSON 解码行为也已按原合同校正。

第一轮筛选结果为 45 个测试、6 个 suite，通过，用时 24.612 秒（测试目标编译另计 159.11 秒）。其中 8 个资源数据库测试因使用独立 opt-in 配置而跳过，不计为资源数据库验证通过。实际运行的关键数据库场景包括：授权 ACK 失败 2 例、批量授权回滚 2 例、转发授权与终态恢复 18 例；同时运行 Gateway 命令测试、无数据库资源签名后 generation 重查、事务所有者缓存发布测试。

资源数据库检查使用另外两个新建、安装当前 schema、运行结束后自动删除的独立数据库，显式配置 `IMV2_RESOURCE_TEST_DATABASE_URL` 和 `IMV2_RESOURCE_FORWARD_TARGET_DATABASE_URL` 后补跑受影响场景。补跑通过：5 个 suite 中的 8 个测试实际执行、无跳过，用时 1.880 秒。覆盖上传、生命周期回放与 generation、导入源持有、群头像命令与展示、资料签名后的权限重查。日志位于 `/tmp/imv2-decoupling-resource-tests.log`。

验证遵循用户“不要过度测试”的要求：每一批稳定改动统一构建，按改动选择已有测试，只有新增独立边界或故障风险时补少量必要用例。相关检查通过后继续下一批，不重复跑无关全套测试。

## 模块迁移前的第二批拆分

资源媒体值、时间戳纯值与精确范围规则、房间执行能力陆续归入 Contracts；PostgreSQL 时间编解码留在 Infrastructure。事件日志值与服务分离，服务只依赖提交事实观察接口。预编码分页通过 Gateway 注入编码能力，日志缓存保持每次成员授权复核，命中编码缓存时仍不构造事件数组。

这一批统一构建通过（30.37 秒，日志 `/tmp/imv2-decoupling-build-2.log`），修正了 package 协议实现与 PostgreSQL 时间编解码的访问级别。边界检查通过，例外为零；定向测试通过：6 个 suite、36 个测试，无跳过；执行 3.750 秒，测试目标编译 136.68 秒，日志 `/tmp/imv2-decoupling-tests-2.log`。覆盖缓存命中延迟物化、成员修订边界、帧限制、精确时间戳、提交后缓存发布及真实数据库公开消息日志写入。目录分层尚不代表 SwiftPM target 隔离；Package 迁移、剩余反向依赖与 RoomWrite 路径收敛仍在实施中。

## 真实模块迁移（进行中）

`Package.swift` 已建立 `IMV2ServerContracts` 和 `IMV2ServerApplication` 产品与 target，调用方显式声明依赖和 import。Contracts 保留必要的纯密码学验证；数据库和网络驱动不进入这两个新 target。初始 Contracts 与 Application 切片分别独立构建通过，随后扩大的当前全包迁移也已通过 macOS 构建（最后增量 6.76 秒，日志 `/tmp/imv2-modules-build.log`）；本批定向测试已通过，具体证据见下文。

转发计划的业务编排已迁入 Application，具体 RoomRef 初始化接线留在组装层。GroupEvent wake 的值与接口归 Contracts，观察/relay 编排归 Application，连接分发归 Gateway。RoomWrite 新增 hybrid batch 事务内路径组件。编译暴露的 PostgreSQL 命名约束识别已移至基础设施，并新增逐项回退的定向测试；该测试已通过。

首个真实 `IMV2ServerInfrastructure` target 已建立，当前包含 PostgreSQL 时间戳编解码并仅依赖 Contracts/PostgresNIO/NIOCore。其余基础设施仍待迁移。遥测值与接口移入 Contracts，计数与文本指标实现移入 Application，protobuf 映射留 Gateway；用户事件契约与恢复 worker 分离。单条发送的数据库错误翻译归具体 PostgreSQL Store，Application 不再识别驱动错误。当前静态依赖图为 488 文件、零候选逆向边、零候选跨层循环；这是静态迁移辅助结果，不替代全量模块拆分和运行验收。

本批定向测试通过：5 个 suite、32 个测试，无跳过，执行 0.223 秒；测试目标最后一次编译 154.73 秒，日志 `/tmp/imv2-module-tests.log`。覆盖原子批次回退、约束错误识别、激活后续可用、数据库时间戳编解码、用户事件恢复和遥测并发。

随后开始下一批并行编辑：完整 Gateway 会话与传输链迁入真实 target、剩余应用与契约归属、RoomWrite direct fast 路径拆分。上述证据对应下一批编辑前的稳定点，后续编辑需要重新统一构建。

## Gateway 与应用层主体迁移

27 个 Gateway 文件已迁入真实 target，覆盖公共 protobuf、会话/字节流、命令分派、连接管理、TLS 与事件编码缓存。账号边缘的 IP 地址解析构造移至 HTTP，纯限流值和摘要留 Contracts。应用层剩余准入、邀请、转发与恢复编排已内移；指标快照归 Contracts，Actor 运行指标纯值归 ActorContracts。RoomWrite direct fast 的准备与借用事务追加已抽出，形态和授权策略谓词由共享纯实现统一维护；原 SQL 文本、锁顺序与提交后结算保持。

这批 macOS 全包构建通过（20.49 秒，`/tmp/imv2-gateway-build.log`）。定向 PostgreSQL/Gateway 测试通过：4 个 suite、17 个测试，无跳过，执行 2.103 秒，测试目标编译 163.56 秒（`/tmp/imv2-gateway-tests.log`）。真实可丢弃数据库中实际执行普通/Actor 两种模式的 reciprocal direct fast 缓存与修订围栏、分片额度不超卖；另覆盖 Gateway 会话/Actor 接线与运行指标。protobuf 生成及比对脚本已适配公共/内部协议的不同目录，使用现成 protoc 插件重新生成比对通过；schema readiness 检查路径修正后也通过。Actor 台账已更新并通过检查：412 个归属文件、31 个写者 ID、46 条源码证据、36 个目录行与 235 个 DTO 条目；该静态结果不替代运行时写者/fence 验证。

下一批开始提取 HTTP 所需账户/设备/密码/运维契约与纯认证逻辑，四个 Invitations 纯编排/端口迁入 Application。随后重算清单，迁移 Infrastructure 主体；HTTP 的 RoomRef 与文件流具体类型依赖仍需独立处理。新的编辑不由前一稳定点的构建/测试结果背书。

## HTTP 契约及事务内路径收口

HTTP 的账户、设备、密码及运维 DTO/错误/能力接口已提取到 Contracts；HMAC assertion、operator 认证和指标聚合归 Application。RoomRef 命令入口改用按业务划分的窄接口。本地媒体上传通过关联类型约束暂存对象与提供方配对，资源字节流通过明确的读取/关闭接口暴露；HTTP 保留原有 range、ETag、取消和流关闭处理。

RoomWrite 的 forward inbox 与 rich/hot direct batch 路径已提取：路径组件只借用事务连接，Store 继续拥有事务、锁顺序、提交分类及额度/缓存收尾。组合状态约束仍待下一批收敛。本批随后完成了下节记录的统一构建与定向回归。

依赖分析脚本新增 HTTP target 覆盖；源码边界检查禁止 HTTP 导入旧 Server、Infrastructure 和数据库驱动，并验证注释/字面量不会误报。新增覆盖发现邀请查询协议仍与 Actor 客户端混放，已纳入本批迁移修正。


## Infrastructure 主体与 HTTP 模块闭合

268 个旧 Server 文件已迁到 Infrastructure（含内部 NATS protobuf）；激活恢复校验另抽为包内基础设施入口。当前扫描范围共 569 个文件：Server 15、Contracts 82、Application 126、Infrastructure 270、Gateway 27、HTTP 49。静态图零候选逆向边、零跨模块循环；HTTP 不再依赖旧 Server 或数据库 target。

本批 macOS 全包构建通过（17.12 秒，`/tmp/imv2-infrastructure-build.log`）。源码边界、公共/内部 protobuf 重新生成比对、schema readiness 表覆盖检查均通过。Actor 台账同步后检查通过：412 个归属文件、31 个写者 ID、46 条证据和 235 个 DTO。首次测试编译发现部分测试仍通过旧 Server 的 `@testable` 读取已迁走的内部实现，已将测试访问同步至 Infrastructure；本批定向测试已通过：9 个 suite、44 个测试，执行 14.590 秒，无跳过（`/tmp/imv2-infrastructure-tests.log`）。覆盖媒体流上传/取消/range/ETag、邀请映射、密码/设备及消息 operation HTTP、指标缓存，以及真实 PostgreSQL direct 日志/批次和 forward inbox 接受、恢复及终态处理。

最终验收的具体命令、故障 opt-in 和环境缺口见[验收矩阵](server-decoupling-validation.md)。本机 Docker daemon 当前不可连接；Linux、独立服务角色及性能对照仍未完成。


本轮迁移造成的源码文档链接已修复（65 处，涉及 15 份文档），RoomWrite 拆分记录已更新到当前事务协调、路径和提交后职责。全仓文档链接检查仍报告弱网提案中的 4 个既有 ClientKit 断链；不计为本轮服务端验证通过。进一步只读检查确认默认 Docker 和现有 `imv2-va-capacity` Colima profile 均未运行。

下一批实施 RoomWrite 归属与控制授权的显式组合状态，同时删除旧 Server 的冗余直接依赖；上一稳定点测试不自动覆盖这批编辑。


## RoomWrite 组合状态与包依赖清理

归属选择现由受控构造的 `V2RoomWriteOwnerSelection` 保存路由、activation 和 forward source；保留独立 activation 和同房间转发的合法输入。`V2RoomWriteControlResolution` 将未准备与已准备控制事实分开，已准备但无 grants 不会再次预留。事务所有权、SQL、锁、ACK 及提交后处理顺序维持原合同。

旧 Server 已删除 Argon2、protobuf、Crypto、TLS 和部分数据库驱动的冗余直接依赖；HTTP 删除未用 ActorContracts 导入。macOS 全包构建通过（最后增量 8.79 秒，`/tmp/imv2-scope-build.log`）。更新后的边界/台账检查通过，静态图为 571 文件、零逆向边与零跨模块循环。本批定向故障回归通过（`/tmp/imv2-scope-fault-tests.log`，退出码 0）：编译 182.75 秒、执行 33.801 秒，6 个 suite。运行器报告 19 项测试，其中 18 项实际通过，1 项仅供子进程调用的 crash 入口在父进程按设计跳过。实际执行包括：单/双房间 COMMIT ACK-loss 各 1 项、Host 恢复 3 项、作用域构造 4 项，以及 owner fence、operation receipt、借用事务缓存、群批次与转发检查。授权 SIGKILL 8 个和入群配额 SIGKILL 6 个参数场景均实际执行通过；全部 8 个本轮创建的独立数据库已由脚本清理。

文档结构检查另报告既有 `docs/reviews/message-send-dual-transport.md` 未列入 reviews 索引。未将该检查或仍有 4 处 ClientKit 断链的链接检查标为通过。Linux Release、G4/G6 独立 Host、真实 Account/Gateway/Operator 栈及性能基线对照仍待执行；本轮不宣称整体完成或性能改善。


## Linux 验收启动

2026-09-28 已启动此前停止的 `imv2-va-capacity` Colima profile，未切换默认 Docker context。该环境已有固定 Swift 6.4 Linux 镜像，现已开始应用栈 runner 的 Linux Release 构建，使用独占 scratch `~/.codex/virtual-actor-builds/server-decoupling-20260928-swiftpm`，源码只读挂载。此次运行仍在进行，尚无 Linux 通过结论。

由于生产修改尚未提交，另保存了 1327 个源码及验证脚本文件的冻结快照与逐文件哈希；聚合 SHA-256 为 `c191d55f750912454c5d162fe66da948438207c6a6253898bdb428f5b4a8654f`，位于 `~/.codex/virtual-actor-builds/server-decoupling-20260928-runs/source-manifest.json`，同目录保留 `source-snapshot.tar.gz`。运行结果中的 HEAD 必须与此快照一并解释，不代表当前未提交代码已属于该 commit。

文档收口：已依据实际 ClientKit 实现修正 4 个旧链接及对应表述，并补消息发送双通道审查索引；文档链接、结构及差异检查现在均通过。

首次两次 Linux runner 都在依赖获取阶段结束：容器默认 DNS 不能解析 GitHub，未进入业务源码编译。测试 VM 的 Docker daemon 已临时配置 DNS `1.1.1.1`，默认容器 Git 请求验证成功，随后重新启动原应用栈流程。原配置备份为 `/tmp/imv2-decoupling-colima-before.yaml`，待验收结束恢复网络 DNS 与 Docker 配置并停止该 profile；不修改默认 Docker context。

性能对照的基线工作树已由 Codex 管理：`~/.codex/worktrees/server-decoupling-baseline/IMMonorepo`，HEAD 为 `524716ef2204992270bd0439984a97aab47dc5a5`，创建后核实无修改。其 Gateway/LoadGenerator Linux Release 构建已启动，scratch 与候选隔离，使用同一固定镜像、2 CPU 与 6 GiB 容器上限。该构建只准备对照产物，不计为性能测量。已有 hot canary 的历史数据没有形成 direct atomic batch，因此另准备显式验证原子批次实际提交的补充测量，不能以单条发送负载替代批量路径验收。


### Linux 入口兼容修复与第二版源码快照

应用栈运行 `run-4bb857118402436aa5d9734fbba109f3` 在 Linux 编译阶段退出，未进入服务冒烟。Swift 6.4 拒绝 Account 入口对 C 全局 `stderr` 的并发不安全访问。只读基线确认三个服务入口均已有这种写法；本轮将三处错误输出改为 `FileHandle.standardError.write`，保持原错误字节、换行和失败退出行为。该修复只作用于无效日志级别的启动失败路径。

修复后的源码已再次冻结并保存 `source-manifest-v2.json` 和 `source-snapshot-v2.tar.gz`，聚合哈希 `73ea6392e64ee01f7990040b7e98cbf5a5880ddcc9593032b6cbe9b33946027c`；逐文件比较确认仅三个 App 入口改变。新的应用栈 runner 使用原 scratch 增量构建，结果待确认。原失败记录继续保留，不计入通过证据。

Caddy 镜像拉取还需要测试 VM 本身可解析镜像仓库，因此临时保存 VM `/etc/resolv.conf` 至 `/tmp/imv2-decoupling-resolv-before.conf` 并使用 `1.1.1.1`。`caddy:2.8-alpine` 已拉取成功；该 VM resolver 也须在最终环境清理时恢复。


第二版运行 `run-0242e5685f8846f6b5a74b2f18042aeb` 已构建四个 Linux Release 产品（Account、Gateway、Operator、LocalGatewayProbe），真实服务均启动并健康。黑盒冒烟随后在容器内 probe 调用账户 HTTP 时连接被拒绝：验证脚本将宿主 `localhost:<动态端口>` 传进 Gateway 容器。此运行整体失败，不能计为应用栈通过；正在将宿主 HTTP 地址与容器内 probe 地址分开。该接线问题在起始版本也存在。

原始性能基线构建已终止，失败原因同为 ServerApp 的 `stderr` 并发检查。独立基线工作树仅应用三个入口的兼容修复，形成真实本地 snapshot commit `b01bb09338ddde61374af9d19f031173bab06b07`（父提交为 `524716ef2204992270bd0439984a97aab47dc5a5`），已确认 clean，未推送。精确补丁 SHA-256 为 `61eddf937804b4027b08fcc87d7c79c5d35b1475511c1af97444ad8d21ba2def`，证据位于 `~/.codex/virtual-actor-builds/server-decoupling-20260928-baseline-stderr-compat/`。基线增量构建已重新启动；后续对照绑定此实际版本，不再将产物标作未经修复的原始 SHA。

P6 静态复核还发现少数恢复/审核/推送 worker 的纯业务编排和 SQL 实现仍混放 Infrastructure；已开始最后的职责迁移。第二版 Linux 构建证据不自动覆盖随后源码改动。主工作区保持未提交；另建立候选工作树供最终冻结与性能产物溯源，目前尚未录入候选源码。


### Worker 业务边界与可追溯候选

PushWake、ContentReview、RoutedContentReview、SyncHousekeeping、邀请创建恢复、入群配额恢复及资源恢复的纯编排已迁入 Application。SQL、过期事务和具体 Actor 接线保留 Infrastructure；资源恢复的持久 JSON 解码留在适配器，并以每项强类型 Result 保持遇到坏行前已完成候选的行为。macOS 全包构建通过（37.44 秒）。随后的统一定向回归通过：4 suites、14 tests、无跳过，执行 7.218 秒（编译 151.42 秒），包括 6 个真实 SIGKILL 入群配额恢复参数场景；日志 `/tmp/imv2-worker-boundary-tests.log`，五个独立测试数据库正常清理。

更新后的静态清单覆盖 576 个文件，1955 个唯一声明、1946 条依赖边，越层边/跨模块循环/归属 override 均为零。Actor 台账检查通过：416 个归属文件、31 个 writer ID、46 条证据、36 个目录行、235 个 DTO。文档链接与结构检查通过。创建隔离候选快照时将 29 处多余文件尾空行统一为单个换行，未改变语义；这是已运行测试之后唯一的 Swift 格式调整。

独立候选工作树 `~/.codex/worktrees/server-decoupling-candidate/IMMonorepo` 已冻结为真实本地 snapshot commit `c1944b1a103b121cc73b36beceb5348cc465fc88`。1628 个源码、测试、配置及脚本文件均与主工作区逐文件 SHA-256 相符，记录在 `~/.codex/virtual-actor-builds/server-decoupling-20260928-candidate-snapshot/source-manifest.json`。主工作区保留未提交状态，快照未推送。当前 Linux runner 从此 clean 候选启动，以便后续产物复用可核验真实源码身份。

可构建基线 `b01bb09338ddde61374af9d19f031173bab06b07` 的 Linux Gateway/LoadGenerator 已通过构建，证据 `~/.codex/virtual-actor-builds/server-decoupling-20260928-baseline-compatible-release/result.json`。独立性能 harness 已冻结为 `a8dcae1faf999a94d24b5451ff94e184bf6a88c6`，保留来源与校准检查，两版均要求 Actor 指标；新调查门槛为吞吐下降 5%、P95/P99 上升 10%。尚无实际性能样本或性能通过结论。临时的基线 harness 接线 commit `216cfd2d` 保留为单独分支证据，被测基线工作树已恢复至与产物一致的 `b01bb093`。

### 候选 Linux Release 与本地应用栈现况

候选 `c1944b1a103b121cc73b36beceb5348cc465fc88` 的 Linux Release 结果为 `passed=true`、退出码 0，固定镜像 `swift:6.4-jammy@sha256:a6053d2de72091906bfa064f76f145e3f28830664cae250e1b84aa8c499a8ee6`、lockfile SHA-256 `3af1e16190f46bdd8fad3de86c6b386dc196443291463355bf36edb62b7fd15c`。实际生成六个产品：`IMV2AccountServerApp`、`IMV2ServerApp`、`IMV2OperatorServerApp`、`IMV2LocalGatewayProbe`、`IMV2GatewayLoadGenerator`、`IMV2ResourceImageWorker`。逐产品 SHA-256 见 `~/.codex/virtual-actor-builds/server-decoupling-20260928-candidate-release/result.json`。可比基线 `b01bb09338ddde61374af9d19f031173bab06b07` 用同一镜像、lockfile、2 CPU/6 GiB 限额成功构建 Gateway 与 LoadGenerator；证据为 `~/.codex/virtual-actor-builds/server-decoupling-20260928-baseline-compatible-release/result.json`。这些是构建结果，尚无性能测量结论。

应用栈使用已核验的候选预编译产品；harness 来源 `6237fa62c06dc86c37b732597ffc68df040dcb4d` 经唯一脚本 `IMV2/scripts/test_v2_virtual_actor_application_stack.py` 的补丁形成 `db5cd51705696f7052d2bc8c176fd27633037f5d`，补丁 SHA-256 为 `54743da122b701edbf3d9051d1cac07f307ec8c830a08636e9fc0f944e7ba39f`（`~/.codex/virtual-actor-builds/server-decoupling-20260928-app-harness/provenance-v2.json`）。本地模式 `run-ac2ea47bf02f435da43eaf1403cdf6a7` 的 general smoke 已记录账户 HTTPS、密码注册和设备凭据、Gateway direct chat、密码失败限流、Push 端点注册/移除、Operator 禁号、TLS 1.3 及私有指标检查通过；`smoke.log` 给出逐项结果。紧接着 Actor HTTP smoke 在 `group nickname write and read` 阶段失败，`actor-http-smoke.log` 只记录 `SmokeFailure`，不足以判定根因。该次 `result.json` 为 `passed=false`、`failureType=CalledProcessError`，整个应用栈不能标为通过，昵称阶段正在定位。证据位于 `~/.codex/virtual-actor-builds/server-decoupling-20260928-runs/run-ac2ea47bf02f435da43eaf1403cdf6a7/`；P6 仍未完成。
