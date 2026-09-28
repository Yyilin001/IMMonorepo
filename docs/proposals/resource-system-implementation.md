# 资源系统实施进度与验收缺口

更新：2026-09-27。本阶段实现基于 `9ba7264c`，随资源系统代码一并提交。状态：实施中，尚未满足完整资源系统的交付条件，也没有生产容量批准。

完整范围仍以[资源系统实施方案](resource-system-design.md)为准。下面区分运行时已经接入的路径、实际测试证据和仍需完成的工作；不能把本地适配器通过解释为任意运营商已经通过验收。

项目尚未上线，以统一的新模型和 canonical schema 为实现基线，不保留旧版本兼容、旧媒体回退或草案回填。重启恢复、未知结果核对和更换运营商仍属于新系统的运行要求。以下历史验证记录不构成保留旧实现的要求。

供应商接入的实际代码边界、配置方式、错误语义和验收要求见[适配器接入合同](resource-provider-adapter-contract.md)。

当前执行范围调整（用户于 2026-09-27 明确要求）：继续完成资源系统实现，但本阶段不进行生产验证和真实端到端测试，不以开通 S3 或其他云服务作为前提。保留单元测试、本地 PostgreSQL 组件集成、适配器合同测试及模拟器组件测试。下方涉及真实 CDN/云存储容量、远程全链路和部署验收的项目转为后续验证记录，不作为当前开发工作的阻塞条件；对应功能实现仍在范围内，不将未执行的验证标为通过。

私聊作者补充已接入提交事件的同步和异步投递路径，正文提交后才向有界 ingress 提交提示，沿用精确接收者、排除连接与页面 nonce。指定房间的资料读取使用 `memberRoom` 内部授权请求，由所属 Actor 检查实际房间类型和双方当前成员关系；显式群聊、私聊和入群审批权限仍各自隔离。App 的私聊消息行及页面订阅统一使用 `.room(roomID)`，避免推送与可见兴趣查询键不一致；联系人和会话标题继续按各自上下文读取。

调整范围前执行的原生测试发现私聊房间被误当群聊授权，已据此修正；该次测试失败，未重跑，不能作为私聊全链路通过的证据。本阶段改用本地组件验证此问题。

本地验证：服务端 52 个 test 声明 / 5 个 suite 串行通过（2.607 秒），涵盖私聊双方/陌生人/拉黑/离房、显式群权限拒绝、群昵称、签发期间撤权和有界 Gateway 分发。混合 `.group` / `.memberRoom` 的 50 个观察者合批及实际房间执行器装配另 2 项通过（0.176 秒）。App 模拟器会话 store 117 项通过，头像页面管线 9 项复跑通过（0.124 秒），搜索筛选专项通过；查询键改变后的旧测试预期已同步更新。静态 inventory（405 文件 / 231 DTO）、文档链接与差异空白检查通过，自有 PostgreSQL 测试库已删除。

证据：`/tmp/im-resource-direct-scope-server-serial.log`、`/tmp/im-resource-direct-scope-cohort.log`、`/tmp/im-resource-direct-scope-app-final.log`（会话 suite 通过，包含随后修正的头像夹具失败）、`/tmp/im-resource-direct-scope-pipeline-final.log`、`/tmp/im-resource-direct-scope-search.log`。服务端并发运行曾在 5 ms 控制域队列期限触发一次限流，停止同时构建并串行复跑通过；未放宽生产期限，也不将该轮结果解释为负载容量保证。

## 未上线项目的统一基线

扫描租约收尾现同时检查当前 claim token 与 PostgreSQL 微秒精度的租约截止。即使尚未被其他 worker 重新认领，已到期的执行者也不能发布扫描结果、安排重试或暂停任务；原任务保持可恢复。扫描 worker 按实际并发槽位逐批认领，避免一次取得整轮租约后让后续任务在本地排队消耗有效期，并继续遵守每轮总量上限。

扫描租约验证：24 个 PostgreSQL 微秒边界场景覆盖通过/失败发布、重试、暂停及重新认领后的旧 token 隔离；worker 专项验证下一批取得新期限且不超过执行槽位和每轮上限，均通过。相关媒体期限、计数、生命周期测试通过；维护时钟测试修复裸媒体消息夹具后，三种场景复跑通过（2.941 秒）。原生 HTTPS/TLS 链路通过（2.825 秒），临时库与自有服务已清理。证据：`/tmp/im-resource-scan-lease-final.log`（包含修复前的三项维护夹具失败）、`/tmp/im-resource-scan-maintenance-final.log`、`/tmp/im-resource-scan-lease-live/summary.json`。未以这些局部测试声称后台全部作业或容量验收完成。

旧上传存储清理：`PostgresV2MediaUploadSessionStore`、旧上传命令/grant 模型及通用媒体 store 的上传、状态、扫描回调和引用断言入口已删除。canonical schema 移除 `media_upload_operations`、`media_upload_grants` 及其五个索引，readiness 和 housekeeping 同步收敛。其余直接构造裸媒体的测试仍需逐项审查。

相应时钟/租约测试改用当前资源会话和真实消息附件引用。扫描重试或暂停后，旧 claim 不得绕过调度提交结果；已过期对象只收尾扫描任务，不发布可用状态。新 schema 建库、恢复和漂移检查通过，基线为 157 张表、368 个索引；Core 资源与媒体合同 19 项 / 3 个 suite 通过。

删表后的 PostgreSQL 验证覆盖 8 个 test 声明、44 个参数/独立场景，49.205 秒通过，包含微秒期限、持久回执、并发重放、下载计数与租约、扫描调度、消息引用和设备过期。原生 HTTPS/TLS 上传、头像变体、作者资料及附件下载/撤回链路再次通过（1 项，2.982 秒），自有服务及临时库已清理。证据：`/tmp/im-resource-grant-retired-server.log`、`/tmp/im-resource-grant-retired-schema.log`、`/tmp/im-resource-grant-retired-core.log`、`/tmp/im-resource-grant-retired-live/summary.json`。静态 inventory 为 405 个文件、231 个 DTO；这些结果仍不等于全量集成测试或生产万人容量验收。

删除旧上传清理类别后，housekeeping 的四种调度间隔专项通过（3.152 秒，`/tmp/im-resource-grant-retired-housekeeping-final.log`）。该验证同时修复测试建库工具：仅跳过 SQL 语句外部行注释，保留 dollar-quoted 函数体原文；原先全局去注释会改变群头像终态栅栏函数摘要，导致正确的 readiness 校验拒绝测试库。没有放宽生产摘要检查。

依据用户明确要求，本轮删除四个草案增量 SQL 文件及旧结构回填测试，数据库由 canonical schema 完整初始化；导入 hold 的所有字节事实从创建时即为非空。`V2BoundMediaProvider`、`V2PlacementMediaScanner`、`V2ResourceForwardMediaCopier` 已移除旧存储提供方依赖和目录缺失时的回退。清理器仍通过统一上传传输接口删除暂存，这是当前上传生命周期的一部分。个人头像绑定也必须具有当前目录、用途、placement 和完整变体，原先允许裸媒体记录的兼容分支已删除。

消息绑定与下载授权已要求资源目录中的所属房间、附件用途、当前 generation 和 active placement；裸媒体、错房间、头像用途、旧代次或正在退出的存储位置不能绕过校验。通用媒体授权不再提供头像分支，头像只经资料展示服务签发能力。Account 运行入口已撤下旧媒体上传 HTTP 路由，新的资源上传路由继续使用本地传输适配器的字节 PUT，这属于新上传流程。

App 的聊天附件改为必须交给绑定 room 的持久化发送接口；依赖不可用时保留草稿和文件，不回退到通用上传。个人头像上传也必须依赖资源引擎。个人资料页当前头像改用 `V2AuthorizedAvatarView` 的展示租约，本地选图仅作本地预览，已移除裸 mediaID 下载头像的调用。新增测试覆盖意图保存失败/依赖缺失时不发送、不丢文件，以及退出账号等待头像读文件任务结束。

ClientKit 已删除旧上传解析/完成/状态协议、旧 HTTP 上传客户端和内存上传编排。下载目标仅接受完整 GET 计划，长度和 SHA-256 都是必填字段；实际下载只接受 HTTP 200，通过字节数与摘要核验后发布文件。服务端旧业务上传 HTTP 路由、处理器、编排服务及旧上传目标/状态 DTO 已删除。下载服务协议也已只保留下载 grant 申请，移除旧上传、扫描回调和引用写入口。旧上传提供方会话兑换服务及底层 grant/store 均已删除。剩余旧集成测试尚未全部改写和执行，不能将新资源专项通过视为全仓库集成测试通过。资源 generation、operation 幂等、进程重启恢复和运营商迁移保护继续属于新系统的运行要求。

当前资源会话的集成测试继续收敛：并发上传重放改用 `resource_upload_sessions` 与 `resource_catalog`，验证相同请求复用已持久化会话/期限、不同媒体或大小冲突、异常重放时钟不改写状态；消息附件引用改为创建会话、发布精确 placement、扫描通过后接受，继续覆盖撤回/退群拒绝下载与保留清理；设备绝对过期测试在每个资源事务内读取真实设备有效性，验证发布、finalize、创建重放、状态和取消全部拒绝。三项 test 声明（并发重放含三个参数场景）在两个自建临时 PostgreSQL 库实际通过，耗时 8.165 秒；日志 `/tmp/im-resource-current-store-postgres.log`。其余时钟和租约测试现已转换，旧上传 store/table 已删除。

本地 SQLite 也已统一：主库只执行 `createCurrentV2Schema`，直接创建全部 231 个 schema 对象；搜索库保持独立基线。删除资源草案的 10 个增量迁移、重建表/回填 SQL 和快照补表逻辑；所有当前字段、约束与索引都在首次建表时生效。验证从“草案升级”改为同版本重启、在途 claim 和快照激活恢复，没有自动擦除用户现有开发数据库。

本轮验证：新上传引擎的六个取消注入点覆盖准入前、创建、目标、字节传输、完成及状态阶段，确认不再推进且 journal/源文件可恢复。ClientKit 模型、journal、恢复与下载相关 57 项 / 11 个 suite 通过（4.593 秒）；App 附件、会话、下载、文件租约与账户关闭 129 项 / 5 个 suite 通过（3.916 秒）。日志：`/tmp/im-resource-canonical-client-final.log`、`/tmp/im-resource-single-upload-app-final.log`。

完整 GET 额外验证通过（9 项 / 1 个 suite，包含返回 206 时即便字节匹配也不发布文件）。真实原生 HTTPS/TLS 链路重新通过，覆盖头像、昵称、入群审批和房间附件完整计划下载，全部自有服务与临时 PostgreSQL 已清理。首次执行中原始昵称 HTTP 检查触发 429；测试补上遵守 `Retry-After`、最多两次且单次不超过 5 秒的重试后通过，没有放宽服务端限流。日志：`/tmp/im-resource-download-status-client-final.log`、`/tmp/im-resource-canonical-live-02/client.log`、`/tmp/im-resource-canonical-live-02/summary.json`。静态 inventory、文档链接和差异空白检查通过。

旧上传 HTTP 表面已移除：删除 `V2VaporMediaUploadRoutes`、`V2MediaEdgeUploadHTTPHandler`、`V2MediaEdgeUploadService`、Core 的旧上传目标/状态 DTO 和无调用方的上传目标错误映射。新 [`V2ResourceRouteContractTests`](../../IMV2Server/Tests/IMV2ServerTests/V2ResourceRouteContractTests.swift) 验证 create/status/targets/finalize/cancel 的 15 个参数场景：认证先于解码与存储、缺失资源事实返回 400、认证 actor/device 不被请求正文替换、存储拒绝统一为 404。Core 时间边界测试改为当前上传计划，继续覆盖毫秒溢出、非有限值及舍入；本地字节 PUT 仍由新上传传输适配器使用，予以保留。

本轮验证：Core 19 项 / 3 个 suite、Server 18 项 / 5 个 suite 通过，Account 可执行目标同步构建通过。另在本轮新建并按 canonical schema 初始化的 PostgreSQL 库执行资源 HTTP 全链路测试，通过上传重放、默认存储切换后恢复原会话、完成/扫描、暂存删除后的最终字节下载、错房间拒绝及复制资源后释放 hold；该自有数据库已删除。日志：`/tmp/im-resource-retired-upload-core.log`、`/tmp/im-resource-retired-upload-server.log`、`/tmp/im-resource-current-upload-postgres.log`。静态 inventory、文档链接和差异空白检查通过；底层旧上传 store/session 方法及其旧集成测试仍需后续收敛，尚未完成全系统验收。

下载授权服务进一步收敛：`V2MediaStore` 协议只声明 `requestDownload`，`V2MediaService` 不再持有上传配置或提供旧上传/扫描/引用状态写入口；Account 装配和下载测试随之更新。底层旧 PostgreSQL 写方法仍有旧集成测试依赖，未将接口缩减冒充物理实现全部删除。

迁移时将上传时钟不变量补到当前 `PostgresV2ResourceLifecycleStore`：新建操作先验证 PostgreSQL 可表示且严格递增的期限，已提交 create/finalize/cancel 重试继续恢复既有结果；首次 create 从持久行返回期限，避免首响应与重放的微秒差异。claim/publish 用数据库原始微秒比较到期，claim 的 60 秒加法须可表示。cancel 使用带溢出检查的 generation 后继，拒绝最大代次的新取消而不修改 catalog/session/media/purge；已取消会话收到极端输入不再整数溢出。

真实 PostgreSQL 与服务边界测试共 16 项 / 6 个 suite 通过（0.720 秒）。新增快照验证覆盖非有限/超范围时间、微秒精度相等期限、首次期限与重读相同、已提交结果恢复、claim 租约加法越界、publish 拒绝不写入，以及未取消/已取消两种最大 generation 场景。实际资源 HTTP、独立供应商适配器回执与下载授权回归同时通过；测试数据库已删除。证据：`/tmp/im-resource-current-clock-server-final.log`。真实原生 HTTPS/TLS 全链路另 1 项通过（2.910 秒），上传、作者资料、头像、昵称、撤权、房间附件下载和入群审批继续通过，全部自有服务已退出；日志：`/tmp/im-resource-current-clock-live-01/client.log`、`/tmp/im-resource-current-clock-live-01/summary.json`。能力签名目录同步缩减为当前接口，静态 inventory、文档链接和差异空白检查通过。

旧目标兑换实现已删除：移除 `V2MediaUploadProviderSessionService` 及其专属测试；本地字节适配器仍使用的上传目标/提供方定义移至 `V2MediaUploadProvider.swift`。当前 `V2ResourceService.targets` 在异步边界检查取消，并在签发后的授权读取后复核当前会话期限，拒绝期间缩短的会话期限或失效计划。续签与提供方失败后的重试复用持久会话，不依赖旧 grant 的 pending/claimed/consumed 兑换状态机。

[`V2ResourceUploadTargetPostgresTests`](../../IMV2Server/Tests/IMV2ServerTests/V2ResourceUploadTargetPostgresTests.swift) 的 11 个场景通过，覆盖正常续签、提供方失败、长度/摘要/模式/期限不符、过期目标、事务授权回调撤权、真实会话取消/期限缩短和非协作式适配器中的任务取消；未取消会话的失败/重试前后持久 session 快照保持一致。原下载会话时钟集成测试已改为资源 create→claimFinalize→publish→scan→消息绑定准备媒体，不再依赖旧上传 grant 或裸媒体旁路；它在本轮自建的两个空库执行 canonical schema 初始化和完整用例并通过。连同资源 HTTP 上传/下载/复制共 3 个 test 声明 / 3 个 suite 通过（1.201 秒），三个自有测试数据库均已删除。日志：`/tmp/im-resource-target-current-server.log`。真实原生 HTTPS/TLS 全链路另 1 项通过（3.007 秒），本轮自有 Account、Actor、Gateway、图片 worker 和 PostgreSQL 均已清理；证据：`/tmp/im-resource-target-current-live-01/client.log`、`/tmp/im-resource-target-current-live-01/summary.json`。静态 inventory、80 个资源文档本地链接和差异空白检查通过。其余旧 grant/store 测试与物理表清理尚未完成。

下载响应已完成统一：[`V2MediaDownloadTargetEnvelope`](../../IMV2Core/Sources/IMV2Core/MediaReference.swift) 仅编码必需的 `plan`，构造和解码均要求完整 GET、字节数与 SHA-256；HTTP/ClientKit 不再读取旧 URL/headers 字段或选择可选 plan 回退。服务端 `V2MediaObjectProvider` 与下载服务直接返回 `V2ResourceTransferPlan`，上传暂存目标独立为 `V2MediaProviderUploadTarget`。本地适配器的下载计划也携带实际文件摘要。公共类型和静态 DTO 清单同步更新。

下载合同验证：Core 20 项 / 3 个 suite、ClientKit 相关 22 项 / 4 个 suite、Server 42 项 / 9 个 suite 通过；App 下载与文件生命周期 127 项 / 3 个 suite 通过（3.959 秒）。真实 HTTPS/TLS 测试新增房间附件上传、Actor 接受消息、HTTP 签发新下载计划、长度/摘要与实际字节校验、消息撤回后 404 拒绝新签发，完整测试通过（3.147 秒），原头像/昵称/拉黑/入群审批场景同时通过。日志：`/tmp/im-resource-download-plan-core.log`、`/tmp/im-resource-download-plan-client.log`、`/tmp/im-resource-download-plan-server-final.log`、`/tmp/im-resource-download-plan-app.log`、`/tmp/im-resource-download-plan-live-01/client.log`。这是新下载合同的真实链路证据，不替代尚待完成的全仓库旧测试重写、实际设备或万人负载验收。

本轮附加验证：资源绑定、原图/变体与分库转发共 13 个 test 声明 / 3 个 suite 通过（5.651 秒）；App 121 个 test 声明 / 4 个 suite 通过（3.709 秒）。真实原生 Account、Actor、Gateway 与图片 worker 启动后，上传、资料授权、头像字节、昵称更新和拉黑撤权链路通过（1 个 test，2.552 秒）。另一个真实 PostgreSQL 测试的 5 个参数场景，确认 Actor 和通用消息下载授权均拒绝缺失目录、错房间、错用途、过期代次及 retiring placement（0.330 秒）。日志：`/tmp/im-resource-unified-admission.log`、`/tmp/im-resource-unified-download-auth.log`、`/tmp/im-resource-unified-client-final.log`、`/tmp/im-resource-unified-live-01/client.log`。文档 77 个本地链接、静态 inventory 和差异空白检查通过。真实链路验证仍不等同于万人压测或个人资料页的设备 UI 验收。

当前新建两个 PostgreSQL 测试库，相关资源、迁移、原图/变体、头像与适配器回归 43 个 test 声明 / 9 个 suite 通过（9.769 秒），包含 18 个转发场景和群头像控制/房间分库场景。统一 schema 初始化、导出/恢复和漂移检查通过（159 表 / 373 索引 / 31 触发器 / 28 函数）。日志：`/tmp/im-resource-fresh-model-tests.log`、`/tmp/im-resource-fresh-model-schema.log`。这些验证不覆盖尚待清理的全部旧入口。

## 已接入的边界

