# 当前工作树性能测试：10,000 在线 / 1,000 新消息每秒

日期：2026-10-06。用户要求先测性能；使用本地工作树的 Release 程序，普通私聊 direct-ring 数据集、6 个 Gateway、12 个负载器。目标负载合计 1,000 条新消息/秒，计划 60 秒；消息正文 128 字节，TCP 发送及 TCP 查询恢复。独立 PostgreSQL 使用 24532，不操作日常 5432 实例。

数据集 `/tmp/imv2-10k1000-current-fixture-20261005` 与场景 `IMV2/load-scenarios/actor-realtime-message-redesign-1000.json` 的 SHA256 均与 R20 一致。原 runner 要求 50,000 用户才称为正式 capacity acceptance，因此本次 10,000 用户使用 `--allow-scaled-diagnostic`；消息、资源、质量和窗口检查仍保留，不把 runner 的名称约束当作通过或失败性能的依据。

## 启动阶段失败与修复

R21 `/tmp/imv2-memory-policy-10k1000-20261006-r21` 和 R22 `/tmp/imv2-memory-policy-10k1000-20261006-r22` 均在连接建立阶段结束：认证/峰值在线 6,528，连接失败 384，12 份报告完整，消息发送和 ACK 都为零。6 个 Gateway 均以 SIGBUS（exit=-10）退出。两轮清理均 settled=true、forcedKillCount=0；这两轮不提供消息吞吐或端到端延迟证据。

R21 macOS 崩溃报告 `/Users/yyl/Library/Logs/DiagnosticReports/IMV2ServerApp-2026-10-06-101530.ips` 显示 stack size exceeded / SIGBUS，栈顶为跨池 borrower 的 pump，下面反复出现 Sendable 函数重抽象 thunk。安全诊断保存于 R21 `candidate/startup-crash-diagnostic.json`。

先将容量通知合并到 EventLoop 调度，避免直接进入 SQL 完成栈；R22 仍失败，证明只延后执行不能修复根因。随后独立 Release 回归 `repeatedCapacityNotifications` 连续借用/归还 20,000 次，在没有 PostgreSQL、TLS 和消息业务的情况下同样崩溃，日志 `/tmp/imv2-capacity-observer-release-before.log`（构建 774.30 秒，实际测试进程 exit=1）。独立崩溃报告 `/Users/yyl/Library/Logs/DiagnosticReports/swiftpm-testing-helper-2026-10-06-103923.ips` 同样为栈溢出 SIGBUS，栈包含重复 thunk。

`V2PhysicalDatabaseLoanGate` 的通知原存储为 `Mutex<(@Sendable () -> Void)?>`，每次通知取出函数。现改为 Mutex 内保存不可变引用对象，对象只构造一次并保存通知函数，避免反复通过 sending 返回值转换函数。borrower 的合并 EventLoop 调度保留；未增加连接容量、排队额度或超时预算。

修复后 `/tmp/imv2-capacity-observer-release-after.log`：Release 重建 605.04 秒，15 项测试、3 个 suite 全部通过（0.214 秒），实际 exit=0；20,000 次容量通知完成。包含不同 EventLoop 借用、并发归还、取消、截止、关闭和实际容量归还。Debug 的先行调度回归 `/tmp/imv2-peer-pump-deferred-tests.log` 14 项通过，但其证据不足以发现此次 Release 缺陷；以独立 Release 复现和修复后验证为准。

## 修复后性能重跑

R23 `/tmp/imv2-memory-policy-10k1000-20261006-r23` 使用修复后的生产 Release，同数据集、场景和资源预算。Gateway / Account / Loader 构建日志前缀 `/tmp/imv2-performance-r23-`，Gateway 构建 237.94 秒，实际成功退出。压测进程最终 exit=1，结果未通过。

| 指标 | 实际结果 |
| --- | --- |
| 启动在线 | 12 份 ready，activeConnections 合计 10,000；全部就绪后同步发消息。 |
| 消息目标 | 合计 1,000 条新消息/秒，计划 60 秒。 |
| 最终报告 | 11/12，缺少第 4 份；该负载器在清理时收到 SIGTERM（exit=-15）。 |
| 实际窗口 | 11 份已知报告交集约 20.001 秒；缺少一份，全局完整共同窗口为零，未完成 60 秒。 |
| 已知报告合计 | 认证/峰值在线 9,167、发送 18,312、ACK 12,888、workloadFailed 5,424。合计仅属于 11 份，不能代表完整负载吞吐。 |
| 客户端 ACK 延迟 | 已知报告 p50 3,253–3,624 ms，p95 8,575–8,958 ms，p99 9,956–10,000 ms；不是合并全体样本的分位数。 |
| 失败记录 | 2,665 次临时 SERVER_BUSY；51 次 deferred retry exhausted，5,373 次 outcome unknown connection closed。后两者合计 5,424；未知结果可能已提交，不能当作明确消息未接受或全是服务端主动断连。 |
| 质量与收尾 | quality、steady、capacity、drain 均 false。清理 settled=true，但 forcedKillCount=1，Gateway 3（服务进程 ordinal=10）exit=-9；其余服务退出正常。 |

R23 已越过两轮 SIGBUS 的启动失败并进入消息负载阶段，服务清理没有 SIGBUS 退出。这证明本次压测未再触发此前的崩溃，不证明任何持续时间和负载下都已稳定。负载器约 20 秒后的失败保护提前结束场景；未通过吞吐、延迟和收尾要求。`acknowledgedMessagesPerSecond` 的局部值不作为完整 10,000 在线吞吐结论，也不与其他缺失报告的历史合计计算提升比例。

### 失败阶段诊断

`candidate/policy-partial-window-diagnostic.json` 限定于 11 份已知报告的约 20.001 秒交集：4 次完整六节点采样，首末跨度 15.487 秒。累计计数差分结果如下，各阶段样本数与嵌套关系不同，不能相加当成客户端延迟：

| 阶段 | 样本数 | 平均耗时 |
| --- | ---: | ---: |
| 冷授权状态队列完成等待 | 3,663 | 1,699.01 ms |
| 状态 SQL 准入 | 10,686 | 14.18 ms |
| 状态 SQL 事务 | 10,699 | 27.67 ms |
| 状态事实读取 | 10,693 | 9.75 ms |
| Owner 连接获取 | 7,147 | 12.07 ms |
| Owner 事务设置 | 7,147 | 8.69 ms |
| Owner 事务正文 | 7,143 | 39.94 ms |
| Owner 提交 | 7,145 | 4.53 ms |

正文内部：围栏 7.88 ms、回执读取 6.33 ms、房间预检 6.79 ms、消息持久化 13.50 ms。该局部区间没有 Owner/事实驱逐；内存快照 probe hit/miss=6,483/3,907。冷状态排队和 SERVER_BUSY 说明仍有资源等待压力；仅凭这些均值不能确定所有端到端长延迟都来自这一处。

所有持有的进程已结算，独立 PostgreSQL 24532 已停止并确认端口无响应。代码回归与 diff whitespace 检查通过，但整条消息链路与容量目标仍未完成。本轮到此结束性能测试，没有继续修改授权设计或扩展负载调优。
