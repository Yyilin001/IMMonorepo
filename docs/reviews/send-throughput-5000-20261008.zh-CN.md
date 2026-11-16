# 10,000 在线 / 3,500 msg/s 优化记录（原目标 5,000，2026-10-08）

本记录覆盖 10,000 在线场景。R156、R157 在发送房间全部预热后，各通过 180 秒的 3,000 msg/s 测量。3,500 msg/s 有通过和失败轮次，稳定容量仍待验证。下文保留 R153—R155 的失败对照与 R156—R157 的配置和结果。较早轮次的逐轮数据可从提交 `9e31ff0c82a7` 的本文件查阅。

## R153—R155：全发送房间预热后3000稳定性验证

用户要求房间预热后能否稳定3000。服务端main072a8a51/R145 Release未改，10000在线、6Gateway、每节点6写连接/2消息DB EventLoop、128字节消息、测量10Hz及原persona随机发送、同步20/s不变。修改仅压测器：Phase可选sendSelection（weighted_random默认不变、round_robin轮询全slots用于覆盖预热），刷新算法SHA并Release构建IMV2GatewayLoadGenerator成功23.90秒。round_robin忽略persona发送权重，刻意覆盖所有在线客户端；测量恢复weighted_random，因此预热改变活跃房间覆盖与运行历史，不能将差异单独归因于缓存冷热。未改失败阈值/并发上限/队列上限/报告收集规则。

各轮独立恢复原fixture，预热1000/s×30秒轮询、10秒无主动发送消化，再3000/s×180秒。每轮预热29988条全部ACK；DB按消息created_at与测量开始时间切分，确认10000发送者、5000房间、10000发送者/房间组合预热；各轮测量入库的组合均有预热记录（未预热组合0）。每轮测量counter权限冷SQL新增0。预热期间每个worker2499次发送，覆盖其833/834连接多轮；默认availability_hint发送选择当前active room，不能误称已向fixture两目标房间各自发送，实际测量房间覆盖以DB组合验证为准。

| 指标 | R153 | R154 | R155 |
|---|---:|---:|---:|
| 测量观测公共窗口秒 | 90.001 | 180.009 | 180.002 |
| 测量阶段跑满 | 否 | 是 | 是 |
| 测量发送 | 269022 | 539959 | 539854 |
| 测量阶段内ACK | 266179 | 539395 | 539575 |
| 测量最终ACK（排空/结束后） | 267040 | 539945 | 539805 |
| 客户端发送队列溢出 | 954 | 41 | 146 |
| 客户端发送队列放弃 | 12 | 0 | 0 |
| TCP_DEFERRED_RETRY_EXHAUSTED | 528 | 14 | 49 |
| TCP_OUTCOME_UNKNOWN_CONNECTION_CLOSED | 1466 | 0 | 0 |
| SERVER_BUSY wire次数 | 18223 | 8042 | 15140 |
| 房间队列均值ms | 70.297 | 27.216 | 37.657 |
| 写调度均值ms | 115.554 | 43.885 | 63.879 |
| 实际借连接ms | 1.072 | 0.947 | 1.039 |
| 单语句周期ms | 7.810 | 6.465 | 7.130 |
| 分片阶段消息P50 ms | 293—344 | 172—186 | 256—292 |
| 分片阶段消息P95 ms | 2472—2889 | 1047—1242 | 1482—1676 |
| 分片阶段消息P99 ms | 4921—5252 | 1963—2265 | 2424—2840 |
| 整机CPU使用率 | 97.228% | 99.593% | 99.790% |
| 压测通过 | 否 | 否 | 否 |

R153约90秒触发workload failure guard（TCP_DEFERRED_RETRY_EXHAUSTED），之后连接关闭带来额外outcome unknown，不能将全部连接关闭错误当作最初原因；12报告保留，但失败后停止发送，不作为持续180秒容量样本。R154/R155跑满仍因溢出、重试失败未通过，跑完≠稳定通过。各轮无关的最初连接预热仍通过，失败属于测量消息负载，不混同R150/R151启动失败。

PG messages/completions分别297687/569933/569793，两表匹配、metadata missing/mismatch均0。R154/R155等于含预热的最终ACK；R153比最终ACK总数297028多659条，说明存在入库但客户端结果不确定的消息，不能称所有发送均成功或仅靠数据库记录宣称未丢消息。三轮owned服务cleanup settled=true，验证PG均关闭。未走正常成功路径的前台最终验证不能推断全部10000前台视图已追平。

阶段均值6节点counter加权、人口不一致且有嵌套，不相加当端到端；客户端分位数是12分片各自范围，并且仅阶段内完成消息，失败/未完成请求不在延迟分位数中。整机CPU为测量内相邻采样区间加权，包含PG、压测器、六Gateway、其它服务及系统。确认全覆盖预热和无权限冷SQL，足以否定“冷加载是此次失败的必要原因”，但尚不能精确归因CPU、投递恢复放大、数据库执行或调度中的唯一瓶颈。与此前60秒未全覆盖预热轮不同，不能宣称预热本身导致负优化或计算因果提升百分比。

结论：当前配置下，房间真实发送预热后仍未达到零失败稳定3000msg/s。本次是三轮可复核诊断，非长期生产容量认证。证据/tmp/imv2-resource-10k3000-roomwarm-20261008-r153/r154/r155，各轮hotspots、verification和roomwarm-coverage日志；/tmp/imv2-r153-r155-roomwarm-performance.json；/tmp/imv2-room-prewarm-loader-build.log。


