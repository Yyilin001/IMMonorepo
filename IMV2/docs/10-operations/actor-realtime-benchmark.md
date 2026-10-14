# Actor 实时路由本地压测

当前 Gateway 使用房间 Actor 独立排序、内存权限判断和房间独立事务。实例归属由三个原生多数派控制节点确认；正常转移等待实际排空，崩溃接管由 Supervisor 排除旧进程并收尾数据库会话。房间不使用 SQL 实例租约或逐房间续租。部署与故障验收见 [Room Host 监督部署](room-host-supervision.md)。

## 构建与夹具

使用同一 Swift 工具链构建最新 Release。Runner 不自动构建，并在启动前核对负载器的协议与算法摘要。二进制路径应来自对应构建的 `swift build --show-bin-path`。

```sh
cd IMV2Server
swift build -c release --product IMV2ServerApp
swift build -c release --product IMV2AccountServerApp
swift build -c release --product IMV2PlacementControlApp
swift build -c release --product IMV2GatewayLoadGenerator
cd ..

python3 IMV2/scripts/prepare_v2_actor_realtime_direct_fixture.py \
  --output-dir /tmp/imv2-direct-ring-fixture \
  --seed 4a5a8a27-cb40-5627-a0b9-3bcfb21ebec1 \
  --foreground-paired

python3 IMV2/scripts/run_v2_actor_realtime_benchmark.py \
  --kind candidate \
  --fixture /tmp/imv2-direct-ring-fixture \
  --output-dir /tmp/imv2-direct-ring-current \
  --candidate-binary /path/to/release/IMV2ServerApp \
  --candidate-account-binary /path/to/release/IMV2AccountServerApp \
  --candidate-placement-binary /path/to/release/IMV2PlacementControlApp \
  --loader-binary /path/to/release/IMV2GatewayLoadGenerator
```

夹具默认有 50,000 个账号、设备和直聊房间。用户 i 与 i+1 是房间 i 的成员，每个连接保留两个目标、一个前台详情订阅。`--foreground-paired` 使相邻双端共享第一目标，形成 25,000 个双端前台房间。不要将全部房间数量解释为同时具有双端订阅的房间数。

若要运行 10,000 在线诊断，生成夹具时添加 `--users 10000`，运行时指定对应 `--scenario`、`--allow-scaled-diagnostic` 和 `--measurement-phase`。包含发送预热的场景必须明确指定测量阶段；连接订阅预热不等于房间发送状态与权限已经预热。

正式默认场景为 `high-active-50000-uuid-ab-5000.json`。缩放诊断保留完整质量检查，但不等于正式容量验收。历史版本对照可使用 `--kind both` 和三个 `--baseline-*` 参数；旧 wire45 适配只属于测量工具，生产端严格使用当前协议。

## 纯在线诊断

使用 `--online-only --allow-scaled-diagnostic --measurement-phase online-idle`，场景选择
`IMV2/load-scenarios/online-only-idle.json`。该模式只登录、保持 TCP 连接和正常心跳；不创建聊天房间、不建立前台房间订阅、不发送消息、不主动补拉、不注入重连。全部负载分片到达共同屏障后，观察 180 秒。

前台数据库池采用弹性续期预算：空闲续期名额可以借给认证与接纳，续期排队后优先取得归还的连接；不会增加物理连接上限或提前回收执行中的连接。新连接接纳保留用户、设备锁及全局连接数限制，事务正文只有锁查询和合并接纳查询两次往返。认证、接纳、续期的借用观测分别标记为 `authentication`、`presence_admission`、`presence_renewal`，避免用通用来源推断具体业务耗时。在线投影续期使用每连接一项的可更新到期堆，撤销时删除该项，临近到期工作合并在最多 10 ms 的调度窗口内；TCP 心跳不会等待该投影写入。

启用数据库工作池隔离时，消息写入、前台认证／控制、后台工作分别拥有独立的数据库 EventLoopGroup。前台组线程数仍取非消息数据库线程配置，各池连接预算保持原值；后台借用队列的超时处理不再占用认证连接所属的 EventLoop。主机资源采样同时记录网络缓冲分配拒绝计数和文件句柄使用量，不能把这两类系统资源耗尽误判为 SQL 执行慢。

纯在线观测完成后，负载器先在全部连接上停止新心跳，等待已经发出的心跳得到 ACK，再开始分批断开；等待沿用心跳原始期限，拒绝、超时或断连仍记录为漏心跳并使验收失败。每个场景阶段单独记录心跳发送、确认、漏心跳计数，整体报告也保留完整生命周期计数，验收条件不会因主动退出而放宽。

