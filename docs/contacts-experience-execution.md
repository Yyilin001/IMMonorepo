# 通讯录体验修复执行文档

## 目标

把通讯录从功能可达补齐为正式 IM 联系人中心，重点收口好友申请、联系人详情、黑名单、举报、状态反馈和测试覆盖。

## 执行清单

- [x] 好友申请表单：保留本地校验、提交 loading、成功/失败反馈和稳定测试标识。
- [x] 过期申请重发：发出的 14 天以上 pending 申请展示为已过期；重新发送前先取消旧 pending，再创建新申请。
- [x] 申请危险操作确认：拒绝收到的申请、取消发出的申请都增加二次确认，并补齐测试标识。
- [x] 申请已读同步：进入新的朋友页时清除未读收到申请；页面可见期间有新申请变化时继续同步已读状态。
- [x] 联系人详情实时性：详情页按 contactID 从 store 派生，避免备注、删除、拉黑后显示旧快照。
- [x] 拉黑状态收敛：拉黑成功后从本地联系人列表移除，更新黑名单并持久化联系人缓存。
- [x] 举报入口：联系人详情接入用户举报，支持原因选择、补充说明、提交反馈和稳定测试标识。
- [x] 黑名单体验：解除黑名单保留确认、loading、防重复点击和失败反馈。
- [x] 临时消息隔离：进入联系人、申请、黑名单、详情和表单页面时清理上一次操作遗留的 banner。
- [x] UI 测试标识收口：动态 row 使用带 ID 容器标识，row 内按钮保留通用 action 标识，避免同一元素 identifier 覆盖。
- [x] 任务生命周期收口：联系人页面统一使用 `ContactTaskBag` 管理异步操作，页面消失时取消仍在运行的任务。
- [x] 会话关系消息隔离：direct conversation 好友关系操作使用独立 `DirectRelationshipNotice`，不再污染好友申请页面消息。
- [x] typed result 收口：联系人申请操作新增 `ContactOperationResult`，result 方法只更新业务状态和 session 状态，不写 UI notice。
- [x] direct notice 二次隔离：direct conversation 好友关系操作直接消费 typed result，不再读取或清理 `.requests/.form` notice。
- [x] 旧兼容层移除：删除 `contactsMessage`、`contactRequestsLoadMessage`、`contactRequestActionMessage`、联系人申请 `Bool` wrapper 和 direct relationship 旧字典入口，新代码只使用 typed notice/result。
- [x] 剩余联系人操作 result 化：备注、删除、拉黑、解除黑名单、举报改为 `ContactOperationResult`，runtime 不再为普通操作写 UI notice。
- [x] direct 关系二次刷新：会话内接受、拒绝、取消好友申请本地未命中时先刷新申请，再给出最终状态。
- [x] 申请已读顺序修正：新的朋友页进入和下拉刷新先刷新申请，成功后再标记收到的申请已读。
- [x] 首页过期状态自然刷新：通讯录首页入口使用 `ContactRequestClock` 驱动 pending/expired 计数。
- [x] 联系人刷新去重：联系人、申请、黑名单刷新在 runtime 内合并同类进行中的任务，避免并发覆盖。
- [x] 联系人错误文案统一：`ContactOperationErrorMapper` 为联系人操作提供稳定用户文案。
- [x] 生命周期任务收口：页面进入自动刷新使用 SwiftUI 结构化 `.task`，`ContactTaskBag` 只管理用户触发的 action 任务。
- [x] 私聊关系反馈 typed 化：会话页通过 `DirectRelationshipNotice` 读取 message/tone，删除旧 string facade。
- [x] 会话侧关系操作 loading：私聊添加好友、接受、拒绝、取消、拉黑、解除和举报使用本地 action key 防重复，并将结果写回当前会话 notice。
- [x] 申请重发恢复：取消旧 pending 成功但重新发送失败时保留本地 draft，提供“重试发送”入口。
- [x] 添加好友提交前刷新：好友申请 sheet 在联系人状态过期时先刷新 contacts/requests，再重新校验并提交。
- [x] 错误文案映射稳定化：`ContactOperationErrorMapper` 使用集中常量并覆盖重复申请、已是联系人、申请不存在、黑名单、限流、离线、未授权和服务端错误。
- [x] UI 自动化约定固化：UI test helper 统一按 row identifier 定位后，再查 row 内通用 action identifier。
- [x] 测试覆盖：补充拉黑后本地联系人移除测试，并跑通联系人展示、举报 payload 和全量 iOS 测试。

## 验证命令

```bash
xcodebuild test -project IMApp/IMApp.xcodeproj -scheme IMApp -destination 'platform=iOS Simulator,name=iPhone 17'
```

## 验证结果

- 目标联系人展示/举报测试通过。
- 全量 `IMApp` scheme 测试通过。
- Xcode 输出中存在 iOS Simulator debugger snapshot/runner 启动噪声，但最终结果为 `TEST SUCCEEDED`。
