# 邀请创建后台恢复合同（B27 第三阶段）

2026-09-06。Account 已接入持久恢复队列，继续执行同一创建 intent，不需要用户重新生成 token。该批补齐普通提交中断后的自动恢复；B27 的完整房间历史迁移仍未关闭；独立 owner 旧目录已接通[审计导入](https://github.com/Yyilin001/IMMonorepo/blob/21fb3cc8/docs/reviews/group-invite-directory-import-contract.md)，B23 全局申请配额仍独立开放。

## 时间与幂等输入

创建持久输入保留原始 createdAt、expiresAt、inviteID、actor/operation、digest、lifetime 和最大使用次数。新增内存字段 evaluatedAt 表示本次尝试的判断时间，不进入客户端 DTO、token 推导或持久输入摘要。

Directory prepare 的重试保留原始日期，但将本次 evaluatedAt 传给 owner；owner 的活跃链接计数、已存在链接的 expired 状态，以及尚未创建链接的过期拒绝，都用本次判断时间。重试不会延长有效期，也不会把已经到期的链接继续计入当前活跃额度。

如果本次判断时已经到期且 owner 没有原操作记录，创建失败为 creationExpired（HTTP 409），后台暂停。若 owner 已有完全匹配的记录，即使链接已过期或原创建人已失权，也只重放原结果并完成目录，不重新创建链接。该时间合同是服务端的每次尝试时间，不宣称对真实提交瞬间提供跨库全局时间事务。

## 持久队列与发布

schema 24 的 `group_invite_creation_recovery` 以 `(actor_user_id, operation_id)` 为主键，并通过精确复合外键绑定不可变目录 intent。状态为 pending、claimed、completed、paused，附认领 token、租约、到期时间、饱和尝试计数与闭合错误分类。

- prepare 在同一 control 事务内创建 prepared 目录与 pending 恢复任务，首次延迟 30 秒给前台正常完成留出时间。
- finalize 在同一 control 事务内发布 ready 目录并将任务 completed；若最后的任务更新失败，目录发布一起回滚。已经提交的 owner 链接不回滚，之后按原 operation 重放。
- ready 的重复 finalize 不更新已完成任务，不重写原完成时间。
- 前台重试可以完成一个正在 claimed 或 paused 的任务；后台旧 claim 的失败不能覆盖这个结果。
- 目录及恢复记录均不做 TTL/GC。paused 只表示停止后台调度，不是取消原操作或其迟到结果；原 token/操作绑定始终保留。

## 认领、退避与生命周期

每轮最多处理 8 次尝试。运行器逐个认领，避免一次租赁多个任务后让慢 owner 消耗队尾任务的租约。claim 先处理已过期租约，再处理 pending，两条查询分别匹配各自的 due-time 部分索引，采用 FOR UPDATE SKIP LOCKED；每次认领生成新的 UUID claim token，租约为 60 秒。

发生暂时性数据库/路由依赖失败、owner epoch 不一致或容量限制时，按 15、30、60、120、240、480、900 秒退避，之后上限 900 秒。暂时不可用持续很久也不会被误判为成功或永久取消；恢复依赖后自动继续。attempt_count 在 1000 饱和，用于退避而非无限精度累计计数。

权限拒绝、当前尝试时未创建即过期、不可匹配的 owner/目录证据会暂停，保存 permission_denied、creation_expired 或 conflicting_evidence。队列不会通过改 token、改 room、延长寿命或绕过当前权限来消除错误。

fail 只接受仍处于 claimed、token 相同且租约未过期的认领。前台已经完成、其他进程已经接管或旧租约已过期时返回 lostClaim。已证明匹配的 owner 结果可以正常 finalize，不把目录发布依赖于某个旧 worker 的租约。

取消不会清除认领或猜测 owner 是否提交；RuntimeTaskSupervisor 排空任务，后续进程在租约到期后重试同一操作。Account 每 5 秒运行一轮，日志只含聚合数量，不含 token、digest、账号或房间 ID。数据库等待使用已有 session/statement/lock timeout；认领事务在访问 owner 前已经结束。

## 暂停后的处置

操作人员可在受控 control 数据库读取 paused 任务的 actor/operation、last_error_code、attempt_count、updated_at，并关联目录定位房间。暂停不会无限刷新状态或反复执行业务写入。

权限恢复后，原身份可通过正常创建接口携带相同 operation 重试，仍受当前 owner/权限验证，成功会完成原任务。过期意图需要用户以新 operation 明确创建新链接。证据冲突应先调查，禁止直接覆盖不可变 binding 或修改任务状态来冒充成功。本批没有新增 operator 强制重放/改写接口。

## 迁移与验证范围

当前新库直接创建邀请准备队列及其约束。当前 prepare 事务负责持久化恢复任务；不扫描旧版本 prepared intent 做升级回填。

Swift 与 SQL readiness 检查全部列、精确状态 CHECK、有效主键、复合 intent 外键和两个到期索引。验证见[证据 manifest](../../docs/reviews/verification-records.md#20260906-invite-creation-recovery)：最终 31 项测试 / 3 套件及真实 23→24 迁移验证通过。测试覆盖真实 owner/control 提交中断、认领竞争、前台/后台并发、旧认领失败阻断、原创建人失权后的已有结果恢复、时间与额度边界、持久退避和取消后租约接管。

测试中的取消和重建 worker 使用真实数据库，但不是 OS kill -9 故障注入；Account 任务组装已编译，未部署运行中的账号服务。完整跨物理房间迁移、全局配额、压力测试和真实 TLS/客户端生命周期组合继续按原问题表推进。

历史 owner 已提交链接但缺目录的创建重试，已补沿用原绑定的预检查结果；矛盾旧目录不会自动改写，见[兼容合同](group-invite-legacy-binding-contract.md)。