该模式使用独立的在线质量判定：达到目标连接数、完整共同观察窗口、零接入／业务失败、零心跳漏应答，并由负载器报告确认没有房间或消息工作。它不要求消息 ACK 或前台消息追平，不作为消息吞吐验收。启动前额外等待六个 Actor 服务资格就绪；服务退出与停机排空仍单独记录。夹具生成工具允许最多 100,000 个测试账号，每个负载分片仍受原有 10,000 连接上限约束。固定源端口范围与本机其他监听器冲突时，可用 `--loader-excluded-local-ports` 指定需要跳过的端口；不停止其他应用，也不放宽失败质量标准。

## 服务与资源配置

Runner 启动 6 个 Gateway/RoomHost、1 个 Account、3 个归属控制节点和 12 个负载分片。全部请求连接就绪后，Driver 释放共同场景屏障。连接与订阅预热、发送预热、测量、排空分别记录。

| 参数 | 当前默认值 |
|---|---:|
| 消息数据库 EventLoop／Gateway | 1 |
| 消息写连接／Gateway | 4 |
| 独立权限控制连接／Gateway | 4 |
| 前台读／控制工作池连接 | 4 |
| 同步／投递／投影／维护连接 | 1／1／2／1 |
| 非消息工作池 EventLoop | 1 |
| 临时 PostgreSQL 最大连接数 | 320 |

消息写连接总量由 `--candidate-message-write-connections` 指定，通过 `--candidate-event-loop-threads` 在 1 或 2 个 EventLoop 间平均分配，两者必须整除。消息写入使用实际写连接调度，不经过通用前台写准入。读、同步与后台任务使用隔离连接预算；数据库 CPU、WAL 和磁盘仍是共享资源。运行时实际配置和拓扑证据优先于历史报告中的连接数量。

默认 TLS 端口为 18443–18448，Actor 为 18337–18342，控制节点为 Actor 起始端口加 64–66，metrics 为 20464–20469。Account HTTP 为 18544，HTTPS edge 为 18643–18648，PostgreSQL 为 18532。端口都可通过参数更改。候选模式使用 Actor 传输；NATS 仅用于历史基线。

脚本创建独占 PostgreSQL 16 集群和随机名称的新数据库，安装当前 schema 并写入夹具标记。它不复用或清空既有数据库。输出目录必须不存在，数据与证据默认保留；结束后停止自建集群。`--drop-disposable-databases` 只清理本次带标记的数据库。`--shared-postgres` 显式使用已有集群，并只读检查连接上限。

消息发送和结果恢复使用真实 TCP。HTTPS edge 用于 Account 请求：每个入口最多 128 条上游连接，响应读取完成后复用，失败请求不自动重发。HTTP 代理校准不能替代 TCP 吞吐证据。

## 质量检查与故障边界

有效结果要求报告完整、测量窗口达到要求、连接覆盖证明通过、没有业务失败或队列溢出／遗弃、在途请求完成排空，以及全部前台视图追平已提交水位。吞吐使用测量阶段实际 ACK 和实际时长，不能使用配置速率或预热、排空阶段的 ACK 冒充。

消息提交后丢失 ACK 时，客户端按同一消息身份查询或重试，通过成功记录确认结果。数据库存在消息不等于客户端已经确认成功；恢复与实时投递需要分别检查。

本工具保留小规模通知丢弃、Actor 通道分区和 App 验收入口，其范围以 `--help` 和对应验证脚本为准。旧的直接 SIGKILL 后依靠自然 TTL 重启入口已经移除。原生 Host 崩溃接管由 `test_v2_native_host_crash.py` 验证，它覆盖 Supervisor、旧容器排除、数据库会话收尾和未知发送结果恢复。

## 按实际阶段定位热点

```sh
python3 IMV2/scripts/analyze_v2_actor_realtime_hotspots.py \
  /tmp/imv2-direct-ring-current/candidate \
  --phase rate-5000 \
  --output /tmp/imv2-current-hotspots.json
```

Analyzer 使用全部分片实际阶段的交集窗口，披露计数器边界偏移、缺样和重启。客户端 P50/P95/P99 属于各分片，不能直接平均成全局分位数。CPU 使用窗口内相邻采样计算，不能把预热峰值当成测量资源占用。

发送指标由 `V2SendOperationStage` 定义，已移除没有实际生产调用的旧授权路由、回执预检、证明写入和房间租约 SQL 来源标签。阶段输出在途、开始、完成、耗时总量和生命周期最大值。均值使用 `Δ耗时总量 / Δ完成数`；阶段调用可能处理整批消息或以错误结束，完成数不是消息成功数。

优先核对以下边界：

