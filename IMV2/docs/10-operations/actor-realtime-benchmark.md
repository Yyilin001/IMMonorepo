# Actor 实时路由本地对照压测

`prepare_v2_actor_realtime_direct_fixture.py` 生成一次固定夹具，随后两版共用其凭据和 SQL。正式夹具包含 50,000 个账号、设备和直聊房间。用户 i 与 i+1 成为房间 i 的两名成员，每个用户保留房间 i 和 i−1 两个目标。正式运行使用 `--foreground-paired`：偶数用户的第一目标为房间 i，奇数用户的第一目标为房间 i−1，其余邻居房间作为第二目标。Common Loader 每个连接只有一个前景详情订阅，因此形成 25,000 个双端前景房间；相邻两端跨 Gateway 接收实时消息。其余 25,000 个房间保留为第二目标，不宣称它们同时具有双端实时订阅。成员允许相互发送，避免将陌生人策略变化混入路由对照。

```sh
python3 IMV2/scripts/prepare_v2_actor_realtime_direct_fixture.py \
  --output-dir /tmp/imv2-direct-ring-fixture \
  --seed 4a5a8a27-cb40-5627-a0b9-3bcfb21ebec1 \
  --foreground-paired

python3 IMV2/scripts/run_v2_actor_realtime_benchmark.py \
  --fixture /tmp/imv2-direct-ring-fixture \
  --output-dir /tmp/imv2-direct-ring-comparison \
  --baseline-checkout /path/to/baseline-checkout \
  --baseline-binary /path/to/baseline-release/IMV2ServerApp \
  --candidate-binary /path/to/candidate-release/IMV2ServerApp \
  --loader-binary /path/to/shared-release/IMV2GatewayLoadGenerator \
  --baseline-account-binary /path/to/baseline-release/IMV2AccountServerApp \
  --candidate-account-binary /path/to/candidate-release/IMV2AccountServerApp
```

基线独立 checkout 应使用迁移前版本 a72f25e52a7c7f985625fdc43044b10f7ef12318。两版 Server 和共用 Loader 均须事先使用同一工具链、相同 Release 优化参数编译。脚本记录源码提交和二进制 SHA256，不自动构建。 Loader 路径必须来自实际构建参数对应的 `swift build --show-bin-path`，不能假定 `.build/arm64-apple-macosx/release`：不同 build system 可能输出独立产物。Runner 在创建输出目录或启动数据库前执行 `--describe-message-transport` 并核对 TCP、TCP query 恢复及 20/60 秒和 5 次预算；旧工具或错路径会立即非零退出。原版运行自己的 NATS 子进程，候选版使用 Actor 传输；NATS 二进制路径可通过 `--nats-binary` 指定。

脚本创建独占的 PostgreSQL 集群和带随机名称的新 `imv2_va_actor_*` 数据库，安装对应 checkout 的新建库 schema，并写入夹具 UUID 标记。每个 SQL 文件检查数据库名称和标记，拒绝未标记数据库。数据库、输出目录和夹具默认保留；目录必须不存在。可用 `--drop-disposable-databases` 在退出后清理本次创建的数据库。它不重启或修改既有 PostgreSQL，不清空既有库，也不调整系统配置。

默认运行 6 个 Gateway/RoomHost 和 12 个 Loader；凭据按索引分片，前 8 片各 4,167 条，后 4 片各 4,166 条。分片轮流连接 6 个端口，直聊环的所有边都跨 Gateway。共同建连批次为 32，每片目标建连速率为 200/s；订阅预热按每片 16 用户/s 爬升，避免同时压满读与房间激活队列。预热与正式 rate-5000 测量分开，正式场景速率不变。候选 Gateway 每个物理数据库使用一个事件循环、11 个连接（普通工作9、续租保留2），原角色别名复用物理池；write/read/sync=5/3/3 中前台写/读为保障份额，允许借用空闲前台份额，同步容量独立。必要覆盖授权与普通读取共享原读取额度和384等待预算；单物理资源在该预算内预留4个授权位置，双方有积压时1:1公平授予。默认独立 PostgreSQL 集群提供 320 个连接额度；机器仍需具有足够内存、文件描述符和端口。默认 TLS 端口为 18443–18448，Actor 端口为 18337–18342，metrics 端口为 20464–20469，基线 NATS 为 18422；可通过参数更改。

场景固定为 `high-active-50000-uuid-ab-5000.json`。每片使用 1/12 的场景速率，总目标为 5,000 条消息/秒；checkpoint 阶段和 drain 都保留。每片完成预热后写出自己的 Ready 记录，Driver 核验全部请求连接在线才释放共同启动屏障；正常与失败的阶段报告都记录实际时长及墙钟起止。比较值是各片 rate-5000 阶段实际 acknowledged 消息数除以实际阶段时长的总和，不使用配置速率冒充吞吐。自动验收要求阶段的共同测量窗口至少达到配置时长的 90%；同时核验 Gateway 指标，不能只累加不同时间的连接峰值。

输出包含：夹具和二进制 hash、每片命令、进程 RSS/CPU 采样、Gateway/Loader 日志、原始 JSON 报告、汇总和对照结果。自动接受要求两版完整完成 50,000 连接场景、阶段和 drain，无连接/业务失败及队列溢出/遗弃，候选吞吐至少达到基线 80%。延迟分布、丢失序列及服务端指标仍需结合原始报告审阅。 TCP 质量门槛还要求每片报告真实 transport、协商成功数等于认证数、wire submit 不少于逻辑发送数且 ACCEPTED 数等于 ACK 数。质量失败或正式比例失败均保持非零退出；小规模 canary 仅在功能质量通过时退出零，仍不产生容量接受。`--kind baseline` 或 `candidate` 只运行一版，不产生跨版验收结论。

独占 PostgreSQL 模式还在现有五秒监控周期写出 `postgres-metrics.jsonl`：记录本轮数据库按 state/wait_event_type 聚合的连接数、事务与块读取/命中计数、死锁与临时文件统计，以及集群级 WAL 字节、写入和同步累计计数。监控连接从 activity 聚合中排除；数据库 numbackends 可能包含该连接。数值为累计快照，计算速率时须使用实际时间差并检查 stats_reset。块和 WAL 耗时是否有值取决于 PostgreSQL 原有计时设置，零值不能证明没有 I/O 等待。文件同时记录本轮 postmaster 及其子进程的 PID、父 PID、RSS 和累计 CPU 时间，可用相邻快照估算 CPU 消耗；不记录进程命令、SQL、参数或 token。采样有连接与语句超时，失败保留错误类型或退出码；`--shared-postgres` 不执行此采样，避免采集既有实例。

同一快照还按锁类型、schema/relation 名、mode 和 granted 聚合本轮数据库的 `pg_locks`，并记录最多 128 个锁等待 PID 的等待事件、事务年龄及 blocker PID、状态和事务年龄。SQL 在数据库内按固定表名与语句操作归类，只返回 `room_activation_fence`、`admission_credit`、`message_append`、`route_registration`、`presence`、`transaction_control` 或 `other`，不返回或保存 SQL 正文、参数或 token。blocker 还附带已授予的 tuple 锁及与行锁操作相关的 relation 锁类别、mode 和数量。PostgreSQL 的多数行锁持有信息保存在 tuple header；relation 锁不能证明该事务持有具体哪一行，最后语句类别也不能代表整个事务此前执行的全部操作。事务 ID 锁或 advisory 锁没有 relation 名；锁样本必须结合阻塞链判断，不能凭连接处于 `idle in transaction` 就认定泄漏。

分类修复前的 r10 `query_category` 不可用于归因：原事务控制正则未锚定语句入口，会把 `UPDATE … SET` 错归 `transaction_control`，不能据此声称 COMMIT 或 deferred trigger 是阻塞点。原始 `held_locks`、表名/tuple 锁和时序数据独立于该正则，仍保留有效证据。修复后的采样器先分类受控表，再限定事务控制语句入口；`postgres_statement_category_probe_sql()` 与实际采样器共用同一个 CASE 生成函数，通过真实 PostgreSQL 的固定合成输入自证分类，无业务数据写入。

`pg-hotspot-v2` 将本次 `pg_locks` 读取物化复用，输出等待者的 `requested_locks` 和 blocker 的 `lock_objects`。事务 ID、虚拟事务 ID、relation 名及观测到的 tuple 页/槽号只用于关联同次诊断中的锁对象，不输出业务主键或查询参数。`blockerAnalysis.edges` 区分匹配的事务 ID、匹配的观测 tuple 对象、匹配的虚拟事务与仅有 `pg_blocking_pids` 证据；同时报告去重 blocker 数、最大观测 fan-in、未出现在等待者集合中的 blocker，以及截断和无法解析的 PID。后者不能直接解释为根阻塞者，可能是预备事务、退出的 backend 或截断边界。活动、锁及阻塞函数不能构成原子快照；短暂链环或孤立边不证明死锁，必须结合多个样本、deadlocks 计数与实际错误。

同一版本按固定表集采集 INSERT/UPDATE/DELETE/HOT 累计计数、估计活跃/死元组与扫描/维护计数；相邻快照生成 `rates`，将消息写入与房间激活租约、在线租约、实时兴趣和唤醒 outbox 的背景更新分开观察。WAL 仍是独占集群级计数，不能把 WAL 字节直接分配给某张表或当前数据库；HOT 更新也不是免 WAL。CPU 差分只覆盖两个快照都存在的本轮 PG PID，短寿命 backend 的 CPU 会遗漏；RSS 为 PG 进程 RSS 之和，共享页可能重复计入。采样记录自身 SQL 的耗时，超时和计数重置会留下明确缺口，不能补成零或伪造消息吞吐。

定位吞吐热点时，优先使用真实 TCP 消息入口和 TCP ACK。先在 120 用户、6 Gateway 的双端前台夹具验证同一条消息的发送、两端应用与排空后游标，再以小规模固定在线数分别做无发送背景窗口和 100/500/1,000/5,000 条每秒的 TCP 诊断窗口，观察实际发出、ACK、排队与锁等待的拐点。小规模 5,000 目标仅用于诊断，不能替代 50k 容量结论。正式比较仍要求 50k、180 秒 checkpoint、既定测量窗口和同一 common Loader/TCP 模式；HTTP 结果只能作为不同接入路径的历史诊断证据。不要以增加 HTTP pool/deadline掩盖真实消息入口的后端限制。

