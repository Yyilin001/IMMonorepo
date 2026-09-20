# 历史邀请目录分页导入合同（B27 第四阶段）

> 2026-09-20 当前范围：项目未上线，不保留历史兼容。历史邀请目录的分页导入服务、运维入口及专用审计表已删除；当前邀请创建的目录与失败补偿保留。 以下内容仅保留为历史记录。

2026-09-06。独立 operator 从明确指定的当前 room owner 读取已提交链接，原子补齐 control 定位目录与审计。B27 仍待完整房间历史迁移验证；B23 全局申请配额单独开放。

## 入口与发布前提

仅独立 `IMV2OperatorServerApp` 注册 `POST /internal/v2/group-invites/import-directory`，沿用 operator 独立 bearer 和启动配置中的固定 principal。先认证再解码；Account 和公开 Gateway 不注册该入口。请求只接受 operationID、shardID、ownerEpoch、roomID、afterInviteID、limit 和闭合 reason，不接受数据库地址、token 明文、链接元数据或客户端指定 principal。

limit 为 1–100。每页使用独立 operationID；同一页遇到响应丢失时必须重试原 operation 和完整输入。reason 沿用 dependency_recovered、data_repaired、false_positive。

新环境的 control 与各 owner 使用同一当前 schema。正常跨所有者目录导入和幂等恢复仍保留；不运行历史结构升级。分页导入不能假定 UUID 游标代表跨所有页的数据库快照，当前路由写入仍须独立完成目录登记。

导入需要显式持久 `room_owner_routes` 行；不使用本地 rooms 回退、不广播 owner、不猜测 shard。旧单库部署也需先完成显式 route 登记。operator registry 必须配置该 shard，物理数据库 schema 仅接受 im_v2。

## 源读取与路由栅栏

先读取 control 中已保存的同一导入审计，精确匹配 principal 和全部命令输入。存在匹配记录时直接重放首次结果，即使 route 已改变或原 owner 已从注册表移除，也不重新读取源库。相同 operation 改 principal、room、ownerEpoch、shard、游标、limit 或 reason，返回幂等冲突。

首次操作先检查 control route，再到唯一注册 owner 的事务中取得 room FOR SHARE 锁，核对本地 shard/owner_epoch。查询该 room 的全部链接状态，按不可变 invite_id 升序读取 limit+1 条；仅前 limit 条进入本页，额外一条用于判断 nextCursor。包含已撤销、已过期、已用尽链接。

源数据只含 actor/creation operation、invite/room、digest、寿命、最大使用次数及原创建/到期时间。没有身份表 JOIN，不读用户展示资料、正文或 token 明文，不改变 owner 链接、使用次数、成员、申请、事件或 outbox。

释放 owner 事务后进入 control 事务，取得导入 operation advisory lock，并再次检查是否已有首次结果。随后对显式 route 行 FOR SHARE，核对相同 shard/epoch，持有到目录及审计一起提交。读取 owner 期间 control route 改变会导致发布拒绝。这里没有跨库全局事务；源绑定在读取点已通过 owner 栅栏，最终 control route 在提交点受锁保护。目录仅定位 room，不授予链接有效性或 owner 写权限。

## 整页原子提交

对本页每个源链接，按目录的三个唯一键处理：

- 缺失绑定：插入 ready 目录，保留原 ID、日期和业务输入。
- 完全相同的 prepared 绑定：发布 ready，并在同一事务完成现有 pending/claimed/paused 恢复任务，清除 claim/lease/error。
- 完全相同的 ready 绑定：不改原目录或已完成任务的完成时间，计入 unchanged。
- actor/operation、digest、invite ID 任一已有矛盾绑定：记录该源 invite ID，不改写已有绑定。

整页使用 control savepoint。如果发现任何绑定冲突，撤销本页所有目录和任务变更，新增不可变 conflict 审计。conflict 结果的 inserted/published/unchanged 均为零，conflictingInviteIDs 定位本页冲突源链接；已存在目录和任务保持原状。不同 operator operation 并发扫描相同页面也不能覆盖绑定。

没有冲突则将目录变更与 applied 审计一起提交。审计写入失败会回滚全部目录发布和恢复任务完成。异常数据库错误不生成成功审计，原 operation 可重试。

## 审计、响应与处置

`group_invite_directory_import_audit` 保存命令范围、固定 principal、原因、尝试时间、outcome、完整最小源绑定快照、规范化 JSONB 的 SHA-256（快照日期为 Unix 秒数，保留浮点亚秒精度）、计数、nextCursor 和冲突 IDs。没有会被业务删除连带清理的外键，禁止 UPDATE/DELETE，不做 TTL/GC。摘要用于核对保存快照，不代替 owner 授权检查，也不是抵抗数据库管理员篡改的签名。

HTTP 成功返回 200 和 no-store，包括已持久化的 conflict 结果；调用方必须检查 outcome。绑定 conflict 表示整页未导入，不得把 nextCursor 当成这一页已经成功后继续跳过；先调查冲突，再使用新 operation 重新处理该页。重复原 operation 始终返回首次冲突，不会因后来数据变化而变成成功。

未知 shard 返回 404；输入错误 400；route/epoch 或 operation 输入冲突 409；数据库等内部错误统一 503，不泄漏连接信息。响应不返回 token digest 或源快照。新插入的目录不会恢复已撤销/过期链接可用性，后续预览和提交仍由当前 owner 判定。已用尽链接保留原使用次数及既有成员/申请预览语义。

此入口不提供矛盾绑定强制改写能力。已有错误 binding 须先调查证据，不得直接禁用不可变触发器、删除审计或通过更换输入伪造同一操作成功。准备/恢复旧链接的普通创建重试见[兼容合同](group-invite-legacy-binding-contract.md)。

## Schema 与验证

schema 25 新增 18 列审计表、精确状态/计数/快照/摘要/游标 CHECK、不可变触发器和 owner `(room_id, invite_id)` 全状态分页索引。Swift/SQL readiness 同时验证有效主键、精确列与空值合同、全部 CHECK、触发器类型/启用状态/函数体摘要、无业务外键及分页索引。分页索引在迁移事务内普通创建，需要安排停写窗口；未进行大型历史索引创建耗时测量。24→25 迁移不回填或改写 owner 链接、control 目录和恢复任务；导入须通过审计入口显式执行。

初轮 3 项测试 / 2 套件通过；最终 39 项测试 / 5 套件通过。真实双库覆盖两种群分发模式、103 条链接分页、十次同操作并发、不同操作冲突审计、目录/任务/审计的事务回滚、三类唯一绑定冲突、owner 读取期间 control 路由变化、无 profile owner、原终态/使用次数保留及原审计在 owner 不可用后的重放。另包含真实数据库 HTTP 空页、同库 owner 空页、9 种 HTTP 边界、三库邀请流程和七条历史迁移链。真实 24→25 迁移保留旧链接/目录/任务；完整 SQL readiness 拒绝弱化摘要、计数、快照、游标 CHECK，Swift/SQL 均验证禁用触发器和缺失分页索引的拒绝。

证据见[导入验证记录](../../docs/reviews/verification-records.md#20260906-invite-directory-import)。分页与路由测试不等于完整在线房间迁移；真实 TLS/客户端、生产部署、进程 kill -9、大型历史导入吞吐和 B23 全局配额仍按问题总表推进。
