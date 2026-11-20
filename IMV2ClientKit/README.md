# IM V2 客户端 SDK

## 四端共享目标与当前边界

长期目标为 iOS、Android、macOS、Windows 共用一套 Swift 业务实现。共享认证、同步、SQLite、搜索、消息、联系人/群组和资源状态机；各端分别提供系统适配、薄语言绑定和界面。桌面 UI 技术栈不在本次约束中预先确定，不为接入新 UI 重写业务。

| 平台 | 当前基础 | 尚需验证或实现 |
| --- | --- | --- |
| iOS | 保留 `IMV2ClientKit` 门面及 Apple 适配；会话建立、退出和任务所有权通过原生 `V2SharedSession` 接入共享模块 | 页面与完整功能依赖组合仍在 App，后续按功能收敛；不是改用 JSON 快照 UI |
| Android | Swift 共享运行时、Keystore / HTTP / TLS 适配、Kotlin 绑定与 App，第 5–11 阶段已有真实后端验收；第十二阶段拆分后重新回归 | 覆盖范围以各阶段验收报告为准；Release 原生库压缩是 Android 独立打包策略 |
| macOS | Package 已声明 macOS 15；共享动态库、C ABI、Keychain 与双客户端真实后端链路已验证 | 桌面 App/UI、沙盒文件授权、系统生命周期及签名分发；SDK 验收不等于桌面产品已交付 |
| Windows | 搜索锁已增加 Win32 分支，提供原生检查脚本；尚无原生 Windows 验收 | 工具链和依赖、安全存储、HTTP / TLS / 取消、资源文件持久化、DLL 宿主接入及分发 |

应用级组合已移入 `IMV2SharedRuntime`，通过 `SharedPlatform` 注入凭据/安装绑定、退出标记和恢复账本、邀请秘密、认证与头像 HTTP、资源上传/下载、TLS、注册设备信息及暂存文件创建。该模块不导入 Android / Apple 具体实现。`IMV2SharedAndroid` 保留原有 Android 存储命名空间、请求和 JNI 语义；`IMV2SharedApple` 接入 Keychain、URLSession 与 Network.framework，使用新的共享入口命名空间，不迁移或修改原 iOS 凭据。

`IMV2SharedSDK` 仅保留 C ABI 句柄注册表和平台入口选择，按目标平台链接对应适配；非 Apple / Android 入口尚未实现时明确失败。Apple App 原有 Swift 产品接口保持不变。C ABI 的 UTF-8 JSON、内存所有权、取消及关闭合同见 [桌面接入与验证](../experiments/swift-desktop/README.md)。