失败运行保持 fail-fast 取消和非零退出。Driver 等待本轮进程退出、再确认数据库业务连接已排空后，在停止独占 PostgreSQL 前尽力聚合已有报告并读取已提交的房间头，保存 `result.json`、`foreground-delivery-proof.json` 及 `failure-diagnostics.json`。失败汇总始终标记 `qualityPassed=false`、`failedRun=true` 和闭合的 failureStage/failureCode；报告、数据库排空或诊断失败只记录闭合错误码，不替换最初失败，也不能产生 accepted 结果。

排空后还会独立读取数据库的房间消息头，并逐个比较 50,000 条连接报告中的前台房间游标，保留 `committed-room-heads.txt` 和 `foreground-delivery-proof.json`。缺少游标、落后或超前都不能通过验收；观察到序列间隙后成功补拉的情况由最终游标证明恢复完成。

本机 macOS 默认自动临时端口范围为 49152–65535，曾使两版在连接爬升时出现 `Can't assign requested address`，未进入消息阶段。共同 Loader 因此支持显式来源端口：第一组 6 片从 25000 开始，第二组从 35000 开始，每片拥有 10000 个单调分配的端口，连接与重连均取新端口，并在 bind 前启用 `SO_REUSEADDR` 与 `SO_REUSEPORT`；后者覆盖多个进程同时绑定、尚未连接时的竞争窗口。不同 Gateway 目标端口使用不同 TCP 四元组；同一 Gateway 的两片使用分离的来源范围。Driver 在下一版运行前等待上一版的这些连接退出 TIME_WAIT，记录实际等待结果。此配置两版一致，报告记录来源端口配置，不修改系统网络参数。

启动验证可单独生成 `--users 120` 的小夹具，并运行时显式加 `--allow-small-canary`。小夹具无论吞吐如何都不会产生正式容量验收通过结果。每次失败保留独立目录，重试必须使用新目录。

## Account HTTPS 接入补充

