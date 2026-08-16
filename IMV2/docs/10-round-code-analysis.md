# 十轮代码分析与问题处理表

本记录以当前工作树为准。每一轮都执行全仓搜索，并用一个独立风险视角审查
App、共享 ClientKit/Core、服务端、数据库、脚本与测试；只有完成修复和定向
验证后才把该轮标记为完成。生产环境、真实设备或外部服务才能证明的事项会明确
保留为未处理/待验证，不用本地单元测试替代。

| 轮次 | 审计范围 | 发现的问题 | 等级 | 处理方案 | 验证证据 | 状态 / 未处理原因 |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | 架构边界、模块依赖、领域/基础设施类型 | `IMV2ServerHTTP` 同时承载 Vapor transport 与四组 PostgreSQL store/限流事务，HTTP target 因此直接依赖 Fluent/SQLKit；密码路由还绑定具体 PostgreSQL store，不能用能力替身验证完整成功路径 | P2 | 把账户边缘限流、密码账户 store、登录限流、认证审计和公共身份目录的协议/错误/PostgreSQL 实现移入 `IMV2Server`；HTTP target 只保留 middleware、DTO、鉴权及状态映射；密码路由改依赖 `any V2PasswordAccountStoring`，composition root 显式选择 PostgreSQL 实现；移除 HTTP target 的 Fluent/SQLKit 依赖 | `swift test --package-path IMV2Server --filter V2PasswordAccountRoutesTests`：6/6 通过；新增 fake-store 成功路径证明 transport 只向持久化边界传 bcrypt digest；全 target 编译通过；搜索确认 `IMV2ServerHTTP` 不再导入/调用 Fluent、SQLKit 或原始 SQL | 已处理 |
| 2 | Swift 6 并发、Task 生命周期、取消 | 账户服务在 `Application.startup()` 前启动两个非结构化维护任务，后续 provider/route/startup 抛错时 catch 未取消它们，会让任务继续访问正在关闭的 DB/event loop；ClientKit 快照激活后创建未持有的清理 Task，生命周期无法由 sync engine 收回 | P1 / P2 | 账户服务增加 actor supervisor，所有正常和异常退出先 cancel-and-wait，再关闭 App/事件循环；快照清理 Task 改由 `V2SyncEngine` 持有、替换时取消、engine deinit 时取消，保留清理不延长 ACK 事务的设计 | `swift build --package-path IMV2Server --target IMV2AccountServerApp` 通过；`swift test --package-path IMV2ClientKit --filter V2SyncEngineTests`：48/48 通过；并发模式全仓搜索复核了 `Task.detached`、continuation、AsyncStream buffering、长循环和取消分支 | 已处理；进程被 `SIGKILL` 时任何应用级清理都无法运行，这是操作系统语义而非可修复代码缺陷 |
| 3 | 服务端事务、锁顺序、一致性 | PostgreSQL 登录失败计数的拒绝路径按规范化账号句柄取得事务 advisory lock，成功路径却直接 `DELETE`；当记录尚不存在且两个副本并发时，成功事务可先删除空集合，随后排队的拒绝事务插入失败窗口，导致已成功登录仍残留错误失败计数甚至锁定 | P1 | 提取统一的账号句柄锁函数，失败计数和成功清除在同一事务中先取得同一把 advisory lock，再读写限流状态和审计事实；新增真实 PostgreSQL 确定性竞态测试，先阻塞锁、再依序排队拒绝和成功事务，验证最终无残留状态 | `bash scripts/run_v2_postgres_integration.sh`：一次性 PostgreSQL 上 70 个 suite、318 个测试全部通过；新增测试通过 `pg_locks` 确认两个竞争事务都已排队，释放后验证限流表无该句柄记录；容器和网络已自动清理 | 已处理 |
| 4 | 协议、网络输入、分页、背压 | 本地对象边缘以 `.collect(maxSize: maximumUploadBytes)` 把整份附件读成 `ByteBuffer` 再复制成 `Data`，下载也先构造整文件 `Data`；并发大附件使服务端峰值内存按附件大小与并发数相乘，且上传处理没有磁盘写入背压 | P2 | 上传改为 Vapor request-body `AsyncSequence`，逐块转换并通过 NIO 异步文件系统写入 provider 私有随机暂存文件；要求签名声明、`Content-Length`、边缘上限和实际落盘大小完全一致，提交时再次验证有效期并同卷原子移动；所有失败路径删除暂存文件。下载先验证签名与文件大小，再用异步文件流逐块回写。复核 TLS 帧、NATS parser、网关入站队列、live hint 和分页均有帧数/字节数/块数或页大小上限 | `swift test --package-path IMV2Server --filter V2VaporLocalFilesystemMediaRoutesTests`：3/3 通过；覆盖流式上传/下载的精确字节、无暂存残留、超预算请求在暂存前返回 413、无效 capability 保持不透明；`git diff --check` 通过 | 已处理；该 provider 明确只用于本地开发/隔离测试，生产对象存储及 CDN 的流式实现仍由部署适配器负责 |
| 5 | 认证、安全、隐私、密钥、日志 | Vapor 默认 `ErrorMiddleware` 在每个错误日志中记录完整 `req.url.string`；本地对象边缘的 `target` 查询值是可在过期前重放的上传/下载 capability，因此 4xx/5xx 会把短期凭据写入日志。默认访问日志也记录真实路径参数，增加账号/媒体/设备标识泄露与日志高基数风险 | P1 | 新增全服务统一的 redacted HTTP middleware 基线并在 gateway、account、operator 三个 composition root 创建 App 后立即替换默认中间件；访问和错误日志只保留 method、匹配后的 route template、status，不记录查询、真实路径参数、headers/body、user-agent 或底层错误描述；未知 500 始终返回泛化消息，所有错误响应加 `no-store`。复核 Keychain accessibility、TLS 1.3、token HMAC、credential envelope encryption 和普通 logger 调用 | `swift test --package-path IMV2Server --filter V2RedactedHTTPMiddlewareTests`：1/1 通过；测试使用真实捕获 logger，证明签名 query、路径 ID、含数据库口令的 error description 均不进入日志，500 body 也不泄露；三个可执行 target 随测试构建通过；`git diff --check` 通过 | 已处理 |
| 6 | CPU、内存、I/O、数据库性能 | NIO 网关为每条连接保存分片 `Data` 数组并用 `pendingHead` 消费；达到清理阈值后在 event loop 上执行 `removeFirst(pendingHead)`。慢数据库或突发分片可把单连接队列推到 4096 块，此操作会周期性搬移大量仍保留的 `Data` 值，与同一 event loop 上的其他连接竞争 CPU；输入虽然有字节/块数硬上限，但容器算法仍造成不必要的尾延迟 | P2 | 提取 event-loop confined 的双维准入队列，底层改为 NIO `CircularBuffer<Data>`；append/pop 均为摊销 O(1)，入队前以防整数溢出的减法同时检查总字节、单块字节和块数，关闭时释放容量。复核对象边缘已是流式 I/O，worker 查询有 page/batch 上限，后台 cadence 带空闲退避，未发现其他明显的无界 CPU/内存热路径 | 新增队列测试执行 10 万次入队/出队和反复 ring wrap，验证 FIFO、精确字节计数与两个维度溢出不改变状态：2/2 通过；`V2GatewayByteStreamTests`：7/7，通过真实 handler 回归分片、帧限制、心跳、关闭；`V2GatewayConnectionAdmissionTests`：1/1 通过；`git diff --check` 通过 | 已处理 |
| 7 | 最终 Schema、索引、约束、清理策略（按项目未上线处理，不评估旧库迁移/历史兼容） | `PostgresV2ControlPlaneHousekeepingStore` 按 `state = 'terminal' AND terminal_at <= cutoff ORDER BY terminal_at, source_event_id LIMIT ... FOR UPDATE SKIP LOCKED` 清理 `room_outbox`，最终 schema 却只有非终态 claim partial index；随着终态 outbox 累积，每个小批清理周期都可能扫描并排序整张终态集合 | P2 | 在当前建库 SQL 的 bounded-housekeeping 索引组增加 `(terminal_at, source_event_id) WHERE state = 'terminal'` partial index，并更新 SQL manifest；逐一对照 sync capability、snapshot、fan-out leaf、媒体、审核、认证 replay、live lease 与 27 个幂等表的清理谓词/排序及现有索引，未发现另一处同等级缺口 | 真实一次性 PostgreSQL 上的 bounded housekeeping 集成测试通过；测试同时确认索引存在，并在关闭 seqscan 后对实际 `FOR UPDATE SKIP LOCKED` 候选查询执行 `EXPLAIN`，确认计划包含 `room_outbox_terminal_cleanup_idx`；SQL manifest、baseline append 规则、`git diff --check` 均通过；容器与网络已清理 | 已处理；按用户要求不把历史 migration、旧 volume 升级或兼容性计入问题 |
| 8 | 可靠性、幂等、重试、崩溃恢复、关闭 | 流式上传的普通失败路径会调用 `discardUploadedObject`，但进程在落盘后、原子提交前被强杀时无法执行应用级清理；下一进程的 `prepare()` 只创建目录，永不回收 `.upload-staging` 中没有任何可恢复事务语义的残片，长期会泄漏本地磁盘 | P2 | provider 首次 `prepare()` 明确定义为进程启动恢复边界：只删除其私有 staging 目录并重新以 0700 创建，不触碰已提交对象；actor 记录已完成 prepare，同一进程重复调用为 no-op，避免误删正在流式写入的文件。复核 durable worker 均以 claim token/lease、幂等结果、有限退避或 durable cursor 恢复，服务关闭路径显式 cancel-and-wait | provider 测试 3/3 通过：模拟前一进程留下分片，重建 provider 后确认残片被删、已提交对象仍可签名下载、同一 provider 重复 prepare 保留活动分片；Vapor 流式媒体路由 3/3 回归通过；`git diff --check` 通过 | 已处理；被回收的是未提交且没有数据库完成事实的崩溃残片，不能恢复也不应恢复；生产对象存储仍需自身 multipart-abort 生命周期策略 |
| 9 | iOS 状态、SQLite 边界、UI 生命周期、无障碍与自适应 | `V2DeviceSessionsStore.loadMore()` 没有与 `refresh()` 的快照代次绑定：旧 cursor 的分页请求可在刷新后返回，把旧设备追加进新快照并覆盖新 cursor；旧请求的 `defer` 也可能错误清除更新请求的 loading 状态。去重集合只来自旧列表，同一返回页内重复 `deviceID` 仍会进入 SwiftUI `ForEach`，破坏稳定身份 | P2 | refresh 同步失效所有旧分页代次；分页捕获 refresh/load 两级 generation 与 cursor，只有仍属于当前快照时才提交；defer 只结束自己拥有的 loading 代次；用可变 Set 在追加过程中同时去重现有列表和页内身份。复核主 UI store 的 `@MainActor`、Task 所有权/取消、GRDB service 边界、图标按钮 label、组合语义、点击区域、Dynamic Type 和 RTL 门禁 | iPhone 17 / iOS 26.2 模拟器定向单测 4/4 通过，新增确定性悬挂旧分页测试与页内重复测试；本地 `IMAppUITests` 4/4 通过，执行 element detection、hit region、description、text clipping、trait，以及最大辅助字号 + Arabic RTL 场景；构建采用 Swift 6 严格并发 | 已处理；本轮未新增/修改用户可听文案、accessibility identifier 或本地化 key。完整已登录聊天/设备页的 VoiceOver 人工阅读顺序、真机 Increase Contrast/Reduce Motion 仍需发布前设备验收 |
| 10 | 测试、CI、配置、可观测性、发布门禁 | GitHub Actions 额度耗尽后可用的 `scripts/verify_v2.sh` 并不等价于 workflow：它遗漏 iOS unit/UI accessibility tests、Prometheus/Compose 配置检查；本地 PostgreSQL compose 只有一个数据库，也未设置 `IMV2_REQUIRE_CROSS_STORE_POSTGRES_TESTS=1`，因此跨 store/shard 测试通过 `guard` 静默返回，造成总门禁假绿 | P1 | 本地 integration compose 增加独立 secondary PostgreSQL；运行脚本同时传入两个 URL 并强制 cross-store 测试必须配置。扩展唯一总门禁依次执行三包测试/生成物与静态门禁、Prometheus、Compose env precedence、双库 PostgreSQL、iOS build-for-testing、全部 App unit tests 和 signed-out accessibility UI tests；临时 `.env.local` 只在原文件不存在时创建并由脚本回收，不覆盖开发者配置。保留云 workflow，不用“禁用 CI”掩盖额度问题 | 双 PostgreSQL 本地集成：72 suite、323 tests 全通过，日志明确包含 cross-store copy、fan-out retry、目标库故障恢复和 forwarding；Prometheus 17 条规则/配置通过，Compose 环境优先级通过；compose config、两个脚本语法和 `git diff --check` 通过；最终总门禁结果见下节 | 已处理本地覆盖缺口；GitHub Actions 额度是外部账号状态，无法由代码修复，云端 runner 本轮未运行且不宣称云 CI 通过 |

