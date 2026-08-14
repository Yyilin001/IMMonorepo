# ADR-013：同步 projection checkpoint 与日志保留

状态：已接受并实施；Snapshot V3/checkpoint/retained floor/compaction 已启用
日期：2026-08-13
所有者：同步、存储与分片负责人

## 背景

旧 snapshot 路径虽按 sequence 分批读 `user_sync_log`，仍需在应用层持续折叠一个随用户
历史增长的完整当前状态。它限制了单次查询，却没有给一次 reset 的进程内状态设置硬上限；
此外，`user_sync_log` 还承担设备增量同步、cross-store inbox 幂等结果、shared fan-out
payload 引用和 user-shard copy/verify。简单按时间或设备 ACK 删除日志会破坏这些语义。

## 已决定并实施：Snapshot V3

Snapshot V3 不再从完整日志临时物化当前状态：

1. `user_projection_versions` 按用户、projection kind、entity key 保存应用级 MVCC 版本；
   `user_projection_checkpoints` 记录严格连续的 `projected_sequence`。
2. 有界 projector 按 user/sequence 推进版本，snapshot 在固定 base sequence 上以稳定 keyset
   扫描 `valid_from <= base < valid_to` 的投影。builder 的候选、编码页和事务均有显式上限，
   不构造完整 Swift 状态图。
3. artifact、page、lease、rolling/root digest、device assignment 和 generation fence 全部持久化；
   构建可逐页恢复，失败或过期会恢复原 generation，已签发但未发布的能力会被撤销。
4. 客户端逐页验证并写入 SQLite shadow tables。完整 shadow 先由服务端幂等 ACK 提交 generation，
   再在一个本地事务中激活；ACK 前 live projection 从不被替换。客户端保存 reset 前精确游标，
   服务端拒绝过期 fence 时可无损回退；ACK 后进程崩溃则从本地 manifest/shadow 重放同一 ACK。
5. user-shard copy/fingerprint 已覆盖 projection versions、checkpoint、artifact/page、reset 和完整
   ACK fence；projection version GC 会保护所有 building/published snapshot baseline 和迁移 fence。

协议与本地状态均按绿地切换，不保留旧 snapshot schema 或双读兼容路径。

## 已实施：日志保留线与 compaction

Snapshot V3 关闭 reset 内存随历史增长，并把 reset 构建工作量改为随当前投影规模增长。
日志删除同时满足：

1. checkpoint 已持久化、摘要已验证，并可被当前受支持 capability profile 解码；
2. 新设备以及低于 retained floor 的 cursor 强制从 checkpoint snapshot 入场；
3. 没有未过期 token、receipt、snapshot 或迁移 fence 引用更早序列；
4. consumer inbox 保存足以回答裁剪后重试的稳定 sequence/result，不再回查已删除 log row；
5. media delivery authorization 已改读 current projection；shared payload 只在所有 log
   引用消失后回收；fan-out inbox 持久化原分配 sequence，裁剪后重试不回查 log；
6. user-shard copy、fingerprint、forwarding 与回滚复制 retained floor 和剩余 tail；
7. compactor 不枚举设备历史；pull 与 retained-floor 发布通过 retention row lock 串行化，只有
   真正再次拉取且低于 floor 的有效设备才获得 reset assignment；同一用户/profile/schema
   可复用仍位于 floor 之上的最新不可变 artifact（之后用增量同步追上），但各自保留独立
   generation、token、receipt 和有效期；
8. 已撤销、无法再次认证的设备能力与 cursor 由 housekeeping 分批回收，不再永久钉住
   compaction 或让状态量随账户设备历史增长。

`PostgresV2UserSyncLogCompactionWorker` 按用户和序列使用有界 `SKIP LOCKED` 批次，在同一
事务复核 checkpoint/fence、未过期 token/receipt 和最小 replay window，发布 retained floor
并分批删除前缀。未来新设备/低 token 的 pull 在共享锁下读到 floor 后按需 stage V3 reset；
压缩成本因此与有界日志批次相关，而不与历史设备数或设备数乘快照大小相关。迁移复制、
fingerprint 和 source retention cleanup 覆盖 floor 与
inbox sequence。Prometheus 分别暴露 uncompacted records、projector lag、snapshot、GC 和
sync-log relation 指标。

## 拒绝的局部方案

- 按 `created_at` TTL：离线设备和历史可见性没有时间等价物；
- 只按最低设备 ACK：未来新设备、token/snapshot 和 inbox 重试可能需要更早事实；
- 保留最近 N 行：无法证明状态折叠或退群后的 delivered-history 语义；
- 先删 log、保留 inbox：当前重试仍可能回查 log sequence；
- 只将 device snapshot 当 checkpoint：它绑定 device/generation 且会过期。

## 验收与运行边界

Snapshot V3 的仓库门禁包括最大尺寸 codec/page、逐页恢复、空账户、构建失败 generation 回退、
过期 reset 回退、ACK 后崩溃恢复、跨代 ACK 重放、MVCC GC 与跨 shard copy/fingerprint；客户端
完整套件和 disposable PostgreSQL 完整套件必须持续通过。

代码回归覆盖 poison projector、compaction 不触碰低 cursor、低 cursor/new device 按需共享
artifact、撤销设备状态回收、有界多批删除和迁移复制。
生产仍需按实际速率验证 replay window、阈值与恢复演练，但不再保留 append-only 设计风险。