| 边界 | 当前实现 | 限制 |
| --- | --- | --- |
| 逻辑资源 | Core 中的 home、usage、upload locator、generation、import、presentation lease、传输计划；独立资源目录及持久逻辑 VariantID | 目录不依赖上传会话；消息继续只持有 MediaID，不携带物理存储位置；完整位置迁移尚未实现 |
| 存储 | `V2ObjectStorage`、不可变 `V2StoredObjectReference`、带配置版本的 registry | 已有本地参考实现；尚无生产云适配器验收 |
| 上传 | `V2UploadTransport`、create/status/targets/finalize/cancel、可信 SHA-256、owner 路由与发布栅栏 | 当前部署只支持前台单次 PUT；multipart 与后台传输关闭 |
| 下载 | `V2ResourceDelivery`，旧附件接口通过 `V2BoundMediaProvider` 解析已核验 placement | 本地分发已接入；CDN、上层缓存与边缘撤权尚未验收 |
| 处理 | scanner/transformer 协议；独立图像子进程；固定头像尺寸与元数据移除 | 本地 EICAR 扫描器仅供参考；Linux 图像工具链尚未运行验收 |
| 导入 | 精确来源授权、source hold、独立目标副本、持久恢复、终态释放；普通转发接入封存对象和持久输出身份 | 同库和分库正确性已验证；吞吐和完整生命周期竞争仍待验收 |
| 资料 | 有上下文和期限的批量展示资料接口、控制域跨接收者合批、同房间 Actor 相邻读取合批、头像变体签发及独立版本群昵称；真实 Account → 远程房间 Actor → SQL 的读取及拉黑复核已验收 | 其余旧资料入口授权迁移、跨房间 owner 合并、其他作者上下文与端到端负载验收尚未完成，不能据此声称解决全部万人突发 |
| 作者补充通道 | protocol 32 能力协商、独立 delta 帧、Gateway 注册/订阅/退出、NIO 可丢弃写出、ClientKit 页面协调/接收/入仓，App 页面共享 activation、可见行兴趣和提前补充暂存；运行入口与关闭所有者已装配，真实 ClientKit 广播及历史补充链路通过 | 服务端默认关闭，需显式部署配置；App 前台声明支持，后台不订阅。真实 App UI 与容量验收仍待完成，仅在隔离验收进程中打开开关 |
| 群头像基础 | 独立幂等操作、owner 原子绑定/版本事件、引用 GC 保护、Actor/HTTP 读取与签名后复核；永久关闭协议、ClientKit 持久意图/恢复/显式替代；App 可见展示、管理入口与账户恢复装配 | 完整 UI/并发/生产验收仍待完成，上传 capability 继续关闭 |
| ClientKit | GRDB 上传/导入 journal、冻结 SendIntent、同事务 handoff、原 operation 恢复、能力读取；控制/journal 操作的有界准入与关闭排空 | 后台系统传输、分片、Range 仍未开放 |
| App | 会话附件准备与恢复、个人/群头像共享字节管线、可见范围展示租约、消息待确认与永久关闭后的显式重试/放弃、群头像管理页、账户级待处理群头像入口与恢复 | 完整 UI 场景、全部旧资料入口迁移仍待完成 |

存储和分发由独立协议注入。业务服务不导入云 SDK，不按域名识别运营商，不把 bucket、原生 ETag、签名 URL 放入持久消息。临时传输计划由适配器生成，再检查模式、字节数、摘要和有效期；提供方不能扩大上层给定的权限期限。

修改默认 storage binding 只影响新分配。旧上传的幂等重放先读取持久会话，再应用新会话的准入规则；新默认大小限制不能误拒绝旧会话。旧附件下载解析其精确、已核验的对象，已经不依赖上传暂存副本。会话与 placement 引用的旧后端缺失时启动失败，不回退到新默认。

资源目录保存逻辑归属、用途和 generation，上传与服务端复制使用同一目录。普通转发跨 room 时为新资源建立独立目标副本，即便两房间同库同分片；同 room 沿用精确源引用。目标身份在复制前入库，丢失响应或切换默认后端后复用该身份。下载、扫描及图片预览均无需上传会话。旧 pair 已接受结果仍重放，不因升级再次提交；只有未接受的新资源跨 room 操作选择持久导入。

源导出提交形成持久复制授权和 hold，之后源消息撤回不撤销该次导出。目标接受继续检查当前目标权限。已绑定新资源可在最初上传绑定期限之后转发；普通新发送仍遵守绑定截止。Account 与 Gateway 检查会话、placement、变体、未发布复制输出和显式导入 active hold 引用的旧后端；Gateway 的后台复制元数据查询使用投递连接池。

本地参考分发在每次缓存命中前验证能力；小图缓存限制为 32 MiB / 512 条 / 64 个回源任务。缓存身份包含完整存储引用、大小和摘要，失败回源的旧等待者不能清除新任务。大附件绕过该缓存，按最多 64 KiB 的块读取，限制 16 个打开的流，检查长度和全文摘要。下载能力最多 120 秒；输出缓存块以及等待源站读块后均检查截止时间。上述数值是当前参考实现的保护边界，不是生产吞吐承诺。

旧附件接口也可携带结构化传输计划；通用头策略不再按运营商前缀筛选。客户端拒绝互相矛盾的外层字段与计划，以及混入对象目标的业务 token，下载后验证 SHA-256 再发布本地文件。扫描和转码回执有公开构造器，外部适配器不依赖内部测试权限。

## 逻辑变体身份与导入输入快照

头像签发此前直接将物理 placement UUID 作为 `VariantID`。现改为读取 `resource_variants.variant_id`：生成衍生意图时分配独立 UUID，按配方的幂等键重放不会更换它。新导入根据逻辑 ID、所属 media 和目录的当前 generation 查找变体，原图也必须匹配当前 generation；不会把一个新对象的物理 UUID 当作逻辑 ID 的别名。客户端传输和展示合同无需改变。

`resource_import_holds` 现在同时保存精确引用、大小、SHA-256 和媒体类型。导入在目标持久完成前失败时，重试沿用该 hold 的快照，不重新选择已经迁移的当前位置。新操作才读取新位置；已经释放的 hold 不重新开放，相同操作携带不同请求仍被拒绝。active hold 的配置引用加入启动检查，避免仅因为目录不再指向旧对象就漏掉其适配器。该修复不代表已证明取消、在途 I/O、迁移和删除的全部竞争。

所有 owner 从 [canonical schema](../../IMV2/sql/schema.sql) 初始化。变体从创建时分配独立逻辑 UUID，导入 hold 的大小、摘要和媒体类型均为非空字段；不提供旧草案回填、旧服务器混跑或协调升级步骤。此前新增的四个资源/群头像/消息关闭增量脚本已经移除，约束和触发器统一保留在 canonical schema。

新增[逻辑身份与导入 PostgreSQL 测试](../../IMV2Server/Tests/IMV2ServerTests/V2ResourceLogicalIdentityPostgresTests.swift)验证两个真实本地存储中的一致副本、位置替换前后头像 ID 不变、原图/头像两种导入中断后的原位置恢复、新操作选择新位置、旧 generation 拒绝、物理 UUID 拒绝和衍生任务幂等。这一组测试中的位置切换直接修改目录，仅验证使用者的身份和恢复约束；后续迁移内核的实际调用验证见下一节。

本轮专项 3 个 test 声明 / 1 个 suite（其中导入有 2 个参数场景）通过；相关资源、上传、头像绑定/授权及适配器回归共 47 个 test 声明 / 10 个 suite 通过，使用新建的独立 PostgreSQL 测试库。该阶段曾验证旧草案回填；按未上线项目的新基线，该回填实现和用例已移除，当前仅验收统一 schema 初始化、导出/恢复及约束。本轮群头像 HTTP 的回归使用同库，未将其声称为本轮分库重验。日志：`/tmp/im-resource-identity-tests.log`、`/tmp/im-resource-identity-regression.log`、`/tmp/im-resource-identity-schema-final.log`。

真实原生 Account、Gateway 和图像 worker 构建后，ClientKit → HTTPS/TLS → 独立 Actor 进程 → PostgreSQL/头像字节的现有验收再次通过：1 项 / 1 个 suite，2.522 秒用例时间。上传、128/256 衍生、绑定、作者补充、字节摘要、热缓存伪造能力拒绝及资料撤权继续通过；自有服务和临时数据库已清理。此用例没有执行生产位置迁移，也不代表 CDN 或万人负载已验收。证据：`/tmp/im-resource-identity-live-01/client.log`、`/tmp/im-resource-identity-live-01/summary.json`。静态 inventory、文档链接及 diff 空白检查通过。

## 同 home 迁移的复制与切读内核

[迁移服务](../../IMV2Server/Sources/IMV2Server/Resources/Application/V2ResourceMigrationService.swift)与[持久存储](../../IMV2Server/Sources/IMV2Server/Resources/Infrastructure/PostgresV2ResourceMigrationStore.swift)已实现以下路径，仍使用纯 storage 协议和身份分配闭包：

1. 在资源所属数据库内校验维护权限、当前 generation、available 状态与精确源事实。按 operation ID 幂等，持久保存源引用、预分配目标、大小和 SHA-256；同一资源最多一个待复制任务，目标 binding 由维护请求明确指定。
2. 取得有期限的 claim 后离开事务执行 I/O。恢复先 inspect 已登记的目标；不存在才读取原输入并复制。回执必须完整匹配目标身份、大小和摘要，响应丢失也不重新分配对象。
3. 发布事务重新取得媒体锁并复核维护权限、claim、有效期、generation 与当前源。原图只替换 placement，变体只替换引用，业务 home、MediaID 和 VariantID 不变；状态与切读原子提交。旧 claim 完成后不能覆盖后继发布。
4. 失败保留原意图和两个引用，活跃 claim 的失败采用有界退避；进程丢失后可按过期 claim 恢复。单次恢复入口有 1～100 项上限，并向调用者返回成功/待重试的 operation ID。
5. `resource_storage_migrations` 中尚未释放的记录参与 readiness 和 GC。复制前、复制期间及切读后，整资源 GC 和直接 purge 都拒绝删除它。直接 purge 在收集引用前取得媒体锁并持久关闭新资源准入，避免检查完任务后又出现新迁移。缺失旧 binding 不能被新默认替代。

**当前仍是维护内核阶段。** 尚未装配运营入口和定时恢复；未提供旧位置释放或迁移取消 API。`switched` 只代表新副本已核验并成为读取位置，旧副本继续保留，相关资源不能回收。这是等待后续排空合同的中间状态，不能当成可上线的完整迁移/空间回收方案。剩余工作包括签发批次保护、晚签发、在途读取/处理/导入保护的统一核对、持久退役与取消清理、旧配置退休、维护审计、指标和跨 owner 公平调度。generation 或维护权限失效后的保留任务，也需要该运维恢复/关闭流程处理。

[真实 PostgreSQL 迁移测试](../../IMV2Server/Tests/IMV2ServerTests/V2ResourceMigrationPostgresTests.swift)已经覆盖原图和变体复制、幂等、目标身份冲突、源/目标配置保留、未知写入恢复、迟到任务、错误回执、权限和 generation 栅栏、回收保留及 purge 后拒绝新准入。旧位置释放和生产分发并未由这些测试证明。

## 原生真实链路验收

[`verify_v2_live_resource_authors.py`](../../scripts/verify_v2_live_resource_authors.py) 为 macOS 上的显式验收入口。它先构建当前 Account、Gateway 和独立图像 worker，再启动自己的临时 PostgreSQL、完整当前 schema、两个独立 Actor 节点、TLS Gateway 和 HTTPS Account 代理。代理只补充真实 Account 所需的受信边缘头，不替代认证、资源或资料处理器。只有一个包含两名成员的 large-class 群通过受限 fixture 写入；账户注册、上传、资料绑定、发消息和拉黑均走真实公开协议。

[`V2LiveResourceAuthorTests`](../../IMV2ClientKit/Tests/IMV2ClientKitTests/V2LiveResourceAuthorTests.swift) 使用实际 ClientKit HTTP/Network.framework TLS 适配器，依次验证：

- 上传 300×160 PNG，经过扫描和独立图像进程生成变体，等待 ready 后绑定个人资料。
- 前台群订阅收到实时消息提示及作者 delta；在消息已经广播之后结束旧 nonce、建立新 nonce，单独通过历史拉取取得新的 delta，区分两条入口。
- 通过真实昵称写入 HTTP/Actor 设置、修改及清空昵称；公开资料和 membership revision 不变时，同一 nonce 下的后续历史补充仍交付独立昵称版本。清空保留版本，随后写入非空昵称并拉黑，确认双入口不泄露该字段。
- 名称、viewer/device/context 和展示期限匹配；下载 128×128 头像并由正式下载器核验大小与 SHA-256。再次下载填热缓存后，错误 capability 仍返回 404。
- Account 的资料批量 HTTP 请求跨进程调用 Gateway 房间 Actor。真实拉黑提交后，后续历史补充和 HTTP 回退均返回不可见，不再签发新头像能力。
- 第三个账户通过真实邀请/申请接口成为待审申请者；申请分页只含申请事实与 ID。群主用审批 context 取得非成员资料，普通成员读取及普通群 context 均拒绝；申请者取消后不再签发新资料。裸 HTTP 验收调用最多重试两次明确的 429，遵守 `Retry-After`；不重试权限拒绝或把 per-item retryable 当成功。
- 精确 handle 查询返回绑定 viewer/device 的短期发现结果；对方拉黑后，后续精确查询返回统一的 not-found。成员/已读 TLS 响应只含标识与角色，关闭阅读披露后不再列出读者。

已签发能力按原短期 TTL 有效；本测试没有把“停止新签发”解释为立即撤销此前已取得的字节或链接。也没有测试 App UI、生产云/CDN、跨机器延迟、多 owner 迁移或万人吞吐。两名成员只用于授权和资源链路正确性，large-class 标记不代表实际万人负载。

运行需要 macOS、Swift/Xcode、PostgreSQL 命令行工具、OpenSSL，以及支持 TLS 1.3 的 Python；某些 Xcode 随带的旧 Python/LibreSSL 不支持 TLS 1.3，脚本会在创建环境之前明确拒绝。选择符合条件的 Python 后运行：

```sh
python3 scripts/verify_v2_live_resource_authors.py --output /tmp/im-resource-live-evidence
```

输出目录必须不存在。证书信任仅作用于测试自己的 URLSession/NWConnection，不写 Keychain；密钥、数据库和资源字节位于临时目录，脚本通过 `finally` 排空本次拥有的服务并关闭数据库。脚本不读取或修改 `.env.local`，不访问已有数据库，不更改常驻服务配置。输出保留构建/服务/测试日志，以及按端点归一化的 HTTP 计数和数据库汇总；不记录请求体、业务凭据或签名 URL。普通 ClientKit 测试没有显式环境变量时跳过这组在线用例。

## 控制域跨接收者查询与客户端退避

`V2ResourceProfilePresentationService` 的初次读取、房间授权后的复核和签名后的复核共用 [控制域批处理器](../../IMV2Server/Sources/IMV2Server/Resources/Infrastructure/V2ProfileControlBatcher.swift)。它按进程内同一控制数据库收集不同接收者；[SQL reader](../../IMV2Server/Sources/IMV2Server/Resources/Infrastructure/PostgresV2ProfileControlReader.swift) 在一条查询中逐项核对 actor/device、账户启用状态、双向拉黑、资料、关系和私聊 owner 路由。返回值按 request/key ordinal 严格拆分，某个设备被撤销不会让相邻请求获准或一起变成不可见。每次批次重新读取当前事实，不缓存跨接收者的授权决定。

一个 SQL 批次最多 100 个目标项和 64 KiB 编码输入；等待合并 3 ms，排队超过 5 ms 或待处理达到 400 项 / 256 KiB 时明确拒绝，最多 4 个实际在途查询。单次查询结果另限 256 KiB。HTTP 原有 64 个总请求、每设备 2 个请求的准入继续生效；上述限制不能当作吞吐承诺。排队取消会移除需求；在途取消或调用期限到达先结束调用者等待，但 SQL 真正结束前继续占用查询名额。服务停机先停止新准入，取消并排空查询，再等待已经进入房间授权或签名的资料读取全部离开，之后才关闭依赖。

客户端资料、群昵称与群头像 HTTP reader 使用公共 `Retry-After` 解析器，处理 429 及带等待头的 503，支持秒数和 HTTP 日期。合法长冷却不截短到 60 秒。资料 repository 将冷却期限保留在该账户/设备实例的单调时钟中，在服务端要求的等待时间基础上附加 0.1～0.5 秒随机延迟；页面重入和前后台切换不会清除该期限。取消后迟到的同账户 429 仍能限制新的前台需求。冷却期间结束尚未分发的等待，其他已发出的请求仍可返回有效资料；冷却本身不会启动后台重试，也不会被记为“作者不可见”。不同账户实例独立。

房间成员权限仍通过各自的 RoomRef 用户信封逐请求准入；[房间通道](../../IMV2Server/Sources/IMV2ActorRuntime/Scheduling/V2RoomTurnLane.swift) 将已经排队、形状合法的相邻资料读取组成同一个轮次。单轮最多 100 个目标项、默认最多 64 个信封；合并后的请求字节受 64 KiB 与通道配置的较小值限制。发送、其他查询/写入和 reservation 都是屏障，两类批次不能混合。这里不新增收集等待，不保证低负载下的单独请求也能合并；排队和实际执行仍占用原有房间/宿主预算。

[真实执行器](../../IMV2Server/Sources/IMV2Server/RoomCoordination/MediaAuthorization/V2RoomMediaAuthorizationDomainExecutor.swift) 在 activation 围栏事务内，使用一条集合查询逐项读取接收者、目标成员、房间类型、当前 membership revision 和获准群目标的昵称行；activation 校验及事务本身仍有数据库开销。各项使用同一语句观察时间，按 request/target ordinal 拆分，各自返回绑定原请求的证明或不可见结果；不会把某个用户的权限转给同批其他用户，也不缓存跨接收者的授权决定。SQL 输入另限 64 KiB，SQL 编码结果和返回证明分别限 256 KiB。整个轮次只申请一次 `interactiveRead` 数据库准入，使用最早调用截止；调用者取消后，实际查询结束前继续持有轮次和额度。

上述实现覆盖同一热房间中的不同接收者。本机独立进程间的真实 Actor TLS 资料读取已通过上述验收；不同房间之间的物理 owner 合并、指标导出、跨机器 Actor 网络及 owner 迁移场景和端到端突发负载仍待验收，不能据此声称完成全部多权威查询链路的生产容量验收。

## 群昵称的授权读取与展示

`V2AuthorizedProfilePresentation.groupMember` 携带同一房间、同一目标的可选 `V2GroupMemberPresentation`，其中 nickname revision 独立于公开资料版本和 membership revision。它受同一 actor/device/context 展示 lease 约束；Core 构造与解码都会复核房间、目标、active 状态及规范化昵称。私聊、关系上下文、非活动资料不能附带群昵称。没有昵称行用 nil；清空既有昵称继续交付带新 revision 的行，不能把清空降为“从未设置”。

房间 Actor 的现有跨接收者集合查询同时读取昵称，仍只处理已准入的至多 100 个目标项，不枚举完整群名册。离群目标、无权观察者和私聊请求不取得昵称。端口拒绝重复主体、其他房间/目标和不规范内容；控制域继续检查账户、设备、双向拉黑及资料状态。头像签名之后再读取房间事实，昵称新增、修改或清空都会使旧证明不匹配并返回 retryable，因此存储或分发调用挂起时不会把旧昵称当作未发生变化的资料交付。

