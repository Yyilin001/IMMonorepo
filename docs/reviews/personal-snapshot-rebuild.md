# B06 个人快照重建合同

更新：2026-09-06。此批实现受控个人基线恢复的基础通路，B06 仍为实施中；尚未部署。

## 请求和恢复

protocol **24** 的 `SyncPull.require_snapshot` 由 ClientKit transport 编码，经已认证 gateway identity、SyncService 和当前 user owner 路由传入 PostgreSQL。普通请求缺少 token 时仍从设备 ACK 位置继续，不能据此推断会收到完整快照。

ClientKit 的 `requestSnapshotRebuild()` 在独立 SQLite 元数据表 `v2_sync_rebuild_requests` 中持久记录意图。重复调用幂等，不删除当前投影、游标或 outbox。`recordSnapshotRebuildIntent` 迁移只创建表，不自动触发重建；主库 schema contract 为 **166** 个对象，搜索库仍为 **5** 个。

SyncEngine 有本地 pending reset 时先继续其导入/ACK。否则，存在重建意图时发送无 token、require_snapshot=true 的 pull。丢响应、重启和 reset 取消均保留意图；普通 ready batch 不能替代所请求的快照，存储事务也会拒绝在意图写入之后到达的普通 batch。只有快照 ACK 后的本地原子切换会清除标记。内部意图表不触发全量 UI 刷新。

普通 reset 仍要求相邻 generation；仅显式持久重建意图允许服务端 generation 高于旧本地库一代以上，不能倒退。此例覆盖旧库恢复后服务端代次更高的情况。

## 服务端边界

- 活跃设备验证和 cursor 锁保持原有流程。被撤销设备不能通过重建取得数据。
- 已在 reset_preparing/reset_pending 的请求复用同一 snapshot 和 generation，不重复 stage。
- 显式请求忽略旧 sync token，基线下限取 `max(retention floor, device acknowledged sequence)`。复用既有 snapshot stager、builder、签发能力和 ACK 栅栏；不另建一套导出流程。
- 从未产生个人事件的账户允许 base zero：仅在没有非零 user_sync_sequences 时补零 checkpoint；已有非零 ACK 仍受基线下限约束。
- 快照完成后重复 ACK 幂等，普通 pull 从新的 generation/base 继续。
- PostgreSQL schema 保持 **18**。protocol 24 的客户端与网关需配套升级，未声称支持混合协议版本运行。

## 验证和未覆盖范围

[验证证据](../../docs/reviews/verification-records.md#20260906-personal-snapshot-rebuild)保存失败与成功日志及最终源码 SHA-256。ClientKit **305 项 / 52 套件**全通过；iPhone 17 / iOS 26.2 App **170 项 / 17 套件**全通过；专用 PostgreSQL 双库上的服务端定向回归 **56 项 / 6 套件**通过。

客户端覆盖旧库迁移、重启、响应丢失、重复请求、跨代恢复、取消后重试、快照激活和 outbox 保留；wire 与 gateway 测试覆盖标志和认证身份传递。真实 PostgreSQL 覆盖 ACK 仍在保留窗口内时强制重建、空账户、待处理请求复用、快照发布、幂等 ACK 和设备撤销；同时回归策略快照、权限 GC 和选定跨 owner 转发路径。协议生成物、协议文档、schema relation coverage 与 diff 检查通过。

这不是所有群状态修复的完成标志：群控制 reducer 迁移尚未调用此入口；历史负事实仍需恢复；已有可复用快照可以被复用，因此该标志不保证强制重新计算最新 artifact。独立 room_log/hybrid 房间流仍遵守各自授权和基线合同，个人快照不能代替其修复。未做 App 到真实 gateway 的端到端网络、Linux、负载或生产验收；B03 缺失依赖恢复和 delivery authority 也未关闭。
