# 第三阶段：Android Keystore 与实时 TLS 接入

分支：`codex/swift-android-feasibility`。新增 SwiftPM 产品 `IMV2ClientAndroid`、C/JNI 边界和不依赖旧 Kotlin SDK 的 Android library `swiftplatform`。当前正式 Android App 尚未切换 SDK。

## 实现

- `V2AndroidCredentialStore`：完整凭据及待刷新/撤销身份一次 AES-GCM 加密、AtomicFile 持久化；密钥保存在 Android Keystore，密文位于 noBackupFilesDir。损坏、永久失效、暂时不可用与记录不存在分别处理。
- `V2AndroidInstallationBindingStore`：为共享 GRDB 开库提供设备安装绑定；`V2AndroidSecurePersistence` 支持共享注册、撤销及签发恢复账本的同步字节存储边界。
- `V2AndroidTLSByteConnection`：TLS 1.3、平台信任、主机名验证；有界读写和连接数，取消关闭物理 socket，异步返回前排空 JNI 操作。
- `V2TLSFrameConnection(androidEndpoint:...)`：直接接入共享帧解析、认证握手和请求所有者，不在 Kotlin 重写业务协议。断线后沿用现有调用方 stop/drain/start 的重连语义，不新增无限自动重连。
- 原 Apple 门面、Keychain、默认 TLS 连接及后台传输实现保持不变。第三阶段重新导出的 6,079 项 iOS API 与第二阶段逐条一致（零增加、删除或变更）。

## 已验证路径

Android 测试使用真实 Keystore、真实 TLS socket、Swift `V2AuthSession`、`V2RealtimeSessionCoordinator`、`V2TLSFrameConnection`、`V2ProtobufSyncTransport`、`V2SyncEngine`、`V2ClientRuntime` 和 GRDB。协议服务端是基于仓库生成 Protobuf 的隔离合同 fixture，测试 CA 仅配置于验证 App，未加入生产 library。

登录路径从测试签发凭据进入 `V2AuthSession.establish`，持久化后重新创建认证对象，由 Keystore 恢复凭据并完成实时认证。首次同步应用并确认水位 1 后，fixture 主动断开；调用方等待运行时停止并排空旧代次，重连恢复已落盘 token，继续应用并确认水位 2。关闭并重开数据库后再次检查水位、确认状态及仅有两条事件。

另外验证完整凭据和 pending 操作身份重开、密文中无明文令牌、篡改拒绝、已有密文但密钥丢失时明确失败、可信 TLS 1.3 往返、未知 CA 拒绝、可信 CA 下的错误主机名拒绝、TLS 1.2 拒绝，以及握手/读取阻塞期间的取消。每项测试结束时 Swift 任务句柄和 Android socket 数量均为零。保留前两阶段的 SQLite/FTS5、搜索、HTTP 和取消回归。

## 验证记录

最终数字及 APK 摘要见 `summary.json`；设备逐项结果见 `api31-debug.json` 和 `api31-release.json`，运行器核对实际安装 APK 的 SHA-256，不把跳过或部分执行计作通过。

- Android API 31 / arm64 Debug：23 项。
- Android API 31 / arm64 R8 Release：23 项通过。
- 共享运行时 macOS 定向回归：233 项 Swift Testing / 9 suites 通过，覆盖认证会话、连接生命周期、同步和运行时。
- iOS 17 arm64 模拟器目标编译通过；iOS 18.5 App 回归 15 项通过（后台回调、上传文件保护、离线启动）。
- Android `assembleDebug`、`assembleDebugAndroidTest`、`lintDebug` 成功；受影响模块 `testDebugUnitTest` 成功执行任务但无 JVM 测试源码，实际平台用例在 instrumentation 中执行。
- API 编译器重导出及 `export_sdk_api_inventory.py --check` 通过，比较证据为 `api-compatibility.json`。

R8 首轮暴露 Kotlin Companion 初始化入口被移除的问题，已将平台入口及 Companion 加入消费端规则；测试 App 的 `R.raw` 类另加仅验证工程的保留规则，避免分离的测试 APK 引用被宿主优化掉的资源类。

## 尚未覆盖

这不是完整正式后端端到端登录验收：未执行密码/Passkey 获取 assertion、真实服务端设备凭据签发、真实网关部署、多设备撤销或正式 App UI。当前验证从隔离 fixture 签发凭据开始，覆盖凭据落盘、恢复、实时认证、同步、断线与重连。

本阶段未运行 API 36、真机硬件失效/锁屏策略、进程强杀/断电故障注入、大型账本或高并发连接压力验证。系统后台任务、网络条件监控、完整 Kotlin 业务 facade、旧存储迁移和正式 App 接线仍待后续阶段；不能把 23 项测试解释成全量 SDK 行为对等。

## 复现

```sh
python3 experiments/swift-android/build_probe.py --reuse-capabilities
JAVA_HOME="$(/usr/libexec/java_home -v 17)" IMAndroid/gradlew -p IMAndroid -PenableSwiftProbe=true \
  :swiftplatform:assembleDebug :swiftplatform:lintDebug :swiftplatform:testDebugUnitTest \
  :swiftprobe:assembleDebug :swiftprobe:assembleDebugAndroidTest :swiftprobe:lintDebug :swiftprobe:testDebugUnitTest
python3 experiments/swift-android/run_probe.py --serial <API31设备> --api 31
JAVA_HOME="$(/usr/libexec/java_home -v 17)" IMAndroid/gradlew -p IMAndroid -PenableSwiftProbe=true \
  -PswiftProbeTestBuildType=release :swiftprobe:assembleRelease :swiftprobe:assembleReleaseAndroidTest
python3 experiments/swift-android/run_probe.py --serial <API31设备> --api 31 --variant release
```

工具链和 native 依赖摘要见 `native-manifest.json`；完整本机日志的摘要见 `validation.txt`。新建验证 AVD 使用禁用 GPU 的配置，不改变已有用户模拟器。
