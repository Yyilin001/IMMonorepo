# 10,000 在线 / 3,500 msg/s 优化记录（原目标 5,000，2026-10-08）

**最新 R138—R143：生产实现不变，原场景3000 / 3500各两轮均通过；发送预热诊断3000通过、3500失败。失败轮保留12/12报告，仍有19次overflow和4条重试耗尽。结论是存在通过能力与明显波动，尚无稳定3500的证明，详细对照见文末。**

**后续对照 R135 / R136：当前实现再次失败；逐文件恢复至R132的旧实现也失败。R133认证消息体改动不是失败的必要条件，现有实验不支持将它作为唯一原因；当前源码已精确恢复，Server / Account Release重建通过。**

**最新复测 R134（同源码与二进制、同3500配置）失败：约20秒触发重试耗尽，全局取消，仅2/12客户端报告。此前三轮通过是历史事实，但最新结果说明3500尚不能称为稳定容量。完整当前诊断表见文末R134，不能用缺失报告计算全量客户端吞吐或总体分位数。**

用户在 R133 测试期间将最终目标从 5,000 调整为 3,500 msg/s；最新 R133 与此前 R130 / R132 的 3,500 档消息和同步验收均通过，R132 / R133 服务退出正常。目标按现有原场景的完整窗口、零溢出、有限排空与前台追平门槛验收；本记录保留原 5,000 目标时期的实验结论。

目标是完整测量窗口内稳定完成发送，并保持 TCP ACK、持久化成功记录、房间顺序和恢复语义。连接预算、运行时线程数与诊断开销分开验证。失败或提前结束的轮次不能用于吞吐量达标结论。

## 官方资料与代码对应

