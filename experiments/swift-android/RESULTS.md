# 第一阶段结果：可以继续分层改造

验证日期：2026-11-12。分支：`codex/swift-android-feasibility`。

**现有 Swift 核心和主要依赖可以在 Android 进程中运行；SQLite/FTS5 和显式 Kotlin → Swift 取消链路满足本轮验证合同。现有 ClientKit 不能原样迁移，HTTP API、后台任务及搜索包仍有明确适配工作。**

## 实际执行结果

| 环境 | 结果 | 证据 |
|---|---|---|
| Android 12 / API 31 / arm64，Debug | 12/12 通过 | [JSON](verification/api31-debug.json)、[runner 输出](verification/api31-debug-instrumentation.txt) |
| Android 16 / API 36 / arm64，Debug | 12/12 通过 | [JSON](verification/api36-debug.json)、[runner 输出](verification/api36-debug-instrumentation.txt) |
| API 31 / arm64，R8 测试壳 | 12/12 通过 | [JSON](verification/api31-release.json)、[runner 输出](verification/api31-release-instrumentation.txt) |

以上是同一组 12 个用例在三个环境运行，不是 36 个不同用例。均核对 APK 与设备安装包 SHA-256，并检查完整测试集合，无跳过。Debug/Release 构建与对应 Lint 通过，各 0 错误、4 个警告（依赖新版本提示、仅 arm64、备份规则声明、测试壳未配图标）。R8 测试壳保留 debuggable、调试签名及 instrumentation 共享的 Kotlin/coroutines 运行时入口；不代表完整生产 Release 优化或发布验收。

## 依赖、SQLite 与搜索

以下内容在真实 Android App 进程中经过 Kotlin/JNI 调用执行：

- 仓库原有 `IMV2Core` 与 `IMV2Compression` 交叉编译；命令常量合同和 zlib 往返通过。
- 仓库生成的整份 Protobuf 源码参与编译；含中文设备标识的编码/解码通过。
- swift-crypto：SHA-256 已知向量、AES-GCM 加解密、随机密钥生成通过。
- GRDB 7.11.1 + 自带 SQLite 3.51.2：WAL、FTS5 ASCII token 短语位置查询通过。
- 消息写入和 ACK 水位在同一事务内成功提交；故意抛错时两者共同回滚；关闭数据库后重新打开仍保留正确水位。
- 中文文件路径经过 Kotlin UTF-8 → JNI → Swift 正常打开。

SQLite 静态链接进探针动态库，并启用 `SQLITE_ENABLE_FTS5`、`SQLITE_ENABLE_SNAPSHOT`、`SQLITE_THREADSAFE=1`。编译 SNAPSHOT 不等于本轮已经覆盖 GRDB 的所有快照/并发读行为。没有依赖 Android 私有的系统 SQLite 动态库。

**完整 `MessageSubstringSearch` 仍不能原样编译。** 本轮实际编译的首个错误是 `no such module 'CryptoKit'`，见[编译输出](verification/search-original.txt)。后续需要把其加密依赖接到 `Crypto`，并处理源码中的 Darwin 文件锁/POSIX 调用。FTS5 测试通过不能扩展表述为整个搜索 SDK 已可用。

直接依赖与 ClientKit 版本一致；探针锁定的传递依赖 swift-asn1 为 1.7.4，ClientKit 原锁文件为 1.7.1。本轮未修改原锁文件。完整版本和 revision 见 `Package.resolved`。

## HTTP 能力与差异

| 检查 | 结果 | 对下一阶段的影响 |
|---|---|---|
| FoundationNetworking 基础 dataTask | 编译及运行通过 | 可作为候选前台 HTTP 底层 |
| `URLSession.bytes(for:)` | 无此成员 | 当前 `V2HTTPExecutor` 需要更换读取实现 |
| 设置 `waitsForConnectivity` | 只读属性，编译失败 | 等待网络/暂停策略由共享调度或平台适配提供 |
| `background(withIdentifier:)` | 明确 unavailable | 后台系统传输必须另做 Android 适配 |
| delegate 分块接收 | 通过 | 可在追加到应用缓冲前执行大小上限检查 |
| 已知 Content-Length / chunked 超限 | 都拒绝 | 不依赖服务端声明长度才能执行上限 |
| 自动重定向 | 拒绝，原 302 返回，服务端仅收到一次请求 | 保留原有禁止自动转发的策略 |
| 150ms 绝对截止时间 | 三组实测 154 / 227 / 156ms 返回 | 取消并等待网络任务完成后结束 |
| 公网 HTTPS | 系统默认信任下返回 200 | 验证基本 TLS 成功路径 |
| 未信任自签名 HTTPS | 被拒绝，服务端未收到 HTTP 请求 | 没有关闭证书验证 |

