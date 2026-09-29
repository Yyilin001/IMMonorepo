# 服务端解耦优化方案

状态：代码改造、macOS 编译及本机 Linux 应用栈定向验证完成，整体验收未完成。真实远端服务器已停机，当前验证只使用本机隔离环境；性能对照与完整故障矩阵仍待执行。下方整体验收清单仍保留。依据 2026-09-28 工作区代码检查制定。当前改动、验证与缺口见[实施状态](server-decoupling-progress.md)。

## 1. 目标与实施范围

让 HTTP/TLS 入口、应用用例、房间执行、持久化和运行资源组装拥有清晰且可验证的边界。完成后，应用用例可以脱离 PostgreSQL 测试，数据库实现可以独立演进，模块依赖由 SwiftPM 强制约束。

本轮采用行为等价的渐进重构。HTTP/protobuf 协议、持久化数据格式、幂等身份、部署角色和数据库 schema 延续当前合同。确需改变这些合同的发现单独立项，避免混入结构重构。

现有 RoomWrite 已完成 SQL、行解码和部分事务内路径抽取。本轮从该结果继续推进；事务协调器持有 PostgreSQL、工厂组装具体实现本身是合理职责。判断是否需要拆分，以变化是否跨越业务边界、是否阻碍独立验证为准。

### 当前依据

- [现有 RoomWrite 拆分记录](../reviews/room-write-store-decomposition.md)
- [房间 Virtual Actor 合同](../reviews/room-virtual-actor-contract.md)
- [当前系统地图](../current-system-map.md)
- [服务端 Package.swift](../../IMV2Server/Package.swift)
- [资源系统实施记录](resource-system-implementation.md)

## 2. 需要解决的问题

| 区域 | 当前耦合 | 目标 |
| --- | --- | --- |
| Resource Application | resolver 返回具体 PostgreSQL Store；应用服务读取表、解析数据库状态 | 用例依赖业务操作接口和强类型快照；SQL 与持久化映射归适配器 |
| HTTP operation routes | social、account preference、direct room、group creation 路由依赖具体 Store | 路由只做身份提取、输入检查、调用用例及响应映射 |
| Room executors | Messaging/Administration 等直接组装并调用具体 Store | 业务调度依赖限定能力；事务适配器承担数据库执行；工厂集中组装 |
| RoomWrite | 控制侧授权、路径选择、事务内写入、缓存与额度收尾集中 | 明确输入、事务内结果及提交后责任，复用已抽取路径 |
| Gateway handler | protobuf 映射、命令分派和数据库准入协调集中 | 按命令族划分 handler，明确准入由入口还是 Host 负责 |
| Package | 大量逻辑同处 IMV2Server，目录无法约束访问 | 建立单向 target 依赖，迁移结束后关闭旧模块旁路 |

## 3. 必须保持的正确性约束

1. 消息或持久拒绝与授权证明在同一事务提交或回滚。每次写入在实际 owner 连接上校验完整 activation token。
2. 保留 room/admission 锁顺序、多房间确定性排序及条件式分片额度预留的位置。事务内路径只借用连接，不自行开启事务。
3. 缓存发布和已消耗额度结算遵循当前提交后顺序；失败及回滚时按现有合同处理额度，不能重复释放。共享缓存、批处理器与额度池保持 owner 级身份。
4. COMMIT 应答丢失及提交后失败继续按结果不明处理；重试以原 operation ID 恢复事实。不能把未知提交变成新一次写入，也不能通过反向数据库补偿撤销已接受消息。
5. 资源的设备、成员、owner 和 generation 授权仍在要求的事务内重查。远程签名、复制和扫描期间不持有数据库锁；I/O 后继续校验期限和权限。
6. 截止时间覆盖排队、借连接和实际执行；调用者取消不代表底层工作已经结束。在途工作、许可、租约与数据库资源按真实完成顺序排空。
7. 已完成操作的回放保持现有指纹和结果语义；后续权限变化的处理服从各用例合同。

