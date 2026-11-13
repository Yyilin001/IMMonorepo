# 第七阶段：联系人资料、备注、头像、群邀请和禁言

2026-11-12，在 `codex/swift-android-feasibility` 延续共享 SDK 迁移。业务、权限准入、持久操作和 SQLite 继续由 Swift 所有；Android 只有不可变绑定、Compose 页面及 Keystore / HTTP / TLS 适配，无独立 Kotlin 业务实现。

## 已交付

- 联系人授权名称、公开账号、私有备注和头像详情；备注保存/清除与原修订号确认。头像校验原授权期限、页面归属、长度和 SHA-256，仅保留内存数据；后台和账号切换撤下展示。
- 群邀请创建（一小时、最多批准 10 人）、系统分享、撤销；粘贴链接/邀请码预览、申请和取消；管理员申请分页及批准/拒绝。取消或被拒绝后需使用新邀请，页面依共享服务状态控制按钮。
- 群成员一小时禁言、原操作结果与确认重试，复用现有 iOS 的成员管理服务和原因码。普通成员无法取得对群主禁言的准入；被禁言者发送被服务端拒绝。
- 邀请 secret 使用 Android Keystore 加密，按安装绑定、账号和引用存放在 noBackup；SQLite 只保存引用。邀请 URL 不进入导航参数、保存状态或日志，只有用户点击分享才交给系统分享界面。
- 新服务、准备循环和观察任务接入同一账号所有者与 dispatcher，关闭时取消并排空。Android HTTP 支持备注所需的 PUT，并将响应体上限扩到头像契约的 2 MiB；Apple 的传输、Keychain、iOS 页面和公开业务 API 不变。

## 验证

| 检查 | 实际结果 |
| --- | --- |
| API 31 arm64，真实后端第七阶段 App 用例 | 1 通过，50.342 秒，无跳过 |
| 同一 APK 的第六阶段联系人和群管理回归 | 1 通过，37.359 秒，无跳过 |
| 同一 APK 的第五阶段消息/账号回归 | 1 通过，40.959 秒，无跳过 |
| Android 构建、App / SDK Lint | 通过；JVM 单元测试任务为 NO-SOURCE |
| 不含隔离测试 CA 的普通 Debug 构建和 Lint | 通过；此包未另做设备验收 |
| DEX 和运行时依赖审计 | 无旧 Kotlin SDK；仅 app/sharedsdk/swiftplatform |
| Swift 资料、名字操作、头像、邀请和禁言相关测试 | 92 项 / 11 suites 通过 |
| iOS 头像、邀请、备注编辑和联系人动作测试 | 37 项通过，0 失败 / 跳过 |
| iOS arm64 simulator package 构建 | 通过 |
| 相对第六阶段的 iOS 公开 API | 6,079 项；新增、删除、变更均为 0 |
| Python 验收工具测试 | 10 项通过 |

Android 测试从真实 `MainActivity` 登录开始。独立共享 SDK 对端与 App 交叉验证联系人、群成员和邀请；夹具只通过真实 HTTPS 注册账户和上传/替换联系人头像。服务栈为隔离 PostgreSQL、原生账户服务、HTTPS edge、placement quorum 和 TLS gateway。

验收覆盖头像替换、备注私有性、后台清理、完整客户端关闭重开后的备注恢复、无权用户资料不展示、Android 申请页、取消/拒绝后新邀请申请、批准、撤销、权限不足的禁言草稿、禁言发送拒绝、relay 断线重连与 A→C 账号隔离。退出后客户端、JNI 操作、HTTP、TLS 均归零。

独立后端查询限于最终成功用例的群：3 个邀请（1 个已撤销且批准使用 1 次）、申请取消/拒绝/批准各 1；邀请操作回执 4、申请回执 4、审批回执 2；禁言回执和禁言记录各 1；消息结果为 `permissionDenied`，操作身份无重复；私有备注修订为 1。普通成员不能禁言群主的用例停在 `paused` 未冻结草稿并被明确放弃，**不是服务端终态 rejected 回执**。

验收期间修正了 Android HTTP 未允许 PUT，以及备注完成后重复失效导致展示更新竞争的问题。测试先等待控件实际启用再点击，避免导航和页面读取时点的竞态。HTTP 总汇包含调试失败轮次与回归，不能当成最终用例请求数。

## 证据与复现

- [机器汇总](summary.json)、[App 验收](api31-app.json)、[instrumentation](instrumentation.txt)
- [第六阶段回归](directory-regression.json)、[第五阶段回归](messaging-regression.json)
- [后端独立查询](backend-observation.json)、[HTTP 汇总](backend-http-summary.json)
- [API 兼容性](api-compatibility.json)、[单 SDK 审计](single-sdk-audit.json)
- [源码摘要](source-sha256.json)、[工具链与原生库](shared-sdk-manifest.json)、[验证日志摘要](validation-logs.json)、[清理记录](cleanup.json)

```sh
python3 experiments/swift-android/build_probe.py --reuse-capabilities --shared-sdk
python3 IMV2/scripts/verify_v2_isolated_native_account.py --hold-seconds 900
python3 IMAndroid/scripts/verify_shared_sdk.py --phase 7 --serial <API31-arm64-device> \
  --endpoints <test-endpoints.json> --output <people-evidence>
# 在同一设备和后端依次运行 --phase 6、--phase 5 回归。
```

三轮设备验收的安装包 SHA-256 一致；普通 Debug 包不含隔离测试 CA。已清理本轮 reverse、专用测试包、模拟器/AVD 和隔离后端，保留用户原有 Android 5554 与 iOS 模拟器。

## 范围限制

本阶段头像为联系人资料头像读取，未接入个人头像编辑上传和群头像编辑；未接入邀请二维码扫描、系统深链接自动打开、提前解除禁言。禁言到期由后端处理，本次未等待完整一小时做到期验收。通用资源、媒体消息、搜索等先前未迁移功能仍不开放；不宣称全量 Android 功能对等。

目录/申请与操作展示为有界窗口（通常 50 条），本次为小目录验收，未做大列表性能或最大头像尺寸压力验证。完整客户端关闭重开验证了恢复，但不等于 OS 杀进程/断电验收。旧 Kotlin 数据迁移、系统后台任务及推送仍不在范围内。未另行声明 Release、实体真机或远端 CI 验收。
