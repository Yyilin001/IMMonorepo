# 私聊 room-log R29：50,000 在线、500–5,000 msg/s 梯度记录

日期：2026-08-27
状态：已完成的限定场景容量证据；不是生产容量批准

## 结论

在单 Gateway、单 PostgreSQL、50,000 条已认证长连接和普通私聊文本写入场景中，R29 完成
500 到 5,000 msg/s 的十段梯度，2,475,000 条消息全部收到提交后 ACK，发送失败、服务端拒绝和
drain 遗留均为 0。最高梯度没有把 PostgreSQL CPU 或磁盘打满，Gateway 前台调度与短时排队是
更接近下一瓶颈的部分。

这项结论只适用于本报告明确覆盖的写入和实时 hint 路径。测试把
`roomLogReadsPerSecond` 设为 `0`，不能证明 50,000 客户端同时执行 room-log 恢复拉取时仍能维持
5,000 msg/s，也不能外推到群聊、媒体、审核、回复、mention、多 Gateway 或长时间 soak。

## 可复现身份

| 项目 | 值 |
| --- | --- |
| Git commit | `0158eb72014b9965c9b20e42dd2bf4fbbeb03eb7` |
| 镜像 | `imv2-server:batched-shard-credit-r29-20260827` |
| Server binary SHA-256 | `897dea5baf234caffd1f9deaa8a591bd69792a636b6313688faf384cb9da897b` |
| 场景 | [`high-active-50000-gradient-500-5000.json`](../../load-scenarios/high-active-50000-gradient-500-5000.json) |
| 原始报告 | `/opt/imv2-loadtest/reports/gradient50k-r29-500-5000-final-20260827/`（压测主机） |

## 拓扑与负载

| 维度 | 配置 |
| --- | --- |
| Gateway | 1 个实例，4 vCPU |
| PostgreSQL | 1 台 8 vCPU / 16 GiB 主机 |
| 压测器 | 1 台云端压测机；5 个进程分区，每区 10,000 连接 |
| 在线连接 | 50,000，全部认证成功 |
| 消息 | 普通私聊文本，128 B；四类发送活跃度 persona |
| 梯度 | 500、1,000、1,500……5,000 msg/s；每段 90 秒 |
| 读取 | Sync pull 100/s；显式 room-log pull 0/s |
| 重连 | 每分钟 0.05% |
| 收尾 | 严格 drain 后额外保持 10 秒；额外保持期间不重试、不生成消息 |

`postDrainHoldSeconds` 只修正压测器在严格 drain 后过早断开造成的 teardown storm。它不会延长
服务器处理时间、补发消息或改变 ACK 统计，因此属于测试有效性修正，不是服务器性能优化。

## 结果

| 指标 | 结果 |
| --- | ---: |
| 请求发送 / ACK | 2,475,000 / 2,475,000 |
| workload failure / server rejection | 0 / 0 |
| steady-state drain | 完成 |
| message p50 | 55–56 ms |
| message p95 | 212–216 ms |
| message p99 | 279–285 ms |
| message max | 1,083 ms |

Gateway 观测到前台队列等待峰值 107 ms、执行峰值 297 ms、pending 峰值 407、in-flight 峰值
16；进程 CPU 峰值 376%，RSS 峰值 2,566.9 MiB，拒绝为 0。压测机 CPU 峰值 342.7%，RSS
峰值 2,733 MiB，`ESTABLISHED` 为 50,001。

PostgreSQL 平均已用 CPU 23.43%，瞬时峰值 86.12%；磁盘 util 峰值 23.70%，write await 峰值
2.26 ms，写入峰值 77,632 KiB/s。该窗口内数据库不是持续饱和点。`pg_stat_statements` 中消息
append CTE 为 66,343 次、均值 4.257 ms；event append CTE 为 73,739 次、均值 2.621 ms。

## R29 实现变化及合理性

R29 把 shard-credit 的本地 issue/commit/release 从“micro-batch 内每条消息分别进入 actor”改为
“每个有界 micro-batch 进入 actor 一次，仅在本地信用不足时等待 durable reservation”。这消除了
Gateway Swift serial executor 上与消息数成正比的调度队列，但没有改变以下合同：

- PostgreSQL 仍是授权、membership、policy revision、lease、容量和 sequence 的权威；
- 普通私聊 accepted event 仍在一个 durable transaction 内提交，ACK 仍发生在 commit 之后；
- 本地 credit 只能消费数据库已经保守预扣的额度；失败只会浪费未用额度，不能超额放行；
- 缓存不保存 room/timeline cursor，当前 sequence 始终在数据库锁住当前 room 行后分配；
- 不满足普通、已建立私聊文本形状的请求仍回退完整路径。

因此这是生产热路径中的调度与批量化优化，不是只针对场景文件的捷径。相反，压测器的 drain 后
保持仅用于消除无效 teardown 干扰，两者必须分开解释。

## 尚未证明的边界

以下项目必须单独压测后才可给出生产容量或 SLO：

1. 按真实游标追平后的 room-log pull，包含离线积压、分页、ACK 和重连恢复；
2. 媒体、回复/转发、mention、编辑、撤回、reaction、审核和陌生人配额混合消息；
3. 两个及以上 Gateway 的 credit 浪费上界、连接重分布、故障切换和缓存冷启动；
4. 至少 30 分钟目标速率、数小时 soak、Gateway/PostgreSQL kill 与 WAL/PITR 演练；
5. 用户多设备、热点房间比例、在线提示丢失后的主动恢复，以及客户端可见延迟 SLO。

所以当前可以表述为：**限定的单 Gateway 私聊写入/实时提示路径已验证 50,000 在线和
5,000 msg/s；完整高活跃 IM 容量尚未认证。**

## 回滚

R29 不需要 schema 回滚。将 append batch 或 shard-credit batch size 设为 `0` 即可回到完整单条
事务路径；回滚后继续保留 logical room-event 读取兼容。任何回滚 A/B 都应固定连接数、消息形状、
读取速率、数据库数据量和统计窗口，并保留同一统计纪元的 PostgreSQL 前后差值。
