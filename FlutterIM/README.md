# 涟漪 Flutter IM

Android 和 iOS 的默认入口是 `lib/main.dart`。两端启动时自动使用原生 iOS 真机包的账户服务 `https://120.77.66.38` 和消息网关 `120.77.66.38:7443`。启动后进入原项目的「消息 / 联系人 / 我」工作区。首次在消息页或「我」中点「登录」，输入账号和密码；没有账号时可切换到「注册」，填写账号、密码、公开 ID 和显示名称。再次启动时由共享 SDK 恢复已有会话。

登录后可按未读过滤或搜索会话，查看 SDK 返回的好友、群聊，进入聊天收发文本、照片和文件。通过输入框旁的加号一次选择多个照片或文件，确认后逐个提交发送，说明文字附在第一个附件上。接收端可查看文件名、类型、大小并请求下载；图片支持在消息内按授权期限预览，并可全屏缩放查看；视频和音频附件可在消息内播放，其他文件可调用系统查看器预览；下载完成后可选择「保存到文件」，将副本导出至系统文件选择器指定的位置。单个附件上限为 32 MiB。在「我」或会话资料中打开「文件传输」，可查看传输阶段及已确认字节数，并按当前任务支持的操作暂停、继续、重试或取消。通过消息菜单可引用回复、收藏，或进入多选模式一次选择最多 100 条消息转发到最多 10 个其他会话，也可编辑或撤回自己已发送的消息；「我 → 收藏」可按收藏时间分页查看并取消收藏，点收藏可定位原消息上下文。群聊输入区可添加最多 20 个提及目标（公开 ID 或 @all），发送后气泡显示提及摘要。具备权限的群成员可在消息菜单置顶或取消置顶消息，气泡显示置顶标记；管理员可对全员移除消息。带附件的消息可把附件重新提交到另一个会话。消息正文支持粗体、斜体、行内代码、代码块和链接样式，链接可点击并用系统浏览器打开。点击聊天气泡中的引用预览可以定位被回复的原消息。聊天页展示引用预览、转发标记和共享 SDK 返回的私聊已读状态。「我」保留外观设置和退出登录；「消息接收设置」可开关陌生人消息、添加权限、单聊/群聊已读回执、在线状态和正在输入，并管理已屏蔽用户或按公开 ID 屏蔽/解除；「账号安全」可修改密码、生成并保存离线恢复码，或用恢复码重置密码；「登录设备」可查看当前设备和其他登录设备，并退出单台或其他已观察到的设备。个人资料页可修改昵称、从相册或相机选择头像并裁剪为 512 像素方图，或移除头像，修改会同步到账号内的其他设备。正式包使用账号数据，模拟压测和模拟资料编辑保留在本地演示入口。会话列表展示最近 50 项。长按会话可置顶聊天、开启免打扰或隐藏聊天；聊天设置页也提供同样入口，隐藏的会话可从消息页右上角的「隐藏的聊天」重新打开。置顶、免打扰和隐藏沿用共享 SDK 的会话状态，会同步到账号内的其他设备。会话列表中的「搜索全部聊天记录」可跨会话检索已建立索引的消息正文，结果显示所属会话。从会话资料打开「搜索聊天记录」可限定在当前会话内，两种搜索每页最多 20 条。点搜索结果可定位原消息，并上下滚动查看前 24 条、后 25 条相邻消息。聊天记录每页最多 50 条，可查看更早消息并返回最新页，联系人页可按公开账号申请好友、查看收发申请、接受或拒绝申请、删除好友以及管理黑名单；联系人与群成员显示共享 SDK 按页面授权返回的昵称，私聊会话、聊天页和成员列表按需加载授权头像并在到期后刷新，联系人资料页还可设置仅自己可见的备注。群聊页可新建群聊，从好友中选择成员或按公开 ID 添加。群资料页可查看群头像，群主可从相册或拍照更换、移除群头像，会话列表、聊天页头和群资料页显示授权群头像。群资料页可查看公告并分页浏览成员。具备相应权限的用户可编辑公告、增删成员或调整管理员角色，管理员可禁言成员 1 小时或带审计原因移除成员，群主可配置管理员和普通成员的群权限、转让群主或解散群聊，其他成员可退出群聊。成员可设置本群昵称，自己发送的群消息可查看已读成员名单。群资料页的「邀请与审批」可创建 7 天、最多批准 100 次的邀请链接，展示二维码并撤销链接，批准或拒绝入群申请；联系人页的群聊入口可按邀请链接或令牌申请加入、查看或取消自己的申请。好友和群聊分别按每批最多 50 项加载，可在对应列表底部继续加载。发送入队后页面显示待发送状态，确认投影到达后更新气泡。发送结果未知且核对已暂停时，可在消息菜单选择「继续确认」。服务器确认未发出或本地提交前过期的消息可选择「重新发送」。仍在准备或已确认未发送的消息也可在同一菜单选择「取消发送」。

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

先从仓库根目录启动隔离后端。Android arm64 模拟器需要启用 Wi-Fi 并连接到活动网络，附件传输使用该网络的套接字。

```sh
python3 IMV2/scripts/verify_v2_isolated_native_account.py --resource-part-uploads --hold-seconds 900
```

在另一个终端将输出的配置路径和已有 Android arm64 模拟器序列号交给驱动。驱动在构建测试包时自动注入隔离后端地址，创建四个临时账号、一个收发消息的私聊，并为两端分别准备两个转发目标私聊，自动创建并清理一个 iOS 模拟器，在两个 Flutter 界面依次登录、收发文本、重开消息窗口并退出。附件用例通过真实平台绑定向对方发送 280001 字节的测试文件，接收端检查聊天页文件名、下载后导出并逐字节比对。两端各自通过消息菜单一次选中两个目标，分别打开目标会话核对正文和转发标记。附件用例使用应用私有测试文件，跳过系统文件选择器。测试 CA 只加进临时 iOS 模拟器和专用 Android Debug 包的 localhost 信任配置。

```sh
cd FlutterIM
python3 tool/verify_shared_sdk.py --endpoints /path/to/test-endpoints.json --android emulator-5556
```

双向文本与附件验收已在 Android API 31、API 36 arm64 模拟器与 iPhone 16 Pro（iOS 18.5 模拟器）上通过，连接隔离 PostgreSQL、账户 HTTPS 服务和 TLS 网关。多目标转发已在 Android API 36 和 iOS 18.5 模拟器分别发起并通过上述验收。普通 Debug APK 和 iOS 模拟器 App 也已构建。
