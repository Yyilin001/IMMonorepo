# 私聊 room-log R51：50,000 在线、4,000–5,000 msg/s 配置隔离与五分钟 soak

日期：2026-08-28

状态：R51 部署和梯度压测通过；已证明本拓扑在该工作负载下稳定承载 5,000 msg/s 五分钟，
但未覆盖完整 checkpoint 周期、故障切换或多 Gateway，不能作为生产容量批准。

## 结论

R50 的 4,000 msg/s 失败不是 PostgreSQL、Gateway 或磁盘已达到物理上限，而是压测凭证中混入
4,510 个旧 capacity profile 房间。任意一个旧房间进入原子批都会让整个事务以笼统的
`admission_state` 回退到标量路径；64 条批次命中至少一个旧房间的概率约为 94.8%，最终形成
批量回退、前台排队和 `SERVER_BUSY` 的级联。

R51 同时修复数据门禁与运行时隔离：

1. 导出只选择指定 profile、有效 shard lease、有效成员、有效 direct pair、未冻结且可发送的房间；
2. 预检按凭证中的实际两个目标逐条校验，任何跨 profile、过期 lease 或授权异常都在压测前失败；
3. 原子事务在执行副作用前收集所有不兼容输入的原始下标，并给出精确原因；
4. batcher 只让这些输入走标量路径，其余兼容请求重新组成原子批；结果仍按原输入顺序返回；
5. 回滚边界不变：不兼容检测发生在消息、投影、quota、credit 等持久化副作用之前，客户端仍只在
   canonical transaction 提交后收到 ACK。

严格预检确认本轮 50,000 账号、100,000 个目标引用全部属于 `loadtest-v17`，且成员、direct pair、
用户状态、mute、shard pool 和 lease 均有效。R51 的四轮测试没有出现任何 profile、authorization、
admission、conditional-write 或 shape fallback。

## 设计正确性依据

- 事务仍按确定顺序取得 operation/room/policy 锁，避免多事务以不同顺序锁定同一批资源；这符合
  PostgreSQL 对死锁预防的建议：所有应用路径应以一致顺序获取多个对象的锁。
- 普通冷私聊仍在一个 PostgreSQL 事务内完成权威预检、消息/投影持久化和 shard reservation；
  兼容子批重试是一个新的完整事务，不会通过 savepoint 暴露半提交状态。
- 多行输入使用 set-based SQL 降低数据库往返，但没有把进程内 cache 当成授权事实；cache miss、
  revision mismatch 或异常配置都回到权威路径。
- 错误对象只携带当前批次的数组下标和枚举原因，不携带用户、房间或 token，避免诊断信息形成
  新的数据泄漏边界。