这些要求应成为接口契约和测试断言。应用层无需看到 SQL，但适配器必须拥有实现这些要求所需的完整上下文。

## 4. 目标模块结构

下列新增名称为规划名称，落地时可按仓库命名调整。先完成职责收敛，再逐个迁移 target。

| 模块 | 职责 | 允许的主要内部依赖 |
| --- | --- | --- |
| IMV2Core | 现有跨客户端/服务端共享领域值与规则 | 维持现有基础依赖 |
| IMV2ServerContracts（新增） | 服务端用例请求/结果、能力接口、资源状态及错误语义 | Core；必要的 ActorContracts 身份类型；纯签名/摘要验证所需 Crypto |
| IMV2ServerApplication（新增） | 资源、账户、房间用例和独立业务策略 | ServerContracts、Core、必要的 ActorContracts；按需 Crypto/Logging |
| IMV2ServerInfrastructure（新增） | PostgreSQL、事务围栏、数据库 worker、对象存储/NATS 适配、连接池 | Contracts、Application 及对应驱动 |
| IMV2ServerGateway（新增） | TLS/NIO、protobuf 映射、网关命令分派 | Contracts、Application、Core 及网络库 |
| IMV2ServerHTTP（现有） | HTTP 路由、middleware、错误/响应映射 | Contracts、Application 及 HTTP 库 |
| ActorContracts/Runtime/Cluster（现有） | 现有 Actor 契约、调度与集群传输 | 延续当前方向，不依赖 Server 基础设施 |
| IMV2ActorApplication（现有） | Actor 节点生命周期及具体执行器组装 | Actor 模块、Contracts/Application/Infrastructure |
| IMV2Server（收敛后的现有模块） | 服务端配置、资源组装、启动与关闭协调 | 以上需要组装的模块 |
| 三个 App executable | 各自进程角色入口 | Server 组装入口及角色所需模块 |

依赖方向：传输适配层调用用例；用例通过 Contracts 中的能力接口调用适配器；组装层注入具体实现。业务判断不回流到组装层。底层模块均不得依赖收敛后的 IMV2Server。

先使用这几层 target，业务域在层内以目录组织。跨模块必要类型优先使用 `package`，对外产品 API 才使用 `public`。Contracts 中的接口签名不出现 Fluent Database、SQLDatabase、PostgresConnection、Vapor Request、NIO Channel 或具体 Store。

对剩余同步、账户、推送、审核、恢复 worker 逐项确定归属：跨能力编排放 Application，SQL 轮询及事务实现放 Infrastructure，启动/停止注册放组装层。迁移清单必须覆盖所有源码，避免旧 IMV2Server 长期成为杂项集合。

## 5. 分阶段执行

### P0：建立基线与依赖清单

工作：

- 记录源码 commit、未提交改动、工具链、数据库与负载配置。
- 列出入口 → 用例 → Store → 数据表/外部服务的实际依赖，标注事务、锁、缓存、额度、截止时间和资源所有者。
- 标明哪些接口已经存在，优先复用；记录当前测试、缺口及 opt-in 环境变量。
- 运行相关现有测试，记录失败和跳过；采集发送热点的吞吐、P50/P95/P99、连接池等待、SQL 次数、CPU、内存和批次大小。
- 增加架构检查：先冻结已有违规清单，禁止新增越层依赖；每完成一区域就移除其例外。

交付：依赖清单、测试矩阵、可复现基线、初版架构检查。

通过标准：每一处拟拆分职责都有现有调用者、所有者和验证入口；历史测试记录与本轮实测分开。

### P1：资源应用层解耦

工作：