搜索写入锁已隔离到 `CSearchFileLock`：Apple / Android 继续使用 `flock`；Windows 分支使用 UTF-16 路径、`CreateFileW` / `LockFileEx`，尚未在原生 Windows 编译运行。共享 C ABI 已移除 `strdup/free` 平台导入，暂存文件创建由适配器提供。尚未完成的 Windows 源码边界包括 `V2ResourceDirectoryIO`、`V2ResourceFileStore`、`V2BackgroundResultInbox` 等 POSIX 文件操作。zlib 链接与 SQLite、GRDB、Crypto、Protobuf、Foundation 的具体版本组合仍需 Windows 实测，保留现有数据、Unicode 搜索和幂等合同。[Swift 已提供 Windows 工具链](https://www.swift.org/install/windows/)，这不代表本 SDK 已支持 Windows；WSL / Linux 或 macOS 探针不能代替原生 Windows 验收。

下一步优先取得原生 Windows 环境，执行最小探针并补齐上述适配，再扩展桌面 UI 与安装包验收。macOS 已通过共享 SDK 登录、双端文本/回复、中文搜索、物理 TLS 断线、客户端关闭重开后的凭据/数据库恢复、发送不重复与第三账号隔离；测试信任仅限定隔离后端 CA 和 localhost，未修改系统信任库。平台专属的导出、链接和体积优化不得改变其他端的默认行为。

`IMV2ClientKit` 拥有独立的本地缓存与协议边界。当前已实现以下持久化边界：

- `V2AuthSession`：统一管理设备凭据与刷新轮换。
- `V2KeychainCredentialStore`：使用 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` 保存一份设备专属 Keychain 记录。
- `V2SyncEngine` 与 `GRDBV2LocalSyncStore`：在独立 SQLite 结构中实现先持久化再 ACK 的增量同步和快照重置围栏。重置时先获取签名清单，再持久化暂存并验证各个不透明分页；完整快照原子替换后才发送 ACK。进程中断后只补齐缺失分页，不清空上一份已就绪投影。不透明的下一次同步令牌、对应待发送 ACK 回执与本地水位一起保存，避免重启后确认错误范围。已受理消息在同一 SQLite 事务中解码为可查询的本地消息投影；无效消息载荷会回滚整批，不推进水位。
- `GRDBV2LocalSyncStore`：创建和每次重新打开时，将管理目录、SQLite 数据库、WAL 和 SHM 排除在设备备份之外。尚未发送的本地命令仅属于当前设备，不用于恢复或迁移。
- `V2CommandOutboxEngine` 与 `V2MembershipCommandOutboxEngine`：分别管理消息和成员变更的持久化发件箱。成员变更保留操作 ID、预期版本、重试计划与终态结果。遇到 `REVISION_CONFLICT` 时保存服务端当前版本，不以过时意图继续重试。
- `V2LocalStoreBootstrapper`：本地存储的唯一生产入口，将 SQLite 数据库绑定到设备专属 Keychain 标记。标记缺失或不匹配时，将数据库视为导入数据，丢弃后通过认证同步重建；Keychain 暂时不可用时暂停启动，不修改数据库。

尚未发布的本地投影数据库在初始化时一次安装完整的当前结构，历史结构升级和投影回填已移除。重新打开当前数据库会保留排队命令、完成回执、成员围栏和快照导入进度。独立搜索数据库同样只初始化当前结构。

## 共享运行时与平台适配（第二阶段）

| 模块 | 职责 |
| --- | --- |
| `IMV2ClientRuntime` | 认证、同步、发件箱、GRDB、搜索、资源调度及 TLS 帧协议；源码保留在原 `Sources/IMV2ClientKit` 路径，避免影响协议生成脚本。 |
| `IMV2ClientNetwork` | HTTP 物理执行接口、URLSession 适配、TLS 字节接口与 Apple Network 实现、网络条件及请求约束。 |
| `IMV2ClientPlatform` | 锁、SQLite 串行执行器、安全随机数、文件保护、备份排除和磁盘容量查询。 |
| `IMV2ClientApple` | Keychain、Passkey、原生后台 URLSession，以及原有 Keychain 构造器和 `native(...)` 工厂。 |
| `IMV2ClientKit` | 保留原产品与 import 入口，重导出共享运行时和 Apple 适配。 |

现有 iOS App 继续 `import IMV2ClientKit`，原有 Keychain service/account、可访问级别、后台 session 标识和文件布局不变。iOS HTTP 保留 `URLSession.bytes(for:)`、连接池、自定义认证代理、响应上限、拒绝重定向及现有指标。模块归属已改变，消费者需要重新编译；不承诺旧二进制 ABI 或反射得到的模块名不变。访问内部实现的测试需显式 `@testable import` 对应模块。

其他 Swift 平台依赖 `IMV2ClientRuntime` 产品，注入凭据/安装绑定存储、注册/撤销账本持久化接口、`V2TLSByteConnection` 和网络条件来源。HTTP 可以注入 `V2HTTPTransport`；默认在非 Apple 平台使用 FoundationNetworking 数据代理，响应缓存有上限，取消等待完成回调，仍由同一运行时负责准入、绝对截止时间和冷却。资源上传及 Range 下载的现有 Foundation 代理保持在运行时内，已补齐跨平台导入，不新增第二份业务调度逻辑。

Android 当前通过 API 31 / arm64 编译及设备验证，第三阶段的 `IMV2ClientAndroid` 产品提供 Keystore 与 TLS 字节连接适配；ConnectivityManager 和系统后台任务仍未接入。通用非 Apple 默认 TLS 连接仍明确失败，Android 调用方须显式选择 Android 初始化入口。自动下载的默认网络条件为不可用；无法执行的蜂窝/昂贵/受限网络约束明确抛错。数据库和资源仍应使用 Android 私有、不备份目录，Apple 文件属性不视为 Android 安全实现。

搜索改用 `Crypto` 的 SHA-256，并按 Darwin / Android / Glibc 选择 POSIX 文件锁；索引格式、分词、摘要及 Unicode 匹配合同不变。Android 链接的 SQLite 必须提供 FTS5，验证程序继续显式构建并隐藏自带 SQLite 符号。

复现和结果见 [`experiments/swift-android`](../experiments/swift-android/README.md)。本阶段只建立共享模块与平台替换边界，不表示 Android App 已切换到完整 Swift SDK。

第四阶段新增独立动态产品 `IMV2SharedSDK`，通过有界 C/JNI 操作句柄向 Kotlin 暴露登录、恢复、连接、同步和关闭；认证 HTTP 使用 Android 原生信任与取消适配。Android App 可选择接入，已在真实后端验证密码登录、两条非空偏好同步、断线重连和凭据/数据库重新打开。该产品不改变现有 iOS 门面或 Apple 默认实现；完整 Kotlin 业务接口及 App 功能迁移仍未完成。参见 [Kotlin 接入说明](../IMAndroid/sharedsdk/README.md) 与 [第四阶段证据](../experiments/swift-android/verification/phase4/RESULTS.md)。

第五阶段将 Android App 默认且唯一切换到 `IMV2SharedSDK`，删除原 Kotlin 业务 SDK 与平台存储模块。会话/消息读取、文本持久发送与确认、房间恢复、退出和账号切换均接到共享运行时；Android 页面只持有不可变快照和调用生命周期。iOS 默认实现及公开门面保持不变。范围与真实后端证据见 [第五阶段结果](../experiments/swift-android/verification/phase5/RESULTS.md)。

## iOS 原生共享会话（第十三阶段）

`IMV2ClientKit` 新增重导出 `IMV2SharedRuntime`。iOS 直接调用公开的 `V2SharedSession`，不经过 C ABI、JNI 或 JSON。Android/macOS 的原有 `SharedRuntime` 也复用同一会话组件完成密码登录、数据库打开关闭、退出尾部和维护任务。旧五模块 API 清单继续单独对照；新原生 API 是独立模块的增量接口。

- `V2SharedSession` 持有凭据/安装绑定 bootstrap、正在打开的任务和已打开的 store。iOS 将既有 `V2AccountRuntime` 注册到它；账户任务排空以前禁止关闭其数据库。退出会取消并等待未完成的打开操作，迟到结果不得交给页面。
- `authenticatePassword` 支持原有注册/登录模式及公开 ID、显示名，沿用原认证、注册和签发恢复服务。`openLocallyEstablishedSession` 保留本地优先启动，不要求在线刷新后才显示已有内容。
- `beginSignOut` 先保存退出意图，再使认证代次失效、排空打开和实时任务。宿主撤下 UI、关闭页面/媒体资源及账户工作后，`completeSignOut` 才执行撤销交接、凭据删除、注册清理和标记清除。关闭失败保留退出责任；已经开始的持久尾部不随页面取消中断。
- `runRealtime` / `suspendRealtime` 持有并排空真实前台连接任务；撤销和注册取消通过 `runMaintenance` 由共享所有者持有。`V2SharedSessionRestoration` 统一恢复任务、独立等待者取消和截止时间，旧 App 名称保留为类型别名。
- iOS 的 `scenePhase`、APNs 回调、受保护数据提示、页面观察和资源系统后台适配仍在 App/Apple 层。`inactive` 仍不等于后台；关闭保留登录，退出才删除凭据。Keychain service/account、安装绑定、退出文件格式、数据库目录及后台 URLSession 标识不变。

本阶段统一的是会话和任务所有权，尚未把 iOS 的全部页面服务组合替换为 `SharedSnapshot`，也未要求 iOS 使用跨语言轮询。实际验证与限制见 [第十三阶段记录](../experiments/swift-desktop/verification/phase13/summary.json)。

验证：iOS 相关单元测试 42 项、共享所有权及平台测试 7 项通过。iPhone 16 Pro / iOS 18.5 模拟器使用隔离 PostgreSQL + HTTPS/TLS 后端，通过注册登录、同步消息、前后台恢复、退出、A→B→A 隔离和双账号冷启动恢复；Android 真实后端回归及 Debug/Release/lint、macOS 共享 SDK 真实后端回归也通过。旧综合 UI 用例的 Dynamic Type 审计失败单独保留；本阶段不声明全套 UI、iOS 真机或分发验收通过。

## 统一会话业务门面（第十四阶段）

账号所有者 `V2SharedSession` 为本地存储注册唯一的 `V2ConversationService`。iOS 的 `V2ConversationDataSource` 和 Android 的 `SharedRuntime` 都通过它读取会话列表、消息时间线和定位窗口；共享层负责读取权限、未读数、缺失摘要恢复以及待发送消息的原子快照。iOS 保留原生 Swift 值、完整列表 diff、页面路由和已有 150ms 普通变更合并策略。

```swift
// 由账号组合层取得 service 后，注入页面；页面不打开数据库。
let window = try await service.openTimeline(in: roomID, limit: 50)
let initial = try await window.read()
let older = try await window.nextPage()
for try await snapshot in await window.updates() {
    // 在 UI 自己的隔离域渲染。
}
await window.close()
```

每个 `V2ConversationWindow` 独立持有查询、游标和观察者，支持多个窗口打开同一会话。取消订阅或关闭窗口不关闭账号连接；切页时过滤已缓冲的旧游标结果。退出账号先关闭门面、终止订阅并排空读取，再关闭数据库，旧窗口不能继续返回缓存。每账号最多 128 个窗口，页面退出后应显式关闭；事件缓冲只保留最新状态。

这是统一业务接口的首批迁移。旧投影值类型及组合层初始化接口暂时保留以兼容现有 iOS；其他功能尚未全部迁移，底层公开符号尚未收窄。Android 原来的默认页面快照和游标仍兼容，新增独立窗口绑定供多窗口宿主使用；原生 Swift 无需经过 JSON。验证范围与限制见 [第十四阶段记录](../experiments/swift-desktop/verification/phase14/RESULTS.md)。Windows 平台实现及分发状态没有变化。

## 统一消息业务门面（第十五阶段）

`V2SharedSession.messages` 注册账号级 `V2MessageService`。iOS 的发送、编辑、撤回和转发适配器，以及 Android 的 `SharedRuntime` / `SharedMessaging` / `SharedInteractions`，均调用该服务。

```swift
let intentID = try await messages.send(in: roomID, text: "hello", replyTo: replyReference)
let workID = try await messages.edit(in: roomID, messageID: messageID,
                                    expectedRevision: revision, text: "edited")
for try await state in await messages.sendConfirmations(intentID) {
    // 持久化提交与服务端确认分开；最终正文以同步投影为准。
}
```

门面保留原操作服务的幂等身份、修订号、未知结果确认和转发计划。文本发送冻结后交给原持久化执行器；取消不会删除已冻结的意图，离线恢复继续使用同一身份。附件由原资源引擎准备，消息消费者与上传依赖通过门面原子冻结。`retrySend`、`retryMutation`、`retryForward` 和 `cancelForward` 复用原持久化重试与取消语义。

消息状态流按订阅者独立观察；关闭门面会拒绝新命令，取消订阅和执行中的工作，并等待物理完成后允许关闭数据库。账号运行时仍负责调度器与连接，门面的 `handlers()` 只将既有执行器接入账号 dispatcher。页面不创建第二套 HTTP 客户端或执行器。

兼容边界仍保留：iOS 内部适配器的旧构造入口供既有测试/宿主使用，生产组合注入统一门面；状态值仍沿用原领域类型。资源上传下载、搜索、已读回执等其他领域没有在本阶段整体迁移。验收记录见 [第十五阶段](../experiments/swift-desktop/verification/phase15/RESULTS.md)。

## 统一搜索和已读业务门面（第十六阶段）

`V2SharedSession.search(for:)` 提供账号数据库级 `V2SearchService`，统一搜索、会话上下文、索引进度与索引启停。每次请求携带自身查询和游标，多窗口互不覆盖；原索引仍负责精确子串、筛选、发布水位、账号/代次游标隔离及编辑撤回失效。

`V2SharedSession.readReceipts(for:accountID:receipts:transport:)` 提供账号级 `V2ReadReceiptService`，统一回执状态、可见消息上报、重试、归档恢复、群读者查询与持久化执行器。iOS 的本地 checkpoint 序号和 Android 的可见消息 ID 都进入原有单调合并队列；隐私暂停不会改写已冻结操作身份。群读者请求前后都核对本地授权，退出时取消并排空查询，再关闭数据库。`V2ConversationService.readCheckpoint(in:)` 提供原生页面使用的本地已应用序号与已知房间头。

生产 iOS 通过原生 Swift 门面调用；Android 保留现有 Kotlin/C ABI 方法和页面状态转换，没有新增 Kotlin 业务实现。iOS 内部旧初始化入口继续兼容。搜索和回执详情的页面游标、展示期限与 UI 防过期结果逻辑保持原样。完整证据和真实后端验收边界见 [第十六阶段](../experiments/swift-desktop/verification/phase16/RESULTS.md)；Windows 的平台与运行验证缺口没有变化。

## 认证与设备凭据

`V2AuthSession.establish(_:)` 是独立可信账户/设备注册服务建立凭据的唯一边界。它原子写入首份设备凭据，并阻止旧刷新结果覆盖新状态。联系刷新接口前，会先保存“前序凭据、待处理刷新操作 ID”；并发调用共享一个刷新任务，网络失败后保留可重试的操作 ID，后继凭据持久化后才返回令牌。Keychain 暂时不可用会暂停会话；确认服务端终态拒绝后才删除记录并回到未认证状态，旧刷新不能重新创建会话。

`V2ClientSessionBootstrapper` 是面向 App 的启动边界。它要求先完成 V2 认证，再打开与安装绑定的本地存储；首份凭据只能来自显式注入的可信账户/设备提供者，没有隐式登录来源。

`V2HTTPDeviceCredentialAuthTransport` 对接 `POST /v2/device-credentials/refresh`。请求携带已持久化的刷新操作 ID，使用 `no-store` 语义；只有 401/403 被视为凭据终态拒绝。网络错误、5xx 和无效响应仍可由 `V2AuthSession` 重试。初始账户认证断言和首份凭据提供者由部署注入，SDK 不自行选择或模拟登录方式。

`V2HTTPAccountAssertionDeviceCredentialProvider` 对接 `POST /v2/device-credentials`。不透明账户断言来自注入的认证提供者，设备 ID 来自注入的身份提供者。App 的 `V2DeviceRegistrationStore` 在请求认证前，先将账户范围的设备/操作身份和用途受限的随机取消证明保存到设备本地 Keychain；通用 `V2KeychainDeviceCredentialRegistrationOperationStore` 仍是设备专属适配器，两者均不保存账户断言。

注册重放要求有效账户认证和服务端有界重放窗口。HTTP 签发要求精确的取消身份，并在响应中确认；确认缺失或不匹配时，先持久交接已收到的撤销能力，再拒绝登录。新尝试的签发期限为十分钟；过期后轮换两个 ID，并保留旧证明。签发方要求 `V2IssuedCredentialRecovering`，生产组合使用 `V2IssuedCredentialRecoveryStore` 在返回凭据前持久化撤销能力。登录结果持久接纳后，收尾过程清除操作和已收到结果记录。冷启动恢复必须先于交互注册，避免遗弃尚未完成的结果。

## 注册取消与恢复

`V2HTTPDeviceRegistrationCancellationClient` 将调用方持有的 `V2DeviceRegistrationCancellation` 发送到 `POST /v2/device-credentials/cancel-registration`，无需账户认证。重试保留相同设备、操作、证明和签发期限；只有空响应 204 确认取消，空响应 410 表示服务端记录已过期。

取消请求 JSON 中的设备编码为 `"deviceID":{"rawValue":"CANONICAL-UUID"}`，签发请求外层的 `deviceID` 则仍为字符串。非 Swift 调用方必须保留这一区别。服务端可以阻止未签发操作，或撤销与其绑定的已签发会话。

注册台账使用格式 3，将格式 2 的证明原子迁移为带持久重试状态的任务。注册台账仅接受当前格式；其他已存格式直接拒绝，不自动升级。退出登录会将待处理证明移入已放弃集合；`pendingCancellations()` 与精确匹配的 `completeCancellation(_:)` 支持响应完全丢失后的恢复。

`V2DeviceRegistrationCancellationRunner` 观察该队列，对暂时失败执行有界退避重试，对无效请求/响应暂停处理。App 在前台运行它，进入后台时取消并排空；它与会话撤销共享汇总清理状态和手动重试入口。冷启动必须先调用 `recoverUnclaimed(ownedBy:)`，再开始交互注册：与已持久持有设备匹配的证明在本地退役，未归属证明入队。队列中的证明仅由服务端取消或过期结清。

## 登录能力边界

SDK 包含与框架无关的 WebAuthn 构件；账户服务尚未实现完整的挑战、来源、RP-ID、签名计数器与凭据撤销前，App 不开放该入口。当前密码支持由 `V2HTTPPasswordAccountAuthenticator` 提供，调用方只向一次性方法传入密码，ClientKit 不持久化密码。

## 实时连接与生命周期

`V2RealtimeSessionCoordinator` 是设备认证会话进入 `V2TLSFrameConnection` 的唯一 App 边界。它获取一致的用户/设备/访问令牌组合，必要时刷新；并发调用共享握手，只接受匹配的认证身份，网关终态拒绝后清除本地会话。App 将同一个已连接的 `V2TLSFrameConnection` 交给 `V2ProtobufSyncTransport`，页面和功能模块不自行处理访问令牌。

`V2ClientRuntime` 管理握手后的前台生命周期。`start()` 合并并发启动尝试；握手完成后，首次持久化同步与实时提示、心跳独立运行，慢同步不阻塞连接就绪。`stop()` 取消任务、关闭连接并等待已持有的任务收尾。页面仅通过该边界表达前后台意图，实时提示不作为投递完成状态。

`V2DefaultClientRuntimeActivity` 统一持有当前连接的恢复循环。任一子循环抛错时，立即取消其他子循环，等待清理完成后把原始错误交给 runtime，记录失败并断开当前代连接。取消时正常结束的监听流仍向上报告取消。账户持久操作继续由独立的账户执行器管理。

打开本地数据库前，App 必须注入具体的 V2 认证与同步传输，并向 `V2LocalStoreBootstrapper` 注入 `V2KeychainInstallationBindingStore`。SDK 不读取外部传输、缓存、凭据或数据库表状态。

## 验证

```sh
swift test --package-path IMV2ClientKit
```

仓库的原生测试使用可丢弃临时构建目录，可运行 `scripts/run_v2_clientkit_native_tests.sh`。默认使用四个编译任务，显式采用 Xcode 默认 Swift 工具链，以匹配 macOS 测试辅助程序；需要调整本机资源限制时，设置 `IMV2_CLIENTKIT_TEST_JOBS`。

单元测试使用 Actor 隔离的模拟存储与传输。设备锁定、重启后首次解锁之前、签名权限或访问组变更时的 Keychain 行为，以及真实服务端终态错误，仍需模拟器/真机与后端集成验证。


## Android 平台接入（第三阶段）

新增独立产品 `IMV2ClientAndroid`，提供 Keystore 凭据/安装绑定/恢复账本存储，以及 `V2TLSFrameConnection(androidEndpoint:frameLimits:...)` 的 Android TLS 1.3 接线。它只依赖共享 Runtime 和 JNI 平台边界；原 `IMV2ClientKit` 门面继续导出 Apple 实现，现有 iOS 调用和默认行为不变。

Android 宿主先加载包含本产品的 native library，再安装 `AndroidRuntimePlatform`。JNI 及 Kotlin 模块的安全条件、生命周期和接入示例见 [`IMAndroid/swiftplatform/README.md`](../IMAndroid/swiftplatform/README.md)；设备和 iOS 回归证据见 [`第三阶段结果`](../experiments/swift-android/verification/phase3/RESULTS.md)。本阶段不包含完整 Kotlin 业务 facade 或正式 App 迁移。


## 统一联系人和群组业务门面（第十七阶段）

`V2SharedSession.contacts(...)` 和 `groups(...)` 按已打开的账号数据库缓存 `V2ContactService` / `V2GroupService`。iOS 使用原生 Swift 接口，Android 的 `SharedSocialGroups` / `SharedCommunity` 只持有页面状态并转换绑定值，查询和持久化命令调用同一组服务。

- 联系人：好友/收发申请的分页与定位窗口、黑名单、精确账号解析、关系提案/确认/重试、持久化私聊创建和建房前的本地消息。
- 群组：独立群目录、成员分页、建群与取消恢复、加入/移除/退出、公告、角色/权限、转让/解散、置顶、邀请与审批、禁言和管理员移除。
- 子服务保留原命令身份、修订、确认期限和持久化恢复算法；共享门面统一安排执行器、准备任务和观察生命周期，不改变 HTTP/TLS 协议。
- 每个调用者独立持有游标和观察订阅。关闭一个订阅不会关闭其他窗口；账号关闭后旧门面拒绝调用，取消并等待查询、准备任务、订阅生产者及注入的查询协调器清理完成，再释放数据库。

生产 iOS 的联系人数据源、群目录/设置和业务适配器均注入这些门面；内部旧构造入口继续支持既有测试。原有五个 SDK 模块的公开符号保持兼容，尚未执行底层公开 API 收窄。资料展示/备注、头像、资源传输和偏好服务仍有独立业务入口，本阶段未将它们全部并入联系人/群组门面。

真实后端与设备范围见 [第十七阶段验收](../experiments/swift-desktop/verification/phase17/RESULTS.md)。macOS 的原生宿主验收不代表桌面 App 或分发验收，Windows 平台缺口保持不变。

## 统一资料、头像和资源业务门面（第十八阶段）

`V2SharedSession.profiles(for:accountID:presentations:names:)` 与 `resources(for:accountID:library:uploads:downloads:groupAvatars:)` 按账号数据库持有服务；这些参数属于平台组合入口，页面从已组合的服务取业务能力。iOS 使用原生 Swift，Android 的 Swift 绑定转换请求与值，Kotlin 不实现业务规则。

- `V2ProfileService` 统一资料授权展示、投影查询、联系人备注和群昵称；`ownProfile()` 提供自身资料及头像持久化命令。每个页面持有独立 activation，关闭一个页面不会结束其他页面。原有修订冲突、展示租约和头像授权失效规则保留。
- `V2ResourceService` 统一上传准备、附件消息冻结、准备完成后的发送交接、取消发送、下载和授权头像字节读取。`library`、`uploads`、`downloads` 是复用现有实现的业务子服务，负责资源目录、存储策略、传输恢复和缓存；没有重复实现网络或文件持久化。
- `resources.groupAvatars` 将原 iOS 群头像的授权、修订、资源复用、持久化命令及失败处理迁入共享层。iOS 适配器只转换页面值；Android 调用同一服务。
- iOS 的 URLSession 后台上传下载协调器、文件选择和图片处理仍由平台层注入，原有账号恢复循环继续驱动任务。账号关闭会取消并排空业务操作及观察者，然后关闭传输、缓存和数据库；旧服务句柄不能跨账号复用。

既有 SDK 五个模块的 6,079 条公开符号记录继续保持兼容；这不是新增 6,079 个业务接口。新增共享门面清单独立记录。本阶段没有收窄旧公开符号，也没有宣称所有业务已完成迁移。验收与平台边界见 [第十八阶段记录](../experiments/swift-desktop/verification/phase18/RESULTS.md)。
