# 第十阶段：消息搜索、编辑撤回与已读回执

2026-11-12，延续 `codex/swift-android-feasibility`。Android 页面接入原有 Swift 搜索、消息变更和已读服务，没有新增独立 Kotlin 业务实现。本阶段 Swift 改动限定在 Android 共享门面与组合运行时，iOS 继续使用原有服务与页面路径。

## 已实现

- 消息标签可搜索全部本地消息，聊天页可搜索当前会话。每页 20 条，Swift 持有游标并在刷新时重新验证权限与投影；结果可定位到最近 50 条之外的历史消息。支持中文及 Unicode 内容，编辑前正文、撤回正文不再作为有效命中返回。
- 自己发送的消息可编辑非空正文、确认撤回。提交使用打开编辑框时的版本，消息变化时要求重新编辑。既有 Swift 操作服务持有冻结身份、持久化、冲突与恢复；页面显示待确认内容及可重试状态，不提前覆盖已同步正文。
- 已读上报只接收前台聊天列表实际可见的消息 ID，由 Swift 查验授权、解析 `roomSequence` 并合并意图。搜索结果不触发已读，已撤回占位和已失效引用会跳过，避免异步变化导致整批失败或页面更新循环。私聊依据服务端可披露回执显示“已读”。
- 群消息作者可打开已读详情，每页最多 50 个用户 ID，30 秒后清除旧页；翻页与披露过滤由原有服务端合同处理。页面退出、后台和账号退出清理临时搜索及阅读者数据。
- 聊天页压缩固定控件，输入与发送并排；发送后清除输入焦点，键盘展开时保留消息操作空间。同会话搜索结果复用已有聊天路由。

## 真实后端验收

独立 PostgreSQL、HTTPS 和 TLS 网关，Android API 31 arm64，从 `MainActivity` 登录开始。用例建立好友关系后由另一共享 SDK 客户端发送 61 条消息，验证搜索 20 + 6 条无重复分页、Unicode 命中、旧消息定位，以及搜索不提前推进尾部已读。

继续验证实际可见消息触发私聊已读、双方同步编辑与撤回、旧正文和撤回正文退出搜索、拒绝修改他人消息、撤回占位上报不报错；断开 App 实时连接后编辑，再关闭完整客户端所有者并重开，恢复为同一消息的版本 2。群消息由对端阅读后，作者页面显示对应阅读者。退出并切换第三账号后，聊天、搜索、变更记录和阅读者均不串号。结束时客户端、JNI 操作、HTTP 和 TLS 句柄全部归零。

[服务端只读查询](backend-observation.json) 独立确认编辑撤回消息版本为 3 且已撤回、恢复编辑消息版本为 2；两个编辑与一个撤回分别只有一条永久操作回执，私聊和群聊已读水位存在。

最终设备结果、同包回归和检查数量见 [summary.json](summary.json)、[第十阶段设备证据](api31-app.json)、[instrumentation](instrumentation.txt)、[iOS API 比对](api-compatibility.json)、[SDK 与打包审计](single-sdk-audit.json)、[源码摘要](source-sha256.json) 和 [验证日志摘要](validation-logs.json)。

第五至第九阶段使用同一 APK 回归。第六阶段首次在添加成员确认弹窗处发生一次点击未命中；未修改代码或 APK，复跑通过，原始失败保留在 [首次群管理尝试](directory-first-attempt.txt)。不能据此宣称该 UI 用例没有时序波动。

| 检查 | 实际结果 |
| --- | --- |
| Swift 搜索、消息变更和已读服务 | 47 项 / 8 suites 通过 |
| iOS 搜索、消息变更与已读上报 | 17 项通过，0 失败 / 跳过 |
| iOS arm64 simulator package | 构建通过 |
| iOS 公开 API，相对第九阶段 | 6,079 项；新增、删除、变更均为 0 |
| 第十阶段真实后端 | 1 项通过，57.625 秒 |
| 同 APK，第九 / 八 / 七 / 六 / 五阶段 | 各 1 项通过，46.604 / 40.322 / 48.492 / 46.534 / 41.960 秒 |
| Android 构建、App / SDK Lint | 通过；JVM 单元任务为 NO-SOURCE |
| 普通 Debug 包 | 构建与 Lint 通过，不含测试 CA；未另做设备验收 |
| Python 验收工具 | 10 项通过 |
| DEX、依赖和 native 摘要 | 无旧 Kotlin SDK；合并 native 匹配清单，APK native 匹配 stripped 产物 |

两个本次专用后端、测试包、adb reverse、模拟器及 AVD 已清理，原有 Android / iOS 模拟器保留，见 [清理记录](cleanup.json)。[HTTP 汇总](backend-http-summary.json) 包含最终后端上的失败尝试及第五至第十阶段用例，不能将总次数当作第十阶段单用例操作次数。

## 复现与范围

```sh
python3 experiments/swift-android/build_probe.py --reuse-capabilities --shared-sdk
# 等 native 构建完全结束后再打包。
python3 IMV2/scripts/verify_v2_isolated_native_account.py --hold-seconds 900 --resource-part-uploads
python3 IMAndroid/scripts/verify_shared_sdk.py --phase 10 --serial <owned-api31-emulator> --endpoints <isolated-root>/test-endpoints.json --output <output>
# 同一后端和 APK 回归 --phase 9 / 8 / 7 / 6 / 5。
```

本阶段仅验证 API 31 arm64 模拟器，恢复用例是完整客户端所有者关闭重开，不是操作系统强杀或断电。搜索限本设备已同步且仍授权的文本，不提供服务端全历史搜索、发送者/媒体筛选页面。群阅读者当前显示用户 ID；未新增超过 50 人的翻页验收或隐私开关端到端用例，既有 Swift/服务端隐私策略继续生效，隐私设置页面尚未迁移。

不提供管理员代撤回、编辑附件内容或完整消息管理功能。当前可见消息回执不额外推进消息之后仅含非消息事件的房间头。重试和冲突控件已接入，未逐项新增服务器冲突与结果丢失故障注入；相关状态机由 Swift 回归覆盖。普通 Debug 包构建通过后单独审计测试 CA，不将验证专用包当作生产发布验收。
