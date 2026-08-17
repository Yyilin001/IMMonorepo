# ADR-016：单节点数据库连接拓扑、准入与投影批处理

- 状态：已接受并实施（连接池隔离部分经压测修订）
- 日期：2026-08-17
- 范围：Gateway、Account、Operator 单进程、同一 PostgreSQL 实例；不引入独立数据库

## 背景

真实链路压测在 8 vCPU / 16 GiB Gateway 上验证了私聊直达投递和共享消息正文，
但 2,000 连接写入时仍出现 Fluent/AsyncKit 连接池等待超时。进一步观测到：

1. 长生命周期 Store 若只保留一个 `Application.db` 句柄，会固定在一个 EventLoop，导致“每 EventLoop 连接数 × EventLoop 数”的大部分配置容量实际上不可达。
2. 前台命令、Sync、Delivery、Projection 和 Maintenance 共用连接时，后台事务可能增加前台等待；但固定角色池在相同负载 A/B 中又会因不能借用空闲连接而降低总吞吐。
3. 每个物理用户库只有一个 Projection claim loop；共享消息正文虽只存一次，但每个接收者仍逐条执行版本关闭和窄引用插入。
4. 每次 Delivery commit 都立即发送一次 `SYNC_AVAILABLE`，使客户端频繁拉取很小的批次。
5. 每个成功命令都写 info 日志，压测时产生不必要的格式化与输出成本。

目标是测清并提高单机上限，同时保持 PostgreSQL 的事务、WAL、Inbox、游标、路由 epoch 和重试语义。

## 决策

### 1. 每个注册池显式覆盖全部 EventLoop，共享池作为默认

每个物理数据库 URL 的每个已注册 Fluent pool 都显式建立“一条长期句柄 / Application EventLoop”，再由均衡适配器按操作轮转；事务和 session 始终固定在选中的单一底层句柄。Gateway、Account、Operator 使用同一拓扑规则，启动时在每个 EventLoop 上验证 PostgreSQL session GUC。

默认 `IM_V2_DATABASE_WORKLOAD_POOL_ISOLATION_ENABLED=false`，foreground、Sync、Delivery、Projection、Maintenance 借用同一共享池。相同压测下这比五个固定角色池更能利用空闲连接。角色隔离仍是显式实验开关，只能在相同负载证明前台与收敛 SLO 同时改善后启用；它不改变数据所有权或事务边界。

启用角色隔离时，每个 event loop 的五项预算之和不得超过
`IM_V2_DATABASE_MAX_CONNECTIONS_PER_EVENT_LOOP`，再乘 event-loop 数和物理数据库数后不得超过
`IM_V2_DATABASE_MAX_TOTAL_CONNECTIONS`。启动时失败关闭。

同库 Delivery 必须继续通过 Delivery control store 在一笔事务中提交 Inbox、sequence、Sync Log 和 completion 状态；不能为了“拆池”破坏原子性。Sync 使用 Sync control router 获取相同 advisory route fence，Maintenance/Projection 使用各自的数据库句柄。

### 2. 前台和 Sync 使用独立过载准入

`V2DatabaseWorkAdmissionController` 在 Fluent pool timeout 之前提供两个 O(1) FIFO 短队列：

- foreground 与 Sync 各自有独立 in-flight 上限；
- 两类各自拥有等待数硬上限，并共享显式等待超时；
- 超限返回可重试 `SERVER_BUSY`，不占用数据库连接；
- 客户端取消会移除等待者，不遗留 continuation 或 detached task。

产品/滥用限流仍是 `RATE_LIMITED`，不能与本机资源过载混用。

### 3. Projection 并行 claim，accepted message 批量落表

每个物理用户库运行显式数量的 Projection loop。现有 checkpoint
`FOR UPDATE ... SKIP LOCKED` 保证同一用户只有一个 worker，且 checkpoint 只在整个连续批次成功后推进。

共享正文只在 immutable state 创建边界做一次完整强类型验证。接收者 projector 使用关系列重新验证确定性 state ID、消息、房间、revision、variant、schema、origin/state event 和 withdrawal 状态，不再为每个用户重复解析正文。连续 `message.accepted` 使用一个 data-modifying CTE 批量关闭旧版本并插入窄引用；数据库返回的插入数必须等于输入数，否则整笔 checkpoint 事务回滚。Edit、withdraw、redact、membership 等有顺序依赖的事件继续走原逐条状态机。

ready checkpoint 另有 `(updated_at, user_id) WHERE state='ready'` 在线索引，匹配 `SKIP LOCKED` claim 顺序。多个 schema 共用一个物理库时，启动预算按每个 schema 的 projector lanes 加 snapshot builder 合计，不能把同一物理池重复计算。

### 4. Sync hint 合并

`V2SyncWakeCoalescer` 每 40 ms（可配置）按 user 保存一个最大 high-watermark。
Composition root 只创建一个可取消的 `run()` task；Delivery 不再为每条消息创建 task。
pending 与 in-flight 使用同一个用户容量上限；飞行期间到达的更高水位形成一个 follow-up，不会重复占用用户槽位。flush 使用有界结构化并发，交付、合并和丢弃都有固定词汇指标。溢出仍可丢弃，因为 hint 从来不是交付凭证，客户端游标 Pull 才是权威恢复路径。

### 5. 减少 Sync SQL 往返和日志开销

- active-device advisory lock、撤销 tombstone 检查和 cursor create 合并为一个 SQL statement；
- Pull 的 token 与 receipt 在一个 statement 中原子签发；
- ACK 的 cursor lock 与 receipt lookup 合并；
- Prometheus 继续记录全部命令，只有快速成功的结构化日志按 trace ID 稳定采样；拒绝、失败和慢命令全部保留。

PostgreSQL 的 `fsync`、`synchronous_commit`、`full_page_writes` 不得为了跑分关闭。

## 安全性与正确性

- 客户端不能选择 pool、route、audience、projection mode 或准入 class。
- `SERVER_BUSY` 不包含用户、房间、消息、URL、SQL 或异常文本。
- Projection 批量 SQL 不接受正文作为新的信任来源；它验证已持久化 immutable state 的 ID、消息、房间、revision、variant、schema 和 withdrawal 状态。
- hint 合并只影响在线提示延迟，不改变 Delivery completion、Inbox 幂等或 Sync cursor。
- 所有指标使用固定 label vocabulary，禁止 user/device/room/message/shard URL 标签。

## 回滚

以下开关可独立关闭，无 schema 回滚：

- `IM_V2_DATABASE_WORKLOAD_POOL_ISOLATION_ENABLED=false`：恢复单一 pool；
- `IM_V2_DATABASE_WORK_ADMISSION_ENABLED=false`：停止返回 `SERVER_BUSY`；
- `IM_V2_ACCEPTED_MESSAGE_PROJECTION_BATCH_ENABLED=false`：恢复逐条 projector；
- `IM_V2_SYNC_WAKE_COALESCING_ENABLED=false`：恢复逐次本地 hint。

回滚不会删除数据或改变 wire protocol。是否回滚必须依据运行指标和一致性审计，不能通过关闭 PostgreSQL durability 参数掩盖问题。

## 结果与限制

该决策先修复了原先虚假的多 EventLoop 容量，再用有界准入限制前台和 Sync 进入共享池的并发；它不宣称固定角色池必然更快。批处理减少 accepted-message 投影 SQL 往返，wake 合并提高每次 Sync Pull 的平均记录数。它不能消除单 PostgreSQL 的 CPU、WAL、索引更新和提交延迟；最终容量仍必须由相同数据模型、相同 durability 参数和完整客户端链路的压测确定。
