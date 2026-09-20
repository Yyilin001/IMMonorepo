# 群邀请 token 目录与创建意图合同（B27 第一阶段）

2026-09-06。本文记录第一阶段的 control 目录和创建协调器；后续 Account 接线与 schema 23 见[owner 路由合同](group-invitation-owner-routing-contract.md)，B27 仍未关闭。房间 owner 路由、epoch fence、control 身份快照、移除 owner 本地 profile 依赖、跨 owner 全局申请配额与完整迁移仍按修复计划继续。

## 数据归属与读取

`group_invite_directory` 保存 token 的 SHA-256 digest、inviteID、roomID，以及创建幂等所需的 actor/operation、有效期、最大使用次数和原始时间。无明文 token、正文、用户资料、owner 地址或跨库外键。`resolve` 只以唯一 digest 查询 ready 记录并返回两个 ID；prepared 不可见。目录不判断权限、当前成员资格、有效期、撤销或额度，以上必须在当前 room owner 验证。

目录保留已过期、撤销的绑定，因为申请、决策重试和旧链接历史仍可能引用它；现阶段不加入 TTL 删除。删除会失去幂等定位并允许 token 重新绑定。以后必须依据 owner 终态、操作保留窗口及迟到写阻断设计 GC，不能只用链接 expiresAt。

## 创建与中断恢复

`V2GroupInviteCreationCoordinator` 执行 prepare → ownerCommit → finalize，然后才返回链接记录。各次数据库事务独立，control 不在等待 owner 时持有事务。

- `(actorID, operationID)` 唯一。首次 prepare 固定 inviteID、createdAt、expiresAt；重试的新候选 ID/时间被忽略，不延长链接寿命。
- room、digest、requestedLifetimeSeconds、maximumApprovedUses 必须与同操作原始输入一致；变化为 conflict。当前 active invite policy 上限是 owner 本次执行的限制，不是用户幂等输入。
- digest 和 inviteID 也分别全局唯一；跨操作碰撞明确失败，不覆盖目录。
- ownerCommit 必须根据固定 roomID 解析当前持久 route，并在 owner 事务内执行 epoch fence。目录没有固定旧 owner，迁移后也不能向旧 owner 回退或广播寻找。
- owner 返回错误或响应丢失时保留 prepared；重试同一 owner operation 获取确定结果。已有 ready 记录也重放 owner 操作以读取当前链接状态。
- 协调器核对 owner 返回的 invite、room、actor、operation、最大使用次数及原始时间。时间比较只容忍 PostgreSQL 微秒编码误差。结果不匹配不 finalize。
- finalize 失败不会撤销已提交的 owner 链接；下一次重试仍使用同一 intent。完成状态只允许 prepared → ready，重复 finalize 返回成功且不改 readyAt。

第一阶段没有添加自动取消或 TTL。后续 schema 24 已接入持久认领、退避及后台恢复，见[创建恢复合同](group-invite-creation-recovery-contract.md)；目录绑定继续保留，不依靠 TTL 猜测 owner 结果。

## schema 与迁移

当前新库直接创建邀请目录及其约束、不可变触发器。旧结构回填和版本升级脚本已移除；正常目录写入与持久恢复仍由当前服务执行。

回填保持 owner 原始记录不变，active、expired、revoked 都登记 ready。独立 owner 上的历史链接须通过后续 schema 25 的[审计导入入口](group-invite-directory-import-contract.md)显式导入 control、核验冲突与覆盖率；本迁移不会跨数据库自行发现它们。路由启用前必须完成导入。owner 历史成员区间、D05 审计与旧操作阻断的迁移不属于目录数据，仍必须完整迁移后才能开放写入。

readiness 的 Swift 与 SQL 两个入口同时检查列类型/非空、三个非延迟有效唯一键、六个完整 CHECK、无外键、触发器类型/启用状态及函数体 SHA-256。仅表名或 schema 版本正确不足以启动。

## 验证边界

验证见[证据 manifest](../../docs/reviews/verification-records.md#20260906-invite-directory)：最终 17 项测试 / 2 套件通过，覆盖新目录恢复及七条既有迁移链；真实 21→22 回填、重复迁移拒绝和完整 readiness 负例通过。测试使用两个独立的专用 PostgreSQL 数据库，control 没有目标群成员关系；owner 仍使用现有本地身份校验，因此这不等同于 B27 的最终无 profile 副本验收。尚未完成 Account HTTP、未知 owner、旧缓存 epoch、在线迁移及全局申请配额组合测试。