编译检查见 [bytes](verification/urlsession_bytes.txt)、[connectivity](verification/waits_for_connectivity.txt)、[background](verification/background_urlsession.txt)。有独立基础 API 编译成功作为对照，避免将工具链配置失败误判为缺少 API。

TLS 失败在本次 FoundationNetworking 中映射为 `NSURLErrorDomain Code=-1`，同时含 `SSL certificate problem: self signed certificate`；不能直接照搬 Apple 错误码分类。API 31 首次公网请求失败是模拟器未启用网络，开启临时测试网络后重跑成功，原设置已恢复。

本轮 HTTP 是独立 delegate 探针，不是已移植的 `V2HTTPExecutor`。未覆盖账户认证刷新、上传/Range、连接池、公平调度、后台系统任务、证书固定、企业/用户 CA 或完整 Android Network Security Config 行为。大小测试验证的是应用层缓冲控制，不是整个网络栈的内存峰值。

## 异步取消与调用边界

验证路径为 `Kotlin coroutine → JNI 数字句柄 → Swift Task`。取消在 Kotlin `finally` 中显式传给 Swift，在 `NonCancellable` 清理区等待终态，然后释放句柄。没有跨线程保存 JNIEnv，也没有让 JVM 持有裸 Swift 对象指针。

- 每次执行 30 轮 sleep 取消、20 轮 AsyncStream 取消，结束后句柄数均为零。
- Stream 结束前取消并等待 producer；未把停止收集等同于生产任务已退出。
- 重复取消幂等；未完成时禁止释放；完成后释放一次；旧句柄不能访问新任务。
- 流式 HTTP 取消后等待 URLSession 完成回调；服务端实际观察 socket 断开。
- 三组 HTTP 取消并收尾实测分别为 11 / 13 / 13ms，仅代表本机模拟器观测，不是性能保证。

结论是**显式桥接方案可行**。本轮使用可审查的小型 C ABI/JNI 与轮询，不证明 swift-java 自动生成器能自动映射现有 actor、协议和 AsyncStream。生产 Kotlin suspend/Flow 接口、背压、高并发、MainActor/UI 线程集成仍需后续验证。

## 包体与工程边界

[构建摘要](verification/build-summary.json)记录 APK 大小、SHA-256 和打包的 native 库；[原生构建清单](verification/native-manifest.json)记录工具链、源协议摘要和未裁剪库摘要。

- Debug APK：88,536,255 字节，约 84.4 MiB。
- R8 测试壳 APK：88,625,401 字节，约 84.5 MiB。
- APK 中 19 个 arm64 native 库合计 84,638,528 字节，约 80.7 MiB。
- 最大项为 Foundation ICU，约 38.2 MiB；探针库约 14.9 MiB，包含本轮完整协议与依赖代码。

这些是当前验证包的原始 APK 字节，未做 AAB 下载压缩估算、运行库裁剪或生产链接优化，不能直接当作正式 SDK 的最终增量。两台模拟器都是 4 KiB 页；真机、其他 ABI 和 16 KiB 页设备运行未验收。

SDK 与 NDK 已安装供后续复用，未切换全局 Swift 工具链。测试只安装独立包 `com.xmtx.im.swiftprobe`；既有 API 36 模拟器空间不足后使用新建临时 AVD，未清理用户的其他 App。结束后移除测试包、恢复 API 31 网络设置并关闭本轮启动的模拟器，原先运行的模拟器保留。

## 建议进入第二阶段的范围

1. 将通用帧连接逻辑从 Apple `Network` 条件编译中移出，通过字节连接工厂注入系统实现。
2. 给共享 HTTP 执行器增加底层接口，保留原有准入、绝对预算、响应上限和确定性分类；用本轮 delegate 行为作为 Android 候选实现。
3. 保留同一套 GRDB/SQLite 业务事务，固定 Android SQLite 构建及打包；迁移搜索模块的 Crypto/POSIX 依赖。
4. 将取消和资源释放合同作为 Android 桥接接口的强制要求，再评估 swift-java 生成器与生产 suspend/Flow API。
5. 将运行库体积、MainActor 边界、KeyStore/安装绑定、系统后台任务纳入下一阶段门槛。

本阶段没有改写生产 SDK，没有迁移 Android 业务模块，也没有执行真实 IM 后端收发、进程崩溃恢复、设备凭据或旧数据迁移验收。