作者压缩提示包含昵称内容及其独立版本，公开资料不变也能交付更新。ClientKit 仓库按完整 context 保留昵称版本下界，同版本不同内容、版本倒退或把已存在的行降为 nil 都不能覆盖已接受结果；隐藏资料不会抹掉这个下界。昵称内容变化通知已持有该 key 的可见行，旋转下载 URL 不触发全页重取。App 的共享头像管线优先展示已授权群昵称，清空后使用公开名称；异步图片读取/解码前后比较同一昵称事实，避免新旧名称与图片混用。

### 群昵称持久失效事件

[`PostgresV2ProfilePresentationStore`](../../IMV2Server/Sources/IMV2Server/PostgresV2ProfilePresentationStore.swift) 在同一个 owner activation 围栏事务内写入昵称、幂等回执和 `group.nickname_changed`。事件仅含 `event_type`、`room_id`、`target_user_id`、`revision`、`room_sequence`、`server_created_at_ms`，不含昵称正文、头像或下载能力。当前房间日志允许其成员知道发起者 ID；若后续产品要求隐藏该身份，须改成不泄露主体的范围失效合同。

事务持有房间序号锁，复用群命令准入和 shard 额度；额度不足或事件失败时全部回滚。变更只追加一条 room event，不写每个成员的 user-sync 事件。相同 operation 重放先取原回执；新 operation 提交相同内容会保留回执但不新增版本、事件或额度扣减。普通群的 Account HTTP 写入同时写合并 wake outbox，大群沿用事件触发器；pending wake 合并，已认领 wake 被新版本替代，worker 读取当前房间水位。这里不保证端到端通知延迟，广播/拉取仍需要在线订阅和实际 worker 部署。

[`GRDBV2GroupNicknameInvalidations`](../../IMV2ClientKit/Sources/IMV2ClientKit/GRDBV2GroupNicknameInvalidations.swift) 将事件回执和每个 `(room, user)` 的最新版本下界与日志游标原子落盘；冲突身份、同版本不同事实、序号倒退和含正文的事件都拒绝推进。重新打开数据库不会丢失下界；个人快照只为仍授权房间保留已经处理的房间事实，退群清除对应状态。新增 SQLite 迁移也安装未完成快照的 shadow/retired 表，房间高水位查询使用索引，不逐次扫描整群昵称。

App 订阅独立 `.groupNicknames` 投影变化。仓库只集合读取当前有界跟踪 key（最多 2,000 个状态及 64 个提前候选），只通知旧昵称版本的对应作者/context，不清空其他群或关系上下文。通知允许合并；缓存出仓、HTTP 完成和作者 delta 入仓都会再次读取下界，遗漏一条通知不能放行旧内容。昵称内容失效不撤销当前 author nonce，满足新下界且通过原授权规则的补充可以直接恢复；权限拒绝的 nonce 栅栏仍独立生效。头像不可变身份未变时复用经核验的字节，不因昵称变化生成新的资源。

### 群昵称分页授权迁移

`GET /v2/profile-presentations/groups/:room/nicknames` 已复用统一资料授权服务，响应改为 [`V2GroupNicknamePresentationPageResponse`](../../IMV2Core/Sources/IMV2Core/GroupNicknamePresentationPage.swift)：`roomID`、`batch` 和 `nextCursor`。每项是绑定当前 viewer/device/room 的限期展示、不可见或临时失败，已取消直接返回裸 `nicknames` 数组的路径。未装配授权服务时返回 503，不回退旧读取；App 内没有旧分页调用，聊天可见作者继续走显式 key 的批量接口。这是当前未提交版本的协调升级，不承诺旧响应格式兼容。

#### 联系人备注与本人群昵称编辑恢复

本轮 W3 采用 [联系人备注合同](../../IMV2Core/Sources/IMV2Core/ContactAliasOperation.swift) 和 [本人群昵称合同](../../IMV2Core/Sources/IMV2Core/GroupNicknameOperation.swift)。`V2ContactAliasUpdateCommand` 绑定 owner/target/operationID、可选 expectedRevision、remarkName 与首次提交期限；`V2GroupNicknameUpdateCommand` 绑定 actor/room/operationID、可选 expectedRevision、nickname 与首次提交期限。指纹由这些规范化字段确定编码，禁止 self alias。nil revision 表示从未有字段记录，nil name 表示清空；每个新 committed 操作递增版本，包括首次清空与值不变，重放返回原版本。

`GET`、`PUT /v2/profile-presentations/contact-aliases/:target` 分别返回 `V2ContactAliasSnapshot` 和 `V2ContactAliasUpdateReceipt`；`GET`、`PUT /v2/profile-presentations/groups/:room/nickname` 分别返回 `V2GroupNicknameSnapshot` 和 `V2GroupNicknameUpdateReceipt`。GET 只给当前关系/群成员授权下的单字段编辑基线，明确 nil 未设置，不授予目标公开资料展示 lease。PUT 请求与响应采用对应 Core Codable 合同，owner/actor 来自认证并必须匹配请求。客户端先读取基线、编辑、冻结意图，再提交；冲突由用户重新应用，不自动更换基线。

两个 PUT 路径追加 `/operations/recover` 后使用 POST，接受各自 RecoveryRequest 的 `.query` 或 `.closeIfAbsent`。恢复响应区分 original receipt、unresolved 和 fingerprintConflict。新提交和关闭共用 actor/domain/operation 锁；永久终态为 committed、rejected 或 closed，拒绝区分版本冲突、权限/实体失败与首次期限已过。`contact_alias_operation_receipts` 与 `group_nickname_operation_receipts` 通过不可变触发器禁止 UPDATE/DELETE，旧操作 ledger 及 housekeeping 清理路径已删除。群昵称提交、恢复和基线读继续经过 RoomRef owner activation 围栏，没有全局写入旁路。HTTP 限制请求体为 4 KiB、响应 no-store；恢复沿用账号持久限流。

群昵称沿用内容为空的 `group.nickname_changed` 房间事件。联系人备注首次 committed 同事务写入 `contact_alias` 用户状态事件，载荷只包含 `target_user_id` 与 `revision`；原回执重放不重复写事件。用户快照按目标保留最高 revision，支持倒序投递和重建；客户端由该失效版本撤回旧展示并重新授权读取，事件和编辑 snapshot 都不包含公开资料 lease。本轮仅为这两个领域的实现范围，不代表所有应用级弱网写领域完成。当前统一新建库合同为 `im-v2-current-56`，协调协议版本为 34。授权展示新增 recipient-bound `contactAlias: V2ContactAlias?`，owner 必须等于 lease.actor、target 必须等于 view.user；清空行仍携带正 revision。HTTP batch 与 TCP 作者增量复用同一授权组装，现有 `AuthorPresentationDelta.payload` 直接编码强类型 Core JSON，因此该字段自然随该 recipient 的增量交付，不另建重复 protobuf sidecar。


房间 Actor 的旧查询只提供分页候选，候选昵称正文不会复制到 HTTP 响应。服务随后复用控制域的设备/账户/双向拉黑检查与房间当前成员、昵称版本证明，并在返回前复核。每页默认和最大值均为 100；扫描、授权与最终校验共用一次节点/设备准入和原 10 秒截止，非协作式扫描取消后仍占用名额，关闭等待实际退出。空页也复核设备。分页不签发头像下载能力，不提前为整页图片占用供应商或边缘资源。

游标按本次扫描的 UUID 顺序前进，包含被拒绝或暂时失败的项；不为填满“可显示昵称数”而循环扫描更多成员。调用方可能取得没有可显示内容但仍有下一游标的页，retryable 不能记成永久不可见。这是当前成员的分页读取，不是跨多个页面保持一致的名册快照。当前群成员 ID 的披露政策沿用房间日志；若未来需要隐藏主体身份，需同步修改候选/游标合同。

[`V2HTTPGroupNicknamePresentationClient`](../../IMV2ClientKit/Sources/IMV2ClientKit/V2HTTPGroupNicknamePresentationClient.swift) 校验房间、接收账户、设备、大小、顺序及游标进展，只返回内存页。展示截止从 HTTP 发起时的单调时钟计算，包含凭据获取和往返耗时，过期项只标记 retryable；页的 `snapshot(for:)` 在过期后返回 nil。消费者仍必须持有当前账户/页面 activation 并处理权限失效，不能把目录页持久化成全局资料。实际聊天页面不依赖名册分页，后续成员搜索 UI 仍在剩余范围内。其他旧资料入口不能直接当作这份 lease 使用；真实 App 静默页面、远程 wake broker 和万人突发延迟仍待验收。

## 作者资料补充的组件与接线要求

实时正文已有共享编码帧，逐接收者的展示许可和头像能力不能混入该共享内容。[`V2AuthorPresentationDelta`](../../IMV2Core/Sources/IMV2Core/AuthorPresentationDelta.swift) 使用独立的连接 stream ID、前台 view nonce、单调 sequence、actor/device/room，以及现有资料证明与临时头像能力。一个载荷最多 16 项、32 KiB 编码 JSON；retryable 必须携带 100～60,000 ms 的退避，不能伪装为不可见。它不进入消息日志、message hash、持久投影或 journal。两端同时执行 33 KiB 完整未压缩帧上限（含 protobuf envelope 与 18 字节帧头），并受连接配置的更小预算限制；分发器每个输出额外预留 1 KiB 封装开销。

[`V2AuthorPresentationDispatcher`](../../IMV2Server/Sources/IMV2Server/Resources/Application/V2AuthorPresentationDispatcher.swift) 提供可独立验证的任务所有权边界。调用方先完成认证、能力协商和正常房间订阅授权，再注册连接、激活 view；只从已向该接收者授权的消息提取作者并调用 `offer`。`offer` 不等待权威查询或网络写出。默认节点待处理 1,024 项 / 256 KiB，每连接 128 项；最多 4 个实际查询、4 个实际写出，每连接同一时刻只有一个资料任务。查询合并等待 2 ms，整个补充任务期限 500 ms；单批只含一个房间的最多 16 个作者。输出及其待提交压缩提示合计限 256 KiB，输出接近上限时停止启动新的可选查询。这些值是组件保护边界，不是实际网络或生产延迟承诺。

资料内容版本提示只在传输回调确认入队后保存，按连接/完整 context 保留最多 128 项，节点提示总预算 2 MiB。每次选中的 key 仍重新调用授权 reader，之后才决定是否省略相同版本的字节；权限拒绝仍发送并清除旧提示。去重期限再扣除客户端可能消耗的整个 30 秒 view 计时窗口，短于该窗口的能力不建立去重提示，避免省略客户端已经不能使用的资料。断线、离页、重新进入同房间和超时会取消旧任务；非协作式依赖真正结束前仍占用查询或写出名额，重复关闭共同等待排空。[`V2AuthorPresentationTransport`](../../IMV2Server/Sources/IMV2Server/Resources/Application/V2AuthorPresentationTransport.swift) 在实际 NIO 入队时以同一互斥门复核连接/页面代次、任务及 view 截止、认证期限和单次消费。取消会使尚未使用的写入许可失效；字节超出完整帧上限不能创建许可。NIO writer 在连接不可写、已有命令处理/待写响应时丢弃可选补充，不增加重试队列，也不因为可选资料拥塞关闭健康连接。写入成功仅说明本地入队。

[`V2AuthorPresentationReceiver`](../../IMV2ClientKit/Sources/IMV2ClientKit/V2AuthorPresentationReceiver.swift) 每个账户/设备独立，当前仅持有一个前台 view。客户端在发出订阅前生成随机 nonce；服务端必须在该 nonce 对应的已授权订阅之后执行资料读取并回传 nonce。接收器从 `validUntil - serverNow` 中保守扣除“订阅开始到接收”的全部单调耗时，包括服务器队列和网络停滞，避免把迟到的推送变成一份新的完整 lease。头像能力与名称展示分别计算期限，过期头像可被丢弃而保留尚有效的名称。view 的接收窗口为 30 秒；实际接线必须在此前有界、带抖动地更新 nonce，或在过期后回退 HTTP 重授权。仅凭一条 unsolicited 消息中的服务器时间，不能推断网络耗时。

当前 protocol 32 为 `ClientHello` 提供显式 opt-in；服务端只有部署依赖已经组装且客户端请求该能力时才生成新的 stream ID，并在认证应答中完整回显。客户端拒绝未请求的 stream、非法 UUID 与认证回显不一致。`GroupEventSubscribe/Subscribed` 携带并回显 view nonce，正常房间授权通过且应答完成写出后才激活分发器。服务端拒绝客户端发来的 delta 命令，以及未协商能力时携带的 nonce。仓库遵守仅当前协议政策：两端需要同步更新至 32，不提供 protocol 31 及更早版本的混合部署承诺；在 32 内未 opt-in 的连接仍走原订阅路径。

[`V2AuthorPresentationInbox`](../../IMV2ClientKit/Sources/IMV2ClientKit/V2AuthorPresentationInbox.swift) 由 TLS 连接拥有，最多保留 8 帧 / 64 KiB 原始载荷预算。接收器与它共用同步校验状态，在恢复订阅调用者之前安装 nonce，支持订阅应答与 delta 同批到达；解析过程不因跨 actor 等待而让生命周期穿插。过载丢弃旧补充、保留后续资料；它不是可靠消息队列，缺失仍需按可见需求回退重授权。取消订阅请求、替换页面、取消订阅和断开都会清理对应缓冲/等待者；旧应答和旧页清理不能恢复或关闭新页。收到旧 nonce 的补充只丢弃；错账户/设备/stream、超出字节预算则关闭对应连接。出队保留原始单调期限，消费者仍须在展示/下载时重查。

资料仓库和 App 页面已提供绑定页面的 ingest、HTTP 顺序栅栏、共享 activation 与可见行消费，详见下面各节。群广播的正文后有界作者观察入口已接入注册表；`GatewayTransportAssembly` 现已接入实际授权 reader 和 ingress/分发器所有者。App 前台连接显式声明支持，后台连接不请求该能力；通用 `V2TLSFrameConnection` 的默认值仍为关闭。服务端仅在显式开启部署配置并完成装配后协商。正文同步共享帧热路径不为每个接收者创建 Task 或等待资源查询。该通道目前使用 `.room` 群上下文，已增加活动页面的 `GroupEventPull` 响应补充及独立版本群昵称；私聊已接入正确上下文的共享页面 HTTP，主动作者补充、其余旧资料入口、其他历史/个人同步入口仍需补齐。NIO 通道与受控字节连接的测试不替代真实万人网络负载、ACK 延迟隔离或完整 App 验收。

App 的实际房间订阅由 `V2RoomSubscriptionCoordinator` 和页面内的 `V2ScopedActiveRoomSynchronizer` 管理，不能只在旧的 `V2RealtimeActiveHybridGroupSynchronizer.subscribe` 上加 nonce。两端现在仅在同房间的普通无 nonce 订阅时清理作者 view，其他房间的订阅/退出保留当前作者通道。ClientKit 的页面所有者已接上述实际协调器；App 群聊天页面共用一个显式的可见页面 activation，每行持有成对的兴趣令牌，其他资料入口仍使用独立 activation。兴趣和拒绝记录淘汰时保留旧 nonce 的拒绝栅栏，不能因滚动离屏再回来而恢复被拒绝的资料。

## 正文投递与作者提示的有界交接

[`V2AuthorPresentationIngress`](../../IMV2Server/Sources/IMV2Server/Resources/Application/V2AuthorPresentationIngress.swift) 是同步广播路径到资料分发器的独立交接所有者。构造时只创建一个实际消费者 Task，唤醒流最多缓存一个空信号；每个接收者只执行同步有界入队，不建立 Task、不等待资料或数据库。默认最多保留 256 个 offer、1,024 个作者 key、256 KiB 准入计费字节；固定身份每项计 128 字节，每个 UUID 作者计 64 字节，额外分配器/对象开销由项数共同约束，不把计费字节宣称为精确进程内存。正在执行的一个消费者仍占上述名额，真正返回之前不会因为取消而释放。

相同 connection/room/view 的排队提示合并去重，单项最多 128 个作者；合并不延长最初 500 ms 截止。分发器接收精确 view 和原截止，旧页提示不能变成新页需求，排队也不能获得新的一整段任务期限。关闭先停止准入、清除排队提示，再取消并等待实际消费者；重复关闭等待同一实际任务。组合根已安装运行所有者，依次排空 ingress、dispatcher、授权 reader，再关闭 Actor 和数据库；服务端是否启用仍由下述部署开关控制。

`V2DeviceConnectionRegistry` 的同步群微批及兼容群广播入口已连接该交接。只有注入 ingress 时才解析作者，单批最多检查 128 个事件、64 KiB JSON；只接受 room/sequence 与已提交事件一致的 `message.accepted` 作者 UUID，不读取昵称或头像，不持久化展示授权。受众仍由原有订阅与提交成员版本匹配选出；正文共享帧先提交，之后才向这些连接的当前 view 发出提示。未协商、已离页或房间不同的连接不会入队。广播入口沿用既有大群纯文本快速事件的覆盖范围；附件、引用与历史消息的 `message.accepted` 可通过下面的已授权日志响应入口补充，私聊仍需补齐；昵称变更通过独立房间失效事件更新版本下界。

实际 NIO 可选作者 writer 在同一 EventLoop 写出前检查命令/响应、可写性和正文 FIFO 积压；正文仍在排队时直接丢弃补充。正文 drain 在该循环同步执行，不会在弹出正文和写出之间被作者字节穿插。作者队列满、失效或关闭不改变正文广播的返回结果；缺失补充按可见需求回退批量 HTTP。队列只提供资源边界，不保证一万接收者都取得补充，也不替代跨接收者 SQL 合批、CDN/shield 和真实负载验收。

## 作者通道的部署装配与关闭

[`GatewayAuthorPresentationAssembly`](../../IMV2Server/Sources/IMV2ServerApp/GatewayAuthorPresentationAssembly.swift) 在应用装配层接收 `any V2ResourceDelivery`，以真实 `V2ResourceProfilePresentationService` 和 Actor directory 处理每个已认证接收者。当前本地工厂使用与 Account 字节端点一致的 base URL、签名密钥和版本化 storage registry，并检查旧 binding 是否齐全；这些本地配置不进入通用接口。接入另一运营商时替换适配器工厂及配置，作者运行时、消息协议和客户端页面不随之修改。当前尚无生产云/CDN 适配器。

`IM_V2_AUTHOR_PRESENTATIONS_ENABLED` 默认 `false`，只接受显式布尔值。当前参考部署开启时必须具备本地媒体配置，否则启动失败；只有完成 runtime 装配的 session 才协商作者能力。Compose 为 Gateway 传递该变量，真实链路脚本仅为自己启动的 Gateway 打开开关，没有修改实际 `.env.local`。控制域查询使用配置的 delivery 数据库句柄；仅当 workload pool isolation 开启时，它才与前台连接池物理隔离，不能仅凭句柄名称声称 ACK 已获得容量隔离。真实链路脚本打开物理连接池隔离，但其轻载功能验收不证明拥塞下的 ACK 隔离效果。

注册表仅允许在首次连接注册尝试之前安装一次开放的 ingress，不能在认证连接已经运行后热替换。dispatcher 的可选连接名额用尽时仍允许正常聊天认证、订阅与心跳，该连接依靠可见资料的批量 HTTP 回退，不因头像补充容量不足断开。回退仍受原有请求准入、合批与退避约束；节点容量及公平性需要负载验收。

