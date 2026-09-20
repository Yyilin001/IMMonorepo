# 跨 owner 入群申请配额合同

日期：2026-09-19。对应 B23。目标是同一申请人在所有房间 owner 上合计最多 20 个待处理申请，
而不是每个数据库各有 20 个。当前代码和真实跨库专项已满足 B23 关闭条件；生产部署与容量仍按 E 类验收。

## 当前实现边界

当前新库合同为 schema 39。控制库保存 `group_join_quota_intents` 预留和恢复任务，
`group_join_quota_aliases` 保存重复操作与原申请的绑定；房间库保存不可变的
`group_join_submission_receipts`。`V2RoutedGroupInvitationStore.submit` 已接入“预留→房间事务回执→确认”路径，
Account runtime 已启动有界恢复任务。提交、重复绑定、崩溃与终态恢复均已有对应专项证据。

账本遵循以下规则：

- applicant 事务锁串行化预留与释放；held 和 tracking 都占用名额，所有 room/owner 共用此计数。
- `(applicant, operation)` 绑定 room、invite、token 摘要和 note。服务重试生成的新 request ID 和时间
  不能替换首次预留的申请身份、原始时间；同一活跃邀请的不同操作共用一个预留。
  每个重复 operation 都必须先持久绑定，再返回原申请；取消后这些旧 operation 仍返回 cancelled。
  绑定保留各自的 note，拒绝同一 operation 改换业务输入。已拒绝的原操作若遇到另一不确定预留，
  暂时返回限流；只有另一预留已由房间回执确认时才重新绑定，避免不确定尝试之间形成循环。
- held 表示 owner 结果尚未确定；tracking 表示已取得 pending/approving 的 owner 记录。
- approved/rejected/cancelled/already_member 形成 terminal 并释放名额；取消后的旧提交保持终态，
  新提交可另行申请。具体是否允许使用同一邀请重新申请仍由 owner 的申请规则决定。
- unavailable/rate_limited/permission_denied 只有在取得 owner 持久拒绝回执后才能进入 denied。
  denied 后同一用户操作可重试，原 request ID 保留，generation 增加；旧 generation 的结果不能释放新名额。
- 超时、连接中断、进程退出、租约过期或暂时查不到 owner 都不能作为释放证据。账本不自动过期 held。
- 请求目标一旦确定，后续终态只能属于该 target request；终态不会被迟到 pending 重新打开。

新表的唯一索引防止同一申请人对同一邀请持有多个活跃预留；状态组合、正代次、有限时间及唯一键
受数据库约束保护。Swift 和独立 SQL 启动检查均核对真实列、约束与有效索引，而不只看 schema marker。

## 已实现与验收范围

以下前五项已有实现与定向验收；第六项明确独立的迁移和发布边界：

1. **owner 的逐次提交回执。** 以 applicant/operation/generation 固定请求及结果；成员申请提交与回执必须
   在同一 owner 事务内完成，拒绝结果也必须持久化。否则 control 释放后，迟到 owner 执行仍可能新建申请。
   不允许把普通网络错误直接传给账本 resolve 当作拒绝。
2. **路由协调器。** 先验证 control 身份和 token 目录，再预留固定意图；解析 owner/epoch 执行该次提交，
   根据持久回执更新 control。重复请求、不同操作的同邀请申请和配额已满时的重放必须保持幂等。
3. **持久后台恢复。** control 预留与恢复任务原子创建；有界认领、过期租约回收和退避保证进程重启后
   继续原 generation。重复 worker 不产生第二次申请，不因不确定结果释放名额。
4. **全部终态。** 批准、拒绝、申请人取消和 operator 恢复后的确切 request 状态都必须能触发最终释放；
   不能靠申请人的当前成员资格判断原申请是否完成。即时通知丢失后后台仍须收敛。
5. **实际跨库与故障验收。** 同一申请人跨多个 owner 并发提交，验证全局 20 上限；覆盖 control 预留后、
   owner 提交后、control 确认前的进程中断，以及迟到旧代次、终态释放、取消/审批竞态和重试。
6. **发布边界。** 新库基线不要求兼容旧 schema，但运行中房间迁移不得遗漏申请、回执和预留绑定；
   完整搬迁执行器仍由 B27 跟踪，不能用受控 epoch 切换冒充迁移验收。

## 验证记录

早期阶段只验证账本并发、绑定、释放与代次隔离，原始运行见
[全局配额账本专项](verification-records.md#20260919-group-join-quota-ledger)。
后续已增加真实双 owner 并发、重复操作绑定及独立子进程 SIGKILL 恢复专项。
最初跨库生命周期用例在审批处失败：测试传入命令额度 100，而数据库固定为 10，导致审批限流；
已修正测试配置为 10，未放宽审批成功断言。后续 16 项配额/邀请专项全部通过，另补 operator 恢复 3 场景；详见[最终接线验收](verification-records.md#20260919-group-join-global-quota)。
没有执行全仓业务测试；B23 关闭。完整房间迁移仍由 B27 跟踪，生产长稳与容量仍由 E09 跟踪。