参考 PostgreSQL 官方文档：
[显式锁与一致加锁顺序](https://www.postgresql.org/docs/17/explicit-locking.html)、
[INSERT 多行输入](https://www.postgresql.org/docs/current/sql-insert.html)、
[事务隔离](https://www.postgresql.org/docs/current/transaction-iso.html)、
[RELEASE SAVEPOINT](https://www.postgresql.org/docs/current/sql-release-savepoint.html)。

## 测试拓扑和方法

| 项目 | 值 |
| --- | --- |
| Gateway image | `imv2-server:profile-isolation-r51-20260828`；镜像配置只含标准 `PATH` |
| Server binary SHA-256 | `32e97c6ac08c04b983a3cd8baa9b172477948e9104b286481e5ef14182d97a18` |
| Gateway | 4 vCPU / 8 GiB，单 ARM64 实例 |
| PostgreSQL | 8 vCPU / 16 GiB，容器限制 8 GiB，`fsync/full_page_writes/synchronous_commit=on` |
| 压测器 | 4 vCPU / 8 GiB，5 个进程，每进程 10,000 连接、1 个 NIO event loop |
| 在线模型 | 50,000 峰值活跃连接；每账号两个 direct room；persona 加权发送 |
| 消息模型 | 128-byte 普通文本；room-log tail；availability hint 触发拉取；Sync 100/s；计划重连 0.05%/min |
| 每轮隔离 | 200 连接/s 聚合爬坡；50,000 全在线后 180 秒零消息屏障；Gateway 重启清零指标；PG 前后 profile |
| 梯度 | 4,000、4,500、5,000 msg/s 各 90 秒；5,000 msg/s 再持续 300 秒 |

客户端报告保存在压测机
`/opt/imv2-loadtest/reports/r51-profile-isolation-50k-*/`；Gateway 指标在
`/opt/imv2-gateway2/r51-observation/`；PostgreSQL 前后 profile 在
`/opt/imv2-smoke/r51-observation/`。报告保留，临时 access token 与 HMAC 清单已精确删除。

## 客户端结果

下表的延迟取五个分区中最差的对应分位数，不用跨进程平均值掩盖尾部。

| 稳态速率 / 时长 | 在线峰值 | 发送 / ACK | failure / overflow | message P50/P95/P99/max | room pull P95/P99/max | Sync P95/P99/max |
| --- | ---: | ---: | ---: | --- | --- | --- |
| 4,000 / 90 s | 50,000 | 360,000 / 360,000 | 0 / 0 | 58/87/117/262 ms | 4/9/67 ms | 23/42/97 ms |
| 4,500 / 90 s | 50,000 | 405,000 / 405,000 | 0 / 0 | 53/82/110/229 ms | 6/37/85 ms | 23/31/111 ms |
| 5,000 / 90 s | 50,000 | 450,000 / 450,000 | 0 / 0 | 64/109/142/336 ms | 7/47/158 ms | 27/44/145 ms |
| 5,000 / 300 s | 50,000 | 1,500,000 / 1,500,000 | 0 / 0 | 83/158/201/495 ms | 12/88/323 ms | 32/47/212 ms |

四轮均满足：认证失败 0、heartbeat missed 0、workload failure 0、客户端队列尾值 0、
Gateway queue-full 0。五分钟 soak 的五个分片全部排空，最慢 drain 29 ms。

## Gateway 与 PostgreSQL

| 速率 / 时长 | Gateway CPU 峰值 | PG CPU 峰值 | append queue/execution max | 原子批提交 | PG active/lock waiter max | WAL 增量 | commit/rollback/deadlock |
| --- | ---: | ---: | --- | ---: | --- | ---: | --- |
| 4,000 / 90 s | 337.92% | 528.71% | 86/122 ms | 9,474/9,474 | 8/1 | 1,331,941,986 B | 350,523/0/0 |
| 4,500 / 90 s | 376.06% | 361.48% | 75/122 ms | 10,724/10,724 | 9/0 | 1,351,078,420 B | 336,180/0/0 |
| 5,000 / 90 s | 379.24% | 429.42% | 123/153 ms | 11,732/11,732 | 8/2 | 1,415,579,867 B | 353,147/0/0 |
| 5,000 / 300 s | 376.21% | 450.91% | 162/233 ms | 44,122/44,122 | 29/2 | 2,996,168,734 B | 561,776/0/0 |

CPU 是 Docker 的主机核百分比：Gateway 376% 约等于 3.76/4 核，PostgreSQL 451% 约等于
4.51/8 核。CPU 数值为 5 秒采样峰值，不能当作整段平均利用率。五分钟 soak 期间没有 checkpoint
完成：`delta_checkpoints_timed/requested=0/0`；background writer 写 114,587 buffers，backend 写
64,787 buffers，说明本轮覆盖了持续脏页压力，但没有覆盖 30 分钟 checkpoint 周期。

五分钟 soak 的 PostgreSQL 累积 SQL 热点如下。累计执行时间包含并发 worker，不能直接与 300 秒
墙钟时间相除后相加：

| 热点 | calls / rows | 累计执行 | 单次均值 | 主要成本 |
| --- | ---: | ---: | ---: | --- |
| 权威批量房间/权限预检 | 39,870 / 1,434,406 | 165.566 s | 4.153 ms | room、membership、direct pair、policy 与 fence 锁/检查 |
| 批量消息与投影持久化 | 42,991 / 42,991 | 111.488 s | 2.593 ms | 消息、投影、索引、FK 与 WAL |
| 聚合 shard reservation | 39,870 / 39,870 | 64.906 s | 1.628 ms | 条件更新 durable command window |
| operation advisory locks | 50,343 / 50,343 | 27.531 s | 0.547 ms | 幂等串行化 |
| 条件快速追加 | 10,473 / 62,473 | 20.465 s | 1.954 ms | revision-fenced 单语句追加 |

WAL 约为 1,997 B/ACK（该 profile 还包含认证、presence、Sync 与 room pull），没有
`wal_buffers_full`、临时文件、rollback 或 deadlock。现阶段 PostgreSQL 不是先到顶的资源，Gateway
4 核 CPU 余量更小；继续提高单 Gateway 速率时，应先验证 Gateway 的编码、TLS、事件分发和 batch
协调 CPU，而不是盲目扩大数据库连接池或队列。

## 与 R50、R44 的解释性比较

| 版本 / 场景 | 结果 | message P95/P99 | 服务端症状 | 解释 |
| --- | --- | --- | --- | --- |
| R50，4,000 msg/s | 约 10 秒即失败；8,055 ACK，28,570 workload failure | 5,957/7,242 ms | queue 644、27,971 queue-full、141 个 `admission_state` 批回退 | 4,510 个旧 profile 目标污染，约 94.8% 批次被拖入标量回退 |
| R51，4,000 msg/s | 360,000/360,000，0 failure | 87/117 ms | queue max 86 ms、0 rejection、0 fallback | 数据门禁阻止污染；运行时隔离不让单个异常请求拖垮兼容子批 |
| R44，4,000 msg/s | 360,000/360,000，0 failure | 最差分区 72/924 ms | batch execution max 1,912 ms | 数据起点与 checkpoint 相位不同，只能说明 R51 尾部更均匀，不能作为纯代码吞吐 A/B |

因此 R51 相对 R50 是故障恢复和尾延迟数量级改善；相对 R44 不应宣称吞吐百分比提升，因为数据体量、
checkpoint 相位和实现基线不同。可以确认的是，R51 在约 1,332 万条历史消息起点上通过了更高的
5,000 msg/s 与 300 秒持续段。

## 仍然存在的问题

| 优先级 | 问题 | 当前证据 / 影响 | 解决方向 | 关闭门禁 |
| --- | --- | --- | --- | --- |
| P0 | 尚未覆盖完整 checkpoint 周期 | 五分钟 soak 内 checkpoint 增量为 0；无法排除 checkpoint 写回期间 P99/队列突刺 | 固定数据库快照与 checkpoint 相位，5,000 msg/s 至少 30 分钟；统一采集 checkpointer、WAL、设备写延迟和 Gateway 时序 | 跨至少一个完整 checkpoint，ACK 100%，无持续队列，P95/P99 满足 SLO |
| P0 | 单 Gateway CPU 余量较小 | 5,000 msg/s 峰值 3.76/4 核，数据库仅 4.51/8 核；下一上限更可能先在 Gateway | profile JSON/TLS/frame encode、room hint 广播、actor hop 与 batch 协调；先减 CPU 再提高速率，生产则横向扩 Gateway | 同一 workload 提高速率且 CPU、P99 与队列均有可重复改善 |
| P1 | WAL 与索引写放大仍高 | soak 产生约 3.0 GB WAL；持久化 SQL 贡献约 1.46 GB WAL，且每消息仍触发 FK/index 工作 | 审计冗余索引和投影字段；保持正文一次存储、投影窄引用；合并可安全批量的 durable 记录；用 WAL/ACK 验证 | 不减少可靠性/幂等前提下，WAL/ACK、buffer writes 和 SQL CPU 显著下降 |
| P1 | 长时间尾延迟上升 | 90 秒 5k 为 109/142 ms，300 秒为 158/201 ms；batch max 233 ms，虽无积压但余量收窄 | 给 batch stage、pool wait、WAL sync/checkpoint 建同一时间轴；区分偶发写回与 Gateway CPU 调度 | 30 分钟内 P99 不随时间持续漂移，无秒级 max 或排队增长 |
| P1 | 场景仍不是完整高活跃 IM | 当前主要是 128 B 普通私聊、每用户两个房间、单设备、单 Gateway；未覆盖附件/回复/群聊/离线恢复/热点大房间 | 建立 persona×消息类型×房间热度×在线/离线×设备数矩阵，分别给写入和恢复 SLO | 混合消息、恢复 backlog、热点与多设备报告全部通过 |
| P1 | 故障与多实例尚未验证 | 没有 Gateway kill、数据库重启/切换、网络分区、多 Gateway 重连风暴 | 两 Gateway + LB，执行受控 SIGTERM/kill、DB failover、NATS 分区和重连 soak | 零丢失/重复可幂等、游标无 gap、RTO/RPO 达标 |
| P1 | 历史 ARM64 `libdispatch` SIGSEGV 根因未闭环 | R51 四轮及 soak 未复现，但没有原始 core/application frame | 启用 core、符号与崩溃采集，做数小时连接/消息/重启 soak | 可重复根因已修复，或批准时长内零崩溃且证据完整 |
| P2 | 大数据 A/B 起点仍需标准化 | 本轮从约 1,332 万条历史消息开始，结束后消息表进一步增长；不同数据体量会改变 cache/index/checkpoint | 开发环境使用可恢复快照或明确清理策略，每轮记录 relation 大小和统计起点 | 同一快照重复三轮方可宣称代码百分比提升 |

## 清理与当前部署

- 本轮 50,000 个临时 token 已按 HMAC、user、device 三元组精确删除，复核残留为 0；压测机明文凭证、
  数据库机 HMAC 清单和本机传输副本均已删除。
- R48/R49/R50 回滚容器和携带运行时 secret 元数据的旧镜像已删除；当前 R51 镜像配置不含业务 secret。
- 当前服务仍运行 R51，健康检查正常。压测报告与不含 token 的 profile/metrics 保留供审计。