[`V2AuthorPresentationRuntime`](../../IMV2Server/Sources/IMV2Server/Resources/Application/V2AuthorPresentationRuntime.swift) 持有完整依赖关闭顺序。正常停机、运行失败和装配中途失败均先等待 ingress 实际消费结束，再等待 dispatcher 的实际读取/写出结束，最后关闭 reader；并发关闭和已取消的关闭调用共同等待同一个任务。TLS、Actor 和数据库不能提前销毁。装配已构造 TLS 后若后续启动步骤失败，也会关闭该 TLS 实例。超过配置的 shutdown grace 后进程以失败状态退出，避免继续释放仍被使用的依赖。这些生命周期保证不等同于真实部署的端到端验收。

## 日志拉取后的附件与历史作者补充

普通 `GroupEventPage` 与预编码缓存页面都可在原响应 writer 成功返回后交给作者 ingress。连接在调用领域 handler 之前捕获当前作者 view，响应写出后再检查同一 room/view、能力和连接状态。页面读取或写出期间更换 view、未协商、未选中页面、返回权限错误、房间不匹配或写出失败，都不启动资料读取。随后仍通过现有 reader 按当前接收者重新授权；读到历史消息不等于历史作者现在仍允许展示。

每次只保留实际响应开头至多 16 条事件、64 KiB 载荷引用，从中提取至多 8 个不同作者。JSON 只在响应写出后解析；`message.accepted` 的 room/sequence 与事件必须匹配，其他事件类型不推断作者。媒体、引用、提及等字段不妨碍提取作者，也不会被重写。该限额只是服务器未知可见窗口时的有限候选，不为整页 80 个作者预签名或下载；未覆盖作者仍按可见需求批量 HTTP 获取。

预编码路径从本次通过成员栅栏、按帧预算裁剪后的精确事件区间保留样本，继续返回共享的原编码帧，不为提取作者反向解码整帧或把每个接收者的展示许可放入共享缓存。没有活动 view 时不取样。初次打开页面若日志拉取先于作者 nonce 激活，仍走正常 HTTP 回退；该补充允许丢失，不改变同步游标和持久恢复语义。只有此入口覆盖的已接受事件获得上述补充，其他历史查询、编辑事件及个人同步还需逐入口接入与验收。

## 作者页面与房间订阅的协调

[`V2AuthorPresentationPageCoordinator`](../../IMV2ClientKit/Sources/IMV2ClientKit/V2AuthorPresentationPageCoordinator.swift) 是账户级的单消费者所有者。最近选择的前台页面替换上一个页面；调用方先创建资料 activation，再运行该页面，并在离页/后台取消后等待清理，最后结束 activation。它通过现有房间协调器取得独立 `.roomEvents` 意图，等待正常订阅确认；其他场景持有的房间意图不会被页面替换或关闭释放。

正常订阅、作者 nonce 订阅和接收均绑定相同连接代次。每个房间另有本地订阅/权限代次；成员变化、服务端拒绝、重新订阅或权限重审会改变它。快照缓冲只保留最新项时，即使中间的 revoked 状态已被覆盖，同连接恢复后的 subscribed 也不等于此前的授权。页面替换/重连/权限代次改变先取消并等待旧实际任务，再启动新任务；每次 await 后和资料 ingest 前检查当前作用域，仓库也拒绝已取消任务的入仓。作者专用代次与提前失效通知只发给显式作者消费者，普通聊天同步保持原有快照和恢复顺序。

正常情况下在 30 秒 view 截止前 4～6 秒随机续订，只保留一个实际作者任务、一个接收者和一个续期计时器。正常续期保留仍有效的页面 grant，由替代 binding 重新关联，不主动重拉 HTTP 或头像。接收队列继续沿用 8 帧/64 KiB 预算。未协商能力的连接只尝试一次，等待新连接后再判断；普通可重试错误退避，服务端 `Retry-After` 形成不短于其要求、附加小幅抖动的账户冷却。即使原请求取消后才返回限流，后来的页面和重连仍遵守冷却。

离页、后台、换页或权限代次变化先撤销当前 binding 的展示 grant 和暂存补充，再等待实际任务。非协作式订阅或接收真正结束前，下一页面不能取得名额；可重复的 `suspend()`、永久 `close()` 及并发重复关闭等待实际排空。服务端明确拒绝作者订阅时，房间协调器撤销该房间的共享订阅状态，等待后续权限重审。普通资料失败不关闭健康的实时连接。

该组件已用实际 `V2ProtobufSyncTransport`、`V2TLSFrameConnection`、房间协调器和资料仓库验证“普通订阅 → nonce 订阅 → 同次字节读取中的应答和 delta → 入仓”。测试字节对端仍是受控替身，不代表远程服务与 App 完整端到端验收。protocol 32 的 `AuthorPresentationEnd/Ended`（命令 122/123）携带 stream、room、view 三个身份。Session 验证已协商 stream 和 UUID，清理仅作用于当前连接的精确 view，不调用领域授权、不取消房间订阅；过期/重复 view 返回原身份回执，不能清除替代页面。退出消耗正常帧及在途请求预算，不消耗业务命令限流令牌，避免撤权或业务限流时阻止廉价清理。ByteStream 在回执写出之前撤销旧 view 的实际入队许可；已经在执行的查询/写出仍占名额直到真正返回。

页面先清除本地 inbox，再由唯一的实际 worker 创建并等待一个不继承取消状态的清理任务；它继承原连接 TaskLocal，后续页面、`suspend` 与并发 `close` 等待它排空。TLS 对退出先等待同 nonce 尚未结束的订阅 socket 写入，再复核连接代次，防止被取消的旧订阅在退出之后到达服务端。退出回执必须回显全部身份；传输失败不在页面中循环重试，使用现有连接请求的超时/关闭语义，服务端 view 仍有 30 秒期限。当前正常续期也先结束旧 nonce，再发新订阅，保留仍有效的页面 grant；按 24～26 秒续期估算，一万实际可见页面约产生每秒 770～835 条订阅/退出控制命令（退出不触发数据库），不是一万在线用户必然同时产生该流量，也不是已验证容量。生产压测必须计入这项固定开销。

## 客户端资料仓库与可见像素的顺序

[`V2ProfilePresentationRepository`](../../IMV2ClientKit/Sources/IMV2ClientKit/V2ProfilePresentationRepository.swift) 将页面兴趣、已授予的展示访问、等待者需求和实际 HTTP 批次分开保存。最多 256 个 activation、每个 activation 256 个兴趣键、合计 2,000 个跟踪键、256 个待处理键、512 个等待者；内容与能力缓存限制 2 MiB / 2,000 项。HTTP 沿用 32 ms 合并、单批 100 键/最多 8 个房间或私聊目标、最多 2 个实际请求。它们是客户端内存与并发边界，不是服务端容量结论。

`activateVisiblePage` 单独标识共享页面。可见行使用 `retainVisibleInterest` / `releaseVisibleInterest`，全仓最多 512 个行令牌；重复释放旧令牌不影响替代行，只有同 key 的最后一行离开才取消其等待并移除兴趣。该类页面禁止未借用的读取。仍有效的 grant 可以在本页离屏后保留于有界缓存，但没有可见兴趣就不能取得展示快照；超过容量时淘汰未被当前可见行引用的 grant。因此长时间滚动不会被最初访问的 256 个作者永久占满，重新进入页面仍需新的授权。

每个批次冻结原 demand ID、完整 context 的状态身份和发起时已有的 activation。最后一个等待者离开后取消无用批次，但非协作式 I/O 真正返回前保留名额；重入的新需求不能被旧响应完成。请求发出之后才加入的新 activation 同样需要后续权威读取。失效按完整 key 更新状态身份，A context 的失效不拒绝同一 HTTP 批次的 B context。`close()` 永久停止准入并等待所有实际请求结束，重复关闭等待同一批任务；普通前后台切换只结束当前 activation。迟到 429 继续约束该账户/设备，并结束被旧请求挡住、尚未真正发出的替代需求。

`bindAuthorView` 要求页面先激活、之后创建该连接的随机 nonce，绑定仅对应一个前台页面；`ingest` 保持原接收时计算的展示和头像单调期限，不在入仓或出仓时续期。已登记兴趣的资料直接授予本页；对于显式可见页面，尚未出现的作者最多暂存 64 项 / 256 KiB，可消费期限最多 5 秒，并取原展示期限与 view 期限的更早值。仅同一页面和 binding 的可见行可消费这些候选，不提前下载图片、不建立后台 HTTP 任务；续订、退出和失效清理暂存。超过条数/字节上限时淘汰最早到期项；丢弃的是优化机会，后续正常批量 HTTP 仍可补齐。

明确不可见和暂时 retryable 保留不同语义。拒绝候选或其状态被淘汰时，保留一个单调时间栅栏，必要时让整份旧 nonce 的后续正向资料等待新 nonce 或 HTTP 重授权，避免遗忘 key 后复活权限。这一保守策略可能增加少量 HTTP 回退。推送可以满足该页面的 HTTP 等待，但不会释放 HTTP 并发名额；旧成功不能覆盖已接受的 delta。profile、visibility、context revision 和观察时间分别保持不倒退。完整批次先验证接收者、context、身份与期限，再改变展示或暂存状态。

同一仍存活页面的重叠 HTTP 查询若迟到返回明确不可见，采取保守拒绝：立即清除展示并记录本地拒绝时间。此前已创建的 nonce 不能重新授予该 key；必须用拒绝之后新建的 nonce 重新授权，或由后续正常 HTTP 获得新许可。临时 retryable 仅形成最多 60 秒的 key 退避，不改成 negative cache、不清除另一 context 的合法访问；新的有效补充可解除该退避。该策略可能暂时隐藏已更新的资料，不承诺跨多个权威的线性一致瞬时撤权。

`cachedSnapshot` 原子返回当前资料、展示截止与独立头像能力截止。HTTP 路径也扣除整个往返耗时，过期字节能力不延长或清除仍有效的名称 lease。每个 activation 最多一个 `.bufferingNewest(1)` 失效订阅；内容/权限上下文改变、拒绝或展示期限缩短会通知现有消费者。相同内容的签名 URL 轮换或 lease 延长不会导致可见行相互触发 HTTP 刷新。

App 的 [`V2AuthorPresentationPageScope`](../../IMApp/IMApp/V2/V2AuthorPresentationPageScope.swift) 已接入群和私聊页面、实时运行时工厂和账户的 `V2AvatarPipeline`。页面负责激活和资料观察，标题及可见行只借用同页兴趣；不同房间、独立资料入口与新页面不能复用该页证明。仓库通知合并后，页面读取完整的可见 key 失效版本快照，分别刷新受影响行。多个前台页面保留各自 HTTP 展示能力，最近选择的一个群页面持有可选作者通道；私聊尚未接入该群订阅协议。

### 私聊作者权限上下文

消息投影只提供真实 sender ID，不再对所有消息预先填入 `.room` 群权限。详情 store 根据已知会话种类和对端身份选择查询：群消息和私聊消息作者均使用 `.room(roomID)`，私聊另在本地要求作者为已知对端或当前账户本人。房间所属 Actor 核验实际类型和成员关系，不通过自己与自己的私聊 pair 授权本人。选择不依赖气泡的 `isOutgoing` 布局标记；未知会话、缺失或不匹配的对端、非该私聊两端的作者不生成展示请求。

私聊 scope 的身份包含房间、当前账户和对端，只接受对端私聊 key 与本人资料 key。标题和同作者重复消息借用同一个页面 activation；页面退出、重入、失效和迟到图片解码沿用群页面的隔离规则。私聊只走现有统一批量 HTTP，不误开群作者订阅，也不把内容缓存当作新页面的授权。

空私聊投影补齐对端查询 key；新建私聊在列表同步前保留同一查询身份，使首次进入也走限期展示。对端身份只用于定位请求，不能凭缓存文案放行；会话列表缺少资料 key 时显示通用占位，不回退展示旧私聊昵称。搜索筛选、转发选择器和收藏的名称已按下一节迁移；私聊主动作者补充通道已接入；其他旧入口仍需收敛，真实 App UI 全链路按本阶段要求暂不验证。

### 搜索、收藏与目标选择器的名称

ClientKit 的 `conversationLookupContexts` 在一个 SQLite 读取快照内最多处理 100 个房间，通过三次集合查询读取群标题或私聊对端 ID；不读取、返回私聊缓存昵称及头像。查询结果只是下一次授权的路由事实，不授予展示权限。App 的 [`V2ConversationLabel`](../../IMApp/IMApp/V2/V2ConversationLabel.swift) 区分群标题、完整个人资料查询 key 与未知占位；收藏、转发和附件复制目标不再把私聊名称存为普通标题字符串。

搜索筛选依据选中消息的原房间选择作者 context，房间内搜索固定使用当前房间。群和私聊作者都使用原房间的 `.room`，私聊只接受已知对端与本人；未知房间和不匹配主体不猜测关系。筛选代次隔离迟到的本地查询，包括 A→B→A 的重新选择与清除操作。名称和 VoiceOver 标签都由限期展示组件产生，不再读 `profileView` 缓存字符串。

[`V2AuthorizedProfileNameView`](../../IMApp/IMApp/V2/V2AvatarPipeline.swift) 与头像视图共用权限、失效、前后台及账户关闭逻辑；纯名称路径不下载或解码图片。当前统一资料 HTTP 仍可能返回头像能力，名称组件忽略这些字节计划，本轮没有增加省略签名的请求字段。展示快照绑定完整资料 key，视图切换主体/上下文时立即拒绝旧值，无需等待异步 task 清空状态。名称允许两行，并保留现有选择控件的 identifier、按钮语义和选中状态。

搜索、收藏、转发和附件复制选择页各自拥有独立的 list activation，不继承被模态页遮挡的聊天页面权限；同页重复目标合并读取。每个 key 仍独立授权，列表不能跨 viewer/context 共用访问决定，也不会打开群作者推送订阅。附件复制改为可持续更新名称的目标选择页，保存操作由页面 task 持有；缺少持久复制服务时明确失败，不把可选调用未执行解释为成功。已有导入、journal 与原操作恢复合同保持有效。

其余资料入口、成员搜索及全流程 UI/VoiceOver 验收尚未完成，不能把这些界面的迁移解释为所有缓存入口均已关闭。旧资料补全路径的迁移见下一节。

`V2AvatarPipeline` 与 `V2AuthorizedAvatarView` 消费上述快照。行退出、后台与账号关闭立即隐藏受保护像素；下载/解码结束后再核对页面、activation、账户代次、原始资料与 context revision、不可变头像身份，并取新旧展示截止的较早值。渲染和辅助功能名称也检查当前期限。行按失效或展示截止刷新，不再每秒重复查仓库/图片；服务端退避按实际剩余时间等待。账户暂停/关闭先停作者所有者，再结束仓库 activation；生产 opt-in 仍关闭，不能将本地页面/管线与受控字节对端测试解释为生产作者分发已经启用。

### 联系人补全与旧资料端点退休

实时运行时与 App 的头像/名称管线现在共享同一个 `V2ProfilePresentationRepository`。[`V2ProfileProjectionReader`](../../IMV2ClientKit/Sources/IMV2ClientKit/V2ProfileProjectionReader.swift) 把联系人补全与个人同步后的失效刷新接入该仓库：每次最多 100 个去重 key，后台内容补全使用 prefetch 优先级，与可见行共用最多 2 个实际 HTTP 请求、每批 100 项及去重 room/私聊目标合计 8 个上下文的预算。100 个不同私聊目标会拆成至少 13 批，不能把旧 hydration 的 100 项直接发到新端点。

远端回复仍核对账户、设备、完整 key、版本和单调截止时间；等待其余批次之后，正向内容还要重新核对当前快照。只有完整且有效的结果才能一次写入内容投影；网络/过载/过期/部分响应不当作不可见，不清除待补全失效记录。只有明确拒绝才删除旧内容。SQLite 只保存普通资料事实，不保存展示 lease 或下载能力；新页面必须取得自己的访问许可，不能直接显示检索命中的旧文案。

`V2ProfileRepository` 的远端读取、失效扫描及本地落库纳入最多 4 个操作的账户 scope。退出、替换账户及构造失败时停止准入、取消并等待实际操作结束；随后共享展示仓库排空仍未返回的 HTTP，再关闭数据库。取消信号不能代替写入或网络真正完成。正常内容缓存与原账户数据库继续按既有保留政策保存。

联系人及好友申请列表各自使用页面 activation；资料行始终使用有期限的展示组件，缺少管线时显示占位，辅助功能也不回退朗读旧昵称。保留本地内容用于好友搜索与打开私聊的身份线索。群管理/阅读回执与精确公开 ID 查询的迁移见下面两节；其余入口及完整 UI 验收仍需完成。

旧 `POST /v2/profile-views/batch` 已退休：认证后返回空的 `410 Gone` 与 `Cache-Control: no-store`，不读取 profile store。App 已没有该端点的运行时调用；旧 ClientKit HTTP 类型保留为 deprecated，便于识别残留外部调用。即使新资源装配没有启用，也不会恢复旧裸资料响应。发布必须先保证新资源/资料服务可用并协调客户端升级；不提供旧客户端继续补全资料的兼容承诺，也未在本轮启用线上部署。

### 群成员与已读目录的资料边界

实时 `RoomMember` 只包含 `user_id` 和角色，`ReadReceiptReader` 只包含 `user_id`；旧 handle/display name/account kind 字段号和字段名均在 protobuf 中保留为 reserved，客户端与服务端代码已重新生成。ClientKit 成员模型、Core 阅读者模型及 App 成员行模型不再保存这些资料正文，Actor 阅读者结果也仅含 ID。服务端内部成员/阅读者筛选仍读取原有控制事实；成员资格、历史消息受众、账户状态和阅读披露偏好的校验没有因为移除展示字段而被取消。目录标识的披露不等于资料内容展示授权，也不等于管理命令授权。

群成员、已读详情及移除确认页使用各自的 list activation，可见行按 `.room(roomID)` 共用统一资料与字节预算；列表不会枚举全群头像，也不会接管聊天页面的主动作者订阅。角色/管理菜单使用静态动作标签，不把旧缓存昵称拼进辅助功能名称。管理员移除改为可持续更新资料的确认页，选中目标的名字或头像过期后及时占位；实际提交仍使用原成员身份、期望成员版本与原审计命令。

已读传输单页最多 100 人、游标最多 512 字节，拒绝错误房间/消息、重复读者、超量响应及不前进的游标。App 最多保留 1,000 条，窗口前部淘汰后提供“返回列表开头”；重新查询会清除旧窗口标记。新的消息/重置需求先清空旧页、取消并等待旧读取实际结束，再发起最新需求；最多一个实际读取，迟到旧结果不能回填。页面 task 同时拥有初次加载、分页和刷新，离页取消会传递并排空当前读取。

本轮修改的是当前尚未提交的 protocol 32 形状和内部 Actor JSON 结果，需要协调更新 Gateway、Actor 与客户端；不承诺与仍要求旧资料字段的客户端混跑。没有数据库 schema 变化，也没有把目录/阅读披露的缓存事实解释成可永久展示的昵称许可。精确公开 ID 查询的迁移见下一节；成员搜索、其余旧入口、真实 VoiceOver/大字体及管理交互 UI 流程仍待完成。

### 精确公开 ID 查询与添加好友确认

