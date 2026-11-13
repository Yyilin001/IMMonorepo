# 第五阶段：Android 直接使用唯一共享 SDK

日期：2026-11-12。分支：`codex/swift-android-feasibility`。

Android App 已默认且唯一使用共享 Swift SDK。按用户明确要求，旧 Kotlin `clientkit` / `platform` 模块、旧 App 业务入口，以及依赖旧实现的测试和 benchmark 已删除；不再用构建开关选择旧业务。`protocol` 仅在启用历史探针时生成 Java 测试类型，未进入生产 App。

## 实现

- 会话列表：读取共享 SQLite，50 条稳定游标分页，显示标题与最新消息预览。
- 聊天：Navigation 3 详情、50 条消息窗口及历史分页、待发送记录分页；本地权限检查拒绝其他账号的房间。撤回消息不输出原正文。
- 文本发送：共享 `V2MessageSendOperationService`、持久意图、`V2OperationWorkDispatcher` 和原身份确认；UI 区分入队、等待连接、确认结果、已发送等待投影与终态。消息及待发送记录使用同一 SQLite 读取版本，避免回执收敛时重复或丢失气泡。
- 接收和恢复：共享房间恢复 runner、个人同步、设备房间进度与重连唤醒；不再有 Kotlin 版同步或消息协议实现。
- 退出与切换：先持久保存退出意图，再隔离认证代次、排空实时/发送任务、关闭数据库、持久交接撤销并删除本机凭据。失败保留退出意图及重试入口，恢复时先完成退出；页面和草稿按账号代次隔离。
- 默认构建、Manifest、依赖、CI 和文档均切换到共享 SDK。生产工程依赖仅有 `:sharedsdk`、`:swiftplatform`；Debug DEX 未发现旧 `com.xmtx.im.client`、`com.xmtx.im.platform` 或生成的 Kotlin SDK 协议包。

## 最终真实后端验收

API 31 / arm64 专用模拟器运行 **1 项集成测试：1 通过、0 失败、0 跳过，45.851 秒**。以下是同一用例的连续步骤，不计作多个独立测试：

1. HTTPS 夹具注册 A/B/C 并建立私聊。真实 App 拒绝错误密码，然后登录 A，显示会话列表与对端 B 的消息。
2. App 文本发送，独立共享 SDK 对端 B 收到且仅有一条；App 收到持久投影后待发送气泡收敛。
3. 透明 relay 关闭 App 的真实 TLS 字节流。App 离线入队，关闭并排空整个所有者，再重新打开，仍有原待发送记录。
4. relay 恢复后自动重连，原发送送达对端且仅出现一次。
5. A→B：A-C 私聊不出现在 B 的列表，旧聊天窗口和草稿清空；SDK 直接请求 B 无权读取的 A-C 房间也被拒绝。
6. B 在 App 中回复，退出后关闭所有者；重新打开仍未认证且无会话/聊天数据。再登录 A，可以恢复自己的会话并收到 B 回复。
7. 取消阻塞 TLS 握手中的 HTTPS 登录，物理连接关闭，取消耗时 **13ms**；所有 App/对端客户端、操作、HTTP 和 TLS 资源排空。

独立 PostgreSQL 观察：**4 条消息、4 个发送身份、0 个重复正文、3 个撤销设备、3 个撤销刷新会话**。消息来自真实服务端，不注入投影或伪造 ACK。隔离后端包含 PostgreSQL 16、账户服务、HTTPS edge、placement quorum 和 TLS 网关，使用已有本地服务端构建，本阶段没有重建服务器。

最终 APK SHA-256：`7eb089c966d5628a80efbd7b5633f0b0906ba681bbe105fe9b3e331a5640ca32`，与实际安装包一致。App 不依赖旧 Kotlin SDK，测试对端也已改用共享 SDK；只有测试用 HTTPS 夹具负责账户和房间准备。

增加本地权限断言后，夹具暴露了“目录已出现、权限投影尚未补齐”的时序窗口。最终夹具由对端作为私聊发起方，并有界等待正向读取准入后开始发消息；对其他账号房间的拒绝断言保留，没有放宽权限检查。后续检查还移除了重试确认对第一页发送历史的错误限制，直接复用共享服务的账号/操作身份验证，并补跑 23 项发送测试和完整真实后端流程。所有最终证据均来自此版本。

## 其他验证

| 检查 | 结果 |
| --- | --- |
| 默认 App Debug / instrumentation APK + App、sharedsdk、swiftplatform Lint | 通过，无需共享 SDK 开关 |
| Release / R8 unsigned 构建 | 通过；仅 arm64，无测试 CA；本阶段未在设备运行 Release |
| Swift 认证、取消、启动器、实时、TLS、发送、房间恢复、调度、会话/时间线回归 | 197 项、18 suites 通过；最终补跑发送子集 23 项通过，不与前次相加 |
| iOS 后台桥接、上传来源、离线启动、会话发送和会话存储回归 | 170 项通过，0 失败 / 0 跳过；iOS 18.5 模拟器 |
| 新 SDK 产品及 iOS arm64 模拟器构建 | 通过；iOS deployment target 17.0 |
| 既有五个 iOS 模块公开符号 | 6,079 项，相比第四阶段无新增、删除或声明变化 |
| Python 清单/设备报告工具测试 | 10 项通过 |
| App / sharedsdk JVM 单测任务 | NO-SOURCE，不计作通过用例 |
| GitHub Actions | 已更新并校验 YAML；未在远端执行 |

本阶段没有修改既有 Apple HTTP、TLS、Keychain 或后台会话默认行为。上述是针对改动范围的回归，不代表整个仓库所有测试均已执行。

## 范围与复现

构建及真实后端命令见 [Android README](../../../../IMAndroid/README.md)，接口见 [sharedsdk](../../../../IMAndroid/sharedsdk/README.md)。App 构建前必须生成 `libIMV2SharedSDK.so` 及其依赖；缺失时明确报错，不能生成缺库安装包。

当前 UI 覆盖文本聊天。联系人、群管理、资源/媒体、搜索、编辑撤回、已读上报、Passkey、系统后台任务与推送未接入。旧 Kotlin 凭据/数据库/发件箱未迁移，也未主动删除；旧安装需重新登录。旧实现的历史测试和 benchmark 不计入新 App 的能力证明。

已验证所有者关闭重开，未验证系统杀进程或断电。分页已实现，本例使用两个房间和四条消息，不是大历史或性能压力验收。仅验证 API 31 arm64 模拟器，未验证其他 ABI、真机或 Release 运行时。

证据：[App 数值结果](api31-app.json)、[instrumentation](instrumentation.txt)、[数据库观察](backend-observation.json)、[HTTP 聚合](backend-http-summary.json)、[唯一 SDK 审计](single-sdk-audit.json)、[iOS API 比较](api-compatibility.json)、[构建清单](shared-sdk-manifest.json)、[源摘要](source-sha256.json)、[汇总](summary.json)、[本机日志摘要](validation-logs.json)、[环境清理](cleanup.json)。不保存密码、令牌、私钥或原始请求正文。本机 `/tmp` 日志不保证在其他机器存在。

隔离后端、测试 App、ADB reverse 和专用模拟器已清理；正常 App 与原有模拟器未改动。本阶段未提交、发布或部署共享环境。