## 写放大核对与序号触发器优化（R156—R157）

检查普通无引用私聊的单语句路径：每批按房间更新 rooms 游标，插入 messages 和 message_send_completions；消息语句级触发器按房间合并推进 realtime_dirty_room_heads，后台确认再清 pending。普通 message_row 消息不逐条写 room_events、realtime_change_outbox 或 realtime_change_journal。成功记录已只有一份，不能重复执行已经完成的旧回执表删除。两张内容/成功表的生命周期不同，保留内容清理后的发送身份与结果。

R155 留存数据库累计插入消息及成功记录各569793行，rooms更新490745次/HOT481333次（98.08%），dirty head更新541882次/HOT474411次（87.55%）。messages包含9个索引，普通无引用消息维护7个，加成功记录主键共8个Btree条目。两表含索引分配空间约630.72MiB，索引约312.59MiB。两个摘要索引在该负载扫描0次、合计约89MiB，但 PostgresV2RoomLatestVisibleStore 的最新候选及授权历史回退实际使用它们，已有长历史执行计划测试要求保留最新候选索引；本轮未删除。统计包含初始化/预热/验证，空间不是实际写入字节或WAL，也不能换算为耗时份额。证据 /tmp/imv2-r155-write-amplification-audit.json。

实际改动：capture_realtime_change 在 rooms UPDATE 分支先比较原生 owner_epoch、membership_revision、group_permission_revision、frozen_at；只更新序号时直接退出，不再先构造 NEW/OLD 整行JSONB。其余表、房间INSERT/DELETE及真实控制变化继续原流程。更新 V2RealtimeJournalSchemaReadiness 函数源哈希至9ac9e0b999285c37e8d169a676c33cfb；没有减少持久化行数、删除索引或弱化CAS通知恢复保护。

独立disposable PostgreSQL运行V2RealtimeJournalSchemaReadinessTests共4项全部通过，包括新增序号不递增控制版本、Owner/成员/权限版本及冻结/解冻仍递增版本。最初新增测试的冻结输入未同步frozen_by_user_id，违反已有rooms_check；修正合法测试输入后通过。可重复安装、禁用触发器拒绝、缺失revision++拒绝等原测试通过。Release IMV2ServerApp构建通过193.73秒，git diff --check通过。原压测器round_robin改动延续R153—R155，本轮没有修改它或阈值。


两轮独立恢复原fixture、同配置重测：10000在线/6Gateway/每节点6写连接/2消息DB EventLoop/128字节消息；round_robin1000/s预热30秒、消化10秒，恢复原persona weighted_random3000/s测量180秒，同步20/s、10Hz突发不变。测量每轮540000条，含预热最终569988条全部ACK；两轮qualityPassed、capacityCompleted、steadyStateCompleted、drained全部true、runner退出0、12份报告完整。相对于R155观测如下：

| 指标 | R155优化前 | R156 | R157 |
|---|---:|---:|---:|
| 测量持续秒 | 180.002 | 180.003 | 180.003 |
| 测量发送 | 539854 | 540000 | 540000 |
| 测量阶段内ACK | 539575 | 539360 | 539816 |
| 测量最终ACK | 539805 | 540000 | 540000 |
| 房间排队均值ms | 37.657 | 10.561 | 9.275 |
| 写调度均值ms | 63.879 | 12.068 | 10.034 |
| 借连接均值ms | 1.039 | 0.700 | 0.666 |
| 单语句周期均值ms | 7.130 | 4.304 | 4.020 |
| 分片消息P50 ms | 256—292 | 65—69 | 60—66 |
| 分片消息P95 ms | 1482—1676 | 340—359 | 317—338 |
| 分片消息P99 ms | 2424—2840 | 568—612 | 523—592 |
| 队列溢出 | 146 | 0 | 0 |
| 重试耗尽 | 49 | 0 | 0 |
| 测量SERVER_BUSY wire次数 | 15140 | 371 | 274 |
| 整机CPU使用率 | 99.790% | 97.745% | 96.975% |
| 通过 | 否 | 是 | 是 |

R156/R157数据库分别messages/completions各569988行，operation_metadata_missing=0、mismatched=0。预热数据库覆盖10000发送者/5000房间/10000发送者房间组合，测量9852组合均预热（未预热0），测量权限冷SQL计数两轮均0。owned服务cleanup settled=true/forcedKillCount=0，验证启动的PG均finally关闭。

对比R155，单语句周期观测下降39.6%/43.6%，房间排队下降72.0%/75.4%，写调度下降81.1%/84.3%。这是历史基线与两轮改动后同配置的观测差异，未做交错恢复旧SQL的随机A/B，不能全部作为两次JSONB转换的独立耗时；整机仍接近CPU饱和，少量开销/重试减少可能产生非线性排队改善，尚未证明唯一原因。没有新增行级/WAL实测，也没有消除消息索引与dirty head写放大。两轮各180秒通过，不宣称长期生产稳定容量或3500能力。阶段均值计数加权且嵌套，不直接相加；P50/P95/P99为12分片范围，非总体分位数。

证据：/tmp/imv2-resource-10k3000-roomwarm-20261008-r156、r157；/tmp/imv2-r156-performance.json、/tmp/imv2-r157-performance.json；各轮hotspots/db-verification/roomwarm-coverage JSON；/tmp/imv2-write-amplification-tests-r156.log、/tmp/imv2-write-amplification-release-r156.log。保留改动，未自动提交或推送。