[`V2PublicIdentityResolution`](../../IMV2Core/Sources/IMV2Core/PublicIdentityResolution.swift) 为一次明确的精确 handle 发现定义独立结果：公开身份、查询账户、设备、观察时间、截止时间和响应时间。最长 60 秒，不包含头像、对象地址或可复用到其他资料上下文的授权。它没有加入批量 profile context；不能通过任意 UUID 批量发现陌生人。原有单条精确匹配、每用户查询预算和目标屏蔽查询者时的统一不可用语义保持不变；自己已屏蔽的目标仍可按原策略解析，以支持解除屏蔽。

[`V2PublicIdentityResolutionService`](../../IMV2Server/Sources/IMV2Server/V2PublicIdentityResolutionService.swift) 在目录 I/O 前后读取认证结果，拒绝账户替换、撤销、截止已过或 handle 不匹配的结果。期限从第一次认证之前计时，并取两次认证截止与 60 秒上限的最小值；查询与排队不会延长有效期。它只依赖认证与目录端口，不依赖 storage/delivery，也不签发资源字节能力。该短期结果允许有界的旧观察窗口，不保证已经交付的名称在远端拉黑瞬间消失。

`GET /v2/public-identities/resolve` 现在返回上述带期限的 Core 合同，成功及统一 not-found 响应为 `no-store`；`/me` 保持本人资料接口。ClientKit 验证账户、请求设备、规范化 handle、时间关系、60 秒上限及 8 KiB 响应上限，并从剩余期限扣除整个请求的单调耗时。裸旧响应明确拒绝。`resolve(handle:)` 继续仅供私聊、建群、添加成员、提及与屏蔽等命令解析目标；发现页面必须使用 `resolveForPresentation` 返回的内存快照，不能持久保存期限或拿它替代关系/群资料授权。

添加好友页在结果到期、修改输入、切后台或离开时立即清除结果；渲染和提交前都检查有效期及当前 handle。无自动刷新，用户明确重新查找才消耗新的目录预算。store 最多保留一个实际查询，替代需求取消并等待旧查询完成；迟到的成功或失败不能恢复旧名字或旧发送目标。服务端的好友请求、建群和成员变更仍分别执行原业务授权。新建私聊保留对端 ID 作为查询线索，标题和头像继续走私聊上下文的限期管线。

这是 HTTP 响应格式与 ClientKit 初始化参数的协调升级，需要 Account 与客户端共同更新；未修改 protobuf 或数据库 schema。完整 App 交互、VoiceOver/大字体、其他尚未迁移的资料入口和生产容量仍待验收。

### 入群申请与审批资料

申请 HTTP 的提交、分页、取消和决策响应统一改为申请事实与 `applicant_user_id`；ClientKit 使用 `V2ClientGroupJoinRequest`，不再接收或长期保存申请者昵称、handle 和账户类型。服务端内部申请模型保持原状，实际审批命令与幂等身份不变。

审批行使用独立的 `.groupJoinReview(roomID)` context，由共享资料/头像管线取得限期展示。房间 Actor 要求查看者为当前成员并拥有 `invite_members` 权限：owner 允许；其他角色按已有显式权限、空策略标记及默认管理员策略解析。目标必须仍有该房间的 pending 申请，不要求其已入群。普通 `.room(roomID)` 仍要求目标成员资格，不可互换；同房间两个 context 分别计入最多 8 个授权范围。控制域继续检查设备、资料和双向拉黑，审批不返回群昵称。签名后重新观察待审状态、成员和权限版本；已交付的展示/字节能力仍受原先明确的短期有效期约束，取消申请不会撤销已经到达客户端的字节。

管理页拥有独立 list activation；可见行使用授权组件，不启动聊天作者订阅。页面请求单页最多 100 项，游标最多 1,024 字节，拒绝重复身份、错误群、非 pending 结果及不前进的游标；最多保留 1,000 条，溢出后允许返回列表开头。显式刷新生成新的发布代次，替换页面先取消并等待原管理操作实际结束；离页和退出清空页面，迟到成功/失败均不能回填。邀请列表和申请首页共同校验后一次发布；实际业务写操作仍使用原操作身份。

HTTP 申请响应和内部 Actor profile proof 的 `permissionRevision` 字段需要 Account/Gateway/Actor/ClientKit/App 协调升级；没有数据库或 protobuf 变化，不提供旧裸申请者资料回退。真实 App 交互、VoiceOver/大字体及其余资料入口仍待验收。

本轮证据：Core 11 项 / 1 suite、ClientKit 6 项 / 2 suites、Server 13 项 / 3 suites（真实 PostgreSQL，7 种角色/策略场景、上下文隔离、双向拉黑、权限版本变化、取消与撤设备，以及 20 种邀请 HTTP 响应路径）、App 20 项 / 2 suites 在 iPhone 18 Pro / iOS 27 Simulator 通过。App 覆盖同群/跨群切换的迟到成功与失败、离页/退出、1,000 条窗口和重新回到首页；共享头像管线回归通过。原生完整链路 1 项 / 1 suite 通过，用例 2.671 秒，全部自有进程退出。日志：`/tmp/im-resource-join-review-core.log`、`/tmp/im-resource-join-review-client-final.log`、`/tmp/im-resource-join-review-server-final2.log`、`/tmp/im-resource-join-review-app.log`、`/tmp/im-resource-join-review-live-03/{client.log,summary.json}`。

验收过程保留限制：服务端首次运行因新 fixture 复用全局唯一邀请摘要失败，改为每次独立摘要后通过，未调整业务约束。第一次原生运行在原有实时作者补充断言处取得非 presentation 结果，之后新增阶段诊断；第二次原生运行在新增裸 HTTP 审批读取遇到 429，补上有界 `Retry-After` 处理后第三次通过。首次实时补充失败尚无足够日志定位根因，不能以随后通过代替抖动/过载稳定性或万人容量验收。

## 个人资料更新、恢复与头像保留

当前本人资料合同由 [`V2ProfilePatch`、`V2ProfileUpdateCommand` 和原操作回执](../../IMV2Core/Sources/IMV2Core/ProfileOperation.swift)定义。`displayName` 是 `unchanged | set(String)`；`avatar` 是 `unchanged | remove | set(V2AvatarReference)`。至少修改一个字段，名称沿用 NFC、空白规范化与公开名称校验。改昵称时保留 `avatar.unchanged`，不把表单曾读到的头像作为完整目标重写。

`PUT /v2/profile/me` 接收 `operation_id`、`expected_revision`、`patch` 和 `first_submission_deadline_ms`；`patch` 按 Core Codable 合同编码。请求体最多 8 KiB。冻结的命令保留 actor、operation ID、预期版本、规范化字段 patch 和首次提交截止，并据此计算版本化指纹。身份、语义字段或截止改变必须使用新的明确意图；token、attempt 等传输状态不参与指纹。首次截止使用服务端当前观察时间检查；已经存在的原回执不因本次重放时钟或截止而改变。

成功读取 `GET /v2/profile/me` 直接返回 Core `V2ProfileView`；提交返回 `V2ProfileUpdateResult`，其中 `receipt` 与 `currentSnapshot` 分开。原回执绑定 actor、operation ID、fingerprint、终态和解决时间；`committed` 保存本次产生的 profile/visibility revision。后来 B 更新成功后重放 A，A 的原回执保持不变，而当前快照可以是 B 的较新版本。客户端独立保护快照 revision，不从 A 的成功回执回退当前资料。版本冲突、头像不可用和首次未受理过期也保存 `.rejected` 原回执，通过 HTTP 200 的明确业务结果返回；同 ID 不同指纹是冲突错误，不能据此创建替代。

`POST /v2/profile/me/operations/recover` 接收 `operation_id`、`fingerprint`、`action = query | closeIfAbsent`，请求体最多 2 KiB，响应按 Core `V2ProfileOperationRecoveryResult` 编码。查询返回原 `receipt` 和可用的独立当前快照、`unresolved` 或 `fingerprintConflict`；无法取得当前 active 快照时可以只返回最小原回执。`unresolved`、404/403 或传输错误都不是未执行证明。关闭和提交在 [`PostgresV2ProfileUpdateStore`](../../IMV2Server/Sources/IMV2Server/PostgresV2ProfileUpdateStore.swift) 内获取相同 actor/operation 咨询锁：已有终态返回原回执；不存在则原子记录 `closed`，迟到提交只能取得该关闭回执，不能修改资料。

上述路由都经当前账户/设备鉴权，响应 `no-store`。生产 AccountServer 将恢复路由装配到已有 PostgreSQL 已认证请求限流 owner，使用独立 `profile-recovery` scope、cost 3；键绑定 user/device/scope，额度跨进程保留。该独立速率预算限制随机 ID 查询与墓碑写入，不另设无界内存计数。当前没有新增永久回执的 lifetime 总量 quota，不将速率保护宣称为总存储容量验收。

当前 canonical PostgreSQL schema 为 `im-v2-current-56`。`public_profile_update_operations` 保存 `fingerprint_version`、32 字节 `request_fingerprint`、`outcome_kind`、可选 `result_revision`、强类型编码的不可变 `receipt` 与 `created_at`。只有 committed 必须具有正 result revision，rejected/closed 不携带成功版本。触发器禁止修改或删除原回执，housekeeping 不再按时间清理这张表；永久关闭栅栏和原结果不会在普通保留窗口后失效。启动 readiness 与 SQL contract 检查当前表形、指纹/回执字段、结果约束与不可变触发器。直接采用全新当前建库合同，不提供旧全量资料 PUT、旧操作记录或历史 schema 兼容。

实际资料修改仍在账户资料行锁内检查预期 revision，再按固定顺序锁定新旧媒体。新头像要求本人 account home、`user_avatar` 用途、available 图片、当前 generation 的 active placement，以及该代完整 ready 的 128/256 头像变体。取得媒体锁后重新读取数据库时间检查绑定期限和首次提交截止；不能凭请求开始时仍有效而绑定等待期间已过期的资源。

当前已绑定头像可以在初始上传绑定期限之后随改名继续保留。替换或移除时，将旧媒体保留至至少本次持锁观察时间后 120 秒；GC 与绑定使用相同媒体锁，并继续检查资料引用。命令重放读取原操作回执，不因旧资源已回收而重新执行修改。没有资源目录记录的扫描媒体不能成为新头像，资源 Ready 与业务 committed 仍是不同事实。

验证范围：Core 字段 patch/规范化/指纹/receipt binding 专项通过；真实一次性 PostgreSQL 覆盖 A/B 原回执重放、提交和关闭两种顺序及 8 次并发竞争、持久拒绝、no-op/版本上限、头像与 GC 锁等待；HTTP 覆盖 Core 读取/提交/恢复格式及 no-store，middleware 覆盖恢复独立限流与 429 阻止 handler。这里登记的是本人资料 Core/Server 合同及组件证据；全部领域公共 work 接入、全 App 弱网体验、真实账户和平台/部署容量验收仍见[应用弱网实施状态](application-weak-network-progress.md)，不由本节宣告完成。

## 群头像接入边界

群头像使用独立 operation ID、expected revision 和不可变回执。设置、替换、移除都与房间序号及 `group.avatar_changed` 事件在同一 owner 事务提交；并发重复操作只生效一次，之后的重放仍返回原回执。事件仅包含房间、版本、序号与服务端时间。当前要求成员角色与结构化群主身份同时匹配，上传者及用途/home/generation 正确，并具备 ready 的 128/256 头像变体；不从上传成功推断群头像已设置。

群头像 binding 与 GC 共用精确媒体锁；绑定中的媒体不进入回收。新绑定在取得全部媒体锁后重新观察数据库时间，不让队列和锁等待延长已过期的上传绑定窗口。替换/移除后将旧媒体保留到至少本次持锁观察时间后 120 秒，覆盖此前已签发字节能力的最长截止；不能以较早的命令开始时间缩短这个保护期。表和幂等回执直接定义在 canonical schema，并属于启动 readiness 合同。

读取由房间 Actor 给出当前成员资格、avatar revision、resource generation、activation 和观察时间。控制服务单独验证账户/设备；签发后再次读取权限、资源和 owner 路由。`V2GroupAvatarPresentation` 将展示期限限制为最早相关观察后至多 300 秒，下载期限至多 120 秒，并进一步受设备与 activation 截止约束。返回值不进入持久资料表或 journal。个人资料批量签发同样增加了签名后的控制事实和房间权限复核。

Account 已装配 `GET /v2/rooms/{roomID}/avatar`，成功响应 `Cache-Control: no-store`。ClientKit 的 `V2HTTPGroupAvatarPresentationClient` 验证房间/账户/设备一致，拒绝进入对象目标的业务 token，并区分权限拒绝与临时故障。App 已在群会话列表和聊天标题消费展示租约；群头像管理界面已接入，但上传 capability 仍关闭，完整 UI 与跨 owner/GC 并发验收之前不能宣称群头像读写端到端可用。

`V2GroupAvatarPresentationRepository` 按账户、设备、房间及可见 activation 管理内存授权。同房间并发需求合并；单仓库最多 2 个远程读取、128 个待处理房间、512 个等待者、256 个 activation，展示缓存至多 2 MiB / 256 个房间。页面重入即使有磁盘图片也重新授权；一个等待者取消不影响其他消费者。最后一个等待者退出时取消旧读取，但直到它真正结束才释放并发名额；旧响应不能满足新页面的需求。只有明确拒绝和服务端限流进入有界冷却，网络故障不记为不可见。

展示与下载期限根据服务端时间映射到单调时钟，并保守扣除完整往返时长。读回复和复用展示前都核对本地头像失效版本；图片解码完成后再次核对 room state、resource generation、membership revision 与 activation。每个 activation 最多一个有界失效订阅；其他页面收到明确拒绝、新版本或已知过时响应时，按房间通知已经展示的消费者立即隐藏旧像素。尚未获准的等待者直接处理请求结果，不以自身失败通知重置重试预算。UI 只在可见且前台时显示，按展示截止清除；后台、权限失效或账户切换撤销 activation。共享字节缓存和已解码图片始终不能代替展示授权。本地管理 journal 的 claim/重试只通知管理状态，不让所有可见头像重新授权；真正的 room-log 版本变化仍触发展示失效。

管理入口为 `POST /v2/rooms/{roomID}/avatar`，请求体限制 8 KiB，只接收 Core 的冻结命令；路径与命令 room 必须一致。控制库先验证活跃账户/设备，再调用 `V2RoomRefAdministrationClient` 的用户通道，绝不直接写 owner 表或调用对象服务。单进程最多 32 个并行命令，同设备最多一个，不排无限队列。授权预算从控制查询开始计时，最多 10 秒，并收紧至设备剩余有效期；同一个截止传给 RoomRef。已进入执行的命令可能与后续设备撤销并发，不能把后来撤权当成已提交操作的回滚证明。

成功或幂等重放都返回原始提交回执，并绑定账户、设备及完整命令。版本冲突与幂等载荷冲突返回不同的 409 结果；资源未就绪为 422，房间权限拒绝为 403，过载为带有界 `Retry-After` 的 429。ClientKit 的 `V2GroupAvatarCommandSubmitting` / HTTP 实现检查回复身份、完整命令、回执内容与 HTTP 状态是否相符；网络故障和 503 保留为结果未知。业务拒绝只描述本次尝试，不证明另一个在途尝试已永久关闭。

ClientKit 已增加独立的 `V2GroupAvatarIntent`、SQLite journal 与 `V2GroupAvatarIntentEngine`。冻结时核对本地账户绑定、room、用途与 media，并登记上传依赖；同一 room 只允许一个未结束的意图。发送前在事务中标记 `submission_started` 并领取 30 秒 claim，之后不再以资源上传期限决定能否重放原命令。旧 claim 的失败不能覆盖新尝试，迟到且匹配原命令的提交回执仍可确认成功。重启与快照替换保留未知结果；退群或资料投影被清除也不能删除原命令。

恢复引擎单次最多扫描 16 个意图、同时运行 2 个操作、接纳 64 个等待者；页面取消仅取消自己的等待。网络故障以指数退避重试，最多自动尝试 5 次，第 5 次期间崩溃也不重置计数，之后进入 `needsAttention`。显式重试复用原命令；权限拒绝、冲突和资源不可用也保留原意图等待处理。只有从未提交的准备状态可以直接取消，并在同一 SQLite 事务记录上传清理需求。`needsAttention` 不是完整终态。App 账户运行时已构造提交/恢复端口并接入持久资源恢复循环，关闭账户同时停止管理服务的准入与群头像意图引擎，再关闭共用上传引擎，并等待所有管理操作实际结束。

服务端新增 `POST /v2/rooms/{roomID}/avatar/recovery`，接收原命令与 `query` / `closeIfAbsent`。查询不存在时只返回 unresolved；关闭在原操作锁和 activation 栅栏内，先返回已提交回执，否则写入永久关闭记录。关闭绑定原 actor、operation、room、media 和预期版本；载荷不符返回冲突。恢复只操作调用者自己的命令，控制库继续校验账户/设备，故可以在退群后确认旧操作。已关闭命令的普通提交返回 410；客户端将此视为待恢复提示，必须通过匹配完整请求的恢复响应消费关闭证明，不以一个 HTTP 状态码自行创建新操作。

ClientKit 通过独立的 `V2GroupAvatarOperationRecovering` 端口恢复，不接触对象存储或分发适配器。HTTP 实现检查账户、设备、完整命令及请求动作，回复最多 16 KiB。恢复动作在 I/O 前落盘，重启继续查询或关闭原操作；已请求的关闭不能被后来的查询降级。旧在途提交返回成功仍可确认，旧失败则释放自己的 claim，让持久化的关闭请求继续执行。过期查询不能清除新的 claim 或关闭动作；相互矛盾的成功/关闭证明被拒绝。

收到永久关闭证明后保留 `closed / awaitingDecision` 记录及源文件。明确放弃才记为 abandoned；明确重提则以新读取的 revision，在同一事务分配新的群头像 operation、MediaID 和上传 operation/job，并保留源文件。重复点击返回同一替代意图，原关闭证明始终保留。旧上传可取消，但新意图继续保护共用文件。当前 canonical schema 直接定义完整 journal；同版本重启保留冻结命令、回执和在途 claim。

`resource_group_avatar_closures` 没有级联外键或保留期删除。关闭和成功回执不可更新/删除，两个表的 INSERT 都获取与 Swift 写入相同的操作锁，并用 VOLATILE 函数在锁等待后读取新快照，阻止提交/关闭同时成立。canonical schema、启动 readiness 和离线合同验证关闭表及触发器函数体，所有 owner 从这份统一 schema 初始化。

暂存文件的引用检查同时覆盖消息和群头像。未知群头像意图及等待用户决定的关闭意图，即使对应上传后来过期也继续保护源文件。删除前在 SQLite 中持久标记同一文件的所有 job 已开始清理，之后拒绝新增消费者、创建替代意图或重新绑定该文件；文件已删除但确认未落库时可以恢复清理。这个栅栏避免“查询可删除—新增依赖—实际删除”之间的竞态。

退出登录只关闭账户暂存器，不把仍然保留 journal 的暂存目录整体删除。重新激活同一账户后按 journal 引用及 24 小时宽限期清理孤儿草稿；未知操作和等待决定的关闭记录继续保留源文件。账户间目录独立，下载缓存及展示资格仍在退出时清理。退出登录本身不能当作操作永久关闭的证明。

