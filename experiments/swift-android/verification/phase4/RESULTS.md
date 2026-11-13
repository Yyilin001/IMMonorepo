# 第四阶段：Kotlin 接口与真实 Android App 验收

日期：2026-11-12。分支：`codex/swift-android-feasibility`。本阶段实现独立 `IMV2SharedSDK` 动态产品、Kotlin `SharedClient` 接口，以及实际 `MainActivity` 的可选共享运行时入口。账户认证、凭据签发、恢复账本、Protobuf、SQLite 同步和连接代次继续复用 Swift；Android 提供 Keystore、TLS 和认证 HTTPS 物理执行。

## 真实后端与设备结果

API 31 arm64 专用模拟器运行 **1 项集成测试，1 通过、0 失败、0 跳过**，耗时 23.608 秒。它包含以下连续步骤，不把步骤数冒充测试数：

1. 独立夹具在真实账户服务注册账户并提交陌生人消息偏好变更；实际 App 拒绝错误密码，随后正确密码登录、签发设备凭据并完成 TLS 认证。
2. Swift 同步引擎应用非空投影，SQLite 与 ACK 水位达到 **1**。
3. 透明 TCP relay 关闭真实 TLS 字节流，App 观察离线；独立设备在账户服务提交第二条偏好变更。
4. 恢复 relay 后前台 Flow 自动重连，成功认证连接数达到 **2**，SQLite / ACK 水位达到 **2**，Compose 页面显示正确偏好。
5. 关闭 Activity 并排空所有者，然后重新打开同一命名空间；不重放密码，从 Keystore 与 SQLite 恢复到水位 2，再次连接并同步。
6. 对另一端点发起阻塞 TLS 握手中的 HTTPS 登录，取消 Kotlin job；服务端观察物理连接关闭，取消耗时 **18ms**。最终客户端、操作、HTTP 和 TLS 资源均排空。

后端为隔离 PostgreSQL 16、账户服务、HTTPS edge、placement quorum 和真实 TLS 网关，使用已有本地服务端构建；本阶段没有重新构建这些服务端程序。SQL 独立观察确认 `stranger_message_permission` 有 **2** 条同步日志，最大确认水位 **2**。relay 不解密 TLS；没有伪造同步响应或跳过认证。测试 CA 仅加入本次专用 Debug App，不修改设备/系统信任库。

最终 Debug APK SHA-256：`a27b2188c26c88c50032c9d41a61baa4cd2fbe18dc9e314a428f7dd081a858dc`，与设备实际安装包一致。Debug 和 Release 均仅含 `arm64-v8a`；Release 不含测试 CA。

首次编写夹具时曾错误要求空账户产生非零游标，并尝试用独立资料管线触发个人同步；现已使用真实账户偏好变更。偏好请求期限按服务端合同修正为 60 秒。最终安装包完成了整条验收，无跳过或降级。

## 其他验证

| 检查 | 实际结果 |
| --- | --- |
| Android App Debug / instrumentation APK 构建 | 通过 |
| App、sharedsdk、swiftplatform Lint | 通过 |
| App / sharedsdk JVM 单测任务 | NO-SOURCE，不计作测试用例通过 |
| 启用共享 SDK 的 unsigned Release / R8 构建 | 通过；本阶段未运行 Release 设备测试 |
| 共享 Swift 认证、取消、启动器、运行时、实时与 TLS 生命周期 | 76 项、8 suites 通过 |
| iOS 离线启动、后台传输及上传来源回归 | 15 项通过，0 失败 / 0 跳过；iOS 18.5 模拟器 |
| Swift package iOS arm64 模拟器构建 | 通过，deployment target 17.0 |
| 既有五个 iOS 模块公开符号 | 6,079 项，与第三阶段无新增、删除或声明变化 |

原 Apple 默认 HTTP、TLS、Keychain 和后台会话实现没有因本阶段而更改；新产品独立接入 Android。以上是针对改动范围的回归，不宣称运行了整个仓库的全部测试。

## 复现与交付范围

构建、生命周期用法和完整后端验收命令见 [sharedsdk/README.md](../../../../IMAndroid/sharedsdk/README.md)。先运行 `build_probe.py --shared-sdk --reuse-capabilities`，再通过 `-PimSharedSDK=true` 启用 App 入口。验收脚本使用专用 `.sharedverification` 包，正常 App 数据不受影响。

当前是 API 31+ / arm64 的可选迁移入口，包含密码登录、前后台连接、自动重连、有界会话标题列表及账户偏好读取。原 Kotlin App 仍是默认入口。完整聊天/联系人/资源/搜索 UI、退出与切换账号、Passkey、系统后台任务、其他 ABI 和旧数据库迁移未完成。`close()` 仅关闭所有者，不等同于退出或远端撤销。所有者重开已经验证；未将其表述为系统杀进程、断电或完整冷启动恢复验证。

## 保留证据

- [api31-app.json](api31-app.json)：最终真实 App 数值结果与安装包摘要。
- [instrumentation.txt](instrumentation.txt)：设备 runner 完成标记与实际用例。
- [backend-observation.json](backend-observation.json)：真实数据库聚合及服务端可执行文件摘要。
- [backend-http-summary.json](backend-http-summary.json)：隔离 edge 的方法、路径、状态码计数，不含请求正文或凭据。
- [summary.json](summary.json)：平台、测试、APK 大小及明确限制。
- [api-compatibility.json](api-compatibility.json)：iOS 符号比较。
- [shared-sdk-manifest.json](shared-sdk-manifest.json)：原生工具链和依赖库摘要。
- [source-sha256.json](source-sha256.json)：本阶段实现、合同及验证输入摘要。
- [validation-logs.json](validation-logs.json)：本机完整验证日志的位置与摘要；临时日志不保证在其他机器存在。

没有保存密码、令牌、私钥或带凭据的原始请求。专用后端已停止；专用 App、ADB reverse 和模拟器的清理结果记录在 [cleanup.json](cleanup.json)。本阶段未提交、发布或部署到共享环境。
