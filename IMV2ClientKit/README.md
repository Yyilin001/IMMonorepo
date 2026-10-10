# IM V2 客户端 SDK

`IMV2ClientKit` 拥有独立的本地缓存与协议边界。当前已实现以下持久化边界：

- `V2AuthSession`：统一管理设备凭据与刷新轮换。
- `V2KeychainCredentialStore`：使用 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` 保存一份设备专属 Keychain 记录。
- `V2SyncEngine` 与 `GRDBV2LocalSyncStore`：在独立 SQLite 结构中实现先持久化再 ACK 的增量同步和快照重置围栏。重置时先获取签名清单，再持久化暂存并验证各个不透明分页；完整快照原子替换后才发送 ACK。进程中断后只补齐缺失分页，不清空上一份已就绪投影。不透明的下一次同步令牌、对应待发送 ACK 回执与本地水位一起保存，避免重启后确认错误范围。已受理消息在同一 SQLite 事务中解码为可查询的本地消息投影；无效消息载荷会回滚整批，不推进水位。
- `GRDBV2LocalSyncStore`：创建和每次重新打开时，将管理目录、SQLite 数据库、WAL 和 SHM 排除在设备备份之外。尚未发送的本地命令仅属于当前设备，不用于恢复或迁移。
- `V2CommandOutboxEngine` 与 `V2MembershipCommandOutboxEngine`：分别管理消息和成员变更的持久化发件箱。成员变更保留操作 ID、预期版本、重试计划与终态结果。遇到 `REVISION_CONFLICT` 时保存服务端当前版本，不以过时意图继续重试。
- `V2LocalStoreBootstrapper`：本地存储的唯一生产入口，将 SQLite 数据库绑定到设备专属 Keychain 标记。标记缺失或不匹配时，将数据库视为导入数据，丢弃后通过认证同步重建；Keychain 暂时不可用时暂停启动，不修改数据库。

尚未发布的本地投影数据库在初始化时一次安装完整的当前结构，历史结构升级和投影回填已移除。重新打开当前数据库会保留排队命令、完成回执、成员围栏和快照导入进度。独立搜索数据库同样只初始化当前结构。

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

`V2ClientRuntime` 管理握手后的前台生命周期。`start()` 合并并发启动尝试，完成首次持久化同步及待处理快照重置后，才启动实时提示与心跳循环；`stop()` 负责取消任务并关闭连接。页面仅通过该边界表达前后台意图，实时提示不作为投递完成状态。

打开本地数据库前，App 必须注入具体的 V2 认证与同步传输，并向 `V2LocalStoreBootstrapper` 注入 `V2KeychainInstallationBindingStore`。SDK 不读取外部传输、缓存、凭据或数据库表状态。

## 验证

```sh
swift test --package-path IMV2ClientKit
```

仓库的原生测试使用可丢弃临时构建目录，可运行 `scripts/run_v2_clientkit_native_tests.sh`。默认使用四个编译任务，显式采用 Xcode 默认 Swift 工具链，以匹配 macOS 测试辅助程序；需要调整本机资源限制时，设置 `IMV2_CLIENTKIT_TEST_JOBS`。

单元测试使用 Actor 隔离的模拟存储与传输。设备锁定、重启后首次解锁之前、签名权限或访问组变更时的 Keychain 行为，以及真实服务端终态错误，仍需模拟器/真机与后端集成验证。