`group.avatar_changed` 已归类到 room-log 的群能力事件。客户端将版本失效状态及原事件摘要持久化，拒绝同来源、同版本或同房间序号的矛盾载荷；较旧事件不降低版本。状态变更通知展示消费者，退群清除该房间记录。个人快照保留仍获准房间的较新 room-log 版本，不能以旧快照覆盖；快照影子表在创建时即包含完整头像失效结构，进程重启可以继续激活。持久数据只有版本、序号及事件事实，没有下载凭证。

## 群头像管理页与上传准入

群聊天的“群头像”入口使用独立管理 store 和互斥弹窗状态，接入选择 JPEG/PNG、更换、移除、取消准备、继续准备、确认结果、停止未知更改，以及永久关闭后的重提/放弃。新上传和重提会重新读取群管理权限、当前头像 revision 与上传能力；客户端文件上限为服务端上限与 10 MiB 的较小值。读不到能力或用途未启用时禁用新上传，移除已有头像不需要新上传能力。页面持有的管理权限按往返扣减后的单调期限失效，后台/离开页面清除；最终提交仍由 owner 事务授权。

首次上传任务与头像命令使用同一 SQLite 事务创建，冲突时两者一并回滚。写入后由账户意图引擎启动有界共享任务，界面不等待完整上传才恢复响应。已保存的未知结果保持原命令；只有匹配的永久关闭证明才能创建新 revision 下的替代操作。管理页的待处理查询先过滤终态，再应用 16 项上限，避免大量历史记录遮住旧的待决定操作。失去当前成员资格后仍可查询/关闭自己的旧操作。

页面关闭只取消自己的等待者；在交给管理服务之前取消的文件可直接丢弃，已经越过 journal 边界的文件继续由引用和终态规则保护。元数据读取不会把签名计划写进管理 store。管理权限失效与本地意图进度使用不同订阅，claim/重试不触发权限 HTTP 查询；本地队列完成时会重新读取当前头像并让展示缓存重新授权，不必等待房间日志追上来。

同一 Form 行中的恢复按钮使用独立的有边框按钮样式与大尺寸控件，避免系统默认的整行点击行为同时触发“确认结果”和“停止”两个选择。UUID 隔离的 DEBUG 测试入口使用真实 SQLite、意图引擎、管理服务和页面，仅替换远端授权/恢复响应及未使用的字节 I/O；不访问真实账户 Keychain 或业务数据库。它服务于页面导航和恢复持久性的 XCUITest，不是后端联调或生产容量证明。

服务端上传准入现在同时核对 `room_memberships.role='owner'` 与 `group_rooms.owner_user_id`；资源 owner 的创建事务再次核对这两个事实。即使角色和版本号尚未变化，结构化群主已切换也拒绝新分配。当前仍未打开 group-avatar upload capability；后续必须完成真实图片选择/关闭/重启及退群后恢复的 UI 流程、跨 owner 与绑定/GC 竞争验收，再开放完整用途。

## 账户级待处理群头像入口

账户菜单的“待处理群头像”使用独立的 [列表 store](../../IMApp/IMApp/V2/V2PendingGroupAvatarsStore.swift) 和 [页面](../../IMApp/IMApp/V2/V2PendingGroupAvatarsView.swift)。列表只读取本人 journal 的操作种类、创建时间和处理状态，不读取已失权群的名称、头像或成员列表，也不为每一条记录发起权限 HTTP 请求。列表不与当前房间投影关联；退群、快照替换或重启不会让尚未确认和永久关闭后待决定的操作消失。它目前只覆盖群头像，尚不是所有附件操作的统一恢复中心。

[本地分页](../../IMV2ClientKit/Sources/IMV2ClientKit/GRDBV2GroupAvatarIntents.swift) 在同一 SQLite 读取事务中校验账户，使用 `(created_at, operation_id)` 游标，每页默认 32 条、最多 64 条，并多取 1 条判断是否存在下一页。canonical schema 为当前账户的非终态和 `closed/awaitingDecision` 建立部分索引。终态在 LIMIT 前过滤；翻页前已有操作完成不会造成 offset 位移而遗漏后续记录。游标绑定账户，只驻留内存；这是实时队列，刷新返回第一批，以看到游标之前新增的记录。

页面只保留一批记录，下一批替换当前批次；当前批次全部完成后自动回到首批。点选操作按原 room/operation ID 打开群头像管理页，即使该操作不在房间默认的 16 项窗口内，也会精确读取并置于首项，总数仍不超过 16。查询、停止、取消准备和放弃沿用原操作身份；重新提交仍须重新获得有效管理权限和当前头像版本。

列表观察 `.conversationDetails` 的本地通知，不订阅展示权限刷新。页面最多持有 1 个正在读取的任务和 1 个合并后的读取需求；非协作式请求在实际完成前仍占用名额。后台或关闭清空可见状态、取消请求，迟到结果受页面激活标识隔离。账户退出先隐藏并排空该页面所有者；关闭后的旧列表不能重新激活。所有列表数据与恢复动作均不包含运营商对象路径、签名计划或 SDK 类型。

## 账户任务所有权与构造清理

`V2ResourceOperationScope` 将控制请求和 journal 访问也纳入账户关闭边界。上传引擎的 prepare、能力刷新、取消和文件释放，以及群头像重试/查询/关闭/替代等入口，都先登记操作；普通资源和发送服务最多 32 个已接收操作，群头像意图引擎最多 64 个，App 管理编排服务最多 16 个。调用者取消会传给自己的操作，但名额直到实际任务结束才释放。已有共享上传/提交仍保留独立等待者语义，页面退出不能自行撤销未知业务提交。

关闭先停止准入，再取消并等待已登记任务、共享 flight 和恢复循环。即使底层传输忽略取消，也等它真正返回后才能关闭数据库或文件所有者；迟到的控制结果不能发起下一次网络请求或发布新状态。已经取得的匹配业务终态证明仍在排空期间按原合同持久保存。重复关闭同样等待尚未结束的工作，不能把发送取消信号视为已经结束。关闭是本机生命周期事实，不是远端操作的永久关闭证明。

App 使用 `V2AccountActivationScope` 持有构造中的账户资源。初始化失败、取消或认证代次失效而提前返回时，按依赖倒序清理已经构造的服务；一项清理失败不跳过剩余服务。所有可抛错构造和权限复核完成后，在没有中途挂起的区间将资源交给 AppStore，再启动资源恢复循环。媒体关闭捕获原所有者后清空对应字段，避免等待完成后误清空新的账户实例；源文件继续按照 journal 保留策略处理。后续仍需真实登录/退出/切账户与全部管理 UI 的集成验收。

## 发送结果与原始文件保护

上传完成、资源可绑定、消息接受是三种不同事实。SendIntent 冻结文本、提及、回复、附件顺序与 clientMessageID，handoff 只把同一意图写进本地 outbox。

资源不可用或命令超过自动重试窗口时，客户端保留原命令，调用 room owner 的 message-operation recovery。`query` 的未找到只是 unresolved；`closeIfAbsent` 取得与接受消息相同的操作锁后，返回已有接受回执或建立永久关闭证明。数据库的接受触发器在等待操作锁后重新观察关闭事实，阻止迟到接受。关闭记录不得级联删除或被普通保留策略清理。

原子发送批次遇到该精确关闭触发器时，事务已回滚；store 将其映射为允许逐项重试的批次结果。batcher 按房间原顺序重新核验，只有对应消息返回永久关闭，不能把一条消息的关闭证明复制给整个批次。未知提交或其他数据库错误不走这条回退。

本地待确认记录不参加普通终态清理，也不会自动生成新的消息 ID。只有拿到永久关闭证明且用户点击重试，才在同一 SQLite 事务内创建保留原文、提及、回复和顺序的新意图；新消息/上传/导入身份独立分配，重复点击返回同一替代意图。暂存文件须等待所有依赖意图已接受或用户已取消尚未提交的意图后才删除；删除结果持久记录，可恢复文件已删除但本地确认未写入的情况。消息接受回执在文件清理完成前继续保留。

## 本地文件的播放、预览和分享

`V2DownloadedConversationMedia` 只提供缓存线索；每个缩略图解码、播放器和系统分享操作必须向原账户下载器取得自己的 `V2ConversationMediaFileLease`。下载器校验当前已发布文件、资源身份、所属目录及常规非符号链接文件；文件已淘汰、撤回、被替代或账户关闭时拒绝新的借用。令牌按独立 ID 幂等释放，最多 64 个；最后一个使用者退出才允许清理。文件借用只保护磁盘生命周期，不代替服务端下载授权或资料展示 lease。

附件每次重新授权下载后发布随机后缀的新本地代次，不覆盖正在播放/分享的原文件，也不让旧缩略图缓存混入新内容。旧代次禁止新借用，现有使用者仍可完成；撤回同样先禁止新借用，取消该资源的在途下载，再等待现有使用者释放后删除。不可合作的迟到下载也在发布前检查取消。维护跳过正在写入的 `.partial`，所有固定文件仍计入字节预算；额度不足时拒绝新 I/O。头像与附件共同限制最多 4 个实际下载。

