# B06 客户端角色权限效果

更新：2026-09-06。个人流、前台预览、持久房间流和 snapshot shadow 已共用角色权限 reducer。完整权限基线恢复仍待接入，B06 保持实施中。

## 独立版本和来源

`V2LocalRolePolicyEffect` 校验 UUID room/actor、admin/member 角色、无重复的已知权限集合、正 Int64 revision、可选正 room sequence，以及可选非负时间。房间入口同时校验 payload room 与 envelope room；显式源序号必须与 envelope 一致。旧 payload 缺少源序号时保存 NULL，不使用个人游标替代。

`v2_group_role_policies` 按 room/role 保存完整权限集合、对象 revision、可选源序号及来源摘要，空集合也占一行。`v2_role_policy_effects` 按 sourceEventID/room 保存角色、revision、摘要和源序号，与可见状态及消费游标同事务提交。摘要基于规范化 UUID、排序权限及解析后的事实，不受 JSON 字段顺序和权限排列影响。

旧角色版本不覆盖新值；同版本不同事实或不同来源拒绝；同身份被改成另一个角色、版本或内容也拒绝。源序号可从未知补为已知，之后不得改写。房间全局 permission revision 继续取最大值供命令 expectedRevision 使用，不用于阻挡另一个角色较低的独立版本。

## 迁移与缺失状态

追加 `orderRolePolicyEffects` 迁移，将旧的正权限行转换为完整集合并移除旧表；主 schema 为 **168** 个对象，搜索库仍为 **5**。保留旧行可观察到的角色值和 revision，规范化 room UUID，但不信任旧 room_sequence，也不制造 sourceEventID 或摘要。混合 revision、未知权限及规范化后同版本冲突使事务失败。

旧空策略没有独立行，无法从全局 revision 证明哪个角色何时变化。迁移不会从可能残缺、或属于已清除房间的历史日志推断当前策略。`groupRolePolicies` 仅返回已观察到的角色；缺少的角色保持未知，不再回退默认授权。仍需通过 [protocol 25 权限基线](group-policy-baseline-contract.md) 完成当前态恢复，现有 App 对没有对应策略的角色禁用保存。

旧暂存和已准备快照清除 staging/import 后重新导入同一 artifact；live bank、outbox 和 pending reset 保留。旧正权限值的历史来源仍可能缺失，本迁移不宣称补齐这些证据。

## 快照和验证

权限状态与效果记录参加原子 snapshot bank 切换。普通个人快照保留其角色版本范围内的旧 receipts；同一来源在新快照中变成另一版本或事实会使准备事务失败。明确源序号可以补齐未知 receipts。

对新基线仍授权的混合群，按每个角色比较 live 与 shadow 的 revision，保留较新状态，并保留房间全局命令 revision。这样保留房间日志游标时不会把权限状态退回旧版本；不为已撤销房间复制独立房间日志状态。效果表属于内部元数据，不触发全量 UI 刷新。

测试覆盖个人/预览两种先后、持久房间流、乱序、空集合、独立角色、重启、身份/版本冲突、数值与房间边界、普通和混合快照、两种 staging 阶段的旧库迁移及 outbox 保留。最终日志和源码绑定见[验证证据](evidence/20260906-role-policy-effects/manifest.json)。

本批未接入持久基线恢复 worker、账号/设备与 membership 栅栏、旧库缺失策略的主动获取，也未完成置顶、成员角色或完整 receipts 保留/清理合同。protocol 25 和 PostgreSQL 18 未变；没有部署。
