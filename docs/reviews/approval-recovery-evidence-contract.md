# 审批恢复证据保留（D05 / B26）

2026-09-06。D05 进入实施中；本批次修复恢复证据的清理缺口，未实现操作员接管入口。协议 25 / PostgreSQL 20 / SQLite 173+5 不变，未部署。

## 发现与修复

`PostgresV2ControlPlaneHousekeepingStore` 原本将全部 `room_membership_operations` 当作可在 35 天后清理的普通幂等结果。但 legacy approving 需要它证明成员添加是否提交，新 approved 决策也通过它保存实际输入 revision、结果 revision/sequence/event/plan。清掉回执后，当前成员资格不能替代操作证据：申请人可能已经退群，也可能经其他途径入群。

现在清理候选必须不存在引用相同 `(decided_by_user_id, decision_operation_id)` 的申请。schema 20 的决策唯一索引支持这一查找。匹配只使用操作身份，不因旧记录的 room/target/action 绑定可疑而删除证据；绑定异常应留给恢复调查。相同 UUID、不同 actor 的过期成员操作不被误保留。

清理仍使用原有全事务删除预算、旋转表选择和 `SKIP LOCKED`。此次不改变回执内容、不刷新其时间、不释放申请名额、不增加邀请码使用量，也不重新加入成员。该修复需要所有执行此清理路径的进程更新；旧清理二进制仍可能删除证据。

保留边界是申请仍引用该操作；D06 终态保留/删除必须同时考虑审批结果和审计依赖。删除行数仍受预算约束，但未验证大量长期引用记录下的候选扫描成本，不把本次正确性验证当作大规模性能验收。

## 真实数据库证据

专用 PostgreSQL 16.13，`127.0.0.1:56440` 两个明确可销毁数据库；Swift 6.3.3 / macOS。

1. 新测试先在旧清理实现运行。approved、approving、绑定异常三种参数各有 3 条过期成员回执，原实现全部删除；应保留的精确回执缺失，1 test / 1 suite 共 9 个断言失败。
2. 修复后，三个参数都只删除 2 条无关操作，保留审批引用的 1 条回执，逐字段 JSON 快照完全一致。申请人已通过真实成员移除路径离群。再次清理没有新增删除；approved 重放决策稳定，legacy approving 保持冲突而不被误结算。
3. 最终 12 tests / 1 suite 通过，覆盖上述清理、审批故障回滚及并发、申请配额、清理预算/同步重置、Push 条件意图、群策略回执清理，以及 forward export/delivery/operator/audience/ABA 的真实单库和双库回归。
4. 同时补齐 7 条旧版本迁移测试链至 schema 20。模拟旧 schema 时先移除当前决策唯一约束，执行实际 `20260906_atomic_group_approval.sql`，最终通过 Swift 和 SQL readiness；未用改 marker 冒充迁移。

[证据清单](evidence/20260906-approval-recovery-evidence/manifest.json)。初始失败日志中的旧打印文字只是测试说明；以实际 `purged=3`、缺失回执和失败断言为准，最终日志已打印真实保留布尔值。

## 下一步恢复约束

- 找到成员 operation 时，核对审核人、操作 ID、room、target、add 及因果关系；旧 B26 冲突重试可能使实际 expected revision 高于申请准备时保存的值，不能机械要求两者相等。确定提交的操作只补审批记账，不重新入群；申请人随后退出不改变该结论。
- 查不到 operation 可能是历史清理，不能直接认定未提交。必须建立可验证的未提交证明或隔离调查，不能用当前成员资格推断。当前修复保护尚存证据，不重建已经删除的旧回执。
- 将确定未提交的旧申请退回 pending 时，必须同事务留下审计和持久旧 operation 阻断记录；普通成员变更及审批入口必须拒绝被阻断的旧操作，即使旧审核人以后重新获权。新审核人用新 operation，按当前权限执行。
- 恢复入口必须独立操作员认证，按配置 owner 和 epoch 处理，限定输入和批量范围；恢复及审计同事务，重试读取原结果。尚未实现这些入口和阻断机制，D05 不关闭。

后续实现（2026-09-06）：现有 owner 的 operator 恢复、不可变审计和旧 operation 阻断已完成并验证，见[恢复合同](group-approval-recovery-contract.md)。本文件保留对应阶段的历史验收范围；最新 schema 为 21。