App 图片解码结束后释放，播放器在退出或离开前台时暂停、取消 asset 加载、移除 player item 后释放；返回前台重新借用，丢失文件时回到重新下载。系统分享改用 `UIActivityViewController` 的完成回调与控制器实际移除路径结束使用，保留独立于来源消息行的生命周期。`NSItemProvider` 导出文件副本并给出媒体类型及“音频.wav”等显示名称，不提供缓存原地访问、内部哈希文件名或签名 URL。分享已交给外部应用的副本属于用户导出，后续撤回不能收回该副本。[Apple 分享完成回调](https://developer.apple.com/documentation/uikit/uiactivityviewcontroller/completionwithitemshandler-swift.property)、[文件提供合同](https://developer.apple.com/documentation/foundation/nsitemprovider/registerfilerepresentation%28fortypeidentifier%3Afileoptions%3Avisibility%3Aloadhandler%3A%29)。

账户关闭先移除账户界面，再停止新下载和新借用，排空传输、解码及仍在使用的文件后删除目录。共享令牌在尚未创建控制器便离页时也会释放；并发 close 和重复 completion 不重复减少其他使用者的计数。目录 URL 统一目录标记，避免相同路径因尾部斜杠差异被误拒绝或遗漏清理。此边界不改变任何运营商端口、服务端协议或数据库。

测试使用真实文件系统与正式文件提供接口；界面用显式 signed-out DEBUG fixture 运行真实 AVPlayer 和系统分享控制器，只有远端授权/字节取得被替换。仍需真机锁屏、系统分享扩展实际完成、iPad 布局、真实账户切换和大文件峰值占用验收，不把模拟器界面用例视为所有外部应用均已通过。

本轮验证：下载/缩略图/会话/文件使用/个人及群头像共 141 项 / 6 suites 通过；随后补充的文件使用专项最终 9 项 / 1 suite 通过，覆盖独立计数与重复释放、旧代次固定、撤回延迟删除、额度不足不启动 I/O、并发 close、未创建控制器便放弃、64 个使用者上限、缺失/符号链接拒绝、维护不误删在途 partial，以及真实 `NSItemProvider` 文件导出。iPhone 18 Pro / iOS 27 的 2 项 UI 测试通过（38.817 秒）：音频播放、后台恢复、播放器/系统分享期间回收保留文件、页面移除后账户关闭完成。保留截图已目视检查，最终分享面板显示“音频”并识别为音频类型。首次专项暴露目录 URL 标记差异，修正后上述测试通过。日志：`/tmp/im-resource-file-use-app-final.log`、`/tmp/im-resource-file-use-leases-final.log`、`/tmp/im-resource-file-use-share-final.log`；最终截图在 `/tmp/im-resource-file-use-share-artifacts/`。文档链接与 diff 空白检查通过。

## 实际验证

- 精确查询与添加好友增量：ClientKit 4 项 / 1 个 suite 通过，含错误账户、设备、handle、裸旧格式、超量正文、过长期限、倒置时间与非法 handle 共 8 个参数场景，以及扣除完整 RTT 的单调截止验证。Server 4 项 / 1 个 suite 通过，含撤销、账户替换、凭据到期、超时与返回 handle 不符共 5 个参数场景；验证初次/最终认证期限均会收紧结果。App 联系人及会话套件 132 项 / 2 个 suite 在 iPhone 18 Pro / iOS 27 Simulator 通过，覆盖编辑、到期、后台/离页清除、非协作式旧查询成功/失败、替代请求排空及取消不发布。收尾补齐等待期间取消时的状态复位后，联系人套件另 15 项 / 1 个 suite 与构建再次通过（`/tmp/im-resource-discovery-app-final.log`）。真实原生 Account/Gateway/图像 worker 构建通过，ClientKit → HTTPS Account → PostgreSQL 精确查询及拉黑后拒绝通过，原 TLS/资源/昵称场景继续通过：1 项 / 1 个 suite，2.145 秒用例时间，自有进程与临时数据库均已清理。静态 inventory、Markdown 链接及 diff 检查通过。测试未替代真实 App 交互、生产适配器或万人负载验收。日志：`/tmp/im-resource-discovery-client-final.log`、`/tmp/im-resource-discovery-server.log`、`/tmp/im-resource-discovery-app.log`、`/tmp/im-resource-discovery-live-01/client.log`、`/tmp/im-resource-discovery-live-01/summary.json`。

- 群成员与已读目录迁移：ClientKit 实时协议、成员与回执边界 27 项 / 3 个 suite，Server Gateway、Actor 回执映射、RoomRef 与相关授权 79 项 / 5 个 suite 通过。验证回复只含标识/角色、错误身份与角色、重复条目、页上限和 512 字节游标边界；首次 Server 断言把 protobuf JSON 的 `userId` 误写为 `userID`，修正后全部通过。App 会话与头像管线 126 项 / 2 个 suite 在 iPhone 18 Pro / iOS 27 Simulator 通过，覆盖非协作式请求取消排空、旧需求隔离、1000 条读者窗口与重置，以及群/私聊资料上下文区分。最终成员行调用调整后重跑会话套件 117 项 / 1 个 suite 通过；此前一次单项筛选选中 0 项，仅算构建，不计测试证据。真实 ClientKit → TLS Gateway → 远程 Actor → PostgreSQL 验收 1 项 / 1 个 suite 通过（1.878 秒用例时间）：检查实际成员/读者 protobuf JSON 无资料字段，关闭阅读披露后读者消失，原上传、头像字节、作者补充、昵称更新及拉黑用例继续通过。自有服务与临时数据库已清理。生成协议检查、protocol 32 文档一致性、静态 inventory（405 文件 / 31 writer / 41 claim / 233 DTO）、Markdown 链接和 diff 检查通过；未改数据库 schema。此为协调升级，未证明旧客户端混跑、实际 App 交互/VoiceOver 或生产 CDN/万人容量。日志：`/tmp/im-resource-directory-client.log`、`/tmp/im-resource-directory-server-final.log`、`/tmp/im-resource-directory-app.log`、`/tmp/im-resource-directory-app-suite-final.log`、`/tmp/im-resource-directory-live-01/client.log`、`/tmp/im-resource-directory-live-01/summary.json`。

- 联系人补全迁移：ClientKit 资料补全、展示与操作所有权 14 项 / 4 个 suite 通过，其中错误账户、设备、上下文、部分响应、retryable 与到期回复覆盖 6 个参数场景。验证 100 个私聊失效目标按每批最多 8 个上下文拆分且共用最多 2 个实际请求，完整批次才写入；真实 SQLite 的内容重启保留、明确拒绝清除、新页面不能复用补全授权；账户关闭等待忽略取消的 HTTP 和本地写入。App 联系人、构造清理、头像管线 25 项 / 3 个 suite 在 iPhone 18 Pro / iOS 27 Simulator 通过，构建通过；包含真实 GRDB 联系人补全、检索内容保留、显式撤权清除及既有窗口滚动/取消用例。Server 旧端点退休与认证 2 项 / 1 个 suite 通过；首次构建的测试响应体读取 API 不匹配已修正。未修改 schema 或 protobuf；旧端点返回 410 属于协调升级要求，生产 CDN、万人容量、实际登录切换及 VoiceOver/大字体验收不在本轮证据内。日志：`/tmp/im-resource-profile-projection-client.log`、`/tmp/im-resource-profile-projection-app.log`、`/tmp/im-resource-profile-projection-server-final.log`。静态 inventory、文档链接与 diff 检查通过。

- 名称选择器迁移：ClientKit 真实 SQLite 上下文读取与既有私聊身份缓存 11 项 / 2 个 suite 通过，涵盖同步/显式缓存来源、未知房间、100 项边界及重启。App 的会话、搜索竞态、真实投影选择器和头像/名称管线 133 项 / 4 个 suite 在 iPhone 18 Pro / iOS 27 Simulator 通过，构建通过；验证收藏/转发的完整查询键、搜索 group/direct/self/unknown 区分、旧查询跨重新选择与清除隔离、同页名称请求合并、纯名称不下载/解码、重入重新授权和不可见处理。首次 App 构建发现新增测试遗漏 `@testable` 导入，修正后上述实际用例全部执行通过。未修改协议、服务端运行时或 schema；真实交互、VoiceOver/大字体视觉验收及生产容量不在本轮证据内。日志：`/tmp/im-resource-selector-client-tests.log`、`/tmp/im-resource-selector-app-final.log`。

- 私聊页面授权增量：移除消息投影中统一假定的群权限，由详情上下文选择群、私聊对端和本人资料查询；标题与消息行共享页面 activation，scope 拒绝其他 peer 和错误上下文。App 在 iPhone 18 Pro / iOS 27 Simulator 执行会话与头像管线 121 项 / 2 个 suite 通过，覆盖未知/错误身份、与气泡方向无关的权限选择、群和私聊重复行合并、页面重入重授权、隐藏后迟到解码拒绝及独立 key 失效。真实 PostgreSQL 与房间领域执行器的 1 项 / 1 个 suite 通过，验证本人/对端授权、陌生目标/自己私聊 pair/错误群上下文拒绝，以及拉黑和设备撤销。未修改服务端运行时代码、Core/ClientKit 协议或数据库 schema；私聊主动推送、其余旧入口和真实 UI/生产 CDN/万人容量仍未完成。日志：`/tmp/im-resource-direct-page-app-tests.log`、`/tmp/im-resource-direct-page-server-tests.log`。

  随后补充并单独执行新建私聊立即导航的回归：列表尚未同步时仍保留正确对端 key 和页面上下文，1 项 / 1 个 suite 通过；构建同时通过。日志：`/tmp/im-resource-direct-open-app-test.log`。本轮静态 inventory（405 文件 / 31 writer / 41 claim / 233 DTO）、文档链接和 diff 空白检查通过。

- 群昵称分页授权迁移：旧 HTTP 入口已接入统一 ResourceProfilePresentationService，房间扫描仅提供候选，逐项复核设备、资料、双向拉黑、成员及当前昵称版本；最大 100 项，空页也验证设备，不签发整页头像。Core 合同 4 项 / 1 个 suite、ClientKit 分页/资料入仓/退避 27 项 / 3 个 suite、Server 真实 PostgreSQL/路由/准入与关闭 20 项 / 3 个 suite 通过。覆盖裸旧响应拒绝、错误账户/设备/房间、倒退游标、页上限、网络耗时扣减、候选旧文案不泄漏、被拉黑和已离群目标分别不可见，以及扫描取消后仍占名额、关闭等待实际扫描退出。App arm64 Simulator 构建通过。真实 ClientKit → HTTPS Account → 远程 Actor → PostgreSQL 链路 1 项 / 1 个 suite 通过（2.000 秒用例时间）：4 次目录 GET 覆盖正常限期昵称、不预签头像、末页、拉黑后不可见及响应正文不含私密昵称，原上传/字节/TLS/昵称失效用例继续通过，全部自有服务已退出。旧裸分页格式不再兼容；其余旧资料入口、成员搜索 UI 和生产万人负载仍待完成。日志：`/tmp/im-resource-nickname-page-core.log`、`/tmp/im-resource-nickname-page-client.log`、`/tmp/im-resource-nickname-page-server-final.log`、`/tmp/im-resource-nickname-page-app-build.log`、`/tmp/im-resource-nickname-pages-live-01/client.log`、`/tmp/im-resource-nickname-pages-live-01/summary.json`。

- 群昵称持久失效增量：新增 `group.nickname_changed` 房间日志与两张本地版本/回执表；昵称、幂等回执、房间序号、命令额度和合并 wake 在同一个服务端事务提交，无每成员 user-sync 扇出。ClientKit 全量 804 项 / 130 个 suite 通过；随后增加“内容失效仍接受同一 nonce 的新昵称，权限拒绝仍阻止旧 nonce”回归，资料/昵称/页面相关 45 项 / 5 个 suite 通过。验证版本单调、冲突回滚、重启与快照、退群清理、独立通知作用域及迟到 HTTP 拒绝。Server 昵称事件、资料和合批专项 13 项 / 4 个 suite 通过；随后普通/大群 wake 租约替换、pending 合并及迟到发布回执不删除新 wake 的专项 2 项 / 1 个 suite 通过。另在本次自建的两个可丢弃 PostgreSQL 数据库执行既有并发重放、最大版本、异常时钟、owner 切换 4 项参数化回归（23 个场景）并通过，随后删除这两个自有数据库。最终补齐 Actor 事件 ID 工厂注入，昵称/wake/owner fence 3 项 / 2 个 suite 再次通过，自有验证数据库已删除。App iPhone 18 Pro / iOS 27 Simulator 的头像管线/投影通知 12 项 / 2 个 suite 与构建通过。真实原生链路 1 项 / 1 个 suite 通过（1.694 秒用例时间）：4 次昵称写入经 Account → 远程 Actor，TLS 拉取事件后落入 SQLite，旧展示立即不再可取，同 nonce 新版本恢复，清空与后续拉黑也正确处理；所有自有服务退出。未改变服务端 schema 或 protobuf；新增客户端迁移与事件类型仍需协调部署。旧昵称分页接口、实际 App 静默页面与远程 wake broker、生产 CDN 和万人容量仍未完成。证据：`/tmp/im-resource-nickname-invalidation-client-full.log`、`/tmp/im-resource-nickname-invalidation-client-final.log`、`/tmp/im-resource-nickname-event-server.log`、`/tmp/im-resource-nickname-wake-final.log`、`/tmp/im-resource-nickname-final-server.log`、`/tmp/im-resource-nickname-legacy-regressions.log`、`/tmp/im-resource-nickname-invalidation-app-final.log`、`/tmp/im-resource-nickname-events-live-01/client.log`、`/tmp/im-resource-nickname-events-live-01/summary.json`。

- 运营商抽象边界增量：统一上传封存首次写入和恢复 inspect 的回执校验，完整比对 placement、binding ID/配置版本、handle 格式/内容、大小和 SHA-256。公开导入的独立 storage/upload 测试替身配合真实 PostgreSQL，16 个参数组合覆盖正常回执与上述 7 类不一致；错误回执不能写 placement 或扫描 outbox，正常恢复不重复写字节，原持久对象身份保持不变。Server 相关 12 个 test 声明 / 5 个 suite 全部通过，包括原有后端切换、精确删除、缓存鉴权/请求合并、HTTP 上传与导入及生命周期栅栏。证据：`/tmp/im-resource-provider-boundary-tests.log`。本次未改客户端、协议或 schema；尚未交付生产适配器、存量迁移或万人容量验收。

- 群昵称授权分发增量：Core 全量 149 个 test 声明 / 44 个 suite；ClientKit 资料仓库、可见页面及作者通道专项 58 项 / 7 个 suite；Server 资料、真实 PostgreSQL 同房间合批及分发器 20 项 / 3 个 suite，Actor capability envelope 另 5 项 / 1 个 suite，均通过。新增验证跨房间/主体/私聊/隐藏状态拒绝群昵称，解码规范化约束，50 个不同 viewer 的一条集合读取不泄露离群目标昵称；签名期间昵称新增、修改、清空均使证明失效；客户端拒绝昵称倒退和同版本冲突，清空及隐藏状态转换保留版本下界并通知可见行。App iPhone 18 Pro / iOS 27 Simulator 的头像管线 7 项 / 1 个 suite 通过，覆盖群昵称优先、清空回退以及解码期间仅昵称发生变化的竞争；最终 arm64 Simulator 构建通过。真实原生链路 1 项 / 1 个 suite 通过（1.645 秒用例时间），4 次真实昵称更新后保留相同公开资料/成员版本，TLS 实时/历史和 HTTP 读取正确交付独立昵称版本，拉黑后不再交付；全部自有服务已退出。没有 schema 或 protobuf 变更，新增 JSON 字段仍属于当前同步发布的未提交 protocol 32 实现；不能据此推断混合旧部署兼容性。昵称失效事件、旧分页迁移和万人容量仍未完成。日志：`/tmp/im-resource-nickname-core.log`、`/tmp/im-resource-nickname-client-final.log`、`/tmp/im-resource-nickname-server-final.log`、`/tmp/im-resource-nickname-app.log`、`/tmp/im-resource-nickname-app-build.log`、`/tmp/im-resource-nickname-live-01/client.log`、`/tmp/im-resource-nickname-live-01/summary.json`。

- 真实原生资源链路增量：当前 Account、Gateway、图像 worker 产品构建通过；隔离的 PostgreSQL、双 Actor 进程、HTTPS Account、TLS Gateway 与实际 ClientKit 的 1 个集成 test / 1 个 suite 通过（1.522 秒为用例时间，不含构建与启动）。覆盖真实上传及 ready、资料绑定、独立实时与历史作者补充、头像字节校验、热缓存错误能力拒绝，以及拉黑后的双入口不可见；数据库汇总为 1 个 ready 个人头像、2 个变体、1 条拉黑关系。全部本次拥有的服务和数据库已退出。未改生产 Swift、协议、schema 或 App，未重复 App 构建，生产 CDN/万人容量仍未验收。证据：`/tmp/im-resource-live-authors-03/client.log`、`/tmp/im-resource-live-authors-03/summary.json`、`/tmp/im-resource-live-authors-03/build.log`、`/tmp/im-resource-live-authors-03-run.log`。

- 日志响应作者补充增量：Server 作者运行时/ingress/Gateway、Session、领域 handler、正文 FIFO、普通与预编码页面缓存/预算共 176 个 test 声明 / 11 个 suite 通过；ClientKit 作者线路/页面所有者/可见兴趣专项 32 项 / 3 个 suite 通过。新增服务端测试验证普通与预编码附件页在正文 writer 返回后才开始读取，81 条消息限制为 8 个去重作者；读取或写出挂起期间换 view 后旧请求不补充；未协商、未选页、拒绝、其他房间及写出失败不产生读取；16 条/64 KiB 取样上限、错误事件身份拒绝、预编码裁剪范围与新成员栅栏、冷热页面复用原编码字节。客户端通过实际 TLS 连接所有者和 protobuf transport 接收同批附件页与独立 delta，验证正文游标/媒体字段和作者消费者不混用；字节对端仍为受控替身。Gateway target 构建、静态 inventory（405 个文件 / 233 个 DTO）、协议文档、Markdown 链接（含未跟踪文档）及 `git diff --check` 通过。本轮未修改 Core/协议/schema/客户端生产代码，未重复运行 App 构建，也未将专项线路测试称为真实 App/远程 Actor/PostgreSQL 端到端或万人容量验收。日志：`/tmp/im-resource-author-page-server-final.log`、`/tmp/im-resource-author-page-client-final.log`、`/tmp/im-resource-author-page-gateway-build.log`。

- 作者运行入口装配增量：Server runtime/配置/Gateway/注册表等专项 96 个 test 声明 / 7 个 suite 通过，App worker supervisor 另 2 项 / 1 个 suite 通过。新增用例验证 read/write 非协作式挂起时真实排空、取消及并发关闭只关闭 reader 一次、启动期一次安装、可选连接名额耗尽不影响聊天、部署布尔开关解析。真实 PostgreSQL 资料专项 5 个 test 声明 / 1 个 suite 通过，新增 runtime → ingress/dispatcher → 实际资料 SQL → delta 路径，并验证后续拉黑仍重新授权及发送不可见；房间权威端口使用受控证明，不将其称为真实远程 Actor/TLS 端到端。App iPhone 18 Pro / iOS 27 Simulator 的资料头像、订阅和账户装配专项 14 项 / 3 个 suite 通过，Gateway target 与 App arm64 Simulator 构建通过。最终 Gateway target 再次构建通过；静态 inventory（405 个文件 / 233 个 DTO）、协议文档、Markdown 链接（含未跟踪资源文档）、Compose 环境优先级及 `git diff --check` 通过。此轮没有改变协议或 schema，没有启用实际部署或验证生产 CDN/万人网络负载。日志：`/tmp/im-resource-author-runtime-tests.log`、`/tmp/im-resource-author-assembly-postgres.log`、`/tmp/im-resource-author-assembly-app-tests.log`、`/tmp/im-resource-author-assembly-app-build.log`、`/tmp/im-resource-author-assembly-build.log`、`/tmp/im-resource-author-assembly-final-build.log`。

- 正文后作者交接增量：Server 作者 ingress/dispatcher/Gateway、正文 FIFO、连接重入、Session 和 codec 共 86 个 test 声明 / 8 个 suite 通过，Gateway target 构建通过。新测试覆盖实际同步/兼容群广播在正文之后补充作者、成员版本不匹配时两条路径都不投递、可选队列饱和时共享正文仍同步提交；真实 NIO 通道从不可写变为可写但正文尚未排空时仍拒绝补充，正文排空后再写独立 delta。ingress 验证一万次受控同步入队在挂起消费者后仅保留 256 项（255 排队 + 1 实际执行），其余 9,744 次明确拒绝；另验证 key 与计费字节上限、精确 view 合并、过期合并不续期、旧 view/已过期交接不能产生新读取，以及关闭/并发关闭等待非协作式实际消费者。这是可控单进程准入和线路正确性证据，不是实际万人网络吞吐或跨节点公平性证明。静态 inventory 为 402 个文件、233 个 DTO；本轮未改 Core/客户端/协议/schema。生产组合根的 reader/ingress/dispatcher 生命周期组装、指标与完整负载仍待完成，能力保持关闭。日志：`/tmp/im-resource-ingress-final-tests.log`、`/tmp/im-resource-ingress-gateway-build.log`。

- 精确 nonce 退出增量：protocol 32 双端重新生成，生成物与当前协议文档门禁通过。Core 全量 146 项 / 43 个 suite、ClientKit `--no-parallel` 全量 791 项 / 128 个 suite、Server 连接/分发器/codec 专项 64 项 / 5 个 suite 通过；随后新增旧连接替换测试，ClientKit 作者线路/页面专项 21 项 / 2 个 suite 通过（该新增用例不计入前述 791）。验证取消订阅的实际 socket 写入先于退出、等待期间换连接不向新连接发旧退出、取消页面仍执行并等待清理、并发关闭不提前释放实际任务、其他场景的房间消费者保留、stream/room/view 回显不一致拒绝、旧 nonce/其他房间退出不清除替代页、业务限流后仍允许无领域 I/O 的精确清理、退出回执前撤销待写许可以及迟到写出真正结束前保留槽位。Gateway target 和 App arm64 iOS Simulator 构建通过，文档链接（含未跟踪资源文档）、静态 inventory 与 `git diff --check` 通过。本轮未改数据库 schema，未运行生产运营商或真实万人网络压测；生产作者补充能力仍关闭。日志：`/tmp/im-resource-nonce-client-full.log`、`/tmp/im-resource-nonce-client-final-races.log`、`/tmp/im-resource-nonce-core-full.log`、`/tmp/im-resource-nonce-server-contracts.log`、`/tmp/im-resource-nonce-gateway-build.log`、`/tmp/im-resource-nonce-app-build.log`。

- 可见页面与提前补充增量：ClientKit 显式 `--no-parallel` 全量 788 项 / 128 个 suite 通过；新增 10 个可见页面仓库用例与 1 个协调器用例。验证资料早于行登记时直接消费且没有 HTTP、同页多个行令牌共享/重复释放隔离、新页面重新授权、64 项与 256 KiB 两种淘汰边界、原 lease 到期及独立 5 秒暂存期限、拒绝状态/候选被淘汰后旧 nonce 不能恢复访问、合并失效通知保留多个 key、同页滚动经过 2,025 个作者不被 256 兴趣上限卡死，以及 512 行令牌准入。另验证关闭时立即撤销已显示 grant，非协作式接收真正结束前仍不释放任务名额。App 在 iPhone 18 Pro / iOS 27 Simulator 执行 14 个 test 声明 / 3 个 suite，通过真实 PNG/缓存、共享页面两个可见行只读取一次 HTTP、新页面在缓存图片存在时仍重新授权、页面隐藏后迟到解码拒绝及按 key 的失效刷新；最终 App arm64 iOS Simulator 构建通过。静态 inventory、文档链接与 `git diff --check` 通过。本次没有改动 protobuf 或数据库 schema，尚未启用生产作者补充，不以这些模型/管线与受控传输测试代替完整聊天 UI、真实服务端投递或万人网络负载验收。日志：`/tmp/im-resource-visible-client-full.log`、`/tmp/im-resource-visible-client-verified.log`、`/tmp/im-resource-visible-app-tests.log`、`/tmp/im-resource-visible-app-final-build.log`。

- 作者页面协调增量：ClientKit 显式 `--no-parallel` 全量 777 项 / 127 个 suite 通过，相关专项 37 项 / 4 个 suite 通过。新增 8 个页面协调用例验证普通订阅确认之后才开始作者工作、入仓完成 HTTP 等待、续期保留展示、页面替换/并行关闭等待实际 ACK、重连与撤权恢复、未协商能力不反复尝试、非协作式接收排空、迟到限流对替代页面生效，以及缓冲合并撤权/恢复快照后仍使用新权限代次。真实 ClientKit protobuf/TLS 所有者与受控字节对端验证应答和 delta 同批到达后的入仓；客户端和 Server 分别验证其他房间的普通订阅不清除当前作者 view、同房间普通订阅仍清除。Server 相关 9 项 / 1 个 suite 及 Gateway target 构建通过。App 在 iPhone 18 Pro / iOS 27 Simulator 执行订阅/个人头像/账户作用域共 11 个 test 声明 / 3 个 suite 通过；回归曾暴露作者专用通知影响普通房间恢复顺序，隔离通知后重新执行通过。静态 inventory、文档链接与 `git diff --check` 通过。本次未修改协议 schema 或数据库 schema，尚未完成 App 页面共享 activation，也未开启生产作者通道或执行万人网络压测。日志：`/tmp/im-resource-page-client-final-full.log`、`/tmp/im-resource-page-client-scoped-notifications.log`、`/tmp/im-resource-page-app-tests-final.log`、`/tmp/im-resource-page-server.log`、`/tmp/im-resource-page-gateway-build.log`。

- 资料仓库与可见头像增量：ClientKit 显式 `--no-parallel` 全量 767 项 / 126 个 suite 通过，新增 13 个仓库回归用例覆盖旧页面与新需求隔离、请求发出后加入的 activation、推送与 HTTP 顺序、迟到明确拒绝及新 nonce、按 context 失效、首次等待期间失效通知、整批验证、展示/头像独立期限、缩短期限通知、关闭排空、迟到 429、部分 retryable 退避和版本倒退。App 在 iPhone 18 Pro / iOS 27 Simulator 执行 9 个 test 声明 / 3 个 suite 通过；新增个人头像测试使用真实 PNG 和文件缓存，验证缓存仍需当前页面授权、迟到解码不能跨失效/后台/关闭重新显示，以及资料变化后旧像素和旧名称不混入新快照。最终 App arm64 iOS Simulator 构建通过；静态 inventory、文档链接与 `git diff --check` 通过。本次没有修改协议或数据库 schema，未启用生产作者 delta，也未运行万人网络压测。日志：`/tmp/im-resource-profile-client-final-full.log`、`/tmp/im-resource-profile-app-tests.log`、`/tmp/im-resource-profile-app-verified-build.log`。

- 作者补充协议与连接增量：protocol 从 30 升至 31，两端 protobuf 重新生成，生成物与协议文档门禁通过。Core 全量 146 项 / 43 个 suite、ClientKit 显式 `--no-parallel` 全量 754 项 / 125 个 suite、Server 连接/分发器/codec 专项 61 个 test 声明 / 5 个 suite 通过。新用例覆盖能力协商/认证回显、正常订阅授权及应答写出之后才激活、拒绝订阅无资源读取、错误方向命令与未协商 nonce 拒绝、实际 NIO 拥塞丢弃且健康连接保留、退出/断开后的迟到写出失效与实际结束前保留名额、实际入队代次/期限/一次消费/取消栅栏，以及完整帧限制。客户端受控字节连接验证同批订阅应答与 delta、取消旧页后迟到应答、协商降级/非法回显、过大载荷关闭、8 帧/64 KiB 队列边界；共享接收器继续验证因果期限。另修正了新订阅/退出逻辑中的 UUID 大小写比较。Gateway target、App arm64 iOS Simulator 构建、静态 inventory、文档链接与 `git diff --check` 通过。本轮没有数据库 schema 改动，未运行真实万人网络负载；生产能力仍关闭，正文后生产投递与 App 接入尚未完成。日志：`/tmp/im-resource-author-client-wire-full.log`、`/tmp/im-resource-author-core-wire-full.log`、`/tmp/im-resource-author-server-wire-final.log`、`/tmp/im-resource-author-gateway-wire-build.log`、`/tmp/im-resource-author-app-wire-final.log`、`/tmp/im-resource-author-protobuf-check.log`。

已执行的本地证据：

- 作者补充组件增量（尚未接入实时运行路径）：Core 全量 146 项 / 43 个 suite、Server 专项 18 项 / 3 个 suite、ClientKit 专项 12 项 / 3 个 suite 通过。新增服务端组件用例覆盖独立查询/写出名额、输出反压、节点/连接/编码字节准入、重复与 distinct 作者合并、重新授权后才压缩、短 lease 不被过长提示抑制、连接替换与同房间重新进入、非协作式任务的超时/并行关闭排空、错接收者拒绝、429/NaN 退避边界、过大能力降为有界部分 retryable；同时复验已有真实 PostgreSQL 资料及同房间合批。客户端验证账户/设备/stream/view 隔离、重复 sequence、全因果耗时扣除、头像先到期时保留有效名称、30 秒接收窗口、pending 独立语义、过大载荷与永久关闭。Gateway target 和 App arm64 iOS Simulator 构建、静态 inventory、文档链接及 `git diff --check` 通过。没有修改 protobuf 或消息 schema；这些证据不证明真实 Gateway ACK、网络帧或 App 已消费 delta。日志：`/tmp/im-resource-author-core-causal.log`、`/tmp/im-resource-author-server-final-verified.log`、`/tmp/im-resource-author-client-causal.log`、`/tmp/im-resource-author-gateway-final-build.log`、`/tmp/im-resource-author-app-final-build.log`。
- 同房间多接收者合批增量：Server 16 项 / 4 个 suite、ActorRuntime 46 项 / 4 个 suite、ActorContracts 5 项 / 1 个 suite，共 67 项通过。两个新增 PostgreSQL 用例验证 50 个独立接收者 / 100 个目标项、退群/未来成员/非成员/房间类型隔离、同语句观察时间、原请求与 activation 绑定、成员变化后的重新读取、非法批次和旧 activation 拒绝；实际 lane + factory 在 reservation 释放后只取得一次 `interactiveRead` 准入。新增调度测试验证目标/字节/命令数量边界、过大单项拒绝、发送/写入屏障、排队期限和取消在途调用后保留整个批次额度；同时复验原有 host、reservation 与控制域测试。Account target 构建、静态 inventory（400 个文件 / 233 个 DTO）、文档链接及 `git diff --check` 通过。本次未改 SQL schema，未将本地真实数据库集成解释为远程 Actor、跨物理 owner 或万人吞吐证明。日志：`/tmp/im-resource-room-cohort-final.log`、`/tmp/im-resource-room-cohort-account-build.log`。
- 控制域多接收者合批与客户端退避增量：Server 14 个 test 声明 / 3 个 suite 通过；真实 PostgreSQL 在一条查询中验证 100 个不同接收者、双向拉黑、撤销/过期设备、账户与设备不匹配、停用账户和同一账户的两个设备，并通过实际合批 owner 执行并发 SQL。另覆盖队列/字节/批次上限、取消与超时后仍保留真实在途名额、并行关闭排空、关闭后拒绝准入、结果数量错误和签名期间权限变化。ClientKit 专项 6 个 test 声明 / 2 个 suite、显式 `--no-parallel` 全量 742 项 / 123 个 suite 通过；验证 429 头部边界、401/403 区别、页面/前后台重入、迟到 429、附加抖动、账户隔离及冷却后真实重读。Account target 与 App arm64 iOS Simulator 构建、静态 inventory、文档链接和 `git diff --check` 通过。上述证据覆盖控制域与客户端退避，不代表房间权威合批、跨节点合并或万人容量验收。
- 头像绑定、恢复交互与适配器增量：Server 本轮相关 35 个 test 声明已通过，包括群头像 17 项、个人头像绑定 4 项、资料展示 4 项及适配器合同 10 项。真实 PostgreSQL 覆盖绑定/GC 两种先后顺序、事务回滚、取得锁后的新时间观察、结构化群主变更与同物理数据库的 data-owner epoch 交接；个人头像另覆盖 8 种目录/变体准入、旧媒体兼容、保留已绑定头像及移除后的 120 秒保护。模拟器实际 UI 点击测试 1 项通过，覆盖账户入口、当前无群权限时查询/永久关闭、切后台、进程重启后保留关闭证明、放弃后列表清空及再次打开。修复了 Form 同行多按钮会触发错误操作的问题，并检查了运行截图。该 UI 使用 UUID 隔离的 DEBUG 本地账户、真实 SQLite/意图引擎和页面，远端授权/恢复由替身提供；未替代真实图片上传、真实退群、切账户或跨物理 owner 迁移验收。
- 账户级待处理群头像增量：ClientKit 显式 `--no-parallel` 全量 737 项 / 122 个 suite 通过；分页/意图/关闭/schema 专项 25 个 test 声明 / 4 个 suite 通过。新增证据覆盖同时间戳 70 条记录的游标顺序、翻页期间旧项完成不漏项、账户及游标隔离、页大小上限、部分索引升级与实际查询计划，以及快照替换后重启仍可列出未知操作。本地 schema 现为 227 个对象。App 在 iPhone 18 Pro / iOS 27 Simulator 执行 19 个 test 声明 / 5 个 suite 通过；覆盖批次替换、空页回首批、非协作式读取在重入时保留名额、账户关闭排空、同页突发通知不会饿死已完成结果、通知范围与失败恢复、超出房间窗口的精确操作定位，以及失去成员资格后的本人查询/关闭/放弃。App 构建、静态 inventory、文档链接与 `git diff --check` 通过。这些是 journal、服务和页面状态测试；尚未以真实 UI 点击验证全部图片选择、退群、重启及切账户流程。
- 群头像管理页与上传准入增量：ClientKit 显式 `--no-parallel` 全量 734 项 / 121 个 suite 通过；新增证据覆盖初次上传与命令的原子创建、幂等重放、冲突回滚，以及旧的永久关闭决定不会被已完成历史和分页上限遮住。App 在 iPhone 18 Pro / iOS 27 Simulator 执行 20 个 test 声明 / 7 个 suite 通过；新增管理服务/页面状态测试覆盖能力、角色、revision、受管路径准入，关闭后的新身份与原文件保护，失去成员资格后的本人恢复，错误设备与期限拒绝，页面退出后的迟到读取隔离，以及交接前后的文件取消差异。Server 群头像专项 12 个 test 声明通过；新增真实 PostgreSQL 的 5 种场景验证有效群主、权限证明前后的结构化群主/角色变化及拒绝后没有上传记录。Account target 和 App 构建、静态 inventory、文档链接与 `git diff --check` 通过。这些服务与状态测试不等于真实文件选择器点击、完整重启/退群 UI 或生产容量验收，上传 capability 仍关闭。
- 账户资源所有权增量：ClientKit 显式 `--no-parallel` 全量 732 项 / 121 个 suite 通过。新测试覆盖独立调用取消后直到真正完成才释放名额、并行重复关闭等待非协作式任务、关闭后拒绝新准入、失败/预先取消不消耗名额，以及上传引擎的能力读取与取消请求排空。App 在 iPhone 18 Pro / iOS 27 Simulator 实际执行 12 个 test 声明 / 5 个 suite，通过构造失败/提前返回的倒序清理、取消前接管拒绝、清理失败仍排空其余所有者、成功接管、真实 GRDB 导入取消及恢复循环的迟到结果隔离，并复验头像管线、下载和暂存生命周期。App 构建、文档链接、静态 inventory 与 `git diff --check` 通过；尚未以这些服务与构造作用域测试代替真实登录/退出/切账户的完整 UI 验收。
- 群头像可见展示与账户装配增量：ClientKit 显式 `--no-parallel` 全量 728 项 / 120 个 suite 通过。新增仓库测试覆盖同房间合并、页面重入重新授权、独立取消、非协作式旧请求不能释放名额或满足新页面、2 路并发及 activation 上限、本地更高版本栅栏、账户/设备/房间绑定、往返扣减后的单调双期限、拒绝/限流与网络故障区别、后台 epoch，以及明确拒绝/新版本/过时回复对已显示消费者的通知。另以真实 journal 事务验证本地 claim 不触发全局展示刷新，而房间版本事件仍触发。App 在 iPhone 18 Pro / iOS 27 Simulator 实际执行 11 个 test 声明 / 4 个 suite，通过真实 PNG 缓存仍需重授权、失效/后台/关闭后的迟到解码拒绝、下载和解码排空、退出后源文件与 journal 同步保留、重新进入只清理无引用草稿等测试。相关 App 构建、文档链接、静态 inventory 和 `git diff --check` 通过；未把管线测试等同于完整管理 UI、真实切后台/退群交互或生产万人容量验收。
- 群头像客户端关闭恢复增量：ClientKit 显式 `--no-parallel` 全量 717 项 / 119 个 suite 通过，专项为 25 个 test 声明 / 4 个 suite。新增证据覆盖恢复请求绑定与状态码隔离、丢失响应后原动作重试、请求落盘后重启不重提原命令、旧查询不能覆盖新 claim/关闭动作、在途提交与关闭竞争的两种结果、矛盾终态证明拒绝、关闭后过期文件保留及明确放弃、原子分配替代身份/重复点击幂等、上一版 journal 的在途 claim 升级。本地 schema 为 226 个对象，App arm64 iOS Simulator 构建、文档链接、静态 inventory（400 个文件 / 233 个 DTO）和 `git diff --check` 通过。App 尚未装配群头像恢复服务，这些证据不替代完整 UI 与生产分发验收。
- 群头像永久关闭服务端增量：Core 5 项 / 1 个 suite、Server 16 个 test 声明 / 3 个 suite 通过。真实 PostgreSQL 验证查询未找到不等于关闭、退群后的本人操作恢复、载荷冲突、关闭记录不可变、提交/关闭并发只产生一个终态，以及实际 advisory lock 等待后两个方向的新快照判断。恢复 HTTP 在真实同库和控制/房间分库都验证旧回执与关闭证明。canonical schema 初始化、导出/恢复与漂移检查通过（158 表 / 367 索引 / 31 触发器 / 28 函数）；App arm64 iOS Simulator 构建通过。
- 群头像持久管理意图增量：ClientKit 显式 `--no-parallel` 全量 706 项 / 118 个 suite 通过，包含 9 个管理意图 test 声明。新增证据覆盖账户/用途/room/media 绑定、重启后资源过期仍恢复原命令、取消准备与禁止取消已提交操作、旧 claim 失败隔离和迟到回执、崩溃不重置 5 次预算、页面独立取消、空快照保留未知结果，以及消息/群头像共享文件的删除前栅栏和文件删除后崩溃恢复。本地迁移增至 225 个 schema 对象；App arm64 iOS Simulator 构建、文档链接、静态 inventory 和 `git diff --check` 通过。ClientKit 恢复引擎尚未装配进 App，不以这些测试替代完整 UI 验收。
- 群头像管理 HTTP 增量：Core 4 项 / 1 个 suite、ClientKit 专项 12 项 / 3 个 suite、Server 10 个 test 声明 / 2 个 suite 通过。新增命令 HTTP 用例在真实同库与控制/房间分库分别执行，通过 RoomRef 客户端和真实领域执行器验证丢失响应后的原命令恢复、移除后重放旧回执、两类 409、资源/成员/设备拒绝及 8 KiB 请求上限；传输是测试注入，尚未替代远程 Actor 网络与 owner 迁移验收。另验证命令并发限流与失败释放。Account target 和 App arm64 iOS Simulator 构建通过；文档链接、静态 inventory（398 个文件 / 229 个 DTO）与 `git diff --check` 通过。
- 群头像读取/同步接入：ClientKit 显式 `--no-parallel` 全量 694 项 / 116 个 suite 通过，包含失效版本乱序/冲突/重启、快照较旧版本不覆盖新状态、退群清理、导入中数据库升级、HTTP 身份/大小/凭证隔离；本地 schema 为 221 个对象。Server 群头像 6 个 test 声明通过，HTTP 场景分别使用同库和真实分离的控制/房间数据库，验证匿名拒绝、空头像、已绑定头像及退群后拒绝。room-log 实际拉取返回群能力类型，未混入消息投影。
- 群头像/供应商抽象本轮：Core 专项 13 项 / 2 个 suite 通过；Server 专项 20 个 test 声明 / 7 个 suite 通过。真实 PostgreSQL 包含 12 个权限/资源拒绝场景、6 个群头像签发期间变化场景、5 个个人资料签发期间变化场景，以及原有群管理跨库的 8 个参数场景。还验证了同 operation 的 8 个并发请求仅提交一次、替换后重放原回执、不可变回执约束、引用保护/移除后宽限期、旧 activation 拒绝。
- 群头像 canonical schema 空库初始化、导出/恢复和漂移检查通过（157 表 / 366 索引 / 28 触发器 / 27 函数），包括绑定外键和不可变操作回执触发器。Core 解码校验展示/字节双期限、身份、代次和序号边界；服务端通过独立 delivery 测试替身签发，未依赖云 SDK。
- 之前 Core 全量 138 项测试通过；上述 13 项专项是群头像增量后的验证，未把之前全量结果视为本轮全量。
- 上一轮 Server 全量测试命令通过；六个测试产品分别报告 1293、2、58、20、36、3 项通过。本轮资源目录/转发变更以以下专项与 Gateway 构建验证；上述全量结果不代表本轮全部改动。资源专项使用真实 PostgreSQL；其他未配置的外部集成场景仍会跳过，不能据此宣称所有集成测试均执行。
- 资源专用 PostgreSQL 测试已连接本机临时测试库，覆盖上传、取消晚发布、同物理库不同逻辑 home 的独立导入、source hold 释放、资料授权，以及消息关闭与迟到接受的锁等待竞争。
- 100 个同图冷请求合并、热缓存伪造/过期能力拒绝、大文件流准入、原后端恢复和删除暂存后的 HTTP 下载测试通过。
- PostgreSQL canonical schema 在独立空库初始化、导出、恢复及漂移检查通过。新增检查覆盖资源幂等键、ready 变体非空摘要，以及永久关闭触发器的实际函数体。
- App 的 arm64 iOS Simulator 构建通过，包含永久关闭后的显式重试与结构化附件下载计划。
- ClientKit 默认并行全量运行出现计时断言与重连 deadline 失败；单独复跑通过。最终显式使用 `--no-parallel` 的全量 685 项测试通过，包含待确认展示、接受后暂存清理、永久关闭后的混合上传/导入附件重建与顺序、结构化传输计划和下载完整性。
- 资源/恢复/下载服务端专项 26 项测试通过，资源数据库场景连接真实 PostgreSQL。公开适配器 API、缓存身份隔离和慢源站期限检查均有执行证据。随后新增的批次关闭隔离及相关 Actor 批处理专项 23 项通过：直接发送拒绝关闭操作、原子批次完整回滚、逐项回退保留前后有效消息顺序、重放不重复接受。
- 本轮普通转发专项：4 个 suite 的 10 个 test 声明通过，其中数据库复制包含 18 个参数组合（3 种 owner 布局 × 6 种故障/恢复场景）。覆盖同分片、同库不同分片、真实源/目标分库；默认后端切换复用原输出；ACK 丢失不重读源；旧 claim 拒绝；删除未发布目标阻止迟到写入；源绑定期限到期后的跨 room 与同 room 转发。另验证图片转发无上传会话仍生成 320/1280 预览、原接受回执恢复、独立下载及重复投递不重复发消息。
- 新资源目录与复制输出表的 canonical 初始化、导出/恢复及漂移检查通过（155 表 / 362 索引 / 27 触发器 / 26 函数），包含用途/home 合法组合、复制意图与持久导入任务的外键约束检查。
- 普通转发阶段最终资源、恢复、下载及路由相关测试共 35 个 test 声明 / 11 个 suite 通过，含上述 18 个复制参数组合和首次复制自动建立输出意图。旧转发字节/恢复测试在另外两个空库实际执行 19 个参数场景并通过，涵盖 EICAR、碰撞、大小、租约、压缩和源 GC。Gateway 构建通过；文档链接/结构、静态 writer inventory 和 `git diff --check` 通过。这是群头像 HTTP/客户端投影变更之前的基线。

以上按增量保留历史验证，历史段落中的未完成项以顶部当前状态和下面的缺口表为准。工作日志位于本机 `/tmp/im-resource-*.log`，不是可长期保留的发布证据。正式交付时需要重新整理可复现命令与最终结果。

## 完整范围中尚待完成的工作

| 工作 | 必需完成条件 |
| --- | --- |
| 统一新模型 | 已移除草案回填、provider 回退、无目录绑定/授权旁路、运行时旧上传路由和 App 上传回退；个人头像预览使用展示租约。下载 HTTP DTO 已统一为必需计划；ClientKit 旧上传编排与 URL-only 内存构造器已删除，本地 SQLite 已收敛为一次完整建表。旧业务上传 HTTP API 和 DTO 已删除；旧上传目标兑换服务、底层 grant/store、命令 DTO 与两张旧表已删除；继续审查其余裸媒体测试构造器，不验收旧版本混跑 |
| 群头像 | 事务/授权/读写与关闭 HTTP、ClientKit 意图/证明恢复/显式替代、失效投影、App 可见展示/管理页/账户级待处理入口及恢复、上传准入的结构化群主复核已实现；仍需跨 owner 与并发 GC 完整验收、真实图片选择/重启/退群后恢复的 UI 流程；此前保持上传 capability 关闭 |
| 作者资料分发 | protocol 32 协商、完整帧/NIO 边界、Gateway reader/ingress/分发器装配与生命周期、活动页面日志响应中的附件/引用/历史作者有界补充、TLS nonce 队列、HTTP 顺序、实际页面接收/续期、多房间协调、App 群/私聊共享 activation 与兴趣、群提前补充消费、独立版本群昵称读取/展示与持久失效事件已实现；真实 ClientKit → Gateway/Account → Actor → SQL/字节路径通过。私聊主动补充、房间成员授权和 App 订阅/兴趣查询键已接入并执行本地测试；仍需其余旧资料入口授权迁移、其他历史/个人同步及编辑事件入口、导出指标与本地 ACK/正文隔离测试。生产和实际 App 全链路验证按本阶段要求后置 |
| 跨接收者授权合批 | 控制域批量 SQL 与同房间 Actor 相邻读取合批已接入，保留各请求权限和屏障；仍需跨房间物理 owner 合并、指标导出、跨 owner/远程网络场景及端到端压力验收，不能以当前局部证据代表完整链路 |
| 万人突发 | 真实边缘鉴权、共享缓存键、同键请求合并、上层缓存或等价回源保护，10k 冷启动/撤权/过期/故障压测及业务 ACK 隔离指标 |
| 运营商接入与迁移 | 独立 storage/delivery 端口、配置版本解析、稳定 VariantID、导入精确快照，以及同 home 迁移持久输入/输出、复制恢复、条件切读与保留保护已接入；仍需生产适配器、迁移运维/恢复装配、晚签发/在途读取排空、退役与取消清理、旧配置退休及完整验收 |
| 转发补充验收 | 新资源主路径已迁移；补齐 owner 迁移与大批量公平性、统一模型的部署验收，不将当前局部矩阵视为全部生命周期证明 |
| 扩展传输 | 持久 part 状态、原生上传状态核对、分片 finalize、取消残留清理、Range 与平台后台恢复后再开放能力 |
| 扩展处理 | 图片/动图/视频/语音产物、资源 descriptor、生产扫描器、受限 Linux worker 的真实运行与故障验收 |
| 客户端完成项 | 全部资料入口的权限上下文；成员搜索；当前播放/分享/解码文件借用及模拟器生命周期已接入，仍需真机锁屏、实际外部分享扩展、iPad 和大文件空间验收；关闭后重建的完整 UI 场景；账户构造与资源任务排空已补齐，仍需真实登录/退出/切账户及全部新旧界面写入竞争的集成验证 |
| 生命周期 | 群头像的同库真实锁等待、绑定/GC 两种顺序、回滚及 owner epoch 交接已补充；个人头像已补齐新资源绑定期限、当前 generation/完整变体核验与旧头像下载保护期。仍需多物理 owner 的作业与公平性、配额结算、其余绑定/GC 与跨库未知结果 hold 矩阵 |
| 最终交付 | 完整需求审计、最终构建/相关测试/仓库检查、部署说明和清晰限制；本次为阶段性代码提交，尚不代表完整功能交付 |

功能实现继续按完整方案推进；生产和真实端到端验证按用户最新要求后置，不将其作为当前开发完成的前提，也不将“基础链路已可运行”视为所有功能已经完成。
