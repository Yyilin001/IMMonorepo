# 私聊 room-log R36：50,000 在线、历史数据与 checkpoint 压力复测

日期：2026-08-28

状态：已完成的瓶颈诊断；不是生产容量批准，也不能与空表 R34 直接作代码 A/B

## 结论

当前代码和单 Gateway 可以建立并维持 50,000 个认证连接。总发送速率为 4,000 msg/s 时，
Gateway 约使用 3.03 核、RSS 约 2.37 GiB，append pending 为 0，未出现 CPU、内存、连接池或锁等待耗尽。
升到 4,500 msg/s 后，append pending 突增到 1,141，最大排队约 1,362 ms、最大执行约 1,535 ms，
随后客户端保护阈值终止了测试。

本轮首先暴露的是 PostgreSQL checkpoint 相位下的 WAL/FPI 与脏页写回放大，而不是 50,000 个长连接本身。
测试开始前数据库约有 1,087 万条 `messages` 估算行数；测试期间又恰逢新的定时 checkpoint。
该条件与 R34 的清理后受控起点不同，因此不能把本轮失败解释成 R36 代码相对 R34 的性能回退。

## 可复现身份与场景

| 项目 | 值 |
| --- | --- |
| 源码基线 | `e0bcc9ad` 加本报告同一工作区内的进程生命周期、重启和测量修复 |
| Gateway image | `imv2-server:gateway-main-r36-20260828` |
| Server binary SHA-256 | `63032033a64a9fd4bb706fb971246962d1832b6bafa6f78cfde9ebe6e0cbdb1a` |
| Gateway | 4 vCPU / 8 GiB，单实例 |
| PostgreSQL | 8 vCPU / 16 GiB，单实例 |
| 压测器 | 4 vCPU / 8 GiB，5 个进程，每进程 10,000 连接 |
| 场景 | 两个热私聊房间、room-log 初始追平、availability hint、Sync、混合 persona、0.05%/min 重连 |
| 梯度 | 4,000 msg/s 60 秒，4,500 msg/s 120 秒，5,000 msg/s 180 秒；因 guard 未进入 5,000 档 |
| 原始报告 | `/opt/imv2-loadtest/reports/gradient50k-r36-main-lifecycle-focused-20260828/` |

## 客户端结果

| 指标 | 结果 |
| --- | ---: |
| 认证 / 峰值活跃 | 50,036 / 50,000 |
| 发送 / ACK | 429,372 / 421,693 |
| workload failure | 5,298 |
| `SERVER_BUSY` | 5,215 |
| `UNAVAILABLE` | 83 |
| message P50 | 54–58 ms；异常分区 56 ms |
| message P95 | 74–78 ms；异常分区 130 ms |
| message P99 | 93–104 ms；异常分区 8,573 ms |
| room-log P95 | 正常分区 4 ms；异常分区 97 ms |
| Gateway restart / health | 0 / healthy |

四个分区在保护阈值触发前的 message P99 为 93–104 ms；一个分区承受了队列突刺和系统性中止，
P99 达 8,573 ms。该长尾不能通过只汇总五个分区的平均数隐藏。

## PostgreSQL 证据

本轮 profile 增量：

| 指标 | R36 focused |
| --- | ---: |
| WAL bytes | 1,666,463,118 B |
| WAL records / FPI | 9,220,103 / 236,246 |
| WAL write / sync | 122,665 / 122,499 |
| WAL write / sync time | 3,062 ms / 30,769 ms |
| checkpoint buffers | 8,271 |
| background clean buffers | 113,454 |
| backend-written buffers | 109,369 |
| lock wait | 0 |

按 ACK 粗略归一化，本轮约为 3,952 WAL B/ACK、0.56 FPI/ACK 和 0.259 backend buffer/ACK。
R35e 在相同历史数据附近但不同 checkpoint 相位下约为 2,135 WAL B/ACK、0.125 FPI/ACK 和
0.069 backend buffer/ACK。本轮分别约放大 1.85、4.5 和 3.8 倍。R35e 使用的是旧 R33 Gateway，
且最后发生过进程崩溃，因此这些数字只能定位数据库相位，不能证明应用版本优劣。

PostgreSQL 日志记录到一个 checkpoint 写出 214,532 个 buffer，写入阶段持续 1,620.018 秒，
总耗时 1,620.109 秒。当前 `checkpoint_timeout=30min`、`checkpoint_completion_target=0.9`，
意味着 PostgreSQL 会尝试把一次定时 checkpoint 的写入摊到约 27 分钟；在持续脏页负载下，
距离下次按开始时间计算的 checkpoint 只剩约 3 分钟。提高 timeout/max WAL 降低了频率，
但没有消除稳态写放大。

最热两类 SQL 仍然是授权/预检 CTE 和 canonical append CTE；它们分别约 4.914 ms 和
3.113 ms/批。没有观测到锁等待，瞬时数据库 CPU 也没有先达到 8 核上限。问题是同一批消息在
checkpoint 相位需要写入更多 WAL/FPI/脏页，并把偶发存储停顿放大为有界队列突刺。

## 本轮同时关闭的问题

1. 部署漂移：测试前实际运行的是旧 R33 image；R36 已部署当前工作区 binary，并记录 SHA-256。
2. 进程停止放大：SIGTERM source 改为进程级持有且不在退出前取消；listener 启用
   `SO_REUSEADDR`。受控重启无端口占用，R36 focused 全程 restart 为 0。
3. 压测身份匹配：load generator 读取 UUID 时统一成 canonical 形式，避免服务端大写 UUID 与
   小写夹具造成 room/用户映射误判。
4. PostgreSQL profile：新增 checkpoint/bgwriter/WAL/index 增量和负载前置校验。

这不能证明此前 ARM64 Linux `libdispatch` SIGSEGV 已根除。当前只能证明可疑 signal source 生命周期
已经收敛、重启风暴已消除，并且本轮约五分钟压力没有复现；关闭该风险仍需长 soak 和崩溃转储。

## 剩余工作及优先级

1. **先做受控 checkpoint A/B。** 固定数据库快照、显式记录 checkpoint 起止和 relation 大小，
   分别测 checkpoint 外与 checkpoint 内 4,000/4,500 msg/s；每档至少 10 分钟。
2. **降低 durable write amplification。** 以 WAL B/ACK、FPI/ACK、backend buffer/ACK 为主指标，
   审查 append 热路径的冗余索引、热行更新和事务边界；任何索引删除都必须先有读取计划与恢复路径证据。
3. **再决定存储配置。** 若数据模型优化后 checkpoint 内仍超 SLO，才比较更大 WAL 空间、独立 WAL/更高
   IOPS 或数据库横向拆分；扩大 Gateway queue 只会把 `SERVER_BUSY` 变成长尾。
4. **完成真实场景门禁。** 至少 30 分钟目标速率和数小时 soak，覆盖多次完整 checkpoint、显式恢复拉取、
   离线积压、混合消息、多 Gateway 和 kill/failover，并审计零 gap/丢失。
