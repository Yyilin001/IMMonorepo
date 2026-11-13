# 共享 SDK 桌面接入（第十二阶段）

本阶段将应用级会话和功能组合移入 `IMV2SharedRuntime`。原有领域业务仍在 `IMV2ClientRuntime`；`IMV2SharedAndroid` / `IMV2SharedApple` 仅组装系统适配，`IMV2SharedSDK` 保留跨语言入口。Android JNI 名称、动态库名称、存储命名空间、业务请求及压缩打包配置不变。旧 iOS `IMV2ClientKit` 门面不切换到新入口。

## 当前交付范围

- macOS：共享 dylib 可构建，由 Python 非 Swift 宿主实际加载并调用 C ABI；Keychain 不存在/写入/覆盖/删除、安装绑定、句柄及返回缓冲区释放有测试。SDK 真实后端覆盖双端登录/消息/回复/回应、中文搜索、物理 TLS 断线、所有者关闭重开后的凭据/数据库恢复、无重复发送及第三账号隔离。
- Android：原有页面继续调用同一 SDK；回归范围与结果见本阶段验证目录。
- iOS：原有接口及相关回归继续检查；不更改 Keychain service/account、网络默认实现和 App 页面。
- Windows：增加原生预检脚本及搜索写入锁的 Win32 实现。当前没有原生 Windows 执行证据，也没有完整 Windows 平台适配；不得作为可用 Windows SDK 发布。
- 尚未交付 macOS / Windows App UI、沙盒文件授权流程、签名安装包、OS 强杀恢复或桌面自动更新。本阶段验证的是共享 SDK。

## 本阶段验证记录

结果和构建指纹保存在 [verification/phase12](verification/phase12/summary.json)。真实后端是本机隔离的 PostgreSQL、HTTPS 和 TLS 网关，不是模拟服务；未使用生产账号或修改系统信任库。

| 范围 | 验证 |
| --- | --- |
| macOS | 3 项：Keychain/绑定、C ABI 生命周期、双客户端真实后端；另由 Python ctypes 加载实际 dylib |
| Swift 业务/网络 | 53 项回归 |
| 搜索 | 15 项边界与恢复回归；原生锁探针检查竞争和进程退出释放 |
| iOS | 7 项 App 回归；五模块公开 API 的 6,079 条完整记录与上一阶段一致 |
| Android | 第 5–11 阶段 7 个真实后端场景；最终结果、APK 指纹以验证目录为准 |
| Windows | 仅 macOS 宿主探针通过，`windowsValidated: false`；原生执行及完整适配仍未完成 |

最终普通 Release（未签名）为 **38,974,154 字节，37.17 MiB**。20 个原生库解压共 96,495,600 字节，APK 中压缩为 35,869,787 字节，减少 60,625,813 字节（约 60.63 MB）。压缩设置仅作用于 Android Release；普通 Debug 保持原有打包方式。两种普通包均不含隔离后端 CA。设备真实后端验收使用独立验证 Debug 包，不能视为 Release 签名安装或分发验收。详见 [打包检查](verification/phase12/android-packaging.json)。

第十一阶段 Android 用例曾在会话摘要已到达、独立读取权限投影尚未完成时立即打开聊天而失败。测试已改为仅对这一明确的暂态错误进行有时限的 UI 重试，保留最终错误断言；没有放宽共享 SDK 权限检查。初次失败日志与最终回归结果均保留。桌面用例也等待实际可读权限，不能用目录存在代替授权。

## C ABI 合同

头文件为 `IMV2ClientKit/Sources/CIMV2SharedSDK/include/CIMV2SharedSDK.h`。载入对应平台库后使用 C 调用约定：

- `im_shared_create(bytes, count)` 接收 UTF-8 JSON，配置字段为 `accountURL`、`gatewayHost`、`gatewayPort`、`storageDirectory`。输入在调用期间借用，不保留宿主指针；限制 1 MiB，返回正客户端句柄，失败返回 0。同一存储根不允许重复所有者。
- `im_shared_submit(client, bytes, count)` 返回正操作句柄，拒绝或句柄无效返回 0；每进程最多 8 个客户端、128 个未释放操作。操作与快照格式沿用 Kotlin 绑定，业务结果不在语言绑定中重新计算。
- `im_shared_poll(operation)` 在完成前或句柄无效时返回 NULL。完成后返回独立、NUL 结尾的 UTF-8 JSON，字段为 `snapshot` 或 `error`；响应最多 8 MiB。每次成功 poll 都分配一份独立缓冲区，必须用同一 SDK 的 `im_shared_free` 释放，禁止宿主使用 `free/delete`。
- `im_shared_cancel(operation)` 请求取消但不释放句柄。宿主继续等待完成、读取结果，再调用 `im_shared_release`；不要把“已请求取消”当作物理 I/O 已结束。
- 关闭时停止提交、取消并排空现有调用，再提交 `close` 并等成功，释放所有操作后调用 `im_shared_release_client`。`close` 保留登录凭据，`signOut` 才执行持久退出。退出等已交接的持久操作不能靠释放句柄回滚。
- `im_shared_active` / `im_shared_clients` 仅用于无敏感数据的资源计数。错误以受控字符串返回，不通过异常穿越 C ABI。

