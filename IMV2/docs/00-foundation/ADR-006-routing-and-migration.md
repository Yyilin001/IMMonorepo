# ADR-006：Room/User shard 路由与在线迁移

状态：在线迁移部分已于 2026-09-20 删除（见 [用户分片部署范围](../10-operations/user-shard-migration-runbook.md)）；路由部分待存储与运维负责人批准  
日期：2026-07-23  
所有者：存储平台主管

## 背景与决定候选

规范要求版本化 `StorageRouter`：room 以 `room_id` 路由，user 以 `user_id` 路由；
delivery 保存逻辑 user-shard bucket 和 router epoch，不能保存物理数据库地址。
迁移需 initial copy/verify → forwarding/dual-write → final verify → cutover → retention
rollback → cleanup。当前实现不启用 dual-read 或任意读取错误时的 read fallback，避免旧
序列覆盖新 owner 的单调读取。运行时必须显式配置 bucket
和 epoch，planner 将二者持久化到每个 delivery，绝不以用户 UUID 前缀推导路由。
delivery worker 在写入前重新解析目标用户的 route；若其 bucket/epoch 已过期，
以当前 claim token 为 fence，把同一 pending delivery 原子改写为当前逻辑 write
bucket/epoch 并释放 lease，绝不向旧 owner 写入、复制 target 或 terminal skip。
新 bucket 的 worker 随后处理保留原始
`(source_event_id, target_user_id, projection_kind)` inbox key 的同一任务。router
当前 PostgreSQL control-plane 已持久化默认 route、每用户 write-owner override、
可选 read fallback、epoch CAS 与幂等 operation audit；gateway 在启动时只初始化
缺失的默认 route，随后 planner/worker 每次有界处理都会重新读取这一逻辑配置。
copy/verify 的阶段记录、切流前置校验、PostgreSQL user-projection copy/verify
adapter、运行时物理 bucket registry 与保留期租约已实现；loopback-only operator
可对单一指定 user migration 运行 initial copy/verify 和 forwarding final-verify。
fan-out delivery 会在由逻辑 route 选定的物理 target store 写入同步投影，随后才在
控制库完成 delivery；迁移 forwarding 时，仍在 source owner 的同一 fan-out effect
会先写 source 再 shadow 写 target。关系、block 与陌生人消息接收设置的权威事务
仍在控制库；forwarding 时会以其已提交的 source operation/sync sequence 幂等 mirror
到迁移 target，cutover 后则由 current write owner 分配新 sequence。同一 operation 的
响应丢失重试不会分配新 sequence。sync pull/ack/snapshot
每次只按当前 logical write owner 访问物理 store，绝不自动使用 read fallback。
runtime 会对部署 registry 中每个逻辑 bucket 进行有界 delivery claim；全局 worker
并发上限不因 bucket 数量而放大。该调度能力不构成网络分区或容量证据。

## 备选方案

- 固定哈希：无法安全移动热点和恢复路由；
- 版本化 router + 单写 owner/read fallback：满足可恢复 cutover；
- 多 owner 同时写：会扩大 fan-out 与 inbox 不确定性，拒绝采用。

## 批准后的门槛与复审

明确 router 控制面、epoch/fence、存储布局、迁移 owner、回滚窗口和 runbook；
实现 stale-route refresh/forwarding 后，以故障注入证明一个 inbox/sync effect。
任何物理存储拓扑或迁移窗口变化均复审。

## 已落地的过期路由交接边界

上述 stale-route handoff 是切流后的单写-owner durable 基元：它只转移已存在的
`fanout_delivery`，不会发起跨 shard 广播；接收侧 `consumer_inbox` 唯一键仍是
最终去重防线。迁移窗口内 source→target 的 shadow 写由 forwarding phase 明确
执行，而非由 stale-route handoff 隐式承担。两者都不是完整迁移控制面，不能替代
copy、最终校验、保留窗口或回滚运行手册。

