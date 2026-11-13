# 第六阶段：联系人和群组管理接入共享 SDK

2026-11-12，在 `codex/swift-android-feasibility` 延续前五阶段。Android App 使用同一 Swift 运行时和持久操作服务，未恢复旧 Kotlin SDK，也未增加 Kotlin 业务协议、数据库或操作队列实现。

## 已交付

- 联系人分页目录、收到/发出的好友请求、请求/接受/拒绝/删除、屏蔽/解除屏蔽、精确公开账号查找和私聊创建入口。
- 群目录、选择好友建群、成员分页/添加/移除、公告、管理员角色、角色权限、转让群主、退群和解散。
- Compose / Navigation 3 对应页面、确认弹窗、原操作结果及确认重试。群操作使用用户确认时所见的修订号，不自动更新修订号或续期；未冻结且暂停的草稿可放弃，刷新后重新操作。
- Swift 账号所有者持有社会关系、私聊、建群、成员和群能力服务，注册到同一 dispatcher；准备循环、SQLite 观察任务和实时权限恢复均可取消、排空。退出后再关闭数据库。
- 查找名称遵守 Swift 的单调时钟展示授权；离页、后台和账号切换清理展示结果。联系人/群成员使用用户 ID 回退，不把旧资料缓存当作展示授权。

## 实际验证

| 验证 | 结果 |
| --- | --- |
| Android API 31 arm64，真实后端联系人/群组 App 用例 | 1 通过，48.360 秒，无跳过 |
| 同一 APK 的第五阶段消息/账号回归 | 1 通过，39.888 秒，无跳过 |
| Android Debug / instrumentation 构建、App 与两 SDK Lint | 通过 |
| 不带测试 CA 的普通 Debug 构建及 Lint | 通过；该包未另做设备验收 |
| Swift 相关测试 | 112 项、14 suites 通过 |
| iOS 联系人、群目录和持久群/社会操作适配测试 | 27 项通过，无失败/跳过 |
| iOS arm64 simulator Swift package 构建 | 通过 |
| iOS 公开 API 与第五阶段对比 | 6,079 项；新增、删除、变更均为 0 |
| Python 验收工具测试 | 10 项通过 |
| DEX 和运行时依赖审计 | 无旧 Kotlin SDK；仅 app/sharedsdk/swiftplatform |

JVM 单元测试任务为 `NO-SOURCE`，未把构建成功算作测试用例。未在本阶段额外声明 Release、真机或远端 CI 验收。

真实链路为隔离 PostgreSQL + 原生账户服务 + HTTPS edge + placement quorum + TLS gateway。夹具仅注册账号；社会关系、建群及所有管理操作由 App 或独立共享 SDK 对端执行。UI 覆盖请求、接受、拒绝、查找、建群、成员管理、公告、角色、权限、转让、退群。删除与屏蔽/解除屏蔽经 App ViewModel 调用同一 SDK，并验证列表投影。

普通成员修改公告未取得准入，旧成员修订号也未取得准入，均停在 `paused` 草稿；测试明确放弃草稿，再由用户以刷新后的修订号发起。**这不是服务端终态 rejected 回执**。`api31-app.json` 中历史字段 `staleMembershipRevisionRejected` 表示该操作未获准，具体断言以本段和用例源码为准。

两个对端交叉验证公告、权限、成员和所有权变化；透明 relay 注入断线后重连。完整 App 所有者关闭/重开保留联系人，清除临时查找和群选择；A→C 切换无旧目录操作泄漏。收尾断言 JNI 客户端、操作、HTTP 与 TLS 连接数均为 0。消息回归继续覆盖文本收发、离线持久队列、切换隔离、错误密码、取消与重开。

后端独立查询确认：建群 1 次，群能力已应用回执 5 项（公告、角色、权限、转让、解散各 1），成员变更回执 3 项，双方关系回执 9 项，群最终已解散，成员修订为 7；群操作身份无重复。HTTP 汇总包含首次验收和最终验收及消息回归，不能把总请求数当作最终用例计数。

## 证据与复现

- [机器汇总](summary.json)、[目录 App 证据](api31-app.json)、[目录 instrumentation](instrumentation.txt)
- [消息回归](messaging-regression.json)、[消息 instrumentation](messaging-instrumentation.txt)
- [后端独立查询](backend-observation.json)、[HTTP 汇总](backend-http-summary.json)
- [iOS API 比较](api-compatibility.json)、[单 SDK 审计](single-sdk-audit.json)
- [源码摘要](source-sha256.json)、[原生库与工具链](shared-sdk-manifest.json)、[验证日志摘要](validation-logs.json)、[清理记录](cleanup.json)

```sh
python3 experiments/swift-android/build_probe.py --reuse-capabilities --shared-sdk
python3 IMV2/scripts/verify_v2_isolated_native_account.py --hold-seconds 900
python3 IMAndroid/scripts/verify_shared_sdk.py --phase 6 --serial <API31-arm64-device> \
  --endpoints <test-endpoints.json> --output <directory-evidence>
python3 IMAndroid/scripts/verify_shared_sdk.py --phase 5 --serial <API31-arm64-device> \
  --endpoints <test-endpoints.json> --output <messaging-evidence>
```

专用 `.sharedverification` App 的测试 CA 未进入普通 Debug 包；两次最终设备验收 APK 摘要一致。设备验收后已清理本轮 reverse、测试包、模拟器、AVD 和隔离后端，保留用户原有 Android 5554 与 iOS 模拟器。

## 范围限制

联系人完整授权资料展示、备注和头像、群元数据编辑、邀请链接/二维码、成员禁言尚未接入。媒体/资源、搜索等前阶段未迁移功能仍未开放；本阶段不是旧 Android App 全量功能对等。联系人、群目录和成员每页 50 条，真实用例使用小目录，未做大目录性能验收。操作结果保留有界窗口，建群展示最近一次；不宣称完整操作历史浏览已实现。旧 Kotlin 数据迁移、OS 杀进程/断电恢复和 Android 系统后台任务仍在范围外。
