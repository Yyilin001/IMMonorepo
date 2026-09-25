# 测试有效性治理：首轮盘点与判定规则

审阅日期：2026-09-25。范围为当前工作区的 Swift 测试源码；本记录是测试治理台账，不是全套业务验收结果。工作区已有的文档与 Server 改动不属于本轮测试结论。

## 判断标准

“编译通过”只证明类型、访问控制、泛型约束和穷尽性等静态条件。即使输入已经是强类型，自定义初始化器、计算属性和协议适配器仍可能在运行时错误地校验、转换或保存值。每项测试先写出**它能发现而编译不能发现的故障**，再决定去留：

| 分类 | 处理 | 例子 |
| --- | --- | --- |
| 纯静态保证 | 删除运行时断言，保留生产调用方的编译覆盖 | 两个不同的无关联值 enum case 由编译器合成的 `Equatable` 比较必然不等；同一强类型参数不能以其他 ID 类型传入 |
| 构造、解析和弱输入边界 | 保留针对有效值、拒绝值与临界值的测试 | `UInt64` 到 PostgreSQL `bigint` 的范围、JSON/protobuf/SQLite 解码、URL 与文本策略 |
| 领域决策与状态变化 | 保留结果和无副作用断言 | 授权、准入、幂等、取消、重试与版本竞争 |
| 跨进程、存储、网络或 UI 边界 | 保留该边界的独立证据；若两个测试走同一入口和断言，再合并 | 数据库事务回滚、实际序列化、连接生命周期、页面可见状态 |
| 只回读固定输入或重复同一边界 | 查找唯一故障信号；没有时删除或合并 | 第二份相同构造器的固定值回读测试 |

删除前必须对照生产实现和其他测试；仅凭测试名短、断言少、没有直接 `#expect`，或与另一层名字相似，均不能判为无效。特别是“非法状态不可表示”成立的前提是所有入口只能构造受限类型；若类型仍有公开原始值初始化器、解码器或数据库恢复入口，应测试这些弱输入边界。

## 首轮证据

清理前的源码盘点有 Core 40 个测试 Swift 文件 / 129 个 `@Test`、Compression 1 / 8、ClientKit 110 / 669、Server 254 / 1387、App 单元测试 38 / 237。文件和注解数量只用于安排审阅工作量，不代表有效性或覆盖率；App 的 UI/E2E 目标另行审阅。

本轮用静态筛选找出没有直接断言的参数化测试，并逐一检查：ClientKit 的 `V2ProjectionRecoveryBoundsTests` 和 `V2PendingCommandRecoveryBoundsTests` 共 4 个入口把断言放在共享辅助函数中；Server 的 `V2AccountRoomGatewayTests.protocolLifecycle` 委托给完整协议场景，`V2ActorAuthenticationTests.readerCandidateAdmission` 以认证是否抛错验证入口。它们均不是“无断言即可删除”的证据。按规范化函数体搜索未发现完全相同的 `@Test` 实现，但不能据此排除语义重复。

| 结论 | 证据与处理 |
| --- | --- |
| 已删除一项重复的固定值回读测试 | `MessageWithdrawalTests.commandValue` 只构造一个合法 `V2WithdrawMessageCommand` 并回读版本 `1` 与操作 ID；同一构造器的越界拒绝、合法版本 `1`/`Int64.max` 的接受与精确保存已由 [`CommandRevisionBoundsTests`](../../IMV2Core/Tests/IMV2CoreTests/CommandRevisionBoundsTests.swift) 验证。操作 ID 的领域类型由签名约束，原测试没有额外的跨边界故障信号。此处是**重复证据**，并非声称编译器会验证自定义初始化器的所有赋值。 |
| 已删两条纯类型恒真断言 | [`V2RoomRequestTests`](../../IMV2Server/Tests/IMV2ActorContractsTests/V2RoomRequestTests.swift) 中两个不同无关联值的 response case 不等断言。保留同一测试的 JSON round-trip，后者证明运行时编码、解码与区分结果，编译不能替代。 |
| 已收窄一项测试宣称 | [`V2ActorAuthenticationTests`](../../IMV2Server/Tests/IMV2ActorClusterTests/V2ActorAuthenticationTests.swift) 原 `readersPrivacyBoundary` 只证明签名后的候选查询通过 Actor 会话认证，并未执行控制面的隐私过滤；测试现按实际证明范围命名。隐私过滤由 `V2RoomRefClientsTests` 及 PostgreSQL 集成场景另行覆盖。 |
| 保留领域边界测试 | [`MessageMutationResultBoundsTests`](../../IMV2Core/Tests/IMV2CoreTests/MessageMutationResultBoundsTests.swift) 覆盖零、`Int64.max` 与溢出值；[`V2ProfileStorageTypesTests`](../../IMV2ClientKit/Tests/IMV2ClientKitTests/V2ProfileStorageTypesTests.swift) 注入 SQLite `REAL` 并核对失败时事务状态。这些故障由运行时数据决定。 |
| 保留看似旧模型的状态测试 | [`V2MessageProjectionStateTests`](../../IMV2Server/Tests/IMV2ServerTests/V2MessageProjectionStateTests.swift) 名称含“projection state”，但生产写入、编辑、撤回、内容审核和消息版本仓库仍引用该状态类型；它不是可按旧扇出名称直接删除的孤儿测试。 |
| 保留协议和认证测试 | [`V2ActorAuthenticationTests`](../../IMV2Server/Tests/IMV2ActorClusterTests/V2ActorAuthenticationTests.swift) 虽使用类型化请求，仍实测签名篡改、重放、权限和会话上限。测试名称中的“typed”不等于编译期即可证明。 |
| 修复一项并发测试的虚假失败 | [`V2GatewayDomainCommandHandlerTests`](../../IMV2Server/Tests/IMV2ServerTests/V2GatewayDomainCommandHandlerTests.swift) 中 room-log 预留测试用 5 毫秒等待队列跨过 handler 构造与调用；并行测试负载下等待者可能提前超时，随后无条件释放未持有的许可并触发 precondition。将该测试的排队期限放宽至 5 秒，并仅在确实获准时释放许可；队列已满时的 handler 响应仍须立即断言为 `SERVER_BUSY`。 |

