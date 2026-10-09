# ADR-019：群邀请链接、二维码与入群审批

## 状态

Accepted — 2026-09-03；审批事务修订 — 2026-09-06；申请取消修订 — 2026-09-19

## 背景

群成员不能依赖内部 `user_id` 或客户端本地状态完成邀请。邀请链接会被转发、截图和复制，
本质上属于 bearer credential；但持有链接只应获得“申请入群”的能力，不能绕过群成员资格、
群角色权限、人数上限和服务端容量准入。

## 决策

- 邀请链接统一采用审批模式。任何持有有效链接的已认证用户只能查看最小群预览并提交
  申请；只有当前拥有 `inviteMembers` 有效权限的群主或管理员能创建、撤销和审批。
- 链接令牌为 256-bit 随机等价强度的 base64url 值。账户服务以专用 HMAC key、创建者和
  幂等 operation ID 确定性派生令牌，使响应丢失后的同一操作可恢复；PostgreSQL 只保存
  SHA-256 digest，不保存明文令牌。
- QR 只编码 `iim://group-invite?token=...`。令牌只放在 HTTPS JSON 请求体和分享载荷中，
  不进入 HTTP URL、日志、指标、Push、同步投影或客户端持久化数据库。
- 链接必须有 5 分钟至 30 天的有效期、1–1,000 次批准额度，可被撤销；每个群最多 20 个
  未过期活跃链接。每个申请人最多 20 个待处理申请，每个邀请最多 1,000 个待处理申请。
- 同一申请人对同一邀请只有一条未取消申请。申请人可取消待审申请，再用新的提交操作重新申请。
  被拒绝后不能重放同一链接反复骚扰管理员；管理员可通过创建新链接明确允许重新申请。
  取消与审批在同一 owner 事务边界串行，旧提交重放保留取消终态，见[申请取消合同](../../../docs/reviews/group-join-cancellation-contract.md)。

## 一致性与故障恢复

新批准在一次数据库事务内完成。服务必须依赖具有原子审批能力的 store，不再依赖
`prepareApproval → membership.change → completeApproval` 三段调用。

1. 以成员变更相同的 `(actor, operation)` advisory key 串行化操作，先查原决策；同一审核人
   的操作 ID 只能绑定一份申请和一种决策。数据库唯一约束为这一绑定兜底。
2. 按 operation → room → membership → request/invite 的顺序锁定。事务内读取实际 room
   revision，复用成员变更内部原语执行权限、人数、room/shard admission、成员区间、revision、
   room sequence、房间事件、个人状态待办和成员 operation 回执。
3. 同一事务增加邀请码已用次数，并直接将申请从 `pending` 改为 `approved`，保存审核人、
   操作 ID、实际输入 revision 和决策时间。结果 revision/sequence/event 保存在同次提交
   的 `room_membership_operations` 中，以审核人＋操作 ID 关联；失败回滚全部业务效果。

提交后丢失响应时，同一审核人的同一决策读取原记录，不重新入群或收费；申请人随后离群、
审核人随后失去群权限也不改变原操作结果。不同操作读取当前已决策状态仍要求当前审批权限。
普通成员添加返回 `targetAlreadyMember` 或独立成员 operation 存在，均不算本次审批成功。
撤销/过期链接继续阻止新申请，已提交申请保持可审批的既有策略。

新路径不产生 `approving`。旧的 `approving` 继续占用邀请码和申请人名额，普通审批入口返回冲突；现有独立 operator
恢复入口按确切成员 operation 和完整历史区间判断，同事务保存审计与必要的旧操作阻断。
结果不确定则隔离，不能凭当前成员资格释放或结算。详见
[恢复合同](https://github.com/Yyilin001/IMMonorepo/blob/21fb3cc8/docs/reviews/group-approval-recovery-contract.md)。B23 已在 schema 39 接入 control 全局预留、owner 回执与恢复，
见[全局配额合同](../../../docs/reviews/group-join-global-quota-contract.md)。B27 的完整房间迁移仍开放；账户库不因此成为所有群的 owner。

schema 21 在 20 的决策唯一约束上新增不可变恢复审计和旧操作阻断。schema 20 增加 `(decided_by_user_id, decision_operation_id)` 唯一约束。19→20 迁移要求
排空旧邀请写进程；重复旧决策键会使迁移完整失败，保留旧数据供调查。启动就绪检查必须验证
实际非延迟唯一约束及有效索引，不能仅检查 schema marker。详见
[原子审批合同](../../../docs/reviews/atomic-group-approval-contract.md)。

## 接口与客户端

账户 HTTPS 服务提供创建/列出/撤销邀请、预览/提交申请、申请人取消、分页列出待审批项和批准/拒绝接口。
所有接口要求设备绑定 access token，响应为 `no-store`。iOS 客户端支持系统分享、二维码显示、
相机扫码、粘贴链接、登录后恢复深链、申请说明、审批列表翻页以及批准/拒绝。

## 密钥与部署

`IM_V2_GROUP_INVITE_TOKEN_HMAC_KEY_BASE64` 必须是独立的至少 32-byte 密钥，不能复用 access
token、账户 assertion 或数据加密密钥。丢失或轮换该 key 会使既有链接无法重建，因此生产
轮换必须采用双 key 验证/按 key version 派生的单独迁移方案；当前绿地配置选择 fail closed，
启动时缺键直接失败。

## 非目标与发布门槛

本次不实现免审批链接、未登录网页落地页、Universal Link、邀请关系奖励或通讯录批量邀请。
仓库内测试通过只证明域约束、HTTP 合同、schema bootstrap 和 Simulator 构建；生产发布仍需
真实账号双端 E2E、链接泄漏/重放滥用测试、VoiceOver 人工验收和密钥备份/轮换演练。
