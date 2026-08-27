# 私聊 room-log R34：50,000 在线共享前台帧 A/B

日期：2026-08-27

状态：已完成的限定场景容量证据；不是生产容量批准

## 结论

在同一台 4 vCPU Gateway、同一台 8 vCPU PostgreSQL、同一批 50,000 个账号与房间、相同空消息表起点和相同定时 checkpoint 条件下，R34 把普通私聊前台事件的 protobuf 与 frame 从“每个本地接收连接各编码一次”改为“按事件编码一次，再把不可变字节发送给已授权连接”。

R34 完成 500–5,000 msg/s 十段梯度：2,475,000 条发送全部 ACK，workload failure 与服务端拒绝均为 0。R33 控制组在相同条件下只得到 2,469,564 个 ACK，发生 2,451 次 `SERVER_BUSY`，3/5 个压测分区失败。R34 相对 R33 的分区 P95 约下降 42%，P99 约下降 36%，而 Gateway CPU 与 RSS 基本不变。

该结果支持保留共享编码实现，但不等于完整高活跃 IM 的生产容量。测试仍是单 Gateway、普通私聊文本、禁用内容审核；room-log 读取由 availability hint 触发，没有独立固定的显式 pull QPS，也未覆盖媒体、mention、群聊、多 Gateway、故障切换或长时间 soak。

## 可复现身份

| 项目 | R34 candidate | R33 control |
| --- | --- | --- |
| 源码基线 | `0158eb72014b9965c9b20e42dd2bf4fbbeb03eb7` 加本报告对应工作区变更 | 同一工作区，去掉共享前台帧变更 |
| Server binary SHA-256 | `0e6552f0586a9872cb4e4fd11166cf7288ad1ef655f977a59a92279e9a5fc550` | `d54e2966fd6a603894b273384b48f5bbd779c708db1a7613014150c242983a9e` |
| 场景 | `online-50000-mixed-gradient-500-to-5000-v1` | 相同 |
| 原始报告 | `/opt/imv2-loadtest/reports/gradient50k-r34c-clean-db-500-5000-20260827/` | `/opt/imv2-loadtest/reports/gradient50k-r33d-clean-db-control-500-5000-20260827/` |

两轮均使用 5 个压测进程，每个进程 10,000 连接；每段速率持续 90 秒，总发送速率依次为 500、1,000、1,500……5,000 msg/s。消息是 128 B 普通私聊文本，`maximumInFlightMessagesPerConnection=8`，每个账号准备两个热房间；Sync 与 room-log 客户端路径保持启用，room-log pull 由 availability hint 触发。

## 严格 A/B 结果

| 指标 | R34 shared frame | R33 control | 解释 |
| --- | ---: | ---: | --- |
| 发送 / ACK | 2,475,000 / 2,475,000 | 2,475,000 / 2,469,564 | R34 全部 drain |
| workload failure | 0 | 2,451 | R33 均为 retryable `SERVER_BUSY` |
| 成功分区 | 5 / 5 | 2 / 5 | R33 两个 failure guard、一个 drain timeout |
| message p50 | 50–54 ms | 53–57 ms | R34 约低 6% |
| message p95 | 142–147 ms | 247–251 ms | R34 约低 42% |
| message p99 | 196–232 ms | 333–338 ms | R34 约低 36% |
| message max | 575–5,451 ms | 1,055–1,212 ms | R34 仍有 checkpoint 尾延迟 |
| 实时 payload applied | 2,367,411 | 2,315,313 | R34 多 52,098 条 |
| availability hints | 2,411,835 | 2,363,680 | R34 accepted 闭环更多 |
| fallback room-log pulls | 42,935 | 46,211 | R34 少约 7% |
| fallback records | 97,793 | 130,813 | R34 少约 25% |

R34 的共享帧不改变授权。`V2DeviceConnectionRegistry` 仍先按 room 与 commit 事务捕获的 recipient user IDs 选择连接；每条 stream 在发送前仍检查已认证协议版本和当前 transport writer。共享值只含 `requestID=0` 的 server push 字节，不含连接级凭证、身份或可变状态。持久恢复仍依赖 room cursor，实时 payload 仍是可丢的提交后加速层。

## 资源与数据库

| 指标 | R34 shared frame | R33 control |
| --- | ---: | ---: |
| Gateway CPU 峰值 | 379.83% | 376.25% |
| Gateway RSS 峰值 | 2,537.5 MiB | 2,542.6 MiB |
| append pending 峰值 | 340 | 554 |
| append in-flight 峰值 | 16 | 16 |
| append queue wait 最大值 | 675 ms | 125 ms |
| append execution 最大值 | 4,130 ms | 287 ms |
| event-cache pending 峰值 / drop | 43 / 0 | 19 / 0 |
| PostgreSQL CPU 峰值 | 629.07% | 502.00% |
| PostgreSQL active 峰值 | 19 | 10 |
| PostgreSQL lock wait 峰值 | 0 | 0 |
| WAL 增量 | 4,559,604,222 B | 4,605,291,759 B |

R34 完成了更多 durable work，并把更多提交后事件直接送达客户端，因此 PostgreSQL 瞬时 CPU 与 event-cache pending 高于未完全 drain 的 R33；WAL 反而少约 1%。两版 Gateway CPU 与内存差异不足 2%，不能宣称共享编码降低了峰值资源占用。它的主要已证收益是更少的 Gateway 调度/编码竞争、更高的实时命中率和更低的成功请求 P95/P99。

R34 最大延迟与 append execution 最大值仍受定时 checkpoint 影响。测试没有延长 `checkpoint_timeout` 来回避它：R34 窗口内 checkpoint 于 19:17:23 启动，最高档仍无拒绝。该尾部问题需要单独以 checkpoint、后台脏页写回、WAL 与磁盘延迟为自变量优化，不能靠放大队列掩盖。

## 两个无效/诊断轮次

1. `gradient50k-r34-shared-frame-500-5000-20260827` 在开始负载前因 50,000 个 access token 到期而被 session expiry fence 断开。该轮只证明过期围栏有效，不是性能结果。
2. `gradient50k-r34b-shared-frame-500-5000-20260827` 从 1,030 万条历史消息、约 5.12 GB `messages` 表与索引起跑，并在 4,000 msg/s 时遇到定时 checkpoint。append execution 达 6,001 ms、pending 达 1,152，产生 2,824 次 `SERVER_BUSY`。清除 disposable 旧消息、显式 checkpoint 后，R34c 在真实的下一次定时 checkpoint 内完成 5,000 msg/s。

这两轮说明容量报告必须固定 token/lease 有效期、relation 行数与大小、checkpoint 相位。把旧数据轮次与空表轮次直接比较，会把数据库状态误判成代码收益或回退。

## 尚未证明的边界

1. 至少 30 分钟目标速率和数小时 soak，包含多次完整 checkpoint；
2. 固定显式 room-log pull QPS、离线积压、分页、ACK 与重连恢复；
3. 媒体、回复/转发、mention、编辑、撤回、reaction、审核与陌生人策略混合；
4. 多 Gateway 的连接重分布、credit 浪费、缓存冷启动和故障切换；
5. PostgreSQL 数据量增长后的稳定容量、autovacuum、备份、PITR 与磁盘故障演练。

所以当前可表述为：**在明确的单 Gateway、普通私聊与 hint-triggered room-log 恢复场景中，R34 已验证 50,000 在线和 5,000 msg/s；完整生产容量仍未批准。**
