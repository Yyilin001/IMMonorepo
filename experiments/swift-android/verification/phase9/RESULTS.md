# 第九阶段：图片、文件消息与资源传输

2026-11-12，延续 `codex/swift-android-feasibility`。Android 的附件业务接入原有 Swift 资源中心、上传引擎、下载缓存和消息发送服务，没有新增 Kotlin 业务 SDK。

## 已实现

- 聊天页选择图片或文件、附带文字发送、附件详情、图片预览、原件下载、保存到系统文档位置；“我的”与附件页可进入上传/下载任务页。任务状态和允许的暂停、继续、重试、取消操作来自共享 SDK。
- 每次消息一个附件，上限 32 MiB。文件按 64 KiB 输入 Swift 私有暂存，资源中心完成大小、摘要和用途校验。图片沿用 Android 设备解码工具，源文件最多 10 MiB、长边最多 2048，按原比例转为 JPEG 并移除元数据。
- 上传、分片状态、处理轮询、发送冻结与交接、消息身份和恢复仍由原有 Swift 服务和 SQLite 持有。头像与消息共用同一个资源中心和上传引擎。切换会话、后台、退出和关闭清理当前页面的数据；已交接的任务保留持久身份。未提交附件的空暂存标记用于下次打开时回收选择，不承诺恢复页面草稿。
- 对象 HTTP 使用独立的流式平台适配，不扩大认证 HTTP 的正文限制。上传从受控文件流式读取，下载按 64 KiB 返回 Swift；不自动重定向或重试，不把账户认证头复制到对象请求。关闭和取消排空实际 I/O 后释放句柄。对象 HTTP 状态、Retry-After、平台 I/O 失败和计划过期保持原有 Swift 恢复策略所需的错误分类。
- 下载仍经过原有范围下载、长度/SHA-256 校验、资源授权和租约。保存文件通过 256 KiB SDK 分块，每次重新借用授权文件，不把 SDK 缓存路径暴露给 Kotlin。保存失败时尝试删除未完成文档；成功导出的外部副本由用户选定位置管理。

## 平台兼容边界

Android Foundation 不支持 Apple 的备份排除文件属性；范围下载暂存改用账号隔离目录和 `0600` 权限，Apple 分支保持原样。下载网络约束通过 package 范围的 TaskLocal 传递给 Android 流式适配；Android 默认 URLSession 仍拒绝无法执行的限制。Android 将对象连接绑定到已检查的网络，并在响应/分块读取时检查网络能力和 Data Saver，避免网络切换后静默使用不允许的网络。iOS 继续使用原有 URLRequest 属性和 URLSession 路径。

## 验证

第九阶段真实后端用例从 `MainActivity` 登录开始：对端发送图片和 9 MiB 文件，App 预览、下载并通过系统文档接口保存，SHA-256 与原文件一致；App 选择图片后转换上传，对端读取预览；App 在实时连接断开时冻结另一个内容不同的 9 MiB 文件，关闭完整客户端再重新打开，消息只发送一次，对端下载后的 SHA-256 一致。文件上传经过真实 8 MiB 分片边界。

同时覆盖 Data Saver 拒绝受限下载及恢复后的成功读取、导入途中取消、错误消息引用拒绝、A→C 账号隔离、临时选择标记回收；结束时客户端、JNI 操作、HTTP 和 TLS 句柄均归零。系统文档结果使用真实 URI 注入，见下方范围说明。

服务端只读 SQL 独立核对最终用例的四个媒体：上传会话全部 `completed`、媒体全部 `available`，每个媒体恰有一个有效消息引用；四条消息各接受一次。详细记录见 [后端独立查询](backend-observation.json)。

最终检查数量和同包摘要见 [summary.json](summary.json)、[设备验收](api31-app.json)、[instrumentation 输出](instrumentation.txt)、[iOS API 比对](api-compatibility.json)、[SDK 与打包审计](single-sdk-audit.json)、[源文件摘要](source-sha256.json) 和 [校验日志摘要](validation-logs.json)。

| 检查 | 实际结果 |
| --- | --- |
| Swift 资源、媒体传输、范围下载、发送与重试调度 | 332 项 / 47 suites 通过 |
| iOS 附件下载、暂存、上传及文件租约 | 18 项通过，0 失败 / 跳过 |
| iOS arm64 simulator package 构建 | 通过 |
| 相对第八阶段的 iOS 公开 API | 6,079 项；新增、删除、变更均为 0 |
| Python 验收工具测试 | 10 项通过 |
| API 31 arm64，第九阶段 App 真实后端 | 1 通过，45.127 秒，无跳过 |
| 同一 APK，第八阶段头像/扫码回归 | 1 通过，40.530 秒，无跳过 |
| 同一 APK，第七阶段资料/邀请/禁言回归 | 1 通过，47.374 秒，无跳过 |
| 同一 APK，第六阶段联系人/群管理回归 | 1 通过，46.340 秒，无跳过 |
| 同一 APK，第五阶段聊天/账号回归 | 1 通过，39.849 秒，无跳过 |
| Android 构建与 App / SDK Lint | 通过；JVM 单元测试任务为 NO-SOURCE |
| 普通 Debug 包构建和 Lint | 通过；不包含测试 CA，此包未另做设备验收 |
| DEX、依赖和 native 摘要审计 | 无旧 Kotlin SDK；仅 app/sharedsdk/swiftplatform；合并库匹配构建清单，APK 匹配 stripped 库 |

最终隔离后端的 HTTP 汇总包含同包第五至第九阶段五组用例，不能把其总次数当作第九阶段单用例操作次数。四个本次专用后端均已停止，专用测试包、adb reverse、模拟器和 AVD 已清理；用户原有 Android / iOS 模拟器保留，见 [清理记录](cleanup.json)。

## 复现与范围

```sh
python3 experiments/swift-android/build_probe.py --reuse-capabilities --shared-sdk
# native 构建完全结束后再打包 Android。
python3 IMV2/scripts/verify_v2_isolated_native_account.py --hold-seconds 900 --resource-part-uploads
python3 IMAndroid/scripts/verify_shared_sdk.py --phase 9 --serial <owned-api31-emulator> --endpoints <isolated-root>/test-endpoints.json --output <output>
# 同一后端和 APK，再运行 --phase 8 / 7 / 6 / 5。
```

本阶段仅验证 API 31 arm64 模拟器。系统选择器和文档创建器由 instrumentation 返回真实 URI，其后的设备图片转换、文件流、JNI、SDK、HTTPS 和真实后端均实际执行；未人工操作系统选择器。恢复验收关闭并重开完整 App SDK 所有者，不是操作系统强杀/断电测试。

当前仅显示最近 50 个传输任务；不提供系统后台上传下载、多附件消息、完整资源目录、视频/音频播放或旧 Kotlin 数据迁移。没有验证真实设备蜂窝切换、传输中途网络政策改变、对象服务 HTTP 故障注入或 32 MiB 上限压力测试。暂停/继续/重试控件已接入，未逐项新增真实网络中断验收；对应资源状态机由共享 Swift 回归覆盖。
