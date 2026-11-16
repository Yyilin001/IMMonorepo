# 涟漪 Flutter IM

Android 和 iOS 的默认入口是 `lib/main.dart`。两端启动时自动使用原生 iOS 真机包的账户服务 `https://120.77.66.38` 和消息网关 `120.77.66.38:7443`。启动后进入原项目的「消息 / 联系人 / 我」工作区。首次在消息页或「我」中点「登录」，只需输入账号和密码；再次启动时由共享 SDK 恢复已有会话。

登录后可按未读过滤或搜索会话，查看 SDK 返回的好友、群聊，进入聊天收发文本。「我」保留外观设置和退出登录。正式包使用账号数据，模拟压测、模拟资料编辑和图片发送保留在本地演示入口。会话与时间线按共享 SDK 的最近 50 项窗口展示，联系人和群聊各展示首批最多 50 项。发送入队后页面显示待发送状态，确认投影到达后更新气泡。

原项目的本地模拟、压力演示与 Compose 实验一并保存在副本中。手机上可通过 `flutter run -t lib/mock_main.dart` 运行旧演示。macOS 默认打开本地演示。[原演示说明](docs/local-demo.md)

## 构建和运行

使用 Flutter 3.50 / Dart 3.14。Android 的共享库目标是 API 31+ 的 arm64-v8a，iOS 的 Swift Package 目标是 iOS 17+。从仓库根目录执行以下命令。首次配置 Android Swift 工具链与 NDK 的版本见[原生构建说明](../experiments/swift-android/README.md)。

```sh
# Android 首次构建或共享 Swift 源码更新后
export ANDROID_NDK_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}/ndk/30.0.16248370"
python3 experiments/swift-android/build_probe.py --reuse-capabilities --shared-sdk

cd FlutterIM
flutter pub get
flutter devices
flutter run -d <device-id>
```

在 `FlutterIM` 目录运行 `flutter build apk --release --target-platform android-arm64` 可生成正式 APK。Release 构建压缩 Flutter 和 Swift 原生库，设备在安装时解压。Gradle 默认从 `~/.android/im-flutter-release/signing.properties` 读取签名配置，也可通过 Gradle 属性 `imFlutterSigningFile` 指定配置文件。配置使用 `storeFile`、`storePassword`、`keyAlias` 和 `keyPassword`，相对密钥库路径以配置文件所在目录为准。请妥善备份密钥库和配置，以便后续版本覆盖升级。

## 插件

`packages/im_flutter_sdk` 是 monorepo 内的 Flutter 插件。Dart 的 `ImClient` 管理应用前后台连接与订阅。每个列表或聊天订阅有独立的 Swift 查询窗口，取消订阅会关闭对应窗口。应用退出账号调用 `signOut()`，宿主销毁调用 `close()`，后者保留凭据以便重新启动后恢复。

Android 的 Gradle 设置引入 `:sharedsdk` 和 `:swiftplatform`，通过 Kotlin `SharedClient` 接入已有 JNI 和 Swift 动态库。iOS 的插件通过本地 SwiftPM 依赖调用 `IMV2SharedApple` 提供的独立宿主入口。账号、连接、收发、数据库均由 `IMV2SharedRuntime` 及其依赖管理。这个入口用于独立 Flutter App，嵌入已有原生会话需要由宿主注入该会话。

```dart
final client = await ImClient.open(
  accountUrl: Uri.parse(accountUrl),
  gatewayHost: gatewayHost,
  gatewayPort: gatewayPort,
);
await client.restoreSession();
if (client.session.userId == null) {
  await client.signIn(account, password);
}
final rooms = client.watchConversations();
final timeline = client.watchMessages(roomId);
await client.sendText(roomId, text);
```

更新 Pigeon 接口后，在插件目录运行 `flutter pub get` 和 `dart run pigeon --input pigeons/im.dart`，一并保存三个平台的生成文件。

## 双端联调

先从仓库根目录启动隔离后端。

```sh
python3 IMV2/scripts/verify_v2_isolated_native_account.py --hold-seconds 900
```

在另一个终端将输出的配置路径和已有 Android arm64 模拟器序列号交给驱动。驱动在构建测试包时自动注入隔离后端地址，创建两个临时账号和一个私聊，自动创建并清理一个 iOS 模拟器，在两个 Flutter 界面依次登录、收发、重开消息窗口并退出。测试 CA 只加进临时 iOS 模拟器和专用 Android Debug 包的 localhost 信任配置。

```sh
cd FlutterIM
python3 tool/verify_shared_sdk.py --endpoints /path/to/test-endpoints.json --android emulator-5556
```

本版已在 Android API 31 arm64 模拟器与 iPhone 16 Pro（iOS 18.5 模拟器）连接隔离 PostgreSQL、账户 HTTPS 服务和 TLS 网关完成上述双向验收。普通 Debug APK 和 iOS 模拟器 App 也已构建。
