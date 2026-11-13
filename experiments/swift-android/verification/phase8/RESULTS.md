# 第八阶段：头像编辑上传、群头像和邀请扫码

2026-11-12，延续 `codex/swift-android-feasibility`。Android 的头像和邀请业务继续由 Swift 共享 SDK 管理，Kotlin 仅负责不可变绑定、Compose 页面、设备选图/裁剪与二维码像素识别。

## 已实现

- 我的头像与群头像编辑页：系统选图、缩放/水平/垂直裁剪、预览、明确确认上传及移除。源图片最多 10 MiB，解码长边最多 2048，输出 512×512 JPEG、最多 512 KiB，并移除源元数据。
- `SharedAvatars` 接入原有资源中心、传输恢复循环、个人资料准备/命令分发和群头像恢复引擎。SQLite 持有上传与命令身份、资源保留关系；失败重试复用原操作，资料冲突后的重新应用需要确认。关闭账号所有者时取消并排空任务。
- 群头像重新读取管理权限，并保留用户确认的修订号；普通成员只能读取授权头像。对象传输使用计划凭据，不混入账号认证头；读取验证授权、期限、字节长度和 SHA-256。页面、后台和账号切换撤下授权图像及临时编辑数据。
- 邀请页新增相机 QR 扫描和二维码图片识别。扫码结果交给原有 Swift 邀请预览/申请服务，不打开任意 URL，不自动提交入群。相机权限按需请求，拒绝后可选择二维码图片。
- JNI 请求上限增至 1 MiB 以容纳 JPEG 编码，响应仍为 8 MiB；HTTP 对象上传仍受 512 KiB 限制。

## Android 文件兼容修复

真实 API 31 设备验收发现两个问题：尚不存在的资源目录经过 Foundation 路径解析时，`/data/user/0` 与 `/data/data` 别名不一致；Android SELinux 禁止应用数据目录的硬链接，导致个人头像原件复用于群头像时迁移失败。

Android 现在先解析既有祖先，再附加尚不存在的目录。已发布头像原件统一使用稳定的账号私有路径，缓存/保留分类、配额、淘汰和恢复由原有资源账本管理；不复制负载，也不移动仍有租约的文件。系统不会自动清理这些缓存原件，由 SDK 执行配额淘汰；传输暂存仍使用缓存目录。资源目录符号链接替换继续被拒绝。Apple 路径解析和硬链接布局保持原样。

这是 Android 首次接入头像资源存储。通用展示/文件导出别名未开放给 Android；不把本次修复视为通用文件功能全部可用。

## 验证与证据

| 检查 | 实际结果 |
| --- | --- |
| API 31 arm64，第八阶段 App 真实后端 | 1 通过，40.308 秒，无跳过 |
| 同一 APK，第七阶段资料/邀请/禁言回归 | 1 通过，45.596 秒，无跳过 |
| 同一 APK，第六阶段联系人/群管理回归 | 1 通过，47.282 秒，无跳过 |
| 同一 APK，第五阶段聊天/账号回归 | 1 通过，41.824 秒，无跳过 |
| Android 构建与 App / SDK Lint | 通过；JVM 单元测试任务为 NO-SOURCE |
| 普通 Debug 包构建和 Lint | 通过；无隔离测试 CA，此包未另做设备验收 |
| DEX、运行时依赖和 native 哈希审计 | 无旧 Kotlin SDK；仅 app/sharedsdk/swiftplatform；合并库匹配 native 清单，APK 匹配 Gradle stripped 库 |
| Swift 资料/群头像/资源文件及传输测试 | 104 项 / 12 suites 通过 |
| iOS 头像管线、群头像管理及裁剪测试 | 49 项通过，0 失败 / 跳过 |
| iOS arm64 simulator package 构建 | 通过 |
| 相对第七阶段的 iOS 公开 API | 6,079 项；新增、删除、变更均为 0 |
| Python 验收工具测试 | 10 项通过 |

完整结果与哈希见 [summary.json](summary.json)、[设备验收](api31-app.json)、[原始 instrumentation 输出](instrumentation.txt)、[iOS API 比对](api-compatibility.json)、[后端独立查询](backend-observation.json)、[校验日志哈希](validation-logs.json)。

主用例从真实 `MainActivity` 登录开始，独立共享 SDK 对端确认个人和群头像。系统选择器返回由 instrumentation 提供真实 PNG URI，其后的设备解码、裁剪、JNI、资源账本、HTTPS 上传和服务端回执均为实际链路。同一张图先作为个人头像上传/移除，再用于群头像，覆盖资源复用；关闭完整 App 客户端并重新打开后验证群头像仍可读。普通成员修改被拒绝。

二维码图片由独立对端的真实邀请生成，经 Android ZXing 像素解码，再由 Swift 预览/申请；群主批准后 App 同步到成员身份。非邀请 QR 被拒绝且旧预览清空。相机验收覆盖权限已授予后的实际扫描 Activity 打开/取消，未验证实体摄像头光学识别、权限拒绝页面或扫码时的 OS 进程死亡。

还覆盖 relay 断线重连、A→C 账号隔离、资源子目录替换为符号链接时拒绝访问且外部 canary 不变、恢复目录后重新打开成功；退出后客户端、JNI 操作、HTTP 和 TLS 均归零。

后端独立查询仅限最终成功用例的账号和群：个人资料更新回执 2 个，个人头像最终移除且修订为 3；群头像回执 2 个且操作身份不同，最终移除且修订为 2；个人和群上传各 1 个完成；二维码入群申请 1 个批准并具有成员修订号。HTTP 汇总包含同一隔离栈的排错运行及第五至第七阶段回归，不将其总次数当作单个用例的操作次数。

三个本次专用后端均已停止；专用测试包已卸载，adb reverse 清空，专用模拟器和 AVD 已清理。用户已有 Android 模拟器及 iOS 模拟器保留，见 [cleanup.json](cleanup.json)。

## 复现与范围

```sh
python3 experiments/swift-android/build_probe.py --reuse-capabilities --shared-sdk
# 等待 native 构建完全结束，再启动下面的验收。
python3 IMV2/scripts/verify_v2_isolated_native_account.py --hold-seconds 900
python3 IMAndroid/scripts/verify_shared_sdk.py --phase 8 --serial <owned-api31-emulator> --endpoints <isolated-root>/test-endpoints.json --output <output>
# 同一后端和 APK，分别 --phase 7 / 6 / 5 回归。
```

当前仍仅支持 Android API 31+ arm64；未提供拍摄新头像、通用大文件/媒体消息、系统后台传输、群元数据编辑、深链接自动导航、提前解除禁言及旧 Kotlin 数据迁移。本次验证不代表全量功能或所有设备兼容性验收。