1. 将 ResourceStoreResolving 的返回值改为生命周期能力接口，覆盖创建、读取、领取 finalize、完成/失败等实际操作；保留必要的原子操作粒度。
2. 将数据库 row 映射为强类型上传快照。上传状态与媒体状态分别建模，数据库字符串映射集中在适配器；未知状态显式报持久化错误。
3. 群头像服务中的设备/账号 SQL 移入授权读取适配器；profile presentation、import source resolver、migration 一并检查和迁移。
4. 将 owner 数据库选择封装到资源路由适配器，应用接口传逻辑 home、身份及授权上下文。SQL 授权闭包继续留在 Infrastructure 内部。
5. 保留上传传输、分发、扫描、转换已有协议；注入确有测试需要的时间和 ID 生成能力。

验证：生命周期、重复提交、并发 finalize、generation 冲突、claim 过期恢复、签名前后设备撤销/owner 变化、过期 lease、迁移与跨 home 导入。接口替身验证用例顺序，真实 PostgreSQL 验证原子性。

通过标准：Resources/Application 无 SQL、数据库句柄、具体 PostgreSQL Store 或持久化状态字符串；应用用例可在无数据库条件下测试。应用协议不提供通用 transaction 闭包。

### P2：HTTP 与 Gateway 入口收敛

工作：

- 为 social、account preference、direct room、group creation 定义或复用窄的用例接口。简单路径允许现有 Store 直接实现接口；有编排时再设应用服务。
- 路由保留认证提取、actor 绑定、解码、body 限额、HTTP status/header 映射；领域授权由用例/持久化权威继续保证。
- 将 GatewayDomainCommandHandler 按消息操作、已读、房间查询、同步、瞬时活动拆成处理组件；顶层负责分派。
- protobuf 映射和精确帧预算留在 Gateway。将工作准入收敛为明确能力或类型配置，逐条确认入口与 Host 的责任，防止重复获取或漏获取许可。

验证：各路由的成功/拒绝/延后/恢复、身份不匹配、取消、Retry-After/no-store；网关消息映射、帧限额、错误码和准入释放。保留既有接线集成测试。

通过标准：HTTP 不依赖具体 Store；Gateway 命令族可单独测试；每类命令的 admission 所有者唯一且可追踪。

### P3：房间执行器与组装边界

工作：

- 按 Messaging、Administration、Queries、Receipts、MediaAuthorization 逐项提取执行能力，避免一个覆盖全部房间业务的巨型协议。
- 工厂创建已绑定激活上下文的能力；业务执行器只做对应命令的校验、编排和结果映射。
- 具体 SQL/fence 执行器归入 Infrastructure。适配器直接接收命令并原子执行合理时，可保留这种实现，不额外复制业务流程。
- 明确 context 中的 token、deadline、容量配置及稳定操作身份。已有类型满足要求时直接复用；禁止用一个携带所有服务的 context 隐藏依赖。
- owner 共享连接池、批处理器、缓存和额度池仍由工厂/运行资源所有者管理，激活关闭仅退休自身代次状态。

验证：同房间 FIFO、错误房间/token、owner 变化、激活恢复失败、租约失效、旧代次迟到关闭、批处理、取消与 shutdown。实际 token fence 仍由 PostgreSQL 测试覆盖。

通过标准：纯业务执行器不构造 Store；具体数据库实现和生命周期组装位置明确；Runtime/Cluster 不增加服务端业务依赖。

### P4：RoomWrite 职责拆分

按现有实现逐条迁移，保持一个权威写入流程。建议的职责划分如下，类型名称在实施时确定：

| 职责 | 输入/输出与限制 |
| --- | --- |
| 授权协调 | 读取控制事实、预留持久授权，返回明确 grants；保留 owner 提交后的证明核对与 ACK 顺序 |
| 路径选择与准备 | 依据已验证输入选择 scalar/direct/batch/forward 路径，输出不可变准备结果 |
| 事务协调 | 唯一负责借连接、事务、fence、锁顺序、授权回执、最终分片预留及提交分类 |
| 事务内路径 | 复用现有 preflight/append/persistence 组件，显式借用事务连接；返回结果和提交后需要的信息 |
| 提交后处理 | 对应确切 token 结算额度、发布缓存/观察结果、执行原有 ACK；保留失败恢复责任 |

