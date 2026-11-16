# IM Android：共享 Swift SDK

Android 12 / API 31+、arm64，Jetpack Compose + Navigation 3。App 默认且仅使用共享 Swift SDK；旧 `clientkit`、`platform` Kotlin 业务/存储模块及依赖它们的 App 实现已移除，不再保留构建开关或业务回退。

## 当前范围

- 密码登录、设备凭据签发与恢复，Keystore 凭据存储。
- 会话分页列表、消息预览、聊天文本收发、历史分页和持久发送状态。
- 前台实时同步、断线重连；离线发送经过共享持久队列，重新打开后按原身份恢复。
- 退出登录与账号切换：持久退出意图、排空任务、撤销能力交接、凭据删除和账户数据库隔离。切换账号清除旧页面和草稿。
- 联系人分页、公开账号查找、好友请求/接受/拒绝/删除、屏蔽/解除屏蔽与私聊创建。
- 群目录和建群、成员分页/添加/移除、公告、管理员角色、角色权限、群主转让、退群与解散；权限与修订号由 Swift 提供。
- 联系人授权资料、私有备注和头像读取；群邀请创建/分享/撤销、申请/取消、管理员审批及一小时成员禁言。
- 个人/群头像选图、裁剪预览、上传和移除；邀请相机扫码及二维码图片识别，识别结果交由共享 SDK 校验。
- 图片和文件附件收发、图片预览、原文件下载及系统文档保存，单文件最多 32 MiB。
- 本地消息全局/会话搜索与分页定位；自己消息编辑、撤回和结果确认；可见消息已读上报、私聊已读标记与群消息阅读者分页。
- 支持单条消息的引用回复、定位原消息和转发到已有会话（含附件）。转发状态由共享 SDK 提供。
- 三个根标签共用 Navigation 3 详情栈；聊天详情隐藏底栏。

群元数据编辑、系统深链接自动跳转、手动提前解除禁言、音视频播放、Passkey 和系统后台任务等尚未接入新的 Android UI。联系人在授权有效期内显示名称、备注和资料头像，群成员仍使用用户 ID。图片和文件可从消息进入附件详情；音视频暂按文件下载保存。原 Kotlin SDK 的旧入口及其专属测试/性能测试已删除，不能沿用历史测试数量宣称功能对等。Android 推送继续暂缓。

旧安装的 Kotlin 凭据、数据库不会自动迁入 Swift 命名空间，也不会被本阶段代码主动删除；升级后需在新入口重新登录。切换回来按当前设备凭据及服务器同步恢复，不能宣称旧发件箱迁移完成。当前不是全量功能对等的生产交付。

## 模块

| 模块 | 职责 |
| --- | --- |
| `app` | Compose、Navigation 3、ViewModel 和前后台所有权；仅调用 `sharedsdk` |
| `sharedsdk` | Kotlin `suspend` / 不可变 `Flow`，有界 C/JNI 操作句柄 |
| `swiftplatform` | Android Keystore、认证 HTTPS、TLS 字节 I/O，无第二份业务协议 |
| `IMV2ClientKit/IMV2SharedSDK` | 共享认证、SQLite、同步、持久发送、房间补齐及账号生命周期 |
| `swiftprobe` / `protocol` | 仅 `-PenableSwiftProbe=true` 包含；前几阶段的隔离验证壳和从根 Protocol 生成的 Java 测试类型，不参与 App |

## 构建

需要 JDK 17、Android SDK 36、NDK 30.0.16248370、Swift 6.4.1 和匹配的 Android Swift SDK。初次安装按 [固定工具链说明](../experiments/swift-android/README.md) 执行。

```sh
# 仓库根目录；首轮运行包含能力检查，后续可加 --reuse-capabilities。
python3 experiments/swift-android/build_probe.py --shared-sdk
JAVA_HOME="$(/usr/libexec/java_home -v 17)" IMAndroid/gradlew -p IMAndroid \
  :app:assembleDebug :app:assembleDebugAndroidTest :app:lintDebug \
  :sharedsdk:lintDebug :swiftplatform:lintDebug
```

Linux 设置已有的 `JAVA_HOME` / `ANDROID_HOME` 后直接执行 Gradle，无需 macOS 的 `java_home` 命令。没有 native 产物时 preBuild 会明确失败并给出构建命令；不能生成缺失 Swift 动态库的安装包。当前所有 App 变体仅包含 `arm64-v8a`。

APK 位于 `app/build/outputs/apk/debug/app-debug.apk`。`:app:assembleRelease` 开启 R8、资源裁剪和原生库压缩，输出 unsigned APK，不包含隔离测试 CA。Release 的直接 APK 和 App Bundle 生成的 APK 均压缩 `.so`，安装时由 Android 解压；Debug 保留原有打包方式。JNI keep 规则由两个 SDK library 提供。

第十一阶段基线的 Release APK 从 99.69 MB 降至约 38.95 MB；这是分发包大小，原生库内容未裁剪，安装占用不会等量减少。此后大小以实际构建产物为准。

CI 改为先构建 Swift 动态库，再构建 Android / Lint / Release；Swiftly 自动安装依据 [官方文档](https://docs.swift.org/latest/documentation/swiftlydocs/automated-install/)。本机已验证构建；修改后的 GitHub Actions 尚未远端运行。

## 验证与接入

[Kotlin 接口说明](sharedsdk/README.md) 包含接口、分页、取消及退出语义。真实后端验收需要显式隔离服务与 API 31 arm64 设备：

```sh
python3 IMV2/scripts/verify_v2_isolated_native_account.py --hold-seconds 900
python3 IMAndroid/scripts/verify_shared_sdk.py --phase 11 --serial <设备序列号> \
  --endpoints <隔离后端/test-endpoints.json> --output <证据目录>
```

真实服务使用已有本地服务端构建，缺少时按脚本提示构建。验收使用专用 `.sharedverification` App，测试 CA 只加入该 Debug 构建；不清空正常 App、不修改系统信任库。测试夹具通过真实 HTTPS 建立隔离账户、私聊及联系人头像；实际 App 和对端均调用共享 SDK，没有旧 Kotlin SDK 依赖。ADB reverse 与 relay 由驱动创建和清理。

第十一阶段结果见 [回复、转发与表情回应验收](../experiments/swift-android/verification/phase11/RESULTS.md)，前阶段回归分别使用 `--phase 10`、`--phase 9`、`--phase 8`、`--phase 7`、`--phase 6`、`--phase 5`。既有 iOS 公开接口清单见 [sdk-parity](sdk-parity/README.md)，该清单用于兼容性检查，不代表 Android UI 全量对齐。