## 最终本地回归

最终执行 `bash scripts/verify_v2.sh`，退出码为 0，结尾明确输出
`verify-v2 result=pass`。该单一入口实际完成了 Core、ClientKit、Server 三个
Swift package 的测试和静态/生成物门禁、Prometheus 17 条规则、Compose 环境
优先级、双 PostgreSQL 323 个测试（72 个 suite）、iOS build-for-testing、全部
App unit tests，以及 4/4 signed-out accessibility UI tests。验证完成后一次性
数据库、网络和容器均已清理，原有 `IMV2/.env.local` 未被覆盖或删除。

十轮共确认并修复 11 项问题：P1 级 4 项、P2 级 7 项。当前表中没有已知但因
实现困难而搁置的代码缺陷；仍需生产部署或真机环境才能闭环的风险单列如下。

## 已知外部约束

- GitHub Actions 额度已用完。本次十轮验证以本地命令、一次性本地 PostgreSQL、
  Simulator 和静态门禁为证据；云端 workflow 不能执行会保留为外部阻塞，并在
  第 10 轮验证本地门禁是否覆盖相同检查。
- 本地文件媒体 provider 已解决流式背压和崩溃残片回收；生产对象存储/CDN 的
  流式 adapter 与 multipart-abort 策略属于部署实现，仍需在选定供应商后验证。
- 本轮 iOS 无障碍覆盖最大 Dynamic Type、Arabic RTL、元素可发现性、点击区域、
  描述、文本截断和 traits；完整登录态 VoiceOver 阅读顺序、真机 Increase
  Contrast/Reduce Motion 仍需发布前验收。本轮没有新增或修改用户可听文案、
  accessibility identifier 或本地化 key。