- [SwiftNIO EventLoop](https://github.com/apple/swift-nio/blob/main/Sources/NIOCore/EventLoop.swift)：同一线程处理多个 Channel；同步长计算也会阻塞其他 I/O。当前锁之外执行的计算仍可能占用数据库 EventLoop。
- [SE-0417 Task Executor Preference](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0417-task-executor-preference.md)：偏好能够减少执行器切换，但不隔离计算开销；具有默认执行器的 Actor 也可能受到偏好影响。当前事务体偏好连接 EventLoop，借用根任务仍在全局执行器运行。
- [AsyncKit 1.22.0 池实现](https://raw.githubusercontent.com/vapor/async-kit/1.22.0/Sources/AsyncKit/ConnectionPool/EventLoopGroupConnectionPool.swift)：按 EventLoop 建立子池，连接额度按子池配置，闭包 Future 完成后归还连接。当前依赖确实为 AsyncKit 1.22.0、PostgresKit 2.16.1、FluentPostgresDriver 2.12.0、SwiftNIO 2.101.3。
- [PostgresClient](https://github.com/vapor/postgres-nio/blob/main/Sources/PostgresNIO/Pool/PostgresClient.swift)：提供结构化并发管理的连接池，必须持续运行 `run()`；`withConnection` 闭包结束才释放连接。不能仅更换 async API 就消除闭包内计算占用连接的问题。

## R82：定位诊断代码对热路径的干扰

配置与 R79/R80 相同：6 个节点，每节点 4 条消息写连接、2 条消息数据库 EventLoop 与 1 条控制 EventLoop，10,000 在线、1500 msg/s、60 秒窗口。采样文件：`/tmp/imv2-r82-server-sample.txt`。

发现 `selectConnectedRoom` 获得物理连接后，在数据库任务执行器上执行慢请求等待归因。最多扫描 512 份历史 timeline，逐个取锁读取标记，再构造事件集合、排序并计算区间。两个消息数据库线程分别有 254 / 628 和 252 / 628 次栈采样落在归因计算入口。这个比例是线程栈采样比例，不能解释为全进程 CPU 百分比。

该轮有 CPU 采样干扰，且提前失败：仅 1 / 12 份负载报告，报告中有 6 次 TCP_DEFERRED_RETRY_EXHAUSTED；随后取消产生 2 次结果不确定的连接关闭。质量门槛未通过，不能作为完整性能基准。

## R83：将计算移出物理连接租借范围

- 房间选中时保存固定等待终点、覆盖范围和有界历史引用。
- 在物理连接归还并释放调度资源后，由原借用根任务进行归因计算；之后继续已提交状态更新与结果返回。没有增加脱离生命周期的诊断 Task。
- 半开区间之外的历史在事件集合建立和排序前过滤，减少无关历史参与计算。
- 保留归因类别、历史缺失标记、事务提交后 ACK 与同房间串行边界。
- 单元测试 25 项通过；独立临时 PostgreSQL 回归 25 项通过（43.114 秒）；Release 构建通过。新增回归检查历史与未来区间不会改变当前请求的等待分区。

R83 完整窗口通过：90,000 条发送、90,000 条 ACK、失败 0；数据库消息和成功记录各 90,000 条，缺失操作元数据与匹配错误均为 0。服务和核对用 PostgreSQL 已关闭。

| 指标（ms） | R80：改动前 | R83 |
|---|---:|---:|
| 写连接调度等待均值 | 45.833 | 15.535 |
| 房间队列等待均值 | 29.207 | 12.828 |
| 实际借连接均值 | 1.104 | 0.679 |
| 客户端分片 P95 均值 | 440.583 | 237.000 |
| 客户端分片 P99 均值 | 641.667 | 386.833 |

阶段均值来自测量窗口内监控计数差值；客户端分位数为 12 个负载分片各自分位数的算术平均，并非所有请求合并后的分位数。R83 的写连接等待下降约 66.1%，房间排队约 56.1%，分片 P95 均值约 46.2%。主机 CPU 空闲区间均值由 14.12% 到 16.76%，服务进程合计占用由 792.91% 到 757.92%（100% 为一核）。因此连接占用范围的改善显著，但总 CPU 开销下降有限。

## R84 / R85：3000 档尚未通过

R84 保持每节点 4 条写连接；R85 仅改为 8 条，两轮均因重试耗尽提前结束，不能报告完整 3000 档吞吐量。R84 仅 10 / 12 份负载报告，截短窗口约 10 秒；一个完整 5 秒主机 CPU 区间空闲为 0%。截短窗口的写调度等待均值约 1039 ms、房间队列约 635 ms、事务正文约 4.60 ms、BEGIN 约 2.74 ms、COMMIT 约 2.11 ms。上述只用于失败定位，不与完整窗口建立性能提升结论。

扩连接未解决 3000 档失败，继续采样优化后的执行路径以确定计算热点。目标仍未达到，不能用局部连接等待改善代替最终目标达成。


## R86 / R87：限制拥塞时的诊断计算

R86 为 3000 档、每节点 8 条写连接的采样诊断轮，提前失败，不作为完整性能比较。新的调用栈里，签名 / 验签入口分别累计命中 692 / 609 次、trace 完成 319 次、等待归因 312 次。计数是采样栈入口计数，不能相加解释为全进程 CPU 百分比；后者已经在连接归还后的全局执行器上执行，但仍与业务争用 CPU。

R84 / R85 / R86 的事后数据库核对分别为 26,726 / 28,721 / 25,145 条消息及同数量成功记录，均未见元数据缺失或记录不一致。它们包含全部已提交消息，不等于客户端 ACK 数，更不能证明失败轮质量通过。核对结束后 PostgreSQL 均已关闭。

R87 把详细链路收集改为按操作 UUID 固定 1/64 采样，保留所有请求的聚合阶段指标与压测业务校验。只在选择的房间请求上运行等待归因；Gateway 未解码操作时暂存早期边界，识别出未被采样的操作后丢弃详细 spans。拥塞不会把未采样请求重新升级为详细追踪，避免所有慢请求一起产生计算和日志。全量模式可通过 `IM_V2_SEND_PATH_TRACE_MODE=all` 及压测参数 `--candidate-send-path-trace-mode all` 恢复；实际模式写入证据清单。

验证：29 项 Swift 单元测试通过（25 + 4，含跨分段稳定采样、未采样慢请求跳过和原有全量 sink 兼容）；10 项 Python 压测汇总测试通过；脚本语法与 diff 空白检查通过。首次编译发现装配文件缺少 Foundation 导入，已修复并重跑通过。该改动只调整诊断，不改变签名、授权、事务或 ACK 语义。Release 构建通过（190.71 秒）。R87：采样后的直接 3000 档仍提前失败，仅 1 / 12 份报告；详细日志从 R85 约 77,616 行降至 1,713 行，但截短窗口仍有写调度等待约 558 ms、房间队列约 344 ms，CPU 空闲区间约 0.21%。不把失败窗口作为有效提升比较。R89：先 1500 预热 60 秒，再 3000 测量的诊断场景也失败，仅 2 / 12 份报告；它只用于区分冷加载与持续能力。R87 / R89 事后数据库核对分别 32,125 / 182,447 条消息及同数量成功记录，元数据缺失与记录不一致均为 0，核对后数据库关闭。


## R90：消息追加 SQL 的有界模板缓存

核对发现消息追加 SQL 通过 PostgresKit 2.16.1 的 Future query 接口进入未命名扩展查询，每次重新 Parse / Describe。复杂追加 CTE 的 SQL 形状重复，而 PostgreSQL 与当前 PostgresNIO 已支持命名预备语句。根据[扩展查询协议](https://www.postgresql.org/docs/16/protocol-flow.html)，复用预备语句可以减少重复解析，并可能复用计划；`auto` 规划策略是否选择通用计划仍由 PostgreSQL 决定，不能保证每次都完全省去规划。

本次在现有 PostgresNIO 本地 fork 中增加可选、有界的自动准备选项。默认库行为关闭；Gateway 仅为消息写角色启用，匹配 `/* imv2_plain_direct_append */` 前缀，每物理连接 16 个条目。键包含完整 SQL 与参数类型，首次准备合并沿用驱动状态机，缓存满后回退未命名查询，不增加跨连接共享缓存、驱逐任务或定时器。连接关闭自然释放所有条目。库选项上限 64。

保留 BEGIN、正文、COMMIT 和提交结果不确定的恢复边界。没有因为正文通常只有一次 SQL 就直接删除事务：当前行流在 CommandComplete 完成，而隐式事务由 Sync 关闭，且应用仍在事务内验证写入集合的完整性。

`IM_V2_MESSAGE_WRITE_PREPARED_QUERIES_ENABLED=false` 或压测 `--candidate-message-write-prepared-queries disabled` 可在同一二进制上做对照，模式写入 evidence.json。真实 PostgreSQL 27 项回归通过，包含缓存容量、绑定值变化与失败回滚后的缓存重用；增强后的同 SQL 不同参数类型回归也已在真实 PostgreSQL 通过（2 项，0.018 秒）；Release 构建通过。没有修改签名、权限或房间排序。


## R90 / R91：同一二进制的缓存开关对照

两轮均采用详细链路 1/64 采样、每节点 4 条写连接、2 条消息 EventLoop / 1 条控制 EventLoop，10,000 在线、1500 msg/s、60 秒、10 Hz 发包节奏。R90 开启模板缓存，R91 关闭；两轮均发送 / ACK 90,000 条，失败和队列溢出为 0，完整窗口及实时覆盖质量检查通过。数据库消息、成功记录均为 90,000 条，操作元数据缺失和匹配错误均为 0。服务及事后核对数据库均关闭。

| 阶段均值（ms） | R91：关闭 | R90：开启 | 减少 |
|---|---:|---:|---:|
| 事务正文 | 2.520 | 1.758 | 30.2% |
| 写连接调度等待 | 16.480 | 9.878 | 40.1% |
| 房间队列等待 | 13.236 | 8.550 | 35.4% |
| BEGIN / 设置 | 1.403 | 1.228 | 12.5% |
| COMMIT | 1.183 | 1.101 | 6.9% |
| 客户端分片 P95 均值 | 218.583 | 162.000 | 25.9% |
| 客户端分片 P99 均值 | 389.167 | 283.583 | 27.1% |

这是单次开关对照，未给出多轮统计置信区间；客户端分位数仍为 12 个分片各自分位数的均值，不能标为合并请求的全局分位数。结果支持保留缓存；此前 R83 到 R90 的变化同时包含详细诊断采样，不能全部归因于缓存。

R92 使用同一二进制在 3000 档进行 100 Hz 平滑发包诊断（30 条 / 10 ms，原场景为 300 条 / 100 ms）。仅改变现有负载器支持的场景配置，没有修改负载器算法。它用于判断突发是否为主要原因，不替代原始场景的最终吞吐目标。


R92 提前失败，仅 3 / 12 份负载报告，截短公共窗口 10.004 秒，不能作为完整 3000 档通过或与成功轮比较吞吐。截短窗口写调度约 759.73 ms、房间队列约 426.46 ms、正文约 3.83 ms、BEGIN 约 3.01 ms、COMMIT 约 2.42 ms。说明发包突发不能单独解释失败。数据库事后消息、成功记录均为 30,438 条，元数据缺失 / 匹配错误均为 0，已关闭。

## R93：减少内部 RPC 编码计算

先前采样显示内部签名入口内 JSON 编码占用较多。核对接收端 `V2ActorTrustStore.verify` 是先验证原始包体签名，再解码；`V2ActorSessionAuthenticator` 重放检查使用 session / sequence / attemptID，没有按重新编码字节比较。移除发送签名、本地载荷字节计数和订阅续租批次预检三处 JSON 键排序，保留传输原始字节签名、长度上限、身份 / 主体 / 接收者 / incarnation / 重放检查及提交 ACK 边界。

保留 JSON 协议格式，旧的排序包仍能验签；相同内容更换字节顺序时必须重新签名，不可复用旧签名。新增排序 / 逆序签名互操作和未重新签名的改序拒绝回归。该调整不修改数据库载荷或需要规范化指纹的领域编码。

验证：41 项认证 / 订阅 / 实时认证测试通过（4 个 suite），包括新增签名字节顺序回归；diff 空白检查通过。Release 构建通过（230.15 秒），正在测量新二进制。


R93 的 1500 档完整窗口通过：10,000 在线，发送 / ACK 90,000 条，失败 / 溢出 0，实时覆盖及交付质量通过；事后数据库消息 / 成功记录均 90,000，元数据缺失 / 匹配错误 0，服务与核对数据库关闭。

| 指标（ms） | R90：排序 | R93：未排序 |
|---|---:|---:|
| 写调度等待均值 | 9.878 | 9.640 |
| 房间队列均值 | 8.550 | 8.936 |
| 正文均值 | 1.758 | 1.727 |
| BEGIN 均值 | 1.228 | 1.213 |
| COMMIT 均值 | 1.101 | 1.045 |
| 分片 P95 均值 | 162.000 | 133.250 |
| 分片 P99 均值 | 283.583 | 279.500 |

主机 CPU 空闲区间均值为 24.73%（R90 23.99%）。客户端分片 P95 均值下降约 17.7%，但 P99 和数据库排队变化很小，房间等待略增；尚不足以给出稳定 CPU 或吞吐提升结论。单轮比较未估计随机波动，继续在原 10 Hz 节奏测试 3000 档（R94）。


R94 原始 10 Hz 的 3000 档仍提前失败，仅 3 / 12 份报告、公共窗口 10.006 秒。窗口内写调度约 762.91 ms、房间队列约 429.22 ms、正文约 3.87 ms、BEGIN 约 3.04 ms、COMMIT 约 2.60 ms；CPU 空闲约 1.08%。不能报告完整吞吐或质量通过。事后数据库消息 / 成功记录均 30,918 条，元数据缺失 / 匹配错误 0；服务与核对数据库关闭。移除 JSON 排序没有解决 3000 档容量问题，不能宣称吞吐上限提高。

接下来保留 10,000 在线、6 节点、原 10 Hz 与质量门槛，测试 2000 档（R95）确定完整窗口的可用边界。每包公钥签名 / 验签仍是下一项结构优化候选，不能通过禁用认证来获得性能结果；若采用会话认证，应保留签名握手、身份和接收者绑定、重放、过期、长度及结果绑定，并测量其自身收益。

R94 截短测量窗口进程采样：6 个 actor_host 平均合计约 9.48 核，12 个负载器约 0.35 核。该数据按 CPU 累计时间差值估算，不等于调用栈各类别比例；支持继续优先定位服务端工作量，而非将饱和归咎于负载器。


## R95：2000 档完整通过，5000 目标仍未达到

6 节点、10,000 在线、4 条写连接 / 节点、2 消息 EventLoop / 1 控制 EventLoop，原始 10 Hz 发包，60.002 秒公共窗口。实际发出 / ACK 均 119,988 条，测得确认速率 1999.54 msg/s。最终业务失败 / 队列溢出 / 放弃均 0；WIRE_SUBMIT 119,996 次，其中 8 次 SERVER_BUSY 拒绝重试后成功，不称为没有发生瞬时拒绝。所有连接实时覆盖和前台追平检查通过。数据库消息 / 成功记录 119,988，元数据缺失 / 匹配错误 0；服务正常清理，没有强杀，事后核对数据库也已关闭。

| 阶段 | 窗口均值（ms） |
|---|---:|
| 房间队列等待 | 21.505 |
| 写连接调度等待 | 33.918 |
| 实际借连接 | 0.863 |
| BEGIN | 1.505 |
| 正文 | 2.037 |
| COMMIT | 1.100 |

客户端分片 P50 / P95 / P99 均值为 59.25 / 341.75 / 553.50 ms（非全局分位数）。主机 CPU 空闲区间均值 8.84%。这是新的完整通过档位，不证明优化前无法达到 2000，也不构成优化使容量提高 33.3% 的对照结论。

已验证的确定收益：连接租借范围外移除等待归因计算；详细诊断稳定采样；有界模板缓存。移除键排序简化 RPC 编码，1500 档 P95 单轮改善，但没有改善 3000 档是否通过。后续应以 2000 档为基线继续减少认证 / 编解码 / 调度工作量，再复测 3000、5000；不通过扩大连接池、关闭认证、放宽 ACK 或忽略消息丢失来达标。


## R96 候选：二进制分布式调用封装

现有 `ClusterInvocationEncoder.recordArgument` 先分别编码参数；随后 `InvocationMessage` 通过固定 foundationJSON 再编码 `[Data]`，产生 Base64。候选在当前 distributed-actors fork 中加入 opt-in specializedWithTypeHint serializer：版本标识、调用 UUID、UTF-8 target、泛型类型名称与原始参数字节，用 UInt32 长度定界。不改参数编解码、签名 / 验签、回复认证和事务边界。拒绝截断、尾部垃圾、非法 UTF-8、越界长度和无法容纳的数组数量，再分配集合；受现有外层网络帧大小上限约束。

库默认关闭二进制出站；升级后的 fork 可同时接收原 JSON 和新二进制调用。旧的未升级对端无法接受 新的二进制调用格式，需要所有接收方升级后才启用出站。`IM_V2_ACTOR_BINARY_INVOCATIONS_ENABLED=true` 用于开启当前节点，压测 `--candidate-actor-binary-invocations enabled` 为同一候选的所有节点设置，并写入 evidence.json。默认 disabled 保留原压力场景。回复封装仍为原 Codable 格式，这一候选只处理请求调用外层，不宣称消除整个 RPC 的 JSON。

正在进行 codec 边界及真实 Actor 传输回归，之后使用同一 Release 开关对照；未经测量，不将减少封装字节数等同于提高吞吐。

首轮 45 项 codec / 认证回归通过，但补充真实节点启动测试发现 fork 的出站初始化只支持标准专用序列化 ID，自定义 24 导致启动失败；改用现有 specializedWithTypeHint 入口，重新验证后才能进入压测。

修复后的 78 项测试 / 8 suites 通过（7.672 秒），包含 codec、认证、真实节点桥接、订阅网络和本地 capability；Python 10 项汇总回归通过，diff 空白检查通过。正在构建 Release 用于开关对照。

Release 构建通过（230.47 秒）。R96 以 2000 档开启外层二进制调用封装，随后 R97 使用同一二进制关闭，其他负载及资源参数保持一致。


R96 / R97 同二进制 2000 档对照均完整通过，发送 / ACK 119,988 条，最终失败 0；即时 SERVER_BUSY 拒绝分别 5 / 9 次，重试后成功。两轮消息 / 成功记录均 119,988，元数据缺失 / 匹配错误 0，服务和核对数据库已关闭。

| 指标 | R96：二进制开 | R97：关 |
|---|---:|---:|
| 写调度均值 ms | 33.641 | 37.733 |
| 房间队列均值 ms | 21.438 | 23.673 |
| 正文均值 ms | 1.871 | 2.164 |
| BEGIN 均值 ms | 1.306 | 1.581 |
| COMMIT 均值 ms | 0.961 | 1.123 |
| 分片 P95 均值 ms | 354.917 | 343.167 |
| 分片 P99 均值 ms | 587.083 | 536.417 |
| 主机 CPU 空闲 % | 9.115 | 5.570 |

CPU 与部分排队有改善，但客户端 P95 / P99 单轮更差，原 R95 的 CPU 空闲为 8.84%，不足以确定稳定容量收益。候选保持默认关闭，不宣称吞吐上限提高。R98 将在 2000 档关模式稳定发送约 30 秒后，对一个宿主采样 6 秒 / 2 ms；标记诊断轮，不用于无干扰性能比较。


R98 采样轮提前失败，仅 3 / 12 报告；虽然截取到 60.002 秒公共阶段，缺失报告与最终失败仍使其不具备完整质量证据，不用于性能对照。事后数据库消息 / 成功记录均 119,974，元数据缺失 / 匹配错误 0，服务与核对数据库已关闭。采样在预热和发送约 30 秒后，PID 37646，6 秒 / 2 ms，工具退出 0；单节点采样不能换算全系统 CPU 百分比。

调用树统计对同函数的非 thunk 祖先去重：签名入口 501 次、验签 726 次、JSON 编码 874 次、JSON 解码 680 次、房间选择 39 次、等待归因 7 次。分类有重叠，不能相加当成总 CPU 时间。编码采样的业务父路径还包括订阅状态机 apply 204 次、投递批次 validate 168 次；验签内 JSON 解码 486 次。框架外层编码仅是其中一部分，支持继续检查业务重复编码与完整性指纹，避免直接假设只换 InvocationMessage 就解决容量。


## R99 候选：订阅重放指纹直接按字段哈希

R98 编码父路径之一 `V2RoomSubscriptionStateMachine.apply` 原来执行 JSONEncoder.sortedKeys → JSONSerialization 字典 → 按重新编码字节排序 recipient 集合 → JSONSerialization.sortedKeys → SHA256。候选替换为进程内专用的固定字段 SHA256 增量编码：带版本域、枚举标签、固定大端整数、UTF-8 / Data 长度前缀、optional 存在标记，直接哈希原始消息 PB 载荷。接收者集合按 UserID 排序；成员控制数组保留原顺序；完整 activation / fence / sequence / event 字段均纳入指纹。指纹只用于本进程有界内存重放记录，不持久化、不作为客户端 / 节点间协议字段，因此不要求与旧 JSON 指纹字节相同。

不可变 delivery 结构验证同时移到共享状态锁外；锁内仍检查当前房间、认证 service、fence、过期、重复指纹与授权序号，推进状态和获取投递 permits。没有删除冲突重放保护或重复投递抑制。原 26 项房间订阅 authority 回归已通过，正在增强全部 fence / event 字段、recipient 集合及有序控制数组的指纹回归。

增强验证通过：Server 82 项 / 10 suites，加 Actor 网络 6 项 / 2 suites，共 88 项；Release 构建通过（223.48 秒）。R99 在关二进制调用模式下测试 2000 档，单独检查新指纹及锁外结构验证的效果。


R99 2000 档完整通过，发送 / ACK 119,988 条，最终失败 / 溢出 0，5 次即时 SERVER_BUSY 经重试成功。59.999 秒窗口确认速率 1999.57 msg/s，实时覆盖及前台交付检查通过。数据库消息 / 成功记录各 119,988，操作元数据缺失 / 匹配错误 0，服务与核对数据库关闭。

| 指标 | R97：旧指纹 | R99：字段指纹 |
|---|---:|---:|
| 写调度均值 ms | 37.733 | 26.965 |
| 房间队列均值 ms | 23.673 | 17.263 |
| 正文均值 ms | 2.164 | 2.010 |
| BEGIN 均值 ms | 1.581 | 1.499 |
| COMMIT 均值 ms | 1.123 | 1.151 |
| 分片 P95 均值 ms | 343.167 | 273.250 |
| 分片 P99 均值 ms | 536.417 | 470.333 |
| CPU 空闲 % | 5.570 | 11.671 |

两轮均关闭实验性二进制调用，其他连接 / 负载配置相同；不是同二进制开关对照，也没有多轮置信区间。R99 写调度 / 房间等待分别下降约 28.5% / 27.1%，分片 P95 均值约 20.4%、P99 约 12.3%。此前旧指纹 R95 的 CPU 空闲 8.84%，写调度 33.918 ms；对照存在轮间波动，不能将全部 CPU 差异必然归因于单项改动。R100 保持这些配置测试原 10 Hz 的 3000 档。

下一项已从代码确认的候选：启用 pureRoomLogPull 的 ActivationHost 为判断读取路径，对普通发送请求也完整 JSON 解码；随后 RoomTurnLane 再解码 permit 中的同一 Data。可以将同一次解码的有类型值沿内部执行句柄传入，原公共原始字节接口保留，仍使用原字节预算、准入后取消 / 过期 / phase 重检和串行排队；不能暴露允许调用方提供不匹配字节与 typed 值的入口。


R100 3000 档未通过：公共窗口 20.008 秒（目标 60），发送 59,789 / ACK 56,215，最终工作负载失败 3,574，队列溢出 / 放弃 145 / 66，瞬时 SERVER_BUSY 8,824 次、连接关闭结果不确定 3,251 次。全部 12 份截短报告可用，不能把截短窗口确认速率约 2770 msg/s 作为稳定容量。实时覆盖未通过，3,833 个前台视图未追平。阶段均值仅用于失败定位：房间等待 418.07 ms、写调度 750.49 ms、借连接 1.95 ms、BEGIN 2.87 ms、正文 3.64 ms、COMMIT 2.36 ms；CPU 空闲区间均值 1.68%。事后数据库消息 / 成功记录各 58,707，元数据缺失 / 匹配错误 0，服务与核对数据库关闭。

当前完整通过上限仍为测试档位 2000，未验证整个容量边界，更未达到 5000。保留字段指纹和锁外结构验证的优化；二进制调用封装仍是默认关闭的实验候选，不能算默认路径收益。后续先消除已确认的重复请求解码，再检查投递批次编码，必要时重新采样认证成本；不放宽原在线数、ACK、数据库一致性、实时追平或完整窗口标准。


## R101 候选：复用 Host 的已解码请求

ActivationHost 的 pure-room-log 检测现在创建 runtime 内部 `V2DecodedRoomInvocation<Request>`，其自定义构造函数只从传入字节解码，不能构造不匹配的 byte / value 对。普通请求将这一不可变对象沿内部 execution-handle / lane 入口传递，跳过 Lane 的第二次 JSON 解码；纯读取仍走原 read pin 路径。公共 handle / lane 仍只接受原始字节并自行解码，解码失败时 Host 保留原 raw fallback 及失败优先级。

保留 Host 字节上限、预算中的精确原始 Data / byteCount、准入前和准入后的 phase / cancel / deadline 检查、profile 上限、ordinal、排队与 authority 生命周期。没有增加 Task 或跳过房间准入。新增计数解码器回归验证 Host 普通调用只解码一次，原公共 handle 仍只解码一次，超限载荷不会触发解码，最终预算清零。55 项 Host / Lane 测试通过（2 suites，1.025 秒）。正在验证真实节点桥接 / 本地 capability，之后构建和测量。

节点桥接和本地 capability 回归 30 项 / 2 suites 通过。正在构建 Release，之后 R101 测试 2000、R102 测试 3000；二进制调用实验均关闭，单独验证解码复用。


Release 构建通过（224.07 秒）。R101 2000 档完整通过：60.008 秒，发送 / ACK 119,988，最终失败 / 溢出 0，3 次瞬时 SERVER_BUSY 重试成功，实时覆盖 / 前台追平通过。数据库消息 / 成功记录各 119,988，操作元数据缺失 / 匹配错误 0；服务与核对数据库关闭。

| 指标 | R99 | R101：解码复用 |
|---|---:|---:|
| 写调度均值 ms | 26.965 | 25.451 |
| 房间队列均值 ms | 17.263 | 16.766 |
| 实际借连接 ms | 0.802 | 0.805 |
| BEGIN ms | 1.499 | 1.429 |
| 正文 ms | 2.010 | 1.977 |
| COMMIT ms | 1.151 | 1.071 |
| 分片 P95 均值 ms | 273.250 | 273.333 |
| 分片 P99 均值 ms | 470.333 | 450.583 |
| CPU 空闲 % | 11.671 | 11.821 |

解码复用消除了代码中确定的重复工作，但单轮改善较小，分片 P95 基本不变，不能宣称容量提高。R102 3000 档再次提前失败，仅 1 / 12 份完整报告，公共窗口 10.002 秒；阶段均值用于失败诊断：写调度 683.601 ms、房间等待 380.808 ms、借连接 2.042 ms、BEGIN 2.968 ms、正文 3.747 ms、COMMIT 2.365 ms，CPU 空闲 0.957%。唯一报告的终止原因为 4 / 2512 触发 workload failure guard（TCP_DEFERRED_RETRY_EXHAUSTED）；取消后还记录 351 条连接关闭结果不确定，不能外推全轮 ACK 率。数据库消息 / 成功记录均 31,653，元数据缺失 / 匹配错误 0，所有服务和核对数据库关闭。

## R103 候选：宿主命令预算同步计数

`V2RoomCommandBudget` 没有 I/O、异步等待或真正等待容量的队列，原 Actor 仅为多个房间统一核对宿主 / 房间数量、字节和预留许可。候选改为 Sendable final class，使用 Swift Synchronization.Mutex 保护有界计数与索引，原始字节检查及 UUID 创建在锁外。准入、归还、快照是短同步操作；JSON 解码、SQL、房间执行与取消回调都不进入该锁。保留请求大小、房间 / 宿主容量、预留上限、原始 Data 许可、预算身份、重复 / 跨预算归还保护和峰值统计；房间 Lane 的串行执行及准入后取消 / 截止检查继续保留。

该方案依据 SE-0433 对同步共享状态的 Mutex 支持，避免每次准入与归还仅为计数而跨 Actor 调度；不是移除宿主总容量，也不保证互斥锁公平性。新增并发预留与普通请求共享字节容量、重复归还竞速回归。正在执行 Runtime 全部回归，之后单独测量，未经验证不认定吞吐收益。

Runtime 105 项 / 8 suites 全部通过（1.035 秒）；真实节点桥接与本地 capability 30 项 / 2 suites 通过（7.866 秒）。diff 检查通过，Release 构建中。


Release 构建通过（221.54 秒）。R103 2000 档完整通过：60.003 秒，发送 / ACK 119,988，最终失败 / 溢出 0，3 次瞬时 SERVER_BUSY 重试成功，实时覆盖和前台追平通过。数据库消息 / 成功记录各 119,988，缺失 / 匹配错误 0。

| 指标 | R101：Actor 预算 | R103：同步预算 |
|---|---:|---:|
| 写调度均值 ms | 25.451 | 27.450 |
| 房间队列均值 ms | 16.766 | 18.157 |
| 实际借连接 ms | 0.805 | 0.808 |
| BEGIN ms | 1.429 | 1.448 |
| 正文 ms | 1.977 | 2.008 |
| COMMIT ms | 1.071 | 1.125 |
| 分片 P95 均值 ms | 273.333 | 281.417 |
| 分片 P99 均值 ms | 450.583 | 470.083 |
| CPU 空闲 % | 11.821 | 13.462 |

两个纯计数 Actor hop 已移除，但上述单轮没有测出稳定端到端收益；不能宣称提高吞吐。R104 3000 档仍提前失败：公共窗口 10.009 秒，仅 1 / 12 份报告，写调度 685.108 ms、房间等待 383.996 ms、借连接 2.026 ms、BEGIN 2.936 ms、正文 3.744 ms、COMMIT 2.436 ms，CPU 空闲 0.997%，与改动前 R102 基本相同。唯一报告因 3 / 2508 触发 workload failure guard 终止，发送 2495 / ACK 2102，取消后工作负载失败 393；不能外推全轮 ACK。数据库消息 / 成功记录均 31,693，缺失 / 匹配错误 0。

核对临时 helper 克隆时发现 owned verifier 的整数轮次常量未替换：最初 R103 / R104 输出误查旧轮次。已修复常量、生成对应查询子脚本，逐轮启动各自 PG 根目录重新核对并关闭；上面报告仅采用修复后的真实 R103 / R104 数据。R105 首次 verifier 未找到误指根目录，未启动任何 PG，修复后成功核对。压力测量本身未受影响。

## R105：2500 档定位持久化与实时质量的分界

同一 R103 Release，连接 / EventLoop / 原 10 Hz 调度 / 原在线数保持不变，仅增加 2500 档。公共窗口 60.005 秒完整，149,988 条消息全部 ACK，最终工作负载失败 / 溢出 / 放弃 0，瞬时 SERVER_BUSY 1,208 次重试成功，确认速率约 2496.47 msg/s。但 coverageProof / qualityPassed 均 false，10,000 前台视图中 1,728 未追平；所以 **2500 未达到完整质量验收，不能作为已通过容量**。

数据库消息 / 成功记录均 149,988，元数据缺失 / 匹配错误 0。所有服务正常关闭，forcedKill / exitFailure 均 0，逐轮核对 PG 已关闭。

| 指标 | R103：2000 | R105：2500 |
|---|---:|---:|
| 写调度均值 ms | 27.450 | 164.169 |
| 房间队列均值 ms | 18.157 | 92.287 |
| 实际借连接 ms | 0.808 | 1.160 |
| BEGIN ms | 1.448 | 2.216 |
| 正文 ms | 2.008 | 2.959 |
| COMMIT ms | 1.125 | 1.667 |
| 分片 P95 均值 ms | 281.417 | 1213.250 |
| 分片 P99 均值 ms | 470.083 | 1743.000 |
| CPU 空闲 % | 13.462 | 5.373 |
| 客户端直接实时载荷应用次数 | 122,943 | 15,535 |
| 房间历史拉取记录次数 | 51,352 | 233,071 |
| 房间进度报告接受次数 | 32,810 | 16,496 |

这些是各自完整运行的聚合次数，包含预热 / 排空，不是测量窗口里的精确实时投递率；历史记录可能重复，直接载荷数也不能除以发送数当独立消息覆盖率。它们仍支持明确的后续定位方向：实时载荷通道退化、历史恢复工作增加，而持久化 / ACK 保持完成。不能仅归因于全机 CPU，也不能把补拉次数直接当成消息丢失。

窗口内实时服务 qualification 剩余至少约 18.89 秒，partition renew 失败、房间 activation renewal 各分类失败计数增量均为 0，不支持直接假设服务资格 / activation 续租失败；房间订阅本地 fence / deadline、投递批次错误及重试仍需单独定位。下一步优先按消息 / 授权投递 lane 增加失败归因、分析直接载荷停止的时间点与恢复放大的关系，再优化验证 / 编码与调度；不再仅围绕预算 Actor 或加连接试参数。

从 fork 代码另确认：InvocationEncoder.recordArgument 通过 system.serialization.serialize 编码 SignedPacket，随后 InvocationMessage 再封装 [Data]。上一二进制实验只优化后一层，SignedPacket 的 body / signature 仍有 JSON Base64。后续可评估受版本约束的参数级专用 codec，必须保持原始签名字节、全部鉴权、帧 / 长度边界与旧格式兼容策略，并以实际压测判断；当前尚未实现，不作为已有收益。

完整质量通过档位仍是 10,000 在线 / 2000 msg/s。5000 目标保持未完成。


## R106：订阅授权过期归因与独立续租

上一轮热点分析没有包含 `im_v2_room_subscription_` 前缀，但原 gateway-metrics.jsonl 已保留这些指标。补读原始窗口计数后：R103 2000 档 renewalAccepted 170,902，renewalAuthorityExpired / progressAuthorityExpired / progressAuthorityNotReady 均 0；R105 2500 档 renewalAccepted 14,634，renewalAuthorityExpired 2,074、renewalAuthorityNotReady 195、renewalInvalidGrant 2,269、progressAuthorityExpired 6,823、progressAuthorityNotReady 6,080。是本地房间订阅权限过期，不是已有证据中的 Actor activation / 实时 service qualification 续租失败。上述计数仍用最近压力窗口前后采样近似，不能视为每条消息的精确因果；已扩展分析前缀并加入分类不混淆回归，18 项 Python 分析测试通过。

代码确认 subscriptionRenewBatch 虽已做同 Host 有界 fanout，每个项目仍调用 Host.invoke 进入 RoomTurnLane 的普通写队列。业务叶子 V2RoomSubscriptionOwner.renew 实际只检查既有 activated fence、成员、连续 authorization sequence、内存 control cut 与 Host 既有租约 / 控制 feed 证明，不进行成员 SQL 或推进消息消费；消息积压因此可以阻塞证明返回并压缩 Gateway 的保守租期。这是可消除的结构耦合，未宣称解释全部过期事件。

新增 factory.pureSubscriptionRenew，仅匹配 `.roomSubscription(.renew)`。Host 使用与纯 room-log pull 共用的 lifecycle pin、精确原始字节预算、准入前后 / 完成后的 phase、取消、deadline、qualification 检查，提供 executionAuthority 的可信 activation 截止时间。Host 上层不创建额外 Task、不占写 Lane / 事务连接；订阅、reset、activate、unsubscribe 保留原串行路径。

生产 callback 从 SubscriptionHost 中查找同一完整 token 的既有 Owner，缺失时返回原 catch-up/unavailable 类结果，绝不从 SQL 初始化、生成授权或放宽权限。Owner.renew 的 activated fence / 当前成员 / authorization sequence / controlVersion 前后重检、control feed freshness、租期扣减和过期拒绝保持原样。只是读证明不再等待消息提交。普通请求已解码值继续沿 R101 内部 proof 对象传给 Lane，不引入再次解码。

新增 Runtime 回归覆盖：持有写 reservation 时续租可进入、精确 byte/count budget 占用、过载拒绝、取消等待实际结束、unknown 不毒化写 Lane、subscribe 仍进 Lane、资格撤销后拒绝。新增 Host/Owner 回归覆盖：未登记 / 未 activate 的 Owner 不可续租，登记激活后可续租，成员 snapshot 与历史 read 次数不增加，返回期限不能超过当前控制 feed 15 秒界限。

Server 72 项 / 4 suites、Runtime Host 32 项 / 1 suite、真实节点桥接 / 订阅网络 / 本地 capability 33 项 / 3 suites，共 137 项通过；diff 检查通过。Release 构建中；下一轮同 2500 原场景、同连接配置对照 R105，不先扩大连接、延长权限租约或放宽实时质量。


R106 Release 构建成功（227.42 秒）。原 10,000 在线 / 2500 msg/s、60.009 秒同场景完成，12/12 分片：发送 149,988，ACK 149,987，1 条 TCP_DEFERRED_RETRY_EXHAUSTED，整体 qualityPassed=false。coverageProofPassed=true，10,000 个前台检查均已追平（behind=0），上轮 R105 的 behind=1,728。数据库实际核对消息 / 完成记录均 149,987，operation_metadata_missing / mismatched 均 0；服务 cleanup settled=true、forcedKill=0、exitFailure=0，核对数据库已经关闭。

压力采样窗口：renewalAccepted 183,238（R105 14,634），renewalAuthorityExpired / renewalAuthorityNotReady / progressAuthorityExpired / progressAuthorityNotReady 均 0。说明本次结构拆分解决了此场景观察到的续租过期和实时追平失败，不能据此宣布整体容量提升。socketResponseBusy 增至 31,024（R105 9,319）；实时路径恢复后工作量也恢复，不应把 R105 的降级状态当成完整负载的性能基准。

R106 全量计数均值：房间队列 189.799 ms、写调度 356.536 ms、连接借用 1.589 ms、BEGIN 2.562 ms、正文 3.114 ms、COMMIT 1.846 ms。12 分片 P50 / P95 / P99 的算术平均为 584.333 / 1437.417 / 1996.833 ms（不是全局分位数）。写路径本轮明显更慢，仅实时质量有改善；尚无 2500 完整通过结果。

下一步 R108 合并 Gateway 续租准备的内存读取：缓存代表成员正常路径，一次通过房间 Actor 的既有 read / publication barrier 获取成员是否有效与同一 fence / service 的 authorization sequence；原先 representative 的 checkpoint + memberRevision、随后 admitRenewals 的 checkpoint 共三次串行 Actor 读取。失效 / 退休成员才进入候选搜索，不为大房间每次枚举成员。只读快照不延长租期、不跳过 EventLoop 权限投影发布，不生成注册，准入仍复核 relation 和 shared fence；生产续租成功后仍由原 authority.renew 重新检查。独立续租保留，本轮不改连接数、租期或负载标准。

R108 相关 58 项 / 3 suites 回归通过（2.260 秒）；新增快照回归覆盖缺失 / 未 baseline / 正常 / 错误 service / 错误 fence / 到期，不允许复活授权；新增 Coordinator 回归覆盖 cached 代表成员撤销后，替代授权成员携带同一已发布控制序号续租。既有饱和 peer 公平调度、冷加载不能饿死续租、shutdown join、EventLoop 权限撤销与其他房间独立回归均通过。Release 正在构建，之后仍复测同一 2500 原场景。


R108 Release 成功（221.40 秒）；2500 压力窗口采样 60.005 秒，但 loader 最终因重试失败触发取消，只有 4/12 最终报告，不可作为有效完整容量结果。已回报分片存在 14 条 TCP_DEFERRED_RETRY_EXHAUSTED；取消前数据库已持久化消息 / completion 均 149,954，metadataMissing / mismatched 均 0，owned PostgreSQL 核对后已关闭。服务已停，forcedKill=0；12 个 loader 非正常结果退出而非服务器存活遗漏。

R108 采样均值：房间队列 189.054 ms、写调度 352.967 ms、借连接 1.572 ms、BEGIN 2.539 ms、正文 3.045 ms、COMMIT 1.794 ms，CPU idle 2.353%。续租 accepted 179,380，renewalAuthorityExpired / progressAuthorityExpired 均 0。写调度与 R106 356.536 ms 仅约 1% 差异，不能证明此内存读取合并能解除容量瓶颈，决定撤回 R108 的 RenewalPreparation、Coordinator 和新增实验测试，保留 R106 独立续租。下一项针对不可变投递 batch 的重复 JSON 大小计算进行优化；不放宽边界或增加 retry 掩盖失败。


## R109：不可变投递批次复用本地编码大小

沿调用链确认：Sender 的 validateRoomSubscriptionBatch、Receiver 解码后的 validateRoomSubscriptionBatch、Gateway Ingress.applyRoomSubscriptionBatch 均调用 batch.validate；其中每次都 JSONEncoder.encode(batch).count，再做最大字节检查。Receiver 与 Ingress 持有同一不可变 batch 值，可复用派生计数，而不需要再次把事件 payload Base64 编码和分配完整 JSON Data。先只消除这次重复工作，不改调用边界、房间 Actor、签名或交易语义。

V2RoomSubscriptionDeliveryBatch 保留 let deliveries，添加私有、每实例的短 Mutex<Int?> 派生大小缓存；值复制共享该计数，不保存载荷 Data。首轮 JSON 计算在锁外执行，再以短同步写发布计数；同时首读并发允许重复计算，绝不把编码或 async 工作放进锁里。每次 validate 仍校验 items、每项 payload、fence、顺序、混合 room fence 及当前 maximumBytes；较严格的限制不能借之前缓存通过。自定义 Codable 仅编码原 deliveries key，解码总是创建空本地缓存；自定义 Equatable 仅比较 deliveries。传入 / 网络数据不能提供信任计数，不增加协议字段或持久化。

新增回归针对 wire key、复制 / decode 的不同限制、外来伪造 encodedSize 不可绕过 byte 限制、重复 sequence 仍拒绝，以及同一值并发不同 byte limit 的正确结果。将与真实节点订阅认证 / 网络和 Gateway Authority / Registry / EventLoop 相关回归一并验证，再按原 2500 场景压测；尚不声明收益。

R109 65 项 / 6 suites 通过：Gateway Authority / Registry / EventLoop 56 项，新增 batch 边界 3 项，真实节点订阅 Authentication / Network 6 项。diff 检查通过。Release 构建中；下一轮仍原 10,000 在线 / 2500 msg/s。


R109 Release 构建成功（228.15 秒）。2500 原场景仅获得约 30.006 秒共有采样窗口，因 loader 重试耗尽触发取消，3/12 最终报告，非有效容量 / 对照结果。已报告分片 26 条 TCP_DEFERRED_RETRY_EXHAUSTED，取消后额外 364 条 connection closed / outcome unknown。实际 owned DB 消息 / completion 均 76,875，metadataMissing / mismatched 均 0，已停库。采样均值房间队列 242.096 ms、写调度 444.895 ms、借连接 1.784 ms、BEGIN 2.664 ms、正文 3.202 ms、COMMIT 1.896 ms，CPU idle 1.293%。renewalAccepted 99,075、renewalAuthorityExpired / progressAuthorityExpired 0。不能将较短 / 部分报告的取消结果和完整 R106 当成严格性能百分比对照。

尽管局部理论上少一次 JSON 编码，R109 没有端到端收益证据，不继续保留大小缓存 / 自定义 Codable / Equatable / 实验测试。已撤回本轮源码，仅保留记录；不宣称已定位本轮恶化的单一因果。生产发送源码回到 R106 结构，下一轮先复核 2000 原场景，再重点拆解真实连接持有时间与计算 / 协作执行器负载，不继续堆叠小型未证明缓存。


## R110：撤回无收益实验后复核与同请求连接持有时间

生产源码已回到 R106 结构，R108 内存准备合并、R109 batch 大小缓存完全移除。Release 构建成功（252.51 秒）。10,000 在线 / 原 2000 场景 60.008 秒，12/12 报告，119,988 发送 / ACK，全量工作负载失败 0，qualityPassed / coverageProofPassed 均 true，前台 10,000 / behind 0。5 次临时 SERVER_BUSY 后重试成功。实际数据库消息 / completion 均 119,988、operation_metadata_missing / mismatched 0；核对后数据库已关闭。服务 cleanup settled=true、forcedKill=0、exitFailure=0。

全量阶段计数均值：房间队列 17.364 ms、写调度 26.645 ms、借连接 0.790 ms、BEGIN 1.453 ms、正文 1.995 ms、COMMIT 1.121 ms，借用 ticket Task 启动等待 1.571 ms、gate 交付等待 0.637 ms。CPU idle 平均 13.599%。12 分片 P50 / P95 / P99 算术平均 51.333 / 281.000 / 455.083 ms，仍不是全局分位数。本轮不宣称相对 R103 的约 1% 小差异为稳定性能收益。

另用每条 sampled room_actor trace 上的时间戳，严格选择仅一个完整 BEGIN/body/COMMIT 且包含 driver-entry / pool-return 区间的样本，计算实际持有区间，避免阶段均值相加：

| 同请求指标（抽样，非全量分位数） | R110 2000 | R106 2500 |
| --- | ---: | ---: |
| 合格持有时间样本数 | 1812 | 2252 |
| driver entry → pool return 均值 | 5.412 ms | 9.066 ms |
| 同区间 P95 / P99 | 14.735 / 23.920 ms | 26.967 / 44.549 ms |
| 同一 trace BEGIN + body + COMMIT 均值 | 4.840 ms | 7.982 ms |
| 持有区间中三段之外均值 | 0.573 ms | 1.084 ms |
| ticket creation → scheduling slot release 均值 | 7.811 ms | 14.024 ms |
| 同组 ticket Task 启动等待均值 | 1.698 ms | 3.243 ms |

样本跨该发送负载段的排队 / drain，并受 1/64 与慢日志条件影响，不能用作总体容量算式。完整代码边界：V2EventLoopBalancedDatabase 在实际 entry.database.withConnection 回调标记 driver_entered，actual.whenComplete 标记 pool_returned / 返回 loan / 释放调度名额。物理 callback 内独立 Task 使用数据库 TaskExecutor；顶层 V2SendDispatchRoot 仍 Task.detached 全局执行器，调度名额在创建 root 前占用。

R106 sampled ready 等待分类按时长合计：所有连接已进入 driver 区间 31.21%、slots-full/task-pending 28.01%、slots-full/assignment-pending 21.20%、slot-available 8.82%，其他分类 10.76%。slots-full 的 pending 分类意味着至少一个保留名额仍在该交接阶段，其余名额可能已执行 SQL；绝不代表全部连接同时空闲。这些是请求窗口的观察状态，不是 CPU 采样或可相加的 SQL 单段耗时。

新证据支持优先检查“借用入口占名额后等待全局 root Task”与 assignment 交付的结构成本，同时降低核心签名 RPC 的编码 / 计算负荷。SE-0417 官方再次核对：指定 Task(executorPreference:) 可将任务直接提交到指定 executor；默认 Actor 仍保留隔离，自定义 Actor executor 有更高执行要求。不能只加一个偏好就把 finalization、诊断或其他大计算放进 I/O EventLoop。后续实验要证明入口、SQL 回调、归还和 post-commit 的执行域与生命周期，并同场景对照；当前尚未加入此新实验。

来源：https://github.com/swiftlang/swift-evolution/blob/main/proposals/0417-task-executor-preference.md 。完整质量通过档位仍 2000 msg/s；2500 实时过期修复但发送压力未全量通过，5000 目标未完成。


## R111：同步登记实际借用，独立全局任务等待结算

R110 后直接检查当前代码：调度器先计入 connectionTasks / capacity，再 root.start 的 Task.detached 开始运行，之后才调用 withScheduledSendConnection，实际 NIO 借用登记因此被全局 Task 启动延迟挡住。既有 SQL callback 已在实际数据库 TaskExecutor，post-commit / 慢诊断已在全局执行器，无需再次把整条 root 偏好设成数据库 EventLoop。

新增 v2StartOwnerBatchConnection / v2StartRoomPhysicalConnection，同步创建既有 deadline watchdog、acquisitionCancellation、实际借用 Future 与物理 callback；返回单一拥有者 V2StartedRoomConnection，finish 保留原 cancellation handler、等待 Future 真正结束、state.settleClose、归因与 deferred metrics。原 async 物理 / scheduled 借用 API 包装同一实现，其他事务路径不改变 SQL 或截止策略。finish 以短 Mutex 原子声明一次结算，防止重复等待者取消已经复用的连接。

生产 Batcher 把 startScheduledConnection 传给池调度器。在已注册 lifecycle root 后，effects 在锁外直接发起借用，实际 SQL callback 仍使用原 physical executor；全局 root 始终跟踪拥有此 Future，等待其结束后做 post-commit / trace diagnosis / room ACK 结算。提交结果在 callback 结束前放入原 completed 状态，物理清理失败后仍能保持已确认业务结果。房间排序、预算、单房间占用直至 finalization、实际 pool 返回即释放 SQL slot 都保留。

新增同步入口 marker ticket_entry_started 和 owner_ticket_registration_wait。owner_ticket_task_wait 仍测全局 settlement root 实际启动，但此等待现在可以与 SQL 重叠，不再表示开始借用前的等待；旧 / 未配置 start 的测试入口保留原定义。resourceWindow 优先用真实 entry marker 分类注册前等待，其次兼容旧 Task marker。不能拿新全局 Task 启动值继续加到连接前路径。

处理 NIO 同步完成的失败边界：若实际 Future 在 start 返回前失败，尚未选择房间的 callback 不立即释放调度位置，否则可能在当前堆栈重复登记同一 ready 房间。由拥有者先报告 unbound failure，再释放该位置；实际连接已归还不受此逻辑保留影响。正常已选房间仍在物理 pool 返回时立即释放，post-commit 不占连接。

18 项 / 3 suites 的 timeline、resource wait、pool borrower 单元回归通过。独立 PG16 实例新增 caller TaskLocal 登记上下文 / SQL selected EventLoop / global finalization 检查、inline unbound failure 不递归重提、连接在 waiter 未开始前归还并复用且 late waiter cancellation 不关闭其他 loan、无 waiter 期间 absolute deadline 仍关闭真实长 SQL。连同 prepared cache、原 owner 生命周期、公平排序、取消、独立房间、成功 / rejected 重试与 commit unknown 回归，33 项 / 3 suites 通过（45.144 秒），独立数据库已关闭。diff 检查通过，Release 构建中。

下一轮固定相同 binary / 连接数 / 10 Hz 负载，先 R111 2000 对照 R110，再 R112 2500 对照 R106。暂无性能结果，不宣称吞吐提升。


R111 Release 成功（242.89 秒）。原 2000 / 60.004 秒、12/12 分片、119,988 全 ACK，workload failures 0、SERVER_BUSY 0、quality / coverage / 前台追平均通过，实际 DB message / completion 均 119,988、缺失 / mismatch 0、核对库已关闭、service cleanup settled=true / forcedKill=0 / exitFailure=0。全量阶段均值：roomQueue 12.020 ms（R110 17.364）、ready 11.215 ms（R110 26.645）、connectionAcquire 0.332 ms（0.790）、BEGIN 1.451 ms（1.453）、body 2.220 ms（1.995）、COMMIT 1.397 ms（1.121）。登记 entry 0.007 ms，全局 root Task 启动仍 2.141 ms，可与 SQL 重叠。12 分片 P50 / P95 / P99 算术平均 46.000 / 178.167 / 417.583 ms（原 51.333 / 281.000 / 455.083），CPU idle 15.037%（13.599%）。单次 before/after，有统计波动；本轮写调度 -57.9%、房间队列 -30.8%、分片 P95 均值 -36.6%，不能称所有事务阶段都优化。

同一 binary 继续 R112 原 2500 场景：60.007 秒，12/12 分片，149,988 发送 / ACK，workload失败 / overflow / abandon 0，70 次临时 SERVER_BUSY 均重试成功。qualityPassed / coverageProofPassed 均 true，10,000 前台检查 behind 0。实际 owned DB message / completion 均 149,988、operation_metadata_missing / mismatched 0，核对后已停。服务 cleanup settled=true、forcedKill=0、exitFailure=0。

R112 均值：roomQueue 32.697 ms、ready 47.338 ms、connectionAcquire 0.365 ms、BEGIN 1.960 ms、body 3.243 ms、COMMIT 1.979 ms，登记 entry 0.012 ms，全局结算 Task 启动 4.365 ms。R106 原2500对应 roomQueue 189.799 / ready 356.536 / acquire 1.589 / BEGIN 2.562 / body 3.114 / COMMIT 1.846。ready 本次约 -86.7%、roomQueue -82.8%，该阶段改善大于小幅波动；仍仅一个 matched 场景的 before/after。12 分片 P50/P95/P99 算术平均 96.083 / 470.833 / 734.583 ms，max 平均 1653.627 ms，CPU idle 4.036%。renewalAccepted 169,045，本地 renewalAuthorityExpired / progressAuthorityExpired / progressAuthorityNotReady 0，socketResponseBusy 19,878。

本轮 live payload 20,234 / durable历史恢复记录 229,698，实时消费仍大量依赖恢复；全部前台追平并不证明每条事件都通过 live payload 完成。SQL正文、commit和实时投递计算仍是后续容量 / 长尾热点。保留此次同步登记实际借用的改造，下一轮 R113 同 binary 原 3000 / 同连接预算，无放宽重试或质量门槛。

完整质量验证档位现为 10,000 在线 / 2500 msg/s，较此前已验证 2000 档提升25%；不把未测档位当成精确极限。5000 仍未完成。


R113 同 binary / 4 写连接 / 原 3000：约50.006 秒共有采样窗口后 loader 重试耗尽触发取消，仅1/12报告。该分片16条TCP_DEFERRED_RETRY_EXHAUSTED，随后因全局取消90条 connection-closed / outcome-unknown；不把缺失分片的部分汇总当全局吞吐。数据库 actual message / completion 均152,775、metadataMissing / mismatch 0，已核对关闭。采样均值 roomQueue195.892 / ready344.364 / acquire0.531 / BEGIN2.850 / body4.435 / COMMIT2.823 ms，同步登记0.014 ms，全局结算Root启动7.917 ms，CPU idle0.605%。原场景3000仍未通过。

下一轮R114纯诊断：同10,000在线 / 同binary / 同4写连接，先2000持续60秒，再3000持续60秒；测量phase明确选后者。目的区分首次scope事实加载 / 首次数据库缓存积压与持续的系统计算瓶颈，不替代原场景完整容量标准，不扩大连接或延长租期。当前正式验证档位仍2500。


R114 预热诊断，3000窗口完整60.006秒采样但最终loader重试耗尽，仅3/12报告，不是通过结果。已回报分片前一2000阶段全部ACK / failure0，后一3000阶段3条TCP_DEFERRED_RETRY_EXHAUSTED。数据库包含两阶段：messages / completion均299,974、operation_metadata_missing / mismatched0，ownedPG核对后关闭。后一阶段facts冷读3197次（R113原3000窗口同计数需单独取数），scope冷读并未因预热完全消失，不能把预热解释为全部permission命中。采样roomQueue156.961 / ready291.323 / acquire0.475 / BEGIN2.691 / body4.272 / COMMIT2.661ms，registration0.015ms，全局settlementTask启动6.759ms，CPU idle1.160%。冷成本减少后原有持续负载问题仍存在，不能只把权限读取提前就声明解决3000。

补按诊断ready_*的每条时长加总（非全量 / CPU）：R1122500，1279个有诊断的样本，full-driver-borrowed83.49%、task-pending0.18%、assignment-pending5.65%、return-pending3.54%、slot-available5.25%；R1133000，2304个样本，full-borrowed70.04%、task-pending0.16%、assignment-pending8.90%、return-pending6.85%、slot-available12.41%。相比R106 task-pending28.01%，入口阻塞已实际消除；剩余大部分区间所有写driver都占用。state category仍不能解释SQL内部等待 / CPU热栈。

下一轮R115采用同R111 binary、同原3000无额外消息预热，仅每节点写连接4→6（2个message EventLoop，每loop2→3），其他读 / 控制 / 后台预算不变。此时总写连接24→36，单节点拓扑预算19→21，6节点114→126（不含Account），仍在原PGmax320 / process100限制内。之前8连接试验发生在同步登记、prepared cache、trace采样与JSON / replay摘要优化之前，不能直接替代此新结构的测量。原4参数作为baseline，6为测量候选；若只增加CPU / SQL耗时而质量无收益，不保留。


## R115：原3000场景，6条写连接完整通过

同R111 Release、10,000在线、原10Hz突发场景，只将每节点消息写连接4→6。60.010秒，12/12报告，180,000条发送与ACK，workload失败 / overflow / abandon为0。1900次临时SERVER_BUSY均重试成功，实际ACK阶段速率2984.238/s（阶段与drain边界影响，不将其取整为实测速率3000）。qualityPassed / coverageProofPassed为true，10,000前台检查无缺失、落后或超前。实际数据库messages / completion均180,000，metadataMissing / mismatch为0，核对实例已关闭。

全量阶段均值：roomQueue114.182ms、ready190.362ms、acquire0.614ms、BEGIN3.519ms、body5.919ms、COMMIT3.805ms，同步登记0.020ms。12分片P50/P95/P99算术平均427.917/1024.000/1570.750ms，不是总体分位数。CPU idle仅0.356%。live payload16,472、历史恢复记录286,335，追平质量通过但实时投递仍大量依赖恢复。

此前4连接原3000仅部分执行后失败，因此不拿两轮时长不同的结果宣称严格延迟百分比。6连接解决本档发送失败，正文与COMMIT相较部分窗口仍更慢，机器接近CPU上限，不能继续线性推断加连接收益。保留6作为后续测量候选，仓库默认配置不据此修改。完整质量验证档位从2000推进至3000（+50%），5000目标未完成。下一轮同3000/6单独验证已存在的可选binary invocation开关，检查编码成本与排队是否改善；不取消签名、房间排序或持久化确认。


## R116：3000 / 6连接，binary invocation单变量对照

只将已有binary invocation开关disabled→enabled，其余R115场景 / Release完全相同。60.003秒 / 12分片，180,000发送与ACK、workload失败0，1131次SERVER_BUSY均成功重试；quality / coverage / 10,000前台追平均通过。实际owned数据库message / completion各180,000、missing / mismatch为0，核对后关闭；cleanup settled=true / forcedKill=0 / exitFailure=0。实际ACK阶段速率2990.173/s。

全量均值ready134.129ms（原190.362）、acquire0.636ms、BEGIN3.204ms（3.519）、body5.483ms（5.919）、COMMIT3.394ms（3.805）。12分片P50 / P95 / P99算术平均325.000 / 882.000 / 1339.083ms（原427.917 / 1024.000 / 1570.750）；仍非总体分位数。单轮对照中ready约-29.5%、分片P95均值约-13.9%，未据此启用生产默认。live payload11,935、历史恢复290,758，投递质量仍依赖恢复。下一轮沿用6写连接 / binary enabled，原场景只把目标速率提升4000，完整质量门槛不变。


## R117：4000失败；R118单独调用栈诊断

R117保持R116 binary enabled / 6写连接，仅原场景速率3000→4000。仅10.010秒共有采样后loader重试耗尽触发全局取消，9/12报告，不是通过。部分报告含connectionClosed，不能把取消导致的未知结果当作服务端已证明回滚。owned数据库messages / completion各37,757，missing / mismatch0，核对后关闭。采样均值roomQueue430.327 / ready587.204 / acquire1.041 / BEGIN4.688 / body7.462 / COMMIT4.788ms，CPU idle0.191%。

R116进程计数：六actor_host平均合计9.524核、12loader0.329核、account0.009核；整机user84.698% / system14.562% / idle0.739%。不把客户端CPU当主要瓶颈。

R118回到R116的3000 / 6 / binary enabled，专门在稳定运行30秒后对一个server做6秒 / 2ms sample。sample退出0，造成测量干扰后loader失败；不作为容量对照。ownedDB152,654条messages / completion、missing / mismatch0、核对后关闭。sample记录 /tmp/imv2-r118-server-sample.txt，metadata标记diagnosticOnly=true。祖先去重的入口采样计数（含嵌套，不能相加或解释为CPU占比）：sign927、verify1057、JSON encode1070、JSON decode814、deliveryBatch.validate173、replay fingerprint10、wait diagnosis8。JSON encode主要父节点SigningIdentity.sign450、DeliveryBatch.validate165、LanePump.admit102；JSON decode主要TrustStore.verify659、DecodedRoomInvocation.init107。

代码证据：Endpoint.dispatch已经拥有认证后的V2RoomRequest，但普通invoke和每个subscriptionRenewBatch子项仍JSONEncoder→host.invoke(encodedRequest)→DecodedRoomInvocation JSONDecoder。R101只消除了Host与Lane之间的二次解码，未消除此typed→bytes→typed往返。下一项R119只消除Host这次重解码，保留实际JSON字节预算，不修改签名或RPC线格式。Host新增request入口，内部encoding构造不可伪造byte/value对，再共用纯读 / 纯续期 / ordinary lane分派。原raw入口保持。91项相关测试通过，补typed纯续期取消 / budget / authority回归后重新检查与Release构建。


R119最终Host回归32项通过（含typed纯renew的预算 / 取消 / 权限失效），Release192.08秒。3000 / 6 / binary enabled对照60.004秒，12/12报告、180,000全ACK、workload失败0、1395次Busy重试成功、quality / coverage / foreground均通过；ownedDB各180,000、missing / mismatch0，核对库已关闭，cleanup全部正常。roomQueue91.649 / ready149.748 / acquire0.604 / BEGIN3.292 / body5.726 / COMMIT3.410ms，分片P50 / P95 / P99均值356.417 / 892.667 / 1425.333ms，CPU idle0.848%。相比R116没有可测性能收益，ready反而+11.6%，不宣称小幅CPU idle波动为优势。已将R119四个源 / 测试文件精确恢复至实验前备份，保留R101 / R106 / R111先前改造。未改变签名或配置默认。

下一候选的事实边界：普通当前权限私聊使用单条CTE写room cursor、message、event（需要时）及completion，严格INSERT约束报错会回滚整条语句；房间级批次独立。对不需要额外策略 / 投影SQL的路径，存在用implicit单语句事务减少BEGIN / COMMIT交互的空间。但本地postgres-nio ExtendedQueryStateMachine在CommandComplete时结束row stream，ConnectionStateMachine在ReadyForQuery后才转idle并更新transactionState。不能仅await现有query Future就把implicit提交当成功。必须先增加与实际ReadyForQuery关联的驱动确认边界，并验证迟到提交错误、取消、连接断开、未结束显式事务不误认为成功。然后才评估业务单语句快路径；复杂payload、多SQL策略效果、旧路径及恢复仍保留显式事务。此候选尚未实现，不计性能收益。


## R120：先建立真实ReadyForQuery确认边界（尚未启用业务快路径）

本地postgres-nio新增confirmReadyForQuery：HandlerTask / PSQLTask登记确认请求，ConnectionStateMachine在既有命令收到ReadyForQuery、更新后端事务状态之后才结算，并继续既有队列；不发送SQL / Sync / 额外网络报文。返回idle / inTransaction / inFailedTransaction，不能单独把idle解释为前一失败语句成功，调用方仍须保留原query结果。连接关闭 / quiescing / 写登记失败均结算确认Promise。新ConnectionAction以有序next动作保留后续查询，不停住队列。

真实PG16回归发现并修复closed-channel登记失败时Promise泄漏；Handler明确接管登记后总是确认write成功，未接管的write失败由API结算Promise。6项真实PG回归全部通过（0.542秒）：排队查询 / 连续确认顺序、显式事务T / failed事务E状态、延迟constraint commit完成后确认、已返回INSERT行后迟到commit错误必须失败、pending / 已关闭连接的新确认不泄漏，及原prepared cache / failure回滚恢复。独立数据库cleanup=0、已关闭。

延迟constraint trigger会让PG缓冲CommandComplete与ReadyForQuery同包发送，因此不把query future与ReadyFuture之间固定100ms差值当协议必要保证；移除这一错误的时序假设，保留总提交耗时与迟到commit失败的真实断言。原服务端发送仍采用BEGIN / body / COMMIT，新的确认API暂未接入生产写路径，不能计入吞吐收益。Release目前为R119实验构建，R119源码已撤销，下一次压测前必须为最终候选重建Release。下一步只对完整内存准备、同房间、单CTE且无额外策略 / 投影SQL的普通当前权限私聊接入隐式原子提交，其余路径保持显式事务，并验证成功 / replay / stale cursor / commit unknown / cancel / late server error后再压测。5000仍未达到，当前完整验证档位3000。


## R121：同房间单条原子写入候选（验证中，未计吞吐收益）

将DirectOwnerBatchPath的内存规约与SQL写入分开，由显式与隐式路径共用。仅当前权限、同一房间、有效runtime cursor、已建立方向投影、无reply marker / policy hint / stranger quota额外SQL的普通消息批次启用；严格INSERT仍把cursor、message、completion及需要的event放在同一条CTE。CPU结果和ACK身份先构造，数据库ReadyForQuery确认idle且语句成功之后才发布提交结果；连接先归还、房间仍占用，再推进内存与ACK。

隐式路径保持原owned deadline watchdog、取消关闭与close join。收到服务端SQLSTATE且确认idle才可证明语句失败；零cursor / message / completion变更才允许stale状态恢复。收到行之后本地解码失败、确认失败、断连或超时仍是commit unknown，不能隐藏重试。复杂、冷或额外策略 / 投影写路径保持BEGIN / body / COMMIT。新增owner_single_statement计数确认真实命中，不用owner_setup均值缺失推测。

39项调度 / 借用单元回归通过；39项5组真实PG回归通过，含单语句success / constraint / late commit error / local validation / deadline / cancellation六种场景，以及原prepared、独立事务、提交未知和权限更新回归。独立PG均关闭。补充生产房间当前权限好友热发送、原operation重放和权限变更验证中；首次计数断言错误地要求单向陌生人房间命中，已按好友资格修正。补测又发现测试schema.sql SET timeout=0覆盖连接startup默认，夹具在该组真实默认值验证中跳过这三条导入设置，其他测试保持原行为。Release未重建，性能尚未验证。

R121生产热房间补测最终8组通过（7.191秒，owned PG cleanup=0）：其中解除好友场景在策略事务未提交时的好友热发送，owner_single_statement计数严格为1；同一operation再次提交结果成功且计数不增；策略提交后拒绝、恢复好友后接受，其他房间继续运行。剩余单向陌生人场景保持复杂显式路径。测试schema在真实默认值组跳过SET timeout=0，连接实际默认值检查通过。Release构建中，尚无新性能结果。


## R121性能验证：3000完整通过，保留单语句改造

Release构建213.01秒通过。6节点 / 每节点6写连接 / 2消息DB EventLoop / binary enabled / 原10Hz personas场景，与R116一致。60.009秒、12/12报告、180000发送及ACK、workload failure / overflow / abandon=0，359次Busy成功重试，ACK阶段实测速率2999.469/s；quality / coverage / 10000前台追平均通过。owned DB message / completion各180000，metadata missing / mismatch=0；cleanup settled、forced kill / failure=0，核对后关闭PG。

全量阶段：roomQueue19.047ms（R11684.063，单轮-77.34%），ready14.352ms（134.129，-89.30%），acquire0.744ms（0.636，略升）。window内ownerBody / ownerSingleStatement均157966轮，无ownerSetup样本，证明优化实际命中。单语句整周期4.477ms，body4.464ms，Ready确认额外0.005ms。**0.005ms不是WAL提交成本消失**：隐式提交成本已在语句周期内，不能与旧COMMIT3.394ms作独立成本百分比。也不相加阶段均值当客户端延迟。分片P50 / P95 / P99算术均值95.417 / 547 / 1002.417ms（R116325 / 882 / 1339.083），非总体分位数；P95均值单轮-37.98%。live payload17397、历史恢复282959，追平仍依赖大量历史恢复。

## R122—R124：更高档位仍未通过，不计容量达标

R122仅速率3000→4000，6写连接：共20.008秒窗口、12报告但发送未完成，workload failure4074、overflow427、abandon181；重试 / 排队失败后全局取消。实际DB77391条message / completion、metadata一致，取消后的未知操作不能视为已证明回滚。ready280.010 / roomQueue206.619 / acquire1.223 / 单语句9.128ms，CPU idle0.0068%。quality / foreground追平未通过。

R123原3500 / 6连接：发送阶段跑满60秒，但仅1/12最终报告（其余因门槛失败取消）；完成报告分片4 sent / 最终ACK17497，workloadFailed0，但2次队列overflow使稳态失败。不能以最终drain完成取代零overflow标准。阶段计时只来自已有分片窗口，missingShardPhaseCount11，不作完整跨轮统计证明：room45.140 / ready56.026 / acquire约原窗口 / 单语句6.502ms。owned DB209986 message / completion、missing / mismatch0（原分片小数速率取整后计划209988，2条因overflow未提交；不能把相对210000的14条差值都算丢失）。

R124仅6→8写连接（2Loop，每loop3→4），同3500原场景：仍仅1/12报告，分片7同样sent / 最终ACK17497、workloadFailed0、2次overflow，未通过。已有窗口room34.423 / ready35.369 / acquire1.152 / 单语句6.941ms，连接增大降低排队但正文变慢。DB同209986、missing / mismatch0。两个3500结果都不算通过，生产默认不改为8，也不宣称容量从3000升至3500。R122 / R123 / R124均关闭服务和核对PG。

慢样本ready等待分类（不是全量 / CPU归因）：R1221101样本中fully-driver-borrowed49.78%、return-pending15.17%、assignment-pending16.46%、slot-available15.29%、task-pending0.30%。R121627样本相应61.12 / 7.02 / 17.76 / 8.53 / 0.32%。没有恢复此前Task未启动的大面积资源占用问题；高档位SQL周期和调度队列共同放大，不能从slot-available推出实际连接空闲。

进一步核对冷策略代码：当前PostgresV2PolicyFactsSnapshotReader已经使用单条MVCC SELECT，无BEGIN / 行锁 / ownership声明。policyOwnerStateTransaction指标名仍用于旧兼容阶段，**不能据此认为当前冷读取还有显式事务**。R122 policySnapshotSQLFuture99.945ms、SQLResume6.506ms、读准入0.0007ms。future阶段包含底层借连接、数据库、EventLoop及Future结算，不是数据库执行时间的精确测量。下一项应拆控制读连接池实际借用与SQL/EL时间，结合高负载CPU调用栈；不再建议删除已不存在的冷读BEGIN，也不把共享room state actor约0.364ms均值当成已证实主要瓶颈。5000目标仍未实现，当前完整验证3000；保留R120/R121安全单语句收益，继续定位。


## R125—R126：权限冷加载实际资源等待与独立预算

R125 在实际物理连接借用处新增固定来源 `policy_snapshot`，同步构造原查询 Future 时传递 TaskLocal，不新增任务、SQL 或日志。物理 gate、驱动借用、SQL 和归还均可关联来源。相关物理池回归10项通过，Release208.70秒。

原3500 / 6写连接 / 4权限控制连接，发送阶段60.006秒，但仅1/12报告：分片2 sent / 最终ACK17497、2次overflow，完整验收失败。owned DB209986消息 / 同量completion，元数据缺失 / mismatch0，服务与核对PG关闭。冷权限来源19710次SQL，准入均值60.017ms、进入驱动等待2.629ms、SQL阶段5.400ms、实际持有8.041ms；Future均值68.769ms、恢复Swift任务6.007ms。SQL阶段包含驱动、网络与数据库处理，不等于纯数据库执行。原439ms个例不能代表所有请求。窗口room50.672 / ready62.990 / 单语句周期6.606ms。

R126 新增可选 `IM_V2_DATABASE_POLICY_CONTROL_CONNECTIONS_PER_EVENT_LOOP`，独立设置既有权限控制池容量；未设置时维持原推导默认，实际物理gate与Fluent池容量保持一致，仍计入进程总连接预算。压测器新增 `--candidate-policy-control-connections`（默认4），记录candidatePolicyControlConnectionsPerNode。配置回归38项、压测器Python回归10项通过，Release195.28秒。

仅权限控制连接4→8，同3500 / 6写连接：60.004秒、仅1/12报告、2次overflow，仍未通过。cold gate19.063ms、驱动等待3.733ms、SQL6.282ms、Future29.726ms、任务恢复6.028ms；room51.227 / ready67.215 / 单语句6.564ms。减少冷加载准入排队，但未改善整体质量，SQL反而略慢。DB209986 / 209986、缺失 / mismatch0，服务与核对PG关闭。8连接仅实验参数，未改生产默认，不能宣称3500容量达标。

进一步查读代码：普通账号的私聊已确认接收方回复后，业务决策不依赖陌生人设置；当前准备却仍串行加载该scope。下一轮只裁剪这项无关依赖，保留账号 / 拉黑 / 好友当前内存事实、activation边界和写入检查，不用增加连接代替代码优化。


## R127—R128：已回复普通会话裁剪无关权限依赖

绑定当前activation的统一初始化已恢复direct双方reply事实。权限Registry仅传递已确认的接收方positive reply；未知 / negative仍完整读取，special账号仍完整读取，兼容创建路径默认false。当前snapshot仅普通账号且positive reply时接受三份账号 / 关系事实，省略stranger scope；不制造允许陌生人值（保持false），当前拉黑 / 封禁判断不变。该优化保守地不追踪activation之后新增reply，下一次activation才利用新持久化positive事实。

新增真实数据库测试通过：两方向实际消息建立reply，随后设置拒绝陌生人；生产Host发送仍合法且stranger缓存为空；预热后隐藏stranger表仍可发送；恢复表并执行真实block后即拒绝，无拒绝消息落库。unknown / special缺少setting拒绝的单元用例、已有8种warm策略更新、初始化过期activation和Registry生命周期回归通过，共8项测试 / 3套件（含参数化用例），9.376秒。Release208.42秒，diff检查通过。

R127 original3500 / 6写 / 4控制，仅两份最终报告、missing10，仍失败：分片1 overflow3、分片11 overflow4，两份最终sent / ACK分别17496 / 17495，workloadFailed0；不能将两份报告当全量客户端证明。owned DB209981 / 209981、缺失 / mismatch0，服务退出settled且forcedKill0（loader失败 / 被取消导致exitFailure12），PG核对后关闭。窗口指标仅诊断：冷SQL19710→10961（约-44.39%），coldgate60.017→12.905ms，Future68.769→21.474ms，permission prepare15.658→4.554ms；room50.672→41.690ms，ready62.990→60.588ms，acquire0.874ms，single6.407ms。依赖减少实际生效，但3500容量未通过，不宣称成功吞吐增长。

R128使用同一R127 Release，回归original3000 / 6写 / 4控制。完整60.005秒、12/12报告；180000 sent / ACK、失败 / overflow / abandon0，229次Busy全部重试成功；quality / coverage / foreground通过，10000前台视图0missing / behind / ahead。实际确认2999.610msg/s。owned DB180000 / 180000、缺失 / mismatch0，服务关闭、核对PG关闭。

同配置完整3000对比R121：permission prepare9.685→3.190ms，room19.047→13.033ms（-31.58%），ready14.352→11.468ms（-20.10%），acquire0.744→0.688ms，单语句4.477→4.136ms。阶段均值来自监控计数窗口，不能相加作为客户端延迟；单轮比较不视为精确长期增益。保留依赖裁剪，独立控制预算维持默认4。**目前最高完整验收仍是3000，5000目标未完成。** 下一步继续围绕写资源调度 / 实际持有 / CPU编码认证成本定位，而非继续增加权限连接。


## R129：投递Relay合并读取未证明端到端收益，已撤回

代码发现投递lane的共享admit逐房间先await Relay.status，再await Relay.pending；已实验一次返回同fence状态与最多64条指定lane数据的快照，保留当前ACK精确fence检查、绑定generation及控制lane隔离。参考[SE-0306 Actors](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0306-actors.md)：跨Actor消息可能挂起，两个await之间可插入其他任务；合并读取降低边界数但不自动保证吞吐。

20项 / 2套件回归通过（0.027秒），包括快慢peer隔离、持有消息不挡撤销、退休join、旧fence拒绝、新增bounded coherent snapshot。Release191.18秒。原3500 / 6写 / 4控制、60.004秒，但仅2/12报告，分片5 overflow4、分片3 overflow1；sent / 最终ACK分别17495 / 17498、workloadFailed0，质量仍失败。ownedDB209980 / 209980、缺失 / mismatch0，PG核对后停止；服务settled=true、forcedKill0，loader失败 / 全局取消导致exitFailure12。窗口room45.324 / ready65.214 / acquire0.886 / single6.283 / permissionprepare5.803ms；对比R127 room41.690 / ready60.588，没有可测整体优势，不宣称个别阶段波动为容量收益。

已将两份生产文件与新增测试精确恢复至R129前备份（逐字节一致），保留R127依赖裁剪与其他有效优化。恢复后的Release构建通过（172.06秒）；源码 / 可执行文件已一致，尚未新增签名包codec生产改动。未复活R109大小缓存（此前无端到端收益）。

## R130准备证据：签名包包装层微基准，仅用于选择后续实验

当前Framework InvocationMessage外层支持二进制，但ClusterInvocationEncoder.recordArgument仍调用serialization.serialize(argument.value)。V2ActorSignedPacket三个字段的通用JSON编码再次对body / signature做Base64；接收参数也走通用JSON解码。可考虑在二进制Invocation下让明确opt-in的签名包参数传递原始body / signature字节；签名仍覆盖原body，Trust仍先验签再业务解码，默认出站JSON保持原样、接收支持两种编码。通用Distributed目标仍从声明的参数类型解码，不由远端选择类型。回复路径当前仍独立序列化，不将请求参数优化误称为整个RPC替换。

无服务运行时使用swiftc -O测试合成同字段Packet，每样本5000次、5样本中位数（不含签名 / 网络 / actor）：body512 / 2048 / 8192 bytes；JSON encode2.917 / 6.786 / 22.758μs、decode2.580 / 6.108 / 19.974μs；简单binary encode0.211 / 0.214 / 0.288μs、decode0.192 / 0.195 / 0.276μs；wire长度840→610 / 2908→2146 / 11181→8290。该微基准仅说明包装层有可消除成本，不是生产实现或吞吐证明；真实Codec需要边界 / 截断 / 错类型 / 双向网络兼容测试与未受干扰的端到端对照，5000目标仍未完成。临时源码与结果位于/tmp/imv2-r130-packet-codec-bench.swift / .json。


## R130—R132：签名参数去除 JSON / Base64 包装，3500 连续两次通过

Framework 增加明确 opt-in 的 ClusterBinaryInvocationArgument，只在 binaryDistributedInvocations 开启时编码。V2ActorSignedPacket 使用有界 IMVP v1 帧传递 signer / 原 body / 原 signature；接收同时支持 JSON 与二进制，按目标声明类型解码。签名仍覆盖原消息体，先验签后解码；默认出站关闭，启用前须升级所有接收方。回复包装与认证消息体仍用 JSON。参数截断 / 长度伪造 / 尾随 / 版本 / 签名篡改、实际 Invocation 编解码、混合设置真实 TCP、原权限认证与外层调用回归共36项通过；Server Release196.78秒、Account Release11.45秒。

R130 original3500 / 6写 / 4控制 / 2消息DB EventLoop：60.010秒、12/12报告、209988 sent / ACK，失败 / overflow / abandon0，1304次Busy成功重试，窗口确认3479.286/s；quality / coverage / foreground通过，10000视图无missing / behind / ahead。owned DB209988消息 / completion、元数据缺失 / mismatch0。room32.922 / ready45.808 / acquire0.822 / single6.043 / permissionprepare4.079ms。验收后Gateway0连接排空超时退出1，其他退出，forcedKill0；属于退出生命周期问题，不能隐藏为完全无异常。

R131仅提升original4000，约20.004秒即失败，10/12报告；已有报告sent66466 / ACK63269、overflow173 / abandon21 / workloadFailed3197，不作全量总数。owned DB78964消息 / completion一致、缺失0；取消后未确认操作不等于回滚。room180.792 / ready290.209 / acquire1.097 / single9.808 / permissionprepare18.821ms，CPU idle约0—0.0134%；服务与复核PG已停止。4000及5000仍未达标，不能用3500成功外推。

R132用相同R130 Release复测original3500：60.005秒、12/12报告、209988 sent / ACK、失败 / overflow / abandon0，2550次Busy成功重试，窗口确认3477.576/s；quality / coverage / foreground通过，10000视图无missing / behind / ahead。owned DB209988 / 209988、缺失 / mismatch0。cleanup settled=true、forcedKill0、exitFailure0，所有服务和复核PG停止。3500两轮完整消息与同步验收通过，第二轮退出正常；R130偶发排空问题仍作为后续生命周期风险记录。保留参数包装优化，目前最高完整验证档位3500（相对此前3000档提升16.7%，不是每条请求延迟提升），5000目标未完成。

R132窗口room45.207 / ready68.037 / acquire0.841 / single6.836ms；与R13032.922 / 45.808 / 0.822 / 6.043相比仍有明显波动，不能将两次3500通过说成低延迟或充足余量。CPU前9段idle0—0.571%，最后一段8.665%，压力包含本机loaders / PG / Account / 六个Gateway。R130 live payload9260 / 历史恢复343610，R13216156 / 338987；当前前台追平仍大量依赖历史恢复，5000验收须继续检查投递完整性。

## R133候选：二进制认证身份字段（尚未压测，不计收益）

新增封闭Call / Reply IMVA v1编码，UUID原16字节，序号 / 协议版本 / duration固定宽度，标识符有界长度；request / response业务payload保持JSON。binary flag仅控制调用发送，Reply仅对应已验证的binary Call选择binary；Hello / Grant保持原JSON。Trust在原签名与大小检查后，按声明的Call / Reply类型读取；错误类型、版本、截断、无效principal / duration、伪造长度、尾随字节均拒绝，接收JSON兼容。默认出站关闭，启用前仍须升级所有接收方。没有增加任务 / 锁 / 数据库操作，没有改Ed25519算法或权限绑定。

38项 / 5套件通过（0.090秒），含两种格式实际TCP、真实验签、Call / Reply全截断、数据slice、UInt64.max序号与duration边界、错误target type、重放、过期、错误host incarnation / caller incarnation / 协议版本、服务principal拒绝、reply attempt绑定。测试初始错误枚举名称与caller mismatch预期已按既有sessionExpired规则修正，两种编码走同一规则，不改生产错误含义。Release重建中，尚无R133性能结论。


## R133最终验收与3500目标收口

Server Release193.42秒、Account Release11.34秒通过，源代码与压测二进制一致。original3500 / 6写 / 4控制 / 2消息DB EventLoop / binary enabled / prepared enabled / sampled tracing：60.008秒、12/12报告、209988 sent / ACK，失败 / overflow / abandon / 排空后残留0，1890次Busy均重试成功；窗口确认3492.012 msg/s，少量ACK在有限排空期返回。分片小数调度使计划数209988，不把相对210000的12条差值视为丢失。quality / coverage / foreground通过，10000视图missing / behind / ahead均0。owned PG复核209988 messages / completions、操作元数据缺失 / mismatch0；核对PG关闭。服务cleanup settled=true、forcedKill0、exitFailure0。

阶段全量窗口均值：room_queue_wait37.317ms、owner_ready_wait54.395ms、owner_connection_acquire0.854ms、owner_single_statement6.366ms。客户端12分片P50范围186—202ms、P95范围757—821ms、P99范围1337—1546ms；这是各分片分位数范围，非总体分位数。CPU idle0.026—1.085%，包含本机负载器 / PostgreSQL / Account / 六节点。仍大量依赖历史恢复（345872 records / 8003 live payload），最终全部追平。不能将已有3500成功说成无排队、无延迟或长期生产容量证明。

与紧邻R132相比排队降低，但R133结果仍处于R130 / R132波动范围；不宣称认证身份二进制封装有精确的单项吞吐收益。保留已通过功能、真实TCP与完整3500验收的实现，不再启动4000对照。新目标3500已完成；此处不宣称旧5000目标通过。

### 保留的实现手段

1. **实际连接调度**：按物理池 / EventLoop可用连接选择ready房间，房间独立顺序、独立提交。同步登记真正的借用Future，再由有生命周期归属的根任务等待结算，消除“先占容量、Task迟迟未运行才借连接”的结构空档。SQL callback使用数据库执行器；结算等待与SQL可以重叠，不将所有业务推到EventLoop。超时、取消关闭与close join继续保留。
2. **缩短连接持有范围**：借用闭包只包含必要数据库周期，提交确认后即归还；内存推进、详细诊断、TCP ACK在归还后执行。同房间仍占用至finalization完成，其他房间可复用归还连接。昂贵等待归因的历史筛选、排序移出数据库EventLoop / 连接占用范围。
3. **普通热消息单语句提交**：先在连接外完成内存规约与必要结果构造，再用一条严格CTE原子写入房间cursor、messages、最小成功completion和需要的room event。仅满足热状态 / 普通direct / 无额外SQL的路径命中；复杂路径仍显式事务。PostgresNIO原生ReadyForQuery为idle才确认隐式提交，不用CommandComplete或返回行冒充提交确认；提交未知仍按稳定operation恢复。
4. **SQL模板准备复用**：仅消息追加模板使用每物理连接最多16个命名prepared statement，键为完整SQL及参数类型，满后回退原未命名查询。减少重复Parse / Describe，不缓存业务授权或消息结果；连接关闭即清理。
5. **冷权限依赖裁剪**：依赖activation初始化恢复的已确认接收方positive reply事实，普通账号已回复方向只取账号 / 关系当前事实，省略不影响该方向合法性的stranger设置scope。账号封禁 / 拉黑 / 好友仍按当前策略；unknown / negative / special账号保持原完整依赖，兼容路径默认保守false。冷事实本身是单条MVCC SELECT，不新增事务或行锁。
6. **减少编码与解码**：取消不必要JSON键排序（接收验签原字节，无需重新编码）；Host已解码对象只在内部传给Lane，避免第二次JSON解码；内部Invocation外层二进制，签名参数直接传body / signature，认证Call / Reply身份字段二进制。业务payload暂保留JSON，客户端消息TCP PB不变。默认出站binary仍关闭，本次验收显式开启；接收兼容JSON，启用需所有接收方升级。
7. **短同步内存操作**：无I/O的宿主命令预算改为Mutex保护数量 / 字节 / 许可，解码、SQL、回调均在锁外，减少跨Actor跳转；投递重放指纹直接按封闭字段增量SHA256，替代JSON→字典→排序→JSON，保留完整fence / sequence / recipient绑定与冲突重放保护。
8. **控制工作隔离**：pure subscription renew检查既有精确fence与连续授权序号，经独立控制入口，不排在普通房间消息队列之后；保持实际过期 / 撤销校验，不延长租期掩盖排队。消息写 / 权限控制等预算隔离沿用，最终6写连接、4权限控制连接，未保留8连接的无收益实验。
9. **诊断成本有界**：稳定操作UUID选择1/64详细trace，全量阶段聚合与业务质量校验保留。非采样慢请求不在拥塞时升级，避免大量等待归因和日志反过来放大拥塞。借用 / SQL / Ready / 归还分段记录，阶段均值不相加当客户端延迟。

未保留负面或无充分端到端收益的实验：R108续租共享读取、R109投递JSON大小缓存、R119 typed Host入口、R129 Relay合并读取；未启用unsafe Swift全局执行器接管。相关代码按实验前备份撤回，最终验证使用的是保留路径。

当前3500档连续三轮消息与同步验收通过（R130 / R132 / R133）；R130一节点退出排空异常已单独记录，后两轮退出正常。相对此前最高完整3000档，验收档位增加16.7%；各优化的百分比仅引用其相同档位的对照，不把它们相加，也不把失败或采样干扰窗口当作容量证明。


## R134：用户要求重新测试3500，最新复测失败及完整性能表


当前824份服务端源码哈希与R133一致，Server / Account / Loader Release SHA256一致；没有修改生产代码或资源配置。6节点、每节点6写 / 4权限控制连接、2消息DB EventLoop、binary enabled、prepared enabled、详细trace 1/64，原3500场景 / 10Hz / 10000在线。启动日志确认全部10000连接warm后开始，因失败仅2份报告，汇总authenticated1668是这两份报告覆盖，不能认为实际只建立1668连接。

约20.006秒触发失败保护。两份报告terminal分别为7/5835与6/5854重试耗尽；随后全局取消，缺10份报告。已有报告sent11626 / ACK10953、workloadFailed673，其中重试耗尽13、连接关闭结果不确定660，overflow24 / abandon16。部分ACK在终止后仍返回，不能把阶段ACK与最终ACK混用。全量吞吐、全量客户端P95 / P99无法计算；结果.json内541.880/s仅是两份报告的部分速率，不代表系统总吞吐。前台检查只覆盖1668视图，653落后，不通过。

owned PG复核messages / completions各70738、metadata missing / mismatch0，核对后PG关闭。全局取消未确认的操作不能视为回滚。服务cleanup settled=true / forcedKill0，Gateway / Account / edge退出0，12个loader失败或被取消，exitFailure12。没有继续调整代码或重复筛选成功轮。

### 客户端耗时（ms，仅2个已报告分片，非总体分位数）


| 项目 | 样本数 | P50范围 | P95范围 | P99范围 | 已报告最大值 |
|---|---:|---:|---:|---:|---:|
| 消息ACK | 10841 | 688—692 | 2162—2230 | 3725—3807 | 11670.28 |
| 心跳 | 1269 | 7—8 | 518—585 | 1164—1386 | 1717 |
| 房间事件拉取 | 3756 | 630—666 | 1944—1958 | 2447—2698 | 3023.66 |
| 同步拉取 | 65 | 110—128 | 354—837 | 857—1443 | 1443.71 |


### 服务端全部阶段（6节点窗口计数差值）


阶段均值相互重叠，不能相加当客户端延迟。R134是不完整失败窗口，R133为完整成功窗口；并列仅用于诊断，不计算精确优化百分比。阶段最大值是进程生命周期高水位，不冒充窗口最大值；阶段未提供全量分位数，不将慢trace样本分位数补成全量。policy_owner_state_transaction是历史兼容指标名，当前冷权限事实是单条MVCC SELECT，没有该指标名字暗示的独立BEGIN。owner_commit在隐式路径是Ready确认额外时间，提交成本包含于单语句周期。owner_ticket_task_wait是全局结算任务启动，可以和SQL重叠。

| 原始阶段 | R134样本数 | R134均值ms | R133均值ms |
|---|---:|---:|---:|
| authorization_control | 0 | —（无样本） | —（无样本） |
| authorization_route | 0 | —（无样本） | —（无样本） |
| owner_admission | 0 | —（无样本） | —（无样本） |
| owner_after_begin_gap | 0 | —（无样本） | —（无样本） |
| owner_after_write_gap | 0 | —（无样本） | —（无样本） |
| owner_before_first_sql | 36191 | 1.895670 | 1.258497 |
| owner_begin_future | 0 | —（无样本） | —（无样本） |
| owner_begin_resume | 0 | —（无样本） | —（无样本） |
| owner_body | 36177 | 9.183870 | 6.349224 |
| owner_borrowed_watchdog_join | 0 | —（无样本） | —（无样本） |
| owner_commit | 36177 | 0.007255 | 0.005345 |
| owner_commit_future | 0 | —（无样本） | —（无样本） |
| owner_commit_future_to_execute_return | 0 | —（无样本） | —（无样本） |
| owner_commit_resume | 0 | —（无样本） | —（无样本） |
| owner_connection_acquire | 36198 | 1.124276 | 0.853868 |
| owner_driver_callback_task_wait | 36198 | 0.144909 | 0.096310 |
| owner_execute_return_to_pool_return | 36157 | 0.040792 | 0.037218 |
| owner_gate_admission | 36157 | 0.012163 | 0.007347 |
| owner_gate_callback_registration | 36157 | 0.013352 | 0.010375 |
| owner_gate_capacity_wait | 36157 | 0.002856 | 0.001196 |
| owner_gate_delivery_wait | 36157 | 0.860702 | 0.660324 |
| owner_gate_grant_to_promise | 36157 | 0.000659 | 0.001499 |
| owner_gate_lock_wait | 36157 | 0.000024 | 0.000027 |
| owner_gate_off_loop_delivery | 3679 | 6.589900 | 3.021870 |
| owner_gate_on_loop_delivery | 32478 | 0.211718 | 0.148950 |
| owner_gate_queued_capacity_wait | 0 | —（无样本） | —（无样本） |
| owner_gate_registered_to_callback | 36157 | 0.847350 | 0.649949 |
| owner_gate_request_preparation | 36157 | 0.000062 | 0.000060 |
| owner_locks | 0 | —（无样本） | —（无样本） |
| owner_message_persistence | 36177 | 9.181505 | 6.347133 |
| owner_physical_to_pool_request | 36199 | 0.015487 | 0.038276 |
| owner_policy | 0 | —（无样本） | —（无样本） |
| owner_pool_assignment_callback_wait | 36198 | 0.006726 | 0.003987 |
| owner_pool_assignment_wait | 36198 | 0.919299 | 0.713143 |
| owner_pool_before_winning_gate | 36157 | 0.031028 | 0.027027 |
| owner_pool_peer_before_gate | 0 | —（无样本） | —（无样本） |
| owner_pool_publish_work | 36157 | 0.010000 | 0.015518 |
| owner_pool_return_to_resource_release | 36157 | 0.280368 | 0.125502 |
| owner_pool_to_driver_wait | 36198 | 0.041372 | 0.029097 |
| owner_preflight | 0 | —（无样本） | —（无样本） |
| owner_projection | 0 | —（无样本） | —（无样本） |
| owner_proof | 0 | —（无样本） | —（无样本） |
| owner_ready_wait | 36198 | 183.153062 | 54.395195 |
| owner_receipt_persistence | 0 | —（无样本） | —（无样本） |
| owner_receipt_read | 0 | —（无样本） | —（无样本） |
| owner_record_outcome | 36175 | 0.003354 | 0.002685 |
| owner_reduction | 36193 | 0.025417 | 0.020038 |
| owner_rollback | 0 | —（无样本） | —（无样本） |
| owner_runtime_state | 49272 | 0.534851 | 0.322054 |
| owner_select_room | 36198 | 0.182304 | 0.122108 |
| owner_setup | 0 | —（无样本） | —（无样本） |
| owner_single_statement | 36177 | 9.203496 | 6.365914 |
| owner_store_to_physical_enter | 36199 | 0.009652 | 0.005848 |
| owner_task_to_pool_request | 0 | —（无样本） | —（无样本） |
| owner_task_to_store_enter | 0 | —（无样本） | —（无样本） |
| owner_ticket_registration_wait | 36199 | 0.021799 | 0.017928 |
| owner_ticket_task_wait | 36199 | 13.344745 | 7.798660 |
| owner_write_future | 36177 | 8.916739 | 6.154962 |
| owner_write_resume | 36177 | 0.261175 | 0.188216 |
| policy_owner_memory_probe | 41422 | 1.226030 | 0.713099 |
| policy_owner_state | 41409 | 16.953346 | 3.821634 |
| policy_owner_state_database_admission | 8558 | 0.000964 | 0.000460 |
| policy_owner_state_facts | 8556 | 44.873238 | 26.383993 |
| policy_owner_state_transaction | 8556 | 44.879732 | 26.403990 |
| policy_snapshot_registration | 0 | —（无样本） | —（无样本） |
| policy_snapshot_sql_future | 8556 | 38.063804 | 21.009480 |
| policy_snapshot_sql_resume | 8556 | 6.762146 | 5.361643 |
| preparation_owner_read | 0 | —（无样本） | —（无样本） |
| receipt_preflight | 0 | —（无样本） | —（无样本） |
| room_queue_wait | 36524 | 121.545829 | 37.317425 |


### 实际数据库来源拆分（ms）


不同阶段样本含义不同，不能相加解释为单请求总延迟。SQL阶段含驱动 / 网络 / 数据库，并非纯数据库执行时间；持有从grant到实际Future结算，不包含grant之前gate排队。

| 来源 | 持有样本数 | gate排队 | 驱动等待 | SQL阶段 | 实际持有 |
|---|---:|---:|---:|---:|---:|
| durable_owner | 36175 | 0.015 | 0.925 | 8.917 | 12.582 |
| policy_snapshot | 8556 | 29.176 | 2.771 | 5.753 | 8.535 |
| room_send_initialization | 157 | 120.803 | 1.127 | 7.919 | 18.522 |


### 资源与数据库


CPU仅两个完全落于阶段内的区间，idle0.0246% / 0.0405%；主机14逻辑CPU。角色CPU来自独立进程CPU秒差，和系统CPU口径不同。RSS是各进程采样峰值之和，非同时峰值；PostgreSQL共享页重复计数，省略其RSS，不能相加当物理内存。

| 角色 | 观察进程数 | 平均占用核数 | 各进程峰值RSS之和MiB |
|---|---:|---:|---:|
| loader | 12 | 0.378 | 793.3 |
| account | 1 | 0.010 | 35.3 |
| edge | 6 | 0.001 | 72.5 |
| actor_host | 6 | 8.979 | 6004.9 |
| postgres | 137 | 2.052 | —（共享页） |


数据库窗口commit59492 / rollback0 / deadlock0，WAL103211836字节（约98.43MiB），buffer hit5753653 / read242（hit99.9958%，不是CPU或磁盘瓶颈排除证据）。锁等待快照最多8个blocked、最大观察fan-in6，有14条matching transaction ID观察；属于稀疏快照，非独立等待次数，也不能据此认为所有房间在同一把业务锁上串行。房间初始化等待与当前CPU饱和共同恶化；单轮数据尚不能确定相对R133波动的唯一原因。


Gateway EventLoop lag阶段计数13615 / 累计9192ms，均值0.675ms；不是事务专用数据库EventLoop lag，也不能说明全部异步任务没有调度长尾。观察committed批次36084、singleton批次30083，不用不同计数阶段相除作精确batch size。


证据目录：/tmp/imv2-resource-10k3500-20261008-r134；原始分析/tmp/imv2-r134-hotspots.json；汇总/tmp/imv2-r134-performance-table.json；owned核对/tmp/imv2-r134-verify-owned.py。当前结果纠正之前“3500已稳定收口”的推断：已有成功记录，但最新同配置复测未通过。


## R135—R136：用户要求排查后续改动，当前与旧实现对照均失败

证据核对：R133成功与R134失败的824份生产源码、Server / Account / Loader二进制、场景SHA256及资源参数一致，两轮之间没有改动。R130 / R132相比R133，确实尚无Call / Reply身份消息体二进制封装。R135直接复测当前R133 Release；R136临时恢复R133前的四份生产文件并移出新binary body文件，823份服务端源码与R132全部逐字节哈希一致，保留R130签名参数包装与所有其他优化。旧实现Server Release136.55秒、Account11.74秒通过，然后运行相同数据库夹具 / 原3500 / 10Hz / 6节点 / 6写 / 4控制 / 2消息DB Loop。不是关闭外层binary invocation来混合撤回多个优化。

| 轮次 | 实现 | 窗口秒 | 最终报告 | 已报告overflow | 房间等待ms | 写调度ms | 实际借用ms | 单语句周期ms |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| R133 | 当前 | 60.008 | 12/12，通过 | 0 | 37.317 | 54.395 | 0.854 | 6.366 |
| R134 | 当前 | 20.006 | 2/12，失败 | 24 | 121.546 | 183.153 | 1.124 | 9.203 |
| R135 | 当前复测 | 20.009 | 1/12，失败 | 30 | 97.875 | 158.367 | 1.107 | 8.210 |
| R136 | R132旧实现对照 | 20.005 | 1/12，失败 | 37 | 115.394 | 183.375 | 1.146 | 9.843 |

失败窗口不是完整容量测量，overflow只有已报告分片覆盖，不是全系统总数；上述均值不作精确因果百分比。R135唯一报告terminal为8/5832重试耗尽；全局取消后298结果不确定，最终workloadFailed306。R136唯一报告terminal为7/5808；取消后275结果不确定，workloadFailed282。两轮其他loaders被取消，不能用1份报告推算全量ACK率。

R135 CPU idle0—0.0466%，R136三个CPU区间idle均0。数据库owned核对R135 messages / completions各70990，R136各71164；两轮metadata missing / mismatch均0。复核PG关闭，服务cleanup settled=true / forcedKill0，Account / edge / Gateway全部exit0，loaders失败或被取消。commit unknown仍不能视为rollback。

结论：移除R133的新认证消息体封装并未恢复3500成功，不能将失败简单归因于这项后续改动。也不能凭一轮旧实现失败证明新改动绝对没有性能影响。共同热路径 / 临界CPU容量 / 运行条件是后续应定位的范围，暂未测得唯一成因。源码已经从完整备份恢复，824份源码与R133生产证据哈希一致；没有留下一次未授权的永久回退。


R136对照收尾：恢复当前Server Release143.75秒、Account Release构建通过，源码哈希已核对。服务与验证PG均停止，未保留临时代码回退。


## R137：当前版本3000档跑满60秒，但验收未通过

当前R133源码 / Release，配置沿用6节点 / 6写 / 4权限控制 / 2消息DB EventLoop / binary与prepared enabled / sampled tracing，仅速率3500→3000。10000连接warm后运行完整60.002秒，未出现3500那样约20秒提前失败。但最终只1/12报告，分片10出现overflow1、重试耗尽1；最终sent14999 / ACK14998、workloadFailed1。terminal为scenario phase did not sustain its offered rate，零overflow稳态门槛未通过。不能以排空后基本完成取代稳态验收，也不能把唯一分片ACK当系统总吞吐。前台已报告833视图无missing / behind，但缺其他分片，整体未通过。

owned PG messages / completions各179998，操作元数据缺失 / mismatch0；PG核对后关闭。所有Account / edge / Gateway正常exit0，无drain timeout、forcedKill0，cleanup settled=true；12个loader失败或取消，整体benchmark exit1。这轮说明3000可跑满测量窗口并正常关闭服务，但完整工作负载未正常成功结束。没有修改代码或调整质量门槛。

服务端窗口均值（ms）：room_queue_wait=27.332, owner_ready_wait=34.318, owner_connection_acquire=0.873, owner_single_statement=5.982；阶段均值不能相加当客户端延迟。


## 测量方法纠正：验收通过不等于已确定稳定容量

用户指出此前3500通过、现在3000失败不符合可重复容量结论。代码核对后需区分：R137完整60秒，原计划180000，实际消息 / completion179998（差2），不等于系统连3000总处理量也无法承担；严格零overflow门槛在已有报告overflow1时仍必须判失败。isSteadyStateDrained要求scenarioMessageQueueOverflowed==0，与最终队列已排空并不等价。此前把几次60秒成功概括为3500收口过早；仍保留当时成功的事实，不作为稳定容量证据。

基准控制不足：room warmup仅检查连接、房间打开和tail cursor，未证明全部发送权限scope和SQL模板已warm；R137发送窗口仍有约10601次权限冷事实SQL，R133约10953次。相同源码、fixture和seed证明同模型，不证明完全相同异步执行顺序、实时投递恢复及重试轨迹。核对whenAllComplete按原futures结果收集，未发现“按连接完成顺序随机分配persona”的证据，不把这个猜测当根因。Loader实际maximumInFlightMessagesPerConnection为8，per-device queued上限4；不要混淆服务端TCP发送在途配置与Loader配置。

失败采集缺陷：run_v2_actor_realtime_benchmark.py约2212行任何loader非零立即抛出并取消其他loader，大量最终报告缺失。R137只有1/12，不能算全量ACK率 / 客户端尾延迟或比较负载恢复总量。服务器阶段窗口仍有6节点指标，但采样窗口 / cohort不同，不能直接当精确单项回退百分比。系统条件仅有稀疏CPU / load / VM快照，没有已控制的CPU频率 / 热状态 / 外部进程归因；R133首个loadAverage5min约8.31、R137约28.11，是条件差异信号而不是已证明的失败根因。swap量各轮均815.50MiB，不能无证据归因为新增swap。

下一轮应先保证失败时所有12个loader都生成有界部分报告，保留原质量门槛；固定并记录负载映射 / 计划与实际事件计数；独立冷启动与热发送指标，同环境交替重复3000 / 3500，报告重复通过率、错误计数、排队趋势与完整分位数范围。未做这些控制前，既不宣称稳定3500，也不把R137严苛门槛失败当作容量已经跌到3000以下。此轮只核对方法，未修改生产代码或压测器、未新增压力轮次。


## R138—R143：报告收集修复与交替重复实验

本轮只修改Python压测编排及其测试，生产Swift / Server、Account、Loader Release均保持R133版本。节点数6、写连接6/节点、权限控制4/节点、消息DB EventLoop2、10Hz、10000连接与原质量门槛不变。每轮独立恢复同一夹具，先采样12秒主机基线，再统一等待20秒；原场景按3000→3500→3000→3500交替，两档各60秒。随后两轮加入60秒1000 msg/s发送预热再测目标档位，不与原场景合并计算通过率。没有CPU频率/热状态控制或完整实际事件轨迹回放，因此仍不是确定因果实验。

压测器现在在首次loader失败后最多等待120秒收集其他loader的自然结束报告，保持服务运行；后续失败不延长期限，原工作负载总超时仍生效，服务异常退出仍直接停止。新增`--loader-report-drain-seconds`（1—600），以及`loader-report-collection.json`记录缺失分片与期限状态；任何loader非零仍令整轮失败。32项回归通过。R143真实失败轮保留12份报告、退出码1、collection未超时，验证没有以收集报告为由放宽验收。失败loader退出后剩余负载可能减少，报告齐全也不能使失败轮成为容量证明。

| 轮次 | 模式 | 档位 | 测量期发送 / ACK | 全程最终ACK | 窗口ACK/s | overflow / 最终失败 | 验收 |
|---|---|---:|---:|---:|---:|---:|---|
| R138 | 原场景 | 3000 | 180000 / 179997 | 180000 | 2999.462 | 0 / 0 | 通过 |
| R139 | 原场景 | 3500 | 209988 / 209563 | 209988 | 3492.684 | 0 / 0 | 通过 |
| R140 | 原场景 | 3000 | 180000 / 179993 | 180000 | 2999.654 | 0 / 0 | 通过 |
| R141 | 原场景 | 3500 | 209988 / 209757 | 209988 | 3495.755 | 0 / 0 | 通过 |
| R142 | 发送预热诊断 | 3000 | 180000 / 179261 | 239988 | 2987.358 | 0 / 0 | 通过 |
| R143 | 发送预热诊断 | 3500 | 209969 / 208609 | 269953 | 3476.185 | 19 / 4 | 失败 |

所有轮次12/12报告；全程ACK含测量期后的有界排空，预热轮还含59988条预热消息。测量期ACK不等于最终ACK，原3500受分片取整目标为209988，不能把窗口ACK率写成精确3500。各轮owned PG消息 / completion一致，元数据缺失 / mismatch0；服务cleanup均settled=true、forcedKill0，验证PG均关闭。

| 轮次 | 房间队列均值ms | 写调度均值ms | 实际借连接ms | 单语句周期ms | 冷权限SQL计数 | 客户端各分片P95范围ms | 各分片P99范围ms |
|---|---:|---:|---:|---:|---:|---:|---:|
| R138 | 10.616 | 9.442 | 0.654 | 3.901 | 10608 | 325—352 | 539—639 |
| R139 | 31.255 | 42.230 | 0.826 | 6.013 | 10961 | 615—664 | 1018—1129 |
| R140 | 9.784 | 8.196 | 0.607 | 3.910 | 10608 | 292—327 | 541—605 |
| R141 | 23.865 | 30.846 | 0.729 | 5.275 | 10952 | 638—704 | 1162—1400 |
| R142 | 14.172 | 17.515 | 0.756 | 4.974 | 2519 | 511—638 | 1169—1386 |
| R143 | 34.963 | 55.979 | 0.784 | 5.721 | 2847 | 833—1022 | 1557—1873 |

阶段均值由六节点counter增量加权，只覆盖采样窗口，不可相加当端到端延迟；P95/P99是12个分片各自分位数的最小—最大，不是全局分位数。单语句周期含驱动与调度，不等于纯PostgreSQL执行时间。

R143测量期实际发送209969，最终全程269957发送 / 269953ACK，4条`message:TCP_DEFERRED_RETRY_EXHAUSTED:terminal`分布于分片1 / 3 / 10（1 / 1 / 2）；分片4 / 5 / 7 / 8 / 9因零overflow稳态条件未满足退出非零。19次overflow不是数据库已入库消息丢失，DB最终269953条与ACK一致。全程SERVER_BUSY2832次（含预热），R139 / R141分别1043 / 1170次；BUSY重试压力不等于最终失败数。

本次原场景两档均2/2通过，证明在本批运行条件下可完整通过，不能抹去R134—R137失败，也不能从两个样本宣布稳定容量。发送预热令测量期冷权限SQL从约1万降至2519 / 2847，仍未彻底warm；预热轮排队、尾延迟反而更高，3500失败。预热同时改变缓存、消息存量、后续随机动作轨迹与运行时长，且每档仅一轮、模式未随机交替，不能断言预热本身导致退化，也不能将冷加载作为唯一原因。测试前loadAverage5min从6.25至27.08不等，原场景高load轮仍通过，单一load指标不能证明外部负载根因。

当前最明确的压力差异是写调度与房间等待、客户端尾延迟和BUSY重试放大，实际借连接始终低于1ms；仍未识别历史波动的唯一成因。后续若继续定位，应固定实际动作轨迹、关联溢出连接当时的发送/重试/排空状态，并拆分对应写调度窗口，做同模式多轮交替；本轮没有增加这些生产探针或声称已完成轨迹回放。

证据：`/tmp/imv2-controlled-series-results.json`、`/tmp/imv2-r138-r143-performance.json`；每轮`/tmp/imv2-resource-10k{3000或3500}-20261008-r{138至143}/candidate`，对应`/tmp/imv2-rNN-hotspots.json`、`preflight.json`与`verification.log`。本次6轮全部保留，没有丢弃失败样本。