macOS 接入保持系统 TLS 信任；SDK 不自动安装测试证书。仅测试目标内的隔离后端适配注入 CA，并同时校验 localhost 主机名，系统信任库不变。

## 本地验证

```sh
xcrun swift build --package-path IMV2ClientKit --product IMV2SharedSDK
xcrun swift test --package-path IMV2ClientKit --filter SharedPlatformTests
python3 experiments/swift-desktop/verify_c_abi.py \
  --library IMV2ClientKit/.build/out/Products/Debug/libIMV2SharedSDK.dylib \
  --output /tmp/shared-desktop-abi.json

# 使用已有本地隔离后端脚本；服务端二进制等前置条件先运行 --check 核对。
python3 IMV2/scripts/verify_v2_isolated_native_account.py --hold-seconds 900 --resource-part-uploads
IM_SHARED_BACKEND_ENDPOINTS=<isolated-root>/test-endpoints.json \
  xcrun swift test --package-path IMV2ClientKit --filter SharedDesktopBackendTests
# 验证完触碰 <isolated-root>/stop，等待脚本退出并检查服务清理。
```

真实后端测试使用两个独立客户端安装身份和隔离 Keychain 名称；测试结束删除这些测试项与数据库。注册创建方先发送初始化消息，确保收件方获得本地读取权限投影；目录到达不代表可以绕过权限检查。未提供端点时真实后端用例明确跳过，不把跳过算作通过。

## Windows 就绪检查与剩余阻碍

在原生 Windows 安装 Swift、Visual Studio C++ / Windows SDK、Python，并将 `swift`、`clang` 放入 PATH 后运行：

```powershell
python experiments/swift-desktop/windows/verify.py --output build/windows-readiness
```

脚本校验固定 SHA-256 的 SQLite 源码，构建原生 SQLite/FTS5/WAL/查询中断探针；通过独立进程验证搜索锁竞争、UTF-8 中文路径以及持锁进程终止后的重新获取，再尝试构建共享 SDK。原生构建失败或平台适配未完成时返回非零，不产生 Windows 支持通过声明。`--host-smoke` 只检查脚本与本机 POSIX 分支，结果始终保留 `windowsValidated: false`，不能替代 Windows 执行。

剩余工作：

1. 在真实 Windows 工具链核对 GRDB、Crypto、Protobuf、Foundation、SQLite/FTS5 和 zlib 链接。
2. 为资源目录同步、原子替换、安全创建文件及路径权限提供 Windows 等价实现。`V2ResourceDirectoryIO`、`V2ResourceFileStore`、`V2BackgroundResultInbox` 仍包含 POSIX 边界，不能以忽略错误或空实现通过编译。
3. 实现 Windows 设备/用户范围的安全凭据与恢复账本、安装绑定、受平台信任约束的 HTTP/TLS，以及物理取消/关闭；通过 `SharedPlatform` 注入同一业务运行时。
4. 接入 DLL 宿主薄绑定，验证真实后端、账号隔离、资源恢复与打包依赖。UI 技术栈不由这次 SDK 拆分预先决定。

原生锁使用 [LockFileEx](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-lockfileex) 的非阻塞独占字节锁，句柄和路径转换由 C 适配持有，Swift 不操作 Win32 原生句柄。当前 Windows 分支尚未本机执行，后续需先运行以上探针。

## 第十三阶段回归

iOS 通过原生 Swift `V2SharedSession` 接入共享会话所有权，Android/macOS 继续复用相同会话组件。实现说明见 [客户端文档](../../IMV2ClientKit/README.md#ios-原生共享会话第十三阶段)，本阶段实际执行结果及保留失败见 [验收记录](verification/phase13/summary.json)。macOS App UI、分发和 Windows 的支持边界不变。

## 第十四阶段：原生与跨语言共用会话门面

`V2ConversationService` 提供账号级会话/时间线读取，`V2ConversationWindow` 提供独立游标与异步观察。Apple 原生 Swift 和 Android 绑定调用同一服务；新增 C ABI 请求仅负责转换和句柄等待。多窗口真实后端与 iOS 行为回归见 [phase14](verification/phase14/RESULTS.md)。本阶段没有新增桌面 App UI 或 Windows 可用性声明。

## 第十五阶段：统一消息命令

`V2MessageService` 统一发送、编辑撤回、回复转发和表情回应，原生 Swift 与 Android 绑定共用持久化操作服务及账号生命周期。macOS 原生接口由独立客户端确认每种消息操作，再执行断线、恢复和旧账号句柄拒绝验收；详细结果见 [phase15](verification/phase15/RESULTS.md)。Windows 的平台适配与原生验证缺口没有变化。

## 第十六阶段：统一搜索和回执

原生 Swift 与 Android 绑定共用 `V2SearchService`、`V2ReadReceiptService`；搜索请求携带独立游标，回执沿用原有 durable 操作与隐私规则。真实后端原生测试直接调用搜索与可见消息回执门面，并由独立客户端确认已读。实现、iOS/Android 验收及未覆盖平台边界见 [阶段记录](verification/phase16/RESULTS.md)。