每用户 cutover 必须携带一次性 operation ID 与预期 epoch；控制面在同一事务中
锁定配置、拒绝 stale epoch、写入唯一 operation 结果、更新唯一 write owner，并
返回新的逻辑 route。调用者必须先完成目标 shard 的 copy/verify 证据；本接口不
尝试推断或伪造该证据。控制面会锁定同一用户的 migration record，只接受与
source bucket、target bucket、router epoch 一致且处于 `verified` 的记录；它在
同一事务中写入 route override、cutover operation，并进入有明确截止时间的
`retention` 状态。截止后，独立 worker 的实现会以可过期的 lease 调用幂等
source-cleaner；gateway runtime 会从部署专用的
`IM_V2_USER_SHARD_STORES_JSON` 解析逻辑 bucket 到 database/schema 的映射，启动
前校验每个 schema，并据此调度 cleaner。该映射不写入 delivery、route、日志或 HTTP
响应。cleaner 故障只留下可回收 lease，不会提前删除旧 owner 的数据。

已提供的 PostgreSQL adapter 接受 source/target 数据库连接及经校验的 schema 名，
只复制 fan-out receiver inbox、sync sequence/log、device sync cursor、撤销设备的
单调 projection tombstone、snapshot/page、token 和 receipt；Auth service 的设备凭据
不由它搬运。user sync log 以 sequence
分页 copy，其他记录使用 receiver 端唯一约束 `ON CONFLICT DO NOTHING`，随后对
两端同一投影集合计算 SHA-256 canonical fingerprint。它也实现 source-cleaner，
并由 runtime bucket registry 调度。operator 的同一映射是必填项；其
`copy-verify` endpoint 一次只接受一个 migration ID/user/source bucket/target
bucket/epoch，绝不接受数据库地址或 SQL。

copy/verify、forwarding final-verify 与 cutover 入口均只挂载在已有的 loopback-only operator process：它们
复用独立 bearer 认证与受限 operator principal，返回 `no-store` JSON，且一次请求
只能处理一个用户。copy/verify 仅在 durable `prepared`/`failed` 状态调用物理
adapter，并在初次 fingerprint 相等后进入 `forwarding`；source owner 的后续 fan-out
effect 以及关系、block、陌生人消息接收设置的 source sync record 都会 shadow 写入
target；cutover 后这些控制面投影改由 current write owner 自主分配 sequence。独立
`verify-forwarding` 的最终 fingerprint 相等后才进入 `verified`。进行中的 phase 返回
冲突。cutover
不接受 SQL、物理地址、批量范围或调用者提供的 copy/verify 断言。

rollback 同样只在 operator process 的单用户 `no-store` endpoint 可用。请求不携带
bucket；控制面从已切流 migration 的 durable source/target 事实中推导回切方向，且
只接受尚未过期的 `retention` phase、当前 write owner 仍为 target、read fallback
仍为 source、以及匹配的 router epoch。成功后它以新的 epoch 让 source 恢复 write
owner、target 成为 read fallback，并把 migration 标为 `rolled_back` 以取消 source
cleaner 的保留期 claim。相同 operation ID 只会重放同一结果。

## 跨物理 store fan-out 投影

fan-out 的 plan、delivery lease、completion unit 与 admission 计数继续由控制库
权威持有；它们不能被拆到 target store 后再尝试分布式事务。worker 对一个已 claim
的 delivery 先从控制库读取不可变 event payload，再在 route 对应 target store 的
同一事务中插入 `consumer_inbox`、分配 `user_sync_sequence` 并写入 `user_sync_log`。
若进程在该事务与控制库完成之间中断，下一次尝试会由 target inbox 唯一键命中已有
同步记录并取回其 sequence，随后仅在原 delivery lease 仍有效时完成控制库的计数。
因此不会重复用户可见同步记录或 completion-unit 计数。

该路径已在两个独立 PostgreSQL 容器（控制库与 target store）的集成测试中覆盖，
含上述崩溃窗口及 target TCP connection-refused：目标不可达时 control delivery 保持
pending 并写入有界 retry，目标恢复后才恰好完成一次同步投影和 completion 计数。它仍
不是网络分区、跨 region 延迟或吞吐容量的部署证据。
