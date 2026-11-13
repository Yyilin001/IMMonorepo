# 第二阶段验证结果

日期：2026-11-12；分支：`codex/swift-android-feasibility`。本轮验证共享运行时和平台拆分，不代表 Android App 已接入完整 Swift SDK。

## 已完成

- `IMV2ClientRuntime` 承载原 SDK 业务实现；`IMV2ClientNetwork` 提供 HTTP/TLS 适配边界；`IMV2ClientPlatform` 收纳锁、串行执行器、随机数及文件能力；`IMV2ClientApple` 保存 Keychain、Passkey 和后台系统任务。原 `IMV2ClientKit` 产品及 import 入口继续可用。
- Apple HTTP 保留原字节流路径、会话池和认证策略。FoundationNetworking 使用适配器持有的 session 及任务路由，复用连接并以实际完成回调作为取消排空边界。运行时仍统一处理准入、绝对截止时间、冷却和指标。
- 搜索改为 Crypto + Darwin/Android/Glibc 文件锁；共享搜索 actor 使用平台串行执行器。索引格式和摘要算法不变。
- 公开 API 改为导出五个模块及扩展图，共 6,079 项。原 6,023 项声明按路径/签名核对无缺失；三处 actor Keychain 构造器改为扩展中的委托构造器，编译器标记 `convenience`。这不是 ABI 兼容性声明。

## 实际执行

| 检查 | 结果 |
| --- | --- |
| SDK 全量串行测试 | 53 XCTest + 1,528 Swift Testing 通过 |
| 最终 HTTP 路由/传输改动复验 | 13 XCTest + 7 Swift Testing 通过，含共享 session 的 20 个并发请求隔离 |
| MessageSubstringSearch | 52 项通过 |
| iOS 17 arm64 模拟器目标 | 编译通过 |
| iOS 18.5 App 兼容性测试 | 15 项通过：后台回调、文件保护、离线启动 |
| Android API 31 arm64 | 完整运行时编译、动态库链接及 Kotlin/JNI 调用通过 |
| Android 设备验证 | 16 项通过，已核对安装 APK 的 SHA-256 |
| Gradle | testDebugUnitTest（无单元测试源码）、assembleDebug、assembleDebugAndroidTest、lintDebug 成功 |
| API 清单 | 编译器重新导出，`export_sdk_api_inventory.py --check` 通过 |

Android 验证运行真实 MessageSubstringSearch 的中文、组合字符与 emoji 查询，确认独占写锁、完整性检查及重开；通过安装绑定接口打开完整 GRDB store，启动共享搜索 actor，读取并关闭后再次打开。

生产 HTTP 验证正常响应、已知长度/分块响应上限、重定向拒绝、绝对截止时间、有效公网 TLS 和自签名拒绝。取消流式请求后服务端观察到断开，本轮取消并排空耗时 **12 ms**；该数字只是本次记录，不是性能承诺。JNI 句柄在每项测试后归零。

初次 SDK 全量并发运行出现时间相关失败及失效 session 异常；显式 `--no-parallel` 重跑全量通过。iOS 保护策略测试的旧记录器未跟踪 `.tmp` 到 `.result` 的原子重命名，已按文件身份记录，生产保护逻辑未改变。Android 验证期间旧 AVD 出现 shell/网络挂起，最终在新建的 API 31 AVD、禁用 GPU 的环境完成全部验证；不将挂起的运行计作通过。

## 复现与范围

工具链和探针命令见 [验证工程 README](../../README.md)。SDK 全量测试使用：

```sh
xcrun --toolchain XcodeDefault swift test --package-path IMV2ClientKit --jobs 4 --no-parallel
xcrun --toolchain XcodeDefault swift test --package-path MessageSubstringSearch --jobs 4
```

`api31-debug.json`、`api31-debug-instrumentation.txt`、`native-manifest.json` 保存本轮 Android 结果；`validation.txt` 保存 Apple/Gradle 摘要及完整本地日志摘要；`api-compatibility.json` 保存声明核对结果。

本轮未重跑 API 36 和 R8，第一阶段对应结果只适用于当时的二进制。Android 原生 TLS 字节连接、Keystore、网络条件监控、系统后台任务及真实后端验收仍未实现。受限网络策略无法执行时明确失败；默认自动下载网络条件不可用。资源上传/Range 代理已跨平台编译，本轮未单独做 Android 大文件端到端验收。

现有 iOS App 源码入口保持兼容；模块身份已经改变，需要重新编译，内部测试须显式导入所属模块。Android 平台的备份排除、文件保护和设备限定存储必须由平台实现，不以 Apple 属性的空操作替代安全策略。
