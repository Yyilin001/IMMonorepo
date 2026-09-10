# 私聊 room-log R44：50,000 在线、4,000 msg/s 冷路径事务批处理复测

> **历史归档。** R44 是 R36 与 R51 之间的阶段性复测，已被同日稍后的
> [R51 配置隔离与五分钟 soak](../direct-room-log-50000-profile-isolation-r51-2026-08-28.md)
> 取代。当前容量证据以 R51 与 [standard-100k](../standard-100k.md) 为准。
日期：2026-08-28

状态：压测通过；这是单 Gateway、单 PostgreSQL 的阶段性容量证据，不是生产容量批准

## 结论

R44 在 50,000 个峰值活跃连接、总计 4,000 msg/s、真实 room-log hint/拉取场景下，
完成 360,000 次发送并收到 360,000 次 ACK。没有 workload failure、连接失败、心跳漏失、
Gateway 队列满、数据库死锁、OOM 或容器重启。

本轮修复把 `shard_only` 模式下的冷 room/cache-miss 普通私聊写入合并为单个 PostgreSQL 事务：
批量加操作锁、批量做房间/成员/策略预检、批量持久化消息，最后按 shard lease 聚合并条件扣减容量。
任何容量不满足都会回滚同批全部消息。旧 `room` admission 模式仍保留标量冷路径，避免进程内预取
room credit 与数据库绝对计数互相覆盖。

## 测试身份与场景

| 项目 | 值 |
| --- | --- |
| Gateway image | `imv2-server:cold-batch-r44-20260828` |
| Server binary SHA-256 | `6e455d20ed71f6be9098d23c6eef51151c99f133f75993e8b7fa06faf4df2f20` |
| Gateway | 4 vCPU / 8 GiB，单实例 |
| PostgreSQL | 8 vCPU / 16 GiB，单实例、容器限制 8 GiB |
| 压测器 | 4 vCPU / 8 GiB，5 个进程，每进程 10,000 连接 |
| 连接与速率 | 50,000 峰值活跃；4,000 msg/s；持续发送 90 秒 |
| 场景 | 每账号两个热私聊房间、初始 room-log tail、availability hint、room-log pull、Sync、计划重连 |
| Gateway 报告 | `/opt/imv2-loadtest/reports/r44-cold-batch-shardonly-50k-4000-20260828/` |
| PostgreSQL profile | `/opt/imv2-smoke/walfix-profiles/r44-cold-batch-shardonly-50k-4000-20260828/` |

## 客户端结果

| 指标 | 结果 |
| --- | ---: |
| 请求连接 / 峰值活跃 | 50,000 / 50,000 |
| 认证尝试 / 认证成功 / 失败 | 50,035 / 50,035 / 0 |
| 计划重连 | 35 |
| 消息发送 / ACK | 360,000 / 360,000 |
| workload failure / skipped | 0 / 0 |
| 心跳发送 / ACK / missed | 689,564 / 687,537 / 0 |
| room availability hints | 359,997 |
| room live payload / pull records | 358,163 / 1,837 |
| room pull / pages | 1,815 / 1,815 |
| 五个压测进程合计峰值 RSS | 2,650 MiB |

分区延迟如下，不能用平均数隐藏分区 02、03 的尾部毛刺：

| 分区 | message P50/P95/P99/max | room pull P95/P99/max | heartbeat P95/P99/max |
| --- | --- | --- | --- |
| 00 | 42/62/89/469 ms | 3/20/53 ms | 138/326/2,045 ms |
| 01 | 44/62/91/512 ms | 4/41/176 ms | 124/321/2,123 ms |
| 02 | 44/68/503/4,186 ms | 12/442/1,900 ms | 130/1,565/3,013 ms |
| 03 | 44/72/924/4,630 ms | 5/1,593/1,832 ms | 159/1,653/3,400 ms |
| 04 | 43/61/75/158 ms | 3/19/48 ms | 99/236/2,075 ms |

## Gateway 与 PostgreSQL 证据

Gateway 共接受并 dequeue 360,000 个发送请求；357,992 个请求进入原子批处理，2,008 个走 singleton。
共提交 9,554 个冷批，所有批次均无 shape fallback。全部完成批次为 11,562，平均约 31.14 条/批。
平均队列等待约 1.97 ms/请求，最大 248 ms；平均批执行约 34.70 ms，最大 1,912 ms；队列满拒绝为 0。

消息阶段 Gateway 约 2.48 核、RSS 约 2.36 GiB；PostgreSQL 约 2.21 核、RSS 约 2.56 GiB。
数据盘采样最大利用率约 27.6%，P95 写等待约 0.22 ms，未达到 CPU 或磁盘上限。

本轮 PostgreSQL profile 包含 50,000 次认证、100,070 次房间打开/预热以及消息流量，不能全部归因于消息：

| 指标 | R44 |
| --- | ---: |
| commit / rollback / deadlock | 553,277 / 0 / 0 |
| WAL bytes | 1,324,976,214 B |
| WAL sync / sync time | 182,075 / 43,107.615 ms |
| 冷批预检 CTE | 9,549 calls；4.275 ms/call |
| 批量消息持久化 | 11,375 calls；2.547 ms/call；约 31.65 msg/call |
| 聚合 shard reservation | 9,549 calls；0.383 ms/call |

R43 失败轮只有约 9,048 ACK，因此按 ACK 归一化只可作方向性比较：commit/ACK 从约 10.49 降至
1.54（约低 85%），WAL/ACK 从约 16.82 KiB 降至 3.68 KiB（约低 78%）。与此前 R37 的
352,910/360,000 ACK、3,608 workload failure 相比，本轮达到 360,000/360,000 且不再出现连接池
自死锁或 idle-in-transaction 风暴。

## 剩余风险

1. **P99 相位毛刺。** 两个分区仍出现 0.5–0.9 秒 P99 和约 4.6 秒 max；Gateway 最大批执行
   1.912 秒。需要把 batch execution 按 SQL 阶段打点，并与 checkpoint/WAL sync、连接池等待和
   Swift event-loop stall 用同一时间轴关联。
2. **尚未证明生产稳态。** 90 秒消息段没有覆盖完整 checkpoint 周期、数小时 soak、离线积压恢复、
   多 Gateway 与故障切换。4,000 msg/s 是本场景通过值，不是最终稳定上限。
3. **部署配置仍可能漂移。** backlog/accept batch 和 `room credit = 0` 曾依赖一次性启动参数或镜像继承值；
   当前 R44 已显式设置，但需要把所有必需值纳入版本化部署配置和启动前断言。
4. **优雅停机未闭环。** 旧 Gateway 在停止时超过 35 秒后以 137 退出；应为 listener、连接 drain、
   batch flush 和数据库池关闭分别设置有界阶段与指标。
5. **测试数据生命周期。** 临时 access token 已全部撤销；大规模测试账号、房间和消息尚需独立 namespace、
   TTL/清理作业或可恢复的数据库快照策略，避免历史数据影响后续 A/B。

## 下一轮门禁

先修 P99 可观测性，不扩大队列。固定同一数据库起点，在 4,000 msg/s 下跑至少 30 分钟并跨越完整
checkpoint，再做 4,500、5,000 msg/s 梯度。每档同时要求消息成功率、P95/P99、最大批执行、队列等待、
pool wait、WAL B/s、WAL sync、checkpoint buffer、磁盘等待和 room-log gap 审计通过。