Runner 的 `--baseline-account-binary` 和 `--candidate-account-binary` 必须分别指向两版 Release `IMV2AccountServerApp`。历史 r1–r10 的消息发送固定使用 Account HTTP，不能代表当前 App 的消息路径。当前 common Loader 在既有 TLS/TCP 连接上协商并发送 `messageSendOperation`；`--account-base-url` 仅保留用于工具中的其他 Account 操作。Account caller 使用独立 Actor 身份。当前 App 的 `V2RoutedMessageSendOperationClient` 提交和结果恢复均使用 TCP；缺少就绪会话或超出协商载荷限制时返回明确错误，由持久工作流保留原身份处理，不存在消息 HTTP 自动回退。真实 App 持久 outbox 和跨 Gateway 多设备验证另见[实施证据](https://github.com/Yyilin001/IMMonorepo/blob/21fb3cc8/docs/reviews/actor-realtime-routing-evidence.md)，不能以 Loader 重连代替。

TCP 请求重试保存原 operation identity/fingerprint、冻结首次提交期限和总尝试预算。明确匹配请求的 `SERVER_BUSY` 是前置准入拒绝，客户端保持被拒绝请求的原 submit/query/close 动作；query 被拒绝不证明先前 submit 未执行。`UNAVAILABLE` 与传输超时保持未知并查询持久结果；查询返回 `unresolved` 且首次提交期限仍有效时，才允许同 ID 重提，过期进入 closeIfAbsent。业务 `deferred` 同样保持本次动作。服务端重试下限作为最早时刻，再加不超过剩余总预算的指数随机窗口，避免所有客户端在下限到期同时重试。Loader 与生产策略公式一致，但各自使用单调时钟与持久日期，测试和正式对照必须使用相同新版 common Loader；旧版数据保留其原 hash，不跨版本计算性能比例。

当前候选配置关闭 workload pool isolation，Gateway 每实例物理池上限 11（其中 2 条为续期保留），各工作类共享池与实际 loan 准入，不再叠加旧 direct-send-control 和路由解析独立池；write/read/sync 配置保障份额为 5/3/3，工作准入允许借用其它空闲前台份额，不能解释成三个独立硬并发上限。Runner 的 Account 配置为每 EventLoop 8 条连接。两版分别记录实际拓扑及 PostgreSQL 连接采样，不能以历史池数量推算本轮总连接。Runner 默认创建本次输出目录下的独立 PostgreSQL 16 集群，监听回环端口 18532，配置 max_connections=320，并在结束后停止该集群，保留数据文件。既有 PostgreSQL 配置不变。显式选择 `--shared-postgres` 时只读检查连接上限必须至少为 320。Account HTTP 默认为 18544，HTTPS 入口为 18643–18648，Account caller 的 Actor 端口为 18343。

系统无原生 HTTPS 代理时，脚本使用 6 个独立 asyncio edge 进程；它们只注入可信边缘头并转发真实请求，每 5 秒记录响应状态、实际请求速率、并发、延迟和上游连接池统计。每个入口最多持有 128 条上游连接，完整读完 200 响应的 Content-Length 后才复用连接；失败连接丢弃，业务请求不自动重发，退出时先排空在途请求再关闭池。两版使用同一代理源码和同一个 Release common Loader；Loader 的 HTTPClient 生命周期覆盖整轮负载，在排空后关闭。业务验收必须同时出现真实消息 ACK，以及房间直播正文或补拉记录；直播正文已经应用时，无须为了验收强制补拉。

```sh
python3 IMV2/scripts/verify_v2_benchmark_https_edge.py \
  --keepalive \
  --actor-directory /tmp/imv2-direct-ring-comparison/actors6 \
  --output-dir /tmp/imv2-https-edge-calibration
```

该预检启动自己的回显上游和 6 个独立客户端进程，使用 96 条 TLS keepalive 连接向 6 个 edge 发送 128 字节请求，并记录 5 秒实测速率。它仅证明代理转发余量，不代替 Account 业务、跨节点事件或 50k 容量验证。TCP 消息实测应核验 edge 没有消息发送请求，并记录 Gateway TCP command 指标、房间 Host 准入/批次、客户端有效回执和 PostgreSQL 实际连接数；HTTP 校准结果不作为 TCP 吞吐证据。

## 按实际阶段定位热点

```sh
python3 IMV2/scripts/analyze_v2_actor_realtime_hotspots.py \
  /tmp/imv2-direct-ring-comparison/candidate \
  /tmp/imv2-direct-ring-comparison/baseline \
  --phase rate-5000 --output /tmp/imv2-tcp-message-hotspots.json
```

对 `checkpoint-barrier` 再运行一次可得到无发送时的背景成本。分析以各分片实际时间的交集取样；计数器使用正式阶段前最近快照至最后一个阶段内快照的差分，并公开两端偏移。它不把预热、checkpoint 或 cleanup 的峰值混进消息阶段，不把 lifetime peak 当阶段峰值。Gateway 的 command_duration sum/count 只能提供采样范围内均值；客户端延迟按分片保留，不能平均分片 p95/p99 冒充总体百分位。PG query 类别只代表当时语句，held relation 类别不证明具体行；只有实际匹配的等待对象提供相应强度的阻塞关联。缺采样、counter reset 和边界误差均明确输出。


`--planned-reconnect-inflight-canary` 仅允许显式 `--allow-small-canary` 且全局最多 500 用户。该模式在各分片保留一条已严格验证的 accepted receipt 而不应用 ACK，模拟一次 lost ACK，再排入第二条消息，然后强制移交真实在途操作及待发队列。该模式每连接限定 1 个在途槽，正式模式仍为 8。验收必须出现 `CANARY_RECEIPT_HELD`、`TRANSFERRED`、`RESTORED`、`RECOVERED_AFTER_RECONNECT`、`TRANSFERRED_QUEUE` 和 `RESTORED_QUEUE`，等待两个有效 ACK 和队列恢复原值，仍要求零未知终态及最终游标核对。正式模式不注入。

计划重连将原命令、身份/指纹、首次发送时刻、原截止时间、已用尝试次数、有界待发队列与已应用房间游标在旧事件循环原子移交，经 slot 保存后交给认证成功的新连接。新连接只订阅原前台房间并通过原游标补拉，再以同身份 TCP query 恢复；不新建消息 ID、不重算预算、不从当前 tail 跳过历史。连接/认证或恢复失败仍计未知/失败，意外关闭也不能静默丢失在途消息。

新诊断指标 `im_v2_gateway_message_operation_internal_failures_total` 仅使用两种消息 command、三种 disposition 与封闭 reason 标签；它在旧 wire `UNAVAILABLE` 映射前记录原因，保留客户端协议。不能仅凭 `overloaded` 就判断具体 SQL 或锁对象，需与 Host 队列、执行指标和 PG 证据联合解释。

正式场景的 180 秒 checkpoint 并非保证所有房间 Actor 仍在内存：当前 runtime 默认 idleTimeout 为 300 秒，而 50k 预热按每片 16/s 爬升。分析必须报告 checkpoint 的 active room 时间序列；发送初期可能混入空闲退役后的冷恢复，不能把它当作单纯热房间 SQL 吞吐。若另建热态诊断场景，须明确记录不同等待或保活策略，不能混入固定场景的 80% 容量对照。


分析器会优先从本轮 `evidence.json` 的 loaderPartitions（或 result 的 exitCodes）读取预期报告数，明确输出 expectedReports、missingReportNames 和 reportSetComplete；缺 phase 也计入 missingShardPhaseCount。只有已存在的 10/12 份报告不能产生“缺项为空”的完整性结论。预期数量未知时 completeness 为 null、范围为 observed_reports_only。回归命令：`python3 IMV2/scripts/test_analyze_v2_actor_realtime_hotspots.py`。

去掉 180 秒 checkpoint 等待只能作为独立诊断：保留同一 50k 夹具、5000/s、90 秒和错误门槛，显式 canary 标记排除正式容量验收，记录场景 hash；不得将其结果替换正式场景。活跃房间数量必须取消息阶段附近采样，cleanup 数量不可用于推定冷启动。真实锁链仍需区别发送准入 tuple、房间围栏 XID 与 housekeeping tuple，不能把全体 blocker 边计成独立失败次数。

### 持久消息发送阶段指标

`sendOperation` 按实际存储操作记录八个固定 `stage` 标签，不包含 room、user、operation ID 或 SQL 文本。它们由各物理 owner 的 recorder 聚合到进程指标；一个阶段调用可能处理整批命令、命中既有 receipt 或以错误结束，因此阶段完成数不是消息提交数、客户端 ACK 数或消息吞吐。

| stage | 实际计时边界 |
| --- | --- |
| `receipt_preflight` | 进入发送批次的 receipt 预检、去重和首次提交期限筛选；owner 事务内还会重新核验 receipt。 |
| `authorization_route` | owner 事务之前的 prepare 路由和房间类型/发送策略查询，包括相应缓存命中。 |
| `authorization_control` | owner 事务之前的 prepare 控制库授权协调；没有该工作时不会记录一次虚构完成。 |
| `owner_connection_acquire` | 从请求借用 owner 连接，到物理连接上的 borrowed task 实际开始；包含连接池等待及进入该 task 的调度延迟，不能解释成纯连接池等待。 |
| `owner_setup` | borrowed task 内的 BEGIN 和事务 LOCAL 超时设置。 |
| `owner_body` | 实际 owner 事务 body，包括内部 SQL 授权复核、操作/房间围栏、receipt 和业务持久写入；不能将其全归为消息 INSERT。 |
| `owner_commit` | 实际 COMMIT 调用的完成或错误返回，不表示错误返回时一定未提交。 |
| `owner_rollback` | 实际回滚或被停止事务的物理连接关闭收尾；不表示调用方一取消，数据库任务就已结束。 |

每个阶段固定输出 `im_v2_send_operation_stage_in_flight`、`im_v2_send_operation_stage_started_total`、`im_v2_send_operation_stage_completed_total`、`im_v2_send_operation_stage_duration_milliseconds_sum` 和 `im_v2_send_operation_stage_duration_milliseconds_max`，均带 `{stage="…"}`。recorder 存在时八个标签均有零基线。计时使用单调时钟，只有实际工作完成或实际错误收尾完成才结束；调用方取消不提前归还在途计数。计时器同步幂等，重复 `finish()` 只结算一次。

同一阶段快照满足 `started = completed + inFlight`；`completed` 包含成功与错误结束。按阶段差分计算 `Δduration_milliseconds_sum / Δcompleted_total` 得到该采样范围内**已完成阶段操作的均值**。跨窗口的操作在结束时计入完整耗时，可能包含正式阶段开始前的等待；窗口内开始但尚未结束的操作仍只出现在在途 gauge。因此这存在完成边界偏差，并不是严格限于消息阶段的耗时均值，也不是客户端端到端延迟或 p95/p99。`duration_milliseconds_max` 是进程生命周期最大观测值，不能差分成阶段最大值。与其他计数器一样须公开采样偏移、检查重启和缺样，不得用该阶段完成率代替正式消息吞吐。

### 缓存调用与自动恢复观测

`im_v2_room_actor_cached_local_calls_total` / `cached_remote_calls_total` 记录实际分发的缓存业务调用，`physical_lookups_total` 记录实际分发的房间引用查询。预热后无换代、淘汰或故障的 send/recover，缓存调用增长期间不应增加 physical lookup，也不应占用 Directory pending。`cached_call_attempts_total` 是入口尝试，不能当作实际分发数；`cached_call_misses_total` 严格表示该入口未分发业务 RPC。

`cached_call_responses_total` 来自首批消息 send/recover 快路径；transport 的 cached local/remote 也包含既有本地提示调用。混合 roomLog、订阅和其他严格读取的负载会正常产生 lookup，不能把整个进程的 lookup 增量全部归因于消息发送；零额外 lookup 的硬性断言应在隔离该调用类型的测试中核验。

故障时联合观察 `host_recovery_probes_total`、`host_recovery_waits_total`、`active_host_recoveries` 和 `recovering_rooms` / `waiting_for_lease_rooms`：前者证明按宿主合并探测，后者区分房间恢复与等待权威租约。`recovery_attempts_total` / `recovery_waits_total` 记录按需恢复轮次和退避。超时只是可用性异常；新激活必须由数据库确认允许获取，不能用探测失败或本地等待计时直接证明旧租约失效。

计数器均为进程生命周期累计值，无 room/user/ActorID 标签；组件采样不是事务一致快照。比较阶段增量时仍须检查进程重启、边界和缺样，不能以协调器暂时归零证明实际 RPC/SQL 已排空。

持久发送准备现使用独立有界准入，`im_v2_send_preparation_in_flight`、`queued` 的单位为物理准备 cohort，`admissions_total`、`rejections_total{reason}`、`cancellations_total`也计 cohort；`queue_wait_milliseconds_sum/count`观察已结束的 cohort 准入等待；不与`im_v2_database_work_*{class="sync"}`混用。准备实际结束后才获取owner写名额，因此`foreground_write`在途不再包含control准备等待，跨版本应披露此占用边界变化。准备controller共享于进程内所有物理owner，限制取原foregroundWrite配置，不改变池容量和绝对业务期限；取消仍等待真实control SQL退出才释放。


### 物理 owner durable cohort 指标

`im_v2_send_operation_owner_*` 来自物理 owner coordinator 的真实状态；同址逻辑 shard 的 Resources 只采一次，再异步聚合到进程。没有 room、user、operation 或 owner ID 标签。生产源提供时输出零基线；未接入的可选源缺失不能补作零。它与 `im_v2_send_operation_batches_total` 的 Factory room turn 计数不同，后者不能用于声称跨房间实际合批。

| 指标后缀（公共前缀 `im_v2_send_operation_owner_`） | 类型与口径 |
| --- | --- |
| `retained_items` / `retained_bytes` | gauge；queued 与实际 executing 共同保留的命令数/JSON command payload 字节。字节不是整个进程 RSS，也不包含所有数据库驱动内存。 |
| `queued_turns` | gauge；等待 owner cohort 选择的 prepared room turn 数，不是命令数。 |
| `in_flight_batches` | gauge；已选出的实际 owner cohort，包含等待 owner admission 与 executor 实际结束的工作；取消 caller 不提前减去。 |
| `batches_started_total` | counter；每次实际启动 coordinator cohort 计一次，包含 owner admission 尝试；不是 Factory room turn、SQL COMMIT 或成功消息数。 |
| `batches_completed_total` | counter；executor 或 admission 拒绝真实结束才计一次，不区分提交成功与失败，也不因 caller timeout 提前计完成。 |
| `commands_submitted_total` | counter；选入上述实际 cohort 的命令数；排队后取消、过期或未入队拒绝不计入，结果未知/失败不扣回。 |
| `largest_batch` | gauge；各物理 owner 的生命周期最大 cohort 命令数取 max，不是正式阶段最大值，不能差分。 |

在计数未重置的单 owner 快照中，`batches_started = batches_completed + in_flight_batches`；跨 owner/组件异步采样不是统一事务快照。`Δcommands_submitted_total / Δbatches_started_total` 可描述采样窗口内**启动 cohort 的平均命令数**；不能以 completed 作不同边界的分母，不能当作 ACK 吞吐或 p95/p99。复杂 fallback、已存在 receipt 和拒绝项可在同一次 coordinator 调用中走不同 SQL 路径，因此 cohort 数不等于 PostgreSQL 事务数；结合固定 `owner_commit` / `owner_body` 阶段、实际 table delta 与客户端有效 receipt 才能解释收益。

阶段分析继续按 report 的实际 startedAt/endedAt 使用 phase 前最近采样作 baseline，公开边界偏移、缺样和重启。上述 gauge 峰值只能称“采样中峰值”；开始/结束跨窗口的工作仍有边界偏差。owner batching 的功能、statement 集合与受控排空测试通过，不构成固定 50k/5000 或原版 80% 容量通过证据。


### 跨房间 preparation collector 的观测单位

新增 `im_v2_send_operation_preparation_owner_*` 与 `im_v2_send_operation_owner_*` 使用同一组封闭后缀，但分别来自准备和写入 collector；同址逻辑 shard 按物理 holder 去重采样。`retained_items` 是 queued 与 executing 的命令数，`retained_bytes` 是编码 command payload 字节，`queued_turns` 是等待选择的 room turn，`in_flight_batches` 是已选择而实际 admission/executor 尚未结束的 cohort。`batches_started_total/completed_total` 计 cohort 启动/实际结束，`commands_submitted_total` 计选入 cohort 的命令，`largest_batch` 是各物理 owner 生命周期最大命令数取 max。取消未提交项不计 commandsSubmitted；caller 超时不提前结算实际在途。准备 queue gauge 不应再解释为旧版每房间独立 SQL 准备数。

`Δcommands_submitted_total / Δbatches_started_total` 只表示该阶段启动 cohort 的平均命令数，不是成功接受数、SQL 事务数或 TCP ACK/s；completed 包含拒绝和错误。两阶段各自具有开始/完成边界偏差，不能混用分母或简单相加耗时。`receipt_preflight` 此时包含一次集合 owner receipt/route snapshot，`authorization_route` 为该快照的映射或异库 route 读取，`authorization_control` 为集合控制协调；与旧版每房间完成数相比必须披露单位变化。

正常需要新建/推进的 control chunk（最多128请求）由 7 条业务 SQL + BEGIN/COMMIT 完成；只有既有 frozen intent 时可少一条 mutation，256命令可分两个 chunk。owner connection 实际释放后才借 control connection。域失败隔离与复杂 fallback 有额外 SQL，不能仅依据配置 batch size 推算往返减少比例。测试中的 statement trigger、冻结授权/代次、跨房间完整键和 actual drain 证明功能与集合行为，不代替真实 workload 的事务/WAL/锁链/阶段时延与ACK证据。

最新 r10 编译失败未测试；r11 实际8 tests/2 suites有1项夹具失败；修正后r12仅该control及metrics两项通过。此批 Release 仍待完成，新 TCP 与正式 50k/5000 不记通过。上一批正式阶段仍质量失败；保留90秒、50k在线、5000/s及全部质量门槛，只有实际完整共同窗口及游标证据满足条件后才比较≥80%。

后续生产配置审查发现旧append默认0曾使durable size退化为1。现在durable两阶段独立使用 `IM_V2_DURABLE_SEND_OWNER_BATCH_SIZE`（默认64，允许1–128，实际截到原pending），不依赖旧append/credit开启，不提高原并发/队列/延迟预算。两个collector新增 `largest_room_count`：各物理owner生命周期最大实际cohort房间数取max；它与 `largest_batch` 的命令数分别观察。只有room count>1才能证明该节点曾实际跨房间合批，不能凭单房间多命令断言。分析器将其标记为生命周期水位，phase内采样不表示该水位只在phase内产生。

### Store 集合 waves 与真实回退分支

多命令 plain direct room turn 现以 waves 执行：每波每房间最多一条 fresh 命令，全部波同一 owner 事务；完整 handle 预检，任一项不兼容则整个 turn 保持原路径。中间波失败须真实回滚后按完整 handles 隔离，禁止房间前缀单独提交；COMMIT unknown不隔离重发。messages/completion集合语句随wave数增加，但操作/activation快照、最终proof/永久receipt与累计准入尾部不随每房间逐项发送。全replay不发空INSERT。

新增 `im_v2_send_operation_store_*` 全为生命周期counter，来自真实 Store 执行边界，区别于coordinator的 `im_v2_send_operation_owner_*`：

| 指标后缀 | 单位与边界 |
| --- | --- |
| `cohort_attempts_total` | 实际进入集合执行尝试次数，包含已确认回滚后的隔离子cohort；不是coordinator批次或已获得物理连接数。 |
| `cohort_handles_total` / `cohort_commands_total` | 上述尝试包含的完整handles/命令数；隔离重试可重复计，不是唯一提交数。 |
| `cohort_commits_total` | 集合事务已确认COMMIT次数；unknown不计确认提交。 |
| `cohort_accepted_commands_total` / `cohort_replayed_commands_total` | 已确认集合提交返回的新接受/永久receipt回放命令数；不表示客户端已收到ACK。 |
| `cohort_isolations_total` | 已证明可回滚隔离的决定次数，不是实际SQL回滚语句数或唯一坏命令数。 |
| `scalar_fallback_handles_total{reason}` / `scalar_fallback_commands_total{reason}` | 原标量执行边界的handles/命令数，每个实际回退handle记录一次，不按二分层数重复计；不保证最终接受。 |

`reason` 仅允许 `multi_command`、`complex_payload`、`legacy_or_not_ready`、`domain_isolation`，无room/user/operation标签。当前多命令已支持waves，保留 `multi_command` 零基线兼容；复杂媒体/reply/mention/forward或review归 `complex_payload`，单一候选、legacy或未就绪等原路径归 `legacy_or_not_ready`，确认回滚后二分到原执行边界归 `domain_isolation`。纯永久receipt集合回放不算标量fallback，unknown不转换isolation。

诊断应联合cohort尝试/提交、固定原因回退、actual owner_body/owner_commit、表写入与客户端reports；largest room count只证明曾跨房间选批，不能证明每命令都进集合或成功。跨窗偏差与缺样披露仍适用，不相加不同边界指标推算吞吐。

r14真实专属双库聚焦通过（6 tests/3 suites，12.197秒；构建109.47秒），新增两参数waves回归1.611秒，核验同一实际事务、两波setwise INSERT、回放/混合fresh、累计准入及第二命令失败无前缀提交。只证明功能与集合边界。本批Release、新TCP和50k/5000×90秒容量待结果；此前default64正式失败不改写为通过，不声明≥80%。

### 两段集合 quota tail 的观测边界

最新tail不再在同一statement中先锁pool再UPDATE。正常路径是一个按shard/profile排序的锁SELECT，随后一个集合quota gate+UPDATE；两语句均在原owner事务内，比此前多一个固定SELECT往返，仍只有一次集合quota UPDATE。第一语句完整验证锁键集合，缺行立即missing lease，禁止第二语句发现未锁的新插入行；第二语句在READ COMMITTED新snapshot中复核lease/generation、传入now的expiry与额度，全组gate及strict rowcount不变。该变化不是扩池、扩额度或延长业务预算，也不把expiry检查改成fresh DBclock。

FK成本不能仅按显式SQL列表估算：PostgreSQL16官方实现会在旧tuple xmin属于当前事务时强制检查外键，即使FK键未变化；多wave前一轮写入的room_admission版本可能触发该路径，存在性检查使用KEY SHARE。不能由“只UPDATE used”排除隐式pool锁，也不能由该源码机制断言正式死锁根因已经证明。[PostgreSQL16官方源码](https://github.com/postgres/postgres/blob/REL_16_STABLE/src/backend/utils/adt/ri_triggers.c)

r19旧尾部的完整并发cohort回归通过0.801秒，没有复现正式死锁；保留这一限制。r20最新两段tail受影响真实双库5 functions/1 suite通过8.015秒（build65.04秒），包含authority五case、waves两case、完整cohort、tuple队列及KEY SHARE检查。此时Release正在构建，新TCP/50k容量未验证。原正式阶段中的确切tuple/XID环仍是失败证据；新实现的死锁消除效果必须由实际后续运行确认，不按功能测试或源码解释宣称容量/≥80%通过。


### 物理数据库 loan 指标与停止边界

生产每个实际pool/role/EventLoop共享loan gate，跨logical owner的facade不重复计数。原11连接池为ordinary与activation合计最多9、renewal保留2；activation在这9个槽内默认最多2个，不增加物理额度。小池的activation上限为min(2,非续租容量)；未预留续租的池仍保留原renewal可借总额度的行为，总容量始终受限。`im_v2_database_loan_*`仅含固定 `class="ordinary"` / `class="activation"` / `class="renewal"` 标签，无URL、schema、用户或owner标识：

| 后缀 | 类型与口径 |
| --- | --- |
| `in_flight` | gauge；已授予且实际数据库future尚未结束的loan槽。含driver借连接等待，不表示实际连接使用率或正在执行SQL的连接数。 |
| `queued` | gauge；尚未获得loan grant的请求，不是业务stage队列或Fluent内部池等待数。 |
| `granted_total` | counter；实际grant数，不能解释为成功事务、COMMIT或ACK。 |
| `rejected_total` | counter；获准前被拒绝的请求，含取消/超时/关停；没有动态原因标签。 |

已接源输出三类零基线；nil源整组省略。topology按实际composed pool去重再汇总各EventLoop，借用槽跨异步组件并非统一瞬时事务快照。analyzer已接此family；阶段counter增量仍需披露边界偏移/重启/缺样，gauge仅为采样中峰值。三类facade共享gate，嵌套borrowed transaction/SQL不重复申请。renewal用于实际租约续期；locate/acquire/release及restore validation使用activation，业务执行仍ordinary。满activation队列不阻挡可授予ordinary/renewal，但各类别内部保持FIFO，全类别共用原pending上限与原绝对期限。

旧两类报告中的ordinary包含生命周期工作；新版ordinary不含activation，比较非续租占用应合计ordinary+activation，不将新增分类后的数值下降当作资源需求下降。旧报告没有activation标签表示缺少细分类证据，不能据此证明生命周期实际为零。新增facade未加入拓扑池列表，不重复采集或关闭同物理gate。

取消存在SDK边界：Fluent的EventLoopFuture API不提供Task取消回调，取消await `.get()`不能撤销原future或提前归还loan。该路径仍受原deadline、排队上限和shutdown约束；显式gate request以及async SQLKit入口可移除queued等待者。已经grant并交给真实数据库借用的工作，必须等实际future/connection归还；SQLKit withSession固定真实borrowed句柄，不把SDK默认session(self)当作借用证明。driver借用提前失败未调用业务closure时，session也须完成promise并归还槽，不能遗留shutdown等待。

正常shutdown先关闭业务入口并排空连接/后台任务、durable准备与写入及Actor真实工作，再停止loan gates并等待所有已授予槽归还，最后关闭底层数据库资源。重复gate shutdown等待同一实际排空；新项与排队项被拒绝。达到原停止期限仍有真实所有权则失败退出，不允许先关闭池或清空指标伪造排空。

本批r2受控聚焦通过8 tests/3 suites（0.115秒，构建106.45秒），包含真实受控future的容量/FIFO/嵌套/取消/关停/提前borrow失败及renderer断言。PG环境未提供，实库pool用例条件跳过；不能记为真实PG压力验证。6项Python热点测试与文档/模块检查通过；Release仍在构建，尚无新正式TCP容量结果。旧正式失败及缺报边界保留，不宣称50k/5000×90秒或≥80%通过。

### 当前续租整改与待验证口径

`renewalDeferred` 表示确定此次未续成功；当前仅由confirmed rollback的 `rolledBack(.unavailable)` 映射，COMMIT unknown仍按unknown退休。Host在原 `safetyUntil` 内按原续租周期重试，失败不刷新租约、安全期限或watchdog；分发前与返回后检查当前generation/token和安全性。其它错误仍fail closed，晚结果不复活退休entry。这不是延长TTL或无限即时重试。

批量续租领域SQL由四段减为两段，不是单statement：先完整锁定有序rooms；随后新snapshot内有序锁leases，完全消费 `leases_done` 后取freshclock并逐输入核对owner/token/expiry，执行集合UPDATE。事务setup、BEGIN/COMMIT/ROLLBACK另计，不把领域SQL减少当作整个事务只有两个网络往返。原deadline及实际future收尾不变。

focused r1真实PG三个functions通过（2.755秒），Host四项通过（0.827秒）；Release r1成功退出（164.40秒）。后续r2单function受控锁变更暴露反例：原UPDATE target按statement snapshot预过滤lease，可能在等待锁后漏掉已改写的行并报 `corruptPersistenceState`。最小修复只将target改为按PK定位已锁lease，完整checked授权与freshclock/expiry判定保留；不能把原r1通过当作已覆盖该竞争。r3受影响PGsuite四个functions通过（3.242秒，构建10.84秒），新增expiry case为0.418秒；Host源码未变，不重复Host测试。修复后的Release r2正在运行，新TCP与正式容量尚未验证。

此前物理loan正式候选目录 `/tmp/imv2-physical-database-loans-tcp-5000-20261001-r1` 已质量失败，7/12报告缺0、3、5、7、10；可用phase交集10.013秒，只有两个内部采样，counter baseline提前约5.072秒且末样本缺约4.625秒。末样本ordinary每GW9、总排队944，renewal总8且queue/reject增量为0；该指标跨各实际pool/EventLoop聚合，不可一般解释成单池使用率。Directory各GW active128/pending1024，无Host探测风暴。保留此轮失败与采样边界，不能外推缺失分片吞吐或声称90秒/≥80%通过。

### 1000档缩放诊断与最终容量分离

按用户最新执行策略，后续迭代先跑1000档快速诊断。当前诊断配置明确为10,000在线、1000消息/秒、30秒且无checkpoint，使用 `actor-realtime-scaled-diagnostic-1000.json`；runner必须显式启用 `--allow-scaled-diagnostic`，evidence记录 `scaledDiagnostic=true`，正式验收条件明确排除该模式。此flag只允许明确缩放的诊断样本，不降低消息身份/终态、错误、队列溢出、真实排空、共同在线和游标追平校验。

诊断通过不能记为正式容量通过，不能外推50k或与不同比例样本计算≥80%。最终仍使用原50,000在线、5000消息/秒、90秒固定场景及完整质量校验进行原版/候选对照；历史正式失败保留。先完成小档诊断及必要修复，再执行最终5000档验收，避免每次优化都先启动完整容量运行。


### 整机资源与进程资源分开采样

原 `process-resources.jsonl` 仅记录本轮拥有的服务/压测进程，不代表整机 CPU 或内存压力。现在 macOS runner 每轮采样同时保存 `host-resources.jsonl`：Mach HOST_CPU_LOAD_INFO 的 user/system/idle/nice tick 与相邻区间百分比、load average，以及 vm_stat、vm.swapusage 和内存压力级别的原始输出/返回码。读取失败明确保留错误，其他平台标为 unsupported，不补零。此采样不设置 CPU/内存限制，也不调整线程、连接池或原预算。

hotspot analyzer 的 `host.cpuIntervals` 仅使用起止都在各分片实际 phase 交集内的区间；跨预热边界的百分比不混入。`host.snapshots` 保留阶段内原始 VM/swap/pressure 事实与时间，不把累计 swapout 当阶段换页量，不由 RSS 相加推出整机内存压力，也不把 load average 当 CPU 利用率。旧运行缺文件明确输出缺证据，不能事后用当前整机状态证明旧运行资源充足。

### 完整 owner cohort 持锁 SQL 合并

多命令 turn 的原 wave 顺序仅用于构造公平的交错输入，不再每轮发送 preflight/message/projection SQL。实际 owner 事务一次预检，在 Swift 内按房间 FIFO 累积 room/timeline 序号及共享 shard admission 状态，再一次集合持久化；128 handles/256 commands、collector 批大小、并发、队列与 deadline 保持。陌生人额度按有向用户对累计同冻结窗口的 delta，一个 key 一次 upsert；双方 reply transition 按 room 合并，revision 精确增加一或二；首次投影按 room/sender 的最早有效命令保留 ordinal/sourceEvent，双方 pair 标记一次更新。

配额不足仍经确认回滚回退原逐项执行，合法消息接受、超额消息 rateLimited deferred；不能把一次集合 quota 失败解释成整 turn 永久拒绝。其它拒绝或损坏的整 turn 仍按既有回滚隔离，COMMIT unknown 禁止拆批/隐藏重投。真实 PG 聚焦测试覆盖五个参数 case（3 functions）；功能通过不证明最终 50k/5000 容量通过。


### 单组准入成功路径与事务子段计时

只有 owner cohort 的实际额度集合归并为一个(shard,profile)时，尾部使用完整条件 UPDATE：匹配 lease_id/generation/valid_until，并以最新 pool.command_window_used+delta 在限额内更新，RETURNING 完整身份/期限/计数严格核验。READ COMMITTED 等待后的新行由 PostgreSQL EPQ 重查 WHERE/SET。只有 SQL 成功完成且返回零行才能在同一事务、原 deadline/now 内进入既有 ordered lock SELECT 与新 snapshot 全组 gate；异常、结果未知、已更新后的解码/核验错误不得 fallback 重扣。多组原两段逻辑保留。外层未使用 ROLLBACK TO 的 cohort SAVEPOINT/RELEASE 已删除，所有业务回滚与隔离仍由实际外层事务完成。

`im_v2_send_operation_stage_*{stage=...}` 新增10个封闭子段：owner_locks、owner_receipt_read、owner_preflight、owner_reduction、owner_policy、owner_message_persistence、owner_projection、owner_proof、owner_receipt_persistence、owner_admission。它们在单次 cohort 内互不重叠，属于 owner_body 父段；跨并发 cohort 可以重叠。每项从实际操作开始到 await 返回/throw 后收尾，caller取消不提前计完成。子段未覆盖全部父段组装成本，各段完成次数及边界可能不同，不能把各平均值相加作为端到端耗时，不能再加 owner_body 父段。最后统计均值仍需公开 counter offset/reset/缺样；duration max仍是生命周期水位。

父段owner_body及外层acquire/commit覆盖scalar和cohort两种事务，新增10子段只在cohort路径计时。两者总体不同，即使使用相同采样窗口也不能用父均值减子均值之和推算未覆盖的Swift执行成本；需同一事务的观测或匹配总体计数。SQL分类admission_credit也尚未区分单组fast UPDATE、零行fallback锁SELECT与集合gate UPDATE，不能由idle-in-transaction的最后分类推断实际分支。

### TCP 前门实际预算与拒绝原因

`im_v2_gateway_message_send_` 来自生产传输实际共享的 budget 实例：in_flight_requests 是成功预留尚未归还的请求数（含授权复查间隔），reserved_bytes 为同一批实际保留字节；二者不表示实际 SQL 活动数。peak_in_flight_requests_lifetime/peak_reserved_bytes_lifetime 明确是进程生命周期水位。rejected_total 使用封闭 reason=connection_count、connection_bytes、process_bytes，一个入口拒绝只计一个原因；先判连接数量，再连接字节，再进程预算。没有 conn/user/room 标签。源未连接时整组省略，连接后全零基线；取消后实际处理未收尾前预算保持，不能把caller结束当归还证据。

此组不改变 SERVER_BUSY、retryAfter、原每连接4请求/4MiB、进程64MiB以及 Loader8逻辑operation 的配置。新 analyzer 已接 family，并将 peak 明确标为 lifetime；不得把旧无指标运行的缺数据补零或根据普通loan拒绝为零推断 TCP 未拒绝。

2026-10-02本批诊断：1000档12/12报告完整、30.009秒、29988消息全部ACK且10k最终游标匹配；2000档仅3/12报告、约20秒质量失败。后者counter baseline早3.198秒、末缺2.615秒，采到3346次入口拒绝均connection_count，两类字节拒绝0；host有3个完整内部CPU区间，idle13.675–14.859%，swap/换页计数不增。报告不完整和采样缺口必须随结论披露，不能计算全体吞吐或称30秒完成，不能据此宣布正式50k/5000×90秒容量通过。

### 选择性线程栈采样

`profile_v2_owned_benchmark.py --run-directory /tmp/RUN/candidate --runner-pid PID --phase rate-2000` 仅允许明确scaledDiagnostic的本轮owned进程。等待该phase日志达到指定秒（默认5），选前两个Gateway与最多两个实际owned PG进程，默认采样3秒/10ms，保存stack-profiles/manifest.json及sample文本。日志可能缓冲，必须按manifest的observedPhaseSecond、实际startedAt/endedAt对齐窗口，不能以指定秒替代实际开始。目标亲缘与PG postmaster核验失败直接报错；不采系统中其他PostgreSQL。

PG选择来自非原子锁快照中的可见非等待端点与最高累计CPU进程，并不能保证持续根持锁者或采样期间最忙的进程；记录selection与原快照时间。selector同时排除edges、blocked表及blocker子表已观察到的Lock等待。睡眠/kevent/ClientRead和锁等待栈不是CPU执行热点，sample计数不能当整机或线程CPU百分比，需结合实际进程CPU区间。采样有开销，manifest明确profilingOverhead/excludedFromCapacityComparison，带profile运行用于诊断，不用于收益或正式容量对照。

### 准入返回与提交分发的事件边界

`im_v2_send_operation_admission_handoff_duration_milliseconds_{sum,count,max}` 使用固定 path=single_success/single_fallback/multi_group 和 part=result_ready_to_validated/validated_to_commit_dispatch。实际 SQL future 的成功回调执行时记 resultReady；完整RETURNING解码与guard通过后记validated；原deadline及beginCommit通过后、COMMIT API调用前记dispatch。两part按同一成功验证且到达dispatch的事务同时计一次，COMMIT unknown仍计dispatch。成功零行fast语句不产生validated；fallback使用最终gate结果。失败或dispatch前回滚不计。

resultReady不等于driver内部promise完成或数据库执行结束，dispatch不等于真实socket write或确认COMMIT。max是生命周期水位，不是phase百分位。两个part在单事务内不重叠，却跨owner_body和finalization，不能再与父阶段相加；只覆盖集合核，不能与混合scalar/cohort的父均值相减。renderer保留3×2零基线，analyzer按相同path/part的count增量计算平均，没有完成样本时为None。

2026-10-02 handoff批次无profiler的1000档完整质量通过，30.001秒、29988ACK、10000最终游标匹配；2000档仍约20秒失败，只有5/12报告完整。2000完成样本single_success的两个part平均分别0.597–0.749ms与0.033–0.040ms，admission平均49.957–57.060ms；不能据此把平均长等待归因SQL返回后的Swift恢复。采样覆盖内connection_count拒绝3966次，PG blocked峰17/fan-in11、deadlocks增量0，三个内部CPU区间idle13.961–14.993%。Gateway counter baseline早3.196秒、末缺2.409秒；缺报及采样边界随结论披露，禁止计算全体容量收益。

后续正常eligible singleton也进入现有集合核，confirmedrollback隔离叶仍为原scalar，COMMIT unknown不隐藏重投；single_success标签依然指一个quota组，不代表singleton。新1000档12/12报告、29988ACK、30.006秒与10000最终游标完整通过。新2000仅5/12报告、20.003秒部分窗口，quality失败；counter早3.235秒/末缺2.487秒，入口connection_count拒绝3886、两bytes0，scalar fallback/isolation0。内部CPU加权idle13.555%、swap/pageout不增、PG blocked采样峰10/fan-in7/deadlocks0，功能整改没有消除过载。保留历史失败，不记正式容量收益；原50k/5000×90秒及≥80%仍待完整验收。

### 集合回执与证明的读取边界

ownerReceiptRead 的 execution envelope、accepted/denied completion、legacy closure、exact/prior attempt现使用一次完整statement snapshot；原operation锁和activation围栏必须在前一语句实际取得并验证。ownerProof 中的attempt/completion/owner使用领域写入后的另一完整statement，仍从数据库事实生成证明，proof INSERT保持独立严格写入。正常有attempt的成功路径，七次读取合为两次；空输入或无attempt原本有跳过分支，不能对全部调用宣称统一减少五次SQL。

fixed-kind UNION ALL不依赖结果顺序、不产生JOIN乘积；各阶段按原顺序完整解码，accepted+denied、重复ordinal、缺行、future-generation和身份变化继续fail closed。已有stage计时保持原await边界，新SQL不会变成新权限，COMMIT unknown、quota和deadline不变。准备期existing薄查询保留，未用旧SQL wrapper删除，解码共享。PG sampler目前未给新snapshot marker单独分类，可能归other；不能据粗分类缺失推断未执行该读，应用阶段指标仍是实际调用。

真实PG受影响5 functions/8cases已完成：r1编译失败无测试；r2七cases通过、mixed夹具外键失败；仅修该夹具后r3受影响mixed单项通过0.795秒。功能覆盖包括exact优先、混合事实/closure/missing、schema证明不可变、损坏检测、首次producer和重放、singleton rollback隔离、实际COMMIT未知不重投。日志与失败保留于review evidence，不把静态检查或单项通过当容量证据。Release已通过，新1000/2000诊断待终态。

快照批次新1000实际12/12报告、29988ACK、30.004秒和10000最终游标完整通过。新2000仍quality失败，只有1/12报告、20.007秒部分窗口；Gateway counter早3.246秒、末缺2.629秒。telemetry观察connection_count3085/bytes0、fallback0，receiptRead/proof平均5.418/13.657ms、admission67.492ms；不同完成总体不相减推收益。PG blocked采样峰24/fan-in13/deadlocks0，内部CPU加权idle13.786%、swap/pageout不增。功能改动没有消除过载，禁止用缺报结果算全体容量；正式目标仍未完成。

### 同额度行在借出连接前协调

owner coordinator 以固定profile下的prepared owner shardID为稳定quota key；同key只有一个实际cohort，不同key在原批次上限内并行。等待项留在原有界内存队列，同key多个房间可以进入同一批，实际任务结算才释放key。取消、shutdown和queued deadline不提前释放执行资源；full-slot/all-busy也按最早排队deadline单次唤醒，保持原FIFO/原合批等待age/128handles/256commands。此协调仅进程内，不替代跨Gateway数据库全局额度和围栏。

本批实PG5函数/6cases、Release均通过；1000新诊断12/12、29988ACK、30.001秒和最终10000viewer完整通过。2000新诊断12/12且全Loader exit0，完整30.008秒消息窗口、59988整轮ACK、工作失败与队列丢弃0；phase内59706ACK、1989.618/s，7次TCP count拒绝、bytes0。最终14viewer落后1条，runner实际exit1/qualityPassed=false，不能算通过或绕过游标条件；房间成对另一端匹配持久化头，最后提示/恢复原因仍待定位。

2000 counter覆盖内admission均值3.146ms、body54.369ms、PG阻塞采样峰2/fan-in1/deadlocks0，各Gateway owner实际并发峰1，cohort平均21.315commands/started。ActorRPC仍有5664次overloaded。CPU内部加权idle16.682%、swap/pageout不增，原生14核/48GiB资源未增加；支持结构性争用影响此前表现，但不排除局部CPU压力。counter早3.093秒、末缺2.258秒；未采到某类锁不代表不存在，旧2000缺报不能作为完整fleet增幅分母。完整记录在review evidence，原50k/5000×90秒及≥80%仍待通过。

### 最后一条通知的状态证据

Loader 的 roomCursorSnapshots 新增实际前台、announced水位、wire pull/预留槽、retry/grace以及最后匹配hint的时间。一条handler EventLoop同步快照不代表跨连接或数据库原子观测；旧报告缺新字段表示未知。原独立持久head与quality不依这些诊断值，不主动追平或延长收尾。

真实落后时 runner 另写 `foreground-wake-witness.json`，最多256 unique rooms，记录独立只读数据库时间、当前head、wake有无/state/target/revision/attempt/next/leaseexpiry。4秒SQL、5秒process超时，错误仅diagnostic missing，不改quality。该SQL发生在Loader结束后，no-row不能证明客户端已收到通知；撤销路由后空fanout也可能删除outbox。stored target低于head符合合并设计，claim读取GREATEST新水位。

新诊断版1000完整通过；2000完整59988ACK而quality仍失败，6房间每端差1。客户端全部announced<head且无pending；约945ms后的DB观测六wake仍pending、attempt6/7、next还需6–16秒。RPC采样4815本地overload、failed/rejected0，不保存逐room历史失败原因，不能把所有历史attempt直接归因overload。新增明确背压分类后，房间与个人同步共用短有界jitter重试；未知失败仍原1→30秒，不增加原query4/global32/peer2/receiver限额，不变worker、lease及质量条件。受影响20cases已验证。

背压分类后真实小档已完成：1000为12/12、29988ACK及10000最终viewer匹配；2000为12/12、59988整轮ACK、phase内59658 ACK和10000最终viewer匹配，均qualityPassed=true。post-drain hold10秒未变，no lag不生成wake witness符合预期。2000各片ACK p95 582–639ms高于前轮359–369ms，TCP count拒绝96、PG CPU约4.58核，不能把尾收敛修复当作所有性能指标改善。采样SQL/WAL计数未暴涨，但counter包含多种outbox工作且窗口不精确，不归因全部成本。

正式candidate session56038以50k paired-policy夹具、原checkpoint180/5000×90秒运行，目录 `/tmp/imv2-publication-backpressure-tcp-5000-formal-20261002-r1`，实际exit1。50000连接全部建立，原checkpoint完成；共同消息窗口仅10.015秒，12/12失败，整轮6020ACK，不能使用短阶段523.429 ACK/s产生容量接受。

checkpoint实际activeRooms25534→11818，rate唯一inside Directory六节点均128active、pending约1024；ordinaryloan queue89–147、ownerqueue436–521。最早出现deferred retry exhaustion及SERVER_BUSY，清理后unknown不作为首因。唯一inside PG快照无锁等待，但不排除未采到的瞬态竞争；foreground work controller queue/rejection0，不把物理loan等待混称其准入满。host仅一inside样本，近阶段CPU idle34.38%区间越界约95ms，无严格phase CPU/VM增量。Gateway每个RSS约1.36GiB、Loader约243MiB属于驻留快照，不证明资源上限或泄漏。先小规模冷/热混合定位，不连续重跑formal或更改idle/预算掩盖失败。只有两版原规格完整质量通过及candidate实际ACK吞吐≥baseline80%才接受，单版和小档不替代该门槛。

### 自然退役后的冷热诊断

生命周期借用隔离已通过聚焦9functions/11cases（含真实PG factory退役恢复与receipt重放）、Release及模块边界检查。诊断在10k scaled1000场景前增加270秒零消息checkpoint，保持生产idle300和原发送/排空/hold/质量。早期预热房间可能退役，后期房间仍存活；须以实测activeRooms下降且非零确认冷热，不能按配置时间认定。使用`--allow-scaled-diagnostic`，该场景hash和原formal180秒不同，不能替代正式容量或与旧暖态数据求收益百分比。

`/tmp/imv2-activation-loan-cold-hot-tcp-1000-20261002-r1` session24690实际exit0，12/12、29988整轮ACK、10000最终viewer匹配、失败/队列丢弃0；phase29987ACK、30.003秒、999.467376/s，最后1ACK在drain。checkpoint activeRooms近期峰5502→3424，实际activation grants7467；三类采样queue/rejection0。activation sampled峰只有1，真实硬2上限由controlled gate测试与factory接线验证，不能把稀疏峰值当实际占满。各片ACK p95 170–176ms，body均18.809ms/acquire.163608ms，counter尾缺4.54秒，样本边界随结论保留。

同条件2000档session98866实际exit1，12/12/Loader均0但59988send/59983ACK、5终态失败和1最终viewer落后，qualityfalse；完整30.006秒，phase59604ACK/1986.445538/s。3submit重试耗尽、2query/close unknown未解决在drain完成分类，phase无domain DEFERRED，错误名称不代表域准入拒绝。actualactivation峰各2/queue49–98、ordinaryqueue13–27，逐sample/node仍非续租<=9/总<=11，loan拒绝0；各片ACKp95 1.4–1.726秒。唯一落后announced/applied1<head2、无pending，13秒后的DB no_outbox已是关闭后观测，不能定漏通知位置。CPU内部idle16.54%/swap-pageout0、PGblocked峰4，不把该诊断记成容量接受；counter基线早3.082秒/尾缺2.058秒。下一步有限集合化生命周期查询、保留恢复校验和原期限，方案未实现，原正式容量条件保持。

生命周期集合查询已实现并通过真实PG+调度聚焦10functions/11cases、Release174.26秒；仍用原pool/CPU/内存和idle合同。物理collector最多128distinct room/2actual，原deadline、房间锁后新snapshot租约锁/fresh clock、strictRETURNING及unknown不自动重投不变。Host.stop只关续租，最终Application才排空共享lifecycle。新冷1000诊断session50098进行中，不使用尚未完成结果判容量。

CPU分析必须区分native机器资源、整机tick与各进程实际CPU时间。原机14core(10P+4E)/48GiB，无已观察显式quota；冷2000 raw process样本25.926653秒中6Gateway约6.537288core、12Loader.238750core，PG独立采样约3.849core；整机busy83.459%说明CPU紧张，但不证明某个EL/P核仍有余量。VM无swap/pageout增长不支持本轮内存不足。正式5000仅10秒/1inside sample，CPU/VM窗口不充分；10k/1000对50k/5000同时改变连接和恢复规模，不能按仅速率推断。

新版冷热1000 session50098实际exit0：全部29988ACK/10000最终viewer匹配、无工作失败或队列丢弃；共同30.004秒，phase29984ACK，4条在drain。各片p95 172–177ms/CPU内部idle33.029%，activation sample queue仅node1=2，原预算每sample不超；cold loan grant4397包含恢复validator，不能从loan计数推批次数或collector内部queue0。真实activeRooms5623→3451，前后采样基线早2.059秒/末缺1.438秒。新2000 session57844继续同规格，尚无终态，不判正式容量。

新版冷热2000 session57844实际exit0：全部59988ACK/10000最终viewer匹配，失败/队列丢弃0；共同30.007秒/phase59627ACK。p95各片850–949ms、activation loanqueue1–6（旧49–98）、Directory峰28–39（旧67–109），原资源每sample不超；collector内部queue不因未导出而写0。GW CPU6.454551core/PG约4.015519core、整机busy83.566%、VM无swap/pageout增，普通loan仍各9/queue16–28；支持实现排队改善，不支持硬件容量结论。activeRooms5609→3526证实冷热；counter基线早3.145秒/末缺2.169秒。两小档通过后仅一次原规格candidate session89190进行中，目录`/tmp/imv2-activation-lifecycle-tcp-5000-formal-20261002-r1`，CPT180/5000×90/50k/原资源及quality不改，不能提前接受。

新原规格session89190终态exit1：全部50k warm/CPT180完成，rate2/12失败报告20.009秒、10缺报，原90秒及完整quality未完成，不生成有效fleet容量或80%比较。六Directory128/1024、Hostrestore32、共享非续租9满；有效PG房间围栏XID末ClientRead、期内scalarroom锁超时和idleTxn FATAL，继而userstatepool超时及SWIM失联。PG第二inside psql exit2统计缺失、GW2–5晚期metrics超时，缺失不能记零；仅host4–9秒区间CPUidle51%/VM无swap或pageout增，局部资源/瞬态未排除。所有本轮服务及owned PG已停，原PG1995保留。下一步按来源与实际事务续行定位，保留原正式门槛。


排队零waiter撤销与共享lifecycle恢复校验通过真实PG/Runtime聚焦12functions/15cases，Release166.25秒；完整token/锁后clock/COMMITunknown不减。新同10k冷热1000 session7038仅作有限回归，原正式门槛保持。离线analyzer现保留原已导出的TLS child EventLoop探测histogram、sum/count差值及lifetime max语义；缺基线/缺节点不补0。旧formal仅GW0/1具两个内部探测样本（+4.165→+15.077秒），新增max737/557ms、完成probe均26.201/25.944ms；GW2–5缺有效区间。该timer探测不等同Swift任务或DB EventLoop延迟，也不能由累计max未增长推本阶段无lag。CPU整体空闲不足以排除局部推进问题，无配额不足或内存不足定论。


本批新冷热1000/2000分别session7038/80902均12/12、全29988/59988ACK、10000最终viewer匹配、失败/队列丢弃0；原资源/期限不变，两轮owned服务/PG已停止。共同窗口29.999/30.005秒、phase29967/59656ACK、runner998.679552/1988.151171/s；小档并非正式接受。2000各片p95 656–746ms、coldloanqueue1–2/Directory峰9–21，但ordinary各9/queue12–20、hostbusy84.065%，资源余量没有被证明。TLS probe内部完成样本均值区间峰约1.255–1.530ms、新最大53–109ms，只覆盖TCP事件循环；源码来源与实际SQL续行观测仍待实现。正式50k/5000×90/完整quality与80%门槛未完成，不将小档或整体CPUidle当充分容量证明。


固定50k/1000（原checkpoint180/90秒/质量资源，scaled diagnostic）采样诊断session88879终态exit1，仅10/12报告、37.304秒，缺report4/10；包含owned-only sample开销，明确不计容量/80%，尚不能推未采样相同规格结论。采样前已有loan及交互读取排队和房间锁链末ClientRead，但最早明确可见工作失败在采样之后，仍可能由采样放大。内部整体CPUidle38–42%，VM pageout163/swapin-out0，局部推进或内存因果未确定。全部owned进程finally停止。

本轮已接线封闭来源SQL settle→Swift resume→下次已记录dispatch诊断（8固定来源、两段独立人口/实际终态、不跨未观测SQL误算，物理alias计数一次），以及精确原activity的同步idle预过滤（原Lane原子退役检查保留，无TTL/资源调整）。Python analyzer12tests通过；Swift聚焦r1编译泛型推断失败已修复，r2测试尚在运行，新Release/无采样固定50k低速率验证尚未完成。正式50k/5000×90/完整quality/80%验收保留。


本轮SQL/idle聚焦最终合并13functions/16cases实际通过：r2其余12functions/15cases成功，Factory夹具隐式review开启与声明disabled冲突已对齐，只重跑Factory的r3通过（真实生产lifecycle/durable/scalar来源、围栏、unknown、取消与退役均有实际验证）。r2/r3 owned PG均finally停止。模块598files/forbidden与SCC0、文档链接/diff通过；新Release session72896正在构建，固定50k低速无采样验证尚未启动。保留原正式门槛。

## 2026-10-02 实际借用来源与跨业务竞争诊断

新增物理loan来源/阶段/SQL phase观测后，只运行一次固定50k/1000诊断，
目录`/tmp/imv2-fixed-50k-loan-observation-tcp-1000-20261002-r1`。
50k预热与原checkpoint180均完成；消息期37.947秒失败，仅report2完整，
其余11片缺失。terminalError为计划重连时认证回复前连接被关闭；
Gateway2同刻实际错误为AsyncKit.ConnectionPoolTimeoutError。
sync SERVER_BUSY是此前的工作错误，不能替代真实终止原因。

三个可复核的实现边界：

- 空载末30.721秒有51186次路由查询（1666.15/s）且无RPC投递；心跳在线提示
  先解析用户路由，再查询实际接收节点，即使最终无接收端仍付出查询成本。
- userPresence/userSync主题解析发生在Fanout4查询名额之前，使用单连接
  `gateway-user-state-route`池；重连注册userSync兴趣和随后readHead也使用它。
  路由池约第16秒已超时，最终认证前关闭发生在该注册链路。
- 第1秒已有游标缺口/即时pull；6083次完成pull约48707次SQL Future，
  平均每次约8个SQL、实际占用90.48ms，连接准入等待另计148.78ms。
  读取队列约第15秒满384，随后才出现同步准入超时。

现增加4固定topic kind的Fanout查询在途/实际完成/空结果/门拒绝/耗时指标，
原来的routes.failed与rpc.overloaded没有统计进入Store前的查询门拒绝。
受控检查实际通过：四个空presence查询会拒绝房间推送，释放后推送成功。
新topic指标在上述诊断之后接线并聚焦验证，不能倒填该次压测的缺失数据；
它也不覆盖前置topic解析的单连接池请求，后者由源码与实际错误定位。

实际PG观测检查、受控竞争/容量门检查、Python分析器15项检查通过，
两个观测版本Release分别190.20/181.72秒通过。只读检查两个已有消息房间，
原pageSize100、cursor0/head的4个custom readBody计划为0.170–0.710ms；
不代表负载下全部SQL、generic计划或围栏均已排除。PG未记录死锁，实际借用
持续完成；整体CPU空闲和无swap增长仍不能排除局部调度与压缩开销。
所有owned服务/PG已停，原PG1995保留，原5000与80%门槛未接受。

完整时序、采样边界、源码链与原始日志见
[本轮诊断证据](https://github.com/Yyilin001/IMMonorepo/blob/21fb3cc8/docs/reviews/actor-realtime-routing-evidence.md)。


### r70生产寻址窗口与最终收敛

`/tmp/imv2-actor-realtime-10k-1000-r70/candidate`实际终态0：完整12报告、10000认证、29988 ACK、约999.532/s，最终独立10000 viewer无missing/behind/ahead，coverage/quality通过。live gap frames=6315、metadata gap observations=9181，故证明最终恢复收敛，不能表述为直播严格FIFO或无补拉。

独立`hotpath-address-sql-proof.json`在共同rate-1000 phase内取6个完整六节点实际HTTP采集窗口：publishSettled增27042，route_lookup与realtime_owner_snapshot来源四phase SQL计数增量各0、边界active总数0。这个结果仅覆盖特定寻址来源，排除授权/注册、恢复头、持久化和租约SQL；旧routeQueries零值及ACK量单独都不能证明它。离线工具不改原quality或回填历史结果，旧记录缺实际read时间、缺节点、计数重置或有效窗口不足10000发布均为incomplete。

r71正式50k/1000仍在根代理独占运行，原checkpoint180秒+90秒消息及资源不变；此处不预写终态。10k结果不能代替50k/5000或同规格基线至少80%门槛。详见[实测证据](https://github.com/Yyilin001/IMMonorepo/blob/21fb3cc8/docs/reviews/actor-realtime-routing-evidence.md)。

### 写连接等待的请求窗口归因

`analyze_v2_actor_realtime_hotspots.py` 的每个阶段增加 `readyWaitDiagnosis`。
分析对象为日志中写连接等待至少 20 ms、完整落在共同测量窗口内的房间请求。
日志本身包含慢请求和固定采样，因此这里的 P50/P95/P99 **只属于这些诊断请求**，
不是全量消息分位数。每个分类使用相同的请求集合，未发生的分类贡献为 0。

等待终点与 `owner_ready_wait` 一致：实际驱动交出连接。随后选取房间的耗时
单独记录，不能计入等待归因。分类总和必须等于该请求的原始等待；不闭合的
记录计入 `incompletePartitions`，不进入分位数。越过阶段边界的记录另行排除。

| 分类 | 实际观测状态 |
|---|---|
| `ready_pool_fully_borrowed_sum` | 所有写连接都已进入驱动借用闭包，尚未归还 |
| `ready_slots_full_task_pending_sum` | 调度名额满，尚未获得连接的票据均等待任务开始 |
| `ready_slots_full_pool_request_pending_sum` | 调度名额满，未获得连接的票据均已运行但尚未发出池请求 |
| `ready_slots_full_assignment_pending_sum` | 调度名额满，未获得连接的票据均等待分配结果发布 |
| `ready_slots_full_callback_pending_sum` | 调度名额满，未获得连接的票据均等待分配回调开始 |
| `ready_slots_full_driver_pending_sum` | 调度名额满，未获得连接的票据均等待驱动借用闭包进入 |
| `ready_slots_full_mixed_pending_sum` | 未获得连接的票据处于不同阶段，无法归为单一原因 |
| `ready_slots_full_unknown_pending_sum` | 旧记录或缺少阶段标记，无法判断借用停在哪 |
| `ready_slots_full_return_pending_sum` | 连接已归还，但仍占用调度名额 |
| `ready_slot_available_sum` | 调度器有可用名额；不等于物理池必定有空闲连接 |
| `ready_diagnostic_history_missing_sum` | 有限历史已淘汰，不能判断该区间 |

分类说明资源状态，不单独证明根因：例如分配等待还可能来自池准入、续租预留
或回调推进；任务等待不证明 CPU 全局满载。全忙时须继续结合现有
`owner_begin/write/commit_future`、`owner_begin/write/commit_resume`、
SQL 间隔及 PostgreSQL 等待事件判断连接为何被占用。这些子阶段与连接等待
属于不同维度，不能全部相加。

所有边界采用 `ContinuousClock`；借用票据可由另一个房间先触发，关联后只取
当前请求窗口内的交集。历史最多保留 512 个已结束票据；区间分析采用事件扫描，
只重算状态发生变化的票据，在调度器锁外完成，不为每个边界扫描所有票据。
旧日志仍能分析粗分类，但缺少新标记时不得回填具体任务或回调归因。

### 写连接执行路径的前三项调整

消息写入的分配回调在获胜物理 gate 的 EventLoop 上直接进入对应数据库，
不再先等待 facade 上的 assignment Future 回调。只有最终 Sendable 结果回到
稳定的 facade Future；普通 Fluent 泛型接口保留原有结果隔离。

借用轮次由调度器持有的普通全局执行器任务启动；不提前选择数据库 Executor。
拿到物理连接后，只有连接回调内的事务任务偏好实际连接的 EventLoop。
连接归还后，原借用任务直接等待通知和内存收尾，不额外创建收尾任务。
shutdown 仍等待房间收尾完成，同房间下一轮仍不能越过未完成的提交后状态更新。
执行器归属由真实 EventLoop 回归验证，不能仅凭清除 preference 推断。

不可变命令的排序键、操作键、UUID、授权索引键及成功记录指纹十六进制表示
在调度入队之前准备一次。权限执行上下文在执行时读取，不缓存权限判断结果；
提交时间、房间序号和结果仍在原来的事务边界生成。消息内容协议未改变，
房间事务没有合并，连接预算未增加。

### 传输拆包与房间消费者等待

NIO 通道处理器在自己的 EventLoop 上用现有有界解码器拆包，只将完整帧
交给业务 Actor。半帧保留在传输解码器中，不创建业务处理任务；达到批次上限
时先排空残留再消费后续 TCP 数据块。认证协商完成后才放宽发送帧限制。
Data 接口保留原解码器，两种入口复用相同业务分发；连接背压及发送在途预算不变。
EOF 半帧校验只在完整批次已经排空时执行，业务期间断连留下的合法排队帧不被误报。

房间 trace 新增三段，它们的总和等于 `room_queue_wait`：

- `room_queue_before_consumer_request`：请求入队到消费者启动被请求前的区间。
- `room_consumer_start_wait`：当前请求等待区间与消费者任务从创建到开始运行的交集。
- `room_queue_after_consumer_start`：消费者开始运行后，当前请求到实际分发前的区间。

启动等待以外的两类队列区间可能包含既有轮次、屏障和收集窗口，不能直接视为运行时调度
或数据库执行时间。原消费者仍是同房间唯一轮次执行入口。

### 连接分配等待细分

`owner_pool_assignment_wait` 从池请求发起到获胜分配发布，细分为互不重叠的区间：

| 阶段 | 边界 |
|---|---|
| `owner_pool_before_winning_gate` | 池请求 → 获胜 Gate 请求；包括候选探测，换池时还包括原池等待 |
| `owner_gate_request_preparation` | Gate 请求 → 开始申请 Gate 锁；包括 UUID/Promise 准备 |
| `owner_gate_lock_wait` | 开始申请锁 → 进入锁内 |
| `owner_gate_admission` | 进入锁内 → 准入完成 |
| `owner_gate_capacity_wait` | 准入完成 → 容量批准；排队请求包含真正的容量等待 |
| `owner_gate_grant_to_promise` | 容量批准 → 准备好完成交付；合并路径随后提交一个 EventLoop 作业 |
| `owner_gate_delivery_wait` | 完成交付准备 → 获胜回调进入；原路径包含 Promise 投递及 Future 回调登记，合并路径包含单次 EventLoop 交接 |
| `owner_pool_publish_work` | 回调进入 → 发布分配；包括借用协调器锁及换池取消 |

仅获胜 lease 的时间戳进入统计，丢失竞态的 grant 不重复计数。时间戳随 lease
传递，不增加 Future 回调；统计在连接结束、watchdog 解除后汇总，避免在交付路径
逐项记录指标。阶段区间基于同一 ContinuousClock，子阶段总和应等于该请求的
assignment wait。延后汇总的窗口计数可能与父阶段略有边界差异。

`owner_gate_off_loop_delivery` 与 `owner_gate_on_loop_delivery` 是按批准时是否位于
该池 EventLoop 分类的子集；它们的 count 用于说明比例，不是额外阶段。
`owner_gate_callback_registration` 和 `owner_gate_registered_to_callback` 将 delivery
分为提交后发起回调登记前、以及其后的区间；后段不应直接当成纯 CPU 时间。
`owner_gate_queued_capacity_wait` 只统计真正入队的获胜请求；
`owner_pool_peer_before_gate` 只统计换池获胜请求的前缀等待。这些子集不能与父阶段相加。

消息借用器的立即授予与 peer 立即授予使用合并交付：请求状态安装后，单个实际池 EventLoop 作业完成 Gate Promise 并调用借用器。真正排队及通用数据库借用继续使用 Future 路径。指标边界保留，不把合并路径的交付等待误读为独立 Future 回调登记耗时。

### 消息数据库执行资源隔离

启用 `IM_V2_DATABASE_WORKLOAD_POOL_ISOLATION_ENABLED` 后，Gateway 通过 `V2DatabaseWorkloadResources` 分别持有消息与控制数据库资源：两套 Fluent 驱动注册容器、线程池和 EventLoopGroup。消息池使用 `IM_V2_DATABASE_EVENT_LOOP_THREADS` 条循环；前台读／控制、同步、投递、投影、维护及独立路由／权限控制池使用 `IM_V2_DATABASE_NON_MESSAGE_POOL_EVENT_LOOP_THREADS` 条控制循环。它们不再共享同一组循环的前缀，连接预算算法不变。关闭隔离的显式共享池模式继续使用原资源布局。

R79 使用两条消息循环、四条消息写连接，另有一条控制循环；数据库 EventLoop 总数从每 Gateway 两条增加到三条，六节点共增加六条。独立资源容器各有自己的两线程 NIOThreadPool；不将“数据库 EventLoop 总数”当作进程总线程数。两组仍共享机器 CPU、内存及 PostgreSQL，不能据此宣称完全没有资源竞争。

公平写调度、Gate、单次实际消息 EventLoop 交付和同房间串行边界保留。事务任务继续只偏好实际借用连接的消息循环；不可变命令排序、身份／指纹准备在借用前完成，连接归还后由全局获取根任务等待内存和结果收尾，没有新增中间 Actor、Task 或 Future 队列。SQL 绑定和依赖数据库结果的计算仍在事务边界内，不声称消息循环只运行裸 I/O。

关闭顺序为上层 Actor／Worker／loan 排空，随后关闭每套驱动、线程池及其所属 EventLoopGroup。资源关闭幂等；其中一套失败仍会尝试关闭另一套。启动或组装失败同样清理两套资源。


### 有界详细链路诊断（R87）

服务默认按消息操作 UUID 稳定采样 1/64 的详细链路；Gateway、房间 RPC、房间 Actor 的选择一致。每条请求的阶段计数与质量校验仍为全量。采样不包含的慢请求不产生详细 spans 或等待历史分类，避免拥塞时诊断计算和日志量随慢请求比例增长。维护探针沿用原来选择。

`IM_V2_SEND_PATH_TRACE_MODE=all` 恢复原有全量采集及慢请求日志选择，适用于短时间诊断；压测入口对应 `--candidate-send-path-trace-mode all`。默认参数为 `sampled`，实际模式写入 `evidence.json` 的 `candidateSendPathTraceMode`。与之前全量诊断轮比较时必须注明这个变化；采样 trace 不代表所有请求的分位数，整体延迟仍取负载器报告。


### 消息 SQL 模板准备缓存（R90）

仅消息写角色启用自动预备语句缓存，匹配固定消息追加注释前缀。缓存归属物理连接，键包含完整 SQL 和绑定参数类型，每连接最多 16 个模板；库默认关闭、最大允许 64 个。满后使用原未命名查询，连接关闭时随服务端会话释放。首次模板准备有额外往返，后续复用解析结果；计划是否复用仍受 PostgreSQL 默认 auto 策略控制。

`IM_V2_MESSAGE_WRITE_PREPARED_QUERIES_ENABLED=false` 或压测 `--candidate-message-write-prepared-queries disabled` 关闭此缓存，使用同一二进制比较。证据字段 `candidateMessageWritePreparedQueries` 记录实际选择。BEGIN / COMMIT、超时、取消及提交不确定恢复语义保留。


### 二进制 Actor 调用封装诊断

`--candidate-actor-binary-invocations enabled|disabled` 默认 disabled，控制候选所有 Actor 节点的 `IM_V2_ACTOR_BINARY_INVOCATIONS_ENABLED`。它替换分布式调用外层 InvocationMessage，并允许明确 opt-in 的 V2ActorSignedPacket 请求参数直接传递 body / signature 原始字节，避免 JSON / Base64 包装。认证 Call / Reply 的身份字段也使用有界二进制封装，UUID 用原始 16 字节；业务 request / response 载荷与 Hello / Grant 保持 JSON。Reply 仅对已验证的二进制 Call 选择二进制消息体，回复外层包装仍用原编码。签名始终覆盖实际传输的消息体，接收始终先验签后解码；证据记录 `candidateActorBinaryInvocations`。升级后的 fork 同时接收原 JSON 与二进制格式，启用出站前所有接收方必须已升级。性能比较必须使用同一二进制分别开关，并保留相同负载节奏、在线数、连接预算和质量门槛。


权限控制池可通过 `--candidate-policy-control-connections N` 单独对照（每节点控制 EventLoop 的连接数，默认4），证据字段为 `candidatePolicyControlConnectionsPerNode`。服务端对应可选环境变量 `IM_V2_DATABASE_POLICY_CONTROL_CONNECTIONS_PER_EVENT_LOOP`，未设置时保留原有预算推导；设置后仍须满足进程总连接预算校验。该选项不改变消息写池或前台读池容量。比较时保持在线数、负载节奏、消息连接预算、测量时长和质量门槛不变；冷加载排队下降本身不代表吞吐容量通过。


### 失败后的有界报告收集

`--loader-report-drain-seconds`默认120秒，可设1—600。首次loader非零退出后，服务继续运行，其他loader按原工作负载结束并写报告；后续失败不延长期限。原总超时、服务异常退出和质量门槛保持生效，任何loader非零仍令整轮失败。`candidate/loader-report-collection.json`（或baseline目录）记录失败分片、期限是否超时及缺失报告。期限到达时执行原清理，报告可能仍不完整，不保证挂死loader生成报告。

失败分片退出后实际负载可能降低，因此报告齐全的失败轮也不作为容量通过证据。连接warmup仅保证既有连接/房间条件，不保证发送权限scope与SQL全warm；发送预热诊断应另列，并记录测量期残留冷读取。3000/3500交替复测与发送预热诊断结果见`docs/reviews/send-throughput-5000-20261008.zh-CN.md`的R138—R143。


### 写连接归还时的同步调度边界

owner_return_callback_wait、owner_return_lock_wait、owner_return_lock_to_release分别测pool_returned→同步归还调用、调用→dispatcher锁进入、锁进入→额度释放；owner_return_schedule_work测释放额度后的锁内调度，不属于owner_pool_return_to_resource_release。等锁时间包含实际Mutex竞争与线程未及时运行，不能单凭耗时证明锁持有方执行了同等时长。房间内存热路径已采用短同步Mutex操作，首次SQL仍single-flight且在锁外等待，提交后才推进游标。R145 / R146的3000对照见性能记录。
