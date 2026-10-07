# Gateway Journal 在线职责审计

日期：2026-10-03。范围：默认 Gateway 装配的 SQL 源触发、Journal publisher 读取、Gateway 权限安装和实际 socket 写入。房间在线权限、body 和 Ready 由 Room Owner 的局部 subscription fence / 连续控制流提供；Journal 保留独立的 userSync、账号/session/device 控制。

## 普通消息不产生 Journal 条目

源定义是 `IMV2/sql/realtime-change-journal.sql`，不是按触发器名称推断职责。

| 源变化 | 源函数 | 实际持久化 | Gateway Journal 行为 |
| --- | --- | --- | --- |
| `messages` INSERT（`accepted_event_storage='message_row'`） | `capture_realtime_messages_heads` | 按 transition table 的 room 聚合 `max(room_sequence)`，更新 `realtime_dirty_room_heads` | 默认 publisher 未注册 `headStore`，不查询、不解析、不发送这些 H |
| `room_events` INSERT | `capture_realtime_room_events_heads` | 按 room 聚合 `max(room_sequence)`，更新相同 dirty-head 表 | 同上 |
| `rooms` 普通 sequence 更新 | `capture_realtime_change` | owner epoch / membership revision / group permission revision / frozen 状态全部未变则立即 RETURN | 不插入 outbox 或 Journal control 行 |
| `rooms` owner / permission / frozen 等控制变化 | `capture_realtime_change` | roomEvents 控制版本与稀疏 outbox 标量行 | 保留源有序 cut；发送投影去掉房间权限变化 |
| `room_memberships` join / leave / role / joined revision 变化 | `capture_realtime_change` | userSync `membership.changed`、membership discovery version；同时写稀疏 roomEvents membership control | 保留 userSync 发现和控制 floor；不重装 room viewer grant |
| `auth_devices` / `device_refresh_sessions` 凭据或 session 变化 | `capture_realtime_change` | userSync `session.changed`、session control version、每设备最新版本 | 可信 user/device 快照与同步 socket 撤权仍保留 |

两个消息 INSERT 源函数均不写 `realtime_change_outbox` 或 `realtime_change_journal`，也不调用 `capture_realtime_change`。`rooms` 更新只推进 sequence 时亦被 control 函数的早退条件排除。因此普通消息不会被 Journal replay 页读取为“房间 body 行”。数据库仍会按每条 INSERT statement / room 更新一个兼容 dirty-head 标量行；本次没有删除该源持久化职责或修改触发器。

## 正常消息的读取与字节成本

`V2RealtimeJournalEntry` 没有 body/payload 字段，仅有序号、topic、事件 ID、控制版本、设备 ID、owner epoch 和可选 roomSequence。`PostgresV2RealtimeChangeJournalStore.read` 从 Journal 控制表构造这些标量 JSON，不 JOIN messages、room_events 或事件 payload 表。

`GatewayJournalRuntime.build` 的 `V2RealtimeJournalPublisherSource` 只注册 `store`，不注册 `headStore`。Runtime 不再构造/启动 `V2RealtimeOnlineHeadDispatcher`，也没有 applyHeads 回调。因此正常消息产生的 dirty H 在该在线 runtime 上的 pending-head SQL 次数、head JSON 传输/解析和 head RPC 字节均为零。这是接线和 SQL 源定义的结构证据，不是 CPU 或数据库吞吐基准测量。

仍保留的基础成本是 physical source / partition 的 publisher lease 与控制 outbox discovery / replay；这是独立账号、设备与 userSync 控制的后台成本，不按普通消息 body 数增长。稀疏 room-control 标量可能位于相同连续 Journal 页中，publisher 保留其可信有序 cut，发送 adapter 仅保留 userControlInvalidation。未引入新的 skipped-page/cut 协议。

## 权限安装与实际写入边界

