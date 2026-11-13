# Android 平台适配（共享 Swift SDK）

此 Android library 实现 Keystore、TLS 字节 I/O 和认证 HTTPS，不依赖旧 `clientkit`，也不解析账户、消息或同步业务协议。Swift 端位于 `IMV2ClientKit/Sources/IMV2ClientAndroid`，通过独立 SwiftPM product `IMV2ClientAndroid` 接入共享运行时。既有 `IMV2ClientKit` 的 Apple 门面和默认传输不依赖它。

## 嵌入

1. 使用 Swift Android 工具链把 `IMV2ClientAndroid` 链入宿主 native library，并打包其 Swift 运行时依赖。当前可复现示例是 `experiments/swift-android/build_probe.py`；仅支持验证过的 arm64/API 31 目标。
2. Android 宿主依赖 `project(":swiftplatform")`，先 `System.loadLibrary(宿主库名)`，再在进程内调用一次 `AndroidRuntimePlatform.install(applicationContext)`。库不绑定验证 App 的 native 文件名。消费端 R8 规则保留 JNI 入口。
3. Swift 使用 `V2AndroidCredentialStore` 注入 `V2AuthSession`；使用 `V2AndroidInstallationBindingStore` 注入 `V2LocalStoreBootstrapper`。注册、撤销和签发恢复账本可用 `V2AndroidSecurePersistence`，每个账本必须使用不同的稳定名称，且每个账本只由一个共享运行时 owner 管理读改写。
4. 用 `V2TLSFrameConnection(androidEndpoint:frameLimits:...)` 注入 `V2RealtimeSessionCoordinator`。后续 `V2ProtobufSyncTransport`、`V2SyncEngine` 和 `V2ClientRuntime` 完全复用 Swift 实现。每次连接创建独立的 socket；连接失败后调用方先 `await runtime.stop()` 排空，再按自己的重试策略 `start()`。

本模块仅负责平台能力。第四阶段的 [sharedsdk](../sharedsdk/README.md) 提供 Kotlin 接口及 App 可选入口；后台任务、网络状态观察、旧账户数据库迁移和完整业务迁移仍未完成。

## 存储与安全边界

- 完整 Codable 凭据记录（包括待刷新/撤销操作身份）由 Swift 编码；Kotlin 只接收不透明字节。AES-256-GCM、随机 96-bit IV、128-bit tag，AAD 绑定独立 Keystore alias。
- `AndroidKeyStore` 中的密钥不可通过此 API 导出；密文原子写入应用 `noBackupFilesDir/im-swift-secrets-v1/<name>.sealed`。固定后缀避免名称与 AtomicFile 的临时/备份文件冲突。名称仅允许 1–120 个 ASCII 字母、数字、点、横线或下划线。
- 缺失文件返回 nil；认证标签/编码损坏返回 malformedRecord；已有密文但密钥缺失返回 permanentlyInvalidated，绝不自动换密钥覆盖旧密文；临时平台故障返回 unavailable。删除显式移除密文并退役 alias。
- 最大明文 1 MiB，读取密文有硬上限。此预算也适用于完整恢复账本，不能把它当成无界任务数据库。
- Android 使用应用凭据加密目录及 Keystore，不绑定生物识别、不要求每次用户认证，也不宣称等价于 Apple 的 WhenUnlockedThisDeviceOnly 锁屏访问条件。应用可在首次解锁后按自身前后台策略访问；备份/设备迁移不携带本存储。
- 不打印异常文本、密码、令牌或密钥。C/JNI 只传数字状态与有界字节，不传 Swift 对象指针。

## TLS 与并发

生产仅启用 TLS 1.3，使用系统 SSLSocketFactory、平台信任和 HTTPS endpoint identification。端点主机须为 ASCII（国际域名先转换为 IDNA）；不提供 trust-all 或关闭主机名校验的选项。验证 App 的测试 CA 配置不属于本 library。

每进程最多 64 个 socket，每次读写最多 1 MiB。Swift 每个连接分别串行读、写，握手和发送共用写队列；同步 JNI 在 Dispatch I/O 队列执行，不阻塞 Swift 协作执行器。连接/握手底层各有 20 秒超时，共享帧层管理业务请求期限。取消关闭 socket；异步调用仅在物理 JNI 调用返回后完成，旧代次不会复用句柄。同步账本协议本身要求不可挂起的读改写，因此 `V2AndroidSecurePersistence` 保持同步；不要从 UI 线程调用它。

`install()` 持有一个进程生命周期 global JNI reference；工作线程按需 attach，返回时 detach，局部引用按次释放。`activeConnectionCount` 仅提供资源诊断，不包含端点或凭据。

验证结果见 [`../../experiments/swift-android/verification/phase3/RESULTS.md`](../../experiments/swift-android/verification/phase3/RESULTS.md)。

## 认证 HTTPS（第四阶段）

`V2AndroidAuthHTTPTransport` 使用 OkHttp 4.12 的系统/应用证书信任。业务请求与解码继续由共享 Swift 账户客户端处理；禁止自动重定向和重试，不配置缓存、Cookie 或日志。单次调用期限 15 秒，最多 32 个调用，请求体 512 KiB、响应体 2 MiB、响应头 JSON 64 KiB；取消会关闭物理请求，并在返回后释放句柄。`activeHttpCount` 只报告资源数量。

平台桥接操作 20–23 分别创建、执行、取消、释放 HTTP 调用。C/JNI 输入 envelope 上限 2 MiB，输出上限 2,162,696 字节（2 MiB 响应体 + 64 KiB 元数据 + 8 字节长度）；原凭据和 TLS 每次读写的 1 MiB 上限不变。平台只执行 GET / POST / PUT / DELETE，方法和编码由 Swift 决定。真实后端及阻塞 HTTPS 取消验收见 [第四阶段结果](../../experiments/swift-android/verification/phase4/RESULTS.md)。
