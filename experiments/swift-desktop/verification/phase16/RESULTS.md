# 第十六阶段：统一消息搜索和已读回执

iOS 原生 Swift 与 Android 绑定现在共用 `V2SearchService` 和 `V2ReadReceiptService`。没有新增 Kotlin 业务实现，没有修改网络合同、数据库 schema、平台 HTTP/TLS 或凭据存储。

## 实现与兼容

- `V2SharedSession` 注册并持有账号数据库的搜索服务和账号运行期的回执服务；关闭时取消观察、排空在途工作，再关闭数据库。
- 搜索统一查询、会话上下文、索引进度观察与索引启停。每个请求自带查询、筛选和游标，多窗口不共享可变查询状态。继续沿用原索引的精确子串、发布水位、账号/代次隔离，以及编辑撤回失效规则。
- 回执统一可见消息解析、隐私状态、重试、归档恢复、群读者查询、准备任务和执行器。iOS 继续使用本地验证的 checkpoint；Android 提交消息 ID，由 Swift 解析 `roomSequence`，不使用时间线序号或 ACK。过期/撤回视口行跳过，搜索不会推进已读。
- 原有单调合并、冻结身份、未知结果确认及隐私暂停语义保持不变。群读者查询返回后再次检查读取权限，取消或退出后的结果不会作为成功返回。
- 两端页面继续持有自己的分页、展示期限和过期结果防护。iOS 使用强类型 Swift 调用；Android 的 C/JNI/JSON/Kotlin 合同和 UI 不变。iOS 内部旧初始化入口保留以兼容原测试与宿主。
- `V2ConversationService.readCheckpoint(in:)` 提供已知房间头与本地应用进度，不改变既有 iOS 页面推进规则。

## 验证

- iOS 会话、搜索并发、账号与恢复回归 **178 项通过，0 失败**。
- 共享门面与会话生命周期 18 项、原搜索/回执领域 36 项通过。新增测试覆盖独立分页、跨账号游标、关闭后拒绝、隐私暂停、订阅取消互不影响、视口序号解析、查询返回后权限重检，以及关闭排空不配合取消的网络操作。
- iOS 原生 Swift 页面真实后端 6 项功能与 2 项 scope 清理通过：注册登录、独立安装发送与阅读、实际成员建群和群消息、对方阅读/回复、群已读详情，以及全局搜索定位到同一消息。
- 原生 Swift 真实后端通过：直接调用搜索和回执门面，由独立客户端确认已读；同时回归消息操作、多窗口、物理断线、持久化重开、无重复发送与账号隔离。
- Android 最新原生库的第 10 阶段真实后端场景通过：全局 Unicode 搜索/分页、搜索不发布已读、超出最近 50 条的定位、视口上报、群已读详情、编辑撤回同步及索引失效、断线重开和账号隔离。客户端及操作句柄泄漏均为 0。
- 普通 Android Debug/Release、lint 及验收脚本要求的测试通过；实际 macOS dylib C ABI 生命周期通过。
- 旧五模块 **6,079 条公开符号记录逐字一致**。共享原生模块由 120 增至 157 条，原有条目无删除或修改。记录包含类型、属性和枚举项，不等于业务函数数量。

普通未签名 Release 为 **39,130,150 字节（37.32 MiB）**，不包含隔离后端 CA。模拟器验收使用专用 Debug 包，不代表 Release 分发验证。

## 验证边界

真实后端为本机隔离 PostgreSQL、HTTPS edge 和 TLS 网关；未使用生产账号。iOS/Android 使用模拟器，macOS 验证 SDK 宿主，没有验证桌面 UI、真机或签名分发。Windows 适配缺口未改变。无障碍审计不在此次业务门面专项验收范围，未宣称解决之前的 Dynamic Type 限制。

本轮保留了测试开发失败记录：回执观察只在工作准备后发布变化，不能用草稿写入当作工作变化；旧 UI 脚本误认占位文字为消息且仍引用已移除的刷新菜单。修正测试的真实输入和等待边界，没有修改业务行为来迎合脚本。

证据：[总览](summary.json)、[iOS 后端](ios-backend-summary.json)、[iOS 单元回归](ios-unit-summary.json)、[保留的初次失败](retained-failures.json)、[源码指纹](source-sha256.json)、[清理记录](cleanup.json)、[API 对照](api-compatibility.json)、[共享与领域测试](unit-tests.json)、[原生 Swift 后端](native-backend.json)、[Android 后端](android-phase10.json)、[打包](android-packaging.json)、[C ABI](c-abi.json)。

复现：共享测试选择 `FacadeTests|SharedSessionOwnershipTests|V2ReadReceipt|V2MessageSearchTests`；原生后端使用 `IM_SHARED_BACKEND_ENDPOINTS` 运行 `SharedDesktopBackendTests`。Android 重建共享原生库后，在明确的设备与隔离端点运行 `verify_shared_sdk.py --phase 10`。iOS 使用 `IMAPP_LOCAL_TWO_INSTALL_SEARCH_RECEIPT_FACADE_ONLY=true`，调用隔离后端脚本的 `--group-read-ui` 并显式指定两个专用模拟器。