- `GatewayJournalAuthorityAssembly` 仅读取 `userSnapshot`，包括空用户集合的源 cut；不再 route 房间、读取 room/viewer permission snapshot 或 room head proof。接收器安装的 rooms/viewers 均为空。
- Runtime 只注册 `configureJournalUserControlReceiver` 和 user baseline barrier，不注册旧 room baseline barrier，也不把 Journal receiver 安装到账号房间变化服务的 viewer 授权端口。
- Registry 在新房间 authority 下不暴露 Journal room viewer interests，旧 Journal room H 发布短路。membershipDiscovery 仍使账号读状态失效，不触发旧 room Coordinator 的权限修复。
- 设备/session 撤权同步取消 room authority 的 connection lifecycle，随后才允许异步 recovery / socket close 清理。
- presence、typing 和独立 userSync 的 Actor 通道没有由这个 runtime 移除；房间 subscription 走独立 Owner ingress。

## 回归证据与限制

已有 PostgreSQL `copyAndMultipleStatementsKeepCoalescedHeadsAndIndependentControlRows` 用例覆盖普通 INSERT/COPY 的 coalesced H 与独立 membership 控制；源代码分类与上面的 SQL 触发定义一致。新增 Gateway/App 测试覆盖发送 adapter 保留 user control 和完整 cut、Journal 不推进房间 Ready/H、实际 Owner ingress 推进 Ready(S) 与 H，以及设备撤权先取消 socket permit。

本代理没有执行构建、SQL 测试或服务。验证由 root 的统一测试执行；本文件只记录可复核的源代码证据与接线边界，不宣称本次测得 SQL 延迟或字节吞吐。

## 120 真实 TCP canary 的 account proof 失败定位

证据目录：`/tmp/imv2-room-subscription-production-tcp-canary-20261003-r1/candidate`。12 份 `report-*.json` 合计 120 个物理连接：room scope 全部 `ready/passed=true`；account scope 17 个 `ready/passed=true`、103 个 `recovering/passed=false`。消息 720/720 ACK，120 个最终 foreground cursor 与 committed head 相等，不能覆盖 account proof 未就绪这一失败。

冻结 Loader `main.swift` 的 coverage snapshot 逻辑要求每个 requested scope 都有新物理连接上的非零 scope generation、递增 revision、正确 scope UUID、`state==ready`，且该 scope 的 applied cursor 不低于 Ready 的固定 highWatermark；报告再验证 physical connection 的完整性与唯一性。它不要求旧 partition owner 字段。新房间 Ready 使用 Registry lifecycle + room interest nonce/generation、可信 actual activation token/shared fence/user authorization 和本地 lease deadline，在同一次实际 socket enqueue gate 中确认，再写固定 S。后续 H 不重新定义 S，这满足等价局部权限证明而非放松 Loader 门槛。

根因：Core UUID 标识输出 Foundation canonical 大写；当时 `V2RealtimeTopicKey.partitionID` 按原字符串哈希。Catalog `userSnapshot` 校验的是 `uuid.uuidString.lowercased()` 的分区，SQL 源 `UUID::text` 亦为小写。用相同 length-prefixed FNV 对 canary 的 120 个 account scope UUID 重算：

| 大写 hash 与小写 hash | account proof | 连接数 |
| --- | --- | ---: |
| 不同 | recovering / failed | 103 |
| 恰好相同 | ready / passed | 17 |

逐连接完全对应，说明早期 `catalogRejected` 可由 Catalog 的 `invalidConfiguration` 分区 guard 确定解释，而非旧房间 proof 不适配。应统一 UUID topic 的 SQL 分区表示，并统一 control entry 与本地 interest 的 UUID key 身份；不能关闭 proof 门槛。后期 coverageChanged/sourceLeaseChanged 位于负载结束与进程关闭附近，独立 generation/lease guard 的拒绝不是这 103 个确定分区失败的替代解释。

修复接线：`V2RealtimeTopicKey` 的所有公开构造与 Codable 解码入口均将合法 UUID 保存为 SQL canonical 小写，opaque ID 原样保留。局部 RecoveryKey 和 ScopeGenerations.Topic 将同一 UUID 保存为 Core 域 canonical 拼写，使 normalized SQL topic 的查找能命中已认证 connection 的 account scope；实际 coverageFrame scopeID 仍为该局部域 ID，Loader 按 UUID 身份校验。没有修改 `V2RealtimeTopic` 的载荷身份字段或降低 Ready/lease/socket 门禁。新增 Swift 构造/解码/opaque 测试、真实 SQL 分区一致测试、account scope index 大小写查找与退休回归；仍待 root 统一构建和 canary 验证。
