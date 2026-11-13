# 项目提交约定

本仓库所有后续 Git 提交的标题和正文都使用中文，包括合并、回退和自动化生成的提交说明。代码标识符、路径、命令和专有名词保留原文。

# 客户端 SDK 多平台目标

- 长期目标为 iOS、Android、macOS、Windows 共用一套 Swift 业务 SDK；认证、同步、持久化、搜索、消息和资源业务不得另写 Kotlin、C# 或其他平台版本。
- 共享业务与应用级会话组合不直接绑定 Android / Apple / Windows 实现；凭据保护、HTTP / TLS、文件系统、系统生命周期等通过平台适配接入。语言绑定仅处理接口、值转换和调用生命周期，UI 可按平台实现。
- 保持既有 iOS 行为与接口；APK 压缩、Android JNI 导出等优化限定在对应平台，不作为所有平台的共同构建配置。
- 应用级组合位于 `IMV2SharedRuntime`，由 `IMV2SharedAndroid` / `IMV2SharedApple` 注入平台能力，`IMV2SharedSDK` 保留 C ABI 和平台入口选择。平台支持声明必须区分编译、设备运行、真实后端和分发验证；macOS / Windows 的缺口见 `IMV2ClientKit/README.md`，不能因命名为 Shared 就认定 Windows 已可用。
