# 群权限与幂等回执保留

## 实现合同

当前 PostgreSQL 合同为 `im-v2-current-18`。`group_role_policies(room_id, role)` 保存角色已明确配置策略这一事实，`group_role_permissions` 保存该策略允许的权限。两者都没有行时使用领域默认权限；存在策略标记而权限集合为空时明确禁止该角色的所有可配置操作。owner 继续遵守不可修改的 owner 权限合同。

设置策略在原来的 room lock 事务中写入标记、替换权限、递增房间策略 revision，并提交源事件和操作回执。标记每个房间、每个可配置角色至多一行。housekeeping 仍可按原保留期限清理 `group_permission_operations`，不再承担当前授权状态的存储职责。

普通权限 resolver 和三处批量消息授权查询均读取当前策略；优化查询同时检查已有非空权限行，避免没有标记的旧数据被误当成默认允许。普通发送、转发写入及群管理命令通过已有的统一授权函数读取相同策略。

## 受控升级

- 新环境使用 canonical `IMV2/sql/schema.sql`。
- schema 17 环境使用 `IMV2/sql/migrations/20260906_durable_group_role_policies.sql`。迁移在单一事务内锁住 room、权限、操作和源事件表，以源事件与仍保留的操作记录回填每个角色的标记，已有非空权限行也保留明确策略身份。
- 迁移要求每个房间从 revision 2 到当前 policy revision 的历史连续。角色非法、revision 缺失、同 revision 多角色或历史缺口都会回滚，不猜测缺失的空权限状态。需要先从权威备份恢复缺失事实再重试；不能只降低 revision 或伪造标记绕过门禁。
- 升级前停止旧版写入、读取和 housekeeping 进程，提交迁移后统一启动 schema 18 二进制。旧进程在运行中不会自动重新检查 readiness，因此此迁移不声明支持混合版本滚动运行。
- 重复执行或从其他 schema 执行会明确失败。尚未部署到生产。事务提交前可回滚；提交后的降级不能删除策略标记后启动旧权限读取代码，因为旧回执可能已经清理。回退应恢复完整升级前数据库及匹配二进制，或保留该授权修复并向前修复。

## 验证范围

集成用例包含默认权限可发送、明确清空权限后拒绝、真实回执 GC 后继续拒绝，以及已有权限缓存/批量路径的再检查。迁移用例覆盖回执已清理但源历史仍保留、缺口时回滚、完整回填、重复迁移拒绝和缺少角色约束时两种启动门禁拒绝。

最终 20 项服务端测试、3 个套件通过；源码指纹、失败/成功日志及完整 filter 见 [验证记录](../../docs/reviews/verification-records.md#20260906-group-policy-retention)。该修复不等于完成 B06：客户端群管理效果去重、按对象版本排序、snapshot 负状态、旧 payload 与 staging 迁移仍需完成。wire protocol 23 与 SQLite 结构在本批没有变化。