- `room_queue_wait`：房间轮次排队。
- `owner_ready_wait`：准备完成到数据库执行调度获准。
- `owner_connection_acquire`：实际连接借用。
- `owner_ticket_task_wait`：执行任务开始前的调度等待。
- `owner_single_statement`：单语句隐式事务完整周期。
- `owner_write_future`／`owner_write_resume`：SQL Future 等待与 Swift 恢复。
- `owner_pool_return_to_resource_release`：归还连接到调度资源释放。

完整周期与子阶段存在嵌套，不能相加当作客户端延迟。复杂消息仍可能使用显式事务及回退路径，BEGIN／正文／COMMIT 应按实际调用计数解释。SQL 来源中的 `*FenceRooms` 表示持久化数据归属校验，不是已移除的房间实例租约。

写调度诊断将等待拆分为实际连接全部借出、归还待处理、任务／分配／回调待运行和槽位可用等区间。采样只说明该请求的观测边界，不能单凭平均值判定锁竞争或运行时调度是唯一原因。

`capture_gateway_perf_when_busy.sh` 使用 `IM_V2_GATEWAY_OWNER_QUEUED_TURNS_THRESHOLD` 和 `im_v2_send_operation_owner_queued_turns` 触发采样，单位是等待调度的房间轮次。历史性能证据保存在 `docs/reviews`；历史 Collector、额度 tail、逐房间租约及旧指标不再作为当前操作说明。

### 纯在线心跳诊断

`--online-only --candidate-heartbeat-diagnostics` 开启服务端心跳分段观测。生产环境默认关闭；直接启动 Gateway 时对应 `IM_V2_GATEWAY_HEARTBEAT_DIAGNOSTICS=true`。按完整连接 UUID 的进程内哈希固定选择约 1/64 的连接，该连接的全部心跳形成同一采样群体；不能只取轻量连接 UUID 的固定进程前缀。没有用户、连接或请求身份标签，不新增执行任务。

`im_v2_heartbeat_stage_milliseconds` 分别记录入站批次到分发、任务启动、ByteStream／Session／Registry／LeaseController 入口与返回、ACK EventLoop 入口及本地写完成。`server_total` 与其连续子阶段嵌套，不能重复相加。入口和返回包含并发运行时调度；Actor 正文单独计时。入站时间是解码批次最后一次使用的通道入站回调，包含其排队，排除内核、TLS 和客户端处理；分片／合并帧应按该批次边界解释。

`cohort="slow"` 仅包含服务端总耗时至少 25 ms 的同一批已完成采样，便于比较长尾中的阶段占比。累计计数用实际测量阶段的差值分析；在新慢样本到来时淘汰 30 秒以前的例子，最多保留 16 条最大慢样本，以 `# im_v2_heartbeat_slow_example` 注释导出匿名阶段明细与完成时间，分析时仍须按阶段窗口过滤。失败采样独立计数，不混入成功耗时。ACK 写完成仅表示本地传输完成，不能视为客户端收到。

开启诊断及 CPU 栈采样的运行用于定位，不用于容量或优化收益对比。先测阶段边界，再在稳定在线窗口使用 `profile_v2_owned_benchmark.py` 或 Time Profiler 附加本次压测拥有的 Gateway，明确采样 PID 与时间窗口。

### Journal 控制恢复

在线连接注册时计算一次用户分区和二进制用户／设备身份；退出及注册回滚同步维护索引与本地控制版本。恢复只捕获目标分区的生命周期票据，快照安装仅更新该批身份。连接排序使用 UUID 字节，不反复格式化字符串。

远端恢复与本地冷刷新共用 `GatewayJournalRecoveryCoordinator`：同一 source、发布者、路由、会话与兴趣代次合并执行，最多四个实际恢复任务。晚到的更高 cut 或控制版本不能由旧结果完成，需要后续轮次。缓存只在当前绑定、截止时间、版本要求和本地连接代次仍有效时使用；取消一个等待者不撤销其他等待者所需的实际执行，关闭等待实际任务退出。

稳定代次的 checkpoint 落后时，优先在同一个恢复任务中回放最多四页、每页 128 条可信数据库 Journal。无关控制及已安装的旧版本可以推进进度；新权限版本、裁剪、序号缺口、不透明记录、过期绑定或新连接需要权威快照。源租约与路由检查仍保留，远端通知本身不能建立授权。

`im_v2_gateway_journal_recovery_total` 记录固定原因：请求、缓存命中、合并、实际执行、后续轮次，以及首次基线、代次变化、本地连接变化、版本要求推进、绑定不可用和回放结果。原因计数存在重叠；`executed` 才是实际执行轮次。压测对照需关闭心跳诊断和 CPU 采样，并保持全部连接及数据库配置相同。
