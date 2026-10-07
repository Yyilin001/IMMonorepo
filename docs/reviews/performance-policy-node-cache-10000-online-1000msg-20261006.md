# 节点权限缓存修正后的性能：10,000 在线 / 1,000 msg/s

日期：2026-10-06。当前工作树 Release 重建后运行 R24，比较修正前 R23。权限热探测从 19.385 ms 降至 0.034 ms，约降低 99.82%；双方共有的六个负载器报告，消息阶段 p95 降低 26.54%–31.84%。整体仍未通过，不能认定稳定吞吐提升或 1,000 msg/s 达标。

## 相同条件

- 分支 `feat/actor-realtime-routing`，本地工作树（含未提交改动），生产 Release。
- 10,000 用户、10,000 普通私聊房间，6 Gateway、12 Loader，128 字节消息。
- 同一 fixture `/tmp/imv2-10k1000-current-fixture-20261005`；同一场景 `IMV2/load-scenarios/actor-realtime-message-redesign-1000.json`，目标合计 1,000 条新消息/秒、60 秒。保留首次冷加载，没有额外预热。
- fixture manifest、scenario、edge source 和 configuration defaults 的 SHA256 与 R23 相同。没有增加连接池、队列容量、重试次数或超时预算。
- TCP 提交与 TCP 恢复，独立 PostgreSQL 24532。沿用 `--allow-scaled-diagnostic` 以执行 10,000 用户，质量检查保留。
- Gateway / Account / Loader 构建分别 217.74 / 11.97 / 16.13 秒，构建进程 exit=0。

## 实际运行

R24：`/tmp/imv2-memory-policy-10k1000-20261006-r24`。压测进程 exit=1。

12 份 ready 证明开始消息前 10,000 连接全部就绪。约 20.002 秒时，负载器因消息 deferred retry exhausted 触发 workload failure guard，提前结束，未完成 60 秒。

最终只取得 7/12 份报告（1、2、3、4、7、8、9），剩余五个负载器清理时收到 SIGTERM。已知七份合计发送 11,659、ACK 9,087、workloadFailed 2,572：其中 18 个 deferred retry exhausted，2,554 个 outcome unknown connection closed。未知结果可能已经提交，不能将这些数当作明确消息丢失。

报告记录 1,023 次 SERVER_BUSY，是临时拒绝事件，含重试，不能与失败消息数相加。报告缺失意味着完整共同窗口为零；不使用局部 ACK 合计计算全局吞吐或成功率。

quality、capacity、steady、drain 均 false。服务清理 settled=true，forcedKillCount=0，13 个服务进程全部 exit=0，未发生此前 SIGBUS；12 个负载器退出非零或被终止。此前 R23 forcedKillCount=1。本次服务正常退出不等于消息排空达标。

## 客户端延迟：只比较双方共有的六份报告

使用负载器 1、2、3、7、8、9 的 `rate-1000` 阶段分位数。每个负载器目标 83.333 msg/s，两轮阶段均约 20 秒。以下为同一个负载器的前后比较，不是合并全体消息后的分位数；统计的是已观察到的 ACK，不能代表未知结果或缺失报告。

| Loader | R23 p95 | R24 p95 | 降低 |
| --- | ---: | ---: | ---: |
| 1 | 8,967 ms | 6,112 ms | 31.84% |
| 2 | 8,797 ms | 6,346 ms | 27.86% |
| 3 | 8,880 ms | 6,481 ms | 27.02% |
| 7 | 8,837 ms | 6,389 ms | 27.70% |
| 8 | 8,749 ms | 6,011 ms | 31.30% |
| 9 | 8,643 ms | 6,349 ms | 26.54% |

这六份报告的 p50 降低 2.37%–15.77%，p99 降低 22.26%–32.59%。长尾改善，但消息 p95 仍为约 6–6.5 秒。

## 六节点阶段采样

两轮都限制在各自已知报告的阶段交集内，仅选择六节点全部成功且采样开始/结束均在区间内的样本。均有四次完整采样，R23 首末跨度 15.487 秒，R24 为 15.476 秒。取累计计数和累计耗时差分。

| 阶段 | R23 样本 / 平均 | R24 样本 / 平均 | 平均降低 |
| --- | ---: | ---: | ---: |
| 权限内存探测 | 10,390 / 19.385 ms | 11,279 / 0.034 ms | 99.82%（约 570 倍） |
| 权限状态获取 | 15,067 / 40.194 ms | 16,307 / 21.952 ms | 45.38% |
| 已完成冷加载排队 | 3,663 / 1,699.009 ms | 3,684 / 1,161.607 ms | 31.63% |
| 状态 SQL 事务 | 10,699 / 27.672 ms | 11,702 / 23.944 ms | 13.47% |
| 消息 Owner 事务正文 | 7,143 / 39.941 ms | 8,084 / 36.843 ms | 7.76% |

各阶段统计对象和嵌套关系不同，不能相加当作客户端延迟，也不能把权限探测的 570 倍当成系统吞吐提升。

缓存快照探测 hit/miss：R23 6,483/3,907，R24 6,751/4,528。这是首次冷启动区间，仍有很多未加载 scope。状态事实 SQL 读取计数从 10,693 变为 11,696，不能宣称本轮消除了首次 SQL 读取。后台续租和长时间热态收益也没有得到完整稳定窗口验证。

可以确认本次修改明显降低权限热读取成本，已观察消息的长尾有所下降；尚未解决首次冷加载排队及消息持久化开销，仍出现 SERVER_BUSY 和重试耗尽，未达到完整质量要求。

## 证据与清理

- 构建：`/tmp/imv2-performance-r24-{gateway,account,loader}-build.log`。
- 运行：`/tmp/imv2-performance-r24-run.log`。
- 前后阶段对比：`/tmp/imv2-performance-r24-comparison.json`。
- R24 局部阶段诊断：`candidate/policy-partial-window-diagnostic.json`。
- 同负载器比较：`candidate/paired-client-latency-comparison.json`。
- 运行配置、二进制/源码 SHA256：R24 根目录 `evidence.json`。

持有的进程已结算，独立 PostgreSQL 24532 已停止并确认端口无响应。本轮未修改生产性能代码或压测负载参数。
