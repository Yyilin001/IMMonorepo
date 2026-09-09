# 群申请原子审批合同（B26）

2026-09-06。本批次完成新审批的单库事务路径，B26 保持实施中。协议 25、SQLite 173+5 不变；PostgreSQL 从 19 升至 20。未部署。

## 实现与不变量

`V2GroupInvitationStore.approve` 是必需能力，`V2GroupInvitationService` 不再接收独立 membership service。Account 入口传入同库 store 和容量 profile。旧 prepare/complete/release 三阶段 API 已移除；没有运行时类型转换或退回旧流程。

`PostgresV2RoomMembershipStore.change(in:)` 是事务内部原语，普通成员变更与审批复用同一份成员权限、room/shard admission、历史区间、revision/sequence、事件、冻结受众、plan、outbox、operation SQL。审批在调用它后、同一事务内递增邀请码使用量和提交 approved 决策。事务提交失败或任一步骤抛错，全部业务效果一起回滚；确定未接受的限额/成员冲突不写审批占位。

锁顺序以同一审核人/成员操作者的 operation advisory lock 开始，然后锁 room，再锁成员和申请/邀请码；内部成员变更重入已有 operation/room 锁，不开启第二个事务。创建、撤销、拒绝邀请的权限写检查也先锁 room 再锁 member，避免与普通成员写形成反向锁顺序。

申请记录保存 reviewer、decision operation、room、request、决策类型及时间、实际输入 membership revision；这些规范化字段完整绑定本次决策输入，无须依赖请求 DTO 的序列化哈希。结果 revision、room sequence、event ID、plan ID 保存在同次提交的 `room_membership_operations`，以 reviewer＋operation 关联。审核人＋决策 operation 的唯一约束阻止跨申请复用；同操作改成拒绝或换 request 返回冲突。

同操作重试返回原审批决策，不重新检查当前群权限或申请人的当前成员资格，也不增加计费。决策 ID、状态、时间及成员 revision/sequence 稳定；申请响应中的公开昵称/handle 仍按现有 profile 查询，不宣称 HTTP JSON 在资料修改后逐字节不变。不同操作访问已决策申请仍检查当前审批权限。普通独立成员添加，无论操作 ID 是否碰巧相同，不能作为本申请的成功依据。已提交申请在链接过期/撤销后的可审批策略保持原合同。

## 数据库迁移

`IMV2/sql/migrations/20260906_atomic_group_approval.sql` 要求排空全部旧邀请写进程，然后从 current-19 迁移至 current-20。迁移在事务内检查旧决策键重复；重复时明确失败，不自动选择记录或删除数据。新增非延迟 `UNIQUE (decided_by_user_id, decision_operation_id)`，未决策的 NULL 保持原语义。Swift readiness 与 SQL readiness 均检查有效唯一索引和真实约束，删除约束但保留 marker 会被拒绝。

## 验证

环境：macOS / Swift 6.3.3、专用 PostgreSQL 16.13，`127.0.0.1:56440/im_remediation`，迁移使用独立 `im_remediation_owner2`。均为显式可销毁测试数据库。

最终 `IMV2Server` 定向 `swift test --disable-build-manifest-caching --disable-automatic-resolution --jobs 4`：10 tests / 2 suites 通过，包括参数化用例。

- 在 outbox INSERT、邀请码用量 UPDATE、申请 approved UPDATE 后由真实 PostgreSQL trigger 抛错，逐字段比较 room/admission/shard/成员/申请/邀请快照及 event/plan/target/outbox/operation 数量，全部恢复原值。
- 从 membership revision 7 / room sequence 11 审批，断言申请保存输入 revision 7，成员回执保存结果 revision 8 / sequence 12。覆盖 standard 和 hybrid 冻结受众；10 路并发同操作重放没有新增效果；随后真实成员移除及审核人失去群成员资格仍重放原决策。
- PostgreSQL advisory barrier 将第一审批停在最终写入，第二审批和普通成员移除确实进入锁等待；最后一个批准名额只生效一次，普通移除收到 revision conflict 后按新 revision 成功，无死锁。
- 独立成员添加、复用独立成员 operation、遗留 approving 均不自动结算邀请码使用量。
- 新建 schema readiness 通过；删除决策唯一约束后 readiness 失败。
- 邀请单库申请配额（pending 与 legacy approving）、分页锚点、耗尽链接额度、普通成员 add/remove 及服务策略回归通过。
- 19→20 迁移遇重复决策时保留旧 schema 与两条记录；修正测试夹具后迁移保留记录并满足物理合同；数据库拒绝跨申请复用；重复迁移在变更前失败。

证据：[manifest](evidence/20260906-atomic-group-approval/manifest.json)。故障 trigger 证明事务错误回滚，并不等同于真实进程崩溃或 HTTPS ACK 丢失演练；重复调用证明 durable replay，不宣称已完成网络故障注入。

## 仍需闭环

B26 的目标 owner 路由与真实 HTTP/进程生命周期组合仍待验证；当前 Account 入口依然用其既有 database，B27 必须将邀请目录、身份快照及 owner epoch 接通。B23 跨 owner 全局配额不能由本批次本地锁替代。

新代码不产生 approving，但旧 approving 继续占额度且普通接口返回冲突。D05 必须用确切成员 operation 证明成功/未提交，并提供审计恢复入口；不能通过当前成员资格结算或释放，不能盲目恢复旧审核人的操作。D06 本人撤销、过期、控制库释放和 GC 仍未实现。

后续证据修订（2026-09-06）：发现通用幂等清理会删除审批引用的成员操作回执，现已增加按审核人＋操作 ID 的保留条件，见[审批恢复证据合同](approval-recovery-evidence-contract.md)。原批次 manifest 保留历史源码指纹；新证据记录更新后的清理器与迁移测试链。

后续实现（2026-09-06）：现有 owner 的 operator 恢复、不可变审计和旧 operation 阻断已完成并验证，见[恢复合同](group-approval-recovery-contract.md)。本文件保留对应阶段的历史验收范围；最新 schema 为 21。