## 后续逐项审阅顺序

1. **Core 与 ActorContracts：** 对每个值类型测试标注静态保证、运行时校验或值变换。优先合并纯字段回读；保留解析、错误、边界和状态机用例。
2. **ClientKit：** 从 `*BoundsTests`、DTO 与 SQLite 恢复测试开始，核对同一约束是否分别由 Core 构造、wire 解码和数据库恢复独立触发。不同弱输入入口不因规则相同而视为重复。
3. **Server：** 对服务单测和 PostgreSQL 集成测试做“入口—提交点—失败信号”映射。只删除同一入口、同一故障注入、同一可观察结果的重复用例；保留真实事务、路由和恢复证据。
4. **App、UI/E2E：** 检查 Store 测试是否只验证同步转发，以及 UI 测试是否覆盖用户可见的状态或系统交互；按实际设备与权限边界保留必要验收。

每次清理记录被删测试、原断言、保留下来的证据和所运行的最小验证。若独立故障信号不能证明重复，暂列“待核对”，不按文件数或测试数设删除指标。

## 测试框架边界

Core、Compression、ClientKit、Server 及 App 的常规单元测试均以 Swift Testing 编写。`IMAppLocalAccountE2ETests` 是 UI automation target，Xcode 在该 target 中将 `Testing` 映射为 `_Testing_Unavailable`，不能直接把 `@Test` 与 `XCUIApplication` 用例放在同一 target。其 7 个不启动 App、只验证 HTTPS、TLS、SQLite 和 gateway 行为的用例已迁入 [`IMAppTests/LocalAccountIntegrationTests.swift`](../../IMApp/IMAppTests/LocalAccountIntegrationTests.swift)。本地 E2E 共享 scheme 同时包含 Swift Testing 单元 target 和 XCTest UI target；集成套件仅在该 scheme 的 `IMV2_LOCAL_ACCOUNT_E2E=1` 环境下启用，普通 App 测试不会依赖本地服务。

仍使用 XCTest 的用例均有 UI 自动化调用：本地账户注册及单侧提示重启恢复直接使用 `XCUIApplication`；房间恢复压力用例的可选 `IMV2_ROOM_RECOVERY_APP_RECONNECT` 分支使用 `XCUIApplication`、截图附件和前台自动重连验证。其余两个 UI target 同样操作应用窗口。后续若将房间恢复压力用例拆为独立的纯传输测试与 UI 自动重连测试，可再把前者迁到 Swift Testing；目前保留原有联合 E2E 的验收路径。

迁移验证：`xcodebuild build-for-testing -project IMApp/IMApp.xcodeproj -scheme IMAppLocalAccountE2E -configuration Debug -destination 'generic/platform=iOS Simulator' -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO` 通过；普通 `IMApp` scheme 只选择新集成套件时，7 项均按预期跳过且测试命令通过。脚本语法、scheme XML 和差异格式检查通过。本地 HTTPS 服务未启动，因此未运行这 7 项的真实联机 E2E。

合并前复核：`swift test --package-path IMV2Core --jobs 4 --quiet` 通过（128 项）；`swift test --package-path IMV2Server --jobs 4 --quiet` 在修复上述 admission 测试后全量通过（各 target 合计 1387 项）。

首轮有效性清理时，Core 128 项及 Server 两组定向测试通过。后续合并前复核见上；ClientKit 与 App 全量测试未运行，也未逐一判定约 2430 个原始 `@Test` 的语义价值。
