# Android 工程约定

- 最低支持 Android 12（API 31），App 与平台 SDK 的 minSdk 保持一致。
- 新增 UI 使用 Compose 与 Navigation 3，保留 iOS 的三标签共享详情栈模式。
- Android App 仅依赖 `sharedsdk` 业务接口；Swift 共享运行时持有业务和 SQLite，`swiftplatform` 只处理 Android Keystore / HTTP / TLS。不得恢复独立 Kotlin 业务 SDK；副作用不进入 Composable。
- UI 模型所有层级均使用不可变值和 kotlinx immutable collections。`val List` 或 `@Immutable` 不构成深度不可变保证。
- 实时 Protobuf 合同只来自根目录 `Protocol`；HTTPS 合同以 `IMV2Core` 的 Codable 类型及服务端实际路由交叉核对。与 Swift 的 wire、身份规范化、幂等、游标、指纹合同保持一致，不另造客户端协议。
- 不记录密码/令牌/撤销证明，不提供 trust-all TLS，不把演示数据混入真实模式。
- 改动后运行受影响的单元测试、assembleDebug、lintDebug；导航或平台持久化变化运行对应 connectedDebugAndroidTest。
- 未对齐功能和未执行的真实端到端验收明确记录在 README，不宣称全量 SDK 已复刻。
- Git 提交标题与正文使用中文。