执行顺序：先明确提交结果与作用域类型，再抽授权协调，随后逐条迁移 scalar、direct fast/batch、hybrid batch、forward，最后删除过渡入口。

重点处理现有 `usingOperationTransaction`、`usingActivationScope`、`usingAuthorizationGrants` 等组合状态：通过显式作用域与已准备输入限制非法组合，明确事务由当前操作还是外层 operation receipt 拥有。外层事务尚未提交时，子组件不能宣布已提交或运行提交后结算。

保持现有三事务转发流程、控制库/owner 库边界与持久恢复记录；不新增分布式事务。事务内组件内部可使用具体类型，热路径无需为每个函数增加动态协议调用。SQL 文本和命名 prepared statement 原样迁移。

验证：正常接受/持久拒绝、重复指纹/冲突、scalar 与 batch 等价、陌生人额度、锁竞争、owner/activation fence、多数据库授权、COMMIT 应答丢失、进程 SIGKILL、forward 恢复、额度只结算一次、缓存仅在正确提交边界发布。

通过标准：事务内路径无法自行提交或修改提交后缓存；授权协调和写入路径可独立检查；原有故障语义及热点性能基线满足验收。文件行数只作辅助指标。

### P5：用 SwiftPM 固化边界

工作：

1. 迁移 ServerContracts 及其最小值类型，先解决循环引用，不把服务端专用接口塞进 Core。
2. 迁移 Application，再迁移 Infrastructure，确保适配器只向内依赖。
3. 将 HTTP/Gateway 改为依赖新模块；调整 ActorApplication 的具体组装引用。
4. 收敛 IMV2Server 的配置、启动和关闭入口；迁移三个进程、probe、worker 和测试 import。
5. 删除过渡 typealias、转发 façade 和违规白名单，收紧 package/public API。

允许每次只迁移一个完整业务切片；每个提交必须可构建。架构检查先限定已迁移路径，再逐步扩大到全部目标。

通过标准：SwiftPM 无循环依赖；HTTP/Gateway/Application 无越层依赖；既有 Linux release 产品矩阵及变更影响到的 worker/probe 均构建；三种服务角色的生命周期检查通过。

### P6：整体验收与文档收口

- 执行完整受影响测试、跨数据库和独立进程故障验证，逐项核实实际执行数及 opt-in 条件。
- 覆盖真实本地 Host、远端 Host、caller-only Gateway/Account 与独立 Operator 接线。
- 使用与 P0 相同的环境和负载重复测量，解释吞吐/延迟、连接池及内存差异。
- 更新 current-system-map、RoomWrite 拆分记录、模块依赖说明与运行说明，记录最终证据。
- 删除过渡实现；确认每个 worker、共享资源与关闭步骤有唯一所有者。

通过标准：第 8 节清单全部满足。未运行的外部服务或故障场景明确列为验收缺口，不能以普通测试全绿替代。

## 6. 验证入口与性能标准

现有测试入口：

- [服务端原生 PostgreSQL 测试脚本](../../scripts/test_v2_server_native_postgres.sh)：创建五个独立的可丢弃数据库，支持透传 `--filter`，以串行方式执行共享 schema 的测试。
- [CI 工作流](../../.github/workflows/verify.yml)：Linux 工具链、release 产品矩阵及额外故障测试的 opt-in 配置。
- [现有服务端测试目录](../../IMV2Server/Tests/IMV2ServerTests)：资源、网关、RoomWrite、Actor fence/取消/应答丢失等测试。
- [Actor 台账检查](../../scripts/check_v2_virtual_actor_inventory.py)：涉及能力入口和执行位置迁移时同步更新并运行。

每个小步骤运行相关检查；模块迁移和最终集成时执行完整受影响矩阵。P0 先识别已有失败，重构过程中及时修复新增失败。原生测试脚本并不自动开启所有故障测试，按 CI 与对应测试源码核对额外环境变量。

