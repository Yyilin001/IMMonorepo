# 入群申请人取消合同

日期：2026-09-19。对应治理项 D06；以全新数据库和新版客户端为基线。
取消功能引入于 schema 37；当前 schema 以[状态表](status.md)为准，实时协议仍为 30。

## 申请状态与重试

申请人可通过 `POST /v2/group-join-requests/:requestID/cancel` 取消自己的 `pending` 申请。
请求体只有 `room_id`，申请人来自设备绑定认证；其他人、错误房间或不存在的申请均不能取消。
响应为完整申请及实际终态，禁止缓存。申请身份本身是幂等键，不另造可漂移的取消操作身份。

- `pending → cancelled` 在 owner 数据库事务内提交，保存申请人为终结人和服务器终结时间。
- 已 `cancelled` 返回原记录；重试不更新时间、不改变任何后续新申请。
- 若批准或拒绝先提交，返回原 `approved` / `rejected`，客户端告知审批已完成。
- 若取消先提交，批准读取 `alreadyDecided(cancelled)`，拒绝返回冲突；均不添加成员或扣减邀请次数。
- 遗留 `approving` 返回冲突，由已有 operator 恢复入口判断确切操作，不能取消不确定的成员提交。

取消按 applicant advisory lock → room owner fence → request 行锁处理。提交使用同一个申请人锁，
审批使用同一个房间及申请行的事务锁，因此本 owner 内配额统计与终态变更不会相互越过。
`cancelled` 不计入 pending/approving 配额，也不消耗批准次数。跨 owner 全局配额仍由 B23 跟踪。

原申请和提交操作记录保留：旧提交重放返回 `cancelled`，不会隐式新建申请。
相同邀请允许申请人用新的提交操作重新申请；被拒绝的申请仍禁止借同一邀请重复申请。
数据库使用排除 cancelled 的 `(invite_id, applicant_user_id)` 唯一索引，保证同一邀请只有一条未取消记录。
预览通过匹配排序的申请历史索引，优先读取未取消记录，否则读取最后一条取消记录，
避免旧历史遮住新申请或为单条预览扫描全部取消记录。

## 邀请与房间归属

邀请到期或撤销只阻止新申请，不剥夺原待审申请人的查询和取消能力。
原申请人重新打开邀请仍能看到 pending/approving；没有待审申请的人不能借失效链接查看预览。
取消不依赖链接秘密重新授权，必须验证请求所属申请人。

取消由 `V2RoutedGroupInvitationStore` 解析当前房间 owner，读取控制库身份、写入 owner 申请。
事务内校验 owner epoch；不匹配就拒绝，不向其他库回退。本合同不把受控 epoch 切换
视为运行中完整房间搬迁；B27 的完整迁移实现仍开放。

## App 与 HTTP 边界

待审页提供“取消申请”。取消中禁止重复操作；失败后可用相同申请身份重试。
确认 cancelled 后才开放重新申请，普通提交完成和已审批状态保持不可再次提交。
新邀请、关闭页面、退出账号会取消 store 持有的任务，并通过代次隔离迟到结果。
客户端要求取消响应的 roomID、requestID 与请求一致，状态为 cancelled/approved/rejected 且有终结时间。

## 验证与范围

真实 PostgreSQL 专项覆盖权限、幂等、到期/撤销、审批竞态、旧提交重放、配额释放、重申请和 owner fence；
schema 就绪检查核对取消约束及部分唯一索引，拒绝被放宽的 CHECK 和恢复成全量唯一的索引。
HTTP、ClientKit 与 App 专项覆盖响应时钟、认证身份、异常响应及迟到结果隔离。
实际运行结果见[验证记录](verification-records.md#20260919-group-join-cancellation)。

这不证明生产 APNs、真机系统生命周期、跨 owner 全局配额或完整运行时迁移已验收；
不删除保留的申请历史，也不支持旧 schema 原地升级。