性能验收采用相同构建模式、数据量、机器、连接池及负载，固定预热后至少重复三次。建议以吞吐下降超过 5% 或 P95/P99 增长超过 10% 作为调查门槛；P0 根据噪声及现有容量要求固定最终阈值。稳定超限须修复或提供明确原因及另行接受的预算，不能直接宣称通过。关注 SQL 次数、锁等待、批次合并率与分配量的变化；不预先承诺性能提升。

## 7. 提交组织与风险处理

建议组织为约 12–16 个可独立验证的提交组/PR，实际按代码量调整：

1. 基线与架构检查。
2. 资源生命周期接口、快照与状态映射。
3. 资源展示/授权/路由、导入与迁移适配。
4. HTTP operation 接口和路由接线。
5. Gateway 命令族与 admission 边界。
6. 房间执行能力与工厂组装。
7. RoomWrite 作用域和提交结果类型。
8. RoomWrite 授权协调。
9. Scalar 路径职责收敛。
10. Direct 与 hybrid batch 路径收敛；必要时分别提交。
11. Forward 路径与提交后处理收敛。
12. Contracts/Application target 提取。
13. Infrastructure/Gateway/HTTP 及进程接线迁移。
14. 最终回归、性能比较、删除过渡层与更新文档。

顺序为 P0 → P1 → P2 → P3 → P4 → P5 → P6。需要提前移动少量共享类型时，在对应业务切片中完成最小迁移，避免临时循环依赖。

| 风险 | 应对方式 |
| --- | --- |
| 抽接口后将鉴权移出事务 | 接口表达完整原子操作；PostgreSQL 并发与撤销测试验收 |
| 误把外层事务内成功当成提交 | 明确事务所有者与完成状态；应答丢失/外层回滚测试 |
| 重建缓存/额度池改变身份 | 共享资源只由 owner 工厂创建；旧代次清理和余额测试 |
| 再次获取准入许可导致死锁/吞吐下降 | 标注入口与 Host 的唯一所有者；检查获取、释放、取消路径 |
| target 拆分产生循环 | 接口和值向内归属，适配器向外归属；禁止底层回调导入旧 Server |
| 以过度抽象增加热路径成本 | 内部路径优先具体类型；用性能基线验证 |
| 仅改文件位置，职责仍共享 | 检查依赖签名、可构造状态和测试隔离，禁止只以行数验收 |

各阶段以可构建、可测试提交为回退点；结构重构出现问题时回退对应代码批次。持久业务结果继续由原 operation ID 和恢复流程处理。过渡适配器采用单一路径委托，不对真实业务请求双写以做比较。

## 8. 最终完成清单

- [x] Resources/Application 不包含 SQL、具体 PostgreSQL Store、数据库句柄或数据库状态字符串判断。
- [x] HTTP 路由和 Gateway handler 通过业务接口访问用例，传输细节留在适配层。
- [x] 房间业务执行器与 PostgreSQL 事务适配器分工明确，工厂集中管理具体实现和资源身份。
- [ ] RoomWrite 的授权协调、事务内路径、提交分类和提交后处理职责明确，保留全部一致性合同。
- [x] 依赖方向由 SwiftPM 和架构检查约束；过渡接口与例外清理完成。
- [x] 同步、账户、推送、审核和恢复 worker 均有明确模块与生命周期归属。
- [ ] 相关行为、并发、跨数据库、崩溃恢复、Linux 构建和关闭验证实际通过。
- [ ] 性能结果与可复现基线对照，重大回退已解决。
- [ ] 文档反映最终实现，剩余验收限制明确记录。

上述勾选表示已实现并取得对应结构验证证据；未勾选项目仍需验收。分批构建和测试结果见[实施状态](server-decoupling-progress.md)，外部环境及故障 opt-in 见[验收矩阵](server-decoupling-validation.md)。历史通过记录不替代本轮执行，也不代表整体解耦已经完成。
