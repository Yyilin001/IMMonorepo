# Gateway Actor 实时推送实现与验收记录

状态：进行中，尚未证明完整业务正确性或达到原版 80% 性能。分支 `feat/actor-realtime-routing`，对照源码 `a72f25e52a7c7f985625fdc43044b10f7ef12318`。

本分支已接线 Gateway 接收 Actor、短期路由登记、全房间和个人同步持久唤醒、多端兴趣与登记后水位屏障、presence 权威刷新、typing 来源合并及托管关闭。候选默认 Actor，NATS 专用实现与部署服务已移除。schema 为 `im-v2-current-68`。这些改动仍需以下实际验收，不以源码存在判定完成。

## 已取得的证据

- 新 schema 全新建库、dump/restore、结构漂移及 readiness 表覆盖检查通过。
- 真实 PostgreSQL 路由测试 2 项通过：旧修订/owner epoch、过期租约和迟到清理不能覆盖新状态；个人日志提交产生持久水位，旧确认不能删除新修订。日志 `/tmp/imv2-actor-routing-db-final-tests.log`。
- 配置与账号房间变更测试 46 项、回调认证测试 1 项通过。日志 `/tmp/imv2-actor-runtime-tests.log`。
- 订阅修订、慢 peer 隔离和多端 typing 行为测试 3 项通过。日志 `/tmp/imv2-actor-routing-runtime-tests.log`。
- 两个真实独立 Cluster/mTLS 进程完成 32 次并发回调；owner 越权、旧 incarnation 和关闭后调用被拒绝。证据目录 `/tmp/imv2-actor-callback-live-20261001`。
- 最终受影响的 ByteStream/实时路由测试 28 项及回调认证测试 1 项通过，覆盖认证启动响应 `[2,3,0]` 顺序和水位合并。日志 `/tmp/imv2-actor-final-focused-tests.log`。
- 修复后的真实双 Gateway App/private hint 同场景复测通过；实际 UI 套件 3 项通过、1 项按场景跳过，脚本完成真实 HTTP 和持久设备效果核验并退出 0。证据目录 `/tmp/imv2-actor-multigateway-privatehint-20261001-r2`。
- 后续质量审查修复了迟到 owner 注册、启动/关闭竞态、重放窗口复制热点、出站正文预算和 SQL 并发限制；最终相关测试 39 项及认证测试 1 项通过。日志 `/tmp/imv2-actor-quality-final-tests.log`。独立进程 mTLS 回调最终版本再次通过 32 次调用及权限/旧代次/关闭拒绝，证据 `/tmp/imv2-actor-callback-quality-20261001`。
- 真实双设备跨 Gateway 场景通过：同账号两个不同设备同时收到房间变化，关闭其中一端后原端继续收到变化。证据 `/tmp/imv2-actor-multigateway-multidevice-20261001-r4`，标记 `IMV2_CROSS_GATEWAY_TWO_DEVICES_AND_SINGLE_EXIT_PASSED`；脚本真实持久设备计数与退出 0 一致。该场景通过真实回复建立双向私聊权限，未放宽陌生人发送策略。

上述路径是本机本次任务的日志位置；后续源码变更需重跑受影响验证，不将这些结果自动扩大到最终版本。

## 未通过与正在修复

实际双 Gateway App/private hint 验收首轮失败：认证连接的个人水位提示可能早于 `authenticated` 响应，客户端报 `unexpectedResponse`。生产 ByteStream 已增加响应写出后的通知就绪门槛及单条合并水位；Native 三步启动等待首个认证后响应写出才开放通知。修复后的同场景复测通过，首轮证据仍保留在 `/tmp/imv2-actor-multigateway-privatehint-20261001`。

性能预检的启动配置缺失、连接池预算不符与小 canary 的 loader 参数失败均不构成性能样本。原版已在独立 checkout 构建 Release；正式对照仍须冻结相同 fixture、负载与编译参数，分别运行原版和候选。

120 用户直聊环预检新发现负载发送依赖 Account HTTPS API；只有 Gateway 的 runner 两版均没有消息 ACK，不能作为性能样本。证据 `/tmp/imv2-actor-direct-canary-20261001-r1`。正在补齐两版 Account 服务、统一 HTTPS 入口及数据库连接预算后重跑。50k 夹具及两版 schema 的导入核验通过，并不代表容量通过。

预检 r2 查明夹具缺少 `user_direct_send_policy_versions`，两版均正确返回 permissionDenied；另有独立连接池使共享 PostgreSQL 100 连接不足。新冻结 policy 夹具、完整 Account/HTTPS 入口和独占 PostgreSQL 后，r3 两版均取得 996 ACK、零业务失败并完成排空。原版通过实时正文直接应用，无须补拉；候选通过正文及补拉交付。证据 `/tmp/imv2-actor-direct-canary-20261001-r3`，仍仅为 120 用户启动预检。

负载工具原本每条消息新建并关闭 HTTPClient，校准暴露临时端口消耗；已改为整轮共享且有界的 256 连接 HTTP/1 池，两版共用同一个 Release Loader。HTTPS edge 使用有界 128 上游复用池；独立回显校准约 58k 请求/秒，仅证明入口余量，不能作为业务性能。正式测量还增加全分片共同启动屏障、实际阶段时长、共同窗口校验和服务端 metrics 采样。

最终双端前景 120 用户预检：两版各 996 ACK、零业务失败、共同测量窗口 20.01 秒并排空。独立 PostgreSQL 核对两版全部 120 个前景接收者的游标均等于持久 room_sequence，无缺失、落后或超前。证据 `/tmp/imv2-actor-direct-canary-final-20261001`。该结果不计入正式 80% 容量门槛。

正式 50k/5000 r1 在连接爬升期间失败，消息发送尚未开始：原版认证 22,081、候选 14,280，主要客户端错误为 `Can't assign requested address` errno49。实际 macOS 临时端口范围为 49152–65535；尚未取得有效性能样本。证据 `/tmp/imv2-actor-direct-5000-20261001-r1`。共同 Loader 新增显式来源端口与 SO_REUSEADDR；跨不同目标端口的真实套接字复用验证通过，同 tuple 立即重连失败 errno48，因此每次连接/重连使用单调新端口，不回绕。Driver 对每 Gateway 的两片使用 25000/35000 两个独立 10k 范围，下一版运行前等待本工作负载旧 TCP tuple 退役，不修改系统参数。

## 剩余完成条件

正式 r2 在显式绑定阶段发现并行未连接 socket 的来源端口竞争，主要为 bind errno48，消息阶段未开始。证据 `/tmp/imv2-actor-direct-5000-20261001-r2`，已中断无效场景并完成自有服务清理。真实 socket 复现证明 `SO_REUSEADDR` 不能覆盖“多个进程先绑定、后连接”的窗口；增加 `SO_REUSEPORT` 后 6/6 先绑定再连接不同目标成功，重复四元组仍返回 errno48，证据 `/tmp/imv2-source-port-concurrent-proof-20261001.json`。共同 Loader 采用两个选项并记录到报告；Driver 在任意 Loader 非零退出后立即取消不完整场景。

正式 r3 已无绑定错误，但两个 Loader 各突发 200 条连接超过本机 128 监听队列，出现 reset/握手 EOF；独立 100 轮并行复用验证 600/600 目标身份正确，无错配，证据 `/tmp/imv2-source-port-parallel-connect-proof-20261001.json`。共同建连批次改为 32、每片建连目标仍为 200/s 后，r4 两版全部认证 50,000 条、连接失败零，证明连接资源问题已消除。

r4 尚未开始消息阶段，订阅预热失败：两版交互读队列均触达每节点 8 在途/384 排队上限，房间订阅 `UNAVAILABLE` 失败分别为 31,718 和 37,049 次。启动预热默认每片每秒突发 200 用户，已改为共同 `--workload-ramp-per-second 16`，不更改正式 rate-5000 场景。Loader 增加协议类型/错误码诊断，不输出正文或令牌、不改变失败门槛。r5 因 root 启动命令误传候选 Account 二进制路径，在启动阶段中止并清理；不计入性能结果。r6 使用正确参数和新独立目录 `/tmp/imv2-actor-direct-5000-20261001-r6` 运行。尚未获得有效 80% 对照结果。

r6 基线实际完成 50,000 条认证连接和 50,000 次前台订阅；3,472 次订阅暂态拒绝全部恢复，没有订阅终端失败。进入 rate-5000 后约第 12 秒出现 HTTP 终端失败，取得 5,292 个消息 ACK，未完成共同正式测量窗口，候选尚未运行。实际热点为单 Host 写排队：第 9.39 秒 GW5 写队列 573，其他节点接近零；第 24.64 秒 GW5 写准入超时累计 617，其他节点零。6 个 edge 上游池全部占满，末段 p95 约 8–11 秒，完成响应主要为 200，只有一条 503；不能把通用 HTTP 失败等同于权限拒绝。Account 日志没有足够应用细节，PG 日志未见错误，但没有 PG CPU 采样，因此尚不能排除其他放大因素。生产优化开始针对等容量 Host 的冷恢复集中，原版 checkout 保持冻结；新增 HTTP 闭合错误码及 PG 轻量采样以核对下一轮瓶颈。

冷恢复优化已落地：同容量候选使用固定 domain/版本 SHA256，对 roomID 与稳定 hostID 做长度前缀编码，incarnation 不参与，已有有效租约保持优先。目录 18 项、路由生命周期 3 项、认证 1 项测试通过，日志 `/tmp/imv2-actor-placement-focused-tests.log`；Gateway Release 构建通过，日志 `/tmp/imv2-actor-placement-release-gateway.log`。模块分析重新生成，forbidden edges=0、cross-target SCC=0。这些验证证明选择行为和编译正确，不证明性能门槛通过。

候选 Account 和共同 Loader Release 构建也已通过，日志 `/tmp/imv2-actor-placement-release-account.log` 与 `/tmp/imv2-actor-placement-common-loader-release.log`。r7 使用同一冻结 50k 夹具及正式场景单独运行优化后的候选，证据目录 `/tmp/imv2-actor-direct-5000-20261001-r7`；单版运行不会自动产生跨版 80% 验收通过结果。正式测量期间不执行共享机器上的构建或测试。

r7 已结束并清理自有进程：50,000 连接及订阅就绪，rate-5000 共同窗口仅 20 秒，3,765 ACK、49,693 HTTP 终端失败、573 次客户端队列溢出，638 个前台游标落后。目录优化使负载在六个 Host 上分散，但六节点仍同时写排队，性能验收未通过。该 HTTP 错误当时只精确到 AsyncHTTPClient.HTTPClientError；已进一步区分请求 deadline、连接池与网络超时等封闭错误码。

r7 保留库只读统计：room_activation_leases 更新约 151 万次、user_live_presence_leases 更新约 80 万次，消息插入仅 4,253 次；无消息屏障末段约 5,887 事务/秒。房间每 5 秒逐条续租，且续租与业务写入锁相同围栏，是明确的背景事务放大来源；原采样的 49 个 Lock 等待没有 relation/blocker 链，不能断言全部等待源自续租。下一轮新增 relation/mode/granted 聚合及 blocker/事务年龄采样，不采 SQL 正文或参数。保留库诊断使用独立只读 PostgreSQL 实例，已停止，未修改共享 PostgreSQL。

当前生产改动补齐账号目录 128 项批量登记及提交后集合授权 head 屏障，并将房间续租合并为有界批次（至多 128 项、2ms 收集窗口、2 个真实 SQL 并发，保持原 TTL 与完整围栏）。新增回滚边界修复防止取消批次误撤既有兴趣。统一验证结果及新版本构建见下文。

统一验证最终通过：32 项账号通知、路由与真实 PostgreSQL 测试，另有目录 18 项、认证 1 项，日志 `/tmp/imv2-actor-batch-and-renewal-focused-tests-r3.log`。真实 PostgreSQL 的 129 并发续租以 trigger 写入的事务编号证明有界共享提交；错误 owner/旧 incarnation/过期/非法标识不能续期，并不影响同批有效令牌。构建首轮缺少合适模块 import 已修复；第二轮测试被 internal 128 与旧本地 index 100 上限不匹配所阻塞，现以无挂起的本地分片安装保持公开 100 上限，真实登记与授权头仍单次 128。失败日志保留，不算通过。

真实双 Gateway、多设备及退出单端业务验收已经通过，生产代码最终候选构建和受影响回归已经通过。剩余为本地 5000 messages/s 档正式对照及原版至少 80% 门槛，并审阅实际资源和最终投递证据；若不达标，检索主源资料、优化并重新测量，仍不达标时用实际瓶颈证据说明。未执行的扩展故障矩阵仍须单独标明，不能以局部绿色测试代替。完成前不宣称整个迁移或性能目标已经达成。

最新批量版本 Gateway、Account、共同 Loader Release 构建均通过，日志 `/tmp/imv2-actor-batch-renewal-release-{gateway,account,loader}.log`。真实 App 双 Gateway/两设备/退出单端回归 r5 通过：HTTP 5 项、UI 3 项通过及 1 项场景跳过，跨 Gateway 两设备标记与持久结果校验通过，证据 `/tmp/imv2-actor-multigateway-multidevice-20261001-r5`。新正式候选 r8 使用同一冻结 50k 夹具及 5000 场景，目录 `/tmp/imv2-actor-direct-5000-20261001-r8`；运行结果待核，不宣称容量通过。

r8 候选正式阶段失败且 driver 非零退出，已清理自有服务。全部 50k 认证和订阅通过，正式共同窗口约 20.019 秒，4,392 ACK、49,413 终端业务失败（46,343 HTTP 连接池超时、3,070 deadline）、584 客户端队列溢出、880 放弃。没有有效 80% 比较。phase 内 PG 有 23–40 Lock 等待，事务编号等待仍需进一步归因；`realtime_gateway_leases` 48 tuple 等待发生在失败后 cleanup，不可作为正式阶段主瓶颈。早期观察必须按场景时间线解释。

真实 PostgreSQL 路由 suite 增补至 4 项并通过，日志 `/tmp/imv2-actor-route-commit-lock-races.log`：AFTER INSERT advisory 屏障确认登记提交前不可见/实际提交后可见；持 node row lock 并确认等待者事务已开始后，以数据库时钟让租约过期，再释放锁，旧令牌不能激活或续期。每个失败分支释放屏障且等候真实 SQL 结束。

真实在途 mTLS 回调关闭实测通过，证据 `/tmp/imv2-actor-callback-inflight-drain-20261001`：offer 已在远端受控进入时，短 deadline stop 未排空、后续新 send 拒绝；第二次 drain 在 offer 释放前不得完成，原调用实际 accepted 后才 drain true。仅测试 ingress 使用有界屏障，不加生产钩子。

同设备跨 Gateway 旧连接仍 open 的并存与旧清理隔离已通过真实 App r6：同 token/device 在另一 Gateway 建立第二条连接，实际 RecoveryRunner 补拉并持久游标后关闭旧端，后续在线消息及另一设备同步仍通过；marker `IMV2_CROSS_GATEWAY_SAME_DEVICE_OVERLAP_AND_OLD_EXIT_PASSED`。HTTP 5 项与 UI 3 项通过、1 项场景跳过，证据 `/tmp/imv2-actor-multigateway-multidevice-20261001-r6`。该证据不冒称真实网络黑洞或心跳 TTL 过期。

原版 r9 使用冻结 a72f25e Release、与 r8 相同共同 Loader、50k 夹具和正式场景，新增诊断仅输出固定查询类别和锁类别，不输出 SQL 正文/参数。预热出现真实 `DistributedCluster.DeadLetterError`，Gateway 因 request_failure 关闭一条连接；metrics 为 49999，只有 11/12 分片 ready。尚未进入消息阶段，root 主动 SIGINT 停止无效场景，driver exit130 并清理自有服务。失败汇总 reportCount=0 表示缺少 Loader 最终报告，不表示实测认证零。证据 `/tmp/imv2-actor-direct-5000-20261001-r9`；原版 r6 曾完成全部 50k 预热，但进入 5000 后也失败。

持久崩溃恢复首轮 room 夹具的 UUID 规范化错误已修正，失败证据保留。进一步修复生产个人 Publisher 的路由规范化缺陷：Postgres wake 输出小写 UUID，但登记与载荷使用 typed canonical ID，原先可能查不到接收者；现在路由与载荷同用 `user.rawValue`。针对实际丢通知路径的回归验证通过，5 项路由 suite 日志 `/tmp/imv2-actor-canonical-user-wake-tests.log`。

真实 room 与 user outbox SIGKILL 恢复均通过，证据 `/tmp/imv2-actor-outbox-kill-room-20261001-r2` 和 `/tmp/imv2-actor-outbox-kill-user-20261001-r2`。schema 67 的 INSERT trigger 在实际 COMMIT 中生成事实和水位；生产 Store、Relay、Publisher、Fanout 经 mTLS offer 进入远端后杀掉源进程，确认事实仍一份、outbox 仍 leased。等待真实 15 秒认领租约过期后，新端口和 incarnation 的后继生产 Relay 重领并发布，最后 outbox 清零、receiver 租约 retired。该证据证明持久通知恢复，不扩大为完整 App 正文提交路径或完整故障矩阵。独占 PostgreSQL 18539 已停止，未动共享 5432。

最新规范化修复后的 Gateway、Account Release 构建通过，日志 `/tmp/imv2-actor-canonical-user-release-{gateway,account}.log`。正式候选 r10 使用同一 50k 夹具、5000 场景和共同 Loader，目录 `/tmp/imv2-actor-direct-5000-20261001-r10`；实际结果如下。

## 本轮最终结论

分支 `feat/actor-realtime-routing` 已完成本轮 Actor 路由实现和上述功能验证；容量验收未通过，不能宣称达到原版 80%。r10 的 50,000 条连接全部认证且连接失败、心跳漏报均为零，但消息阶段仅完成约 20 秒：5,032 ACK（实际部分窗口约 251.47/s）、48,690 终端业务失败、578 次队列溢出、908 次放弃；未完成规定 90 秒正式窗口或成功排空。实际数据库游标核对 50,000 个接收者，无缺失或超前，但 504 个落后。Driver 非零退出并停止自有服务。见 `candidate/result.json` 与 `candidate/foreground-delivery-proof.json`。这些部分窗口指标不能用于有效跨版比例；冻结原版 r6 的 5000 消息阶段也失败，r9 则因预热连接关闭未进入消息阶段。

已按主源资料优化并重新测量：等容量房间宿主的确定性分散、账号目录有界批量登记、房间续租共享批次及真实 SQL 并发上限均已落地；HTTP 入口复用、来源端口与共同预热也完成校准。候选 r7/r8/r10 仍未通过正式容量门槛，因此停止把部分窗口的 ACK 增长当成验收成功。

剩余瓶颈的证据边界：r8 的 49,413 次终端 HTTP 失败已闭合分类为 46,343 连接池超时和 3,070 deadline；r10 正式阶段 PG 阻塞采样约 22–28 个后端，其中明确观察到 `shard_admission_pools` 未授予的 tuple ExclusiveLock（一次 9 个）。源码中消息 operation transaction 仍对共享 `(shard, profile)` 命令额度行执行 UPDATE，并持有锁直到 receipt 所属事务提交；这是多房间写入发生争用的明确来源。阻塞者同时持有消息、额度和房间围栏关系锁，不能将全部事务编号等待归因到同一行。CPU 采样也不足以证明整机 CPU 饱和。需要对持久消息准入/receipt 事务做单独设计和测量，不能通过绕过额度、持久提交或围栏来“优化通过”。

r10 采样器原来的 query_category 正则误把 UPDATE 内的 SET 分类为 transaction_control，因此该字段不能证明 COMMIT 热点。现已修正为入口锚定且优先表分类，并用采样器同一 CASE 在独占 PostgreSQL 18539 执行 6 项真实 SQL 自证全部通过，证据 `/tmp/imv2-actor-sampler-category-self-check-20261001.json`。没有改写 r10 历史采样或补造 SQL；实际锁表、tuple 模式、事务年龄和时序证据仍有效。自证后独占库已停止。

数据库锁解释依据 PostgreSQL 16 官方 [显式锁](https://www.postgresql.org/docs/16/explicit-locking.html)、[事务级锁](https://www.postgresql.org/docs/16/xact-locking.html)及[监控统计](https://www.postgresql.org/docs/16/monitoring-stats.html)。已完成的本地功能测试不扩大为完整 Linux、网络分区、慢链路或长期运行矩阵。性能门槛保持失败，本分支未合并或发布。

## TCP 优先路径复核（2026-10-01）

用户指出消息发送应优先 TCP 后重新核对：App automatic 的新提交使用已协商的 TCP `messageSendOperation`；历史 common Loader 固定走 Account HTTP。r1–r10 的 HTTP 超时和部分窗口吞吐不能当作 TCP 消息路径容量或最终热点结论，前节瓶颈解释限定于该 HTTP 负载。TCP 入口可进入 room sendOperation 批次，必须实测该路径。

本次 common Loader 改为真实 TLS/TCP 协商并发送 operation，校验 receipt 身份/指纹后才计 ACK；延期、拒绝、未知结果和有限同身份恢复分别统计。工具明确使用 TCP query 恢复；App automatic 恢复使用 HTTP，此差异在报告和操作说明保留。单次请求 20 秒与实际客户端默认一致；逻辑操作总预算 60 秒、最多 5 次 wire attempt，业务首次提交有效期继续独立为 24 小时。正式场景和质量门槛保持不变。

新的 pg-hotspot-v2 采样在独占 18539 以两个真实 PostgreSQL 会话争用同一行验证通过：实际 blocked_total=1、admission_credit 分类及 matching_transaction_id 关联正确。两个事务均 rollback，专用探测库已删除且独占 PostgreSQL 已停止。证据 `/tmp/imv2-actor-tcp-hotspot-sampler-proof-20261001.json`。新只读分析脚本严格使用实际 phase 交集，明确采样偏移、缺项和 counter reset；旧 HTTP r10 只用于验证排除 checkpoint/cleanup 的能力，不扩大为新 TCP 样本。


TCP canary r1 误用了旧 native Loader 产物，被新报告审计识别为缺少真实传输证明，qualityPassed=false，不能算 TCP 样本。更正为实际 Xcode Release 输出后，r2 两版各 996 WIRE_SUBMIT、996 ACCEPTED/ACK，120 条连接协商成功，零连接/业务失败及队列溢出，全部 120 个游标等于已提交头；6 个 HTTPS edge 的请求计数均为零。证据 `/tmp/imv2-actor-tcp-canary-20261001-r2`。候选的直播间隙已补拉追平，不将早期间隙计数隐藏或当成最终丢失。该小规模样本不计正式容量比例。

新增实际二进制 contract preflight，旧 Loader 在任何自有服务启动或输出目录创建前 exit2 被拒绝，证据 `/tmp/imv2-actor-tcp-old-loader-preflight-proof-20261001.json`。最终 Loader Release 构建通过，日志 `/tmp/imv2-actor-tcp-loader-contract-release-20261001.log`；功能消息代码与 r2 一致，追加的纯 CLI 描述用于阻止错产物。正式 TCP 候选使用原 50k paired 夹具和未降低的 5000 场景，证据 `/tmp/imv2-actor-tcp-5000-20261001-r1`，结果待实际核对。


正式 TCP r1 driver exit1：Gateway 实际共同屏障时 50k 全在线；一个 Loader 未形成最终报告，汇总只有 11 片/45,834 累计认证，不能据此冒称只有 45,834 条实际连接。消息共同窗口约 10 秒，整轮 524 ACK、45,386 业务失败且大量 UNAVAILABLE/SERVER_BUSY；未通过。末段未知关闭和 route row 锁包含 fail-fast cleanup，不能当作首因。另确认 Loader 的旧计划重连丢失在途命令、队列与旧游标，因此本轮不能作为修复后重连质量证明。

phase 内两份采样显示六 Host 的 foreground write 队列从数十增长至 606–635，执行/等待 7–8 在途，已完成准入等待均值约 3–3.47 秒。实际 PG 阻塞有准入池同 tuple 对象及 XID 链，随后四条房间 activation fence XID 等待；后台租约更新远高于消息插入。但仅两个样本，不能认定唯一锁热点、全部延迟来源或整机 CPU 上限；Actor 提交后推送未见先饱和证据。原始 `UNAVAILABLE` 合并内部原因，新增封闭诊断计数后需重新测量。

checkpoint active rooms 从 +1.54 秒的 25,662，降到 +57.7 秒 22,950、+119.02 秒 17,323、+175.21 秒 12,281；runtime 默认 idleTimeout=300 秒及逐步预热意味着正式负载混入冷恢复。这个时间序列必须保留，不能以“已预热”假定热态吞吐。对应只读分析输出 `message-hotspots.json`、`background-hotspots.json` 位于 TCP r1 目录。

新消息内部失败指标及原 wire 响应保持的 40 项相关测试通过，日志 `/tmp/imv2-actor-tcp-internal-failure-tests-20261001-r3.log`；前两次 native/global-parse 验证命令因 package 内不同可执行入口形式而构建失败，改回项目已使用的默认 build system 后通过，未修改无关可执行程序。Gateway Release 日志 `/tmp/imv2-actor-tcp-diagnostics-release-gateway-20261001.log` 通过。计划重连原子移交及 lost-ACK canary 实际结果见下文。

计划重连 canary r1 两版通过真实在途消息恢复，证据 `/tmp/imv2-actor-tcp-handoff-canary-20261001-r1`。r2 进一步限定 canary 每连接 1 个在途槽，保留第一个严格匹配的真实 accepted receipt、不应用 ACK，并在同一旧事件循环排入第二条消息，再原子移交。在两版各 12 次计划重连中，TRANSFERRED/RESTORED/RECOVERED_AFTER_RECONNECT 和 TRANSFERRED_QUEUE/RESTORED_QUEUE 均各 12；各 1020 次 WIRE_SUBMIT、1020 个 ACCEPTED/ACK，零业务失败、未知结果、队列溢出或放弃，全部 120 个最终游标等于数据库提交头。Driver exit0，质量门槛通过；显式小规模测试不计容量验收。证据 `/tmp/imv2-actor-tcp-handoff-canary-20261001-r2`，Loader Release 日志 `/tmp/imv2-actor-tcp-queued-handoff-release-loader-20261001.log`。正式模式仍使用 8 个在途槽且不注入故障。

## 完整 TCP 报告与热点定位（2026-10-01 r2）

正式 TCP r2 使用原 50k paired 夹具、180 秒 checkpoint、5000/s × 90 秒及原质量门槛，Gateway/Loader 使用实际 Xcode Release 产物。全部 50,000 连接认证、协商和订阅，消息阶段约 10.012 秒后 fail-fast，Driver exit1，12 份最终报告齐全；整轮 602 ACK，实际阶段 565 ACK（约 56.43/s）。整轮 49,203 workloadFailed、21 溢出、169 放弃，最终数据库游标 497 落后，无缺失或超前。不能通过容量验收或计算有效跨版 80% 比例。报告中的 39,643 OUTCOME_UNKNOWN_CONNECTION_CLOSED 包含退出清理，不作为首次失败原因；本轮 plannedReconnects=0，未触发重连移交。证据 `/tmp/imv2-actor-tcp-5000-20261001-r2`。

正式阶段前最近采样的新增内部失败均为零。+0.590 秒首先出现 13 次 submit `not_accepted.not_ready`，与 13 次 UNAVAILABLE 一致；当时 write timeout/queue_full 均为零。已确定执行前物理位置/房间就绪检查失败，仍不能唯一归因 Directory.confirm、ClusterClient physical ref 或 Host lane 的某个检查点。源码路径与内部指标均不能将其误称为 SQL timeout。

+5.784 秒 submit `not_accepted.overloaded` 6,835、recover 同类 4,681；六个调用端 Directory pending_resolutions 为 1,018–1,024，active_resolutions 全为 128，达到默认有界解析容量。Host pending 为 19–43、activation waiters 为 23–68、outstanding commands 为 1,824–2,031，远低其整体预算；因此当前直接可观察的执行前热点是 Directory 解析排队和拒绝。解析还包括已预热远端房间的 physical lookup，不能把这条路径全部称为冷启动，也没有瞬时 per-room 或 ClusterClient exchange 额度的排除证明。

同一采样六个 foreground_write 队列为 617–663，in_flight 为 7–8；累计 257 个 write admission timeout、零 queue_full，另有 326 个 submit `rolled_back.overloaded`。这是独立的持久执行准入排队热点，不能用它解释全部 11,516 个执行前 overloaded。真正 SQL 在首个 phase PG 样本出现 admission_credit 5 个等待，其中 4 条精确 XID 边指向一个准入业务事务；后一个样本出现 activation_fence 2 个等待，2 条精确 XID 边关联消息 owner 事务。r2 没有 phase tuple 对象证据，不能把 r1 的共享 shard pool tuple 观测假称本轮重复。

严格阶段内唯一相邻 5.194 秒 PG 窗口：约 5,995 xact/s、WAL 3.128 MB/s、PG 约 1.30 个核；room lease 更新约 2,649/s、presence 更新约 1,869/s，消息及 receipt 统计插入约 67.8/s（统计发布延迟，不等于精确提交吞吐）。checkpoint 末段仍约 3,504 xact/s、room lease 2,519/s、presence 1,495/s，说明背景维护不可忽略，但不能认定为唯一根因。六 Gateway 合计约 8.41 个核，Loader 约 0.30、Account 约 0.01、edge 0；没有证明整机 14 核达到硬上限。Actor realtime body_degraded/failed/admission_rejected 在已观察阶段保持零，不能据此扩大为故障后也为零或全程跨节点没有排队。

只读输出 `message-hotspots.json`、`background-hotspots.json` 保留实际 phase 交集、缺项、采样边界和 stats reset。只有 +0.59/+5.78 两个 phase 内样本，最后约 4.23 秒没有样本；counter 最近基线早约 4.67 秒，已在分析中披露。尝试采集单 Gateway CPU 栈前，目标已退出，未附加 profiler；无 CPU 调用栈证据，不补写不存在的热点。自有服务和 PG 均已停止。

纯消息阶段的路由查询成本另行核对：routes 计时包含连接池等待、SQL/网络与解码，普通 SELECT 不取行锁。checkpoint 末段已约 1,518–1,546 次 routes/s、平均约 0.48–0.49ms，RPC 为零。近期基线到阶段 +5.78 秒总 delta 8,322 次中，7,615 次处于跨阶段边界的区间；真正两端均在消息阶段的 5.194 秒只完成 707 次 routes，累计调用耗时 111.003 秒，均值约 157ms。不能以跨边界平均 14.6ms 描述纯阶段，也不能将并发累计耗时当墙钟。每次有效 presence heartbeat 即使没有订阅者仍先查询路由；现有 operation/result 指标不能区分 presence、消息正文、room/user wake、typing 或空路由结果，不能定量将全部查询归因消息投递。

## 去掉 checkpoint 等待的独立诊断

独立诊断 `/tmp/imv2-actor-tcp-warm-diagnostic-20261001-r1` 使用同一 50k 夹具、二进制和 5000/s × 90 秒及原错误/排空门槛，只去掉 180 秒空载 phase；明确 `--allow-small-canary`，即便成功也排除正式容量验收。实际 Gateway 50k 全在线、全部分片 ready；阶段前 activeRooms 25,662，+5.12 秒仍 25,548，未发生正式样本中的大规模 idle 退出。然而约 10 秒仍失败，Driver exit1；报告 0 和 5 缺失，只保留 10 片，部分 381 ACK 不代表全体吞吐，不能做比例比较。两缺报进程由失败清理 SIGTERM，不当作初始连接失败。

唯一 phase 内 PG 样本 +5.122 秒有 21 Lock 等待，14 admission_credit、4 activation_fence、3 other。其中 11 个事务明确请求 `shard_admission_pools` 的同一 tuple `(page=3, tuple=66)` ExclusiveLock；另外 2 个 tuple 匹配属于 housekeeping cursor，不能混为消息准入。持准入 tuple 的事务自身等待 XID 549121，实际 XID owner 为 idle-in-transaction 约 0.91 秒的业务事务；3 个 fence 等待者匹配到正在等待共享准入的消息业务事务，形成持房间围栏→等共享准入→其他房间围栏等待的链。证实常态发送中也存在共享持久准入行争用与围栏传播；不能以冷启动作为唯一解释，也不能从单快照量化其占所有失败的比例。该样本六个 foreground_write 队列为 743–832，Directory pending 为 917–1,024、active 全 128，仍复现两个准入热点；Host 总预算未满。

诊断只有一个阶段内 PG/Host 样本，没有纯 phase 相邻速率或 CPU 区间；其 rates 从阶段前 -0.468 秒到 +5.122 秒，不能冒称严格阶段吞吐。只读输出 `message-hotspots.json` 保留偏移与缺项，cleanup 锁已排除。全部自有服务及独占 PostgreSQL 已停止。

另补齐分析器的缺报回归：从 evidence.loaderPartitions 或 result.exitCodes 确定预期分片；缺少最终报告进入 missingReportNames、reportSetComplete=false 和 missingShardPhaseCount，缺 manifest 时不假定完整。3 项有针对性的 Python 回归通过，覆盖部分报告、报告齐全但 phase 缺失、预期数量未知。正式 r2 明确 12/12；独立诊断明确 10/12，重算分析不改变原始报告或吞吐。

本轮最终检查：上述三组运行的各 HTTPS edge 全部 counters/statuses 为空或零，消息提交未经过 HTTP edge。模块依赖检查为 584 个文件、1991 个符号、1976 条边，forbidden=0、cross-target-SCCs=0；文档链接及 retired-reference 检查和 git diff --check 通过。自有 PostgreSQL stop 日志全部确认 server stopped；无本轮 Gateway/Loader 残留。

## Directory 缓存调用与远端自动恢复实施（2026-10-01，功能通过，容量未通过）

本轮按重新检索 Swift 提案后的设计修改 Runtime / Cluster / Host，不升级固定 Vendor 依赖，也不修改共享 SQL 准入模型。Host 的逐 token readiness 为 O(1)；send/recover 优先使用已认证缓存引用，位置与物理引用分别使用安装代次条件更新。故障恢复按宿主合并探测、按房间合并租约等待和激活，未知消息结果保留原请求身份。

聚焦测试第一轮发现两项 Cluster 问题：新增测试误比较非规范 JSON 字节，改为解码 ActorID；旧激活的真实晚回复因 descriptor 换代被缓存守卫抛为 stale，改为返回真实 ready 且跳过旧缓存安装。只读审查另修复迟到 probe/lookup 覆盖新引用、旧有效租约 stale 提前退出恢复，以及 Directory 把旧失败绑定到新缓存的竞态。日志 `/tmp/imv2-directory-recovery-focused-tests-20261001-r1.log` 与 `r2.log` 保存失败和受影响重跑，不掩盖初次失败。

真实 PostgreSQL、两个独立进程和 mTLS 的宿主 SIGKILL / 租约过期 / 新 incarnation 实测通过：`/tmp/imv2-va-g4-1790829910-2081-evidence`。重启 replay 改为单次 RoomRef.call，取消调用方外层循环；epoch 1→2、messageRows=1、原 messageID 保持、旧 token 的真实 SQL 写围栏拒绝。使用任务独占 native PostgreSQL，适配运行脚本保存在证据目录 `native-runner.sh`，未使用共享数据库或 Docker。

进一步提前重启宿主，在旧租约尚有效时开始单次 replay，发现真实恢复边界：旧 cached RPC 耗尽整个 45 秒逻辑 deadline，未留下恢复时间。失败证据 `/tmp/imv2-va-g4-1790830324-3242-evidence`。已将每次消息 RPC 约束到现有 callTimeout，原逻辑 deadline、operation ID 和尝试上限均不重置；该修复的聚焦与真实验证继续进行。前一成功场景只能证明过期后恢复，不能替代此有效租约场景。

TCP 小规模功能验证：`/tmp/imv2-directory-recovery-tcp-canary-20261001-r1`，candidate、120 在线、12 份完整报告、1020 submit / 1020 ACK、12 次 lost-ACK 移交/恢复及12次队列移交/恢复，unknown / failure / overflow / abandon 为0，120最终前台游标全部追平。末次采样合计 cached_call_attempts=1032、responses=1032（含12次TCP query），cacheMiss=0、locationInvalidations=0，Directory pending/active/waiters 均0。Transport physicalLookup=848，来自混合严格读取，不能归因于消息缓存调用；实际 cached local/remote 合计亦包含既有本地提示读取。小规模 canary 不构成 50k/5000 容量通过证据。

有效租约提前重启 r2 / 加闭合诊断的 r3 仍失败，分别保留在 `/tmp/imv2-va-g4-1790830928-6559-evidence` 与 `/tmp/imv2-va-g4-1790831181-8212-evidence`。r3 单次 replay 实测45.224秒，Directory恢复9轮/退避8次，hostRecoveryProbes=1、waits=4、active=1。源码确认：首次业务30秒超时后，恢复 probe 又按业务callTimeout持有旧节点30秒；Discovery必须等待旧节点实际在途排空才能down/join，probe因而把恢复本身钉住。修复为 probeDeadline=min(首lookup deadline, now+3s)，保留真实Task/RPC追踪直到结束及指数退避，不改数据库租约、不直接丢弃旧任务。另将已权威匹配租约的短confirm超时包为私有来源错误，允许房间恢复等待；严格resolve及激活RPC未知结果不改变。这两项的受影响聚焦与真实场景继续验证。

短 probe 修复后的有效租约重启 r4 仍未在45秒内完成：`/tmp/imv2-va-g4-1790832032-11406-evidence`（Debug，功能探针；当时并行进行 Release 编译，不作容量数据）。闭合样本probe4/active0，恢复10轮，排除了单个探测永久不结束；Vendor remoteCall 超时确实移除 continuation 并退出远端调用栈。进一步定位为准入顺序造成排空饥饿：suspendUnreachableHost 先等 !hasRetiredWork 才停止新调用，恢复请求不断进入，Discovery很难观测空窗。现改为失败宽限期后先封闭旧完整身份的新准入，再等待真实旧工作结束，最后才down/join；已有精确且未过期的 grant 仅可mark/abort/finish清理，不允许新invoke/reserve绕过。已分发的真实晚响应保持交付，不清除actual注册表或数据库租约。受影响Cluster/LocalCapability 24项通过（`/tmp/imv2-directory-recovery-admission-tests-20261001-r5.log`），下一真实重启功能验证不与编译并行。

提前重启、有效旧租约场景 r5 最终通过：`/tmp/imv2-va-g4-1790832801-14785-evidence`（Debug原生两个进程、真实mTLS和独占PG，不与编译并行）。replacement host-ready比PG过期观测早29.739秒，调用方在其后立即创建首次continue marker并开始单次ref.call；replacement-ready→client-done为35.360秒，未使用外层重试或提高45秒总预算。运行器后来再次touch同名continue marker，因此该marker最终mtime不能当首次调用时刻；上述差值使用host-ready、lease-expiry与client-done文件，属于有边界的阶段计时而非RPC精确延迟。result证实epoch1→2、新incarnation、messageRows=1、原messageID、原订阅head/revision和真实旧token SQL围栏拒绝；native-runner.sh保留实际故障顺序供复核。功能验证结束及资源停机exit0。

本轮按变更重跑受影响套件，最终覆盖76项独立测试（Directory24、Host19、Cluster/LocalCapability24、Prometheus9）；不是将多次重复执行相加。最后受影响日志为`/tmp/imv2-directory-recovery-final-focused-tests-20261001-r4.log`与`/tmp/imv2-directory-recovery-admission-tests-20261001-r5.log`，其余无变化的Host/Exporter采用前述已通过批次。实际probe与canary明确独立于单元统计；容量结论待固定场景。

固定正式容量 r1：`/tmp/imv2-directory-recovery-tcp-5000-20261001-r1`，Release，原50k/5000、180秒checkpoint、90秒消息配置、原失败门槛均保留，无故障注入。50k全部认证/就绪/协商TCP，12完整报告；实际交集消息窗口10.004秒，阶段ACK563（56.27/s）、整轮ACK588，536最终游标落后，质量和容量均未通过，不能计算通过原版80%的比例。failure后关闭产生44856条connectionClosed unknown，不当作最初原因。该失败轮没有继续无意义地重跑baseline。

阶段2个采样的counter差分有0.989秒前边界及0.643秒末端缺口：cachedAttempts59875、miss36520、responses370、实际cached local6698/remote16664、physicalLookup13963、HostProbe1461。Directory active均128、pending1007–1024，outstanding command每Host3494–3854；本轮PG仅观测最多2个房间fence Lockwait，未捕获前次11事务同准入tuple链，不能推断该争用已消失。foreground_write admission timeout3835、admissions536、等待计数4323/sum20719838ms，仍有数据库工作准入积压。

源码复核确认另一个范围错误：tryInvokeCached因hostRecovery存在而拒绝同宿主全部缓存；任一房间proxy transport unknown又会markHostSuspect，因此物理房间故障可放大为全Host冷恢复。指标只证明该放大路径与大量miss/probe并存，不能断言全部miss由此引起；idle300秒与长预热/checkpoint仍混入真实退役。正在将房间故障限定于精确物理引用的CAS撤下、保留其他已捕获调用；控制HostRPC可用性才触发宿主探测协调，宿主suspect本身不阻断健康房间缓存。既有owner/token/receipt/PGfence与明确Discovery关闭准入不改变。最终性能须再由修正后的固定场景核验，不先声称热点解决。

范围修正后有效旧租约场景 r6 再次通过：`/tmp/imv2-va-g4-1790836100-21016-evidence`（Debug，真实两个进程、mTLS、独占PG，无并行编译）。替代host-ready比PG过期观测早29.949秒，ready→client-done为34.172秒，单次ref.call的原45秒预算不变；与r5同样，continue marker后续被再次touch，以上为阶段边界差值。result验证epoch1→2、incarnation变更、messageRows=1、原消息/订阅身份及真实旧token SQL围栏拒绝，runner与PG停机均exit0。新增同Host第二房间隔离用例与其受影响套件25项通过，日志`/tmp/imv2-directory-recovery-scope-tests-20261001-r6.log`；最终独立覆盖77项（Directory24、Host19、Cluster/LocalCapability25、Prometheus9）。

最终范围修正版 Release Gateway / Probe 构建通过（139.30秒 / 8.58秒），日志`/tmp/imv2-directory-recovery-scope-release-build-20261001-r5.log`；命令首次误将-j4作为单参数，被SwiftCLI拒绝且未编译，立即改为-j 4后完成，未修改源码规避构建。

固定正式容量 r2：`/tmp/imv2-directory-recovery-tcp-5000-20261001-r2`，同50k夹具、原checkpoint180秒及5000/s×90秒，无故障注入或并行构建。50k真实在线通过共同屏障，约10秒后质量失败，driver exit1。失败清理SIGTERM了6个尚未形成最终报告的Loader，仅6/12报告；可用分片阶段ACK526、整轮ACK563均为部分统计，不能当作全体吞吐或与r1直接比较。汇总authenticated25001亦只含6份报告，不能误称实际只建立25001条连接；已保留50k共同屏障。已报告游标962落后、307缺失，质量/排空/容量均失败，原版80%门槛未验收，未追加无效baseline容量对比。connectionClosed unknown21510含清理影响，不作为最初故障。

r2的两个阶段内Host样本，counter差分前边界1.238秒、末端缺口0.667秒：cachedAttempts36509、miss15219、responses388、cachedLocal3386/Remote17898、physicalLookup2676、HostProbe13/Wait5，各采样activeHostRecoveries均0。该数据证明运行中实际存在缓存调用且Host探测不是每消息执行，仍不能以不同失败窗口计数的变化证明整体吞吐改善。三个Gateway Directory active128、pending929–1024；另三个未整体饱和。foreground_write队列365–662、inFlight各8、admissionTimeout2022，完成等待2622次/sum13042003ms（边界内混合计数，均值约4.97秒）。消息send/recover执行前overloaded分别3282/5788，send rolledBack overloaded1115；不能把全部失败归因SQL，也不能以Host总命令1084–2065远低预算排除更细粒度额度。

阶段PG最多30个blocked；累计快照分类route_registration27、admission_credit3、other2（不是独立等待次数），24个精确匹配tuple对象位于realtime_gateway_leases，8条实际XID边；本轮没有捕获此前11事务同消息准入tuple链，不能假称复现或消失。只能确认阶段内额外存在路由注册/维护锁等待，两个样本不能量化其占全部延迟比例；不存在CPU栈证据。所有HTTPS edge最终counters/statuses为空，真实消息提交保持TCP。分析保留缺报、采样边界和证据强度于message-hotspots.json；自有Gateway/Loader/Probe/Account已退出，独占PG stop确认server stopped。

本批次缓存直接调用、O(1) readiness、引用代次安全和需求触发自动恢复已实现，77项聚焦测试及真实有效租约故障恢复通过；固定容量验收仍失败。共享SQL准入、长预热后的冷恢复与路由维护压力留为独立性能问题，不以功能测试通过替代规模结论。未执行Linux、网络分区或24小时稳定性验证。

最终模块检查584文件/1991符号/1976边，forbidden=0、cross-target-SCCs=0；文档链接与retired-reference检查、git diff --check通过，日志`/tmp/imv2-directory-recovery-final-module-check-20261001-r6.log`及`/tmp/imv2-directory-recovery-final-doc-links-20261001-r6.log`。未提交或创建PR。

## 容量失败后的恢复风暴审查（2026-10-01，实施中）

续轮先只读核查同一r2原始阶段采样：阶段前约-1.238秒注册表与transport均50k，renew失败0；+4.171秒本地注册连接已24998、transport仍50k，renew失败增3，PG此时无route节点行等待；+9.337秒interest71477、register从6增9，PG +9.339秒才出现27个route等待者。24个tuple等待分布在3个gateway行，每行8个；因此节点行争用更符合运行中续租失败后的兴趣注销/重新登记放大，不能误称每消息写节点行或简单运行末cleanup。源码仍允许逐topic注销并重新owner注册，续租轮又先等待所有dirty reconciliation再续租；已开始保持节点配额/租约围栏的按物理registrationKey合批、单实际兴趣事务在途及续租顺序修正。阶段稀疏采样尚不证明最初续租失败原因。

另源码发现idle退休重入竞态：Host取lane.snapshot后只比较entry/phase，不重查最新lane活动；在两个Actor挂起之间真实调用可能已完成，旧idle快照仍触发退休。已改为Lane同隔离域原子核对最新lastActivity、队列/执行/未知工作/屏障和等待预算准入，再封闭准入；Host保留实例/phase跨await检查。此为可复核源码竞态，不能声称已由性能样本定量归因；idle300秒与兴趣不保活的合同不改变。新增聚焦回归待与合批修改一起验证。

本批实现冻结：Coordinator按物理registrationKey共用一个兴趣写worker，2ms有界合批、SQL每批≤128；显式128项请求保留同一提交屏障，跨owner同persisted topic key保持顺序分批。单key只有一个实际applyInterests在途；等待者取消不取消共享任务，重复shutdown等待同一实际排空。dirty回放排入同一队列，renewLoop先实际续租再排dirty，不用全部tombstone阻塞下一次续租。RouteStore继续节点独占锁/兴趣逐项SQL/配额围栏，仅计数delta非0时UPDATE节点。此批没有解决失覆盖注销触发owner重新注册的完整状态问题，也没有把未知租约丢弃为清理成功。

受影响套件47项通过（routing7、Host19、Lane21），日志`/tmp/imv2-recovery-storm-focused-tests-20261001-r1.log`，body分别0.489秒与2.381秒；两批测试运行器输出的7与40为不同test targets，不是漏掉routing。新增两项Coordinator测试用受控store门闩验证384兴趣/物理alias的合批、提交前未成功、同key并发写最多1以及重复shutdown等待；不是实际PostgreSQL压力证据。Lane新增用例以真实队列/执行门闩验证旧snapshot/新活动/退休后拒绝。未重复已通过且不受影响的Exporter、Directory、Cluster或UI全套，也未把先前正式r2的失败冒称此新版本结果。

持久写路径只读审查确认：TCP sendOperation经ActivationFactory/foregroundWrite和PostgresMessageSendOperationStore.sendBatch，批次限同一个token.roomID。稀疏负载常每turn1条，完整operation/activation/receipt事务末尾仍reserveShardAdmissionBatch更新shared shard_admission_pools。usingOperationTransaction明确清除credit pools；现旧普通send跨room fast-direct/credits配置不覆盖durable path。admission_credit采样分类只是相关表SQL分类，不证明优化credit pool已调用。后续预扣credit必须保持外层真实commit/rollback/unknown生命周期与PG权限/lease/fence，不直接让旧fast-direct绕过持久回执；此批未实施该独立SQL路径改动。容量门槛继续未通过。

本批Gateway Release通过，日志`/tmp/imv2-recovery-storm-release-gateway-20261001-r1.log`（136.87秒）。固定正式复测`/tmp/imv2-recovery-storm-tcp-5000-20261001-r1`，原50k/5000、180秒checkpoint和90秒目标不变；真实50k通过共同屏障，无其他构建/故障探针。约10秒质量失败，driver exit1；10/12报告，缺3/9，清理SIGTERM。可用分片phase ACK392、整轮393是部分数据，不能计算全体吞吐或原版80%；报告中的41667认证也仅含10份，不代表真实连接总数。已报告游标1069落后、0缺失/超前；37092个connectionClosed unknown含退出清理，不作为首因。HTTPS edge全部counters/statuses为空，消息提交保持TCP。自有进程全退出、独占PG停机确认。

两个phase内采样(+3.455s/+8.675s)：六Gateway连接总和50k，interest始终100k、各registration=1。差分renew成功6、无renew失败/coverageLost增长；PG只观测最多2个fence等待，没有route_registration等待。与前轮阶段内丢覆盖/重注册风暴相比，当前已观察窗口保持覆盖；稀疏两样本不能证明全程无争用或把所有变化单独归因合批。counter最近基线早1.677秒，末端缺口1.331秒，不能当完整10.006秒计数。cachedAttempts48326/miss12839/responses369、physicalLookup12032。全部Directory active128，pending705–973；foreground_write全部inFlight8、queue528–997、admissions379、timeout3275、等待3606次/sum17468290ms（约4.84秒边界内混合均值）。send notAccepted overloaded1472/rolledBack overloaded4569，recover notAccepted overloaded366；未知send229/recover84。这些是独立剩余瓶颈，不把全部发送失败归因单一SQL行锁。

只读分析位于message-hotspots.json并披露缺报/边界。本批生命周期/写队列隔离功能已通过47项测试并有实际规模下覆盖保持证据，正式容量仍失败，目标保持未完成。继续需要优化持久发送实际SQL路径与冷恢复成本；没有降低门槛、增加缓存/解析/SQL预算或改idle时间。本批模块检查584文件、1991符号、1976边，forbidden=0、cross-target-SCCs=0，文档与diff检查通过（日志imv2-recovery-storm-module-check/doc-links-20261001-r1）。

## 冷恢复探测去重与发送成本诊断（2026-10-01，进行中）

本批Pending记录失败cache probe的完整token/owner/cacheRevision。仅同一revision仍当前时跳过performResolve的第二次旧缓存lookup；权威owner/lease定位与确认仍执行，不取消实际调用、不清owner提示、不增加预算。overload/认证/unknown不作为旧位置失效证据。新增同revision一次失败probe及同token重装新revision仍可probe的回归；Directory26项通过，日志`/tmp/imv2-directory-probe-dedup-tests-20261001-r1.log`，body1.038秒。Gateway Release通过（136.89秒），日志`/tmp/imv2-directory-probe-dedup-release-20261001-r1.log`。

对前轮原始PG进一步核对：两个phase内快照54/57个idle-in-transaction，大多ClientRead，Lock仅2/0；说明很多事务已取得物理连接而等待应用继续，不能把全部foreground排队称为SQL行锁或尚未借到连接。48前台write permit始终占满，实际许可覆盖receipt预读、owner路由、独立control授权预留以及最终owner事务。begin batch指标在permit前登记，故数千inFlight batches不等于数千PG SQL正在执行。两点约190次真实batch提交，与48permit服务周期约1.32秒的估算一致，仍缺分段耗时。按实际相邻样本，Gateway约6.56核、PG约1.10核，未证明全机14核上限。已有NIO loop均值约1.82–3.13ms，也不能据此断言长SQL链只因event loop卡死。

源码条件计数：单条已回复普通direct、无媒体/@/reply/forward且无需新profile的durable新消息约40条owner事务SQL/控制语句，加事务前receipt/route及control reserve事务；分支可能更多，不是实际SQL trace。包括operation/activation锁、两层savepoint、标量preflight、重复授权证明、成员校验、receipt与最终admission。现borrowed operation body故意清除credit pools：它返回尚未证明外层COMMIT，并且持有房间/策略锁期间补充credit可能借同有界池造成死锁。不能删除nil或绕过receipt直接接旧fast-direct。

预扣credit若后续采用，必须由外层事务拥有operation-key→token映射；仅新接受项消费，COMMIT确认才commit token，已证明rollback才release，unknown保守discard且不回收可能消耗的token。现FastDirect不持shard共享锁依赖尾部reservation再校验，替代最终UPDATE前还需证明lease/profile轮换围栏；本批未改该独立SQL合同。低风险候选为合并exact/latest授权receipt查询、删除普通direct重复成员校验，以及受事务绑定的验证上下文；仍需实际诊断后选择，不先宣称锁热点已解决。

本批将使用固定50k原场景但显式allow-small-canary、只采1个Gateway的4秒/10ms CPU栈，诊断排除容量验收。runner保留实际PID/起止/计划phase offset和源码，不再试图在fail-fast已退出后附加profiler；不并行编译或运行其他服务。

诊断实际完成于`/tmp/imv2-message-cpu-diagnostic-20261001-r1`，runner及cpu-diagnostic.json保留PID48907及实际时间，sample exit0。固定场景仍50k/5000、180秒checkpoint，但显式allow-small-canary且采样一个Gateway，严格排除容量验收。sample请求4秒、10ms间隔，命令在实际phase+1.050秒开始；命令整体到+10.852秒结束，包含符号处理，不能把整体9.802秒声称全为phase内CPU采集。sample自身日志明确“4 seconds ... sampling completed, processing symbols”；原报告头与调用树保留。driver在约10秒质量失败，9/12报告（缺4/7/10），部分phase/整轮299ACK不作总吞吐或性能对照。

真实调用栈看到PostgresChannelHandler.sendParseDescribeBindExecuteAndSyncMessage→socket write、多个V2NIOGatewayChannelHandler.writeFrameWhenWritable→socket write、Cluster exchange签名/JSON编解码及Directory调用；没有足够样本支持某一个domain SQL函数独占CPU。大量kevent/cvwait/workqueue等待，read/write kernel栈同时可能含系统等待，不能把所有thread sample相加作CPU百分比。Directory.remember及Host reconcile只有少量样本，故不能把源码O(cacheSize)扫描直接升级为实测主热点。后续用闭合阶段计时区分receipt preflight、authorization route/control reserve、owner连接申请、事务体及commit，维度固定、不记录SQL文本/用户ID。

诊断阶段Gateway/PG只有1个采样，counter基线早1.151秒、末端缺口6.034秒，无法生成严格相邻phase速率：已观察cachedAttempts23541/miss6859/physicalLookup4093，write队列585–627、PG Lock0。timeout0仅为该早期局部观测，不证明后半段或全程没有timeout；不据诊断与前轮counter差分比例宣称查询/吞吐改善。所有自有Gateway/Account/Loader/sample已退出、独占PG stop确认server stopped。Directory实现完成与26测试证明语义，正式容量及80%门槛仍未完成。
### 持久发送阶段计时与提交前截止时间（2026-10-01，容量待复测）

为区分发送延迟来源，在同一物理owner的既有sendOperation recorder增加八个封闭阶段：receipt_preflight、authorization_route、authorization_control、owner_connection_acquire、owner_setup、owner_body、owner_commit、owner_rollback。阶段计时覆盖实际异步/SQL生命周期，调用方超时不提前结束仍运行的连接获取或事务；started/completed/inFlight、累计与最大耗时由Prometheus导出。owner connection acquire包括borrowed task进入前的调度，authorization route/control是事务前prepare，事务体仍包括内部授权与围栏SQL。完成均值有采样边界及未完成操作偏差，不能代替ACK吞吐、p95或把所有阶段次数当消息数。分析器按完全相同stage标签配对duration/completed，并保留实际边界；Python四项针对性测试通过，日志`/tmp/imv2-send-stages-analyzer-tests-20261001-r1.log`。

首轮聚焦验证`/tmp/imv2-send-stages-focused-tests-20261001-r1.log`失败：真实PG deadline测试270ms预算内的两次140ms pg_sleep正常提交，行8未回滚；批次fixture缺SECONDARY_DATABASE_URL，因此其七个场景直接return，0.001秒“通过”不算数据库证据。首轮PG启动另遇macOS socket路径长度限制，改用短的专属/tmp目录后运行，未触及共享数据库。COMMIT边界原本只检查异步watchdog设定的stopReason；watchdog协作调度不能证明提交前仍在预算内。现将同一个绝对deadline传至beginCommit，在状态mutex内复查单调时间，过期则物理close并等待原回滚证明，不延长预算。已经分发COMMIT后的unknown语义保持。原270ms/140ms断言保留，并验证TaskLocal及bounded deadline一致。

修复后使用专属原生PG16、18539、两个新空库（stages_test/stages_secondary）实际运行同一受影响测试：`/tmp/imv2-send-stages-focused-tests-20261001-r2.log`，10项测试、4个suite（含6个内容错误参数场景）通过，实际测试10.670秒，构建74.39秒。批次内容隔离实际4.711秒，共享配置失败0.729秒，deadline/连接池/取消/commit uncertainty实际5.132秒。runner及环境记录位于`/tmp/imv2-send-stages-focused-runner-20261001-r2.py`与`/tmp/imv2-send-stages-focused-tests-20261001-r2-evidence.txt`，专属PG已停止。该通过证明受影响事务/计时路径，不能替代正式容量、网络分区或稳定性验收。未更改SQL准入、credit、租约、围栏、重试次数或队列上限。

本批Release Gateway构建通过（140.13秒），日志`/tmp/imv2-send-stages-release-gateway-20261001-r1.log`。正式命令首次候选binary路径误重复IMV2Server，被参数校验拒绝exit2，未创建目录或启动负载；修正后固定正式运行`/tmp/imv2-send-stages-tcp-5000-20261001-r1`。原50k夹具、共同预热屏障、checkpoint180秒、5000/s×90秒及错误门槛均保持，无canary/profiler/故障注入或并行构建。真实50k全部通过就绪屏障，约10秒后质量失败，driver exit1；11/12报告（缺report-0），部分phase ACK615、整轮ACK632不作为全体吞吐或80%对照。39922个connectionClosed unknown包含失败清理影响，不当首因；正式目标继续未完成，没有追加无效baseline对照。自有Gateway/Account/Loader及原生PG已停止。

阶段计时聚合保存在`send-stages-summary.json`，原始采样及窗口分析为`candidate/gateway-metrics.jsonl`、`candidate/postgres-metrics.jsonl`和`message-hotspots.json`。实际消息交集10.004秒内仅2个采样，counter基线早3.870秒、末端缺口3.341秒；以下是六Host完成sum/count加权均值，含披露边界，不能当严格phase latency、p95或把阶段均值简单相加为单条消息耗时。

| 阶段 | 完成差分 | 已完成均值 ms | 最后采样仍在途合计 |
| --- | ---: | ---: | ---: |
| receipt_preflight | 414 | 188.48 | 7 |
| authorization_route | 405 | 141.15 | 9 |
| authorization_control | 396 | 69.18 | 9 |
| owner_connection_acquire | 381 | 150.98 | 15 |
| owner_setup | 381 | 6.77 | 0 |
| owner_body | 374 | 204.26 | 7 |
| owner_commit | 374 | 4.06 | 0 |
| owner_rollback | 0 | 无完成均值 | 0 |

对应foreground write admissions421、timeout1529、queue wait1902次/8718987ms，已完成queue wait均值约4584ms；各Host实际inFlight恒8，队列采样范围215–1018。batch attempted7868、committed374、rolled_back1534，实际owner_rollback为0：二者边界不同，前者含未获permit的批次错误，不能把1534当数据库ROLLBACK次数。ownerBody与事务前回执/路由/连接获取都有成本；COMMIT不是当前主要时延来源。PG两快照分别50和55个idle-in-transaction、Lock均1，实际等待XID匹配到presence与room activation，不支持此轮存在11事务竞争同一发送准入行的判断。约5.24秒相邻采样六Gateway合计8.00核CPU；仍不能凭CPU总体和Client等待把某一个Swift/SQL函数断言为唯一热点，也缺pool-role到backend映射。

后续按测量优先减少持久发送SQL和连接生命周期成本：plain scalar direct确有同事务内两次两成员/pair一致性检查，可将顶层检查移至复杂分支，plain保留实际append入口检查；direct authorization receipt的exact/latest查询可合一，但必须保留旧exact优先、aborted回放、future generation冲突、recipient/fingerprint及owner判定差异。已完成调用链/锁/索引只读审查，本批未实施这两项、不宣称性能收益。preflight/route跨查询借用成本也需在原receipt replay和owner围栏语义内合并，不能简单删校验或恢复旧credit池。模块检查584文件、1994符号、1982边，forbidden=0、cross-target-SCCs=0，文档链接及diff检查通过；最终文档变更后再校验链接。

### 按阶段证据减少重复SQL（2026-10-01，最终候选容量未复测）

上述正式采样结束后实施两项独立低风险优化，不能将其收益追溯到前一轮结果。`PostgresV2RoomWriteScalarPersistence`把顶层direct成员检查移到plain返回之后、复杂CTE之前，plain保留`persistMessages`内实际成员/pair检查，复杂审核/media/mention仍写前检查一次。相同owner事务中的房间/授权锁保持，未绕过前序权限、激活围栏或持久回执。新增真实第三成员腐化用例通过executeSendOperationBatch验证拒绝，message/completion/receipt/closure均0、observer无通知、room_sequence不变。

`PostgresV2DirectAuthorizationReceiptStore.checkAttempt`保留operation advisory lock，用MATERIALIZED exact与条件prior CTE合并两次读取。精确代次命中优先完整matches并重放包括aborted的终态；仅缺精确代次才查latest，Swift继续判定generation<attempt及不可变recipient/fingerprint，未来代次不能被过滤掉，新owner路由仍由后续独立owner fence校验。既有Receipt测试扩展generation缺口、未来代次、旧exact优先、recipient/owner身份冲突和合法新route条件。

仅运行受影响的Receipt/Intent及durable batch测试，原生专属PG16、18539、双空库并明确提供两个URL；`/tmp/imv2-send-stages-focused-tests-20261001-r3.log`，13项/3suite（含原参数场景）通过，实际16.511秒、构建108.33秒。Intent6.932秒、Receipt3.263秒、批次6.315秒，第三成员腐化0.790秒。runner与实际PG目录记录为`/tmp/imv2-send-stages-focused-runner-20261001-r3.py`及`/tmp/imv2-send-stages-focused-tests-20261001-r3-evidence.txt`，专属PG已停止。未重复无变化的deadline/metrics/Directory/Host/UI套件。两项源码减少SQL往返，不构成容量改善的实测证据；最新候选仍需正式容量复测，完整50k/5000及80%门槛继续未通过。

最终优化后Release Gateway构建通过（130.88秒），日志`/tmp/imv2-send-sql-roundtrips-release-gateway-20261001-r1.log`；模块584文件/1994符号/1982边、forbidden=0、cross-target-SCCs=0，文档链接/retired-reference与diff检查通过，日志`/tmp/imv2-send-sql-roundtrips-module-check-20261001-r1.log`和`/tmp/imv2-send-sql-roundtrips-doc-links-20261001-r1.log`。未提交或创建PR。上一正式容量证据对应阶段计时+deadline修复版本，最终SQL精简候选的容量验收仍未运行，不能混用版本。
### TCP重试状态机与TCP优先恢复（2026-10-01，正式容量仍失败）

对发送阶段成本的只读审查发现common Loader的unresolved循环query至预算耗尽，与生产首次期限内同ID重提不同；SERVER_BUSY及deferred又将被拒绝query改为submit。Loader现记录实际submit/query/close动作，确定拒绝保持该动作，unknown/attempt timeout同ID query，unresolved在首次期限前submit、过期closeIfAbsent，实际emit再次检查跨期。保持60秒总预算、20秒单次及5次attempt；服务端floor后加min(指数窗,剩余预算) jitter，不放宽正式速率或错误门槛。

生产TCP adapter仅对已通过requestEnvelope requestID/version关联校验的SERVER_BUSY envelope生成现有deferred/admissionUnavailable hint。服务端来源证据：V2GatewayByteStream容量拒绝在处理任务创建前；V2GatewayDomainCommandHandler准入拒绝在handle前。房间notAccepted/rolledBack/unknown当前都可映射UNAVAILABLE，故不从UNAVAILABLE推断未执行，仍reconcile。matching deferred落库明确nextAction:claim.action，修复原默认reconcile；retryfloor、原身份/指纹/命令和attempt预算保留。没有新公开error enum。无匹配envelope的throw路径仍保守恢复，未把它当作证明拒绝。

RoutedClient automatic移除所有recovery强制HTTP条件：当前账号TCP就绪且无有效冷却时query/close也走TCP；缺session、传输冷却或submit payload超限仍保留独立claim的HTTP fallback。unknown不会在同claim隐形HTTP重提，原operation持久身份保持。V2NetworkWorkPolicy以max(now,serverRetryNotBefore)为base，在其后抽取有界指数jitter，超过尝试预算、floor到期已无剩余或next达到deadline则nil；临近deadline可在剩余窗口内抽样，未增加总预算。

只运行相关客户端测试，`/tmp/imv2-tcp-retry-policy-client-tests-20261001-r1.log`：XCTest18及Swift Testing32为不同运行器的独立测试，共50项通过（含相关参数场景），构建9.19秒，实际0.129/1.297秒。覆盖服务端floor后仍有spread、总预算、submit/reconcile两动作在SERVER_BUSY/UNAVAILABLE四组合下的adapter解码→service→实际GRDB持久状态、TCP优先及无会话fallback、原身份/指纹、原requestID关联拒绝。adapter错误映射测试直接调用真实correlated decoder，不是实际TLS忙拒绝注入，不能冒称已覆盖所有真实网络错误顺序。Release common Loader构建通过15.22秒，日志`/tmp/imv2-tcp-retry-loader-release-20261001-r1.log`。

真实120用户、六Gateway、独占原生PG/mTLS的lostACK+在途/待发队列重连预检`/tmp/imv2-tcp-retry-handoff-canary-20261001-r1`通过，driver exit0、12/12完整报告。1020 WIRE_SUBMIT/ACCEPTED/ACK，12次CANARY_RECEIPT_HELD、TRANSFERRED/RESTORED/RECOVERED_AFTER_RECONNECT及队列移交/恢复，零workload failure、unknown终态、队列溢出/放弃，全部120最终前景游标追平。132认证包含12次重连，不误称132原始用户。该20秒/50msg/s小样本明确allow-small-canary、不计50k/5000或80%容量；未注入SERVER_BUSY/unresolved，不能用它替代相应错误映射验证。专属PG及所有自有子进程已停止。当前正式复测`/tmp/imv2-tcp-retry-sql-tcp-5000-20261001-r1`包含先前SQL精简与新Loader，原50k夹具、5000/s×90秒、checkpoint180及质量门槛保持，无canary/profiler/故障注入，容量结论待实际终态。
正式新候选结果：`/tmp/imv2-tcp-retry-sql-tcp-5000-20261001-r1`，原50k共同就绪屏障通过，约10秒消息阶段质量失败，driver exit1。11/12报告（缺report-3），部分phase ACK638、整轮641，仅为报告覆盖部分，不计算全体吞吐或80%。同新版common Loader的原版对照未运行，因为候选质量失败；旧Loader记录不能跨版本计算改善比例。预检已通过不代替正式容量，目标仍未完成。

阶段分析`message-hotspots.json`及`send-stages-summary.json`：实际交集10.005秒、2个采样，counter基线早2.079秒、末端缺口1.738秒，完成sum/count均值带该边界并排除未完成项。receipt_preflight448/238.88ms，authorization_route436/178.17ms，control433/71.62ms，owner连接获取427/173.41ms，setup427/6.42ms，body417/213.80ms，commit417/4.39ms，实际rollback0；不能将不同完成集合的均值相加为单条消息延迟。foreground admissions463、timeout3183、queue wait3598次/17258534ms（约4797ms），各Host inFlight7–8、queue512–1066；Directory active均128、pending444–590。cachedAttempts46473/misses11629、physicalLookups10773，不将源码减少SQL往返当作已证明容量收益。

PG两消息快照Lock0/2，actual等待XID匹配到room fence，未观测11事务准入行竞争；分别57/55个idle-in-transaction，绝大部分Client等待。checkpoint内一个新快照是连接50k、foreground write0、PG active3/idle86、无idle-in-transaction/Lock，弱证据支持占用随实际工作出现，但单快照不能证明全部背景路径无泄漏。可用11分片phase events为WIRE_SUBMIT52497、WIRE_RECOVERY_QUERY13543、SERVER_BUSY13282、UNAVAILABLE27450、ACCEPTED638、OUTCOME_UNKNOWN14；不能当完整群体或将cleanup unknown当首因。服务端typed notAccepted/rolledBack overload目前仍可统一映射UNAVAILABLE，这是后续应改的确切拒绝分类；unknown必须保留恢复。另下一步可合并owner无锁receipt+route预读，在释放owner连接后reserve control，并保留owner事务内锁后receipt/fence复核；不能在borrowed owner连接内等待独立control或用token代替recipient/kind授权。

当前Source/Loader Release和功能验证完结，所有自有正式Gateway/Account/Loader及专属PG已停止。模块检查584文件、1994符号、1982边，forbidden=0、cross-target-SCCs=0，文档链接/retired-reference及diff检查通过，日志`/tmp/imv2-tcp-retry-module-check-20261001-r1.log`、`/tmp/imv2-tcp-retry-doc-links-20261001-r1.log`；未提交或创建PR。网络分区、长期稳定性与正式80%验收仍未完成。

### 同owner预读合并与确定过载分类（2026-10-01，结构整改尚未实现）

生产Assembly仅在receipt与room route确由同一physical owner构造时显式开启combineOwnerSendPreflight；通用Resources/Store默认false，保留不同数据库构造的行为。单次有界SQL合并receipt和授权route快照，完成并释放owner连接后才执行独立control预留。永久receipt及fingerprint冲突优先于当前route权限；快照不构成写授权，owner事务内原operation锁、receipt复核、激活epoch/lease及权限围栏继续保留。当前foregroundWrite仍包住整个durable调用，尚未解决其持有范围或跨房间集合持久化。

Gateway仅对已解码、已绑定认证发送身份的notAccepted(overloaded)与rolledBack(overloaded)返回现有identity/fingerprint绑定deferred(admissionUnavailable)，保留原内部失败指标，不清理可能已持久的control intent。outcomeUnknown、泛化UNAVAILABLE及其他失败继续原恢复语义，不从网络超时推断未执行。

专属原生PG、两个实际独立空库，聚焦测试日志`/tmp/imv2-send-stages-focused-tests-20261001-r4.log`：39项/2suite通过，实际9.653秒、构建112.40秒。覆盖六种内容错误隔离、第三成员腐化、共享配置错误、control在owner事务外准备、operation锁先于room fence、receipt在route删除后回放及不同owner默认不合并，以及Gateway确定过载/未知结果/认证身份边界。runner证据`/tmp/imv2-send-stages-focused-tests-20261001-r4-evidence.txt`；专属PG已停止。不是新增容量证据，最新正式50k/5000结论仍失败。

结构方案已补入计划的“结构性整改：持久发送按物理owner合批”：有界跨房间调度、room FIFO、控制准备与owner写名额分离、真正集合SQL及完整receipt/授权/COMMIT证明、复杂路径公平回退。此方案尚未实施，不用减少两次查询替代结构性验收，也不能依据两个PG快照确定唯一热点。

本批最终Release Gateway构建通过（146.22秒），日志`/tmp/imv2-combined-preflight-release-gateway-20261001-r1.log`；最终独立只读复核未发现阻断问题。模块584文件、1997符号、1984边，forbidden=0、cross-target-SCCs=0；文档链接及diff检查通过，日志`/tmp/imv2-combined-preflight-module-check-20261001-r1.log`与`/tmp/imv2-combined-preflight-doc-links-20261001-r1.log`。当前未运行新正式容量或baseline，未提交或创建PR。

### 持久发送两阶段准入（2026-10-01，跨房间集合核尚未实现）

Store.prepareSendBatch返回不可公开构造且绑定store witness、原commands/full token/原绝对deadline的句柄；executePreparedSendBatch才进入原owner事务，锁后receipt/epoch/fresh clock/授权及COMMIT证明保持。通用sendBatch兼容调用两阶段。显式较长deadline无TaskLocal时不被默认10秒缩短，execute取prepared与当前TaskLocal较早值，不刷新预算；原物理事务10秒上限保持。应用package能力封装具体句柄，保持模块边界及逐项校验索引。

Factory真实执行先独立准备准入后owner foregroundWrite，不再持owner写许可等待receipt/control准备。生产独立controller在进程内所有physical owner间共享，sync lane用于硬上限，limit/queue取原foregroundWrite配置、原等待期限且enabled沿原配置；不与真实sync或owner准入共享许可。固定im_v2_send_preparation指标独立导出，hotspots analyzer保留其queue/in-flight/counters与completed-wait均值，防止把迁移后的等待误称已经消失。已获准取消仍等待真实structured准备退出才release；当前control Fluent SQL没有保证立即物理取消，可能预算过后等待实际收尾，不能伪称严格期限返回或owner已持久成功。

仅运行受影响验证：真实专属原生PG18539、双独立空库，日志`/tmp/imv2-send-stages-focused-tests-20261001-r5.log`，13项/3suite通过，构建121.49秒、实际9.393秒。7项PG测试覆盖六参数隔离、腐化成员、基础设施失败、prepare无消息写入、store值拷贝执行/异store拒绝、原较长budget保留/更早TaskLocal拒绝、receipt删除route后回放和锁顺序；5项Host准入包含两项实际orchestration屏障，证明prepare挂起owner.write0，取消后prepare实际退出前许可仍1且owner不执行；1项metrics HTTP验证独立指标。专属PG已停止，证据`/tmp/imv2-send-stages-focused-tests-20261001-r5-evidence.txt`。Python热点分析5项通过（0.004秒），日志`/tmp/imv2-durable-two-stage-analyzer-tests-20261001-r1.log`。最终独立只读审查无阻断问题，未重复客户端/UI/无关全套。

本批解决真实资源占用范围问题，尚未实现跨房间集合durable写入，未运行本批新正式容量或baseline；原50k/5000与80%目标仍未达成。下一批共享owner durable store需显式共享store witness及保留Factory注入clock，不能将不同activation的prepared句柄交给任意新store或凭同数据库跳过绑定。

本批最终Release Gateway构建通过（142.28秒），日志`/tmp/imv2-durable-two-stage-release-gateway-20261001-r1.log`；模块584文件、2000符号、1986边，forbidden=0、cross-target-SCCs=0。文档链接与diff检查通过，日志`/tmp/imv2-durable-two-stage-module-check-20261001-r1.log`、`/tmp/imv2-durable-two-stage-doc-links-20261001-r1.log`。未提交或创建PR。


## 物理 owner durable 合批：真实接线及 r6–r9 验证

本节为上方两阶段准备记录之后的新状态；保留历史“尚未实现跨房间集合”的原文，不将前一轮 Release 结果归给本轮集合候选。

生产现由同址 `physicalResources` 的稳定引用 holder 共享一个 Factory-clock Store 与 `V2DurableSendOperationOwnerBatcher`。prepared handle 入队前验证相同 Store witness；FIFO key、命令数、JSON payload 字节与原 deadline 由不可改写的 handle 派生，调用方不能传入不一致 metadata。prepare 仍使用独立进程级许可；等待 owner 合批的 room turn 不占 foregroundWrite。owner coordinator 的实际执行任务持有许可直到真实收尾，最早绝对 deadline 不重置，queued/executing 共享现有数量/字节预算。每 room FIFO/一在途与跨 room 轮转保留，复杂 fallback 不独立放入可饿死的次级队列。重复 shutdown、正常 Gateway 停机及 build failure 都排空实际任务后才能释放下层池。

集合 Store 返回逐 prepared turn 的 `Result`，保留原失败 certainty。fresh plain direct 的 lock/fence/read/allocate/append/proof/receipt 使用集合 SQL；多个逻辑 shard 在同一物理 owner 内一并处理。legacy closure 与 replay/conflict 不产生新的接受；权限变化、域拒绝、坏 activation、真实约束失败或尾部额度变化不取消健康房间。COMMIT dispatch 后异常仍保留全部相关身份的 unknown，不把它伪造成可拆批重试的已回滚。

仅按本轮原始日志记录以下结果（Swift Testing 的 test 数不等于参数化 case 数）：

| 轮次 | 构建与实际运行 | 真实结果与覆盖 | 原始日志 |
| --- | --- | --- | --- |
| r6 | 构建 131.92 秒；实际 19.002 秒 | 18 tests/3 suites **失败，2 issues**：permission case 得到 `corruptPersistenceState`；COMMIT uncertainty 场景得到 `rolledBack(unavailable)`。coordinator FIFO/cancel/drain、两阶段准入等通过不代表整轮通过。 | `/tmp/imv2-send-stages-focused-tests-20261001-r6.log` |
| r7 | 构建 34.63 秒；实际 7.935 秒 | 仅 2 tests/1 suite 复测通过：权限/denial/stale/constraint 四个 case 与 COMMIT uncertainty；没有重跑整套 r6。 | `/tmp/imv2-send-stages-focused-tests-20261001-r7.log` |
| r8 | 构建 86.99 秒；实际 9.601 秒 | 3 tests/1 suite 通过：相同/不同逻辑 shard 的两个集合 case，四个权限/失败 case，以及 COMMIT uncertainty。 | `/tmp/imv2-send-stages-focused-tests-20261001-r8.log` |
| r9 | 构建 85.09 秒；实际 6.353 秒 | 5 tests/2 suites 通过：权限/denial/stale/constraint/late_quota 五个 case，集合授权 proof 检查，两项 coordinator 屏障及既有 metrics renderer 新断言。 | `/tmp/imv2-send-stages-focused-tests-20261001-r9.log` |

各轮专属双库运行路径保存在同名前缀 `-evidence.txt`（分别指向 `/tmp/imv2-stages-2ll1i_za`、`/tmp/imv2-stages-ql3okxcq`、`/tmp/imv2-stages-hcq1tp36`、`/tmp/imv2-stages-iiu4wvnh`）。集合测试用真实 statement trigger 核验两间 fresh stranger room 的 message、completion、授权 proof、永久 receipt 各一次 INSERT；同址相同/不同逻辑 shard 场景均核验 shard admission 一次 UPDATE。replay/conflict/legacy closure 后消息数量与 observer 不增加。late_quota 场景核验受影响项 deferred，而健康项保留其消息与两类 receipt。

COMMIT uncertainty 场景用真实 PostgreSQL deferred trigger 延迟 COMMIT，在 COMMIT 已分发时关闭调用连接，验证每项仍为 transaction outcome unknown、只一次 ownerCommit、没有 ownerRollback 或 provisional observer；随后观察服务端 COMMIT 实际收尾再释放 fixture 激活锁。它不证明最终一定提交或回滚，也不能替代新候选的 TCP lost-ACK/客户端对账验收。

coordinator 屏障使用真实 DB prepare 与租约，仅注入受控 owner executor：四个并发 turn 分成 `[a1,b1]`、`[a2,b2]` 两个真正 coordinator cohort，后续同 room turn 等第一轮实际释放；queued cancel 归还预算，submitted cancel 不早退或归还写许可，两个 shutdown 均进入等待直到实际 executor 释放。这里验证调度与所有权，集合 SQL 本身由上述独立真实 Store 场景验证。新 owner metrics 同时核验 started/completed、commands、largest batch 与归零 gauge；取消的未提交项不计入 commandsSubmitted。

本轮尚无完成的 Release、新 TCP canary 或正式 50k/5000 A/B 容量证据，不声明吞吐收益或 ≥80%。历史两阶段 Release、历史 TCP 功能预检和 HTTP 对照不能移用成本轮性能结论。未降低速率、在线数、截止时间、池/队列门槛或错误要求。

后续验证：本轮 Release Gateway 构建通过，151.60 秒，日志 `/tmp/imv2-durable-owner-batch-release-gateway-20261001-r1.log`。模块检查 589 文件、2032 符号、2018 边，forbidden=0、cross-target-SCCs=0；文档链接检查通过，日志分别为 `/tmp/imv2-durable-owner-batch-module-check-20261001-r1.log`、`/tmp/imv2-durable-owner-batch-doc-links-20261001-r1.log`。

新候选六 Gateway 真实 TCP 功能预检 `/tmp/imv2-durable-owner-batch-handoff-canary-20261001-r1` 通过：120 在线、50/s ×20 秒，1020 WIRE_SUBMIT/ACCEPTED/ACK，12 次 held-ACK/reconnect 均 recovered，12/12 reports、零 failed/workloadFailed/队列溢出或遗留，120 个最终前台游标均匹配 committed head。提交 TCP、恢复 TCP query；小规模显式故障注入不属于容量验收。自有 PostgreSQL 已 shutdown。正式原 50k/5000 候选运行已启动于 `/tmp/imv2-durable-owner-batch-tcp-5000-20261001-r1`，结果仍待实际完成，不计算 ≥80% 对照。

正式运行后续结果：原 50k 全部 authenticated/共同屏障成功，约 10 秒消息阶段质量失败，driver exit1，12/12 reports。整轮 messagesSent=49097、ACK=821、workloadFailed=48314、queueOverflow=70、abandoned=825；最终 50k 前台校验有 940 个落后 committed head。phase 交集 10.019 秒，ACK=765；未完成原 90 秒，不能由累计 ACK 推算正式稳定吞吐或 ≥80%。提交 TCP、恢复 TCP query，未运行无效 baseline 对照。独占 PostgreSQL 已 shutdown，所有自有进程已结束。

`message-hotspots.json` 保留 phase 内两个采样及边界：基线早 2.945 秒，最后采样距阶段结束 2.537 秒。每节点 preparation inFlight=5，阶段内 queued=345–966，timeout 合计增量 1922；owner queued=15–48，largest batch=2–3，started=465、completed=435、commandsSubmitted=608（实际 coordinator 单位，不是 SQL COMMIT 或 TCP ACK）。phase 外最后快照的 preparation queued=991–1027 不用于阶段内结论。完成阶段 sum/count 均值：receipt preflight 735/219.66ms，authorization route 1470/0.02ms，control 730/71.84ms，owner connection acquire 449/219.25ms，setup 447/7.40ms，body 435/249.15ms，commit 435/6.38ms，rollback=0；不同完成集合和新物理批次单位不能相加当消息延迟，也不能跨版本作单条收益对照。PG 最多 4 blocked，样本有 admission credit 和 activation fence 等待，不支持 11 事务持续竞争的断言。

下一结构整改依据：当前 owner collector 位于 prepare 完成之后；prepare 仍每房间独立执行 owner receipt+route SQL，控制策略/intent 仍有逐项 SQL 往返。实际 preparation 队列饱和，而只优化最终 owner 集合写并未完成容量目标。继续实施独立物理 owner preparation collector、跨房间完整键预读和真正集合控制预留；保留独立控制库、冻结授权、原截止时间、未知结果与实际排空，不提高池/队列额度。该下一步尚在实现，不能记录为性能通过。


### 跨房间准备与集合控制授权实际验证（r10–r12）

准备 collector 已接真实 Factory/adapter：同物理 owner 的多个原 room turn 在独立 preparation controller 前合批，queued turn 不先占 SQL 许可。Store 使用一次完整 `room:sender:clientUUID` 集合 owner 预读，future 实际返回并归还 owner connection 后执行集合 control reserve；默认异库组合仍保持各自数据库的 route 权威。每 handle 的 token、Store witness、冻结首次提交期限与绝对调用预算保留，取消/关停等待真实准备结束，基础设施 unknown 不拆批重试。

控制正常 fresh chunk（≤128 请求）为 7 条业务 SQL，加实际 BEGIN/COMMIT：共享策略锁、策略行锁、账号事实、关系事实、操作锁、既有 intent、集合 mutation RETURNING。纯既有 intent 可省略最后 mutation；256 命令可能需要两个控制 chunk，域失败隔离可执行旧严格路径，不能把此计数说成任意 workload 始终 7 条 SQL。真实测试验证 frozen held attempt 的原 owner/generation/policy 不重写，只有 aborted restart；statement trigger 检查集合 mutation。新 Store 测试同时覆盖跨房间同 sender/client UUID、已有 receipt 与健康 fresh 并存、真实 held control fingerprint conflict 及错误 room/token 独立失败。collector 屏障验证取消已提交项不提前释放实际任务或许可。

| 轮次 | 构建/实际测试 | 结果与修复边界 | 日志 |
| --- | --- | --- | --- |
| r10 | 编译失败，未执行测试 | `V2DirectAuthorizationBatchLocks.swift` 未导入 Contracts，找不到 `V2DirectAuthorizationIntentError`；root 补 import。 | `/tmp/imv2-send-stages-focused-tests-20261001-r10.log` |
| r11 | 构建 95.59 秒；实际 15.123 秒 | **8 tests/2 suites，1 issue，整轮失败**；新 control 夹具的 public handle 不符合 schema。其余 7 tests 通过，包括 preparation 完整键、collector 两个参数化取消/排空 case、owner 集合写入、五种 authority/late-quota case、真实 COMMIT unknown、control termination/reverse-batch。 | `/tmp/imv2-send-stages-focused-tests-20261001-r11.log` |
| r12 | 构建 27.55 秒；实际 0.803 秒 | 修正 lowercase/长度的合法 public handle 后，仅该 control 回归及 metrics 路由复测 **2 tests/2 suites 通过**；不声称重跑了整个 r11 集合。 | `/tmp/imv2-send-stages-focused-tests-20261001-r12.log` |

Swift Testing 的 test 数与参数化 case 数不混用。r11 泛化 PSQLError 日志不暴露请求/SQL参数；原因来自已核查的夹具/schema 修正，原失败证据保留。新增准备 collector 指标已在 metrics 回归核验：`im_v2_send_preparation_*` 为物理准备 cohort 准入/等待，`im_v2_send_operation_preparation_owner_*` 为 collector 的 queued/executing 命令、字节、turn 和实际批次；与 owner coordinator 或 Factory turn 的完成数不能混算成消息吞吐。

此批 Release 构建 session 39069 尚未完成；本节不移用上一批 Release 或 TCP canary 的通过结论。下一次真实 TCP 功能预检和固定 50k/5000 容量结果仍待 root 完成，≥80% 门槛未证明。

此批后续验证：Release Gateway 构建通过，135.36 秒，日志 `/tmp/imv2-owner-preparation-release-gateway-20261001-r1.log`。模块检查 592 文件、2039 符号、2031 边，forbidden=0、cross-target-SCCs=0；文档链接检查通过，日志为 `/tmp/imv2-owner-preparation-module-check-20261001-r1.log` 与 `/tmp/imv2-owner-preparation-doc-links-20261001-r1.log`。新候选 `/tmp/imv2-owner-preparation-handoff-canary-20261001-r1` 的六 Gateway TCP lost-ACK 预检通过：120 在线，50/s ×20 秒，1020 submit/accepted/ACK，12 次 held-ACK/reconnect 全部恢复，12/12 reports、zero workload failures/queue overflow/abandoned，120 最终前台游标均匹配 committed head。原提交 TCP、恢复 TCP query；专属 PG 已 shutdown。此为功能预检，不是容量收益证据。

独立正式原参数候选 `/tmp/imv2-owner-preparation-tcp-5000-20261001-r1` 已启动，保持 50k、5000/s ×90 秒、checkpoint180 秒和原质量门槛；正在运行，≥80% 对照和容量目标仍未证明。

该正式运行最终失败：50k authenticated/就绪成功，12/12 reports，消息阶段交集 10.011 秒后 qualityPassed=false，整轮 ACK=671、workloadFailed=49232、queueOverflow=67、abandoned=388，最终 1686 个前台游标落后；未完成 90 秒。独占 PG 已 shutdown。新分析 `/tmp/imv2-owner-preparation-tcp-5000-20261001-r1/message-hotspots.json`：phase 内两个采样，基线早 4.301 秒、末缺 3.836 秒；process-shared preparation 许可 inFlight 各5、queued=0，collector preparation queued turns=124–764，owner queued turns=11–61。preparation started=772/completed=742/commands=987，不是 ACK。完成阶段均值 receipt 747/191.58ms、route1494/0.01ms、control742/47.27ms、owner acquire427/191.19ms、setup427/6.89ms、body411/210.29ms、commit410/4.67ms，rollback0。单位/边界不同，不能相加或跨候选推算性能收益。PG最多6blocked，有admission/fence等待，不认定单一根因。

随后发现必须纠正的生产配置接线：`GatewayRoomOwnerAssembly` 将新 durable owner/准备 collector 复用 `actorBatchConfiguration`，其 size=`max(1, directRoomLogAppendBatchSize)`；旧 append 默认0，正式 runner 未启用该旧项，因此生产跨房间 size 实际为1。largest command batch=2–6仅是不可拆分的单房间多命令轮次，不证明跨房间合批。前述 PG/coordinator 功能测试显式传入可合批配置仍有效，但它们没有证明生产默认启用了该模式。此前生产接线判断不完整，失败日志保留，不将其称为已验证跨房间优化的容量结果。

正在修复独立 `IM_V2_DURABLE_SEND_OWNER_BATCH_SIZE`，默认64、范围1–128，实际 size 截到原 pending 上限；仅 durable collectors 使用，不打开旧 append/credit 路径，不增加原并发/队列/等待预算。新增 largest room count 指标区分房间数和命令数，避免再次用单房间多命令冒充跨房间批次。修复的构建/真实TCP/容量证据尚待取得。

修复后受影响验证 `/tmp/imv2-send-stages-focused-tests-20261001-r13.log`：真实专属双库，5 tests/3 suites通过（配置6参数case、production helper2case、既有owner FIFO、preparation cancel/drain2case、renderer），实际2.423秒、构建126.13秒。原SQL内核未改变，不重复此前SQL/COMMIT套件。两个collector新增 `largest_room_count` 直接记录selected房间数，physical聚合取max，renderer断言及collector2房间屏障通过。分析器仅新增该水位的语义分类，既有5 Python tests通过，0.006秒。

Release Gateway构建通过，133.66秒，日志 `/tmp/imv2-durable-owner-default-release-gateway-20261001-r1.log`；模块检查592文件/2039符号/2032边、forbidden=0/SCC=0，env示例与文档链接检查、diff通过，日志同前缀module-check/env-check/doc-links。此次只修生产配置/指标，复用前一步已验证的SQL与TCP实现，直接进行新的正式真实TCP候选 `/tmp/imv2-durable-owner-default-tcp-5000-20261001-r1`，未重复小规模功能canary。该运行已启动，保持原50k/5000×90秒/checkpoint180和质量门槛；需实际room-count、阶段窗口和前台游标证据，尚未声明容量或≥80%通过。

此运行后续失败，driver因Loader质量guard终止而exit1；50k就绪成功，11/12 reports（缺7），实际已有报告phase交集10.006秒、ACK696，不代表完整全体吞吐。首因记录为deferred retry exhausted（既有5次预算），随后connectionClosed是清理影响；未执行无效baseline。自有进程与专属PG均已停止。phase内两样本，基线早2.538秒、末缺2.192秒，write room-count水位36–56、preparation47–52，终于证明生产实际跨房间合批。phase外最后水位write49–56/prep48–57不混入phase。分析器原按_count后缀将TYPE gauge误认counter，现优先明确TYPE，修正重新分析；新增真实水位回归，6 Python tests通过0.005秒。

此版prepare队列0–42，而owner135–545，prepared写入积压成为显著剩余问题。nearest-pre到lastInside计数write started79/completed49/commands2453，prep started548/completed518/commands11239；actual ownerBody288/COMMIT288/rollback0。严格两inside样本相邻5.198秒，coordinator completed20但actual ownerBody201/COMMIT202/rollback0。源码同时核对到TurnLane主动合并同房间多命令，而Store集合候选仅接受commands.count==1，造成正常逐房间回退；没有足够分支计数量化全部额外事务均由它产生。PG phase样本各仅1 blocked，idleTxn51/61多为ClientRead。31条lockTimeout均在phase结束后，不能作阶段主因。isolation=false时owner/preparation/续租/恢复实际共用原11连接池，独立controller不等于独立物理池，不增加池额度掩盖多事务成本。

下一步实施多命令roomturn waves：每波各房间一条，所有波保持同一实际owner事务，累计准入最后集合扣减；任何不兼容或不能接受的整个roomturn保持旧路径，已开始的失败cohort真实回滚后按完整handles隔离，禁止提前COMMIT房间前缀。新增实际Store候选/回退固定原因指标；未知结果不拆重发。新双库参数化测试与核心实现正待统一验证，不能记录为容量通过。

### 多命令完整 turn 集合 waves：r14 实际验证

当前 Store 已接受多命令 plain direct prepared handle，各房间每波一条 fresh 命令；全部 waves 保持一个 owner 事务，操作锁/activation 和既存事实集合预读一次，累计 reservations 后统一扣减跨 shard 准入，最终 proof/永久 receipt 各集合写入一次。预检以整个 handle 为边界；中间波失败确认整个 cohort 回滚后才隔离完整 handles，未知 COMMIT 不拆重发。permanent replay 可混合 fresh，原命令顺序不变。

| 实际日志 | 构建 | 实际测试 | 结果 |
| --- | --- | --- | --- |
| `/tmp/imv2-send-stages-focused-tests-20261001-r14.log` | 109.47秒 | 6 tests/3 suites，12.197秒 | 全部通过 |

同前缀 `-evidence.txt` 指向专属双库运行 `/tmp/imv2-stages-ddor7fma`。新增 `durableOwnerWavesPreserveWholeTurns` 一个函数 healthy/bad 两参数 case 实际1.611秒；真实 primary control/secondary owner、两个逻辑 shard，各房间两命令。healthy statement triggers 验证 messages/completions 各两次 INSERT（两波），授权 proof/永久 receipt/admission 各一次、同一个真实事务 ID、ownerCommit一次；随后验证全 replay 不追加消息、replay+fresh 回复及 seq 顺序、累计 shard delta 正确。bad 使用实际 messages 第二命令 BEFORE INSERT 23514，验证坏 room turn 首命令也无消息/envelope/seq持久化，健康房间两命令接受，准入delta坏房间0、健康房间2。没有fake token、grant或提交回执。

同轮通过原 fresh setwise 两参数 case、authority 五参数 case、真实 COMMIT uncertainty，以及 Durable send operation metrics 与 Vapor renderer 两项函数。6个test函数不是6个参数case；旧失败和default64正式失败记录不变。新增 Store counters 记录实际集合尝试/提交与固定原因标量回退，隔离子 cohort 可重复计 handle/command，不能换算唯一消息吞吐。

本批 Release仍待实际完成；尚无waves候选的新TCP/固定50k、5000/s、90秒完整结果，不声明容量通过或≥80%。

后续Release构建通过，180.44秒，日志 `/tmp/imv2-durable-owner-waves-release-gateway-20261001-r1.log`；模块检查592文件/2043符号/2033边，forbidden=0/SCC=0，文档链接与diff通过。小规模真实TCP `/tmp/imv2-durable-owner-waves-handoff-canary-20261001-r1` 未通过：120就绪，但Loader有未完成发送/ACK，PG捕获两个事务同时等待尾部额度FOR UPDATE的真实死锁；未启动容量复测。runner已停止全部自有进程与专属PG，原失败证据保留。

源码核对：durable尾部仅修改command_window_used，不修改pool主键或unique(lease_id,generation)，room_admission外键引用该unique键。最小修复将尾部锁改FOR NO KEY UPDATE，仍互斥保护扣减，并兼容KEY SHARE；[PostgreSQL 16锁文档](https://www.postgresql.org/docs/16/explicit-locking.html#LOCKING-ROWS)支持这一锁兼容关系。未在真实服务中完整确认每一端隐式共享锁的获取点，不把推断写成preflight已显式持FOR SHARE。新增两实际事务先持KEY SHARE、再同时扣delta2/3的回归，核验额度+5/两COMMIT/零rollback；该修复正待r15统一双库验证，不增加超时/池/队列或改变lease gate。


r15尾部锁修复实际验证：`/tmp/imv2-send-stages-focused-tests-20261001-r15.log`，构建118.51秒，3 tests/1 suite全部通过，实际6.449秒；authority五case、waves两case及新增两个实际KEY SHARE事务同时扣减回归。专属双库路径`/tmp/imv2-stages-o8ivop_6`，runner已收尾、专属PG停止。只验证受影响边界，没有重跑无关套件。新Release构建正在执行，真实TCP canary仍待复测；不能用此结果替代端到端容量验收。


尾部锁修复Release通过，162.72秒，日志`/tmp/imv2-durable-owner-quota-lock-release-gateway-20261001-r1.log`。六Gateway真实TCP预检r2 `/tmp/imv2-durable-owner-waves-handoff-canary-20261001-r2`通过：120在线，1020 WIRE_SUBMIT/ACCEPTED/ACK，12 held ACK/reconnect全部恢复，零failed/workloadFailed/overflow/abandoned，120前台游标匹配committed head；专属PG已shutdown。保留r1死锁失败，r2不属于容量验收。新正式候选`/tmp/imv2-durable-owner-waves-tcp-5000-20261001-r1`已启动，原50k/5000×90秒/checkpoint180及质量门槛保持，容量与≥80%仍待完整结果。

只读结构复核确认：普通durable准备owner预读实际释放连接后进入control，prepared写入不跨库等待control ack；没有发现该正常路径跨库持owner事务的新缺口。非隔离模式新增preparation controller未被统一纳入owner物理池容量校验；logical shard aliases分别构造activation Store可能各带renew并发，physical pool仍被动排队，不能宣称已有续租专属资源保障。Store单个健康turn仍走原标量事务，当前legacy_or_not_ready指标包含该稀疏尾批，不能解释为全部真实legacy数据。后续容量分支计数须保留此限制。


### Waves正式原参数容量r1：仍失败，新锁环待定位

`/tmp/imv2-durable-owner-waves-tcp-5000-20261001-r1`已终态exit1，50k全部就绪后约10秒Loader质量guard终止。10/12报告（缺3/9），报告交集phase10.008秒；整轮已有报告ACK3068、workloadFailed38062、overflow36、abandoned705，前台检查41667个有4256落后/4missing，不能推算完整吞吐或90秒容量。专属PG已21:13:34.119shutdown，不运行失败候选的baseline。

新hotspots保留2个phase样本+0.962/+6.726秒，baseline提前4.252秒、末缺3.282秒。Store集合attempt133/COMMIT102/handles3629/commands5450，新接受3586，固定fallback仅legacy_or_not_ready5条，其余原因0；计数范围nearest-pre到lastInside，非客户端ACK。coordinator write138started/108completed，实际ownerBody108，与此前大量逐房间事务不同，本轮正常标量回退不是已观测的主要放大路径。preparation277started/247completed/8718commands；完成加权mean receipt444ms/control120ms/owneracquire468ms/body639ms/commit11ms，不相加当单消息延迟。

真实PG死锁发生phase+1.550秒，两事务均已执行tail FOR NO KEY UPDATE，不是旧锁修复未接线。84487等pool tuple(0,14)/relation17383被84498阻挡；84498等84487的XID572220，闭合锁环。首样本28Lock、共享pool主导观测；第二3Lock均activation fence。阶段内另6lockTimeout（4rooms/2control_housekeeping_cursor），phase外最后1rooms不混计。新事实推翻“改NO KEY UPDATE即可解决真实生产死锁”的充分性，r15两KEYSHARE简单回归与120-user r2功能通过仍有效但不足以覆盖本轮锁环。继续查实际锁来源/顺序，不增加超时或池预算。

实际标签是每Host11连接shared池，资源保障须覆盖sync/background/rawSQL而非仅foreground发送；两个stage工作许可不是实际连接数。后样本16cohort处于connection acquire、syncqueued409，说明资源竞争仍存在；同时PG锁链及idle-in-tx表明不能归因纯连接池排队或认定物理loan gate单独可解决本轮容量失败。


本轮终态后静态检查通过：模块592文件/2043符号/2033边，forbidden=0/cross-target-SCCs=0，文档链接及diff检查通过，日志`/tmp/imv2-durable-owner-quota-lock-module-check-20261001-r1.log`与`/tmp/imv2-durable-owner-quota-lock-doc-links-20261001-r1.log`。没有重复全套功能测试，没有提交或创建PR。


r16新增实际三事务tuple queue回归：holder先真实UPDATE额度计数，两个实际tail helper在pg_stat_activity确认Lock等待后释放holder，没有人为KEY SHARE。`/tmp/imv2-send-stages-focused-tests-20261001-r16.log`构建103.12秒，1 test/1 suite实际0.762秒通过，专属双库已收尾。该场景没有复现正式r1死锁，因此不能认定“单statement旧快照重入”已证实或用它证明两SQL方案必然修复；继续补贴近production SAVEPOINT的并发场景，不增超时/池额度。


r17把同一真实队列探针加入production SAVEPOINT/RELEASE并连续三轮，每轮原绝对5秒；夹具只有4连接，因此维持holder+2tails+observer，没有扩连接池。只该测试poollimit设30容纳重复delta18，不改生产额度。实际1 test/1 suite通过0.788秒，日志`/tmp/imv2-send-stages-focused-tests-20261001-r17.log`，专属PG已停。仍未复现正式r1死锁，不认定snapshot/子事务是假设根因；后续需要完整prepared owner cohort并发链路。

已实现同址logical shard续租资源去重：GatewayComposition传已有physicalStoreKeyByShard→ActorApplication→LeaseStore；显式映射必须完整且非空，同physical key只构造一次Store、alias值copy共享renewactor，nil默认保留原行为。不打印可能含凭据的physicalkeys，不改schema/owner围栏/SQL或shutdown去重。单函数leasePhysicalAliasesShareRenewalCoordinator正在r18专属双库验证（session7293），覆盖共享/独立/默认行为与missing/extra/blank拒绝。physicalloan保障仍未实施，没有本批新Release/容量验证，不将one-shard正式失败归因alias。


r18续租alias聚焦验证已通过：`/tmp/imv2-send-stages-focused-tests-20261001-r18.log`构建24.45秒，1 test/1 suite0.727秒；显式同physical共享actor、不同physical独立、nil默认独立，以及missing/extra/empty/whitespace拒绝和敏感值不进error。实际双库夹具未改池，PG已收尾；不是续租压力或容量证明。

对先前排除FK检查的判断作修正：[PostgreSQL16 RI源码](https://github.com/postgres/postgres/blob/REL_16_STABLE/src/backend/utils/adt/ri_triggers.c)的RI_FKey_fk_upd_check_required在比较FK相等之前，若old tuple xmin属于当前事务即要求检查。因此wave2更新wave1新tuple时used-only也可能触发引用pool检查；不能从不改FK列推出整条waves无隐式锁。它仍不单独证明正式deadlock的完整根因。r19只运行新增真实prepared owner两cohort/四room/八commands同pool并发回归，原tail暂不修改，结果待实际完成。


r19原单statement尾部的完整cohort并发回归通过：build24.18秒，1 test/1 suite0.801秒，4room/8命令samepool两个真正owner事务，不能据此否定正式死锁。随后两statement改造已落：尾部先完整稳定排序NO KEY UPDATE并校验锁定key集合，缺行立即missingLease防下一快照接纳未锁新增行，再用新READ COMMITTED快照执行原全组checked/gate/UPDATE。额外一次固定SQL，只有一次额度UPDATE；now/期限/租约/行数及提交certainty保持。未将snapshot假设写成已证明根因。

r20受影响专属双库验证：`/tmp/imv2-send-stages-focused-tests-20261001-r20.log`，5 tests/1 suite全部通过8.015秒，包括authority五case、waves两case、完整cohort并发及两种锁队列回归。Build complete! (65.04秒)。PG已收尾。新Release构建正在session22029，日志`/tmp/imv2-durable-owner-two-statement-release-gateway-20261001-r1.log`；新TCP及正式容量仍未验证，不能宣称deadlock已消除。


两statement+续租alias候选Release通过163.74秒，日志`/tmp/imv2-durable-owner-two-statement-release-gateway-20261001-r1.log`。新TCP预检`/tmp/imv2-durable-owner-two-statement-handoff-canary-20261001-r1`通过：120在线/132auth，12reports，1020 submit/accepted/ACK，12heldACK/reconnect全部恢复，零failed/workloadFailed/overflow/abandoned，120最终前台游标无missing/落后/超前。实时hint/live gap统计仍非零，但原完整前台恢复对账通过，不能说所有中间提示零gap。PG已shutdown。该小规模故障验证不属于容量验收。正式原参数`/tmp/imv2-durable-owner-two-statement-tcp-5000-20261001-r1`已启动，50k/5000×90秒/checkpoint180和原quality保持；尚无完整容量/≥80%证据，未宣称deadlock已消除。


### 两statement正式容量r1：仍失败，未捕获新死锁

`/tmp/imv2-durable-owner-two-statement-tcp-5000-20261001-r1`终态exit1，50k全部就绪，约10秒Loader质量guard终止。6/12报告（缺1/3/4/5/8/11），已有报告交集phase22:24:35.830–45.830 exactly10秒。整轮已有报告ACK2403、workloadFailed22654、overflow29、abandoned279，25000前台游标2131落后；不能用部分报告与上轮直接比较全体容量收益，未完成原90秒/≥80%。自有PG22:25:20.014已shutdown，不运行无效baseline。

完整PG日志没有deadlock记录；阶段内2rooms NO KEY UPDATE locktimeout（+6.924/+9.540），其余housekeeping/rooms/statementtimeouts均在phase之后，不混阶段因果。两个phase样本+1.513/+6.928只有3/2Lock，实际XID边5、最大fanIn1，无pooltuple队列或闭环；稀疏采样不证明全阶段没有pool等待或每条锁来源都已确定。两SQL方案本轮未复现上轮死锁，不宣称全局死锁永久消除。

metrics2样本：baseline早3.750秒、末缺3.074秒。nearest-pre到lastInside Storeattempt164/COMMIT135/accepted4458/isolation0、scalar5handles6commands（legacy_or_not_ready，含稀疏尾批），其它reason0；actual ownerCOMMIT140≈135+5，执行路径可闭合，不能继续按此前隐性N事务归因。completed stage均值acquire488ms/receipt483ms/body488ms/control116ms/commit9.7ms，不相加当每消息延迟。shared11池各Hostprep5在途，全局write27→29/sync18→18，syncqueued59→454、acquire21→19、receipt28→24；这些是在途stage而非已借连接数。PG idleTxn55/56且锁等待少，不能把长连接获取都归因SQL锁或凭aggregate样本证明实际pool耗尽。

下一结构改造已分配三agent并行实施：统一实际物理pool/EL借用gate，完整覆盖shared读写/sync/后台/恢复，保持原11连接、stage5、queues/absolute deadlines；普通最多9，续租保留2。lease alias已共享actor，新增renewal facade仅renew使用保留类别，独立control/resolution池不混。queued取消可移除，submitted至真实future归还才释放，borrowed内层不重复；覆盖withConnection/transaction/execute/withSession并导出低基数loan状态。尚在实现，未构建验证，不把此设计当容量解法已证明。


统一物理loan代码与生产接线已合入工作树：shared/isolated actualpool每EL gate，原11普通9/renew2、低容量reserve0兼容，队列与等待沿原配置；同pool所有rolefallback复用wrapper，独立control/resolution/userstate保持。fixedclass loan指标已Contracts→PressureSource→Topology→HTTP→analyzer接线，inFlight包含driver借用等待到actualfuture归还，不叫实际连接使用率。关停在workers/连接/actors排空后才closegate，正常/装配失败/运行失败都等待实际loan收尾，60秒失败退出。

首次聚焦验证`/tmp/imv2-physical-database-loans-focused-tests-20261001-r1.log`编译失败：新增测试line81 generic withConnection<Void>未推导，没有执行任何测试。实现已编译，但不能把它记为验证通过。正在明确测试返回类型，并补withSession底层borrow提前失败时finished/available promise幂等收尾，避免遗漏待完成promise；随后仅重跑gate/既有pool/metrics受影响过滤。未启动新PG/Release/容量运行。

### 统一物理借用：受控生命周期验证 r2

已修正新增测试泛型，并补齐 withSession 的底层 borrow 提前失败路径：available 与 finished 都必须完成，finished 由 once 收尾保护，成功、调用闭包失败和借用未进入闭包的失败均等待实际操作结束。r2 `/tmp/imv2-physical-database-loans-focused-tests-20261001-r2.log` exit0，构建106.45秒，8 tests/3 suites 实际0.115秒。新增四项受控测试覆盖9普通+2续租、普通FIFO、嵌套借用只计一个许可、取消调用者不提前释放真实future所有权、早borrow失败不执行session body且槽归零、queued取消和重复shutdown。既有pool的真实PG用例因未提供 `IMV2_POSTGRES_TEST_DATABASE_URL` 条件返回；本次不属于真实PG集成验证。

模块库存同步为593 files/2054 symbols/2037 edges，forbidden0、cross-target SCC0；文档链接、git diff --check与hotspot analyzer六项Python回归通过。原Future/.get不自动取消排队的SDK边界保留：只有显式request及asyncSQL/session取消路径可移除queued；submitted始终等待底层实际结算。loan inFlight包括driver借用等待，不等于实际PG活跃连接数。新Release正在session89909构建，日志 `/tmp/imv2-physical-database-loans-release-gateway-20261001-r1.log`；新TCP与正式容量仍待验证。

Release实际exit0，构建196.60秒。只读复核未发现shared pool角色绕过gate；独立control/resolution/user-state-route保持独立池。transaction入口SDK先BEGIN再进入requireLive，过期借用会ROLLBACK、不执行用户closure或COMMIT；不宣称过期后绝无协议SQL。正式预检首次命令因candidate路径多写一层IMMonorepo在可执行检查阶段exit2，没有创建结果目录或启动服务；修正路径后新canary session95700实际exit0。

`/tmp/imv2-physical-database-loans-handoff-canary-20261001-r1`真实六GW TCP预检通过：120在线/132auth、12/12reports，1020 submit/accepted/ACK，12heldACK/reconnect全部恢复；failed/workloadFailed/overflow/abandoned均0，120最终前台游标missing/behind/ahead均0。中间live gap1、metadata gaps20仍保留，不说所有中间提示零gap。该canary只证明小规模实际驱动/恢复质量，不能当容量验收。新原参数候选 `/tmp/imv2-physical-database-loans-tcp-5000-20261001-r1` 已启动session66609；保持50k、5000/s×90秒、checkpoint180及原quality，尚无完整90秒/≥80%结果。

### 统一借用正式 r1：保留槽生效，仍有围栏等待与恢复放大

session66609实际exit1，50k全部预热且执行原checkpoint180，发送约10秒Loader质量guard终止。7/12reports（缺0/3/5/7/10），已有报告交集23:18:19.417–29.430，10.013秒。整轮已有报告合计messagesSent29004/ACK4551/workloadFailed24849/overflow21/abandoned137；缺报且90秒未完成，不能与前轮部分报告计算全体容量收益，不运行无效baseline。PG已23:19:00.567 shutdown。分析在根目录message-hotspots.json。

只有两个phase内采样+0.186/+5.389，counter baseline早5.072秒、末缺4.625秒。末sample六GW ordinary inFlight均9，queue[159,133,175,164,154,159]合计944；renewal inFlight[1,2,2,1,2,0]、queue全0，两类reject增量均0。该metric是各GW去重Balanced各EL之和，一般不能叫单池连接使用率；本轮shared配置与9+2预算一致，ordinary满时renew仍grant，证明本批保护实际生效。Directory仍active128/pending1024各GW达限，waiters1627–1665；cachedattempt29997/miss9839/response4183、actualdispatch20167(local3570+remote16597)、lookup2911，hostprobes/waits0。不把lookup增量当每次send都查询，也不归因Host suspect风暴。

完整PG无deadlock；严格phase内6 locktimeouts均为批量续租的rooms ORDER BY FOR NO KEY UPDATE（122/128 bindings），phase外另外14locktimeout+1statementtimeout不混因果。PG锁2→12、idleTxn51→40，匹配XID边出现room_activation_fence争用（13条观测）及二级链；部分blocker类别other，不能把全部锁持有归于续租。阶段均值acquire490ms/receipt458ms/body348ms/control94ms/commit8.9ms属于完成样本及声明的counter范围，不相加为单消息耗时。最早锁超时接近phase末，不能只凭它断言前段所有排队均由续租失败引起。

静态复核发现Host renewLoop对任意renew错误立即scheduleLeaseLoss；已确认回滚的暂时锁超时也使同批多room退休，具备扩大位置恢复压力的结构条件。下一批明确区分renewalDeferred与令牌失效/unknown：仅实际确认未提交的暂时失败允许按原renewalInterval在旧safetyUntil内再次尝试，绝不延长旧授权或watchdog；expired/owner/activationChanged/outcomeUnknown保持立即fail closed。同时评估将续租rooms→leases→fresh DBclock→完整token检查→expiry更新合为一条强依赖集合SQL，保留锁序及重复输入逐项语义。三agent分别负责Host契约、Infra和相关测试；尚在实现，没有新的功能或容量结论。

### 暂时续租失败与持锁往返：实现及聚焦实库 r1

已实施精确renewalDeferred契约：仅V2RoomCallFailure.rolledBack(.unavailable)映射，COMMIT未知仍outcomeUnknown，其它错误不泛化。Host收到deferred后保持lease、safetyUntil、watchdog不变，按原renewalInterval下一次尝试；重试前和跨await返回后重新检查entry identity/generation/token/phase及isSafe。旧期限到达仍退休，晚成功不能复活；未知结果和owner/activationChanged/expired维持原立即退休。应用层DomainCompletion将renewal-only新错误保守映射outcomeUnknown，避免将“续租未提交”误当“业务未提交”的证明。

单SQL草案在审查中发现等room锁期间前事务插入lease对原statement snapshot不可见（EPQ仅更新既有行），故最终保留两个statement：先sorted rooms FOR NO KEY UPDATE取得完整owner值，再以新snapshot执行sorted leases FOR UPDATE→count aggregate耗尽锁→volatile fresh clock→perordinal完整检查→合法同room最大expiry集合UPDATE与逐项结果。由原四次业务SQL往返降到两次，不弱化锁或更新已过期lease；invalid sibling不被同room合法更新修复。成功行缺失UPDATE RETURNING、ordinal或count不一致使整个实际事务回滚。原timeouts、128批大小、两inflight与2ms窗口保持。

`/tmp/imv2-renewal-deferred-focused-runner-20261001-r1.py` session31810实际exit0；日志 `/tmp/imv2-renewal-deferred-focused-tests-20261001-r1.log` build119.82秒。真实PG suite三个函数2.755秒（其中实际锁等待参数false/true两case）：129续租真实事务边界/排空；独立错误及同room错token+两个valid不同duration同批最大expiry；实际lease锁等待到DB过期后不复活，以及实际200ms locktimeout确认回滚→typeddeferred→释放后成功续租。Host四函数0.827秒：deferred后成功、连续deferred原watchdog退休、unknown立即退休和既有延迟成功不能复活。PG由runner finally停止，未运行无关suite。

模块593files/2054symbols/2038edges，forbidden0/SCC0；文档链接及diffcheck通过。本批Release正在session54906，日志 `/tmp/imv2-renewal-deferred-release-gateway-20261001-r1.log`，新TCP和原固定容量仍未验证，不能从聚焦功能通过宣布正式吞吐改善。

Release r1实际exit0、164.40秒；最终只读审查提出第二statement UPDATE target旧snapshot与locked_leases的EPQ新expiry比较可能预过滤。先新增实际锁变更反例而未修改实现：r2 `/tmp/imv2-renewal-deferred-focused-tests-20261001-r2.log` session53778 exit1，build100.80秒，单function0.385秒确认前事务持lease锁→续租实际等待→前事务延长expiry并COMMIT后，续租错误返回corruptPersistenceState。该受控lease行变更证明新SQL的可用性边界，不把维护式holder变更外推为正式压测全部根因；失败PG已23:54:59.877 shutdown。

最小修复保留FROM renewals JOIN locked_leases，UPDATE只按已锁room主键定位；完整授权仍在MATERIALIZED checked中根据已持room锁与锁后lease最新值校验，renewals只含failure=NULL项，不能更新未锁行。去掉对target旧snapshot的重复token/expiry比较，避免错误预过滤；结果缺失、ordinal/count异常仍整个事务回滚。r3 `/tmp/imv2-renewal-deferred-focused-tests-20261001-r3.log` session62818 exit0，build10.84秒，受影响真实PG四functions3.242秒全部通过，包括新增锁后expiry延长反例（0.418秒）与原混合错误/重复token、129批次及锁后expiry/confirmedrollback两case。Host代码未再变，未重复其r1测试。PG已finally停止。本批修复后的Release r2正在session91357；旧r1二进制不用于新TCP，容量仍未验证。

Release r2实际exit0、170.49秒。新六GW TCP `/tmp/imv2-renewal-deferred-handoff-canary-20261002-r1` session74147 exit0：120在线/132auth，12/12reports，1020submit/accepted/ACK，12heldACK/reconnect恢复，零failed/workloadFailed/overflow/abandoned，120最终前台游标全部追平；中间live gap4/metadata gap29仍保留，不说提示全零gap。PG已00:06:28.027 shutdown。本批正式原参数候选 `/tmp/imv2-renewal-deferred-tcp-5000-20261002-r1` 已启动session35488；无构建/测试并行，保持原50k/5000×90、checkpoint180及quality，尚未获得正式容量/≥80%结果。

### 续租整改正式 r1 终态与用户要求的1000档快速诊断

正式session35488实际exit1，PG00:16:02.085 shutdown；这次12/12reports齐全，但phase仅10.007秒，未完成90秒。整轮messagesSent49554/ACK12331/workloadFailed37608/overflow37/abandoned401，50000最终viewer9617落后。完整PG阶段counter死锁0，两个采样baseline早1.966秒/末缺1.577秒，ordinary末queue合计1054、renewalqueue0；Directory仍128active/约1024pending每GW，cachedresponses6657（已纠正早期口算6757）、hostprobes/waits0。阶段room_activation_fence等待仍有观测；存在退休，但缺少renewalDeferred分类计数，不能证明每次退休原因或称类型恢复风暴。另有20953条独立user-state-route池timeout全在phase外，不能直接归因阶段质量失败。不把前次缺5片报告与本次全片直接算容量增益。

用户明确要求后续先缩放到1000档。已新增 `IMV2/load-scenarios/actor-realtime-scaled-diagnostic-1000.json`：保持原persona、TCP、单连接有限排队、完整错误/排空/游标校验，消息1000/s、sync20/s、发送30秒，跳过checkpoint180。runner增加显式 `--allow-scaled-diagnostic`，与small canary互斥，记录scaledDiagnostic，禁止计入正式50k/5000/90/≥80验收。已异步询问用户online规模；超过合理等待未回复后按明确说明的默认1万在线执行，不改变最终门槛。

`/tmp/imv2-renewal-deferred-tcp-1000-20261002-r1` session34560：12Loader都exit0，29988submit/accepted/ACK，failed/workloadFailed/overflow/abandoned均0，10000最终viewer全部追平，实际rate-1000共同窗口30.000秒。runner仍exit1，原因是新增场景时漏改原汇总只筛rate-5000，造成steadyState0的假失败；原result.json/driver终态保留不覆盖。现已按场景唯一message phase自动选择，可用--measurement-phase显式指定且严格验证唯一存在，两条summary成功/失败路径都接线，并将measurementPhase记入evidence。新增一个无需服务的Python回归验证1000选定阶段、错误阶段和缺失一片均正确判定，实际通过。

未重跑负载：按修正函数对已有12份原始报告再分析，并复用原实际SQL对账的foregroundDelivery，生成独立 `candidate/result-reanalyzed-rate-1000.json`。qualityPassed=true、steadyState共同窗口30秒、约998.706ACK/s、formalCapacityAccepted=false；中间live gaps2168/metadata gaps7106仍保留，不能称即时推送全零gap。PG已00:21:19.221 shutdown。该快速诊断证明1万在线/1000速率质量通过，不证明5000正式或≥80%目标完成。后续实现迭代先这一档，通过后再决定更高档及最终验收，不每次直接重跑5000。


### 完整 owner cohort：实现与聚焦实库验证

Store 保留按深度 round-robin 交错的原输入顺序，但只调用一次 durable append；Path 一次真实 preflight，以 per-room command/timeline state 和 per-shard/profile/lease/generation admission state 滚动，支持本事务首次 producer 和 reciprocal reply 事实。Policy 额度按有向 pair 同冻结 now/cutoff 累计一次 upsert，回复按 room 聚合 distinct sender 并精确推进 revision；Projection 按 direction 保留最早 transition 的 ordinal/sourceEvent，并将同 room 两方向 pair UPDATE 聚合成一行。原 128 handles/256 commands 与全部预算保持，不使用无陌生人/无首次投影的窄化路径。

quota 不足时集合路径的 confirmed rollback 进入原 scalar fallback，保留 accepted 合法前项、rateLimited deferred 超额项。授权/损坏导致的 turn 失败不提交前缀；unknown commit 不拆分、不 fallback。

真实 PG `/tmp/imv2-durable-owner-full-cohort-focused-runner-20261002-r1.py` session81139 exit0，日志 `/tmp/imv2-durable-owner-full-cohort-focused-tests-20261002-r1.log`；build100.23秒，3 functions/5参数cases共7.965秒：waves 消息/completion 集合 SQL 各一次及重放/混合 fresh/坏第二命令整 turn 隔离；[A,A,B,B] 双方向首投影 sourceEvent/ordinal、revision+2/B回复不耗陌生人额度，及 [A,A,A] limit2 前2accepted/第3deferred、健康room不受损、重放不重复额度和投影；真实 COMMIT unknown attempt1/isolation0/scalarfallback0。runner finally 已停专属 PG（证据 `/tmp/imv2-stages-pgvjf0ay`），未重跑无关 Swift suite。

模块593 files/2054 symbols/2040 edges，forbidden0/SCC0。新增整机资源采样实际读取 CPU tick、VM、swap、pressure 成功；Python phase/资源边界与 summary 共8 tests通过（无服务、总约0.005秒）。新 Release 正在session7882，新1000档与最终固定容量尚未验证。

旧5000档资源复核：`/tmp/imv2-renewal-deferred-tcp-5000-20261002-r1` evidence cpuCount14，当前硬件48GiB；该失败phase两样本的相邻区间 owned Gateway CPU约5.405核/PG1.450核/Loader0.427核，Gateway各约0.88–0.92核。Gateway各采样峰值RSS之和约8.144GiB、Loader约2.693GiB，二者不是整机内存使用量。旧日志没有整机pressure/swap/全体CPU，不能排除外部资源竞争、单线程瓶颈或外推90秒容量。新增host采样供下一轮判断；1000档10k与5000档50k同时改变在线数/发送速率，不能视为只改变单一变量的对照。


完整cohort Release session7882实际exit0，日志 `/tmp/imv2-durable-owner-full-cohort-release-gateway-20261002-r1.log`，161.27秒。新1000诊断 `/tmp/imv2-durable-owner-full-cohort-tcp-1000-20261002-r1` session1974实际exit0：12/12 Loader exit0，29988 submit/accepted/ACK，发送失败/overflow/abandoned0，10k最终游标全部匹配；共同窗口30.005秒、999.425ACK/s。中途livegap4160/metadata9254非零，不能称即时推送无缺口。scaledDiagnostic=true，不计正式容量验收。实际PG由runner finally停止。

1000新host采样：共同窗口内5快照/4完全内部CPU区间，CPU idle25.70–44.04%，swap used959.56MiB不变，vm_stat Swapins/Swapouts/Pageouts累计计数均不增长，pressure raw级别均1。旧占用swap不是本轮新增交换的证据。ordinary/renewal loan queue在五采样中各节点max0，Directorypending采样峰[4,1,2,0,0,1]；PGblocked峰2、statementAge峰17.914ms、无死锁。Gateway counter baseline提前0.049秒、末缺4.551秒，host baseline提前0.127秒、末缺4.585秒。Gateway CPU合计4.420核、PG3.515核；不从异构核空闲比例排除局部线程/P核饱和。

为隔离在线人数因素，仅将同10k场景的 rate-1000 改为 rate-2000 和2000/s，其它参数不变，场景 `/tmp/imv2-actor-realtime-scaled-diagnostic-2000-20261002-r1.json` 的hash由runner保留。`/tmp/imv2-durable-owner-full-cohort-tcp-2000-20261002-r1` session55253实际exit1：分片3在约20秒质量guard退出，其它被runner取消，只有1/12report，不能统计全体吞吐/失败率或称30秒完成。该report正式phase2998ACK、SERVER_REJECTED_SERVER_BUSY385，终态4个TCP_DEFERRED_RETRY_EXHAUSTED触发guard，收尾301个connectionclosed unknown不能全算初始失败原因；overflow6，最终834viewer中311未追平。PG已finally停止。

只按唯一已有report的20.007秒部分覆盖phase取样（缺11分片边界明确）：host4快照/3内部区间，idle14.13–14.78%，pressure raw1，swap使用及Swapins/Swapouts/Pageouts未增加；GatewayCPU5.357核/RSS采样峰之和2.183GiB，PG5.434核。ordinary最后均9、queue采样峰[10,14,7,7,14,9]、renewalqueue0；Directorypending峰[4,5,2,2,8,4]，此次并没有原5000满1024的Directory现象。PG lockwaiter采样峰30、实际观察fanin12、statementAge峰0.606秒，实际tuple/XID匹配有admission pool与roomfence链，deadlocksdelta0；blocked观测次数不是独立等待人数。已完成body阶段均值约241–265ms、acquire约7.3–8.0ms，统计有baseline早3.208秒/末缺2.553秒的边界偏差，不相加冒充端到端延迟。CPU压力比1000高，memory交换无增长；仍需区分CPU忙与共享准入锁/持锁执行的交互，不将资源因素完全排除。下一步优先源码与既有样本定位，不再直接跑5000。


2000失败入口复核：phase内 gateway_commands 仅 accepted、message_operation_internal_failures各分类delta0、物理loan/数据库work拒绝delta0；唯一report phase `SERVER_REJECTED_SERVER_BUSY=385`，没有域DEFERRED事件。Loader错误code `TCP_DEFERRED_RETRY_EXHAUSTED` 是通用重试耗尽名，不能误称域层配额deferred。源码V2GatewayByteStream在进入DomainHandler之前按 connection_count/connection_bytes/process_bytes拒绝并回应SERVER_BUSY，该入口目前没有具体reason指标；现证据强烈指向此处，但不能尚无保留字节gauge就断言某个预算触发。配置真实为server每conn4/4MiB/process64MiB、Loader8logicaloperation（各operation一wireattempt）；busy后的4次重试等待约4–11.5秒加RTT可在20秒内耗尽，非必须等60秒总deadline。

Thread topology复核：DB独立1-loop组；TLS child组默认System.coreCount（14），acceptor独立1；Cluster另2-thread NIO组与dispatcher；HTTP另Vapor组。每GW约0.9core不意味着整个服务只能用一个核。已有EL lag仅TLSchild聚合，不覆盖DB/Cluster，不能以低TLS汇总lag排除DB单loop或Swift executor热点。硬件10 Performance+4 Efficiency，aggregate CPU idle不能推出P核余量。

PG链复核：四sample lockwaiter20/27/30/25，admission等待13/13/14/13，roomfence7/14/16/12；实际tuple对象匹配证明等待共享pool行。第一样本tupleholder54909→XID80655→54926(lastadmission/ClientRead)，末样本holder54891→XID104286→54931(lastadmission/idle-in-txn ClientRead)，说明持pool锁期间仍跨应用往返；transaction_age不是该行锁持有时长，不能说UPDATE本身耗去完整body时间。当前末尾为ordered pool SELECT→Swift校验→fresh gate UPDATE→RELEASE SAVEPOINT→COMMIT。下批可评估单group完整条件UPDATE成功快路径，零行回原严谨路径/分类，不猜失败或盲重试；多group原新snapshot/全组gate不弱化。另应补TCP入口封闭reason与body固定分段计时，保持预算不变。尚未实施或验证此下一批，完整50k/5000/≥80%仍未通过。


### 单组尾部 UPDATE、移除未用 SAVEPOINT 与入口分段观测

本批已实现 single admission-group 完整条件 UPDATE 成功快路径，RETURNING 严格身份/lease/expiry/used/limit校验；SQL成功零行才继续同事务原严谨两statement，异常或mutation后decode/guard失败不重扣。多组逻辑、原budget/TTL/deadline保持。实际 cohort 原 SAVEPOINT/RELEASE 无 ROLLBACK TO 使用，删除这两SQL，真实外txnrollback/isolation/unknown仍原规则。新增10个固定owner-body子段计时，optional recorder只测实际await操作；生产共享message budget直接接3固定TCP拒绝reason与实际保留字节/请求数、生命周期峰值，原窗口/预算未改。

实PG聚焦r1 `/tmp/imv2-owner-tail-ingress-focused-tests-20261002-r1.log` session49120实际exit1，build104.51秒：真实PG7 functions通过13.946秒，包括等待最新counter/旧snapshot满窗口后reset两case及实际transition-table审计fast[1]/fallback[0,1]，两旧snapshotwaiters、FK KEY SHARE、不超额度的并发cohort、整turn坏第二command隔离、5类preparedauthority/持久throw/latequota及COMMITunknown子timer均归零。TCP3reason×normal/cancel共6case通过0.004秒，取消后handler未结束实际预算仍保留。唯一失败是HTTP指标测试旧literal阶段数8，新增后实际18；不伪称r1整体绿色。

Root将HTTP断言改为封闭enum allCases数量，只重跑受影响函数：`/tmp/imv2-owner-tail-ingress-metrics-tests-20261002-r2.log` session45764实际exit0，build26.84秒、1 function0.120秒。没有重跑PG或前门测试。PGfinally已停（证据 `/tmp/imv2-stages-65ynbolv`）。Python入口counter/水位/phase回归8项通过0.005秒。模块593files/2058symbols/2046edges，forbidden0/SCC0；文档链接/diff通过。Release session99185正在构建，日志 `/tmp/imv2-owner-tail-ingress-release-gateway-20261002-r1.log`，本批新TCP1000/2000与最终5000仍待验证。

### 单组尾部与入口观测：Release、1000/2000 终态及资源判断

上述 Release session99185 已实际 exit0，构建164.61秒。该二进制用于本批两轮诊断，没有并行构建或测试。`/tmp/imv2-owner-tail-ingress-tcp-1000-20261002-r1` session37322 实际exit0：12/12 Loader exit0，29988 submit/accepted/ACK，failed/workloadFailed/overflow/abandoned/终态排队均0，10000最终viewer全部匹配；共同窗口30.009秒，999.287 ACK/s。中间live gaps4934/metadata10261保留，不能称即时提示无gap。六GW入口三类拒绝增量均0；完成body均值18.252–18.554ms，cohort admission子段0.525–0.689ms。整机内部CPU采样区间idle24.554–45.186%。这是缩放诊断通过，不是正式容量通过。

同10k场景只将发送速率改为2000/s，`/tmp/imv2-owner-tail-ingress-tcp-2000-20261002-r1` session95644 实际exit1：约20秒质量guard终止，仅分片6/7/9的3/12报告完整，其他被runner取消；可用报告共同窗口20.010秒，未完成30秒。三份整轮报告合计9906submit/8875ACK/1031workloadFailed，最终2499viewer中864落后；不能把部分报告当全体吞吐或与前轮缺报结果计算容量收益。SERVER_BUSY是已记录的入口事件，TCP_DEFERRED_RETRY_EXHAUSTED是Loader通用重试耗尽名称；收尾connectionclosed unknown不是初始根因。两轮专属PG均由runner finally停止。

本批入口指标直接证明可观测覆盖内的3346次拒绝全部为connection_count（六GW分别564/549/553/538/584/558），connection_bytes与process_bytes各节点均0。实际reserved_bytes采样峰87–98KiB/节点；其生命周期峰另计，不能当phase峰。原每连接4请求、4MiB与进程64MiB未改变。Loader8个逻辑operation共享该wire窗口，重试和结果恢复也消耗同一实际请求预算，handler实际收尾之前不返还槽。生产App有自己的account/service调度，不能将Loader8直接称为App默认并发。

完成样本body均值159–171ms，cohort admission57–64ms，acquire9.2–10.4ms、commit4.3–5.0ms。注意owner_body及acquire/commit包含scalar与cohort，新增10子段只覆盖cohort；例如GW0 body completed404而owner_locks340、owner_admission338。不能用父均值减子均值之和推算Swift剩余CPU成本。Gateway counter baseline早3.198秒、末样本缺2.615秒，4个phase gauge样本，completed平均与计数均仅代表该披露范围。

ordinary loan queue采样峰为12/16/8/6/13/11，Directory pending峰5/8/0/3/5/8，本轮不是Directory1024排队饱和。PG blocked峰13，实际观察fan-in峰7，statementAge峰0.307秒，database.deadlocks增量0。末样本可匹配pool tuple→XID→idle-in-transaction/ClientRead的持锁者，并有room fence→pool waiter→同持锁者的链，证明共享准入争用可向房间围栏传递；transaction_age与statement_age不等于该行锁持有时长，不能将整个admission子段认作持续SQL锁等待。

当前正常单组tail是conditional UPDATE→RETURNING校验→Swift结果组装→外事务COMMIT，成功后不执行锁SELECT/第二gate SQL，也已无cohort RELEASE SAVEPOINT。只有成功零行fallback或多组才保留两段SQL；PG的admission_credit分类还不能区分fast与fallback，不根据最后SQL分类猜执行分支。下一步可将不依赖quota结果的严格结果组装移到quota前，并观测UPDATE实际完成到COMMIT分发间隔；不能提前提交或在未知结果时重扣额度。

资源证据：当前本机14核（10P+4E）、48GiB，服务为原生进程，没有本轮容器CPU/内存配额；Loader max-rss guard不属于Gateway资源分配。2000窗口三个完整内部区间整机idle13.675/14.218/14.859%，Gateway约5.348核、PG约5.443核，CPU压力确实比1000高，不能用异构核aggregate idle排除P核或单EventLoop饱和。Gateway各采样RSS峰之和约2.337GiB，仅是这些进程，不能当整机内存使用率。四个phase快照pressure raw1，swap used959.56MiB不变，Pageouts/Swapins/Swapouts均不增长，没有本轮新增内存交换压力的证据。历史5000运行缺完整host采样，不能事后证明当时资源充足。

因此1000通过不能线性外推5000：更高到达速率可能越过串行共享资源的处理能力，增加持锁和在途时间，再触发入口拒绝与重试。当前已证明拒绝机制与锁链，CPU对执行/调度延迟的贡献仍需短窗口、时间对齐的CPU栈与提交间隔观测；不先扩大连接池/在途上限/线程数来掩盖拐点。正式50k/5000×90秒、checkpoint180及候选≥原版80%仍未达成，本批未重跑正式5000。

### 持锁后结果组装前移及准入语句细分类

本批将完整per-handle ordinal排序、命令数量/每项结果验证、newlyAccepted数组与OwnerCohortCommit值构造移到最终quota mutation之前。proof/receipt的SQL及授权仍在原外事务内，quota失败丢弃预构造值并整体回滚；成功后直接return，observer仍等真实COMMIT成功后调用。没有提前提交、放宽准入或在unknown时重投，不能仅凭代码前移宣布吞吐收益。

三条quota SQL首部增加固定comment marker，PG采样新增admission_fast_update/admission_lock_select/admission_gate_update；原无marker admission_credit历史兼容，relation锁分类仍admission_credit。首部marker在query截断1024字节时也可识别，sampler仍不保留SQL文本/参数，queryCategoryVersion升级admission-entry-v3。

`/tmp/imv2-owner-precommit-focused-runner-20261002-r1.py` session69397实际exit0；build121.19秒，真实PG3函数/8参数case共10.237秒，覆盖五类preparedauthority（含late quota）、COMMIT unknown及fullcohort首次producer/reply/quota边界。实际PG分类probe11项全部通过，独立结果 `/tmp/imv2-owner-precommit-pg-category-probe-20261002-r1.json`；专属PGfinally已停（`/tmp/imv2-stages-ldt6wyvw`）。Python summary2项+analyzer9项回归通过，共约0.007秒；没有重跑TCP/HTTP未改suite。模块593files/2058symbols/2046edges，forbidden0/SCC0。

Root新增opt-in `profile_v2_owned_benchmark.py`：仅允许明确scaled诊断，校验六GW确为指定runner的直接子进程、PG属于该运行postmaster；phase日志到指定秒后采前两个GW、已观察终端blocker及最高累计CPU的owned PG进程，最多4个3秒/10ms并行sample。保存实际采样起止/所选PID/原观察时间和profilingOverhead，明确不计容量对照；不持久化进程参数或SQL。栈样本不是CPU利用率，不能将睡眠线程的sample数解释成执行热点。尚未实际运行此工具。本批Release session32075正在构建，日志 `/tmp/imv2-owner-precommit-release-gateway-20261002-r1.log`，新1000/2000仍待验证。

本批Release session32075实际exit0，164.91秒。`/tmp/imv2-owner-precommit-tcp-1000-20261002-r1` session46989实际exit0，不带栈采样：12/12 Loader正常退出，29988submit/ACK，failed/workloadFailed/overflow/abandoned/endqueue均0，10k最终viewer全部匹配。共同窗口30.004秒、999.438ACK/s。live gap4782/metadata10095保留；三类入口拒绝增量均0，完成body均值17.606–18.319ms、cohort admission0.599–0.713ms、commit0.378–0.454ms。内部host CPU idle22.626–44.564%。这是缩放质量通过，不能由相近指标宣称容量收益。

`/tmp/imv2-owner-precommit-profile-tcp-2000-20261002-r1` session47413实际exit1，runnerPID95106，仍同10k只改rate2000。约20秒Loader guard失败，只有report1/3完整（2/12）；可用共同窗口20.009秒，三十秒未完成。两份整轮报告6567submit/5765ACK/802workloadFailed/44overflow/55abandoned，最终1668viewer中646落后；取消收尾不等于初始根因，不用缺报数据推全体吞吐。实际PGfinally已停，终态没有本轮Gateway/Loader/build/test遗留进程。

profiler实际exit0，四份样本成功；manifest在candidate/stack-profiles/manifest.json。日志缓冲使标记被观察时已second13，不能称计划的第5秒开始；四项实际采样覆盖约+13.6至+18.5秒（具体起止保留）。两GW为95201/95202、PG为95268/95208。本轮CPU与延迟含明确profile开销，排除性能对照。指标baseline早3.257秒、末缺2.521秒，host早3.288秒、末缺2.657秒。入口采到3460次connection_count、两类bytes0；body完成均值155.9–168.9ms、cohort admission49.0–61.7ms、commit3.93–4.64ms。CPU idle11.703–13.503%，PG合计约5.357核，swap959.56MiB及换页累计计数不增、pressure raw1，不作为无开销资源容量结论。

PG新分类phase快照观察到fast_update等待24次、旧admission_credit7次、roomfence14次，lock_select/gate_update未观察到；这些是观察次数，不是SQL调用总数。blocked峰20/fan-in峰7/statementAge峰0.315秒，deadlocks增量0。末快照实际XID99484匹配：fast95276与旧tail95270等待95239，后者idleTxn/admission_fast_update/ClientRead。明确证明正常fast UPDATE完成后的未提交事务仍可传递阻塞；106ms的transaction_age不等于post-UPDATE间隔，不由此给出完整持锁时长。

两份PG树分别252/249个主线程采样：95208有169客户端输入分支、60 LockRows→XIDwait；95268有132输入、48 LockRows wait，修改器样本也含tuple/XID/multixact等待，计划与COMMIT/WAL分支只有少量样本。均不能换算成CPU百分比，两个PID整段实际CPU约0.065/0.059核，也不能代表所有PG执行。选择时所谓terminal95268在非原子快照中实际是tuple等待者（blockers未捕获但别人指向它），不是被证明的持续根持锁者。Root已修正下一次selector同时排除blocked表及blocker子表里可见Lock等待，命名observed_nonwaiting_edge_endpoint；本轮manifest不改写，仍不能从新选择策略推断旧身份。

结果前移后2000仍失败，不能宣称问题消除。下一步应以实际quota future成功结算与COMMIT分发两个事件测量间隔，区分应用continuation恢复、结果解码/核验与数据库COMMIT等待；当前子段从await开始到返回无法分开。任何改为NIO连续推进的实现都须在mutation结果严格核验、原deadline检查及实际COMMIT未知合同之后成立，禁止盲pipeline quota+COMMIT。正式50k/5000×90秒及≥80%仍未通过，本批未重跑正式5000。

Gateway双栈审查同样没有闭合某个CPU根因：JSON/Protobuf/签名/Directory/SQL row decode均有执行观察，但没有足够样本证明其中某项或单个EventLoop饱和是主瓶颈；Future/Task桥接的少量栈出现也不能直接证明scheduler延迟。下一观测必须在真正NIO future完成处记时间，在实际COMMIT调用处记另一点，并区分single-success/fallback/multi-group；仅在helper await返回后启动timer会漏掉待确认的continuation恢复间隔。两份子代理只读审查保留在 `/tmp/imv2-precommit-profile-pg-audit-20261002-r1.md` 与 `/tmp/imv2-precommit-profile-gateway-audit-20261002-r1.md`，不伪造未测量的handoff数字。

### 实际准入结果到 COMMIT 分发的测量

本批增加同一 owner 事务的 handoff 观测。原始 SQL future 的成功 map 回调执行时记 resultReady，原有完整解码和身份/lease/expiry/counter 验证通过后记 validated，在原 deadline 和 beginCommit 检查通过后、紧邻 COMMIT API 调用前记 dispatch。三个固定路径为 single_success、single_fallback、multi_group；两段分别是 result_ready_to_validated 与 validated_to_commit_dispatch。成功零行 fast UPDATE 不计成功验证，fallback 以最终 gate 返回为准。没有提前提交或绕过 mutation 结果校验。

resultReady 是 future 成功回调开始执行，不是 PostgreSQL 执行结束或 driver 内部 promise 结算时刻；dispatch 是调用 COMMIT API，不是 socket write 或确认提交。只有验证成功并实际到达 dispatch 才记一次，COMMIT unknown 仍有 dispatch 观测，dispatch 前 rollback/失败不计。两段在同一事件链内互不重叠，但跨 owner_body 和事务 finalization；不能加到已有父阶段或用不同总体均值相减。所有路径保留零基线，没有完成样本时均值为 None。

真实 PG 与相关指标聚焦 runner `/tmp/imv2-owner-handoff-focused-runner-20261002-r1.py` 的 session27982 实际 exit0；构建107.04秒，7 functions、16参数case、4 suites 共11.930秒。覆盖成功/零行fallback竞争、setwise首次producer与replay、五类preparedauthority、COMMIT unknown不重投、受控NIO future在caller恢复前记录、固定指标聚合和HTTP渲染。11项实际PG分类probe通过；专属PG finally已停，证据 `/tmp/imv2-stages-ebd76lyd`。Python analyzer10项通过0.006秒。模块594files/2062symbols/2050edges，forbidden0/SCC0。Release session38002实际exit0，186.84秒。

该 Release 的 `/tmp/imv2-owner-handoff-tcp-1000-20261002-r1`（session30989）实际 exit0：12/12完整报告，29988 submit/ACK，failed/workloadFailed/overflow/abandoned/endqueue均0，10000最终viewer匹配，共同窗口30.001秒、999.553 ACK/s。livegap4894、metadata10143保留。六GW single_success 的 resultReady→validated平均0.046–0.072ms，validated→COMMIT API平均0.022–0.024ms；fallback/multi无完成样本。混合owner_body平均17.671–18.353ms。Gateway counter baseline早2.108秒、末缺1.502秒，host早2.182秒、末缺1.574秒，6个phase gauge样本。这是缩放诊断通过。

同10k仅发送速率改2000、没有profiler的 `/tmp/imv2-owner-handoff-tcp-2000-20261002-r1`（session75237）实际 exit1。约20秒质量guard终止，只有1/5/6/9/11共5/12报告；可用报告共同覆盖20.010秒，未完成30秒。五份整轮报告合计16492发送、14730ACK、1762workloadFailed；最终4166viewer中1569落后。报告收尾失败不能全部算作最初失败，不能用缺报结果计算全体吞吐。各可用分片phase实际4或5个工作失败，记录accepted、SERVER_BUSY及WIRE_SUBMIT，没有WIRE_QUERY或ATTEMPT_TIMEOUT事件；不能把这轮最初busy归因结果查询。实际PG finally已停止。

2000六GW handoff single_success完成计数为340/337/330/366/344/340。resultReady→validated平均0.597–0.749ms，validated→COMMIT API平均0.033–0.040ms，fallback/multi无完成样本；admission平均49.957–57.060ms，混合body153.883–160.387ms。这不支持“已返回准入结果后的Swift恢复平均耗去数十毫秒”的假设；不能排除罕见尾部、future回调执行前的driver/NIO等待或单EventLoop压力。下一步不能仅凭先前ClientRead快照盲建NIO提交流水线。

采样覆盖内 TCP connection_count拒绝3966次（633/631/709/664/666/663），PG blocked峰17、fan-in峰11、statementAge峰0.136秒、deadlocks增量0。三个完整内部CPU区间idle13.961/14.927/14.993%。Gateway baseline早3.196秒、末缺2.409秒，host早3.221秒、末缺2.450秒，4个phase gauge样本。CPU与锁竞争的相互影响仍需区分；未新增容器配额或放宽budget。正式50k/5000×90秒、checkpoint180和候选≥80%仍未通过。

单独源码复核纠正一个可能误判：正常prepared singleton已通过acceptForOperationBatch延后quota，消息/proof/永久receipt先完成，最终quota后仍有RELEASE SAVEPOINT；public send接口的普通scalar准入顺序不能套到正式owner coordinator。正常eligible singleton仍因candidates.count>1走旧逐项核，可以尝试复用既有集合核以减少往返，但不能据不同总体计数认定这是已证主热点。下一批仅拓宽正常候选分发，失败isolation叶仍用原scalar，COMMIT unknown不拆批、不隐藏重投。审查 `/tmp/imv2-singleton-terminal-admission-audit-20261002.md` 保留。

资源复核补充：上述1000档5个完整内部CPU区间idle22.756–45.403%，按tick加权idle38.175%；2000档3个区间加权idle14.614%。两轮phase内部及预基线至末内部样本的Pageouts/Swapins/Swapouts增量均0，swap used固定959.56MiB、pressure raw1。Pageins有188/196增量，不能将文件pagein当swap，也不能由换页不增长证明所有内存问题不存在。2000两类bytes拒绝全零，1000三类拒绝全零。六GW handoff按完成计数加权的两个part均值：1000为0.056295/0.023666ms（2255次），2000为0.684814/0.035423ms（2057次）。single_success指一个准入组，不代表一个room或一个prepared handle，不能从该标签反算singleton比例。

### 正常 singleton 复用集合核

本批唯一生产逻辑差异是正常候选非空即执行现有owner cohort；原候选过滤、授权围栏、128handles/256commands、最早deadline及confirmedrollback隔离叶未改变。失败叶仍执行原scalar，executePreparedSendBatch不回调集合核，未知提交不重投。正常singleton因此减少旧逐项SQL及quota后的RELEASE；集合核预读也可能有固定开销，需要实测。

聚焦真实PG runner `/tmp/imv2-owner-singleton-focused-runner-20261002-r1.py` session66877实际exit0；构建119.53秒，3 functions、9参数case，共13.025秒。新的single prepared handle双消息正常case验证FIFO、首次投影、完整回执、正常集合commit、重放不再扣共享/陌生人额度；限额case验证真实整体rollback后只一次scalar隔离，第一消息接受、第二rateLimited deferred。COMMIT unknown增加singleton参数，实际异步提交收尾后仍无隐藏重投；原五类preparedauthority回归通过。专属PG finally已停，证据 `/tmp/imv2-stages-p2w88koi`。没有重跑无变化的TCP/HTTP/Host suite。新Release session8647正在构建，性能待实际诊断。

singleton Release session8647已实际exit0，166.47秒。随后 `/tmp/imv2-owner-singleton-tcp-1000-20261002-r1` session29951实际exit0：12/12报告及Loader正常退出，29988 submit/ACK，failed/workloadFailed/overflow/abandoned/endqueue均0，10000最终viewer全部匹配。共同窗口30.006秒、999.417 ACK/s；livegap5264与metadata10539保留，不能称即时推送无gap。质量门槛未放宽，没有profiler或并行构建/测试。实际PG finally停止。同10k只改2000/s的下一诊断 session13626正在运行，目录 `/tmp/imv2-owner-singleton-tcp-2000-20261002-r1`；不提前宣布收益或正式容量通过。

上述1000内部CPU五区间idle34.561–44.158%、按tick加权40.648%；swap/pageout累计计数未增，swap used959.56MiB不变、pressure raw1。六GW三类入口拒绝全0。handoff single_success2747次，两段完成加权均值0.044660/0.020317ms，其余path无完成样本。body2747次/16.897ms、admission2747次/0.488ms、acquire2749次/0.105ms、commit2747次/0.353ms；cohort尝试2749、handle15813、command28487，四类scalar fallback及isolation全0。counter baseline早2.083秒、末缺1.508秒，host早2.146秒、末缺1.586秒；计数差可能跨边界，不能作为失败或完整phase吞吐证据。

2000 session13626已实际exit1，约20秒质量guard终止，只有1/4/6/8/11五份报告，共同部分窗口20.003秒，未完成30秒。五份整轮报告16532发送、14840ACK、1692workloadFailed，overflow65、abandoned68；最终4166viewer中1546落后。各分片phase初始工作失败分别6/5/7/4/4，事件仅WIRE_SUBMIT/ACCEPTED/SERVER_BUSY，cleanup unknown1664不作为初始根因。不能据缺报结果比较全体吞吐或宣称优化收益。专属PG finally停止，终态ps确认没有本轮Gateway/Loader/build/test遗留，仅原Homebrew PG继续运行。

2000采样覆盖内connection_count拒绝3886（641/669/698/608/659/611），两类bytes拒绝全0。六GW scalar fallback/isolation全0，正常singleton分发已命中集合核，但过载仍在。handoff single_success2734次、两段均值0.758730/0.030295ms；body2734次/138.632ms、admission2734次/51.773ms、acquire2761次/9.930ms、commit2733次/4.589ms。cohort尝试2761、handle18383、command30757，完成与尝试计数边界不同，不从差值推失败，也不与旧混合body总体相减算收益。

PG四个phase快照blocked采样峰10、fan-in峰7、statementAge峰0.172秒、deadlocks增量0；观察到fast UPDATE及room fence等待。ordinary loan queue各节点采样峰10/13/10/10/12/17，renewal queue全0。三个完整内部CPU区间idle13.424/14.258/12.987%，tick加权13.555%；swap/pageout计数仍不增长，Pageins/decompression不是swap。Gateway基线早3.235秒、末缺2.487秒，host早3.257秒、末缺2.534秒，PG早3.234秒、末缺2.486秒；采样最大值不代表瞬态绝对峰。

本批功能与1000诊断通过，2000失败未消除，正式5000未重跑、原容量目标未达成。原生运行不存在容器CPU/内存配额；多个Gateway、PG与Loader共享本机14核（10P+4E）/48GiB。现证据支持较高CPU压力与共享锁排队并存，缺少本轮新增交换压力证据；aggregate idle不能排除局部线程饱和，旧5000缺完整host数据也不能事后证明资源充足。后续优先测实际请求槽生命周期与数据库执行成本；若做资源归因对照，应固定场景/质量/代码，把压测客户端或数据库移至独立资源后比较，不能简单放宽入口或pool上限冒充容量提升。

### 锁后回执与证明读取的完整快照

本批依据既有2000阶段计时减少SQL往返：receiptRead完成2753次、均值15.862ms，proof完成2748次、均值21.209ms。它们是各自阶段的完成均值，不与owner_body相减推成本，也不将减少往返直接当吞吐收益。正常有授权attempt的路径，四组回执预读和三组proof预读分别合为一条statement，共减少五次读取往返；无attempt等分支原本跳过SQL，减少数量不一。

完整operation锁及activation围栏先在原语句中取得并验证，然后新READ COMMITTED statement查询execution envelope、accepted/denied domain completion、legacy closure和精确/最新attempt。共用有界unique fullkey JSON与MATERIALIZED input，固定kind UNION ALL避免JOIN乘积，不用COALESCE或LIMIT隐藏双领域结果损坏。initial按原envelope→domain→closure→attempt阶段顺序完成typed与semantic解码；proof仍attempt→domain→owner。compact attempt ordinal显式映射fullkey ordinal，保留缺行占位、计数、重复、身份及完整代次校验。initial optional generation只用于受锁完整command key的绑定参数只读查询，所有attempt校验在return之前完成，不授予写权限。

proof读取是实际领域写入之后的新statement，可见此前本事务产生的持久facts；不用Swift append结果冒充数据库事实。精确代次仍先于任何更新代次，缺精确行才按最新prior检查，future/recipient/fingerprint冲突和aborted规则保持。proof INSERT和永久receipt严格写入、最终quota、COMMIT未知结果和原deadline未变。删除三份无调用的旧SQL wrapper，共用解码；准备期既有existing薄读仍保留。最终独立静态审查无阻断。模块594files/2064symbols/2050edges，forbidden0/SCC0。

真实PG聚焦r1 session15302实际exit1，仅编译失败，无测试运行；Swift Testing嵌套throws宏无法展开，日志 `/tmp/imv2-receipt-snapshot-focused-tests-20261002-r1.log`。修测试外层为明确do/catch主动rollback后，r2 session4217构建62.84秒并实际运行5 functions/8cases：其中setwise双shard、singleton正常/隔离、unknown单/多handle及exact-generation共4 functions/7cases通过；mixed唯一失败，总测试12.244秒。真实PG日志证明probe随机source_event_id违反时间线外键，尚未走到损坏检测，不能伪称该case通过或归因生产快照缺陷。

仅修mixed夹具，在强制rollback事务中从真实accepted completion引用事件并补合法限制活动，再形成accepted+denied冲突；保留完整约束并断言实际插入两denial，事务结束后恢复一条真实denial。r3 session13645仅重跑受影响mixed函数，构建24.32秒、实际0.795秒通过；没有重复已通过的7cases。该case同时验证混合永久事实、legacy closure无envelope、无attempt的ordinal间隔、missing ready、terminal proof重放、实际schema禁止更新proof、错误recipient及双领域结果损坏。三轮专属PG分别 `/tmp/imv2-stages-ib_qfc9i`、`/tmp/imv2-stages-moc89fmm`、`/tmp/imv2-stages-pkwjjt6_`，均runner finally停止。

新Release session91013正在构建，日志 `/tmp/imv2-receipt-snapshot-release-gateway-20261002-r1.log`。新1000/2000诊断及完整正式容量仍待实际完成；本批未放宽budget、未增加pool或机器资源。

该Release session91013实际exit0，161.93秒。新 `/tmp/imv2-receipt-snapshot-tcp-1000-20261002-r1` session60547实际exit0：12/12报告、29988 submit/ACK，failed/workloadFailed/overflow/abandoned/endqueue均0，10000最终viewer全部匹配，共同窗口30.004秒、999.467 ACK/s。livegap5284与metadata10546保留，不能称即时提示无缺口。没有profiler或并行构建/测试，原quality保持，专属PG finally停止。

1000六GW三类TCP拒绝全0，fallback/isolation全0。handoff single_success2685次、两段完成均值0.052522/0.021495ms；body2685次/17.423ms、admission2685次/0.577ms、receiptRead2686次/1.301ms、proof2685次/3.449ms、commit2685次/0.427ms。cohort尝试2686、handle15597、command28595，计数不等于SQL条数。五个完全内部CPU区间idle22.768–44.829%、tick加权37.848%，swap/pageout计数不增，swap used959.56MiB不变。Gateway counter早2.037秒、末缺1.401秒，host早2.100秒、末缺1.476秒。

同10k仅改发送2000/s，`/tmp/imv2-receipt-snapshot-tcp-2000-20261002-r1` session24284实际exit1：约20秒quality guard终止，仅report10一份完整（1/12），可用共同窗口20.007秒，30秒未完成。唯一报告整轮3311发送、2986ACK、325workloadFailed、overflow10、abandoned12，最终833viewer中325落后；phase实际3310发送/2962ACK、4个工作失败，WIRE_SUBMIT3628/SERVER_BUSY390，无query/attempt-timeout事件。cleanup connectionClosed unknown321不作为最初根因。缺11份报告，不能计算全体吞吐、失败率或跨版收益。实际PG finally停止，终态无本轮Gateway/Loader/build/test遗留进程。

2000 telemetry覆盖内TCP connection_count拒绝3085（455/528/522/530/513/537），两类bytes0，scalar fallback/isolation0。handoff single_success2679次、两段均值0.840368/0.034159ms；body2679次/137.470ms、admission2679次/67.492ms、receiptRead2694次/5.418ms、proof2687次/13.657ms、locks2695次/21.109ms、commit2678次/4.536ms。各阶段完成总体及边界不同，不相减推未覆盖成本，不由读取条数或部分报告宣称容量收益。读取与proof完成样本均值较前一轮小，但过载没有消除，等待仍集中于最终共享准入阶段。

三个完全内部CPU区间idle13.188/13.940/14.250%，tick加权13.786%，swap/pageout计数未增。PG blocked采样峰24、fan-in峰13、statementAge峰0.288秒、deadlocks增量0；fast UPDATE等待观察45次、room fence10次，这不是独立等待人数。ordinary loan queue各节点采样峰12/8/9/24/11/19。Gateway counter基线早3.246秒、末缺2.629秒，host早3.268秒、末缺2.678秒，PG早3.245秒、末缺2.628秒。Gateway实际采样CPU约5.277核、PG约5.629核；不足以隔离新snapshot的CPU贡献。没有证据证明它单独增加CPU，也没有完整容量收益证据。

本批完整快照与真实PG语义验证交付，1000质量通过，2000过载仍失败，原50k/5000×90秒、checkpoint180及≥80%目标未完成，本批未重跑正式5000。后续集中检查共享额度行从更新至实际提交的串行边界与全局额度分配结构；客户端handoff小于1ms平均值不能解释整个准入等待，也不能直接证明数据库锁何时释放。任何提前分配信用的设计都必须保留全局窗口上限、原activation/expiry约束、失败/unknown恢复及严格持久提交，尚未实现或验证该下一步。

### 额度冲突在借出数据库资源之前排队

本批按现有 2000 档共享 quota 行等待证据调整 owner cohort 调度，不增加 CPU/内存、连接池或 TCP 预算。capacity profile 在同一 coordinator 固定，prepared activation owner 的 shardID 对应额度行稳定分片键；epoch/incarnation/lease generation 不纳入 key。同 key 实际 cohort 不重叠，等待房间留在原有界内存队列自然合批；一个 cohort 仍可包含同 key 多个房间，不同 key 可按原 in-flight 上限并行。同步 start 先记录 batchID 的完整 key 集合，actual executor/fallback/unknown 路径全部结算后，completed 的同 ID guard 才释放。caller cancellation 与 shutdown 不早释放执行中的资源。

只在 free key 的 ready heads 上计算真正 command 阈值及原 enqueue age 合批窗口。有限一轮 room 扫描跳过 busy key，独立 key 可以继续推进；不借 foreground permit 或物理 SQL 连接等待本地 key。保留原 FIFO、绝对 deadline、pending items/bytes、128 handles/256 commands 和最大实际批次数。调度只是进程内冲突提示，数据库全局额度及围栏仍完整执行，其他 Gateway/旧路径/窗口维护仍可能争用；不能称跨进程锁竞争已消除。

独立静态审查首先发现 all-busy 取消 timer 会让 queued deadline 等当前 SQL 完成才清理。本批修正：schedule 在 full slots/all-busy 时也扫描所有 queued turns，包括 occupied room 后续项；到期只归还 queued budget，实际 batches 不在 queues，key/room/SQL ownership 不变。单次有界扫描同时计算最早未来 queued deadline，仅到期队列重建；busy/full-slot 使用 deadline-only wake，不按过期 coalescing age 轮询。最终静态复核无阻断。模块 inventory 594 files/2064 symbols/2050 edges，forbidden0/SCC0。

没有直接启用旧信用池：reserve 会提前增加 used，未用额度/崩溃扣费与实际 accepted 语义不同，且 refill 另取围栏，不能等价替代当前事务计数。本批受影响测试只运行 durableOwnerCoordinator，使用真实 PG/store-bound preparations 与受控实际 executor 检查调度生命周期，不将该 executor 当成生产 SQL 吞吐证据；Release 和新 1000→2000 诊断须以真实终态补充。

真实专属 PG runner `/tmp/imv2-quota-key-cohort-focused-runner-20261002-r1.py` session66571 实际 exit0：构建111.00秒，5 functions/6cases 全通过，实际测试5.551秒。覆盖同 key 两房间不重叠、独立 key 越过 busy head、多 key 按实际 batchID 释放、同 cohort 同 key 多房间合批、房间 FIFO、取消及重复 shutdown 实际 drain，以及 free slot/all-busy 与 full slot/occupied-room tail 两类 queued deadline。日志 `/tmp/imv2-quota-key-cohort-focused-tests-20261002-r1.log`，PG `/tmp/imv2-stages-dlq1ndui` 已由 finally 停止。未重跑无改动的 preparation collector 或旧 SQL 全套测试。

新 Release session32188 实际 exit0，169.55秒，日志 `/tmp/imv2-quota-key-cohort-release-gateway-20261002-r1.log`。新 `/tmp/imv2-quota-key-cohort-tcp-1000-20261002-r1` session31701 已启动；只有终态才作为本批负载验证。机器 sysctl 实查14 physical CPU（10P+4E）、51,539,607,552 bytes（48GiB），原生进程不存在容器 CPU/内存分配。本机各角色共同占用资源，不能由 aggregate idle 排除局部饱和，也不能由旧 5000 缺失的完整 host 采样证明资源充足。

1000 新诊断 session31701 实际 exit0：12/12 报告、29988 submit/ACK，failed/workloadFailed/overflow/abandoned/endqueue0，10000 最终 viewer 匹配，共同窗口30.001秒、999.517 phase ACK/s，qualityPassed=true。live gap4642、metadata gap9448 仍保留。TCP三类拒绝全0；Store cohort尝试3792、handle17647、command28596、commit3791，按启动分母7.541 commands/4.654 handles，不是按完成分母推批量。single_success handoff3791次，两段平均0.043327/0.018733ms；body3791次/16.708ms、admission3791/0.457ms、commit3791/0.331ms。PG六采样 blocked/fan-in0、deadlock delta0，不能证明不存在瞬态等待。

1000 完整内部五个CPU区间 idle27.189–40.426%，tick加权35.653%；VM内部首尾 pageout/swapin/swapout0，pageins5072/decompression69 并非新增swap；swap used959.56MiB固定。Gateway counter早1.996621秒、末缺1.393912秒，PG早1.995228/末缺1.392868，host早2.061758/末缺1.466138。新1000的 cohort 比旧snapshot更多、平均命令批量更小，不能宣称本档减少提交数或仅归因keygate取得CPU收益。

同10k只改rate2000的新 `/tmp/imv2-quota-key-cohort-tcp-2000-20261002-r1` session43455 实际 exit1：12/12 完整且全Loader exit0，共同消息窗口30.008秒完整结束，整轮59988发送/ACK、failed/workloadFailed/overflow/abandoned/endqueue0。phase内59706ACK（余282在phase外结束），phase确认吞吐1989.618/s，不把整轮ACK直接除以阶段秒数。WIRE_SUBMIT59995、SERVER_BUSY7，实际固定TCP count拒绝[1,0,3,0,0,3]合7、两bytes0。各分片phase ACK p95为324–347ms、p99为380–401ms；不能平均成fleet p95，也不能与旧仅一份报告算完整吞吐增幅。

本轮仍 qualityPassed=false：10000 最终viewer中14落后、无缺失/超前，证据 candidate/foreground-delivery-proof.json。14个不同房间各仅一端差最后1条，成对另一端全到达持久化头；低端均odd、高端even，双方都是真正 targetRoomIDs[0] 前台订阅。message drain 87–157ms、inflight/queued0，post-drain hold10秒，12片 roomEventPullsSent==PagesReceived、retryable pull rejection0。不能把完整发送ACK覆盖最终交付缺口，也不能直接判持久化丢失或已证明 Loader race。Loader drain只含消息/已定义恢复批次等，不含房间pull/grace，尾段仅被动hold；现存snapshot缺 announcedWatermark/pull/grace 状态，仍不足以区分最后hint未到达与收到hint后的推进遗漏。未静默添加强制最终追平或放宽质量门槛。

2000 六GW采样 owner实际inflight各最大1（旧各5），ownerqueued峰[13,13,13,16,16,28]，retaineditems峰[42,54,56,45,42,65]；这是保留有界内存排队后实际观察，不扩大原上限。Store cohort尝试2595/commits2590/handles40817/commands55313，启动分母均值15.729 handles/21.315 commands；counter总体不同，不能由尝试与完成的差值判断失败。scalar fallback/isolation/replay增量0。body2591次/54.369ms、admission2591/3.146ms、acquire2595/1.448ms、commit2591/2.091ms，receiptRead2593/3.898ms、proof2591/10.075ms；不同阶段完成总体不能相减推成本。single_success handoff2591、两段平均0.371575/0.046128ms，其它路径无完成样本。

2000 六PG快照 blocked最大2/fan-in1/statementAge20.843ms，三次实际XID匹配均room activation fence，deadlocks增量0。未采到fast UPDATE等待支持排队减少，但不能称跨Gateway/global额度竞争彻底消失。ordinary loan queue峰[1,18,10,7,4,2]、renewal0；phase ActorRPC accepted56946/overloaded5664，发送侧改动没有消除实时推送过载。CPU五个完全内部区间idle16.140–17.109%、tick加权16.682%；swap/pageout0、swap used959.56MiB固定、pageins378/decompression37。内部相邻PID CPU PG约3.915核、Gateway约6.517核；仍有CPU压力，不能由aggregate idle排除线程或P核饱和。

2000 Gateway counter早3.093089秒、末缺2.257808秒，PG早3.091990/末缺2.256161，host内部CPU观察25.713389秒。和旧snapshot2000的部分窗口相比，观测admission67.492→3.146ms、PG阻塞峰24→2、入口count3085→7，本轮确实完整发送并排空；旧缺11份报告、窗口不同，不将该差异变成相对容量百分比或纯因果量化。本批两轮专属PG finally都停止，终态无Gateway/Loader/build/test遗留，仅原HomebrewPG1995保留。

本批功能与1000完整质量通过，2000完整发送成功但最终游标质量失败；未重跑5000，原50k/5000×90秒、checkpoint180、候选≥80%仍未达到。资源未增加仍显著改变等待表现，支持结构性竞争是此前失败因素，不能仅归因CPU/内存配额；后续先定位最后单条的实时投递/恢复缺口，再进行原规格容量验证。

只读游标审查 `/tmp/imv2-quota-key-cursor-audit-20261002-r1.md` 补充：Loader 的 hint 处理先增加 announced watermark 再连续应用/触发pull；page返回释放槽后仍按 hasMore/announced gap 推进，静态未发现明确停止 guard 缺陷。所有pull==page是报告总体，不能代替逐房间 pending 状态。下一诊断应保留 active/announced/pull-request/retry/grace 与最后hint水位/时间：announced==cursor<head 才指向未得到末尾通知，announced>=head 则检查已知水位后的恢复推进。此诊断尚未实现，不能提前把末尾缺口归因某一侧。正式5000还同时是50k在线，与当前10k/1000或10k/2000不同，不能只按发送速率倍数外推连接维护/推送/资源成本。

### 尾部通知的真实逐房间证据与背压重试

本批先补充观测而未改变业务行为。Loader 的原 authenticated/availabilityHint/activeRoom guard 通过后，只记录最后实际 hint 的水位、序列及wall/monotonic时间；RoomCursorProbe 在单handler EventLoop同步读取 applied/announced、activeForeground、实际pending wire pull/request-after、reserved slot、retry/grace状态。不存在hint的字段为nil，不填造假0；不增加拉取、延长hold或强制终态追平。runner原独立head与quality判断保持；只有真实落后时，另一次只读SQL对最多256 unique rooms记录 wake状态/目标/revision/attempt/next/lease expiry与实际room head，明确无outbox行，4秒statement/5秒process超时。诊断失败独立missing，不替代原quality；不保存payload/token/SQL错误文本。

独立审查无阻断。Loader Release session60977实际exit0，15.23秒，日志 `/tmp/imv2-cursor-witness-release-loader-20261002-r1.log`。新 `/tmp/imv2-cursor-witness-tcp-1000-20261002-r1` session8371实际exit0，12/12、29988 submit/ACK、失败/队列丢弃0、30.002秒和10000最终viewer完整通过。Gateway二进制、TCP/SQL预算和全部原场景质量条件不变。模块594files/2064symbols/2050edges、forbidden0/SCC0。

同10k仅rate2000的新 `/tmp/imv2-cursor-witness-tcp-2000-20261002-r1` session62580实际exit1：12/12且Loader exit0，30秒完整消息窗口，59988整轮发送/ACK、workloadFailed/overflow/abandoned/endqueue0，WIRE_SUBMIT59992/SERVER_BUSY4。phase确认吞吐1988.972/s。最终6个viewer各落后1、无缺失/超前，qualityPassed=false，保持该失败记录，不以14→6宣称吞吐或因果收益。

新客户端真实快照使6个尾差全部可分类：均activeForeground、announced<head，且pullInFlight/pullSlotReserved/retryPending/gracePending全false，最后接受hint距snapshot10.315–20.192秒。所有6个独立房间都有持久outbox，state=pending、attempt_count四个6/两个7、claimable=false，下一重试仍在未来。witness中 room head分别86/22/86/88/80/84；stored target低于head符合pending合并设计，不是旧水位丢失，下次claim在新statement取GREATEST(target,rooms.head)。

客户端state采于05:09:16.602，reports结束05:09:17；只读DB observed05:09:17.547271，已在channels关闭之后，因此不是client/SQL原子快照。此时六条真实wake仍pending，next_at05:09:23.720281–05:09:34.020394，还需6.173–16.473秒；这直接证明观察时修复被重试时间阻挡，但不能断言精确关闭前的row状态。no-outbox-row也不能证明此前没有待重试，因为撤销路由后空fanout可成功删除；本轮实际6条全部存在。

phase采样RPC overloaded4815、failed/rejected/receiver admissionRejected/coverageLoss增量0。旧overloaded指标来自本地global32/perpeer2拒绝，query4拒绝不记该RPC数。支持统一30秒退避不适用于明确本地短时背压的设计判断；outbox未持久保存每次失败类别，不能逐行断言全部历史attempt均为此reason。原relay第6/7次失败均退避30秒，超过原10秒posthold。新诊断采样CPU内部加权idle15.967%，VM Pageouts21/Swapins4/Swapouts0，Pageins1492/Decompressions3279；不能把本轮描述为所有换页计数0，也不能凭少量活动断言内存是尾差原因。PG阻塞采样峰1/fan-in1、room fence等待2观察。Gateway counter早3.204秒、末缺2.408秒；完整边界保留message-hotspots。

据此实施封闭 `V2RealtimePublicationBackpressure` 分类：明确routeQueries/globalRPCs/peerRPCs/receiverQueue容量拒绝，原query4/global32/peer2/receiver预算不变。receiver只有.overloaded归此类，closed/stale及transport保留原失败。fanout仍等所有实际children结束；混合任何非背压错误时优先保留该错误，只有全部失败均有明确背压证明才采用短重试。本地RPC overloaded与receiver rejected的原指标含义保持。

房间及个人同步durable relay共用内部policy：仅typed背压采用基准0.5→1→2秒、cap=min(2,原retryMaximumDelay)，稳定identity+attempt FNV-1a equal jitter在[base/2,base]。未知/transport/closed/stale/SQL错误完整保留原1→30秒；每次仍只做一次持久scheduleRetry，无内存热循环，不刷新lease/revision或提前删除wake。原workerbatch/cadence/15秒lease/10秒hold/质量门槛不变。较短背压重试可能增加claim/重试SQL负载，必须在真实小档验证，不能由源码宣布全部尾差已消失或正式容量通过。

真实专属PG聚焦r1 session4937实际exit1，构建128.11秒、8 functions/20 cases共0.767秒：19cases通过，包括真实commit产生wake、attempt6短重试及持久pending/tokenNULL、未到期不可claim、到期GREATEST新水位、实际恢复成功删除、新提交后旧mark/retry均不能改新revision；以及localglobal/peer容量、receiver分类、mixed非背压优先且slow实际drain、未知失败仍30秒、个人同步相同policy。唯一失败publicationCapacityGates(routeQueries)：测试将四个实际查询同批放开后向同一peer发送，触发原peer2门槛，错误是.peerRPCs；不能描述该case已通过或因此放宽生产容量。日志 `/tmp/imv2-publication-backpressure-focused-tests-20261002-r1.log`，专属PG `/tmp/imv2-stages-657gl918` finally已停。

仅修该测试fixture：query4 case仍以真实store查询gate同时持有四个查询，第五拒绝；释放后返回合法空路由，不再意外触发另一peer门槛。r2 session20111实际exit0，仅重跑publicationCapacityGates函数三cases，构建26.92秒、测试0.001秒；未重复其它19cases或再次开PG。日志 `/tmp/imv2-publication-backpressure-focused-tests-20261002-r2.log`。模块595files/2066symbols/2053edges，forbidden0/SCC0。

新 Gateway Release session28665实际exit0，167.02秒，日志 `/tmp/imv2-publication-backpressure-release-gateway-20261002-r1.log`。此次受影响20cases经上述fixture修正验证，不把r1失败记成通过。

背压策略后的 `/tmp/imv2-publication-backpressure-tcp-1000-20261002-r1` session46760实际exit0：12/12、29988整轮submit/ACK，失败和队列丢弃0，10000最终viewer匹配，30.002秒、999.510124 phase ACK/s。CPU内部tick加权idle36.990%，VM swap/pageout不增；TCP拒绝0、PG阻塞采样0。

同10k只改2000/s的 `/tmp/imv2-publication-backpressure-tcp-2000-20261002-r1` session17083实际exit0：12/12且Loader全部0，59988整轮发送/ACK、phase内59658 ACK，30.005秒、1988.256442 phase ACK/s，10000最终viewer完整匹配，工作失败/overflow/abandoned/endqueue0。没有真实落后，因此不生成wake witness符合条件。WIRE_SUBMIT60084/ACCEPTED59988/SERVER_BUSY96；livegap7628/metadata10754仍保留。原post-drain hold10秒和全部质量门槛不变，尾收敛质量修复获得观测支持；不从小档推正式容量。

代价必须保留：各片ACK p95为582–639ms、p99为971–1256ms，高于前一诊断版2000的p95 359–369ms。TCP count拒绝96（16/14/17/19/14/16），两bytes0。RPC accepted41833/overloaded2786/failed0/rejected0/acceptedAsWatermark0，receiver admissionRejected/coverageLoss0；采样counter不同，不能将overload降幅认作严格因果收益。owner实际inflight各1，queued峰19/12/20/28/40/25；ordinary loan queued峰16/16/6/12/14/5、renewal0。Store cohort attempt1834/commit1828/handles38561/commands55079，started分母均值21.026handles/30.032commands，replay/isolation/scalarfallback0；body1829次/73.463ms、admission1829/4.482ms、acquire1834/4.046ms、commit1828/3.225ms。single_success handoff1829次、两段平均.502721/.052798ms，各stage完成总体不同不相减。

五个完全内部CPU区间idle14.210/14.753/15.093/17.069/16.332%、tick加权15.486%，内部观察25.761978秒；PG约4.584核、Gateway合计6.033核，各自相邻内部采样窗口。swapin/out/pageout0、pageins136/decompression75，swap used959.56MiB固定。PG blocked采样峰5/fan-in2/statementAge101.175ms、deadlocks0，实际等待分类room activation3/other2/admission fast1，不是独立全阶段等待人数。Gateway counter早3.18043秒/末缺2.33175秒，PG早3.17925/末缺2.33036，覆盖相近但不是exact phase。

与前witness2000相邻counter窗口比较，outbox insert4441 vs5668/update10120 vs13065/delete1460 vs3115/idxscan46273 vs46362；最高相邻UPDATE速率482.38 vs536.07/s。数据库xactcommit134631 vs145412，WAL274363773 vs275978594 bytes，无rollback/deadlock/temp增；未见SQL/WAL暴涨。计数包含claim/retry/append/coalescing，PGstats异步，不代表retry专属次数。PG CPU4.584 vs3.985核、body73.463 vs61.758ms、admission4.482 vs3.405ms、acquire4.046 vs1.660ms仍上升，不能宣称零成本或所有性能指标改善。资源未增加，完整50k/5000×90、checkpoint180、candidate≥80%仍待验收。

正式candidate session56038实际exit1，输出 `/tmp/imv2-publication-backpressure-tcp-5000-formal-20261002-r1`，使用paired-policy 50k固定夹具与原正式场景，无scaled/canary标志，6Gateway/12Loader及全部原资源和质量条件保留。全部50000连接认证、心跳无miss，原180秒checkpoint完成；rate-5000共同窗口仅10.015秒（1790891766.603→1776.618），12/12报告均实际失败，未完成原90秒。

phase内5242 ACK、14582 DEFERRED_admissionUnavailable、11878 SERVER_BUSY、65383 WIRE_SUBMIT、172 workloadFailed。整轮49345发送/6020ACK、43586工作失败、overflow56/abandoned591；整轮43121 OUTCOME_UNKNOWN_CONNECTION_CLOSED主要来自quality guard后的cleanup，不作为首次根因。最早日志在约second9开始记录失败，guard的deferred retry exhaustion与大量前置拒绝必须区别于关闭后的unknown。汇总523.429 ACK/s来自短phase，不是正式可接受容量，不用于80%比较。最终50000viewer中6714落后，约5648 announced<head、1066已知水位且pending；测试提前停止，不能将其与完整30秒+10秒hold的小档尾缺口同类归因。只读outbox witness仍最多256 unique rooms，不代表6714全量快照。

checkpoint的真实activeRooms总数在offset约0/62/119/149/180秒为25534→22363→17381→14546→11818，pending/restoring全0；caller缓存locations从55173升至58944，不等于活跃房间数。rate唯一inside（+5.170秒）active resolutions六节点均128，pending为1024/1024/1023/1024/1016/1024、waiters约1545–1602每节点；Host restoring32/32/32/19/30/32、pending59/60/41/19/30/35、activeRooms总12117。缓存miss9256/invalidations1696/recoveryAttempts2519/waits7819/physicalLookups3689，host fault probes0。原idle retirement合同允许闲置房间退役，本轮证明随后冷恢复压力，但不证明此前小档失败也全由冷恢复解释。

唯一inside PG快照blocked0、49 idle-in-transaction（37 ClientRead/12 None），没有足够两端内部CPU窗口或全阶段锁样本；不把idleTxn认作连接泄漏或死锁。ordinary loan各GW inFlight9、queue120/115/147/89/137/120，renewal0–2/queued0；owner实际各1、queued450/440/436/521/497/453，prepactual各5、queued29/33/30/9/3/37。foreground write各1、该work admission queue/rejections0，因此本轮不能写成foreground work controller排队满。采样store实际owner connection acquire55次均331.237ms、body52次172.786ms、admission52次9.946ms、commit52次5.387ms；handoff52次.987161/.070259ms。TCP count采样拒绝987（143/134/195/165/168/182），两bytes0。fixed internal reason只有send.not_accepted.overloaded500，不区分Directory/Host/lane/collector具体门槛，且store domain unavailable另走deferred；它不解释全phase14582延期。不得把当前失败继续直接归为shared quota行锁。

Gateway counter baseline早.060970秒、末缺4.844893秒；PG早.059812/末缺4.843225。host内部只有一sample，近阶段区间开始早.094676秒，约5.104秒内idle34.38%仅作边界线索；没有完整inside相邻区间，严格CPU均值/VM增量未知，summary单点差0不是内存证据。该process快照Gateway每个约1357–1367MiB RSS、Loader每个242–244MiB、Account35.48MiB，memory pressure level1、swap used959.56MiB；RSS不等heap/泄漏/上限。服务原生运行，未观察容器或显式进程CPU/内存限制；现证据更指向冷解析及共享普通loan/owner排队，但不能排除局部线程或瞬时资源竞争。所有本轮服务及独占PG finally已停，原Homebrew PG1995保留。

只读基线审查确认a72f checkout干净，proto、message-send codec及protocol-version与当前一致，原版已支持v45协商和TCP submit/query；新增cursor诊断只report JSON，未发新wire。两版可共用同一Loader和原质量门槛。候选正式失败，所以本批不再启动耗时baseline或重跑5000，也不以部分短窗求80%比例。后续先精确区分cold Directory/Host/turn/owner/preparation拒绝来源，并以有限冷热混合小档核对合并恢复和资源生命周期；不盲增pool/CPU、不改变idle/订阅pin或强制游标掩盖故障。正式容量目标仍未达成。

源码进一步确认普通资源争用：runner固定关闭workload pool isolation，GatewayDatabaseTopology的sync/delivery/projection/maintenance角色回落同一Balanced facade。owner、准备期owner receipt预读、查询、route/wake、投影维护、activation locate/acquire/release以及restore validation共用9个ordinary slots；续租使用同物理pool的renewal类别，最多2个。Host restoring最大32，冷恢复直接进入事务、未走业务work admission，这与89–147普通loan队列吻合，不能把前台work准入0排队解释成资源无竞争。

静态未发现所查cohort/激活链持有连接又等待同gate的循环：Balanced.withConnection给closure底层borrowed；cohort全程使用transaction.sql；控制准备在owner借用前实际结束、控制池独立；Host等待acquire实际返回后才restore，restore validation是新事务。idleTxn可能是SQL间应用续体等待，不能据此判泄漏。下一最小结构候选是在同物理pool总11/普通9/续租2不变的前提下，为冷生命周期借用增加封闭类别及普通额度内的子上限，阻止最多32个恢复占满全部普通槽；locate/acquire/release/restore validation使用共享facade，不给nested借用新额度。下节记录该隔离的实现与验证，不从静态方案宣称可达5000。

### 冷生命周期借用占用普通额度的子上限

本批并行实现封闭loan class activation，默认上限min(2,原非续租容量)，可选policy参数校验1...原非续租容量。canGrant首先校验真实总inflight，再对ordinary+activation合计使用原上限9；activation额外最多2。renewal原保留2，reserve0时仍可借总额度、总11不超。activation队首达子上限时，原pump跨类别继续分配ordinary/renewal；各类别FIFO、全局pending上限和原绝对deadline保持。不新增pool/CPU/内存，不修改idle300/Host restoring32/Directory128/1024、SQL围栏或业务重试。

PostgresV2RoomActivationStore保存一次由原Balanced派生的activation facade，locate/acquire/release只换借用类别；renewal明确使用原renewal facade，非Balanced保持原DB。OwnerResources保存一次activationValidationDatabase，Factory恢复校验使用它，所有handlers与send/receipt/query数据库继续ordinary。facade共享原entries/selection/gate，不注册新拓扑池，不重复指标。nested borrowed直接使用底层连接；实际Future失败、unknown或完成后才归还，取消grant不提前释放，shutdown等全部类别真实归零。

指标导出新增activation固定标签与零基线，nil源仍省略。旧ordinary包含生命周期、新ordinary只含其它普通业务，跨版观察非续租总占用必须ordinary+activation；不把细分后ordinary下降当收益。analyzer按family自动保留新增标签，无需改原阶段选择或质量计算。独立装配、gate及root指标/fixture审查无阻断；模块595files/2066symbols/2055edges、forbidden0/SCC0。

根代理串行聚焦session1146实际exit0，日志 `/tmp/imv2-activation-loan-focused-tests-20261002-r1.log`：构建103.45秒，9 functions/11 cases共1.742秒。Gate受控实际borrowed Future验证2activation+7ordinary+2renewal总11、cold先排队但hot可进入、cold内部FIFO、nested复用、grant后取消仍实际所有权、queued取消/20ms原截止/重复shutdown、无renew预留和policy非法边界。真实专属PG既有alias复用与factory退役后恢复/同ID严格receipt重放通过：factory实际Balanced共享gate，初次acquire+validation计activation2、ordinary0，之后业务计ordinary，两次stop恢复后activation至少6、所有借用实际归零；这不是底层fixture池已11连接的容量证明。HTTP metrics受影响fixture三类非零/零与nil边界通过。私有PG `/tmp/imv2-stages-ju39rktz` finally停止，无重复全套测试。

Gateway Release session1731实际exit0，165.55秒，日志 `/tmp/imv2-activation-loan-release-gateway-20261002-r1.log`。前一Release二进制原样保存在 `/tmp/imv2-publication-backpressure-pre-activation-loan-release-20261002/IMV2ServerApp`，未构建或改写原版baseline；若需同诊断对照可用记录hash，尚未跑这种对照。

仅启动一轮10k/1000×30秒冷热专用诊断session24690，目录 `/tmp/imv2-activation-loan-cold-hot-tcp-1000-20261002-r1`。场景 `/tmp/imv2-actor-realtime-cold-hot-diagnostic-1000-20261002-r1.json` 在原scaled1000前添加270秒零消息checkpoint；300秒idle及原warmup/发送/TCP8与4/排空30/hold10/质量门槛不变，不主动pin房间或强制补拉。warmup时间跨度可产生早期退役与后期存活，必须由实际activeRooms下降且非零证明冷热，不由配置时间宣称。诊断与原formal180秒场景hash不同，禁止混作容量验收或与旧暖态小档直接算改进百分比。

冷热1000 session24690实际exit0：12/12、29988整轮submit/accepted/ACK、phase内29987ACK（1个在drain），30.003秒、999.467376 phase ACK/s，10000最终viewer全部匹配、连接/工作失败及queue overflow/abandoned/endqueue0、无SERVER_BUSY。livegap4971/metadata9497保留，不能称即时投递无缺口。checkpoint近offset0/61/122/178/239/270秒activeRooms为5170/5267/5374/5502/5480/3424，发送前实际下降且非零；phase前各GW532/590/579/580/536/607总3424，phase sampled max合计3869。这证明自然退休和live并存，未分类逐房间cold/hot，不能算各类独立吞吐。

5个phase内样本，activation granted增量1235/1204/1332/1166/1299/1231合7467，ordinary合100219、renewal3947。各类sampled queued峰/rejected增量0；activation sampled峰仅node2=1、其余0，不能由稀疏采样宣称实际占满2槽，硬上限由上述gate及factory测试验证。ordinary sampled峰1/7/1/1/1/1、renewal1/0/0/1/0/0。Directory active/pending峰0/3/1/2/0/1，Host pending/restoring仅node2=1，其余0。TCP三类拒绝与fixed internal failure增量0；store replay/isolation等需按实际counter，不由无队列假定SQL不失败。

owner body3549次均18.809ms、admission3549均.505ms、connection acquire3551均.163608ms、commit3549均.402094ms，single_success handoff3549两段均.055966/.019649ms。owner completed3549、submitted commands25488，不等于整轮ACK数。各片ACK p95 170–176ms、p99 221–262ms；不平均各片百分位或与旧暖态直接求收益。PG5inside blocked采样峰1、statementAge10.224ms，两次room activation fence等待观察，缺matchingXID链、fan-in0、deadlocks增量0，PG内部相邻CPU约3.337核。四个完整内部CPU区间idle27.882/31.110/36.592/35.908%，tick加权32.855%，swapin/out/pageout0、pageins223/decompression64、swap used959.56MiB固定。Gateway counter早.005033秒/末缺4.541130秒，PG早.003468/末缺4.539985；样本峰不代表瞬态绝对峰，资源改进严格因果尚无同cold旧版对照。

沿相同10k夹具/checkpoint270/原质量，仅将消息率与phase名改为2000，session98866运行 `/tmp/imv2-activation-loan-cold-hot-tcp-2000-20261002-r1`，实际exit1。12/12且全Loader exit0，30.006秒完整消息窗口、59988整轮send/59983ACK，phase59604ACK/1986.445538 ACK/s，queue overflow/abandoned/endqueue0、10000最终viewer中1落后。qualityfalse保留，不用全Loader0冒充验收通过。

5终态失败是report3 submit重试耗尽1，report8/9各submit重试耗尽1与query/close未知结果未解决1；各片phase.workloadFailed及second30日志均0，失败分类在phase后7.504/9.559/9.765秒drain结束时完成，不是cleanup connectionClosed。phase只有SERVER_BUSY431/ATTEMPT_TIMEOUT6/RECOVERY_QUERY7，没有domain DEFERRED；整轮SERVER_BUSY453/timeouts12/query29/late11/UNAVAILABLE1/UNRESOLVED1/unknown2。Loader的TCP_DEFERRED_RETRY_EXHAUSTED按submit action统一命名，不能从名字推domain admissionUnavailable，也无逐操作时间将5项直接关联特定冷激活。各片ACK p95 1400–1726ms、p99 2777–3230ms，冷等待成本保留。

checkpoint约offset0/119/180/241/267秒activeRooms5265/5372/5502/5420/3500，真实冷热共存。6inside Directory active/pending峰80/79/68/67/106/109，未采到128/1024满额；Host restoring峰32/27/17/31/21/32、pending48/27/17/31/21/40、leasewait0/2/2/2/1/5。activation实际sampled峰各2，queued55/63/49/66/58/98，granted增量1490/1473/1451/1446/1446/1567总8873；ordinary sampled独立峰各9、queue19/21/13/27/23/18，renewal各2/queue0。独立类别峰不能相加，逐同sample/node已验证ordinary+activation<=9、renewal<=2、total<=11；三类rejected增量0，不可声称loan到期拒绝。业务继续推进与冷生命周期排队并存，不能由它直接宣布5失败的因果或恢复容量已足够。

owner actual各1、queued峰39/36/21/22/38/52；body1628次79.975ms/admission1628次5.390ms/acquire1633次7.923ms/commit1628次3.684ms，各总体不相减。TCP count采样拒绝420、bytes及internal room failure0。PG6inside blocked峰4/fanin1/statementAge36.764ms、7room activation wait观察与6matching XID，blocker类别4admissioncredit/1commit/1other，未见大的pool tuple convoy、deadlocks0，PG内部CPU约3.849核。CPU内部tick加权idle16.541%，swapin/out/pageout0/pageins398/decompression900、swap used959.56MiB固定；不排除P核或特定EL饱和。GW基线早3.082443秒/末缺2.058415秒，PG早约3.081秒/末缺2.057秒，采样不能排除瞬态或替代完整operation trace。

唯一落后为report5/index589：head2、applied/announced1，activeForeground、无pull/retry/grace/slot，最后hint水位1在phase结束后约1.223秒、至snapshot9.627秒。DB witness比客户端snapshot晚13.334秒且channels已关闭，此时no_outbox_row；不是先前attempt6/7未来pending的正证据，不能推活跃期间一定没有wake或客户端已送达。未获知最新水位的位置尚未定位，不静默强制拉取/加hold使其过关。

本批两个私有PG与所有运行服务finally已停止，原Homebrew PG1995保留。冷借用隔离及11功能cases已交付，冷热1000质量通过，冷热2000完整但5业务失败/1最终落后，原正式目标仍未达成。下一步在此实际冷队列证据上减少locate/acquire（以及评估release）的逐房间SQL往返：有限物理Store collector、原房间→租约锁序、锁后fresh clock、逐item identity/deadline、提交未知不重投与实际drain，restore validator保留。该集合化仍为方案，尚无源码或PG验证，不重复formal或扩大资源冒充完成。

### 有界生命周期集合事务

在上一批实际冷队列证据上，PostgresV2RoomActivationStore 的 locate/acquire/release 改为共享物理 Store 的 lifecycle collector；physical alias 延用相同 Store 引用。每实际批次最多128个不同 canonical UUID房间，最多2个实际事务；含queued及actual总保留1024请求、1MiB身份字段，同房间FIFO保留到实际事务结算。2ms合批从原enqueue age计算；进入actor前捕获调用方原绝对deadline与原10秒/statement上限，detached actualTask显式选取本批最早deadline，满槽/全busy仍独立到期唤醒，不轮询空转。queued取消仅撤该项，提交后取消、未知结果和关停不提前释放实际所有权，不fallback重投。

集合SQL先按room_id取得所有rooms NO KEY UPDATE并消费结果，再用独立新READ COMMITTED statement按room_id取得leases FOR UPDATE；MATERIALIZED锁行经count(*)完全消费后才读取clock_timestamp。这个statement边界保证等待rooms锁时前驱新插入租约可见。locate保留valid lease条件；acquire区分occupied/expired/released并严格增加epoch；release完整token且锁后仍有效才清host/expiry，缺房/owner改变返回false。invalid UUID/owner/epoch等独立拒绝不阻止有效siblings。第三条数据SQL集合INSERT/UPDATE，RETURNING严格检查数量、唯一UUID、原ordinal、epoch/owner/host/incarnation及PG精确微秒expiry；仅actual COMMIT成功才发布成功。事务最大retry0，shared失败撤销所有成功结果，COMMIT unknown映射outcomeUnknown、独立语义拒绝保留。restore persistent validator、renewal保留槽、总11/非续租9/activation内部2和原SQLtimeout均未扩大。

Host.stop仍只关闭原renewal producer，不能永久关闭可供successor Host使用的lifecycle。新增具体Store/Placement的应用级shutdownLifecycle并按physical collector身份去重；V2RoomActorApplication只在Directory quiesce及Host/node final stop全部完成后关闭lifecycle并等待实际SQL排空，false/throw路径保留资源。startup已完成node清理后也排空。独立代理分别审查集合SQL与collector/应用生命周期，无静态阻断；未把源码审查当实际验证。

根代理唯一串行聚焦session38886实际exit0，日志`/tmp/imv2-activation-lifecycle-focused-tests-20261002-r1.log`；Build153.71秒，10functions/11cases共5.240秒。新增实PG5cases覆盖129first-acquire txid审计（实际batch>=2且<129、单批<=128）、occupied/expired/released/stale-owner/epochmax/valid release独立结果、真实rooms predecessor lock等待后观察新插入lease、真实lease lock跨expiry不能成功release、成功COMMIT ACK被代理丢弃时两mutation均unknown且实库只各epoch1/审计共2无重投。受控executor2cases证明满actual slots队列原deadline仍到期、cancel/shutdown等待真实任务，以及同UUID大小写alias串行而其它room能并行、selected TaskLocal等于原期限。既有真实PG deferred-COMMIT failure、same-room acquire竞争/旧token不释放successor、physical alias和factory Host退役后恢复/同IDreceipt重放也通过；未重复全套。私有PG`/tmp/imv2-stages-y544d75b` finally停止，原PG1995未动。模块597files/2074symbols/2060edges、forbidden0/SCC0。

针对CPU/内存疑问，核对本机原生14核（10P+4E）/48GiB，没有已观察的容器或显式进程quota；这不保证单EventLoop或P核无瓶颈。上一冷2000实际6inside process samples第一至末25.926653秒：6Gateway累计CPU约6.537288核、12Loader约.238750核、Account.008100核；Gateway末RSS合计2515.656MiB、Loader785.359MiB。PG独立inside约3.849核、整机tick平均busy83.459%，CPU压力明确；不同sampler边界不相加求严格归因。VM无swapin/out/pageout、swap用量固定，当前无内存不足正证据。1000为10k连接、正式5000为50k且checkpoint不同，不能当仅速率5倍；正式10秒短phase只有一个inside资源sample，严格CPU/VM均值未知。新资料`/tmp/imv2-activation-loan-cold-hot-tcp-2000-20261002-r1/process-resource-phase-summary.json`仅由既有raw采样计算、未新增压测。

Gateway Release session81276实际exit0，174.26秒，日志`/tmp/imv2-activation-lifecycle-release-gateway-20261002-r1.log`；前版activation-sublimit Release原样保存`/tmp/imv2-activation-loan-pre-lifecycle-batch-release-20261002/IMV2ServerApp`。新自然冷热1000诊断session50098开始，尚未终态；不由单元/PG功能通过宣称性能或容量达成，原50k/5000×90/CPT180/完整quality及candidate≥baseline80%仍未满足。

新版自然冷热1000 session50098实际exit0：12/12、全部10000认证、29988整轮send/ACK，工作失败/overflow/abandoned/endqueue0，全部10000最终foreground viewer匹配，qualitytrue；共同窗口30.004秒、phase29984ACK（4在drain），runner报告999.327913ACK/s。各片p95 172–177ms、p99 196–205ms，不聚合片百分位。checkpointoffset约-2.15/120.10/181.32/242.48/267.95秒activeRooms5183/5502/5623/5522/3451，真实下降且仍非零。

6inside activation独立峰[1,2,0,0,0,0]、queued[0,2,0,0,0,0]、grants4397；ordinary峰[9,9,9,6,6,4]、queued[5,0,8,0,0,0]、grant113805，renewal最多1/queued0、grant4418。所有同sample/node非续租<=9/总<=11、三类reject增量0；不能加独立峰，更不能将未导出的collector内部排队当0。Directory active/pending峰[4,4,5,8,1,4]、Host restoring只有node1采到4。owner body3838次18.693ms/admission.521ms/acquire3842次.156968ms/commit.398361ms；TCP count/bytes/internal失败采样0。PG内部blocked0/deadlocks0，host tick idle33.029%、swapin/out/pageout0。Gateway窗口baseline早2.058726秒、tail缺1.437973秒；6inside process约25.533158秒GW CPU4.949642core/RSS合计1466.141MiB、Loader.176241core/RSS778.125MiB。相邻旧冷1000已不拥堵，本次质量维持不能证明所有容量瓶颈解决或严格因果提升；未运行匹配旧Release控制。证据detail/compact/cursor已保存。

仅把同诊断速率提高至2000，session57844已启动，待实测冷队列及终态；不从1000通过直接进入原formal。原资源/期限/idle/hold全部不变。

新版自然冷热2000 session57844实际exit0，12/12且Loader全部0，完整共同30.007秒；全部10000认证/59988send/59988整轮ACK、工作失败/队列overflow/abandoned/endqueue0、全部10000最终foreground viewer匹配，qualitytrue。phase59627ACK、runner1987.120405/s，后361ACK在drain；phase SERVER_BUSY202（整轮同202）、WIRE_SUBMIT60189/整轮60190，无domain DEFERRED/timeout/recoveryunknown。live gap7119/metadata gap9808由现有恢复合同处理，未强制补拉或加hold。各片p95 850–949ms、p99 1370–1694ms，比相邻旧冷2k的1400–1726/2777–3230ms低；新旧非并行受控AB，不作为精确收益百分比。

checkpointoffset约1.88/119.03/180.17/241.36/266.86秒activeRooms5265/5427/5593/5609/3526，证实真实冷热。6inside Directory active/pending峰[32,35,28,32,34,39]，Host restoring[5,5,3,12,6,11]；activation independent峰[2,2,1,2,2,2]、queued[2,1,1,6,2,5]，grant4884；旧cold2k queued49–98/grant8873，loan等待及实际恢复积压下降，但collector内部queue未导出，不能将其当0。ordinary独立峰各9/queue[23,17,16,28,16,20]、grant112594，renewal峰[2,2,2,1,2,2]/queued0、grant4245。逐同sample/node非续租<=9/总<=11、三类rejected增量0；business普通资源仍紧张，不能宣称剩余容量宽裕。

owner body1647次78.459ms/admission5.071ms/acquire1652次7.408ms/commit3.642ms，总体与旧79.975/5.390/7.923/3.684ms接近，不用外层延迟改善冒充所有SQL阶段提速。TCP count采样201（35/31/30/40/27/38），bytes0；PGblocked峰3/fanin2/statementage58.157ms，activation fence7/admission update1观测、deadlocks0；5内部PG区间25.889553秒weighted CPU4.015519core。整机weighted tick idle16.434%，swapin/out/pageout0，pageins150/decompression55。6inside process窗口25.890261秒，6GW CPU6.454551core/RSS2265.172MiB、12Loader.239859core/RSS785.203MiB；相比旧GW6.537288/PG3.849core，本次CPU仍紧，不能排除5000主机容量上限或EL/P核热点。Gateway基线早3.144649秒/末缺2.169028秒、PG早3.143133/末缺2.166712，counter包含边界checkpoint活动。

本轮无lag，因此按原合同未生成wake witness；只证明本轮真实质量通过。此前accepted ingress到writer缺乏逐端点完成证据的条件风险仍在，no_outbox不是已交付证明，尚未实现新增端点诊断或改变通知协议。不能把这次质量通过扩大成所有丢提示路径已修复。

两次新scaled私有PG及全部服务均finally停止，原PG1995未动；新collector PG/Release、冷热1000→2000均实际通过，原目标仍未验收。因两小档已完整通过，只启动一次原规格candidate session89190，`/tmp/imv2-activation-lifecycle-tcp-5000-formal-20261002-r1`；沿用50k paired-policy夹具、原checkpoint180/5000×90秒、原质量/资源，无scaled或额外profile。正式仍进行中，未提前求80%或记为容量通过。

正式candidate session89190实际exit1；50k全部warm，原180秒checkpoint完成；Loader failure guard使其余工作停止，仅report6/10两个失败report落盘，另外10report缺失。两报告rate窗口1790898081.688→8101.697、20.009秒，原90秒未完成。两报告phase ACK合计1235、workloadFailed585，domainDEFERRED6194/SERVER_BUSY3898，不能当全fleet计数或有效吞吐分母。两报告整轮unknown-connection-closed13066主要cleanup，先前的domain延期/重试耗尽与同期异常要独立观察。未生成完整foreground proof/outbox witness，不能报所有50000viewer最终数量；不运行baseline或求80%，不重复formal。

首个有效inside Gateway样本(+4.165s)六节点Directory全128active/1024pending、Host restoring全32；ordinary7+activation2同时满原非续租9，renewal1–2，总仍<=11。ordinaryqueue14/13/5/30/16/11、activationqueue14/29/15/10/11/8；owner实际各1、queued353/345/279/268/328/317，多个actual已在locks/preflight/messagepersistence，不能将全部owner等待归为borrow。后+15.077s只有GW0/1有效，ordinaryqueue62/57、ownerqueued563/556且都owner_locks，activationrejected增量4/12；GW2–5 metrics超时，未采到不当0。各node metric inside数2/2/1/1/1/1，末尾覆盖分别缺4.932/4.932/15.844/15.844/15.844/15.844秒；计数用analyzer各host自己的有效基线/末点。root临时detail helper修正为直接使用该counter_summary，未将空body补0产生负delta；生产analyzer原已正确保留unknown。

PG两inside只有+4.166s一份有效activity/locks/database：activeLock3、idleTxn43（ClientRead14/None29），三真实XID edges、fanin最大1；+15.079s psql exit2缺statistics，派生空blocked不是零阻塞。真实链83646→83653→83655末ClientRead/age173ms；中间rooms tuple及上游XID等待，不是quota pool tuple链；另一83602→83644末presence idleTxn age351ms。仅该有效观察未见quota convoy/deadlock，不能断言全阶段无锁竞争。phase内+6.582/10.863/12.667/19.242s四次lock_timeout全部为标量rooms FOR NO KEY UPDATE（共享v2LockRoomActivationOwner形状），非新集合SQL；+19.8s第一次idle-in-transaction FATAL。该helper同时服务restore validator与旧业务/queries/fallback，现SQL分类不能把锁链唯一归属restore或判泄漏。

资源有效范围有限但已有反证：host仅+3.971→+9.303s、5.332秒有效内部CPU区间，idle51.008%；不称整20秒CPU均值。该时段Directory与loan已拥堵，故不支持当时整机CPU完全用尽，仍不能排除个别EL/P核饱和或未采瞬态。VM两inside之间swapin/out/pageout0、pageins110/decompression1591、swap固定；无内存不足正证据。process两inside5.330424秒6GW CPU4.234185core/RSS合计8891.469MiB、12Loader.371453core/RSS2938.25MiB；PG两process observations约10.912328秒持久PID CPU.364725core，activity第二份缺失，不能凭该低值判DB资源充足。PG各进程RSS含共享映射，不与GW/Loader RSS盲求物理总内存。

phase07:41:21.688–41.697的时序进一步只读核实：PG最早room锁超时+6.582s，所有GW首批user-state-route AsyncKit timeout在+9.3s；GW2 +10.3s开始suspect，GW3 +15.3s unreachable，GW0/1/5约+16.3s unreachable，GW4 +18.3s自身down在phase内。其它selfdown在phase之后属于停机段，不把所有membership事件归cleanup或把后续SWIM当已证最初原因。实际应用/事务推进停顿和故障检测相互放大需要进一步诊断。

只读所有权复核未发现Directory→Host→validator→Directory循环借用：Directory每room singleflight/进程128worker持到actual resolve；Host每room共享entry、最多32实际获取/恢复；factory validator在acquire实际结束后独立txn，返回实际COMMIT后才公布handlers，不awaitDirectory/Hostcallback。确认三个有界放大点但尚未证明是首因：zero-waiter已排队冷工作仍可后续启动、任何candidate activation失败均重新locate（最多6候选）、Host idleLoop每秒逐ready-room跨Actor询问即使尚未到idle。后续先用封闭来源分类区分restore validator/业务scalar围栏，并观测实际持事务等待应用下一指令的阶段；若撤销无需求queued工作或改重复定位，必须保留已提交actual所有权/unknown恢复与idle回收合同，不pin房间、增pool/资源或加hold来过关。

本轮所有运行服务/私有PG finally停止，ps只剩原PG1995。生命周期集合化已实际交付且10functions/11cases、Release、自然冷热1k/2k完整通过；新formal仍失败、原全规格质量与80%目标未完成。上述CPU/内存证据回答资源疑问，但不把源码放大点或稀疏采样当单一根因。


### 撤销无需求排队恢复与共享恢复验证（2026-10-02）

Directory 最后 waiter 取消/到期时只移除尚未 started 的房间代次；Host 只撤销 acquiring 且未 activationJobRunning 的无 waiter 项，立即归还 pending 计数并推进队列。旧 timer/cancel 仍按 generation 校验。恢复循环在下一轮开始前检查仍有 waiter；已 await 的 resolve/activation/SQL 不提前取消或释放实际名额，unknown 恢复合同不变。

production Factory 从同一个 Application leases 注入 validate(token:)，复用物理 lifecycle collector；显式物理别名共享 locate/acquire/release/validate 的同一引用和 canonical room FIFO。验证仍按 rooms 锁→下一 READ COMMITTED snapshot 锁 leases→锁后 fresh DB clock，逐项检查完整 room/owner/epoch/host/incarnation 与 expiry；不更新租约，实际共享 COMMIT 成功后才返回 validated，提交 ACK 丢失则包含只读验证项在内的所有成功项均转 unknown。Factory 等验证实际返回并再检查 closed/deadline 后才公布 handlers。业务写入围栏及普通借用路径未改；未注入时保留标量 validator 兼容路径。没有增加 pool/CPU/idle/hold 配额。

根代理唯一串行聚焦 session86617 实际 exit0，日志 `/tmp/imv2-restore-validation-focused-tests-20261002-r1.log`：构建99.91秒，12 functions/15 cases（Server 7 functions/8 cases 3.997秒，Runtime 5 functions/7 cases .462秒）。新真实 PG 验证覆盖完整 token 错误、缺房间/缺租约/已释放/过期/owner changed、同批健康 acquire、验证不写租约、真实前驱替换及等待到期后的 fresh clock；COMMIT ACK loss fixture 增加只读 validate sibling，不提前成功也不重执行。实际 factory 退役恢复/同ID receipt重放、共享物理 alias lifecycle身份、原 collector FIFO/deadline/actual drain 与 runtime 已启动共享恢复不被取消均通过。私有 PG `/tmp/imv2-stages-c69s45hk` finally 停止，原 PG1995未动。Release及小档性能仍待完成，不能用单元/实库边界测试宣称正式容量通过。

本轮资源核查 sysctl 实际14 physical/logical cores、51539607552 bytes（48GiB），bench为native子进程，未见CPU/内存quota。1000档10k连接与formal5000档50k连接、checkpoint270与180同时变化，不能只按5倍发送速率作线性推断。先前formal唯一有效内部CPU区间仍idle51.008%且VM无换页增长，与Directory/loan已满及rooms锁链同时存在；不支持当时整机CPU完全耗尽或内存不足，不能排除单EL/P核或未采瞬态。资源可能参与放大，仍需固定连接数的速率阶梯与事务推进来源观测才能区分因果，不盲增额度或重复formal。


Release session31092 实际 exit0，日志 `/tmp/imv2-restore-validation-release-gateway-20261002-r1.log`，166.25秒；模块597files/2074symbols/2060edges、forbidden与SCC0，文档链接/diff通过。只启动同10k自然冷热1000 session7038，原270秒checkpoint/idle300、30秒发送/hold10/质量与资源不变，目录 `/tmp/imv2-restore-validation-cold-hot-tcp-1000-20261002-r1`；尚无新容量结论，不重跑formal。

离线分析补纳入原已导出的 TLS child-channel EventLoop 100ms低频探测直方图，保留实际counter差值、缺基线unknown与lifetime最大值语义；聚焦Python analyzer 11tests .006秒通过，无线上观测/SQL额外开销。重新分析旧formal到独立 `event-loop-hotspots.json`，未覆盖原输出或抹去缺report。原消息阶段+4.165→+15.077秒，GW0/1实际已完成探测602/625次，差值均延迟26.201/25.944ms；累计max分别从37→737ms、72→557ms，因此新高点确实发生在这两个内部样本之间。GW2–5只有一个内部有效样本，无区间差值，不当0。`event-loop-probe-detail.json` 保存原始边界与节点覆盖。

该探测只覆盖 Gateway TLS child EventLoops，不覆盖数据库EventLoop或Swift cooperative executor，也没有逐loop/CPU核身份。它说明存在局部事件循环推进延迟，不能直接归因CPU不足、指定持锁事务或宣布SQL continuation根因；与整体CPU空闲、实际rooms锁链的关联还需要固定连接数和来源/续行观测。原CPU有效窗口4–9秒与probe4–15秒不相同，不能合并成同一全阶段均值。


新版自然冷热1000 session7038 实际 exit0：12/12且Loader全部0，10000认证/29988send与整轮ACK、全部10000最终viewer匹配，工作失败/overflow/abandoned/endqueue0、qualitytrue。共同窗口29.999秒、phase29967ACK（21在drain），runner998.679552ACK/s；各片p95 172–243ms、p99 199–278ms，不平均片百分位，也不声称较相邻旧版全部改善。checkpoint约offset-2.10/120.19/181.39/242.54/267.98秒activeRooms5210/5502/5623/5522/3467，真实自然退役且存活并存。

6inside Directory active/pending峰[2,3,2,3,2,5]、Host restore[1,0,0,1,2,2]。activation loan grants4140、sampled inFlight峰[0,1,1,1,2,2]/queued全0；ordinary grants118043/inFlight峰[4,1,4,3,3,6]/queued全0；renewal grants5132/峰最多1/queued0，各类reject增量0，同sample/node预算未超。未导出的collector内部队列不记0；独立sample峰不相加。PGblocked采样峰1/fast admission update1观察/statementAge2.452ms/deadlocks0。host内部tick idle22.205%、swapin/out/pageout0；6inside process25.529773秒6GW约5.443057cores/RSS1438.75MiB、12Loader.179007cores/RSS777.203MiB。相邻旧冷1000本已通过，CPU与部分p95更高，无冻结旧版匹配控制，不能宣称严格容量收益。

Gateway counter基线早2.029152秒/末缺1.413004秒，heads/proof/cursor-detail保留；no lag不生成wake witness符合合同，不等同全部通知故障已消除。私有PG/全部服务finally停止后，仅提高同10k诊断速率启动2000 session80902，目录 `/tmp/imv2-restore-validation-cold-hot-tcp-2000-20261002-r1`；原资源/idle/质量不改，不重跑formal或提前求80%。


新版同10k自然冷热2000 session80902 实际 exit0，12/12且Loader全部0、全部10000认证/59988send与整轮ACK/10000最终viewer匹配、workloadFailed与队列overflow/abandoned/endqueue0，qualitytrue；完整共同30.005秒、phase59656ACK（332在drain），runner1988.151171ACK/s。phase与整轮均SERVER_BUSY71、WIRE_SUBMIT60059，未见domain DEFERRED/timeout/unknown。各片p95 656–746ms、p99 923–1129ms，较相邻旧cold2k的850–949/1370–1694ms低；没有冻结旧版匹配控制，不作精确因果改善百分比。

checkpoint约offset-1.21/121.06/182.18/238.24/268.81秒activeRooms5143/5460/5623/5623/3525，真实冷热成立。6inside Directory active/pending峰[18,9,15,18,21,12]、Host restoring[3,3,2,1,2,2]；activation grants4002、inFlight峰[1,2,1,2,1,1]/queued[1,1,1,2,1,1]，ordinary grants122576/各inFlight9/queued[19,12,20,12,12,14]，renewal grants4043/inFlight最多2/queued0。每同sample/node原非续租<=9/总<=11，三类reject增量0；普通资源仍紧，不把collector未导出队列当0，也不加独立峰。

owner completed body1845均77.245ms/admission4.763ms、connectionAcquire1850均5.670ms/commit1845均3.188ms；各阶段人口不同不强行相减推断空转。PGblocked采样峰2/fanin2、statementAge94.065ms，room fence6/admission fast1观察、deadlocks0。host内部tick idle15.935%、VM swapin/out/pageout0（pageins243/decompressions218）；6inside process25.835383秒6GW CPU6.485679cores/RSS2282.938MiB、12Loader.243465cores/RSS783.844MiB。CPU仍busy约84%，不能从小档通过宣称5k主机有容量；TLS EventLoop已完成probe内部区间均值峰约1.255–1.530ms、新lifetime最大观察53–109ms，不等同DB/Swift执行器或全请求延迟。

Gateway counter基线早1.195529秒/末缺.260242秒，PG早1.194160/末缺.259090秒；所有reports/heads/proofs、analyzer/compact/cursor/EL detail保留。no lag时无wake witness是原合同。两轮新scaled及私有PG finally全部停止，ps仅原PG1995。本批聚焦12functions/15cases、Release、Python11tests、1000→2000全部实际通过；原50k/5000×90、完整正式质量与candidate≥baseline80%仍未验收，不再重跑formal。下一步固定连接数/恢复场景做速率阶梯，并补实际持锁SQL→Swift续行/下条SQL或COMMIT的封闭来源观测；资源参与程度与formal根因仍未唯一确认。


### 固定 50k 连接、1000 速率的采样诊断（2026-10-02）

为区分连接/恢复规模与发送速率，本轮从原正式场景只修改消息速率和名字到1000，保持50k夹具、checkpoint180、90秒发送、sync100/reconnect .05/idle300/hold10及原质量/资源，使用`--allow-scaled-diagnostic`。目录`/tmp/imv2-fixed-50k-profile-tcp-1000-20261002-r1`，运行时为前一版Release（已含queued零waiter撤销及共享restore验证，尚不含本轮idle预过滤与SQL continuation）。session88879实际exit1，benchmarkExit1/profilerExit0；所有50k warm和checkpoint完成，但只有10/12报告，缺loaders4/10，共同rate窗口37.304秒而非90。可见10片phase23935ACK/68workloadFailed，不能当完整fleet吞吐/quality；最早可见per-second工作失败在second28，关闭后的unknown另计。所有owned服务/PG终于finally停止，原PG1995未动。

本轮启动了owned-only stack profiler，manifest明确profilingOverhead=true/excludedFromCapacityComparison=true。只采GW7634/7635和PG7764/7717，工具操作范围约phase+8.49→13.80秒，sample启动/符号解析时间不是连续CPU采样时间，PG进程角色也会变化。不能以本轮失败确定未采样同规格一定失败，不能用于容量或80%比较。采样前+4.94秒已经存在ordinary loan queue20–52/各实际9满、interactiveRead queue18–67和房间围栏阻塞链末idleTxn ClientRead/age164ms；那时拒绝计数仍0。采样中读取队列增至145–275，采样后约+16秒出现queueFull663/admissiontimeout100/TCPcount2。说明压力早于采样，采样仍可能放大并触发失败。

六节点内部Directorypeak128/pending峰131–190，未到此前1024；ordinaryqueue峰107–152，activationqueue峰1–2、renewalqueue0，原预算不增且loan拒绝0。有效PG阻塞峰3/fanin2，rooms fence13与admission fast1观察，PG日志无SQL ERROR/lock_timeout/statement_timeout/deadlock，不能把interactiveRead准入timeout误写成SQL statement timeout。两PG栈多数ClientRead，仅少量row-lock；这是线程墙钟栈观察，不是CPU占用或同一事务持锁全程的证明。两GW栈无可识别idleLoop/beginIdleDrain，不能说空闲扫描为已定位热点；NIO kevent/线程池等待、JSON嵌套栈和系统read/write不可叠加父子计数或当CPU饱和。

主机CPU内部tick全可见区间均idle约38–42%；与profile操作不重叠的+15.306→21.468、21.468→26.683、26.683→31.930、31.930→37.241秒分别idle41.136/42.209/42.327/41.982%。这些均在采样之后，可能仍承受采样积压，不能当无扰动控制。VM内部pageout增163（16KiB页）、swapin/out0、pageins19298/decompression1596，不能沿用旧formal的pageout0，也不足证明内存不足；采样工具的文件/符号处理可能贡献。过程内部6GW约4.956核/RSS7238MiB、12Loader .196核/RSS2918MiB，不将PG共享映射RSS与其相加。整体空闲仅反驳整机持续耗尽，无法排除单核、单事件循环或未采瞬态。

本轮源码减少可证明的无效idle跨actor询问：Lane把原唯一lastActivity放入Mutex，Host先同步读精确activity，未达到原idle cutoff跳过跨actor；过期候选仍由Lane原原子phase/真实执行/排队/reservation检查以及Host await后entry代次检查决定。未改变activity写入时机、TTL、scan频率或pin，不能称其已证明解决formal。

SQL continuation新增固定8来源，分别观测显式room/lease查询的EventLoop future settle→Swift调用方resume、resume→下次已记录dispatch，两段人口独立，含pending gauges及无下次记录的终态计数。实际事务新建trace，借用前捕获recorder，生命周期物理alias复用一个已有owner recorder，实际COMMIT/ROLLBACK前flush；显式fence终结/译码或SQL失败关序列，避免跨未观测领域/SAVEPOINT SQL误计。pending0只覆盖已观测查询，不证明整个executor健康；noNext不是后续没有SQL或提交成功；均值不当SQL执行时间。Python analyzer新增同source/part计数配对测试，实际12tests通过。聚焦r1在编译阶段暴露NIO map泛型推断为Void，尚未运行测试；修复显式EventLoopFuture<Value>和闭包返回类型后，r2仍在运行，未提前宣称通过。


SQL/idle聚焦r2实际session86661 exit1，Build129.16秒：Server9functions中8通过，仅Factory新durable来源4断言失败，Runtime4functions全部通过；私有PG`/tmp/imv2-stages-trcc0drt`finally停止。定位为夹具便利Store initializer默认review enabled，而Factory资源声明disabled，已有fixture因此选择scalar fallback，非trace生命周期失败。将该fixture Store review明确disabled与原Factory声明一致，保留durable两个来源各1的严格断言及后续scalar/生命周期/receipt重放/实际loan预算断言；只重跑该函数r3 session59144实际exit0，Build27.51秒/真实PG .882秒，私有PG`/tmp/imv2-stages-2_irvkcq`finally停止。合并本轮最终实际通过13functions/16cases（r2其余12functions/15cases及r3一Factory），未重复全部已通过检查。Trace3case测实际ELsettle后受控调用方resume、取消不虚构actual completion、原Error identity、noNext/doubleflush，Factory证明实际生产lifecycle/durable/scalar recorder接线；PG fresh lock facts与actual COMMIT ACK loss/COMMIT failure通过。

模块598files/2080symbols/2072edges、forbidden/SCC0，文档链接/diff通过。Release session72896正在构建，日志`/tmp/imv2-sql-continuation-idle-release-gateway-20261002-r1.log`；尚不能将聚焦检查当容量结论。


资源配置进一步源码及本机核实：sysctl仍14physical/logical、48GiB，root RLIMIT_AS/DATA/CPU均unlimited；native harness未设进程CPU/内存quota。六Gateway/PG/12Loader共用本机资源，不是六台机器。`gateway_env`明确DB eventLoopThreads1/main pool connections11，`V2TLSGatewayServer`默认System.coreCount（本机14）TCP child loops+1acceptor，Application metrics/Actor transport另有执行器；数据库单EL不等价只分配1CPU，却有局部串行的可能。本轮保持此配置，不能用整体CPU空闲推出每个执行器够用，亦不先增线程/loan配额替代诊断。


新Release session72896实际exit0/200.11秒，日志`/tmp/imv2-sql-continuation-idle-release-gateway-20261002-r1.log`。根代理随后串行执行无sample的固定50k/1000诊断，目录`/tmp/imv2-fixed-50k-sql-continuation-tcp-1000-20261002-r1`；原50k/CPT180/90秒/资源及质量不变，scaled diagnostic。终态session19842实际exit1：仅report4完整、消息阶段35.850秒，3个sync SERVER_BUSY触发停止，其他11片缺报。六节点interactive_read队列均达到384，foreground_write未先拒绝；不能把清理期的连接关闭错误计为首因。内部CPUidle42.359%、swap/pageout无增，指定room/lease SQL续行均值不足1ms，覆盖范围不能推广到所有SQL。该轮不与含stack采样的上一轮作严格因果收益比较；原5000 formal未启动，80%未接受。

## 2026-10-02 补充实际连接来源观测后的诊断

用户要求先完善观测、重测并说明原因。本轮只补连接与SQL观测、固定主题查询
计数和受控竞争检查；业务锁、SQL、池大小、超时、检查点和质量条件未调整。

### 验证与实际复现

- 实际借用票据在准入时固定来源，取消不替代实际Future归还，嵌套操作复用票据；
  覆盖并发SQL、重复完成、迟到归还、真实Factory围栏与COMMIT不确定性。
  聚焦r1/r2实际通过，日志分别为
  `/tmp/imv2-loan-source-focused-tests-20261002-r1.log`、
  `/tmp/imv2-loan-source-focused-tests-20261002-r2.log`；私有测试PG均已停止。
- 新loan/SQL phase Release实际通过190.20秒，日志
  `/tmp/imv2-loan-observation-release-20261002-r1.log`。
- 唯一大档复现session72064实际exit1，目录
  `/tmp/imv2-fixed-50k-loan-observation-tcp-1000-20261002-r1`。
  50,000在线均预热、checkpoint180完成；TCP发送1000/s、原计划90秒。
  report2实际阶段37.947秒，terminalError为重连时
  `gateway connection closed before authentication`（plannedReconnects1）；
  12个sync SERVER_BUSY是此前的工作错误，不能写成该Loader的终止原因。
  仅1/12报告，后续7个发送unknown发生在关闭收尾。
  不能推完整fleet吞吐或质量达标。
- 六节点各7个消息期有效采样；计数基线早1.477秒、尾缺1.639秒。
  主证据为 `message-hotspots.json`、`loan-observation-detail.json`、
  `idle-loan-observation-detail.json`、`presence-route-competition-evidence.json`。
  全部本轮服务与owned PG已finally停止，原Homebrew PG1995未动。

### 已确认的实现问题和时序

1. **心跳会产生没有实际接收端的路由工作，且与消息共享查询名额。**
   `V2GatewayByteStream` 的heartbeat处理等待registry.refreshLivePresence；
   registry在允许在线状态发布时调用routePresence；Actor publisher仍先解析
   userPresence主题，再调用Fanout.activeRoutes。消息正文、房间唤醒、用户同步
   和在线状态共用Fanout的4个查询名额，也没有按主题区分优先级。
   最后30.721秒空载检查点内，完成51,186次routes查询（1666.15/s），
   对应52,536次other实际借用的97.43%；所有RPC结果增量为0。
   这是该路径在50k连接下产生大量无投递查询的实测与源码交叉证据，
   不意味着每个other借用都已被独立标成presence。

   **更关键的准入边界在主题解析之后，用户路由读和重连注册共用单连接池。**
   Runtime的topic resolver对userPresence/userSync使用Topology.userStateRouter，
   后者绑定`gateway-user-state-route`单连接池、未接物理loan gate。
   `publishPresence`在调用Fanout之前先await topic解析，所以Fanout的4个名额
   完全不限制这些用户路由请求。它们可以先在AsyncKit驱动中大量排队。
   重连的ByteStream在发authenticated回复前，await Registry.register：
   userSync interest.activate→publisher.activateUser→同topic resolver；
   interest注册后的readHead还再次解析同一用户路由。该阶段抛错时Registry
   rollback并throw，ByteStream关闭session/连接，客户端于是看到认证前关闭。
   Gateway2在10:38:50已出现该单池超时（阶段开始10:38:34.626，
   时间戳只有秒精度，约+15.4到16.4秒）；10:39:12首次transport error为
   `AsyncKit.ConnectionPoolTimeoutError`，与report2终止时刻10:39:12.573一致。
   这确立了本次实际停止的错误类型与认证边界；没有连接级waiter关联，
   尚不能把某条具体池超时日志精确配对到该次认证调用。
   不能将该池只称为投影控制池，
   也不能把源头未标来源的全部SQL归为投影。userStateProjection完成计数为0。

2. **即时恢复每次是一个约8次SQL往返的围栏事务，放大共享池竞争。**
   第1秒已见151次local-echo游标缺口及153次拉取，第5秒累计1435次拉取；
   缺口只说明前序尚未应用，不能单独证明服务端丢推。
   Loader grace实际为0，因此立即走恢复。消息期完成6083次实际group pull，
   48707次SQL Future：fence24356、read_body6083、事务控制12176、other6092。
   平均实际占用90.48ms，其中readBody单次12.81ms；连接准入排队另计148.78ms。
   不把不同阶段人口的均值直接相减，SQL并发耗时不作可加的墙时分解。
   Directory恢复读取仍可能先查询owner、确认位置，Host的读取准入在后；
   被拒绝的恢复请求也可能已付出解析与路由成本。

3. **队列饱和早于同步失败；查询门拒绝原来是观测盲点。**
   +9.04秒读取队列峰185且尚未拒绝；+15.35秒达到384并出现拒绝，
   +25.86秒首次采样见sync SERVER_BUSY，客户端第24秒先记录失败。
   六节点计数窗口共24262次读取queue_full、6841次读取timeout、298次sync timeout。
   消息期routes完成调用均值88.11ms（含借连接等待），空载均值0.581ms。
   原Fanout guard发生在store-operation计数之前，不能由routes.failed=0
   或rpc.overloaded很小推出没有查询门过载。现已补四固定topic kind的
   在途、实际完成、空结果、耗时和capacity_rejected计数。

受控 `emptyPresenceQueriesBlockForegroundDelivery` 实际通过：4个最终返回空
结果的userPresence调用占住所有查询名额，roomEvents房间唤醒在进入Store之前
被typed routeQueries拒绝；释放后房间投递成功。断言包括实际Store调用类型、
新增拒绝/empty计数与指标不泄漏身份。与既有3类容量门及metrics route一起
实际通过3个测试函数/5个case，日志
`/tmp/imv2-route-query-contention-focused-tests-20261002-r1.log`。
这一检查证明跨业务竞争机制，不能替代消息期逐类推送的动态归因。
新增topic计数是在本轮大档复现之后接线的，该复现没有这些计数；没有为了
补历史数据再跑一次大档。Python分析器15项检查实际通过。

### 已排查与仍有的边界

PG消息期有效样本blocked峰6、实际XID fan-in峰2、deadlocks增量0；实际连接
继续归还，不支持本轮发生数据库死锁或借用泄漏。整机内部32.606秒CPU平均
idle42.263%，swap/pageout不增；但compression增加175294页、decompression
增加11809页，整体空闲和无swap不能排除局部事件循环或压缩开销。

在本轮保留的owned PG上，全部服务停止后，只读执行原权威readBody SQL、
与Loader相同pageSize100，选两个已有消息/当前有效成员的房间，各cursor0/head，
4次EXPLAIN ANALYZE耗时0.710/0.170/0.340/0.202ms，未产生temp spill。
存在对空room_events/content_versions的便宜Seq Scan，不能写成完全没有Seq Scan。
计划见 `readonly-query-plans/summary.json`；未ANALYZE表、改索引或planner设置，
owned PG再次finally停止。该检查仅排查所选房间的离线custom readBody计划，
不包含围栏、实际负载、网络、驱动和generic计划，不能宣称全部SQL已无热点。

最终新增topic-kind观测的Release实际通过181.72秒，日志
`/tmp/imv2-loan-observation-release-20261002-r2.log`。这个指标针对Fanout实际
route-store调用及其准入门，不覆盖此前topic resolver的独立单连接池请求；
后一边界本轮由组合根源码、池超时日志和认证前关闭错误交叉定位。

下一步修复应先覆盖topic解析之前的有界准入与业务优先级、单用户路由读与
重连注册/投影的资源关系，再处理在线状态空发布、消息查询名额和恢复请求
的额外解析/围栏成本及推送失败诊断。固定连接/超时/质量条件保持；原50k/5000×90秒与
baseline80%验收仍未完成。


## 2026-10-02：新 Actor 路由装配与定向验证（未验收）

当前工作区 production runtime 已装配内存订阅分片、缓存引用、PG 固定分片控制租约、业务 owner 快照和 TCP 单发送入口。原定向构建完成，但混合测试进程持续等待约 9 分钟；保存 sample 后终止精确 owned PID 71439/72161，session 66539 终态 143。不能报告整次测试通过。

独立复核复用了同一已构建测试产物，未重编译：
- `snapshotAndSessionFences`：1 函数通过，0.029 秒。
- `PostgresV2RealtimePartitionLeaseTests`：2 函数通过，0.865 秒；真实 owned PG 上确认幂等 token、到期不能复活、更高 epoch、旧 release 无效及竞争锁序。
- `heartbeatDoesNotPublishUnchangedPresence`：1 函数通过，0.026 秒。
- `scopedOperations`：1 函数通过，0.008 秒。

已定位认证恢复测试 fixture 的确定等待错误：每次底层合法 revision 补偿都创建新的 continuation gate，释放方法只释放一次，后续 gate 永无释放者。fixture 改成仅阻塞首个实际安装、release 后持续开放；保持实际工作 drain、取消和最终 scopes 为空的要求。尚需重编译验证修复后的函数；上述独立通过不证明混合运行的所有等待都已解释。

ClientKit 定向测试实际通过 9 函数/5 套件（1.541 秒测试时间），包括 TCP 发送/恢复与 scope 代次。日志 `/tmp/imv2rt-7o99fjew/client-focused.log`。IMApp Debug generic iOS Simulator 构建实际成功，日志 `/tmp/imv2rt-7o99fjew/app-build.log`；不代替设备运行或多端故障测试。

交叉审查随后修复 presence watcher 的逐端查询放大（单 SQL 批量完整授权键，独立实际 collector）并识别严格恢复提示以 Void best-effort writer 伪装成功的问题。严格 presence/room/userSync 改为明确 Bool 入队与 scope 原子围栏；Ready 状态实际写入的同类缺口仍在闭合。新发现改为逐可信 peer 完成即安装、每 partition 有界等待；已签名旧引用的健康退役与重新 join 不授予租约接管权。这些后续修改尚未统一编译/验证。

以上原始日志位于 owned 临时目录，容量与真实承载分片故障验收未完成；不能声称零寻址 SQL 或吞吐提升已经被负载证明。


### 后续统一定向验证已通过

修复 Swift 类型推导、成员 Mutex 不可复制以及精确 Cluster.Member down API 后，`IMV2ServerApp` 生产入口 Debug 实际构建通过（6.29 秒）；统一 `swift test` 构建通过（69.27 秒），选定 33 个测试函数全部通过：ServerTests 24、RoomRuntime 1（读取/发送两参数 case）、ActorCluster 5、部署配置 3。真实 owned 两个空数据库执行 presence 授权测试，未跳过；PG 分片控制 2 函数也实际执行。日志 `/tmp/imv2rt-7o99fjew/server-focused-tests-r8.log`。

混合测试这次完整结束；认证 fixture 修复后的实际 drain 与多次 shutdown 验证通过。严格 presence 的测试实际暂停 SQL 返回后的 socket owner、注销 scope 后再允许入队，旧作用域未写帧；不得把它扩大为全部两节点故障证明。

Loader 实际 Debug 产物描述 contractVersion 3，wire45/46 和 common algorithm hash 已输出。baseline 只接受 wire45；新服务只接受46，测量工具显式按版本适配，生产 ClientKit/App 不增加旧版本兼容。不同服务分别安装自己的 schema（baseline66/candidate68），不能把协议不匹配当吞吐0；实际双版本连接尚待容量阶段验证。

### 两节点接管 r1/r2：失败证据与纠正归因

r1、r2 均在 gateway-before-kill 屏障之前失败，没有执行计划中的 SIGKILL。r2 在修复发现安装的健康状态竞态后重新构建 Probe（3.83 秒）并使用新 owned PG 数据库执行，driver 终态 1。原始证据分别为 `/tmp/imv2rt-7o99fjew/handoff-r1`、`/tmp/imv2rt-7o99fjew/handoff-r2`，driver 日志为同目录根下 `handoff-r1-driver.log`、`handoff-r2-driver.log`。

日志约 11 秒后的 sender down 不能证明误退役：Probe 在捕获原错误后先执行 node.stop，再输出 G4_PROBE_FAILURE；Vendor shutdown 会 down 自身。因此先前“nil 健康竞态解释此次 down”的推断撤回。该竞态本身可由源码证明并已修正，但不能被用作本次失败的运行时根因。

进一步源码定位：Transport 的 pollFinished 将一次无结果的发现 pass 解释为 wrongRecipient，并立即结束所有 resolver waiter，启动时 Receptionist 尚未同步也走此路径。正在修正这一错误分类与过早结束行为，保留原调用者绝对期限，添加清理之前的阶段证据。修复后尚需实际重跑，不提高 TTL 或 RPC 等待预算。

并行只读复核另外确认 heartbeat ACK 在 Registry.refreshLivePresence 中等待实际 PG 续期；续租 batcher 未限制实际在途批数，finish 不排空已提交 SQL。续租 SQL 以入队 request.now 判断有效期，不能证明锁等待后仍未过期。这些是待修正的生产边界，不能仅靠“没有逐次路由 SQL”认定心跳已经脱离数据库等待。

### 心跳、权威期限与生产控制器修正已定向验证

生产心跳现只检查本地确认期限并提交有界续期；确认期限只能由实际成功续租延长。续租批处理保持 256/2ms，FIFO、一个实际在途批次，关闭排空 SQL 及结果回调。生产 Registry 上限由 configuration.maximumConnections 传入；单次心跳不创建新的后台任务。在线租约 admission/renew 使用锁后的数据库时钟，返回已确认剩余期限；未知或迟到结果不能复活到期连接。

分片控制事务复用实际 PostgreSQL deadline 执行器，5 秒总预算、2 秒锁等待，禁用未知提交自动重试。生产 App 构建实际通过（11.25 秒）。`heartbeat-controller-tests-r9.log` 实际通过 10 个函数：Server 9（包含阻塞实际 SQL 时 ACK、到期及迟到未知结果、续期实际排空、锁等待超时和 DBclock），App 1（直接运行 production controller，真实提交后响应丢失、原 token/epoch/expiry 重试、重复 shutdown 实际排空）。Server 运行 2.461 秒，App 5.384 秒。没有运行全套或容量场景。

r3 的 cleanup 前证据确定失败阶段为 initial_desired_activate，错误仍为 wrongRecipient，故仅修正冷发现提前失败还不足以闭合。后续定位发现广告中的 ActorID 被客户端再次 JSON 编码，而握手验证的是宿主原始编码字节的 SHA256；对象字段顺序不规范导致摘要不一致。现广告签名包含宿主一次编码的原始 endpointReference，发现校验解码 ActorID 与签名身份一致，再保留原字节。没有放宽鉴权。Probe 按冻结源码实际重建通过（4.78 秒），r4 接管验证正在执行，未记通过。

### r4 真实接管通过及证明边界

`handoff-r4-driver.log` 终态 0，`handoff-r4/partition-handoff-result.json` 与 scope 文件实际确认：杀死承载进程、相同配置端口重启、PG epoch 1→2、incarnation/session/interestGeneration 换代；旧租约不能续期。Gateway 原 desired activation 只执行一次，观察覆盖丢失后自动恢复，重新读权威 head，再得到 16 次真实回调；热发布 cache miss 增量 0。旧投递被拒绝，旧引用在 dispatch 前被拒绝，实际任务排空、PG 租约释放。

范围明确：该两节点 fixture 在确认 SIGKILL 后主动加速旧租约到期，使用 fixture 续期，不使用 production partition controller。它不测自然 TTL 恢复时延，不证明完整 App 游标补齐，也不伪造已死进程的迟到回复。production controller 的未知提交与 drain 由上面独立真实 PG 定向测试覆盖，不能把两者合并宣称完整生产故障矩阵通过。容量仍未运行。

同一冻结 Probe 随后执行 `callback-inflight-r4`，driver 终态 0：实际 offer 被暂停时 stop 到期返回未排空、新调用拒绝；释放实际 offer 后 dispatch 完成，再次 stop 真正排空。未提前返还实际调用名额。

受数据库时钟契约影响的旧 lease 测试随后按真实 DB expiry fixture 校准。`live-lease-contract-tests-r10.log` 构建 29.85 秒、运行 2.535 秒，5 个函数通过（其中 duration 有 12 参数 case）；4 个实库函数覆盖过期后的全局准入额度、时间边界、消失的精度与 scalar/batch 微秒一致性。没有以调用方旧时钟模拟新的生产时钟权威。静态 inventory 和全局 diffcheck 通过。

最后写入围栏复核发现普通通知/required 账号通知的 NIO 实际写入仍只检查 channel，author presentation 也未组合租约期限。现实际 EL 入队前核对纯同步确认期限，handler 启动前重新核对，author presentation 实际 permit 同样核对；已提交业务事务不因到期被推断回滚。`notification-lease-fence-tests-r12.log` 终态 0，2 函数/7 参数 case 通过，新增 mode4 确认 session 仍在而期限已过、关闭任务未执行时，普通与 required 通知均未写出帧。先前 Release App 构建通过 210.58 秒，但发生在这次最后围栏补丁之前；容量前须更新 Release 产物，禁止用先前成功构建替代最终源码。

### 压测准备复核：实际续期优先级与覆盖证明

最后通知围栏后 Release App 更新构建通过（171.56 秒，`server-release-r13.log`）。之后源码审查确认 heartbeat renewal 仍使用普通 facade；现仅 renewConnections 切换为相同物理 entries/gate 的 renewal facade，不新增池或重复指标，admit/read/remove 保持 ordinary。该最小改动的最终 Release 更新正在进行，不能引用前次构建声称这项已编译。

App 覆盖展示按账号及当前活跃 scope 聚合，account Ready 不再掩盖 room Recovering；Ended 和未请求 scope 不阻挡，Ended 后同 generation 的全部非 Ended 状态均拒绝，更高 generation 可重开。第一轮 Xcode filter 未带 Swift Testing 方法括号，命令成功但 xcresult 的 totalTestCount=0，明确不记通过。通过实际枚举获得标识后，带 `realtimeCoverageAggregatesRequestedScopes()` 重跑；`app-coverage-test-r15.log` 终态 0，xcresult 明确 totalTestCount=1/passedTests=1/result=Passed。该函数覆盖旧 Recovering→Ready 链不能复活、合法新代次及旧 loop 的清理围栏。

Loader 当前的 Ready 计数只用于诊断，原独立数据库 head 对比证明前台游标最终追平，并不证明每条当前连接已安装实时覆盖。正在添加当前物理连接、实际请求 scope 的状态及水位证明，保持原发送质量和独立游标门槛；candidate wire46 要求该证据，reference wire45 无新协议字段而不伪造证据。当前尚未运行新容量场景。

### 最终产物及 r21：发送阶段完成，接收质量失败

上述准备之后，续期优先 loan facade 已接入相同实际 pool/gates，最终 ServerApp Release 构建通过（81.36 秒，`server-release-r16.log`），Account Release 通过（12.27 秒，`account-release-r19.log`），Loader Release 通过（15.84 秒，`loader-release-r20.log`）。Loader 实际描述的新覆盖证明算法 hash 为 `e78e858b035811daa13280913826ef2494d49611b071ed0f61418ce3e64b63fb`。客户端 Ended 作用域围栏的定向测试 r17 因新断言混淆 fixture 水位 7 与状态 revision 9 失败；只修正断言后 r18 实际 1 函数通过，不能将 r17 记录为通过。

`/tmp/imv2-actor-realtime-10k-1000-final-r21/candidate/result.json` 记录 6 个 Gateway、12 个 Loader、10,000 连接全部认证和预热，TCP 发送及确认均 29,988，共同消息窗口 30.006 秒，确认速率 999.344/s；无发送队列溢出、遗留消息或 missed heartbeat，实际排空。但覆盖证明失败，独立 `foreground-delivery-proof.json` 核对 10,000 个前台查看者，其中 1,843 个落后提交头，故 `qualityPassed=false`、driver 终态 1。没有执行 50k 或 5000 档，不能以发送成功声称本轮通过。当前场景 plannedReconnects=0，不能将它用于证明重连与丢回复恢复。

只读复核阶段指标：GW0–4 的 room Ready 始终 0，GW5 完成房间 Ready；GW0–4 activation waiters 始终为 4，实际 control RPC 均已收尾。PG 六次消息阶段快照均无阻塞，分片控制失败 tick 为 0。recoveryHead 生命周期最大 gate/driver/SQL 约 45/39/74ms，没有秒级持续排队证据。最后的 256 房间 wake 抽样发生在客户端断开之后，均无 outbox 行，不能据此证明断开前已向每条连接保留提示。

启动期另有可核对关联：首个指标样本中 GW2 reachable nodes 为 1、承载 256 分片；约 5.1 秒后 reachable 为 6、承载 32 分片，同时出现 29 次缓存失效和 17 次覆盖丢失。消息阶段在首样本约 60 秒后开始，因此覆盖停滞早于消息负载。本轮旧指标未包含逐分片 epoch 序列，不能把所有失效事件都认定为同一种 token 换代。

源码确认新的生命周期缺陷：Coordinator 在发现 descriptor token 更换后 `rotate` 所有活跃兴趣的 generation；既存 `activate` waiter 仍保存旧 generation，该换代分支未结束这些 waiter。后续 `ready(waiter.desired)` 永远为假。Registry 实际恢复并发为 4，因此旧等待者可占满全部名额，让后续房间订阅无法进入。这是确定的源码缺陷及与本次运行相符的机制，尚需定向复现和修复后运行确认，不能提前宣称 r21 唯一根因。正在统一审计 token 换代、owner 替换与取消的 waiter 终态，并增加低基数阶段观测；不增加 pool、超时或排空预算。

### 旧代次等待者修复与 r22 定向验证

Coordinator 现在统一检查 retained waiter 的 desired entries：缺失、非 active 或 generation 不匹配时结束为 stale；owner 替换及每次成功会话 rotate 都执行该检查。周期 rotate 耗尽也结束受影响等待者。取消、关闭、失败与 Ready 在实际 continuation 结束点记录终态；新增固定枚举的 session rotation 原因及按 kind 的真实读头结果/耗时，未引入 topic/user 标识标签。

`waiter-lifecycle-tests-r22.log` 终态 0，构建 116.35 秒，实际运行 6 个函数通过（新增函数两个参数 case），测试执行 0.031 秒。新增门控场景证明：descriptor token 更换后原调用实际收到 stale、重试的新代次 Ready；旧 head 等待中替换 owner 时旧调用终态、新 owner Ready；另一个分片的确认保持有效。用 9 秒 descriptor 触发正常下一次 resolve，无需等待周期 sleep。它证明本地协调状态机缺陷已修复，不替代真实多节点容量质量或完整生产故障矩阵。下一步使用最终 Release 产物按原预算重跑 10k/1000。

### r24 原规格重跑通过：缺陷因果链闭合

ServerApp 最终 Release 构建通过（184.81 秒，`server-release-r23.log`），Account Release 通过（9.37 秒，`account-release-r23.log`）。`/tmp/imv2-actor-realtime-10k-1000-final-r24` 使用原 fixture、scenario、资源预算与质量门槛；driver 终态 0，owned PG 及服务已自然清理。12/12 Loader 报告齐全，10,000 条连接全部认证，TCP 发送/ACK 均 29,988，完整共同窗口 30.003 秒，确认速率 999.504/s。发送失败、workloadFailed、missed heartbeat、消息队列丢弃与遗留项均 0；实际排空。

本轮 `coverageProofPassed=true`、`qualityPassed=true`。每条当前物理连接的账号与房间覆盖均 Ready；独立数据库核对 10,000 个前台查看者，missing/behind/ahead 均 0，较 r21 behind 1,843→0、房间 Ready 1,666→10,000。约 +86.6 秒实际指标记录 6 Gateway 订阅数达到 accounts+room 的 20,000 范围、activation waiters 全为 0；token_change rotation 各 94/105/72/167/91/18，stale settlement 各 24/23/19/19/24/23，换代实际发生且旧等待者明确收尾。结合定向回归及修复前后的指标、协议和独立持久头证据，本次旧代次悬挂机制已闭合。不能扩称所有历史故障均由此造成。

新读头指标中 wrong_owner/dependency/invalid 全为 0。消息 phase 六次 PG 快照无阻塞，ordinary/activation/renewal loan 排队均 0；实际 route_lookup held/SQL 计数首末均 6，owner snapshot 首末均 6，phase 前 1.918 秒至最后 phase 内 +28.709 秒的这两类来源增量均 0，不仅依赖旧空 route counter。末态控制和 activation 队列归零。本轮仍记录正文/元数据乱序缺口并通过补拉追平，不能称逐帧推送天然有序或将补拉算作正文实时交付。plannedReconnects 仍为 0，丢回复/重连 canary 与完整生产故障矩阵、50k/1000 和 5000/基线门槛尚未验收。

继续完成结构修正：控制 worker 与恢复屏障独立推进；恢复失败局限于实际 Topic/连接，不能旋转整个分片会话；每条连接的 Ready 仍要求同作用域的提示实际保留。该工作属于既定方案，不因本次 10k 通过而删除。后续源码变化只做相应定向验证，再冻结进行正式容量门槛。

### r25 控制、恢复与连接隔离：真实执行及两处测试错误

本轮由 root 独占构建/测试，使用仍在运行的 owned PostgreSQL `127.0.0.1:57517` 与两个 fresh disposable 数据库。命令显式设置 `IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE=1` 和主/次数据库 URL，过滤 ActorRealtimeRouting、ShardAuthentication、逐连接恢复、presence 合并、authentication drain 与新 recovery-head 集成项。实际日志 `/tmp/imv2rt-7o99fjew/recovery-isolation-tests-r25.log`；构建成功 127.69 秒，进程终态 1，不能记为整批通过。

ServerTests 实际执行 13 个测试函数（两个函数各两个参数化 case）：恢复实际槽在取消后保留、读头阻塞时控制/续期推进、单 Topic 失败及周期撤销 Ready、代次更换等待者终态、两端共享 presence 查询但独立保留/Ready、coverageLost 回调不等慢 socket 均通过；控制续期门控实际运行 5.331 秒。新 PostgreSQL 项实际执行并失败，而非环境缺失跳过：新测试使用当前业务时间，但既有 fixture 的真实 shard-admission 租约仅覆盖固定种子时刻至 +100 秒，创建 direct room 因额度租约过期未产生 opened receipt。仅修正新测试沿用原 fixture 业务时钟，不改生产租约或削弱头读取断言。

ActorClusterTests 实际执行 4 个函数，3 项通过，签名/权限/重放测试失败于旧断言 `appliedRevision == 1`。新 renew 协议明确不增加订阅修订，fixture 请求 nextRevision 为 0，因此修正断言为 0，保留签名、替换身份、权限与重放检查。两处修正尚待重跑。只读复核另发现 Registry 独立 shutdown 入口未即时撤销 Ready 写时围栏，正在窄修；本轮通过项不能替代该迟到写入检查，也不能替代真实节点故障或正式容量门槛。

### r26 受影响项通过，关闭入口即时撤销 Ready

Registry 停机入口同步清除 Ready 写时许可；保留水位凭据和发送 Ready 的入口及 await 后均检查 closed，实际排空期间不能重装许可。新增 `shutdownRevokesLateReadyEnqueue`：实际 H7 提示完成后，将 Ready 挂在真正 enqueue 前；观察 Registry closed 后释放写入，Ready 帧为 0、实际恢复任务归零、重复 shutdown 仍完成。没有缩短实际任务寿命或增加资源预算。

root 仅重跑两个 r25 失败项及新增停机项：`V2RealtimeShardAuthenticationTests|realtimeRecoveryHeadsIsolateUnavailableTopics|shutdownRevokesLateReadyEnqueue`。日志 `/tmp/imv2rt-7o99fjew/recovery-isolation-tests-r26.log`，构建成功 35.57 秒，终态 0；ServerTests 两函数均通过（真实 PG 0.860 秒、停机 0.003 秒），ActorClusterTests 四函数全通过。owned PostgreSQL 随后明确停止，原系统 PG 未触碰。r25 已通过部分不重复全套；该组合证明本批受影响机制，不代替最终 Release、真实节点故障和容量门槛。

下一批继续将心跳触发续租改为按实际确认期限提前调度。只读审查确认此前即使 SQL 异步批量化，每次未在途心跳仍 enqueue，批内新心跳完成后还会即时再次提交；现有唯一 timer 只有 expiry/retry，无正常 renewAt。本项须保留原 TTL、连接池预算、未知结果不延权和无新心跳不永久续活，并单独验证。真实生产控制器自然 TTL 重启 canary 也在实现；现 callback fixture 加速 expiry 的记录不作其替代。

### r27 心跳按确认窗口续期通过

Registry 现保存 `renewAt` 和 `coveredHeartbeatInstant`，只用原唯一 leaseWake。心跳更新本地活性并安排 wake；尚未到剩余确认窗口约 2/3 时不提交 SQL，到期且确有未覆盖心跳才进入原有界 batcher。成功重新计算窗口、覆盖该次提交的心跳，批内更新不立即再次提交；无新心跳直接到期，失败/队列拒绝在旧期限内安排有界 retry，提交期间仍武装旧 expiry。权威刷新路径同步更新窗口与覆盖点。不改生产 TTL、SQL 连接池预算或权限到期规则。

root 过滤原未变 presence 发布、local heartbeat/blocked renewal、late unknown expiry，以及两个新 next-window/idle 检查。`/tmp/imv2rt-7o99fjew/heartbeat-renewal-tests-r27.log` 构建成功 34.56 秒，终态 0；实际 5 函数全通过、总运行 0.601 秒。使用原门控夹具的真实短 TTL 与实际 timer，不使用公开 fake clock 配置；证明早期 8 次心跳 SQL 0、实际续期 1、阻塞期间本地 ACK、原权限到期后晚结果不复活、shutdown 等待实际 work、无新心跳不自续。该检查不代替生产 TTL 大规模调度或网络故障证明，后续 Release 和小规格集成待执行。

同步更新模块 inventory/dependency graph：`python3 scripts/analyze_v2_server_module_dependencies.py --sync-inventory` 实际终态 0，605 files、2118 symbols、2097 edges、forbidden 0、cross-target SCC 0。这是静态边界证据，不能代替运行时推进验证。

### r28 本批 Release 构建通过

root 串行、每次四 jobs 构建生产 ServerApp（177.92 秒）、AccountServerApp（10.25 秒）及共同 GatewayLoadGenerator（12.56 秒），三个实际 handle 均终态 0。日志分别为 `/tmp/imv2rt-7o99fjew/server-release-r28.log`、`account-release-r28.log`、`loader-release-r28.log`；不是沿用 r24 旧链接结果。当前 Swift 源码冻结，下一步使用本批二进制进行 ≤500 小规格真实故障验证。重启 runner 与事实核对 helper 尚未执行，不能把构建成功当故障恢复或容量完成。


### r29–r33 小规模故障和本批容量证据

r29 benchmark summary 的四项脚本检查通过（实际进程终态 0）。r30 120 连接 planned lost-ack canary 实际运行：12/12 loader 完成，744 次发送全部确认，12 次跨连接恢复操作，最终 120 查看者 missing/behind/ahead 均为 0。原 `candidate/result.json` 的 qualityPassed 为 false，原因是事实核对 helper 错把仅记录永久拒绝的 closure 当作每个 accepted 操作必需行；不能将原运行描述为整体通过。修正 helper 后 r31 只重开该 owned PostgreSQL，不启动业务 writer；检查 fixture guard、最初零事实和 writer 排空，再只读核对相同 744 项事实。`fact-proof-recheck-r31.json` 和 `canary-recheck-verdict-r31.json` 均通过，原报告保留。它证明 Loader 的 planned 内存交接与聚合持久事实，不证明 App 自动重连及持久 outbox。

r32 `/tmp/imv2-actor-realtime-natural-restart-r32/candidate` 使用生产控制器、原 TTL 和资源预算，目标真实 SIGKILL 后重启，旧 epoch 2 在最后观测旧租约自然过期后变为 3；首次更高 epoch 观测在 kill 后约 32.580 秒。120 连接保留在幸存 Gateway，随后 348 次发送全部确认，30.005 秒共同窗口，质量/coverage/最终 120 查看者均通过。故障前 quiet phase 没有非零消息头，因此不能替代有积压的网络分区恢复或 pre-kill 每连接 Ready 屏障证明。

r33 `/tmp/imv2-actor-realtime-10k-1000-final-r33/candidate/result.json` 使用 r28 源码构建：10,000 认证连接，29,988 发送和确认，30.001 秒共同窗口；failed/workloadFailed/heartbeatMissed/queueOverflow/abandoned/pending 均为 0，实际排空，quality/coverage 及 10,000 独立查看者游标检查通过。存在 5,923 live gap frames 和 8,819 metadata gaps，经恢复最终收敛；不能把接受吞吐通过推导为无缺口实时交付或严格 FIFO。owned PostgreSQL 与运行进程已结束。本批仍没有正式 50k/1000 和 50k/5000 证据。

### r34 网络分区资格修正进行中

当前源码核对发现：实时分区 controller 在仅自身可达时继续作为候选续 PG 租约，RoomHost 的 renewLoop 也仅凭 PG lease safety 持续续租。Actor 网络隔离而 PG 正常可能使旧 owner 永续，幸存节点无法接管。此为源码可证的缺口，尚不是一次真实网络故障运行结论。正式容量门槛延后到本项修正冻结，避免大规模运行被新源码作废。

新增固定 roster 多数服务资格与双向认证发现，RoomHost 与实时分区共享同步 proof generation/deadline；资格失效关闭新业务与新续租，实际已发 SQL 仍必须结算、旧结果不复活本地服务。PG 保留唯一 owner，未知 claim 无可确认 epoch 时等待原 TTL，不能因失联强抢旧有效租约。三节点允许一节点失联，两节点要求两票；单机为明确配置。尚无本批构建或 Swift 测试结果。

原生 task-owned Actor 网络夹具新增 source-specific TCP proxy 和 Darwin connect interpose，只改精确 loopback Actor 拨号端口，保留真实 ActorID/TLS、PG及客户端端口。root 实际运行一项三节点受控 stream 测试，终态 0（0.007 秒），验证 touch-A 已有/新流黑洞和其他节点通信；`clang -std=c11 -Wall -Wextra -Werror -dynamiclib -arch arm64` 实际编译 dylib 终态 0。尚未证明生产 Swift 二进制注入和 Actor association 覆盖，不能视作真实产品分区故障通过。


### r34–r36 资格代码构建与定向检查

root 实际 r34 `swift test --package-path IMV2Server --jobs 4` 聚焦 realtime routing/authentication、Host 资格及 safetyExpiry、Controller 无多数/晚续租/晚claim，构建成功 123.15 秒，原进程终态 1。实际 22 测试函数（两个函数各两个参数 case），新增固定多数、双向发现认证、实时旧token不复活、Host晚acquire/renew和无callback期限、Controller无资格零SQL/晚renew/关停lateclaim均通过。唯一失败为既有 `partialHeadFailurePreservesHealthyTopic` 第一处 `isReady(good)`：坏 Topic 先完成组合 waiter，健康 Topic 仍在独立 recovered await，测试把组合错误返回当成全部健康 Topic 已Ready，缺少完成屏障。

仅将原来紧接断言之后的 `try await coordinator.activate(good)` 移到该断言之前，保留 bad/good 状态、不增加control、同session及实际lost callback占用全部断言，不改生产 recovery 语义。r35 只重跑该函数，日志 `/tmp/imv2rt-7o99fjew/service-qualification-test-recheck-r35.log`，构建25.97秒、实际1函数0.008秒、终态0；r34原日志与失败保留，不将原整批改写为通过。

r36 配置本次 owned PostgreSQL57517/真实 disposable数据库，仅执行 `confirmedClaimRetryAndActualShutdown`。`/tmp/imv2rt-7o99fjew/service-qualification-postgres-r36.log` 构建2.20秒、实际PG检查5.137秒、终态0；确认 unknown COMMIT复用原claim token/原expiry，真实renew SQL gate期间shutdown仍等待，开gate后精确清理。PG实际 pg_ctl stop终态0，系统PG1995未操作。新增qualification和剩余期限两低基数gauge已生产接线，本批未运行新Release或真实生产网络分区。

Darwin task-owned原生connect probe实际验证loaded/mapped、目标proxy收到连接、豁免端口收到原连接、原被映射端口未收到连接；`actor-connect-probe-r34.json` passed=true、productionBinaryTested=false。第一次Python3.9 probe验证器误捕获TimeoutError而非socket.timeout，异常结束；仅修正该验证器并重跑，产品和代理未修改，不能将其算产品失败。

`analyze_v2_server_module_dependencies.py --sync-inventory` 实际终态0，605files/2118symbols/2097edges/forbidden0/SCC0。工具明确只覆盖原六个Server模块，不覆盖新增ActorContracts/ActorCluster/ActorRuntime层；数字未变化不是新增资格已接受全层静态分析的证据。接线交叉审查另修复成功Transport stop后资格observer强引用环；失败停机仍保留实际排空重试能力。

尚缺真实生产网络故障检查点：现Loaderwarm文件只证明active/requested，coverageEvent计数与终态connection snapshots无法证明故障前每连接Ready(H>0)。故障夹具须补event-loop实际检查点，并包含Account非投票Actor caller的代理映射，不能留下可绕过隔离的Actor通道。后续原正式容量/App/多端/热路径与遗留审计范围保持未完成。

### r37 App 集成与软失联恢复审查

root 使用现有 IMApp scheme、iOS Simulator 和每次四 jobs，实际执行 `V2RoomSubscriptionAppTests/realtimeCoverageAggregatesRequestedScopes()`。`/tmp/imv2rt-7o99fjew/app-coverage-final-r37.log` 进程终态0、TEST SUCCEEDED；实际1函数0.003秒，当前 App 与 ClientKit 集成构建通过。此项证明 scope coverage 聚合，不代替真实 TCP 意外断线后的持久 outbox 自动重放。

随后源码审查确认两处恢复缺口：Realtime shard discovery 和 RoomClusterDiscovery 都把健康探测超时升级为 exact node `cluster.down`。进程仍存活且 UID 不变时，网络恢复不能重新加入；这不是已完成真实分区实验的结论。正在改为软失联先停止新调用、等待实际 work/handshake 结束并清旧会话；新认证发现可以恢复同一存活实例。明确实例替换或生命周期终止才永久退役旧 UID。新增真实每连接检查点与本修正尚待编译和生产故障验证。

### r38 软挂起通过，重启关联缺口未关闭

root 实际运行受影响四项 Swift 检查，日志 `/tmp/imv2rt-7o99fjew/soft-recovery-tests-r38.log`，编译成功，进程终态1。新增 `softReferenceSuspensionDrainsAndReauthenticatesSameIncarnation`（0.015秒）、`suspendBeforeActualDrain`（0.050秒）、`replacementDrainsOldRPC`（0.028秒）通过；原 `discoversRestartedHost` 在20.693秒报 `.overloaded`，不能将本批称全通过。脚本真实每连接检查点、summary和proxy共6项实际通过（0.009秒）。

停止原timeout-down后，原测试的同端口新进程无法被发现。Vendor `ClusterShell.beginHandshake` 对已关联 endpoint 直接返回，而旧关联仍保存关闭的 channel；持续 `join` 不等于实际重连。正在定位库内 transport association 的重建边界。尚未修改 Vendor，也未增加超时、退回健康超时永久down或开始新的容量运行。

### r39 实际关联重建通过

固定 Vendor 三处有限补丁仅将 inactive channel 的 Association 在锁内重置为 associating；active channel、永久 tombstone 不重开。同 UID 成功握手保留 membership，不按实例替换 down；新 UID 仍按原流程替换。UPSTREAM pin 不变，PATCH.md 记录行为。

root 实际执行 `discoversRestartedHost|softReferenceSuspensionDrainsAndReauthenticatesSameIncarnation|replacementDrainsOldRPC|V2MembershipGossipRestartTests`，`/tmp/imv2rt-7o99fjew/association-recovery-tests-r39.log` 编译11.44秒，实际4函数全通过，19.909秒，进程终态0。扩展原 discovery 测试先关闭实际 NIO channel，保留两个 ClusterSystem、原签名 beacon 和缓存引用，确认新 channel active 且同 UID membership 未 down；随后原同端口两次新进程实例更换均通过。没有增加测试截止时间。此项关闭 r38 的定向失败，仍不能替代生产静默 Actor 网络黑洞、多数资格/PG接管与客户端游标证明。

### r40 Release 通过，r41 代理地址族失败

root 串行构建本批 ServerApp（198.98秒）、AccountServerApp（12.91秒）、共同Loader（17.51秒），各实际进程终态0。Loader检查点改变源码后，补更新共同算法指纹为 `10227e2c4327b8fb01f00b4eebe313b768990f7ffb58ccc6bdb68d4e4ea6d0e3`，仅重建该受影响产品（15.90秒、终态0），未重编两个服务。日志在 `/tmp/imv2rt-7o99fjew/*release-r40.log`。

r41 `/tmp/imv2-actor-realtime-network-partition-r41/candidate` 实际启动6个生产Gateway、Account、代理及120连接；预填充阶段12个Loader全部连接loss guard失败，发送0，尚未故障注入，进程终态1。原失败报告保留，owned PostgreSQL实际stop完成。代理最终252条opened全部backendFailures、forwardedBytes0；Gateway日志显示Actor只绑定IPv6 `::1`，代理却硬编码后端IPv4 `127.0.0.1`，导致握手前连接失败和TLS EOF。这是夹具地址族缺口，不能作为产品网络恢复失败/通过的结论。

同次源码/日志复核发现Gateway到Account18343仍直连，只有反向Account到Gateway经代理；须补非投票caller双向映射，保持其不进入六Gateway多数roster。夹具将保留原TLS、实际连接/缓冲/超时预算，并补IPv6-only与caller双向覆盖的有限反例后再运行。

### r42 双栈转发通过，预填充目标配置错误

修正夹具后，root 实际7项 proxy/checkpoint/summary脚本检查全通过（0.020秒），包含真实IPv6-only后端往返及非投票caller双向黑洞；无生产重编。r42 运行 `/tmp/imv2-actor-realtime-network-partition-r42/candidate` 在原120秒启动预算内确认六Gateway资格有效、installed合计256后启动120连接；代理实际转发4,474,555字节、backendConnected36，地址族缺口已消除。预填充仍失败，全部认证成功、发送0，尚未隔离，原报告保留；实际进程终态1，owned PostgreSQLstop完成。

源码与实际命令/凭据数量核对定位：prefill CLI targets-per-connection=1，原paired fixture每凭据targetRoomIDs.count=2；Loader StartWorkload 的数量guard主动关闭所有已认证连接。各Loader started/ended相距约1秒，protocol/workload错误计数0，不能将其归因于新侧车或服务端集群日志（down晚于断链）。仅修正夹具目标数与原主 workload/pairing一致，不削弱Loader数量guard。代理末尾socket_close_not_confirmed另在只读审查，不将其静默抹除。

并发交叉审查另发现Sender每node单退休identity可被旧实例退役重试覆盖新实例软挂起门控；有限在途和PG围栏仍在，但不满足本地关闭新准入的合同。正在改为固定roster内的当前认证精确引用与generation匹配；旧descriptor晚到不得重新开业务，已派发旧调用继续实际结算。该修正未构建或运行，本批r40二进制不能冒称包含它。

### r43 精确引用准入检查通过

Sender改为最多原maximumPeers项当前认证descriptor记录；本地自有引用在同步初始化显式seed，远端必须通过认证发现安装。正常健康刷新保持record/session；软恢复或新引用更换record。开始、实际handshake await后及派发前匹配record身份、精确引用和suspended状态；旧派发reply仍正常结算。发现安装带本地单调observation，旧poll不能跨await覆盖新引用；原opaque bytes保留于watch descriptor，不重新JSON编码判等。拒绝同identity换ActorID/同物理Cluster UID换endpoint，避免精确node down误杀新endpoint。不使用永久身份集合积累churn。

root 实际 `V2RealtimeShardAuthenticationTests|discoversRestartedHost|replacementDrainsOldRPC`，`/tmp/imv2rt-7o99fjew/reference-admission-tests-r43.log` 编译124.12秒、实际9函数全通过19.761秒、进程终态0。soft回归0.014秒包含first-use拒绝、旧退役不能覆盖新软门控、旧observation不能覆盖新引用、实际旧reply和认证恢复；签名/权限/重放、stop实际槽、原channelclose/restart检查均通过。不声称已做新的真实生产隔离。

prefill目标2修正、proxy关闭低基数分类及最终fixtureCleanup门槛已冻结。root实际7项脚本检查全通过（0.017秒）；最终代理关闭失败会保留productQualityPassed而overall quality=false，不再只日志报错却accepted。未确认关闭计数明确不是OS当前FD数。下一步仅构建受影响两服务，Loader源码/算法二进制未变，无需重编。

### r48–r51 共享发现、租约历史与进度文件修正

r48 真实两ClusterSystem、100个同partition miss/25取消检查编译114.39秒，进程终态1；新断言将已结算discoveryPasses误当started。仅修测试口径后r50编译4秒、实际1函数0.017秒通过，进程终态0；在屏障中settled0/active1，25取消不结束共享发现，75取得同真实签名token，最后实际排空。生产代码未改。

r49 根代理用现有owned PG57517创建独立临时库，实际安装有界同事务租约历史trigger，验证回滚不可见、精确release后claim的两行历史与strict_release证明通过，`/tmp/imv2rt-7o99fjew/witness-preflight-r49/result.json`。此预检仅验证夹具SQL，不代替生产Store；临时库已删除，PG实际stop终态0。首次预检使用该集群不存在的benchmark角色，连接失败，未创建库；随后以实际owned集群owner执行。相关checkpoint/proxy/summary9函数通过。

模块工具显式增加Actor四层扫描模式，不改原六模块inventory；`/tmp/imv2rt-7o99fjew/actor-layer-dependency-audit-r48.json`657files/2473唯一symbols/2569edges/forbidden0/SCC0。该工具是近似唯一符号扫描，不解析动态分派或typealias，不等于编译器证明。当前源码删除旧路由类型/SQL表的检查仅保留schema absence断言与无关metrics名称。

r51真实生产canary进入isolate后，第二次persist发现progress文件仍用create-only `private_json`，报FileExistsError；except再次persist又报同错，不能称分区恢复通过。根handle51563终态1，owned服务/代理均终止。已保留原runner副本 `/tmp/imv2-actor-realtime-network-partition-r51/runner-source.py`。随后一次完整审核重复写路径：progress、每轮checkpoint及finally重结算result使用有限32MiB/0600/同目录原子快照替换；唯一history/proof仍禁止覆盖；finally记录失败不遮蔽原错误、不中断实际cleanup。root实际checkpoint/proxy/summary共10函数通过（0.031/0.017/0.001秒），包括多轮before/isolated/after真实文件状态机；未启动下一轮或将r51改写为通过。

App真实自动TCP断链后的durable outbox专项测试与ACK-cut代理已静态准备，未构建或运行，仍属未验收。生产冷热寻址SQL、正式50k/1000→5000/基线等原条件保持未完成。

### r47 实际检查点就绪，夹具 UUID 关联失败

r47 `/tmp/imv2-actor-realtime-network-partition-r47/candidate` 真实预填充质量通过。root 只读检查12份实际响应，`checkpoint_connection_proof(parts,[10]*12,require_ready=True)` 返回true，包含120连接的非零房间头与Ready。请求nonce是Python小写UUID，Swift响应是同UUID大写；runner字符串判等导致 `partition_checkpoint_timeout`。尚未隔离，原失败报告保留，根进程31433终态1，owned PostgreSQL实际停止。这不证明故障恢复通过。

实际 `fixture-cleanup.json` ownedProcessSettled=true、unconfirmedClosureCount=4：normal关闭peer_reset3/io_error1，timeout0。现统计将wait_closed异常一概当未确认关闭，须结合实际transport/socket终态检查。下一次启动前先完成夹具关联和关闭判定的审核验证，不延长截止时间或改写原失败结果。

root 随后实际串行运行checkpoint/proxy/summary脚本检查，共8函数全部通过（0.001/0.018/0.001秒，各进程终态0）。nonce按UUID结构匹配，缺失/非法拒绝、旧有效nonce等待；关闭异常分类保留，仅peer_reset/io_error且捕获的公开socket FD=-1、transport.is_closing才计为已确认关闭，原1秒限制未变。原r47失败报告未改写。没有启动新服务或声称生产隔离已通过。

静态审查发现另一证据缺口：精确release保留原epoch/token，将expires_at缩到DBnow；两秒采样可能漏过释放后、接管前的中间行，不能仅凭旧采样expiry判定新接管违法。现有安全判定尚未放宽；下次完整隔离运行前须补独立、同事务的精确旧/新租约历史证据，不能用当前行推造历史。

### r44–r46 本批业务预填充通过，检查点路径参数修正

root 串行生产ServerApp构建175.71秒、AccountServerApp9.18秒，日志 `/tmp/imv2rt-7o99fjew/{server,account}-release-r44.log`，实际终态均0。r45 `/tmp/imv2-actor-realtime-network-partition-r45/candidate` 真实预填充7200发送/7200确认，原质量检查通过，并产生非零房间头；之后main Loader全部参数拒绝，尚未注入网络隔离，运行终态1、owned PostgreSQL实际停止。代理最终关闭未确认，新增fixtureCleanup门槛明确失败，未被改写成accepted。

root 仅以纯Foundation路径程序复现：现有report parent解析为 `/tmp/...`，不存在request full URL仍为 `/private/tmp/...`，目录包含校验false；没有启动服务定位此问题。修正Loader统一解析已有父目录再append filename，并保留不同文件/拥有目录/非regular已有文件拒绝。共同算法指纹更新 `182ae1928586b19c5eafd9ede5dfa6ce58f6217ead31ccdc0c6892932cd36109`，仅Loader Release构建17.15秒、进程终态0，两服务未重编。

root 用r45实际完整main argv，仅将report/checkpoint输出换到新owned诊断目录并将目标TCP端口设为未监听的1，执行新真实Loader二进制的参数预检。`/tmp/imv2rt-7o99fjew/loader-args-r46/report.json`实际产生：configurationRejected=false、authenticated0、terminalError为connection failure guard10/10；诊断进程终态1是明确预期的未监听端口结果，不能描述为业务通过。证明真实CLI已接受该合法检查点配置，不再重开完整服务来发现参数错误。后续仍须真实隔离、正式容量和App原验收。

### r52–r54 真生产 Actor-only 隔离与同实例恢复

r52 `/tmp/imv2-actor-realtime-network-partition-r52/candidate` 保留实际失败：runner报 `partition_takeover_lease_not_active`，最终main报告0/12、确认0、quality=false；清理实际完成。不能据阶段中间文件将整次运行改为通过。r53 App专项 `app-outbox-build-r53.log` 实际 `TEST BUILD SUCCEEDED`，仅是构建证据。

r54 `/tmp/imv2-actor-realtime-network-partition-r54/candidate` 实际通过：120连接、12/12报告及进程终态0，TCP348发送/348确认，heartbeatMissed=0，30.006秒共同窗口；最终120个独立前台游标 missing/behind/ahead均0，全部当前coverage proof通过，fixtureCleanupPassed=true。`actor-partition-canary.json` 明确 productionControllerUsed=true、alteredLeaseTTL=false、alteredPoolBudget=false；真实Actor网络黑洞期间目标资格撤销，目标客户端心跳继续，恢复后仍同进程/物理客户端连接。故障前已验证逐连接Ready及非零房间头，不再仅用安静H0作预故障证明。独立同事务租约历史记录epoch1→2→3，两个边界均有strict_release证据，未根据最终行反推中间接管是否合法。

这是六Gateway固定可信roster、一个非投票caller的本机受控网络隔离/恢复功能证据；没有要求客户端断线重连，也不是容量验收、Linux跨机部署或所有网络故障矩阵。不能用348次确认推断正式50k/1000、50k/5000或与原版≥80%已完成。

### r55–r59 App真实断链持久outbox专项

r55 `/tmp/imv2-app-outbox-r55/candidate` 保留失败：真实测试在2.747秒于 `dueOperationWork(...).first` 取得nil；冻结intent尚未实际materialize工作，runner最终failureCode=timeout、quality=false、fixture cleanup通过。r56 `app-preparation-r56.log` 仅实际GRDB准备边界 `createsExactWorkBeforeAnyNetworkSubmission` 一函数0.091秒通过，不能替代TCP断链恢复。r57 `/tmp/imv2-app-outbox-r57/candidate` 真实一函数11.141秒失败，`receiverProjectionTimedOut(visibleMessageCount:0)`，quality=false、cleanup通过；随后夹具先通过接收者的真实typed TCP accepted回复建立互通，独立baseline操作不算主故障操作的one-fact。r58 `app-outbox-build-r58.log` 实际测试构建成功，仍不是运行通过。

r59 `/tmp/imv2-app-outbox-r59/candidate` 的 `result.json`：qualityPassed/productQualityPassed/exactFactPassed/appProofPassed/stableCommittedFact/fixtureCleanupPassed均true，Xcode实际退出0、ownedProcessSettled=true，capacityAcceptance=false。`app-xcode.log` 确认 Swift Testing实际1函数通过（函数3.356秒、运行3.357秒）；前面的XCTest兼容层0tests不能冒充此项实际运行。

`app-local-store-proof.json` 记录同workID/同identity、实际unknown后recover、自动跨Gateway重连到新physical connection generation；新generation的room Ready H=2，sender已应用cursor=2、receivercursor=2。测试亦关闭并重开SQLite检查原持久结果。`app-precut-fact.json` 在切断ACK前已只读确认主操作的消息/永久receipt/domaincompletion各1，精确accepted=true、roomSequence=2，negative closure=0；后续stableCommittedFact保持同一主操作事实，不把准备回复或aggregate消息数算成该操作证明。`app-proxy-switch.json` 记录实际切换与原连接排空，最终 `app-fixture-cleanup.json` opened=drained=3、held=false、flows空、closed/stopped=true、closeFailures=0，证明代理实际结算。原r59/r60的result fixtureCleanupPassed仅合并App Xcode与代理状态，尚未AND runner服务/PG终态；根另行实际ps确认服务均terminal、owned PG stop进程退出0，不能把此独立核查冒称旧result已具备完整AND。

本项是当前App/ClientKit真实TLS和GRDB outbox在提交后丢ACK、未知结果恢复、跨Gateway新连接Ready及游标应用的功能验收；不是App多设备/旧scope cleanup专项，也不等于UI全流程、正式吞吐或整个迁移目标完成。10000次热publish专项及新增同用户两设备真实TLS room-scope cleanup仍待独立实际执行；原生产冷热寻址SQL、正式容量与同规格基线比较门槛保持未完成。

### r60 同用户两设备与旧房间scope清理通过

`/tmp/imv2-app-multi-device-r60/candidate/result.json` 实际qualityPassed/productQualityPassed/markerPassed/fixtureCleanupPassed均true，Xcode实际退出0、ownedProcessSettled=true、exactMarkerCount=1，capacityAcceptance=false。`app-multi-device-xcode.log` 确认 Swift Testing实际 `oldSocketUnsubscribePreservesBothCurrentDeviceScopes` 一函数0.863秒、整体0.864秒通过；前面的XCTest兼容层0tests不作为运行证据。

该函数真实发行同B账户第二device凭据，短暂保留四个TLS socket：A/GW0发送；旧B/device1/GW0先建立，新B/device1/GW1后建立，B/device2/GW1同时在线。先通过真实typed TCP操作发送S1，三个B接收socket各取得对应房间hint并拉取、应用到各自独立SQLite。旧socket房间unsubscribe取得真实ACK后关闭，再发送S2；两个新设备各取得S2提示并持久应用、检查S1/S2 messageID和游标。重新订阅使用实际已应用cursor取得新的Ready scope，高水位不低于该cursor；两设备各自的physical connection generation保持不变，scopeGeneration提升。这证明旧连接/旧scope清理没有撤掉新设备连接的实际房间覆盖；Ready仍仅是订阅屏障，不能替代SQLite应用，也不将这两次顺序发送检查称为严格server消息FIFO证明。

根代理已实际shutdown/delete本轮owned Simulator（95F3CD3B），测试设备CA随owned设备删除，未改变host trust。App/Xcode及代理清理通过，runner服务/PG终态由根额外实际检查确认（原result还未合并该AND），未将测试连接留作后续运行依赖。该项关闭r59记载的同用户多设备room-scope cleanup专项缺口。r61使用此前已编译冻结probe执行10000热publish，实际根进程81239终态1，`/tmp/imv2-realtime-hot-r61/sender.log` 报综合 `hot replacement callback/cache settlement contract failed`，不能计为热路径通过；owned PG及专属库已实际删除/stop退出0。原probe没有输出各失败分量，新增 `hot-publication-observation.json` 的before/after计数及范围标注尚未实际执行；cacheHit全Handle包含周期Coordinator resolve是静态可证口径，不能凭此认定唯一失败原因。生产SQL热路径与原正式容量/同规格基线验收仍未完成。

### r64 热publish实际计数归因，旧综合断言失败保留

`/tmp/imv2-realtime-hot-r64/hot-publication-observation.json` 为实际执行后的计数：publishStarted/publishSettled各增加10000，实际callback增加10000，cacheMiss增量0、cacheInvalidations增量0，global cacheHits增加10002；同期controlStarted增加2、background discovery结算增加12，实际热段12.587510125秒。本次根进程80088终态1，旧exact cacheHits==10000的综合assert失败保持原样，不能将r61/r64原失败改写为成功。

该观测与Coordinator实际续期调用同Handle.resolve的源码吻合：cacheHits是whole-handle计数，包含后台控制恢复，不具备每次publication精确归属。仅修测试工具的错误计数门槛为global hits≥10000，同时保留实际10000 publish started/settled及callback精确增量、miss0和新增invalidations0要求。结果保留观测的真实global命中值，不制造精确publication-only计数；driver同步相同口径，未改业务门槛、预算或deadline。此修正尚未重新构建/执行；其后旧delivery/ref拒绝与完整actual drain仍须在新的实际运行中通过。该probe没有生产寻址SQL动态计数器，不替代原生产零寻址SQL或正式容量验收。

### r65 真实双向压力与控制预留

根代理实际probe构建r63成功（8.28秒）；driver r65/root93793终态0，`/tmp/imv2-realtime-duplex-pressure-r65/duplex-pressure-result.json` passed=true、receiver/sender actualChildExitCodes均0。复用原两进程TLS/签名RPC入口，`--duplex-pressure`保留原60秒期限。两端各持两条实际publish回复时，renew、subscription delta及反向Gateway callback成功；取消后实际本地槽保持占用，第三条同peer发布仍拒绝。远端门控方法放行后每端control started/settled=3/3、publish=2/2，实际远端方法结算与重复drain通过。

旧shared peer2改为control2/publish2独立预留，单peer两lane合计由2增至4；global control4/publish12保持。实际生产GatewayActorRealtimeRuntime未给makeRealtimeTransport传limits，callback transport默认32；ShardService共享delivery workers硬上限16、peer2，presence/typing4包含于16。因此正常分片链4+12+16=32，不是delivery12，不声称所有预算没变。

本fixture真实互签资格但手工安装token，postgresLeaseAdmissionTest=false；证明RPC资源隔离，不证明PG所有权。RemoteCall timeout只结算本地continuation，不证明远端终止，本case用实际门控方法返回另行证明结算。r54完整生产Actor-only隔离、自然租约与同物理客户端连接恢复证据独立保留；本项不替代热10000或原正式容量/基线验收。

### r67–r68 真实10000热publish与旧围栏通过

根仅增量构建受影响Probe，r67实际4.81秒通过；r68根进程4065实际终态0，`/tmp/imv2-realtime-hot-r68/partition-handoff-result.json` passed=true。`hot-publication-observation.json` 的实际publishStarted、publishSettled、callback各增10000，cacheMiss和cacheInvalidations各增0；whole-Handle cacheHits实际增10002，同期controlStarted增2、背景discovery结算增13，热段12.2055345秒，末尾publish/control active及pendingHandshakes均0。`sender-result.json` 保留真实10002而非伪造publication-only归属。

同一次两进程签名调用检查还通过epoch1→2、宿主新incarnation及session/interestGeneration更换；存活Gateway只activate一次，自动Desired恢复与fresh head屏障通过。旧PG token无法续期、实际旧delivery被围栏拒绝、旧引用在派发前被拒绝，最终服务/transport actual drain及精确lease release通过，无fabricated late reply。根实际删除专属测试库，owned PG stop退出0。

范围保持：本夹具在确认旧进程SIGKILL退出后手工精确lease expiry，使用fixture renewal，productionControllerUsed=false。不能用它替代自然TTL或生产Controller；r54已另外提供真实生产Actor-only隔离/恢复功能证据。这里 perCallAddressSQLMeasured=false、perCallReceptionistMeasured=false：10000实际RPC/回调与cache miss0证明本Probe热引用路径，不等于已经关闭生产零寻址SQL/逐调用Receptionist动态计数验收。r61/r64旧测量失败继续保留，r68是修正计数口径后的独立真实通过；正式容量与同规格基线比较仍未完成。r69生产Server/Account Release随后均已实际通过，具体时间见下一节；该构建结果不等于容量通过。

### r69–r70 当前生产产物与容量进度

根代理串行执行本批 Release：`/tmp/imv2rt-7o99fjew/server-release-r69.log` 实际构建176.75秒、进程终态0；`account-release-r69.log` 实际11.01秒、进程终态0。两服务均包含每peer控制/发布独立计费修正。Loader算法未变，沿用r46共同产物；没有为测试筛选重新构建它。

r62实际执行summary四函数（0.001秒）与App multi-device helper两函数（0.002秒），全部通过，包含产品/App/服务/owned PostgreSQL清理的最终AND判定。r66离线hotpath proof两函数（0.003秒）通过，验证缺节点、旧时间戳、计数回退及不足10000实际发布窗口不能获得通过；它们不证明生产SQL为零。

r70 `/tmp/imv2-actor-realtime-10k-1000-r70` 根进程95575实际终态0。12份报告完整、10000认证、29988 ACK、约999.531962消息/秒，`candidate/result.json` 的 qualityPassed/coverageProofPassed 均true；独立foregroundDelivery检查10000 viewer，missing/behind/ahead全部0。实际roomEventLiveGapFramesDetected=6315、roomEventMetadataGapsObserved=9181（metadata missing sequences=16275），因此此结果证明恢复后最终收敛，不能写作直播严格FIFO、零缺口或无需补拉。

同轮 `candidate/hotpath-address-sql-proof.json` passed=true：12报告共同rate-1000窗口1790948719.846–1790948749.848秒；首个完整六节点采集1790948720.87713–1790948720.942048，最后1790948746.534178–1790948746.5652921，共6个完整sample。实际publishSettledDelta=27042，route_lookup/realtime_owner_snapshot两个来源各四SQL phase的实际future计数增量均0，两个边界的address active阶段总数0，无计数重置。采集沿原HTTP请求新增batch及逐节点实际read起止时间，不新增请求或改质量条件；没有拿ACK数、setup暖机、旧routeQueries零counter替代。

此proof只覆盖两个指定寻址来源，明确排除业务registration/authorization、recovery heads、持久化、控制租约及未分类SQL；不证明全部服务零SQL，也不替代逐调用Receptionist测量。r70属于10k缩放质量/寻址证据，不是50k容量或≥80%性能验收。r71 `/tmp/imv2-actor-realtime-50k-1000-r71`（根进程65140）已实际终态1，原50k/1000、checkpoint180秒+消息90秒与原资源预算，质量与coverage门槛未通过。正式50k/1000→5000与同规格基线≥80%门槛仍未完成。

### r71 正式50k/1000终态与只读存储阶段审计

r71完整12份报告、50000认证、36次计划重连无heartbeat miss，最终89988 ACK、workloadFailed=0；共同消息阶段1790949307.717–1790949397.720约90.003秒，阶段ACK约959.913/秒。qualityPassed/coverageProofPassed均false，独立50000 viewer检查missing/ahead均0、behind=688；最终连接coverage快照另有155连接未通过，不能将两集合等同。该轮不是容量PASS。

`candidate/hotpath-address-sql-proof.json` 实际passed：17个完整六节点阶段样本、publishSettled增量63136，route_lookup与realtime_owner_snapshot实际SQL增量均0、起止active边界0；仍仅覆盖这两个明确寻址来源。离线可复查摘要为本轮根目录 `offline-phase-storage-summary.json`。

17个阶段PG快照中blocked峰7、fan-in峰2；累计观测等待者room_activation_fence=35、admission_fast_update=5、other=1，精确pool tuple等待2次，deadlock增量0。第一至最后阶段样本约86.5秒内pool更新1749、messages插入83699，已实际合批，但共享quota行仍存在且确有竞争；这些稀疏样本不足以证明其是688尾条落后的主因。部分room fence等待者的blocker处于idle-in-transaction、最近语句为admission_fast_update，说明业务事务在后续准入阶段仍持房间围栏；relation锁列表不等于特定pool行锁。

同样本窗口group_event_pull实际借用28525次、SQL future完成228115次（约8次/读取），其中fence114065次（约4次/读取）；SQL活跃采样峰40、gate排队峰15，对照durable_owner分别6/2。ordinary借用活跃峰54、排队峰58；realtime_recovery_head借用7184次、排队峰19/均值约52.43ms，读头wrongOwner/dependency/invalid阶段增量均0。恢复partition排队峰546，但session rotation阶段增量0、activation waiter峰0；周期30秒重验头本身会产生恢复读，不可将其全解释为会话故障风暴。PG采样约1.20–1.62核、host CPU idle约40%、swap未增长，不支持机器CPU上限归因。

终态wake witness在21:57:02.682、Loader关闭channels之后取得，截断选择256/688落后房间，全为no_outbox_row；路由已撤销后outbox可被正常删除，不能据此证明活跃阶段不存在待重试或提示曾完整交付。Gateway阶段内无日志错误，后续cleanup中的Actor/停机日志不归入消息阶段。688尾条最终未收敛的原因应结合客户端announce/head与投递状态审计，不能仅由pull SQL次数或已知共享quota推定。

### r71 原50k/1000运行失败：真实背压与最终覆盖缺口

r71 `/tmp/imv2-actor-realtime-50k-1000-r71/candidate` 根进程65140实际终态1；12/12 Loader各实际退出0，不等于整体质量通过。最终50000在线、89988发送/89988 ACK、workloadFailed=0、queue overflow/abandoned=0、heartbeatMissed=0、计划重连36；90.003秒共同消息窗口内86397 ACK，约959.913 ACK/秒。最终coverageProofPassed=false，逐连接49845通过、155失败；失败scope为30个account Recovering及150个room Recovering（同连接可重叠）。独立DB head检查50000 viewer，missing=0、behind=688、ahead=0，qualityPassed=false。不得运行下一5000档或将ACK无失败写作完整PASS。

离线限定phase窗口为1790949307.717–1790949397.720，gateway-metrics有17次采样，首样本晚0.633秒、末样本距窗口结束2.870秒；以下增量不是未采样边界或完整终态的精确计数。六Gateway在这些样本qualified始终1、资格余量18.917–19.993秒、reachable始终6；cache miss和invalidation增量各0、partitionControl failedTicks增量0，session rotation各reason增量0。partition renew succeeded合增102，head topic success room/user分别合增116639/117024，未见wrongOwner/dependency计数增加。没有可证的发现/资格换代风暴；离散采样不能证明任何未采样瞬间都无失败。

同时Sender rpc_capacity_rejected合增24559，实际control active最高4、publish active最高8；subscription control queued最高216、recovery queued最高100，activationWaiters及pendingHandshakes样本均0。publish started/settled合增63157/63136，末采样存在21个在途差额，不能将窗口尾样本计为未排空终态。Gateway ingress被观测到的body/recovery队列分别最多1项、1644/512字节，activity为0；这些瞬时值不能证明整个下游从未拥塞。

源码边界：Sender control/publish各自peer2、global4/12，已由r65实际证明两条held publish不抢控制peer槽；但这不增加任一lane自身容量。当前统一rpc_capacity_rejected计数未按lane/原因分，不能将24559一概归为控制失败或ShardService delivery失败。ShardService仍有真实delivery workers16、per-recipient2与每lane8个continuation的门槛，control入口8；其拒绝、Gateway接收及coordinator局部重试属于不同阶段，现采样无法精确把全部拒绝映射到688个落后游标。控制排队和背压是真实观测，资格稳定或入口队列小都不足以替代终态覆盖/DB游标质量证据；下一定位须关联具体失败scope与发布/接收阶段，而非猜测新peer隔离失效或机器资源不足。本轮只离线读已有报告/日志，不运行新测试、服务或PG，不改生产实现。
### r72–r75 定向修正验证（正式容量门槛仍未通过）

r72 Debug 编译83.09秒成功，原 metrics renderer 测试通过；Registry 房间参数失败原因是新增高水位阶段将权威夹具推进至9，末尾新 scope 仍断言7。仅修正为严格唯一 `[9]`，保留旧 scope 的7必须被拒绝及 Ready generation 超过 ended generation 的检查。r73 `/tmp/imv2rt-7o99fjew/registry-retention-r73.log` 增量编译27.09秒，原函数 room/presence 两个参数均实际通过（0.536秒），未修改生产行为来迎合断言。

恢复合并仅在同连接生命周期/订阅代次、实际 hint 和 Ready 入队回执、当前有效且匹配 token/session/interest generation 的确认均充分时成立。Ready 的 Bool 证明实际 socket-owner 队列接受，不证明字节写完或客户端收到。房间仍按原30秒间隔执行权威权限复核，高水位变化、失败 Ready、Recovering 或代次变化不能复用旧证明。新增 Registry 指标区分真实待恢复、授权、保留及 coverage 写入阶段，不能以 Coordinator 队列代替它们。

r74 `/tmp/imv2rt-7o99fjew/fence-r74.log` 使用专用 PostgreSQL16 实例57517及实际 disposable DB，`acquisitionAndRelease`、`pairOrderAndReadiness` 和 `lockWaitCrossesExpiry` 两个 scalar/durable 参数实际通过（3函数、4案例，2.847秒）。租约锁等待跨过到期后必须拒绝令牌；房间锁先完成，后一条语句完整消费租约 LockRows 后才读取数据库时钟。DB 实际删除、owned PostgreSQL 实际停止，均终态0。仅减少一次围栏 SQL 往返，不改变令牌、锁顺序或权限边界。checkpoint 的6个原/新增纯文件案例实际通过，0.032秒；首次从根目录执行的 import 路径错误保留于 checkpoint-r73.log，不计为运行通过。

r75 `/tmp/imv2-realtime-duplex-pressure-r75/duplex-pressure-result.json` 实际 passed=true，根进程及双子进程终态0。真实双向各2个 held publish 下，renew/subscribe/reverse callback 完成，取消保留实际 invocation，远端最终归还后重复 drain 完成；新断言检查第三次发布的拒绝来源为 publish/peer，control 分项不变且旧总数增加1。此夹具明确 postgresLeaseAdmissionTest=false，不替代数据库所有权或容量证据。上述验证未重跑已通过的 App、网络隔离或5000档；后续当前 Release/1000档及正式门槛仍待验证。

### r76–r78 实际 Receptionist 计数与下一轮构建

唯一 ShardTransport lookup 调用边界新增固定创建 pass 来源计数：foreground_resolve/background_discovery。共享已有 pass 的冷 waiter 不改变该 pass 的归因，因此 foreground=0 必须结合 cache miss、实际发布窗口及 background 增量解释，不能证明所有 Actor 系统零 Receptionist。r76 实际 typecheck 发现非复制 Mutex 被赋值捕获，失败日志保留；修正为原 Actor 持有 nonisolated Mutex 和同步 record helper，不加任务或等待。r77 `/tmp/imv2rt-7o99fjew/receptionist-metrics-r77.log` 实际 Debug 编译39.33秒、原 rendersAggregateMetrics 函数通过（0.006秒），包含真实非零两来源 renderer 断言。运行期新窗口尚未取得。

本轮模块近似源扫描 `/tmp/imv2rt-7o99fjew/module-audit-r75.json` 实际657文件、2482独立符号、2572边、forbidden=0、cross-target SCC=0；扫描不能替代编译器依赖或动态运行证明。r78 三个 Release 产物串行构建实际通过：Server187.93秒、Account9.29秒、Loader17.60秒，日志分别为 `/tmp/imv2rt-7o99fjew/{server,account,loader}-release-r78.log`，均实际终态0。更新后的共同 Loader 算法 SHA 为 `fbc6f224747a1d74b80879837c9b1243540c3da82939229254188ecaf8e54665`，不是沿用旧二进制。r79 10k/1000 使用当前产物与 bounded preclose witness 运行中；正式50k/1000及5000基线性能门槛仍未取得。

### r79 当前10k/1000质量与真实前台寻址证明

r79 `/tmp/imv2-actor-realtime-10k-1000-r79/candidate` 根执行会话53938实际终态0，12 Loader均退出0；10000认证、29988发送/ACK、约998.7266 ACK/秒，最终10000 viewer missing/behind/ahead均0，coverage/quality均通过，heartbeatMiss/overflow/abandoned均0。live gap4858、metadata gap7611仍存在，不证明直播严格FIFO。所有owned服务及PostgreSQL实际停止；系统Homebrew PostgreSQL PID1995未触碰。

实际共同窗口1790952510.369–1790952540.367中6次完整六节点采样，publishSettled增量30614，两指定地址SQL来源增量0/边界active0，`hotpath-address-sql-proof.json`通过。独立 `hotpath-receptionist-proof.json`在相同样本结合实际lookup边界计数及无reset：foreground lookup增量0、cache miss/invalidation增量0，background lookup增量1050。证明此暖缓存发布窗口的ShardTransport没有前台发起的Receptionist查找，后台发现仍活跃；不证明其他Actor系统或冷waiter归因绝对零。分析源 `/tmp/imv2rt-7o99fjew/receptionist-window-proof.py`随本轮证据保留。

`preclose-recovery-witness.json`实际status=observed：384当前连接/192房间，在12 Loader仍存活且关闭marker未建立时读取；客户端采样约1790952541.459，DB读取1790952543.467–2543.492，明确不同瞬间、不是原子快照。所采384游标对DB head behind=0。此有限抽样不替代最终10000全量验证或50k证明。

新指标揭示真实恢复背压：6个窗口样本合计room desired峰3391、queued峰2650、actual峰23（六节点实际槽总上限24）；authorization阶段峰23，retention阶段样本峰0，coverage_write峰2。控制peer拒绝增量1306、发布peer3330、delivery_peer3454、durable_publications6；room duplicateRetained增量0、account20。峰是各次六节点合计的最大值，阶段相互重叠、离散采样会遗漏短阶段，不证明所有任务都卡在授权。r80正式50k/1000原180秒checkpoint+90秒消息阶段正在运行；不能扩大10k通过为容量通过。

### r80 原50k/1000失败及关闭前真实现场

r80 `/tmp/imv2-actor-realtime-50k-1000-r80/candidate` 根执行会话49439实际终态1，12 Loader均终态0，六Gateway/Account及owned PostgreSQL实际停止（仅用户Homebrew实例PID1995保留）。原checkpoint180秒、消息90秒、drain30秒/hold10秒和固定资源预算不变。50036认证含36次计划重连、89988发送/ACK、0 heartbeatMiss/queueOverflow/abandoned，共同阶段90.006秒约968.924 ACK/秒；quality/coverage均false。最终全量50000 viewer missing/ahead=0、behind=794；逐报告和DB head对齐后793未收到最后announcedH，793 room仍Ready、1 Recovering，仅1还在pull、retryPending=0。不能把794都解释为客户端补拉被阻塞。

窗口1790953271.550–1790953361.556实际17个完整六节点样本，publishSettled增量64301，指定route_lookup/realtime_owner_snapshot实际SQL增量0/边界active0。实际foreground Receptionist lookup增量0，cache miss/invalidation0，background lookup3514；两个独立hotpath proof均通过，仍不扩大为所有SQL/所有Actor系统零查询。

新增 `preclose-recovery-witness.json` 实际observed，12 Loader在读取前后仍活跃且未开始关闭。384连接抽样对独立DB时刻有57落后，其中54存在wake（51 pending/3 leased）、3无outbox；41未有final announcement、16实际pull、8 retryPending（集合重叠）。这是活跃期间待重试积压证据，不能用after-close清表代替；客户端/DB时刻不同，且该抽样不是794最终集合的逐项因果证明。wake.target_room_sequence只为表内持久目标；实际claim在 `PostgresV2GroupEventWakeStore` 使用GREATEST(target, room.room_sequence)，不能因表内目标小于头推断发送永久使用旧H。

`offline-registry-and-rejection-summary.json` 给出窗口合计room desired峰49933、queued2652、actual24。原汇总错误地把六节点oldest相加：107.392秒authorization和508.655秒desired不能作为任何单任务等待时间。r86复核原raw样本后，r80单节点最大queued约85.19秒、旧authorization约29.678秒；原文件保留，新诊断明确不同口径。旧authorization包含manager.activate与实际foregroundBarrier，无法把这些时间全部归因于数据库授权。pending/gauge相互重叠、六节点离散样本不能代表每个瞬间。source拒绝增量：control peer3405、publish peer20788、delivery peer17988、durable_publications238；room duplicateRetained306/account360。

明确源码问题一：Sender本地预派发容量拒绝使用泛认证overloaded；远端delivery typed背压不能通过允许的Codable异常类型保持身份，持久Relay会落入最长30秒退避。修正仅本地publish global/peer预派发抛专用非Codable error，Fanout精确映射；Serving只把已实际settle的明确typed背压变成既有签名.overloaded reply。认证、停机、取消、混合硬错误、未知执行结果不转换，不增wirecase或限额。

明确源码问题二：accepted表示Gateway有界Ingress接受工作，消费的旧fence可能失效且普通Void通知未证明连接保留H。当前修正先保留scope责任、实际强enqueue后版本CAS清理；健康路径复用Ingress原四消费者并由Registry最多四个inline实际ticket等待结算，失败才进入原四恢复槽。恢复与inline双通道不会为同scope并发写，shutdown撤许可后等待实际返回。已发现迟到旧session invalidate无条件清新scope证据的问题，正在按来源隔离修复；不能将静态方案写作容量已通过。

### r81/r82 最小行为验证

r81 `/tmp/imv2rt-7o99fjew/durable-recovery-r81.log` 编译89.41秒成功，3函数4实际案例在1.018秒通过：原Registry room/presence参数、runtime metrics、partialPeerFailure。此版本验证了初版owned hint-only责任和明确背压；随后新增独立inline通道的源码需再验证，不能沿用r81证明它。

r82 `/tmp/imv2-realtime-duplex-pressure-r82/duplex-pressure-result.json` 根执行会话50494及两个真实子进程均终态0，passed=true。保持每方向2个真实held publish及peer2，控制3/3、发布4/4实际settle；新增localPredispatchPeerBackpressure、signedRemoteBackpressureReply、nonCapacityFailureNotConverted均true，原取消实际保留、反向回调、续租和重复drain均通过。此fixture postgresLeaseAdmissionTest=false，不替代PG所有权或性能证据。没有再启动5000档。

### r83/r84 强通知隔离和真实多用户授权批读

r83 `/tmp/imv2rt-7o99fjew/durable-state-batch-r83.log` 根执行会话37841实际终态0。冻结后统一Debug构建74.13秒，7函数9参数案例实际0.542秒通过：Registry原room/presence参数、四恢复槽受阻时inline强通知独立推进与实际停机drain、metrics、Host单SQL准入与实际取消结算、原最早deadline、timer清理、重复pair响应预算及逐pair失败隔离。旧H123在无Ready、新session已Ready和新H10在途三个位置均不得注入旧水位或清新证明。当前deadline显式校验且原实际授权30秒不因续租延长。

r84 `/tmp/imv2rt-7o99fjew/pg-state-r84-tests.log` 根执行会话65501实际终态0，指定disposable URL与独立database `imv2_state_r84`，两个真实PG函数0.546秒通过；没有使用缺环境变量会跳过SQL的路径。新`multiViewerOwnerBatch`验证同房间两用户不同readThrough/latestOwn、非成员unavailable及旧token房间独立activationChanged；实际SQL观测readBody=1、fence=3、transactionControl=2。原queryFamilies亦通过。独立database已实际drop、ownedPG已停止；用户HomebrewPG未触碰。此检查不证明新源码50k容量通过；r85正在生成实际Release产物，仍按10k/1000→原50k/1000顺序验证。

### r85/r86 新产物与小规格检查

r85 Server/Account Release顺序实际终态0，构建195.80秒/9.49秒；Loader复用未改动的r78产物。编译中采样到Gateway/Infrastructure frontend分别约100% CPU、RSS约1.2GiB，系统memory_pressure空闲约70%；构建request显式schedulerLaneWidthOverride=10且useParallelTargets=true。该采样支持当时没有内存耗尽，不替代完整编译阶段计时或历史资源证明。

r86 `/tmp/imv2-actor-realtime-10k-1000-r86/candidate` 根执行会话8396实际终态0，12Loader实际exit0、所有owned服务/PG已停止。10000认证、29988发送/ACK，995.570/s，心跳丢失/溢出/abandoned=0，quality/coverage均true，最终10000 viewer缺失/落后/超前均0。live gap frames5922、metadata gap observations20719仍存在，因此只证明最终收敛。关闭前采样384房间scope/192房间behind=0，所有Loader读取前后仍存活，客户端/DB独立时刻不视为原子快照。

共同phase1790956256.630–1790956286.633，6个完整六节点采样覆盖6259.809–6285.574，实际publishSettled增量25969，指定两地址SQL增量0/边界active0；foreground Receptionist增量0、miss/invalidation0，background1050。两个独立proof通过，范围不扩大。`offline-registry-and-rejection-summary.json`按每采样六节点同时sum count、单节点max oldest：room desired峰2610/queued2027/awaitingRetention702/actual24/authorization24/inline8/interestActivation0；最长queued7.546秒、authorization258.74毫秒、inline2.23毫秒。interest_activation只在这些采样为0，不能证明采样间从不等待。与r79同规格相比队列规模减少，但部分来源拒绝及最长queued增加，不能声称全面性能改善。r87正运行原50k/1000；50k质量、5000和完整基线门槛仍未通过。

### r87 原50k/1000再次失败：周期复核与应用读取准入压力

r87 `/tmp/imv2-actor-realtime-50k-1000-r87/candidate` 根执行会话82927实际终态1，12Loader实际exit0，全部owned Gateway/Account/PG已停止。原资源/fixture/180秒checkpoint/90秒消息不变。50036认证含36计划重连、峰50000；89985发送、89960ACK，901.460 ACK/s，workloadFailed34，心跳丢失/overflow/abandoned0。最终50000 viewer missing9、behind2136、ahead0，quality/coverage均false。34失败细分：room订阅UNAVAILABLE 9、发送未知结果未解决7、deferred retry耗尽18。独立全量reports/head核对证明2136全部unannounced finalH、全部activeForeground、pullInFlight/pullSlot/retryPending/gracePending均0；2102 Ready、34 Recovering。因此最终落后并非这些连接正在补拉。

关闭前384scope/192房间在Loader读取前后均活跃时抽样64behind，其中61pending wake、2leased、1无wake。两个独立时刻且非最终全量集合，不扩大为逐item原因证明。对应 `offline-preclose-classification.json` 保留原witness和quality，不覆盖原报告。

消息共同phase1790956836.951–1790956926.957，16完整六节点采样覆盖6837.511–6920.973，尾部约5.98秒不在样本。publishSettled增量51417；指定两地址SQL0/边界active0，foreground Receptionist0、miss/invalidation0、background3332，两个proof通过。room同时峰desired49959/queued2605/awaitingRetention21940/actual24、recheckActual24/recheckDemand43086、authorization24/inline9/interestActivation0；真实单节点最长queued82.195秒、authorization13.873秒、inline109.66毫秒。授权阶段包括RPC/Host前门/应用准入等待，不等同某条已借用SQL。interactiveRead实际峰43/queued2304、queueFull增量133952/timeout13465；ordinary物理loan峰54/queued59、renewal12/queued6。已观察source loan stage最长约292毫秒，恢复头gate均值68.9毫秒/SQL8.83毫秒；均值和离散阶段不能排除未采到的个别SQL等待，没有operation关联trace，因此不宣称PG死锁或硬件不足。

源码确定触发链：Coordinator每5秒检查维护，当30秒head-check到期，对该partition全部已安装Topic读头；recovered heads和coverage Ready回调进入Registry逐连接授权复核。authority30秒过期后不能走重复receipt快速跳过，实际每scope `foregroundBarrier(room,user)`仍调用 `states([room],user)`，即使同H仍可能重复Ready。50k scope按30秒均摊约1667次必要复核/秒；这是结构算式，不是实测平均执行耗时。新Host SQL多viewer合批并未消除Gateway上游逐scope RPC调用粒度，r87队列规模未解决。

下一批正在实现真正Gateway必要授权收集→已缓存物理Host分组签名批RPC→真实逐房间Host read-turn批准→多viewer集合SQL→逐scope CAS结算。保留原权限30秒/absolute deadline、4实际授权worker、每peer2、每批需求128/Host100、64KiB请求/256KiB回复及真实停机drain；不删除周期恢复、扩大预算或绕过逻辑Host。源码未冻结，不能宣称已验证；仍禁止直接进入5000档。

补充r87 `offline-resource-and-pg-summary.json`：同消息窗口16个PG/17个host采样，数据库deadlocks全为0、stats_reset为null；最多5个已采样阻塞backend，requested-lock wait最长0.229339秒、观察blocker fan-in最多2。类别行room_activation_fence36/admission_fast_update1/other2可能重复同一waiter，不是39个唯一事件。全机非回退CPU tick增量得到平均busy约60.175%（包括Loader和其它进程），memoryPressureLevel输出均1。这些数据与长应用前门等待相容，不支持宣称本轮已发生PG记录的死锁；点采样会遗漏瞬间，且CPU平均不能排除单核心或某阶段限制，不作为完整硬件因果证明。

### r88–r91 真实授权批链路的聚焦验证

三代理本批源码统一冻结后，r88/r89构建分别发现Runtime两个测试文件共三处错误使用Infrastructure才提供的domain→wire初始化器；根代理修成直接wire `.unavailable`，没有修改生产行为或弱化断言。r90 `/tmp/imv2rt-7o99fjew/authorization-host-batch-r90.log` 根会话79263实际终态0，增量构建71.94秒，跨3测试模块共11函数/14参数案例通过。Server模块8函数（10参数案例）0.542秒，Runtime2函数（3案例）0.081秒，Cluster1函数0.095秒。

新增Gateway `foregroundAuthorizationCollectsPairsAndDrains`验证同(room,viewer)两个设备仅一个授权输入、另一Host实际gate仍held时已完成Host可独立Ready、slow Recovering socket实际held不拖健康设备；重开scope拒绝旧submitted H7并用新授权H9；关闭等待实际任务结算。原inline与room/presence代次检查保留。Runtime `recoveryBatchOwnsAdmittedRooms`的取消/qualificationLost两案例验证2房间3viewer只占2真实reservation，实际callback未返回前不提前release/drain；`cachedRecoveryBatchUsesPhysicalGrouping`验证两个viewer合为一次Host调用且位置SQL lookup为0。

Cluster `signedRecoveryBatchViewerBindingAndActualDrain`使用两个真实ClusterSystem和native远端signed exchange：同房间两viewer及缺失房间独立结果；合法签名但普通user principal、缺roomCoordination服务角色均拒绝；两个实际peer调用挂起，取消waiter后实际仍占两额度，第三peer被拒，client/入站drain等待实际释放。此测试不证明mTLS、独立进程故障或真实SQL，先前r54/r82故障证据仍保留，不重复无关Realtime双向测试。

r91 `/tmp/imv2rt-7o99fjew/pg-host-batch-r91-tests.log` 根会话27601实际终态0，独立disposable DB `imv2_host_batch_r91`及明确环境变量；新HostRecoveryBatcher.states真实多viewer PG和原queryFamilies两个函数0.538秒通过，实际readBody1/fence3/transactionControl2，权限与旧token结果隔离。DB已drop、ownedPG已停止；用户HomebrewPG未触碰。r92正在生成生产Release，新批尚没有10k/50k容量结果，不沿用r86或宣称目标完成。

### r92–r95 小规格中断与受控reservation反例

r92 Server/Account Release实际通过197.40秒/12.55秒，静态边界脚本实际exit0，659文件/2492symbols/2596近似源码edges、forbidden0/cross-target SCC0；边界migration exceptions0。它不是动态调用图或行为证明。Room传输原外层预算实际为maximumActivationWaitersPerHost（默认4096），不是Realtime Sender32；本批增加的4 batch/2 peer约束在其内，normal invoke不检查batch专用gate。TCP46/schema未改，Loader继续复用r78。

r93 `/tmp/imv2-actor-realtime-10k-1000-r93/candidate` 根会话9244实际终态1，在约20秒触发两个Loader的真实workload失败门槛，runner取消其余Loader并停止全部owned服务/PG。仅report0/1存在且phase completed=false，分别2/3个message:TCP_DEFERRED_RETRY_EXHAUSTED、23/25次SERVER_BUSY；message max latency15231.71/15225.95毫秒。其余取消部分不能拼成完整质量结果、吞吐或capacity证明；不是crash或holdSeconds到期。

仅四个完整消息阶段样本(+3.010/+8.121/+13.217/+18.323秒，基线早2.092秒)：Registry每GW实际task峰2，queued全0；+8/+13秒仅GW0/1各一个授权批等待，占2/3 scopes，最老authorization5.717→10.814秒，+18秒已归0。数据库准入queueFull/timeout增量各0，物理loan及owner写队列样本0；room reservation总10/4/4/1，远低128上限；PG仅0–1采样阻塞backend，恢复头actual held最大各GW约42–59毫秒。唯一TCP拒绝来源connection_count23/25，所有internal room failure枚举为0，bytes拒绝0。因此不支持把本轮失败称为整体collector/数据库预算饱和。点采样和两份部分报告没有逐操作因果trace。

发现确定的Host跨await缺陷：finishReservation在await lane真实完成/释放旧budget之后，无条件清entry.heldReservation和reservationDispatched；新grant可在旧continuation恢复前已取得同一lane，旧完成会擦掉它，使新grant无法正常finish、lane留到watchdog。修正只在同entry且heldReservation仍等于exact旧grant时清理，同时defer与abort字段清理保持exact CAS。

r94 `/tmp/imv2rt-7o99fjew/reservation-cas-counterfactual-r94.log` 根会话97591实际终态0，内部counterfactual swift test实际exit1：仅临时把修正后清理条件退成旧if finished逻辑；受控observer暂停在真实lane.finish和旧permit释放之后，真实successor reserve+dispatch完成再恢复旧continuation。构建89.39秒成功，测试0.216秒实际失败三个断言：successor.finish=false、真实budget非0、invalidation未执行两次。它证明该精确调度下旧逻辑的错误，不证明r93每个失败均为此路径。

r94 finally已恢复固定源码并与保存副本cmp一致。r95 `/tmp/imv2rt-7o99fjew/reservation-cas-fixed-r95.log` 根会话24323实际终态0，增量8.61秒，同一反例及原batch cancel/qualificationLost两参数共2函数3案例0.066秒通过。未重复无关PG/网络测试；r96含CAS修正的Server Release实际终态0（174.28秒），Account Release实际终态0（9.04秒）。Loader未变，继续复用r78构建。r97先运行1万连接/1000档，尚未证明现场长尾已消除，不进入5000档。

### r97 小规格通过与后继结算窗口

`/tmp/imv2-actor-realtime-10k-1000-r97/candidate` 根会话19566实际终态0，12/12报告齐全：10000认证/峰值在线，29988发送及ACK，998.989 ACK/s；workloadFailed、heartbeatMissed、overflow、abandoned均0。完整30.008秒共同窗口、drain、quality及coverage均通过；最终10000 foreground viewers缺失/落后/超前均0。live gap帧6252、metadata gap21431仍存在，不将最终收敛表述为无中途缺口。

独立地址SQL与Receptionist两份proof通过：共同阶段1790960348.878–0378.886，6个完整6GW采样覆盖0352.094–0377.752，publish settled增量25376；route_lookup/realtime_owner_snapshot实际SQL增量及active为0。foreground实际lookup、miss、invalidation增量0，background lookup1050。关闭前384scope/192room采样落后0，两次读取均在全部Loader存活期间，客户端与数据库快照并非原子。以上均不修改result.json或历史质量。

共同消息阶段各GW逐点取max（不将oldest gauge跨节点求和）：room实际任务每节点最多4，authorization scope最多3/单节点oldest最多133.689ms，真实queued数量及oldest均0；desired/awaiting-retention单节点最多59/53，oldest仍有16.075秒，不能称所有恢复尾延迟消失。inline实际最多1/oldest0.685ms。以上为采样观测，缺少阶段首尾短窗口，不能排除未采集的峰值。

并行只读复核另确认旧finishing标记的邻接缺口：lane实际完成并授予后继后，旧Host continuation尚未defer清标记；旧`finishingReservation == nil`使后继首次finish失败。原反例手动第二次finish掩盖生产只调用一次的边界。r97结束后最小修正为只拒绝同grant重复finish（`finishingReservation != grant`）；新grant取得真实lane能力证明旧SQL/失效已经完成，保留旧held/finishing的exact CAS。强化同一个反例：后继首次finish成功，再授予第三grant，旧continuation恢复不清第三grant；同grant重复拒绝仍验证。r98定向验证进行中，尚未进入正式容量复验。

r98 `/tmp/imv2rt-7o99fjew/reservation-successor-r98.log` 根会话43561实际终态0：Debug构建87.62秒，3函数4案例0.067秒通过，包括强化后继首次结算反例、同grant重复finish不双失效、实际batch取消与qualificationLost排空。r99 Server Release实际终态0（168.46秒）。并行只读审计未发现新transport确定缺陷；Gateway实际Ready/strict-head写入许可缺少原viewer授权截止的再次检查，源码窄修进行中。正式容量尚未运行，不将r97视作新Gateway边界修正后的证据。

r100房间Ready/strict-head授权期限窄修已冻结。捕获原authorityValidatedAt+30s，实际enqueue的代次围栏锁内再次检查；跨await过期抛现有receiverQueue，保留恢复需求并回真实授权collector。account及未配置barrier测试装配不增加房间权限期限。内部测试seam仅可注册前缩短窗口≤30s，不开放生产配置或延长权限。`/tmp/imv2rt-7o99fjew/authorization-enqueue-r100.log` 根会话35163实际终态0：Debug构建78.06秒，4函数5案例1.074秒通过。新增实际writer门控跨100ms窗口，旧Ready许可拒绝、授权读至少2次、实际成功Ready仅1次；既有pair合批、room/presence慢writer隔离、inline实际drain均通过。r101最终Release生成中，后续直接原50k/1000，未重复无关检查。

r101最终Server Release实际终态0（165.49秒）、Account Release实际终态0（9.20秒）；Loader源码不变复用r78。r102 `/tmp/imv2-actor-realtime-50k-1000-r102/candidate` 按原50k fixture、180秒checkpoint+90秒消息、原资源/超时/队列质量运行，日志`/tmp/imv2rt-7o99fjew/50k-1000-r102.log`。运行期间源码冻结；结果未产生前不声明正式通过，不进入5000档。

### r102 正式规格在读取前门再次失败

根会话48969实际终态1，服务/Loader/独占PG已退出；全部50000连接实际预热并释放共同barrier，180秒checkpoint完成，但rate-1000约40.016秒触发workload guard，仅report4/5两份齐备。两份phase失败4/5、最初guard分别4/3666与5/3666；最终542失败包含532个关闭后的TCP_OUTCOME_UNKNOWN_CONNECTION_CLOSED，不可当作542个阶段根因。最终剩余code为3个TCP_DEFERRED_RETRY_EXHAUSTED、7个TCP_OUTCOME_UNKNOWN_UNRESOLVED，phase/close边界可能另含1个。两份phase最大消息延迟19.187/17.555秒，pull最大13.597/12.501秒，SERVER_BUSY26/28。部分ACK6124/聚合147.366每秒仅覆盖两片且不是完整共同窗口，不代表全局吞吐。

只读Gateway审计`/tmp/imv2-r102-registry-audit.json`：8个完整6GW消息阶段采样覆盖+1.615–39.754秒，基线早3.607秒、末缺0.262秒。+6.94秒起各GW原4实际恢复worker持续满，末点actual_scopes每GW279–464（四worker合计，单worker仍≤128）；末点room desired8219–8326，recheck6858–6956。queued单节点oldest最大38.386秒，authorization单节点oldest最大28.272秒，不对gauge求和。interest_activation为0，socket retention/coverage偶发毫秒级；因此无证据把此现场归因为慢socket。interactive_read在+6.94秒queued180–252，之后所有GW触384上限，窗口queue_full增量33600/timeout5141，foreground_write queued几乎0。

Registry为每attempt建立一次原绝对deadline，Directory跨Host不重置；失败重试取得新attempt截止但保留需求createdAt。因此38秒是恢复责任年龄，28秒是整个RPC/Hostlane/读取准入/真实结算等待，不能说SQL单次执行28秒。物理loan observed完成room_recovery379/平均held45.34ms，group_event_pull12123/平均held99.11ms（带首尾边界缺口），进一步要求定位物理借用上游等待。源码和本轮PG/transport审计继续进行；不盲跑第二轮、不进入5000档。

### r103–r104 纯state快照read pin与共享围栏

r102另两份只读摘要：`candidate/offline-actor-transport-r102-summary.json`、`/tmp/imv2-actor-realtime-50k-1000-r102/offline-host-batch-storage-summary.json`。共同阶段资格持续有效，Host probe/failed qualification tick增量0；phase之后self-down日志不能作为阶段原因。Directory单节点pending峰15、reservation单节点峰85，未触既有128限制。PG最大观测语句年龄216.6ms、blocked峰6/fan-in峰2，不支持把20秒授权阶段都解释成quota行锁。EventLoop均值4.54–5.32ms、观测SQL settled→resume最大137ms也不足以解释整段长尾。两份room_recovery完成计数使用不同采样窗口：raw held_duration_count六GW在-3.607/+1.615/+39.754秒合计40350/40626/40729，含阶段前baseline增量379，严格阶段内两端增量103；不能将差异归于不同业务scope或混用均值。

源码确认Host先逐room持独占reservation再等待其它room与共享interactiveRead；普通log读取也先持命令lane再等读取前门。纯state结束还调用write hint失效。这些是已确认的结构放大条件；采样不证明永久循环死锁。现纯state cohort改为同步exact ready Entry/token/qualification/safe的生命周期read pin，最多4实际batch，每room只pin一次；取消、退休与停机一直持有至实际callback结束，结果再核对exact身份、原deadline与ready资格。该路径不占命令reservation、不失效write hints。只读unknown返回unknown而不无条件退役健康写executor，写事务certainty语义不变。

专用SQL围栏按room排序取得rooms FOR SHARE，再按同顺序取得leases FOR SHARE，全部lease锁消耗后读取新鲜DB clock；保留完整owner/epoch/Host/incarnation/token和逐viewer正文快照授权。写fence不变。授权state是DB snapshot，不承诺未COMMIT queued command可见，已ACK事实可见；合同与方案同步修订，shared locks仍与写/续期冲突。interactiveRead原3为保障份额，可借其它空闲前台份额，未改成硬3或另设新池；公平purpose准入暂未叠加，以便验证此结构修正本身。

r103 `/tmp/imv2rt-7o99fjew/snapshot-read-pin-r103.log` 根会话30228实际终态0：Debug85.79秒；Server4函数（permit/deadline/timer/budget两参数）0.076秒，Runtime2函数3案例0.082秒，通过真实4callback上限/第5拒绝、held write不阻pure read、取消/失格实际pin drain及cached grouped RPC。r104显式disposable数据库`imv2_snapshot_r104`，根会话27712实际终态0，日志`/tmp/imv2rt-7o99fjew/pg-snapshot-r104-tests.log`：2函数3案例1.279秒，actual读读共存、读锁阻owner/expiry写、锁等待后过期拒绝与多viewer/坏token隔离通过；仍1readBody/3fence/2control计数。数据库已drop，专用PG已实际停止。r105 Release生成中；新实现尚无运行容量证据，继续小规格→原正式门槛。

### r105–r107 新快照路径小规格通过，正式规格完成但未通过

r105 Server Release实际终态0（168.93秒）、Account Release实际终态0（8.91秒），boundary检查通过0 migration exceptions；Loader不变复用r78。r106 `/tmp/imv2-actor-realtime-10k-1000-r106/candidate` 根会话7471实际终态0，12报告齐备：10000认证/峰值、29988发送/ACK、999.542 ACK/s，失败/丢心跳/overflow/abandoned均0，quality及coverage通过；10000最终viewer缺失/落后/超前均0。关闭前384scope/192room采样落后0，全部Loader两次读取均存活，快照非原子。live gap5504/metadata gap20080仍存在，不当作全程无缺口。

两份独立hotpath proof通过：共同消息阶段1790963399.068–3429.069，6完整6GW采样覆盖3402.183–3427.779，publish实际settled增量27197，指定两类地址SQL增量/active0；foreground Receptionist、miss、invalidation增量0，background lookup1050。未修改质量或历史结果。r107同一源码/Release按原50k fixture、180秒checkpoint+90秒消息、原资源预算继续运行，日志`/tmp/imv2rt-7o99fjew/50k-1000-r107.log`、输出`/tmp/imv2-actor-realtime-50k-1000-r107/candidate`；运行期间源码冻结。正式门槛尚未通过，不进入5000。


### r107 完整正式窗口仍暴露读取前门争用

根会话93871实际终态1，12份完整报告、50,000峰值连接及原180秒checkpoint/90秒message窗口均完成；89988发送、89961最终ACK，完整phase ACK/s916.194，workloadFailed31（19 deferred retry exhausted、8 outcome unknown、4 room subscribe unavailable），心跳miss/queue overflow/abandoned0。最终50000 viewer中missing4、behind1867、ahead0，quality和coverage失败。发送窗口内ACK82459，其余在排空阶段完成；不能用最终ACK冒充窗口吞吐。仍禁止进入5000。

实际关闭前384scope/192room见证中82scope已落后，384连接均active、12Loader采集前后存活，因此最终缺口不能全部归为关闭副作用；客户端与DB是分别读取，非原子快照。见`candidate/preclose-recovery-witness.json`。两独立hotpath证明仍通过：共同阶段1790964001.910–4091.911，16完整6GW样本覆盖4005.076–4087.525，publish实际settled增量50642，两指定地址SQL增量/active0，foreground Receptionist/miss/invalidation0，background3318；只证明这些边界，不替代质量门槛。

只读`/tmp/imv2-r107-registry-audit.json`和`/tmp/imv2-actor-realtime-50k-1000-r107/offline-read-pin-storage-summary.json`：原独占reservation各节点峰0（r102为52–85）；但interactiveRead各节点排队仍触384，授权oldest单节点峰29.94秒、恢复queued oldest单节点峰84.15秒。Registry原4实际任务持续满，socket coverage峰2.63ms、inline oldest峰3.11ms，没有此窗口socket HOL正证据。12完整phase拉取190260、retryable rejection161398；PG采样blocked峰7，最大观测语句年龄223.8ms、每waiter直接blocker最多1，不能把几十秒复核年龄当成数据库锁等待。

两只读摘要的SQL均值使用不同端点窗口：Registry含阶段前baseline的窗口roomRecovery354/90.38ms、groupPull23091/96.11ms；Storage严格inside两个端点间roomRecovery233/106.29ms、groupPull21714/98.56ms。不可混用样本数或做均值相减归因。观察到的控制器排队均值4.607秒及近满队列，结合相同FIFO调用链，支持必要授权被大量日志拉取挤压的结构判断；顺序Host cohort累计等待是解释模型，尚无逐请求全链时序证明。

进程资源共同phase内82.254秒采样：6Gateway合计5.432 CPU core、末RSS合计10072MiB，12Loader合计0.238 core、RSS2702MiB；这是采样平均，不证明单线程没有饱和。下一修正是在原interactiveRead并发/384排队和原前台借用规则内增加授权/普通读取公平准入与目的观测，不扩池、不延长原30秒权限期限；需定向验证后沿小规格→正式1000门槛推进。


### r108–r110 原预算内读取公平与控制故障检验

必要覆盖授权仅在已验证Host实际states cohort处显式分类；两purpose内部FIFO共享原前台read actual/借用额度，双方积压时1:1。生产按URL/schema物理资源去重×query batcher同一默认actual4计算预留，cap至总等待-1；正式单物理资源普通最多380、授权可进入剩余4、总等待384不变。普通补位只检查ordinary自身上限加总上限，已queued授权不会重复扣预留。分类不进TCP/Actor wire，不改变service dual role、逐viewer/fulltoken/资格或原deadline；helper在actual SQL callback真正结束后按exact purpose释放。按purpose固定标签新增实际等待/拒绝/在途观测，与原aggregate同一工作分区。两代理静态审查及root边界检查通过（0 migration exceptions）；禁止在正式运行期编辑源码。

r108根会话44463，Debug82.30秒。日志`/tmp/imv2rt-7o99fjew/fair-read-r108-tests.log`：Server21tests/4suites（原Admission、HostAdmission、RoomRecovery lifecycle、指标renderer）0.474秒全部通过，新增两公平函数包含两个授权与两个普通积压的实际alternation、FIFO补位、总预算、取消、原deadline、实际callbacksettle后释放及purpose aggregate；App物理别名/小队列composition检查通过。初版outage test30.724秒失败4asserts：首次snapshot的session被约20秒初始qualification期限截断，夹具没有production正常Actor订阅续期，导致late publish无订阅者；没有据此改租约TTL或产品实现。

r109仅测试修正为存储失败后按原5秒周期通过真实签名control续订同session/revision=1，受原databaseDeadline限制，store claim/renew仍持续失败、cleanup仅恢复release。根会话58073实际终态0，日志`/tmp/imv2rt-7o99fjew/control-outage-r109-tests.log`，增量Debug5.03秒、唯一actualPG+真实双Cluster test30.597秒通过：初claim真实PG，期限前两次cache publication及actual callback、PG行expiry不变、后继安装不超过原databaseDeadline，到期client/Service拒绝、actual transport/controller drain及租约清理。故障注入为测试依赖wrapper，不声称实际断PG网络或替代业务写权限矩阵。显式disposable DB已drop，root专用PG57517已实际停止。

r110 Server Release生成中（根会话70182），随后复用未变Loader、构建Account所需下游产物。fairness尚未获得容量结果，继续原资源/质量条件小规格→正式50k/1000，不进入5000。


r110两Release实际终态0：Server176.51秒、Account10.30秒（原jobs10/Release参数），Loader源码未变复用r78。r111根会话33745新小规格10k/1000运行中，沿用r106的同一fixture/scenario hash及原资源/质量/关闭前见证，日志`/tmp/imv2rt-7o99fjew/10k-1000-r111.log`，输出`/tmp/imv2-actor-realtime-10k-1000-r111/candidate`；结果尚未产生，源码冻结。


### r111 小规格完整通过，r112 原正式规格复验

r111根会话33745实际终态0，`/tmp/imv2-actor-realtime-10k-1000-r111/candidate`12报告齐备，10000认证/峰值、29988发送及ACK，999.552 ACK/s，workload failure/heartbeatmiss/overflow/abandoned0、quality与coverage通过，10000最终前台viewer missing/behind/ahead0。关闭前384scope/192room落后0，12Loader采集前后存活，客户端/DB非原子读取。live gap5364、metadata gap20319仍存在，不声称全程无缺口或把补拉当实时推送。

两独立hotpath证明通过：共同phase1790965601.754–5631.755，6完整6GW样本覆盖5604.961–5630.507，publish实际settled增量27337，route_lookup/realtime_owner_snapshot实际SQL增量/active0，foreground Receptionist/miss/invalidation0、background1050；未改质量或历史结果。

r112根会话43219按相同r110 Release、原50k fixture/180秒checkpoint+90秒消息/原资源和质量运行，日志`/tmp/imv2rt-7o99fjew/50k-1000-r112.log`，输出`/tmp/imv2-actor-realtime-50k-1000-r112/candidate`。正式结果尚未产生，生产与测试源码冻结、不得进入5000。原完整5000及baseline≥80%和全故障/资源矩阵仍未验收。


### r112 公平生效，但完成排空失败，不能当正式验收

根会话43219实际终态1，runner报告Loader非零并取消其余未报告分片。只有9/12报告，缺0/1/5；已有9份rate-1000均90秒完成，实际terminalError为scenario completion drain timeout，queued0但各自尚有1–7 inFlight。最早可见phase workload失败在load4 second46，不能把关停后的connection_closed并入最初原因。9份报告phase failed21、最终failed98含18 closed，其余三份缺失；不合成全50k吞吐/完整质量通过。独立最终部分proof只覆盖37499viewer，missing4/behind2366，失败；关闭前384scope/192room有85scope落后、全部连接active且12Loader前后存活（非原子），因此不是纯关闭假缺口。所有本轮owned进程/PG已实际退出，禁止5000。

严格17完整6GW phase样本两端1790966175.581446–6263.888077、88.306631秒：critical admission2465、queuewait完成2454均39.49ms，queueFull/timeout0；ordinary admission19255、queueFull155299/timeout19827、排队峰380。roomRecovery实际loan2453均held113.43ms，physical gate2461均65.09ms、SDK等待2459均0.148ms，PG观测blocked峰7/max语句年龄347.4ms；SQL不同阶段均值不是cohort墙时、不可相减。授权实际准入已显著增加，不能继续把20–30秒authorization年龄归因于当前critical SQL FIFO或连接池。Registry authorization单节点oldest峰29.923秒，四actualworker各GW持续满，socket阶段观测最大约50ms、interest阶段1.14ms。

摘要`/tmp/imv2-r112-registry-audit.json`另有phase前4.478秒baseline窗口critical2731，不能混用严格窗口2465。`/tmp/imv2-r112-strict-window-metrics.json`、`/tmp/imv2-actor-realtime-50k-1000-r112/offline-storage-purpose-summary.json`区分这些端点。现确切源码竞争点为HostQueryBatcher state与scalar共享actual4（可能在purpose acquire前busy），以及Directory cold列表逐room resolve完整后才顺序调用Host；当前没有逐段动态观测证明哪处主导，下一步补固定目的actual/拒绝和Directory分段观测，不能盲改预算或假装已有定量根因。

机制完成审计只读实际历史日志与当前源：`/tmp/imv2-actor-realtime-mechanism-audit-r112.md`、`/tmp/imv2-plan-11-app-evidence-audit-r112.md`、`/tmp/imv2-r112-static-delivery-scope-audit.md`。已有签名引用/控制/压力/actualdrain/字节/NIO nonwritable、真实PG围栏、App GRDB未知结果和多端证据不机械重跑；组合跨层单fixture及Linux/soak为外推限制，未另造硬门槛。当前单GWlocalOnly部署已在计划资格约束中明确允许，不是旧SQL/NATS兼容后端。精确当前模块清单r113 root检查实际终态0，boundary0 migrationexceptions及依赖audit无forbidden/SCC；仍不能替代容量门槛。


### r114 恢复分段观测接入并通过定向验证

Directory 4固定阶段、Transport调用者会话等待/actual dispatch、Host states_cohort/scalar实际槽位与准入前busy已接入现有Prometheus来源。物理归属去重聚合，未接入保留nil；不新增SQL/后台Task/容量，不改变原调度。调用者取消不提前结算实际解析、dispatch或Host batch，阶段重叠不可相加，已完成均值不可冒充在途年龄，max为进程生命周期高水位。说明见operations/observability。

Root会话83043实际终态0，`/tmp/imv2rt-7o99fjew/recovery-observation-r114-tests.log`：构建90.86秒，5测试跨4 suites全通过（Host实际held/取消及准入前busy、Directory warm物理分组/cold取消后sharedresolver仍占用、真实双节点签名batch取消后actual gate保留、HTTP指标输出及nil省略）。不重跑无关故障矩阵。Root边界/依赖audit实际终态0，662 sources、0 forbidden、0跨target SCC、0 migration exceptions，输出`/tmp/imv2rt-7o99fjew/module-audit-r114.json`。观测验证不是容量验收，原正式1000仍以r112失败为最新证据，尚不得进入5000。


### r115 Release 构建完成，r116 小规格复验启动

Root serial jobs10：Server Release会话90369终态0/180.19秒，Account Release会话82457终态0/10.48秒，日志分别`/tmp/imv2rt-7o99fjew/server-release-r115.log`、`account-release-r115.log`。观测版本小规格10k/1000沿用原fixture、scenario、预算、质量与preclose witness；输出`/tmp/imv2-actor-realtime-10k-1000-r116/candidate`，日志`/tmp/imv2rt-7o99fjew/10k-1000-r116.log`，尚无终态，不作通过声明。


### r116 小规格终态通过，r117 原正式1000复验启动

r116 root会话29339实际终态0；12/12 report、10000认证/peak，29988发送=ACK、999.334 ACK/s，失败/workloadFail/heartbeatMiss/queueOverflow/abandoned均0，quality/coverage/steady/drain通过，10000前台最终missing/behind/ahead均0。存在livegap5640/metadataGap20694，不能称所有时刻无缺口。热路径两独立proof实际终态0：6完整6GW样本窗口1790967866.607391–7892.182042、settled publication差分27674；route_lookup/realtime_owner_snapshot实际SQL差分与active为0，前台Receptionist/miss/invalidation为0，后台发现1050。

r117沿用r115 Release原50k fixture、180秒checkpoint+90秒消息和同一预算/质量/preclose，输出`/tmp/imv2-actor-realtime-50k-1000-r117/candidate`，日志`/tmp/imv2rt-7o99fjew/50k-1000-r117.log`。当前尚未终态，不作正式通过或5000准入声明；运行期源码冻结。


### r117 running observation: scalar contention remains unproven

Read-only source review matches r116 instrumentation: Registry states(keys:deadline:onSettled:) -> Directory.recoveryStates -> Host invokeRecoveryBatch -> Factory recovery.states records states_cohort. Automatic hint roomLog pulls do not enter scalar recovery batching. Root checked the actual r117 temporary scenario: checkpoint180/rate90, send1000/sync100/reconnect0.05%, no explicit state/latest-visible batch rates. r116 strict six-sample window: scalar start/complete/busy deltas and active peak all zero; states_cohort started delta4435/completed4440 (baseline already held work), busy delta0, oldest node peak35.78ms. r117 preparation samples also show scalar started0 on all six nodes. Shared actual4 remains a potential risk for other workloads, not established contention in this workload. Offline diagnostic /tmp/imv2rt-7o99fjew/recovery-segment-summary.py rejects missing metrics and counter resets; partial reports are explicitly marked and never establish formal quality. r117 remains live; no completion claim.


### r117 terminal failure and segmented cause evidence

Root session79498 terminal1. All50000 warm/12 ready, but loader10 tripped message failure guard7/6416 about70s into rate-1000; runner cancelled remaining loaders. Only report10 exists; rate phase incomplete. Its phase workload failures7 and SERVER_REJECTED_SERVER_BUSY58 are pre-cancellation observations. Whole-run653 failures include645 connection_closed after cancellation and are not the initial failure count. No capacity/steady-state/hotpath formal PASS claim. Root ps verified all owned Gateway/Account/Loader exited.

Diagnostic window derived explicitly from this incomplete report: rate timestamps1790968426.110-8496.120;13 complete6GW samples strictly inside8426.384211-8492.870411 (66.4862s), not the whole phase. Offline summary in candidate/offline-recovery-segment-summary.json; storage audit /tmp/imv2-actor-realtime-50k-1000-r117/offline-storage-purpose-summary.json. Cold caller1235 completed, mean706.99ms/sum873138.57ms/node active peak4; shared actual resolution4534 completed/736.15ms (includes ordinary callers, cannot equate to cold items); Host caller2266 completed/227.73ms; dispatch2225/228.82ms; session mean0.0034ms; callback2.19ms; authorization oldest28.27s. Cold sequential collect-before-dispatch is established source structure, cumulative intervals may overlap and do not establish the cold depth of every long batch or recoverable throughput.

Host scalar all zero; cohort busyBeforeAcquire0/actual batch mean220.79ms. Critical SQL admission2053, completed wait2020/37.33ms, full/timeout0. Ordinary admission14748 but timeout14216/full126226/queue node peak380. Ordinary pull handler14735 completed mean5782ms vs actual loan14730 mean99.43ms; roomRecovery loan2051 mean118.92ms. PG12 corresponding samples blocked peak9/max statementAge267.7ms, not a20s SQL lock chain. Room command outstanding sample growth12974 and send owner queues persist. gateway_message_send connection_count rejection delta422 with no other budget/internal failure growth: ByteStream pre-handler actual messageSendTasks slots are full, matching phase SERVER_BUSY class without claiming per-request correlation.

Next implementation authorized within goal: Directory bounded Pending completion observers settle ready cold groups promptly; pure roomLog.pull lifecycle read pins avoid exclusive command lane while queued for normal SQL, retaining original bounded count/bytes, exact token/lifecycle/deadline, full SQL viewer authorization and shared read fence. Subscribe/mutations, resource budgets, idle TTL and failure reference classification remain outside this specific fix. Three agents edit distinct Directory, Host/Factory, ServerFactory/SQL files; root exclusively runs serial validation after freeze. Formal1000 remains failed, original5000/fullbaseline gate remains unverified.


### r118 bounded cold pipeline and pure pull snapshot targeted verification

Three agents froze distinct implementation files. Directory reuses Pending budget and exact generations, a bounded per-batch completion mailbox and one original deadline timer, no per-room caller Task/unbounded stream; ready cold rooms are grouped by host/owner and settled promptly. Host pure roomLog.pull borrows the original CommandBudget count/bytes and retains exact lifecycle until actual callback/budget release. Committed replies post-check lifecycle/qualification/deadline/cancel; unknown/rollback retain original certainty. The production factory uses original ordinary read admission and full shared PostgreSQL fence/member/history authorization; subscribe and mutations retain prior paths.

Root initial build session93596 exit1 for one new test using stop DrainResult as Bool; fixed completed field. Repair1 session65035 exit1 for ServerFactory calling Infrastructure internal withSelectedDeadline; root switched the single-call path to existing package withDeadline, preserving min inherited/original deadline rather than widening API. Neither failed build executed test assertions.

Repair2 root session3795 terminal0; /tmp/imv2rt-7o99fjew/read-pipeline-r118-tests-repair2.log build56.66s, 6 test functions/8 parameter cases across4 suites PASS: actual held write reservation vs independent bounded pure reads, cancel and unknown actual retention, post-qualification rejection and drain; warm/completion-ready multi-viewer callbacks before slow cold gate and successor generation/cancel cleanup; true PostgreSQL pure pull coexisting with held shared fence, member denial/stale token/actual expired lease; prior multi-viewer SQL isolation and shared fence write/expiry cases. Disposable dual databases imv2_r118_primary/secondary on root-ownedPG57517 were truly created and used; both dropped and PG stopped, all cleanup actual terminal0. No external/user database touched.

Root boundary/dependency/diff checks passed, /tmp/imv2rt-7o99fjew/module-audit-r118.json 662 sources/0 forbidden/0 cross-target SCC/0 migration exceptions. r119 Server Release build started, log /tmp/imv2rt-7o99fjew/server-release-r119.log; no completion claim yet. Formal1000 latest authoritative outcome remains failed r117; original5000/baseline gate remains pending.


### r119 Release complete; r120 small diagnostic started

Root serial builds actual terminal0: Server session85764/180.37s, Account session98866/9.16s. Logs /tmp/imv2rt-7o99fjew/server-release-r119.log and account-release-r119.log. No changes to build flags, Loader, resource budgets or benchmark guards. r120 reuses original10k fixture/scenario/TCP entry/preclose witness, output /tmp/imv2-actor-realtime-10k-1000-r120/candidate, log /tmp/imv2rt-7o99fjew/10k-1000-r120.log. Still live, no PASS claim. All source frozen until terminal.


### r120 small PASS; r121 formal1000 rerun live

r120 root8226 terminal0,12/12 reports:10000 authenticated/peak,29988 sent=ACK,999.4355 ACK/s, failed/workload/heartbeatMiss/overflow/abandoned0; quality/coverage/steady/drain passed,10000 final viewers missing/behind/ahead0. Live gap5184/metadata gap21852 remain; not an every-instant gap-free claim. Two independent hotpath proofs terminal0:6 complete6GW samples1790969888.992852-9914.632468,publication settled delta28430; route_lookup/realtime_owner_snapshot SQL deltas/active0,foreground Receptionist/miss/invalidation0,background discovery1050.

r121 reuses r119 binaries, original50k fixture and180s checkpoint+90s messages, original budgets/quality/preclose witness. Output /tmp/imv2-actor-realtime-50k-1000-r121/candidate, log /tmp/imv2rt-7o99fjew/50k-1000-r121.log. Currently live; no formal PASS/5000 admission claim. Source frozen until terminal.


### Resource evidence and r121 verified wait

Root read r117 host/process resource records without rerunning anything. Eleven CPU intervals fully inside the diagnostic six-node window cover1790968431.640783-8492.671554: host CPU busy arithmetic mean61.31%/max64.61% across14 CPUs; pressure level stays1; swap usage919.56MiB unchanged, vm Swapins/Swapouts deltas0 (Pageouts60). Sampled total Gateway RSS peak9624.39MiB, Loader2972.61MiB (separate maxima, not an atomic whole-host RSS); PostgreSQL/other apps excluded. Aggregate headroom does not rule out single-core/event-loop/actor/queue bottlenecks. Artifact candidate/offline-resource-summary.json is diagnostic, not formal capacity proof.

r121 root59808 remains live.12/12 loaders now ready/all50000 warm; original180s checkpoint is in progress. Actual command workload-ramp-per-second16 with4167 connections per loader implies about260s minimum preparation for the largest loader; this waiting is imposed ramping, not a publish stall. No restart, source edit, quality change or5000 admission.

### r121 terminal failure: Sync admission, not initial message exhaustion

Root session59808 terminated with exit1. All50000 connections warmed and the original180s checkpoint completed, but loader1 triggered the unchanged0.1% workload guard at about30s of the90s rate phase. Only report-1.json exists and its phase is incomplete; the remaining loaders were cancelled. No full capacity, drain or hotpath PASS is claimed, and5000 remains gated on formal1000 PASS.

The guard denominator is2499 message attempts plus249 Sync pulls. Its4 failures are Sync SERVER_BUSY, despite the hard-coded message-workload wording. Whole-report failure counters contain7 retryable Sync SERVER_BUSY and434 message connection-closed outcomes from subsequent cancellation; the latter do not identify the initial failure. Phase message events contain1931 accepted and2 retryable SERVER_BUSY, without message deferred-retry exhaustion. The first Sync failures appear in loader1 at seconds28-29; stdout/stderr buffering must not be used to relocate them to an earlier printed line.

Five complete six-Gateway samples end at phase approximately26.18s, before those failures. Their22.797s window shows1886 Sync admissions, all six nodes at their original3 in-flight slots, aggregate queued growth334 and mean admission wait1326ms. Completed physical Sync loans average119.98ms including transaction activity; physical gate wait averages80.51ms. The sampled timeout/full counters are zero only in this earlier window; missing later bodies are not zero. The evidence supports growing admission backlog reaching the original5s wait budget, but does not directly distinguish timeout from queue-full for the terminal rejections. Artifacts: candidate/offline-recovery-segment-summary.json and /tmp/imv2-actor-realtime-50k-1000-r121/offline-storage-purpose-summary.json.

Source review closes SERVER_BUSY to Gateway acquire(.sync).rejected. Sync uses V2RoutedSyncStore and the authoritative user-shard route fence, not RoomTransport, RoomLane or a UserShardActor. Co-located storage reuses the fenced transaction handle. A normal nil-token pull contains one route SELECT plus five owner statements; a supplied token adds its validation statement. SQL metrics aggregate these statements and do not identify an individual slow query. Loader currently records retryable Sync errors immediately and has no same-action retry; production Sync propagates SERVER_BUSY to the background connection failure path. Neither behavior justifies relaxing the guard.

Next limited implementation is a correctness-preserving Sync SQL reduction. Review also identified a potential existing READ COMMITTED snapshot race when advisory-lock acquisition and revocation lookup share a statement: a waiter can retain a snapshot from before cleaner commits its tombstone. Separate lock acquisition from the subsequent authority snapshot, then consider combining cursor initialization/locked retrieval and retention metadata without a no-op UPSERT or fabricated zero-row defaults. This source finding requires a deterministic real-PostgreSQL concurrency test; it is not asserted as the measured r121 performance cause. Root remains the sole build/test/service owner, and no resource limit, quality gate, workload or benchmark baseline changes are authorized by this diagnosis.

### r122 Sync cursor authority and bounded SQL reduction: real PG PASS

PostgresV2SyncStore now acquires the device advisory lock in a separate statement before establishing its authority snapshot. Pull metadata checks the tombstone, locks an existing cursor or obtains a new cursor through INSERT RETURNING, requires exactly one selected cursor, and obtains the ready cursor's retention row under FOR SHARE. Normal nil-token pull owner statements decrease from5 to4 (route-inclusive6 to5). Token validation and issuance, generation/receipt authority, snapshot staging and actual transaction completion remain present. Retention locking now precedes token validation for ready token-bearing pulls; dependency errors while awaiting that lock can therefore precede invalid-token validation. ACK/snapshot authority helpers also separate the advisory lock from the tombstone statement, adding an authority round trip there rather than preserving the unsafe snapshot.

This follows PostgreSQL's statement-snapshot rules and modifying-CTE RETURNING visibility: [transaction isolation](https://www.postgresql.org/docs/16/transaction-iso.html), [WITH statements](https://www.postgresql.org/docs/16/queries-with.html). The measured r121 backlog is independent evidence; this correctness fix is not claimed as its measured cause.

Root initial19458 terminal1 was a build-only test macro error around a throwing row decode; root separated the decode from #require, without changing production code. Repair1 session89621 terminal0: /tmp/imv2rt-7o99fjew/sync-authority-r122-tests-repair1.log, one test/three serialized cases passed in1.349s. A truly fresh disposable imv2_r122_primary database on root-ownedPG57517 installed the full schema. Tests observed pg_blocking_pids before releasing actual holders: actual cleaner COMMIT followed by deviceRevoked and no resurrected cursor; two first pulls followed by one cursor/two real receipts; retention UPDATE followed by resetPreparing generation2. The owned database was dropped and root PG stopped, both terminal0. This proves these database invariants, not performance capacity or arbitrary COMMIT failure injection.

Client same-connection Sync Busy recovery is separately implemented and under targeted r123 validation. Loader changes are pending; original Busy failures and offered-operation guard denominator must remain intact. No new capacity benchmark or5000 admission has occurred.

### r123 bounded same-connection Sync retry PASS; r124 Loader typecheck PASS

V2ProtobufSyncTransport retries only retryable SERVER_BUSY for an immutable pull or ACK envelope, with new request IDs and the existing interactiveRead2-attempt/10s policy basis. Its monotonic absolute deadline reaches TLS scheduler admission and the response timer; retryAfter is a floor and jitter does not renew the budget. Existing connection generation scope rejects replacement connections. V2SyncEngine retains its real store apply/receipt/acknowledgement sequence and unknown-response semantics. This local deadline does not prove remote SQL settlement.

Root r123 initial17816 and repair143509 were build-only new-test UInt32-to-UInt8 protocol-version errors in two fixtures; root corrected the explicit conversions. Repair2 session73420 terminal0, /tmp/imv2rt-7o99fjew/sync-busy-r123-tests-repair2.log: build22.87s, three functions/six cases in three suites passed0.642s. Actual GRDB plus adapter tests verify immutable Busy pull and ACK replay, one local application, successful server acknowledgement, and cancellation retaining the actual operation gate until the held wire returns. Adapter tests cover an unfulfillable server floor and replaced connection. Existing TLS peer tests exercise scoped response expiry and already-expired predispatch rejection with scheduler drain. These cases do not claim cross-machine transport-failure coverage.

Loader r124 debug build session89696 terminal0/build5.88s, /tmp/imv2rt-7o99fjew/sync-loader-r124-build.log. Loader retains every Busy workload failure and initial offered syncPullsSent in the existing guard denominator; extra wire/retry/logical-failure counters are distinct. Exact ACK values and dirty hints survive Busy. Final review requires retry latency to use the original logical action start rather than only the last wire attempt; that small field adjustment is pending the next Release typecheck. No guard threshold or workload arrival setting changed. Capacity remains unverified after these targeted checks.

### r125 production builds complete; r126 small diagnostic live

Loader now records the first logical action start and measures successful retry latency from that start, including backoff and earlier attempts. Root serial Release builds all terminal0: Server session91558/165.45s, Account10197/10.79s, Loader4451/17.00s. Logs /tmp/imv2rt-7o99fjew/server-release-r125.log, account-release-r125.log and loader-release-r125.log. Root source checks pass:662 sources, forbidden0/cross-target-SCC0/migration exceptions0; /tmp/imv2rt-7o99fjew/module-audit-r125.json. Read-only independent reviews found no blocking cursor-snapshot, connection-generation, deadline or actual-settlement issue. All production/test source is frozen for benchmark execution.

r126 root49952 is live, using the original scaled10k/1000 fixture/scenario, TCP workload, budgets, original failure guard and preclose witness. Output /tmp/imv2-actor-realtime-10k-1000-r126/candidate, log /tmp/imv2rt-7o99fjew/10k-1000-r126.log. No capacity PASS claim yet. Original formal50k/1000 remains failed r121; original5000 and the full baseline80% gate remain pending.

r126 initial49952 actually ended exit2 at the executable identity preflight, before output-directory creation or service startup: Loader's embedded algorithmSourceSHA256 still described the previous source. Root updated that literal using the runner's unchanged canonical normalization, current hash85cc9b30d69a6ad86878e8e39247eb5e5f22f49ee982935a1cb965b81947b1cb. This is not a capacity failure and the verifier was not relaxed. Loader-only Release hash repair session96870 is live; the next benchmark must use its verified executable. The final candidate/reference capacity comparison must use the same updated common Loader artifact and original scenario/thresholds, not compare an old-Loader reference with a new-Loader candidate.

### r126 small PASS; r127 original formal1000 started

Hash repair96870 terminal0/15.15s. r126 rerun root87308 terminal0, all12 reports and all10000 negotiated TCP connections.29988 sent=ACK,997.8374 ACK/s; failures/workload/heartbeatMiss/overflow/abandoned0; quality, coverage, steady window and actual drain passed. Final10000 viewers missing/behind/ahead0. Live gap4812 and metadata gap22456 remain, so the proof is final convergence rather than gap-free live delivery.

Both scoped hotpath proof tools actually exit0. Six complete6GW samples1790972336.823921-2362.621634 show27608 settled publications, route_lookup/realtime_owner_snapshot SQL deltas and boundary-active0; foreground Receptionist/miss/invalidation0, background discovery1050. These scopes exclude business authority and durability SQL and are not formal capacity proof.

r127 root69270 is live: original50k fixture and formal1000 scenario, original180s checkpoint/90s sending, original limits, guard and preclose witness. Output /tmp/imv2-actor-realtime-50k-1000-r127/candidate; log /tmp/imv2rt-7o99fjew/50k-1000-r127.log. All source frozen. No formal PASS or5000 admission claimed; r121 is still the latest formal terminal failure until r127 actually finishes.

### r127 terminal failure: observed Sync admission timeout and physical FIFO contention

Root69270 actually terminated exit1; owned service/Loader processes are no longer live. All50000 connections warmed and the original180s checkpoint finished, but the original workload guard failed. Only5 incomplete reports exist (0,3,6,9,10); no full quality/drain/hotpath capacity proof is claimed. Reports' common phase is1790972884.066-2924.072, about40s, rather than the required90s.

Seven complete six-Gateway samples fully inside that common phase cover1790972884.802878-2918.517741 (33.7149s). Sync admissions increase2962 (87.85/s), queues grow0 to390, all six original3 logical slots sample full;2339 completed admission waits average1.4426s. Actual source.sync physical gate wait averages77.34ms,2950 completed loans hold connections106.02ms on average. The gate wait is42.2% of those two overlapping loan-lifecycle segments combined; it consumes logical Sync capacity before connection borrowing. Actual SQL count per loan is5.029, reflecting the route-inclusive reduction, not six owner statements. Loan-held metrics include actual driver borrowing, route transaction and COMMIT; they do not cover later reply construction. Artifact /tmp/imv2-actor-realtime-50k-1000-r127/offline-sync-resource-summary.json states missing reports and incomplete scope.

The strict seven-sample window ends before rejection and has timeout/full deltas0. The next batch is not a complete six-node in-phase sample: Gateway0-4 each completed its actual metrics response before phase end, while Gateway5 completed106ms after it. Those five in-phase bodies independently record Sync timeout additions7/0/10/14/5 (36 total) and queue-full0; they directly establish phase admission timeout, without claiming a complete six-node counter window. Later saved observed-sync-timeout-sample.json is outside the common phase and must not substitute for that boundary evidence.

Whole-report172 CLIENT_DEADLINE failures mostly describe teardown: four phase snapshots have syncLogicalFailures0, excluding their later137 deadline failures from those phases; across all reports at least171 deadlines are after their phase snapshots. Guard4/3666 in loader10 is Sync SERVER_BUSY, with no phase message terminal exhaustion; loader3 also contains one subscribe UNAVAILABLE. Five phase workload counters sum34. Guard catch freezes each incomplete phase before cursor snapshot and gradual connection closing; still-open connections can run retry/deadline timers during that cleanup. Whole3847 connection-closed outcomes and whole deferred-exhaustion counts must not be assigned to the initial failure without their own phase evidence. No deadline refresh or old-generation timer defect was found.

Source independently explains the observed contention: V2PhysicalDatabaseLoanGate has ordinary/activation/renewal classes, and Sync and room pulls both use ordinary FIFO. The original3 logical Sync permits are held while awaiting that shared physical gate. The common pool remains ordinary9 plus renewal2, total11; the separate logical admission does not reserve physical service. Source and timing support a structural contention fix, not a claim that fairness alone guarantees100/s. Next implementation introduces explicit trusted Sync purpose captured before the outer route's first actual borrow and fair Sync/general queue service inside the same pool. Total connections/queue/wait/deadlines, activation2, renewal2 and original logical limits remain unchanged. Whole syncControlDatabase cannot be reclassified because room recovery also uses it. No5000 run is admitted.

Read-only requirement audits revalidated existing TCP App unknown-ACK one-fact recovery and multi-device evidence and found two stale document states, now corrected: canonical schema68 and already-verified control/recovery separation. Byte limits are wired on both signed batch endpoints; direct64KiB request-overflow execution evidence is being added with the existing two-Cluster fixture, without creating a wider fault matrix. Legitimate state replies rarely approach256KiB, so malicious executor-response defense must be identified separately if tested.

### r128 physical Sync/general fairness: targeted actual ownership PASS

The existing physical gate now distinguishes Sync from general ordinary loans. Ordinary+Sync+activation share the original9 non-renewal slots, activation remains capped2, renewal retains2 and total remains11. No additional pool, queue, wait budget or hard-coded Sync3 cap was introduced; original logical admission remains authoritative. When both eligible family heads are waiting, grants alternate Sync/general with FIFO inside each class; idle capacity remains borrowable. New immediate requests cannot bypass eligible queued family work. Renewal and the selected family retain their existing arrival order rather than gaining a new renewal priority. Only actual grants switch the fairness turn; expiry/cancellation do not release submitted work or fabricate grants.

Package V2PhysicalDatabaseLoanScope is a trusted Swift-entry purpose, distinct from diagnostic source tags. RoutedSyncStore establishes it before the first outer route borrow; Balanced synchronously captures it before crossing EventLoop futures and maps only ordinary to Sync, leaving activation/renewal unchanged. Co-located owner work reuses the borrowed handle; scope exits before later general work. Shared syncControlDatabase is not globally reclassified. Physical metrics add the bounded fixed sync label; ordinary now describes the general class itself, not the non-renewal aggregate.

Root15567 terminal0; /tmp/imv2rt-7o99fjew/sync-physical-fairness-r128-tests.log build80.21s. Six functions/ten parameter cases across4 suites passed (five Server functions0.555s, one real two-Cluster bridge function0.047s). Controlled actual borrowed futures verify9 ordinary+2 renewal held, mixed FIFO alternation and no total growth; existing actual nested/cancel/deadline/shutdown fixtures add Sync. Real PostgreSQL on truly created disposable imv2_r128_primary records the same backend PID for route and nested owner work, exactly one Sync physical grant, then an ordinary grant after scope exit. This uses real transaction/connection borrowing with injected route/store behavior, not a full business-route correctness proof. Database drop and rootPG57517 stop both actually terminal0.

The real two-Cluster signed byte case first accepts a legal one-item long-shard request; the100-item request exceeds64KiB and is refused before caller actual dispatch/business execution. Bypassing the caller encoder with the generic larger signed limit produces a real authenticated endpoint oversized error, again without business entry. This proves both request boundaries; it does not claim normal state replies exercised the256KiB overflow branch.

r129 root12215 production Server Release is live. Source boundary/dependency checks pass663 sources, forbidden0/cross-target-SCC0/migration exceptions0; /tmp/imv2rt-7o99fjew/module-audit-r129.json. All source frozen for serial build and subsequent small/formal tests. r127 remains the latest formal1000 failure; no fairness capacity benefit,5000 admission or completed-goal claim is made.

### r129 production builds complete; r130 small diagnostic live

Root Server12215 terminal0/build169.88s and Account28000 terminal0/build10.65s; logs /tmp/imv2rt-7o99fjew/server-release-r129.log and account-release-r129.log. Loader source is unchanged from its verified canonical85cc9b30d69a6ad86878e8e39247eb5e5f22f49ee982935a1cb965b81947b1cb artifact, so no redundant rebuild was run. Original TCP contract, budgets and benchmark guards remain unchanged.

r130 root83134 is live with the original scaled10k/1000 fixture/scenario, preclose witness and current fair-loan binaries. Output /tmp/imv2-actor-realtime-10k-1000-r130/candidate; log /tmp/imv2rt-7o99fjew/10k-1000-r130.log. No PASS yet. Original formal1000 remains failed r127 until subsequent original-spec verification actually succeeds;5000/full common-Loader baseline80% remains gated.


### r130 small verification passed; r131 formal1000 running

r130 root83134 actually terminal0. All12 Loader reports/exit codes0,10000 authenticated TCP connections,29988 sent=ACK,999.49135 ACK/s, failures/workload/heartbeatMiss/overflow/abandoned0. Original small30.003s common sending window, coverage/quality/steady-state/actual drain passed. Final10000 viewers missing/behind/ahead0. Live gap frames5124/metadata gap observations22002 remain; this proves final convergence, not gap-free instantaneous delivery.

Both scoped independent proofs terminal0: six complete6GW samples inside commonphase1790973939.119–3969.122, actual publishSettled delta28679, route_lookup/realtime_owner_snapshot SQL deltas0 and boundaryactive0. Foreground Receptionist0, background1050, misses/invalidation0. Business/control SQL remains excluded from address-only claim.

r131 root24938 now running original50k/1000 scenario with original180s checkpoint/90s sending, same limits/guards/preclose witness and existing r129 production binaries/common r125 Loader. Output /tmp/imv2-actor-realtime-50k-1000-r131/candidate; log /tmp/imv2rt-7o99fjew/50k-1000-r131.log. No formal1000 PASS or5000 admission claimed. Source remains frozen.


### r131 formal1000 failed; Sync fairness observed, new send/read bottleneck

Root24938 actually terminal1. All50000 warm, original180s checkpoint completed, original guard failed at about60s of the90s messagephase. Only5 incomplete reports(0,6,7,8,11), other7 missing; owned Gateway/Account/Loader processes no longer live. No quality/drain/formal capacity PASS. PhaseworkloadFailed6/9/8/6/6; every availablephase has SynclogicalFailure0/retry0. Whole-report connection_closed/Syncfailures include subsequent cleanup and must not be attributed to initialguard. Messagephase retained counters include SERVER_BUSY and attempttimeouts; terminal failure map includes deferred retry exhaustion, but per-phase kind map is absent so exact first-operation attribution remains constrained.

Strict offline11complete6GW samples1790974722.679414–4778.603974(55.92456s), inside commonpartialphase1790974722.392–4782.392. /tmp/imv2-actor-realtime-50k-1000-r131/offline-sync-resource-summary.json. Syncadmissions5546=99.169/s, timeout/full/cancel0; actual5531heldloans mean116.61ms/gate18.887ms/driver9.827ms/about5.073SQLperloan. Similar early windows r13133.902s vs r12733.715s show gate17.26vs77.34ms and queuedlogicalwait81.48vs1442.59ms, but are not randomized/identicalworkload proof. This supports the physical-fairness mechanism and contradicts attributing currentguard to previousSynctimeouts.

In the same strictwindow ordinaryread admissions8985/queuefull163508/timeout15241, coverageauthorization admissions2587 withtimeout/full0. Durable actualheld317.96ms/gate89.10ms; oneactualownerbatch perGW, queuedturnpeak644–748/Actor outstanding2184–2846. Cohort736commit/0isolation,41888accepted(~56.91commands/txn); sourceactualconnection_countrejectdelta1107 matches admissionpressure but doesnotbind eachreportedfailedop. Ownerstage acquire90.15/body270.37/locks76.68/persistence52.37/proof44.85/admission20.69/commit16.54ms are overlappingintervals, notadditive. TenPGsamples blockedpeak10/age318ms/categoryroomactivation54observations cannotprove globalquota-longlock rootcause.

Next investigation is existingownerbatch critical-path SQL and repeated ordinaryread recovery pressure inside originalresources, without rerunningunchangedformaltest or entering5000. Plan§12.5 skewinstrumentation patch remains stagedoutside repository, uncompiled, whilesource staysfrozen for offlinecauseanalysis.


Root offline resource check in samepartialphase:11host samples allmemoryPressureLevel=1. CPUticks interval user38109/system10898/idle28579 gives sampledwholemachine busy~63.16%; includes allprocesses and cannotexclude singlecore/stage limits. Process55.55348s window:6Gateway~5.995CPUcores andendRSS9406.125MiB;12Loader~0.272cores/endRSS2365.188MiB. Thisdoesnotprove hardwareindependence, but no sampled memorypressure/OOM evidence supports enlarginghardware/pools as the initialfix.


### r132 targeted correctness checks passed; r133 production build running

Root36081 actually terminal0, build77.75s,6functions/13cases/3suites passed in15.066s. Real disposablePGprimary+secondary created on owned57517, exactenvironment guards verified, bothDBsdropped/PGstopped terminal0. Existing durableOwnerBatchUsesSetwiseWrites(false/true) now confirms actual freshproof/permanentwrite combinedstatement; preparedauthority sixcases include permanentreceiptconstraint causing wholefailedroom domain/proof/envelope rollback and validsameidentityretryafterconstraintremoval; COMMITunknown(false/true) stillpreserves everyoperation without hiddenfallback. Newnilattempt acceptancecase observes oneactual permanentwrite/no dummyproofINSERT. Existingheldpeerfailure/cancelactualdrain and metricsrenderer verify fixedskewaccounting. These prove mechanisms, notformalcapacity.

Accepted freshproofbearingcohort now actualSELECT+combinedproof/envelopewrite(3to2 SQLcycles); nilattempt staysonewrite; original fullauthoritychecks, strictinsertkeys, quota-tail, rollback/unknown handling unchanged. ownerProofstage now preparation/read+checks, ownerReceiptPersistence observes actualcombinedwrite; no duplicateSQLspans. Fixedpartitionretainedload/recipientsets/actualcallbackmax-oldest metrics implemented, lifetime/current/localcompletion semantics documented.

Loaderordinaryroompull honorsmax(App1s,serverfloor,existingboundedexponentialbase)+existingjitter; keeps originalplannedbusinessrates,guarddenominator,quality,deferred/unknownidentity/deadlineanddrain. Canonicalalgorithmhash independentlyverified a569cfb30b0223800bf357e5bc4c3435cf33c3b5a09444a963c6398e1bd315a0. Finalcandidate/reference mustuse SAMEnewcommonLoader. r131failure remains historicalevidence, notrewritten.

r133 productionServerRelease root62664 live, log /tmp/imv2rt-7o99fjew/server-release-r133.log. Allagentsfinished/sourcefrozen. SerialAccount/Loaderbuilds remain required before smallandformal1000 rerun; no5000admission/fullgoalcompletion claimed.


### r133 production artifacts passed; r134 small verification running

Root62664 ServerRelease terminal0/175.03s; Account64723 terminal0/9.09s; Loader53779 terminal0/17.27s. Sourceboundary terminal0 anddependencyanalysis663sources/58overrides/2509symbols/2610edges/forbidden0/cross-targetSCC0; module-audit-r133.json/log. Allsources frozen. UpdatedcommonLoader canonical hash a569cfb30b0223800bf357e5bc4c3435cf33c3b5a09444a963c6398e1bd315a0 matches source, compiledartifactwillbevalidatedbyrunnerpreflight.

r134 small10k/1000 root35243 live, output /tmp/imv2-actor-realtime-10k-1000-r134/candidate; log /tmp/imv2rt-7o99fjew/10k-1000-r134.log. Originalscaledscenario/limits/quality/preclosewitnessunchanged. Thisrun cannot substitute for formal50k/1000orfulloriginal5000/commonLoaderbaseline80%. Latestformal terminal remains r131 failure.


### r134 small passed; r135 formal1000 running

Root35243 actualterminal0;12reports/all12exits0,10000TCPconnections,29988sent=ACK,999.08024ACK/s, failures/workload/heartbeatMiss/overflow/abandoned0. Common30.002s window,coverage/quality/steady-state/actualdrain passed; final10000 viewersmissing/behind/ahead0. Livegap5817/metadatagap22281 remain, so finalconvergence ratherthan gap-freeliveclaim. Both scopedproofs terminal0 on6complete6GW samplesinsidephase1790975861.119–5891.121:publishSettleddelta26939,route_lookup/realtime_owner_snapshot SQLdelta0/boundaryactive0,foregroundReceptionist0/background1050/miss0/invalidation0.

Newactualdiagnostics observed in same6samples: skewownershipviolations0 acrosssixnodes,partitionretainedbindingsmax118,room_events recipientmembers lifetime-max2 Gateway sessions (notdevices),completedcallback lifetime-max48.168375ms,oldestactualcallbackpeakobserved15.109833ms. Otherkind-zero baselines do notprove exercisedtraffic. offline-skew-observation-summary.json reports MAXofnode maxima, notSUM/phasequantiles. Thiscloses fixedsource observation integration in thesmallrun only.

r135root94234 liveoriginal50k/1000, original180scheckpoint/90ssend andresources/guards/preclosewitness, updatedcommonLoader andr133Server/Account binaries. Output /tmp/imv2-actor-realtime-50k-1000-r135/candidate; log /tmp/imv2rt-7o99fjew/50k-1000-r135.log. NoformalPASSor5000admission; r131 remains latestformalterminalfailure. Sourcesfrozen.


### r135 formal1000 failed; true ordinary-read supply remains insufficient

Root94234 actualterminal1,all12reports exist butrate-1000 incomplete~70.01s(original90s required),originalcheckpoint180 completed. Totalterminalworkload17507 andclosures are notfirstguardcounts. Phaseworkload180(total12),everyphasesynclogicalfailure0/retry0;initialterminalguard9–23/6414–6416offered perLoader. Phaseaccepted51997 (terminalACK52513),phaseBusy2899/attempttimeouts627; noformalcapacity/drain/qualityPASS. Final50000viewersmissing10/behind13725,coverageproof49990/false. OwnedGateway/Account/Loader verifiedgone. No5000admission.

OfflineactualHTTPresponsewindow13complete6GW samples whollyinside commonincompletephase,67.348s. /tmp/imv2-actor-realtime-50k-1000-r135/offline-storage-resource-summary.json andoffline-storage-resource-report.md. Similar earlywindowr13133.902s→r13533.071s proof40.925→20.813ms,receipt19.477→19.903ms,body249.316→214.155ms; actualSQLreduction mechanism reflected,notrandomizedcausalcapacityclaim. Fullwindowownerheld281.916ms/gate98.488ms/driver0.292ms;13914actualSQLmean18.556ms/betweenSQL2.599ms. Ordinaryqueuesall380,queuefull187314/timeout19125;10721actualgroupPullsmean110.978ms,3217recoveryloans127.397ms,about7actualSQLroundtripsperloan. Originalphysicalbudget is busy,notprovedleaking; measuredread-supply/sharedownerwaitingremainstructural pressure.

PG12samples blockedpeak10/fanin4/stmtage0.437s;roomfence42/fastquota2/other3 are sampledobservations,notuniqueincidentcounts. No recordeddeadlock/rollback,PGCPU~0.33–1.59cores/hostidle35.84%/swapunchanged. Cannotidentifyglobalquotaasuniquecause orhardwareasexoneratedbyaverages. Nextstep is groundedHost-local purepullcoalescing preservingoriginalreadpins/fulltokenSHAREfences/peritemauthandoriginalbudgets, notanotherunchangedrunorblindwriteSQLmicrofix. Sourcefrozenforofflineanalysis.


### r136 typed read backpressure passed; structural read coalescing implementation started

Gatewayonly groupEventPull proven notAccepted/rolledBack(overloaded) now maps SERVER_BUSY/retryable/1s throughsharedmapper inordinary/preparedentries. Otherreasonsholdpriorentrybehavior: ordinaryunknown/unavailable→genericUNAVAILABLE/0, preparedunknown/unavailableoriginalthrow/failedtelemetry. Root73301 actualterminal0, build76.75s, groupEventPullPreservesTypedBackpressure onefunction/eightcontrolledentry-failure combinations passed0.001s; /tmp/imv2rt-7o99fjew/group-pull-backpressure-r136-tests.log. NoPG/servicewasneeded. Thiscorrectsclassification, notcapacity.

Currentstructuralimplementation scope: existingHostquerycollector sharesone400 retaineditemsbudget(includingactual) withordinaryceiling300/reserved100forauthenticatedcoveragecohort; sameactual4slots/1:1purposeFIFO/idleborrow; mixedconfigrequiresmaximumPendingItems>maximumItems, production400/100unchanged. Coverageorigin comesonlyfromexisting service+userRoomCalls+roomCoordination-authenticatedrecoveryBatchHostcallback, ordinaryscalar/pullnotpromoted; no newTaskLocalorwireflag. Actualpurepull metadata+setwisehydration usesfulltoken SHARE fences,per(room,viewer,cursor,pageSize)authority,rigorousCodableData/base64/slash upperbound forpackingONLY. Internal256KiBaggregate isnotordinarynativeperpagecap(default8MiB); legitimatebigsinglepage usesoriginalsingletonpath insameactualslot, nofalseupperboundoversized. Successfulsubgroups settleonlyafteractualreadtxnCOMMIT, pagesdiscardedaftersubgroupcallback; actualslot/borrowretaineduntilremainingSQLsettles/originaldeadlines, noaddedpool/queue/timeout/grace.

Designs /tmp/imv2-r135-pure-pull-coalescing-design.md, /tmp/imv2-r135-pull-byte-protocol.md, /tmp/imv2-r135-read-collector-design.md. AgentSQL/collector editsareauthorized; rootownsFactoryintegrationandserialtargetedverification afterAPI/sourcefreeze. Uncompiled/newstructure notvalidated orcapacityaccepted. Noformalrerunor5000started.

### r137 integration and independent review; verification pending

Factory pure pull now enters the shared Host collector, removing the old per-item logical admission around the scalar executor. Physical resources explicitly bind the SQL continuation recorder. Read collectors drain after Host actors stop and before physical loan admission/pools close, including composition failure cleanup. The existing admission policy exposes its immutable queue timeout; collector enqueue captures one admission deadline across collector waiting and later database admission, while SQL retains the original call deadline.

Independent static review found no blocker in full-token fences, per-viewer/cursor association, commit-before-settlement, or singleton native response limits. It identified repeated metadata over every remaining large page as a potential quadratic workload. Fixed byte packing hints are being added solely to choose the next subgroup; each chosen subgroup must still acquire fresh fences and recompute authoritative metadata. No cached authorization or cursor facts are permitted. This correction is not yet compiled or verified.

Boundary check passed with zero migration exceptions. Module dependency analysis completed successfully; source/test compilation and real PostgreSQL cases remain pending. No new capacity result or 5000 admission is claimed.

### r137 targeted verification passed; r138 Release underway

Initial root73704 build failed on an extra optional chain on the nonoptional loan observation; corrected without changing scheduling or SQL behavior. Root7251 retry actual terminal0: build69.61s, nine test functions/eleven cases across three suites passed2.567s. Log `/tmp/imv2rt-7o99fjew/room-read-r137-tests-retry1.log`. Actual fresh primary/secondary disposable databases were supplied; purePullCollectionPreservesPagesAndBudget exercised both small and overflow cases, purePullSnapshotPreservesAuthority exercised live authority, saturatedBatcher exercised revised shared retention/byte/epoch/deadline behavior, and six collector lifecycle functions exercised actual settlement/cancellation/drain. The small setwise path observed two read-body statements; four overflow subgroups observed eight while retaining one actual loan. A legitimate complete singleton above the internal256KiB cohort budget succeeded under the original native limit.

The fixed byte-hint subgroup correction and exact checked aggregate overhead are included in this verified source. Queue/retained/actual metrics are connected through existing synchronous snapshots and deduplicated physical-owner aggregation. Final boundary check passed; dependency audit665sources/60overrides/2520symbols/2629edges, forbidden0/cross-targetSCC0. Both actual test databases were dropped and owned PostgreSQL stopped successfully.

r138 Server Release root98546 is live, log `/tmp/imv2rt-7o99fjew/server-release-r138.log`. Source frozen. Account Release will follow serially; unchanged current common Loader is to be reused. No new runtime/capacity result is claimed; original small→formal1000→full original5000/common-Loader baseline sequence remains required.

r138 Server root98546 terminal0/191.97s and Account root14326 terminal0/10.76s. Unchanged Loader artifact reused with canonical source identity checked by the benchmark preflight. r139 small10k/1000 root16996 is live, output `/tmp/imv2-actor-realtime-10k-1000-r139/candidate`, log `/tmp/imv2rt-7o99fjew/10k-1000-r139.log`; original scaled30s scenario and recovery witness retained. No result yet. Source frozen, no5000 admission.

### r139 small1000 passed; r140 original formal1000 started

Root16996 terminal0, all12 reports/exits0,10000 authenticated TCP connections,29988sent=ACK,999.528702ACK/s. Failures/workload/heartbeatmiss/overflow/abandoned0; original common30.002s window, coverage, quality, steady state and drain passed. Final10000 foreground viewers missing/behind/ahead0. Livegap7073/metadatagap23392 remain: final convergence is proven, gap-free live delivery is not.

Both scoped proof commands returned0 on six complete six-Gateway samples entirely within phase1790978805.768–8835.770; publishSettleddelta28206, route_lookup/realtime_owner_snapshot actual SQL deltas0/boundaryactive0; foreground Receptionist0/background1050/miss0/invalidation0. Business/control/authorization SQL are excluded from the address proof. Evidence `/tmp/imv2-actor-realtime-10k-1000-r139/candidate/hotpath-address-sql-proof.json` and the existing Receptionist proof output. New fixed collector metrics appeared on every Gateway; a transient sample is not a formal capacity claim.

r140 original50k/1000 started with the unchanged180s checkpoint/90s send scenario, original resources/guards and preclose recovery witness. Output `/tmp/imv2-actor-realtime-50k-1000-r140/candidate`, log `/tmp/imv2rt-7o99fjew/50k-1000-r140.log`. Source frozen. Formal1000 remains unverified; no5000 admission.

r139 offline fixed collector summary covers the same six complete six-Gateway HTTP samples inside the passing scaled phase. Per-node observed peaks: pending10, retained15items/6930bytes, actual4batches, queued oldest19.705417ms, actual oldest65.641625ms. Window deltas: started18900batches, selected35308items, settled35328items, all read kinds combined; approximately1.868selected items/start, not a pure-pull-only mean. More settlements than selections in this window are possible because items selected before the first sample settle inside it. Source `/tmp/imv2-actor-realtime-10k-1000-r139/candidate/offline-read-collector-summary.json`. Neither transient maxima nor small-scale throughput substitute for original formal1000 acceptance.

### r140 complete formal1000 window; final coverage/convergence failed

Root42950 actual terminal1. All12 reports/exits0; original180s checkpoint and90.005s common sending window completed.89988sent=ACK; failed/workload/heartbeatmiss/overflow/abandoned0; actualdraintrue. The run includes36 planned reconnects,50000peak connections/50036authentications. Partial-timeout/recovery counters remain visible: six attempt timeouts, eleven recovery queries, five SERVER_BUSY rejects, two unresolved wire attempts; no discarded errors or altered denominator. ACK/s985.841848. Overall qualityfalse because coverageproof failed and final50000foreground viewers include338behind committed head, missing0/ahead0. Therefore formal1000 acceptance remains failed and5000 is not admitted.

Offline complete-window summary `/tmp/imv2-actor-realtime-50k-1000-r140/candidate/offline-recovery-segment-summary.json` contains17complete six-Gateway HTTP samples wholly inside1790979364.980–9454.985. This is a complete phase but not a formal-quality pass. Report coverage49584passed/416failed connections; failed scopes381room-recovering,36account-recovering,20room-ready with applied cursor below announced H. Only20cursor entries lag their own announced H, each has a pull in flight/reserved; final338DB-behind cannot all be explained by those announced gaps. The36account failures equal the planned reconnect count; equality alone is not causal proof.

Existing bounded foreground-wake witness sampled256of338lagging rooms after the client reports, not atomically:141nooutboxrow,115pending/claimable; only21present rows target the observed committed head. Neither absent rows nor older targets alone prove lost delivery. Existing preclose witness observed allLoadersLiveBefore/AfterReadtrue; its selected scopes and database read are separate snapshots. Source remains frozen while three existing agents perform read-only recovery, Loader snapshot/reconnect and physical-SQL audits. No unchanged rerun, extra test or TTL alteration is scheduled.

### r140 cause localization: recovery dispatch starvation

Independent reports `/tmp/imv2-r140-client-recovery-snapshot-audit.md` and `/tmp/imv2-actor-realtime-50k-1000-r140/offline-storage-coalescing-report.md` correlate36planned reconnects with36account scopes remaining initial/recovering. Complete-window actual recovery count for accounts is0; queued age reaches58.303s, and after sending reaches68.95s. Room desired/queued peaks30312/5618; room awaiting-retention age reaches84.091s despite actual authorization oldest at most4.435s. These observations locate waiting before execution, not a58s individual SQL call.

Production Registry selection unconditionally prioritizes prepared authorization, authorization-batch collection appends nonroom keys to the tail, and prepared queue insertion/eviction prioritizes new prepared scopes. Combined with sustained room backlog these permit account starvation. Root authorizes a fixed three-class eligible FIFO/round-robin correction inside the existing four actual workers and1024 queued IDs, including fair refill for demands outside the queue; no new slots, TTL change, Loader hold extension or weaker quality gate. Only the Registry and a focused existing controlled fixture thaw for this implementation.

The existing Loader `scenarioDrain` boolean has narrower scope than all recovery: it covers messages, read receipts and explicit state-recovery calls, not ordinary room pulls, Sync or coverage. Twenty final snapshots still have ordinary pulls in flight; `drained=true` must not be described as all recovery being settled before the final snapshot. All owned Gateway/Account/Loader processes are now verified absent after root terminal exit. Final snapshot audit selected384preclose connections with the same physical IDs at final sampling; four moved Ready→Recovering between samples, so at least those are real coverage transitions, not inherited/reused snapshots. The final338lagging views are not yet causally explained in full; the scheduler correction must pass real quality checks before claiming resolution.

### r141 recovery fairness focused checks passed; two bounded refinements pending

Root3504 actual terminal0, five targeted functions passed0.668s without PostgreSQL: recoveryServiceClassesAreFairAndDrained, authenticationRecoveryIsBoundedAndDrained, foregroundAuthorizationCollectsPairsAndDrains, foregroundReadyReauthorizesAfterDelayedEnqueue, inlineDurableRetentionIsIndependentAndDrained. Log `/tmp/imv2rt-7o99fjew/registry-fairness-r141-tests.log`. The new fairness fixture holds four actual authorization callbacks, creates prepared-room, authorization-room and account backlog through production entry points, then releases one actual slot at a time to observe account FIFO, prepared FIFO and room authorization progress. Cancelled account/shutdown retain all actual ownership until writer/RPC gates release. This is a controlled scheduler result, not a formal quality pass.

The three-class dispatch retains four tasks,1024 queued IDs,128 authorization scopes and original30s authority fences. No full desired-map sorting; full actual occupancy skips scheduler scans. Two static-review refinements are scheduled only after root3504 ended: move full-queue missing-class replacement into the finite pump refill stage to avoid an O1024 scan for each new demand; route durable-notification hintOnly demand through that same bounded queue/dirty-class entry when inline work cannot start. Only fairness/inline targeted checks will rerun after those refinements.

Loader subscription replies now coalesce max(previous announcedH, appliedCursor, serverH), matching the existing App monotonic target behavior and validating the current active handler/scope. This corrects a real late-reply target regression, not a demonstrated explanation of all338lagging views. No offered rate, hold, retry budget, denominator or quality gate changed. Root independently evaluated the exact benchmark canonical rule and confirmed current embedded/source hash `a894107998d385e96c0a805ea6cd40010fcddf82e55172b04dadd44f900fb9cb`. Production Release artifacts remain stale until rebuilt; next full baseline comparison must use this same updated common Loader.

r141 first build79.56s. Both bounded refinements landed only after root3504 terminal0. Root17771 actual terminal0; the two affected functions recoveryServiceClassesAreFairAndDrained and inlineDurableRetentionIsIndependentAndDrained passed0.008s, log `/tmp/imv2rt-7o99fjew/registry-fairness-r141-refinement-tests.log`. Ordinary full-queue enqueue now only marks the fixed class and returns; at most three missing-class replacements occur inside an actual pump opportunity. Durable hint merges enter the same queue/dirty-class path and respect existing actual/inline ownership. No additional worker, queue or authority budget.

r142 Server Release root64842 is live, log `/tmp/imv2rt-7o99fjew/server-release-r142.log`; source frozen. Account and changed common Loader will build serially next. No dynamic quality improvement is yet proven, and no5000 run is admitted. The318final views that had no announced gap remain an open runtime check; static dispatch/entry improvements cannot substitute for final database-head convergence.

r142 Server root64842 terminal0/167.31s, Account root74869 terminal0/9.10s, changed Loader root49927 terminal0/17.07s. Boundary/dependency audit passed665sources/60overrides/2520symbols/2629edges/forbidden0/cross-targetSCC0; source frozen. r143 small10k/1000 root46901 started, output `/tmp/imv2-actor-realtime-10k-1000-r143/candidate`, log `/tmp/imv2rt-7o99fjew/10k-1000-r143.log`. Current common Loader source identity is independently verifieda894107998d385e96c0a805ea6cd40010fcddf82e55172b04dadd44f900fb9cb. No runtime result or5000 admission yet.

### r143 small1000 passed; r144 original formal1000 started

Root46901 actual terminal0; all12 reports/exits0,10000TCP connections,29988sent=ACK,998.949876ACK/s. Failed/workload/heartbeatmiss/overflow/abandoned0; original30.005s common window, coverage and quality passed; final10000foreground viewers missing/behind/ahead0. Livegap6255/metadatagap23186 still recorded, so final recovery is proven rather than gap-free live delivery. ScenarioDrain retains its documented message/read-receipt/explicit-state scope.

Both scoped proof commands returned0 on six complete six-Gateway HTTP samples inside1790980842.633–0872.638: publishSettleddelta27639, route_lookup/realtime_owner_snapshot actual SQLdelta0/boundaryactive0; foreground Receptionist0/background1050/miss0/invalidation0. Business/control/permission SQL are excluded from the address proof. Same updated common Loader source identitya894107998d385e96c0a805ea6cd40010fcddf82e55172b04dadd44f900fb9cb.

r144 original50k/1000 started after root46901 ended, with unchanged180s checkpoint/90s send, original resources/guards and preclose recovery witness. Output `/tmp/imv2-actor-realtime-50k-1000-r144/candidate`, log `/tmp/imv2rt-7o99fjew/50k-1000-r144.log`. Source frozen. Reconnect coverage and final committed-head convergence remain unverified at this scale; no5000 admission.

### r144 original formal1000 completed; final convergence failed

Root57352 terminal1; all12 Loader reports and exits0. Original180s checkpoint and90.001s common send window completed. Authenticated50036/peakActive50000/plannedReconnects36;89988sent=ACK,989.115581ACK/s. Workload/authentication failures, heartbeat misses, overflow, abandoned messages and terminal message queue0. Transport counters contain only89988WIRE_SUBMIT/89988ACCEPTED. Capacity execution, steady state and common-window completion passed, but coverageProofPassed=false and qualityPassed=false. Final50000 foreground viewers missing0/behindCommittedHead3137/ahead0. No5000 admission.

Account Ready50036 shows the reconnect account scheduling improvement relative to r140 Ready50000; this does not establish room convergence. Room Ready85720/Recovering34943, availability hints99426, room records97239/live payload applied38047. Livegap3719/metadatagap5696 remain. ScenarioDrain=true retains its original narrow message/read-receipt/explicit-state scope; it does not prove all ordinary room recovery settled.

Owned service/Loader processes are absent after terminal completion. Existing-report-only diagnostic `/tmp/imv2-actor-realtime-50k-1000-r144/candidate/offline-recovery-segment-summary.json` derives17 complete six-Gateway samples strictly inside phase1790981405.692–1790981495.693 (sample span1790981408.775–1790981495.418). It explicitly makes no formal quality claim. Independent client, Registry and storage audits are in progress before any source change or repeated run; post-report wake snapshots must not be treated as atomic proof of client delivery.

Independent r144 client and storage audits now exist: `/tmp/imv2-r144-client-recovery-audit.md` and `/tmp/imv2-r144-storage-recovery-audit.md`. Full50000-viewer join finds all3137lagging viewers have announcedH below committedH and no pull/slot/retry/grace;3115are Room Ready/22Recovering,3131lag byone/six bytwo. All50000account scopes Ready. Actual final client snapshots span1506.848–1507.074; original message drain completed about1497.016 at latest, followed by unchanged10s hold. Actual preclose DB statement1499.688–1499.738 already proves34of384selected connections have a committedH above their later final cursor/announcedH; those34cannot be explained by commits after final snapshot. The final full join and later bounded wake witness remain separate snapshots. Later256-room witness246no-row/10leased is not delivery proof; postclose noSubscribers can legitimately consume wakes.

Storage read pressure improved: ordinary admission rejects0, actual PG lock-wait peak7, group pull6386actualcohort loans/51079SQL/12773read-body executions. One cohort can execute several freshly fenced subtransactions; counts must not be compared as scalar caller costs. Collector queue/actual age maxima254.8/357.8ms; actual Registry authorization≤2.135s. Current room desired30077→49329/awaitingRetention4623→26089, oldest queued251.486s includes pre-phase checkpoint demand. Reason/actual_reason families are current gauges, not work-completion counters. Host caller counters show16049calls/46213items≈2.88items/call versus r1407475/86442≈11.56; no per-request expired-proof counter yet proves feedback attribution.

Both independent Registry/storage source reviews identify a concrete work-granularity mismatch: room authorization tasks select≤128scopes and produce≤128prepared continuations, while each prepared task handlesone and repumps/scans the queue. Original unchanged-head retention/Ready fastpaths still avoid unnecessary socket writes but do not avoid this per-scope dispatch cost. This supports a structural backlog correction without claiming every3137missing hint has the same cause. Root authorized r145 bounded prepared borrowing inside the same4actualtask/1024queuedID/128scope/30s authority bounds, exact per-scope CAS and outer actual drain. Dynamically claim only the next current FIFO scope rather than preoccupying127healthy scopes behind a slow writer; eligible account/other-scope work interrupts the next borrow. Source thawed only for the implementation owner after verified r144 termination. No repeated workload or further build has started.

### r145 bounded prepared borrowing verified; production build started

Four files changed: Registry, its reentrancy tests, runtime-pressure Contracts and the existing renderer. Outer prepared task handles≤128dynamically claimed scopes with one actual writer at a time; each scope has exacttaskID settlement and the shared task slot settles only in the outer defer. Eligible queued other scopes or a fixed missing-other signal end further borrowing, allowing the original bounded pump to refill. No per-item desired-map scan, new child-task pool, larger queue, additional writer concurrency or longer permission interval.

After actual Recovering writer returns, failed consumption of the original prepared proof always returns to the batch authorization lane. Independent review caught two time checks permitting an expiry between checks to enter the old scalar fallback. Root removed the redundant guard and placed prepared-owner return directly in the sole consumption condition's else branch, before every scalar path. Original H/receipt/generation/version enqueue fences remain; new H is not claimed retained merely because it was authorized.

Root2841 terminal0, build77.93s; seven functions/eight cases passed1.074s without PG. New `preparedRecoveryCohortsKeepFairnessAndActualOwnership` passed0.115s:132real installed scopes, a real128item authorization callback, lifetime baseline differences, a mid-cohort account insertion, single writer rejection with neighboring progress, and shutdown holding two prepared writers plus one account writer until actual release. Existing class fairness, bounded authentication, pair authorization, permission-window, per-connection isolation (two cases) and inline retention/drain checks also passed. After the narrow deadline refinement, root95296 terminal0/build8.79s; only the two affected cohort/window functions reran and passed0.655s. Logs `/tmp/imv2rt-7o99fjew/registry-prepared-cohort-r145-tests.log` and `registry-prepared-cohort-r145-boundary-tests.log`. No full-suite or extra PG verification was run.

Boundary check0exceptions; dependency audit665sources/60overrides/2522symbols/2629edges/forbidden0/cross-targetSCC0. New fixed lifetime task/scope started/settled counters distinguish actual work units; queued prepared expiry counts actual removal once, not repeated classification or token change. Neither settlement counter certifies client application. Server Release root67463 is running, `/tmp/imv2rt-7o99fjew/server-release-r145.log`; Account will follow serially and unchanged common Loader a894107998d385e96c0a805ea6cd40010fcddf82e55172b04dadd44f900fb9cb is reused. All source frozen. r144 remains the latest formal1000 failure; runtime convergence benefit and full original5000/common-Loader baseline≥80% remain unverified.

r145 production builds now terminal0: Server root67463/171.79s and Account root80477/9.11s. Unchanged common Loader reused. Root13707 started r146 original scaled10k/1000, output `/tmp/imv2-actor-realtime-10k-1000-r146/candidate`, log `/tmp/imv2rt-7o99fjew/10k-1000-r146.log`. Source frozen; no runtime convergence result yet. Small→formal50k/1000→full5000/common-Loader baseline gates remain unchanged.

### r146 small1000 passed; r147 formal1000 started

Root13707 actualterminal0, all12reports/exits0. Original small10000connections/29988sent=ACK/997.624378ACK/s; auth/workload/heartbeatmiss/overflow/abandoned/endqueued0. Quality/coverage/steady-state/common-window passed,29.994s common send interval; final10000foreground viewers missing/behind/ahead0. Room livegap5642/metadatagap23106 remain, so this is recovered final convergence, not gap-free live delivery. Current unchanged a894commonLoader identity accepted by preflight.

Both scoped proofs terminal0: six complete six-Gateway samples inside phase1790983116.615–1790983146.609, publishSettledΔ27873. Actual route_lookup/realtime_owner_snapshot address SQLΔ0/activeboundary0; foreground ReceptionistΔ0/background1050/miss0/invalidation0. These proofs exclude business/control/authorization/recovery SQL and other Actor systems. Small-test throughput does not replace original formal capacity acceptance. Existing-report-only recovery summary is saved; no extra service/PG sampling was added.

Root3109 now runs r147 original50k/1000 with unchanged180s checkpoint/90s sending, original resources/guards/quality and preclose witness. Output `/tmp/imv2-actor-realtime-50k-1000-r147/candidate`, log `/tmp/imv2rt-7o99fjew/50k-1000-r147.log`. Source frozen. Reconnect coverage and final convergence remain unverified at this scale; no5000 admission. r144 remains the latest completed formal failure.

r146 existing-report-only cohort audit `/tmp/imv2-r146-prepared-cohort-summary.md`/`.json`: six complete six-Gateway samples,25.666s observed within the nominal30s phase; r143 comparison25.711s with different first/last gaps. r146 actual authorization starts4366tasks/14990scopes, settlements4382/15008 reflect boundary carry-in. Prepared starts/settlements4408tasks/12063scopes each, average2.737scopes/task, queued prepared expiryΔ0/no node resets. r143 predates these counters; no fabricated work-ratio comparison. Room queued r14374→2626/peak2626 versus r14658→10/peak58; desired161→2880 versus147→77. r146 oldest queued3.063→25.562s is remaining original demand age, not actual writer/SQL duration; all current demand clears at observed phaseend+3.996s. Same full29988ACK/final10000convergence; phase pulls26493versus26492/retryable0. This supports small-scale actual batching/queue reduction, not formal50k throughput or account-backlog fairness. No r147 live data or extra sampling was used by the offline audit.

### r147 full formal1000 completed; final quality still failed

Root3109 actualterminal1; all12reports/exits0, original180s checkpoint/90.008s send. Authenticated50036/peak50000/plannedReconnect36,89988sent=ACK/984.181513ACK/s, auth/workload/heartbeatmiss/overflow/abandoned/endqueued0. One SERVER_BUSY rejection is retained (89989WIRE_SUBMIT/89988ACCEPTED); no hidden retry-denominator change. Steady-state/common-window execution passed; quality/coverage failed. Final50000viewer missing0/behind1049/ahead0, versus3137r144. Final account scopes50000Ready; room48938Ready/1062Recovering, three Ready scopes below their coverage H,48935coverage-pass connections. ScenarioDrain remains narrower than ordinary room recovery. Owned services/Loader are absent after terminal completion. No5000 admission.

Existing-report-only client audit `/tmp/imv2-r147-client-recovery-audit.md`/`.json` classifies the entire1049:1036unknown finalH with no pull/slot/retry/grace (1000Ready/36Recovering),13knownH with actualpull+slot (11Ready/2Recovering).1048lagbyone/onebytwo. At least7of384preclose samples have actual earlier committedH above their later final cursor/announcedH, so those7cannot be final-snapshot late commits. Final snapshot span3822.383–3822.605 follows latest measured message drain≈3812.527 and unchanged10s hold. Later256wake sample120noRow/136present (117pendingclaimable/19leased) is non-atomic and not proof of earlier delivery. All grace configuration/counters0; metadata grace timers did not execute in this run.

Strict17complete six-Gateway samples inside phase1790983720.864–1790983810.872 span1790983722.156–1790983809.905. Registry audit `/tmp/imv2-r147-registry-recovery-audit.md`/`.json`: authorization853started tasks/71823scopes≈84.20 per task; prepared1257/47158≈37.52. Actual batching is proven, but4889queued original permission proofs were removed on expiry. Room desired83→29810/peak36161, queued1→5888/peak5922; original queued age85.6s versus actualauthorization≤4.78s. Recheck dominates remaining demands (25404of29810 at last phase sample); no outer-end-reason metric proves account yielding is the cause of the37.52ratio. At phaseend+9.787s still23079desired/5247queued/24actual. Gauge differences are not completion counters.

Storage audit `/tmp/imv2-r147-storage-recovery-audit.md`/`.json`: original ordinary/coverage admission rejectΔ0; collector queue/actual maxima364/621ms. PG blocked peak10 primarily room-fence sample observations65/quota2; no attribution to exact rows or a unique idle-retirement cause. Control remains256installed partitions/six qualifiednodes/102successfulrenewals/no failure across the window.5378Directory invalidations are not a count of activation epoch changes. Preclose20sampled viewers are behind without announcedH or pending pull;15associated wakes pendingattempt0, two pendingattempt3, two leasedattempt1, one noRow. Sequential Relay revisitation remains a candidate, not an already-proven explanation of all1049.

Source audit identifies a more precise queue-ownership gap: successful authorization callback caches a prepared proof, finishes its scope ownership, then attempts an ordinary queue append. A full1024queue can reject that append while retaining the proof only in the active-scope cache. Existing queued prepared entries suppress missing-class refill; unordered desired refill waits until queue<512, so consumers may not see valid outside proofs before the original30s expiry. The counter proves expiry occurs but does not trace every expiry to this path. The next proposed correction reserves the original removed authorization IDs' return positions inside the existing queue bound (queued+reserved≤1024), with exacttask/key callback settlement and no SQL/socket wait or new queue. Source remains frozen pending independent ownership/fairness review; no unchanged workload is scheduled.

Final requirement audits `/tmp/imv2-final-client-completion-audit-r147.md` and `/tmp/imv2-final-server-completion-audit-r147.md` map current source plus existing real App/PG/native fault evidence to the original scope. They find no additional definite source blocker; formal1000 and full original5000/common-Loader baseline≥80% remain unmet. These audits do not turn historical mechanism proofs or the small pass into full capacity acceptance.


### r148 bounded authorization return positions — implementation and focused verification

Four owned source/test files are frozen after independent Registry ownership and Gateway fairness review. Authorization dequeue reserves exact task/key/lifecycle/scope-generation tickets synchronously inside the original queued-plus-reserved 1024 bound. Ordered partial callbacks atomically consume their own tickets and requeue; duplicates/stale generations cannot transfer permission to a successor. Actual outer settlement alone cleans unused tickets and releases the four actual task slots. Missing-class refill preserves valid prepared proofs, removes classes already represented by eligible queued heads, and follows the existing RR cursor over at most three cached candidates; no desired-map scan or added capacity in this path. Fixed authorization_returns stage exposes actual-owned return positions.

Root session9269 actual terminal0: Debug build83.69s, seven affected tests in one suite PASS0.689s, including new authorizationReturnsOwnQueueCapacityAndGeneration with1032 actual scoped streams, four held authorization calls, full1020queued+4reserved capacity, successor generation, repeated partial callback, one free position/account competition and actual shutdown drain. Log `/tmp/imv2rt-7o99fjew/registry-authorization-returns-r148-tests.log`. Server boundaries PASS0exceptions; dependency audit665files/60overrides/2522symbols/2629edges, forbidden0/cross-targetSCC0. Production Release build is in progress; no r148 runtime capacity acceptance yet. Original formal1000 and full5000/common-Loader baseline gates remain open.

Root Release builds r148 terminal0: Server172.53s (`server-release-r148.log`), Account9.13s (`account-release-r148.log`), unchanged common Loader retained. Root session79221 started r149 original scaled10k/1000 candidate with the existing fixture/scenario and preclose witness; no terminal or quality result yet.


### r149 scaled10k/1000 PASS; r150 original50k/1000 in progress

Root79221 actual terminal0, all12reports/exits0. Authenticated/peak10000;29988sent=ACK;999.377781ACK/s; failed/workloadFailed/heartbeatMissed/overflow/abandoned/endqueued0. Original30.006s common window passed; quality and coverage passed; final10000foreground viewers missing/behind/ahead0. TCP send/TCP_query recovery verified; planned reconnect0 due original scaled rounding, so this run does not establish reconnect load. Live gaps6912/metadata gaps23269 remain: final convergence is proven, gap-free live delivery is not. Owned Server/Account/Loader processes absent after terminal.

Six complete six-Gateway samples inside1790985610.299–1790985640.305, sampling1790985613.393–1790985639.093: publish settled delta28223; route_lookup/realtime_owner_snapshot SQL deltas0 and boundaryactive0; foreground Receptionist0/background1050/misses0/invalidations0. Both scoped proof commands terminal0; business permission/control/persistence SQL excluded. Existing recovery summary records queued prepared expiry delta0 and authorization return positions return to0 at last sample; no formal50k inference. Artifacts `/tmp/imv2-actor-realtime-10k-1000-r149/candidate`, log `/tmp/imv2rt-7o99fjew/10k-1000-r149.log`.

Root session90268 is live for r150 original50k fixture/1000 scenario, original180s checkpoint/90s send/30s drain/10s hold unchanged. Six Gateways ready and client ramp underway; no terminal or quality acceptance yet. No5000 entry until this original1000 quality gate passes.


### r150 original50k/1000 terminal FAIL — no5000

Root90268 actualterminal1; all12reports/exits0,50036authenticated/peak50000/36plannedreconnects.89988sent=ACK/987.490135ACK/s, failed/workloadFailed/heartbeatMissed/overflow/abandoned/endqueued0.90.012s originalcommonwindow passed; quality/coverage failed; final50000viewer missing0/behind871/ahead0. One timeout/unresolved operation recovered via one TCP query;89989wire submits/89988accepted remain reported. ScenarioDrain is narrower than ordinary recovery/coverage. Owned services/Loader absent after terminal. Original5000 remains prohibited.

Seventeen complete six-Gateway samples inside6177.868–6267.880 span6178.869–6266.610. queued prepared proof expiry delta0 (r1474889); last phase room desired27332/queued5040/reserved978, so elimination of expiry does not imply elimination of demand delay. Authorization756tasks/71324scopes started (~94.34/task), prepared851/52788(~62.03/task); boundary scopes settled differ and are not per-client completion. Existing recovery summary is diagnostic only.

Client audit `/tmp/imv2-r150-client-recovery-audit.md`/`.json`: all871lagbyone are unknownH with no pull/slot/retry/grace (843Ready/28Recovering). EveryReady satisfies its own declared H; there are no known-H final gaps in this run. Final room49081Ready/919Recovering,891Recovering already match DBhead; account50000Ready. Six actual earlier preclose samples prove a gap existed before final snapshots; no arbitrary late-commit claim. Later bounded256wake sample135noRow/121present(116pendingclaimable/5leased) is non-atomic and noRow cannot prove delivery. No new client timer/monotonic H bug demonstrated. Registry and storage audits remain pending; source remains frozen and no unchanged benchmark scheduled.

Registry audit `/tmp/imv2-r150-registry-recovery-audit.md`/`.json` confirms per-node sampled queued+reserved peaks1024/1022/1019/1023/1013/1023. At phase end16authorization+8preparedactual Tasks and978authorization+8preparedscopes close actual ownership totals exactly. At +9.556s still21343desired/4041queued/24actual. Last phase recheck23607/newHead2123/initial1602; the original return gap was corrected, but no stable supply-demand capacity is proven. Auth oldest4.711s differs from sampled Host/nativeRPC/SQL<=216ms; cannot assign that difference to a particular stage without attribution.

Storage audit `/tmp/imv2-r150-storage-recovery-audit.md`/`.json`: preclose17selectedbehind allunknownH/no pendingpull,15Ready/2Recovering;13pending rows(12attempt0/1attempt2) had been due16.985–76.912s, fourleasedattempt1. This proves delayed revisit for these selected rooms, not every871 or uniquely serial Relay causality. Collector queued/actual maxima211/422ms and rejects0; PGblockedpeak12 mainlyroomfence sampleobservations105, not an identified quota row.

Root authorized r151 only bounded Relay execution plus focused tests in V2GroupEventWakeApplication.swift/V2GroupEventWakeRelayTests.swift. Same runtime-owned worker, originalclaimlimit/15slease/retry/physicalpools and Fanout8/peer2 gates remain; structured window<=8 per-lease publish→exactmark/retry removes cross-room serial waiting. Fatal/cancel stops new dispatch and awaits submitted actual children before returning; unsubmitted leases remain for original TTL recovery. No r151 test/build/runtime evidence yet. Other production source remains frozen.


### r151 Relay bounded window — source frozen, focused verification running

Two owned files only: V2GroupEventWakeApplication.swift and V2GroupEventWakeRelayTests.swift. One nonthrowing structured group starts at most8 actual per-lease children and replenishes only after a child publish→mark/retry completes. First observed fatal error or parent cancellation stops replenishment; group.next drains submitted children before original error returns. No extra worker/pool/TTL/budget. Unsubmitted claimed leases recover on unchanged15s expiry. Per-lease claim token/revision and typed/generic retry functions remain unchanged; successful publication with an old revision cannot delete a newer coalesced H. Local await settlement is not a claim that a timed-out remote method has physically ended.

Independent Gateway review found no blocking issue. New controlled three-argument test covers slow-peer independence, old-revision CAS, parent-cancel stop/drain and fatal-error drain; the fatal test explicitly does not equate a Store failure observation with the parent receiving that result. Static parse/diff passed. Root65702 focused verification is live, no result yet; source frozen during root build/test.

Root65702 actual terminal0: build92.69s; five focused Relay test functions (12 parameter cases) PASS0.001s, including three new bounded window cases. No PG; exact Store SQL unchanged and old/new revision CAS and typed/generic retry are covered by affected tests. Log `/tmp/imv2rt-7o99fjew/relay-bounded-window-r151-tests.log`. Server boundary check PASS0exceptions. Root60022 Server Release build now live; no r151 capacity claim yet.

Root60022 Server Release terminal0 build171.19s; Root4475 Account Release terminal0 build9.64s; unchanged common Loader retained. r152 scaled10k/1000 originalfixture/scenario candidate launched; no quality result yet.


### r152 scaled10k/1000 terminal FAIL1 — no50k escalation

Root73124 actualterminal1,12reports/exits0,10000authenticated/peak;29988sent=ACK/997.260076ACK/s, fail/workload/heartbeat/overflow/abandoned/endqueued0.30.004s common window and coverage10000 passed, but final10000foreground viewers missing0/behind1/ahead0 causes qualityfalse. Originalsmall gate is not relaxed for a single viewer; no50k or5000 launched. Owned services/Loader absent. Artifacts `/tmp/imv2-actor-realtime-10k-1000-r152/candidate`, log `/tmp/imv2rt-7o99fjew/10k-1000-r152.log`.

Existing later wake witness covers the sole lagging room (not truncated): pendingtargetH22/revision1/attempt9/no lease, nextAttempt08:26:31.804998 after DB observation08:26:31.577416 by227ms, not yet claimable. This is non-atomic after final reports, not proof of the precise pre-final reason. Source remains frozen; client and storage agents are tracing this one case offline before any repeat/change.

Offline focused case audits `/tmp/imv2-r152-client-tail-audit.md`/`.json` and `/tmp/imv2-r152-storage-tail-audit.md`/`.json`: sole receiver applied21/announced20/ReadyH2, no pull/slot/retry/grace. Other room participant observed hintH22 at1790987188.403,1.899s before lagging final1790987190.302, disproving a commit-after-final-only account for this case; selected preclose sample does not contain this room. Laterwake pendingH22/revision1/attempt9/nextfuture227.582ms preserves responsibility; errorclass is not stored and cannot be inferred from attempt. No demonstrated CAS loss, parentdrain fault or client state flaw. Six-node phase window25.726s publisherpeer rejections7894 versusr1494218, deliverypeer2983versus2102, durable14versus3, globalpublisherreject0. These independent scoped aggregate counters support peer2 contention as a candidate after8window, not per-lease causal attribution. No unchangedrerun, denominator/hold/gate relaxation.

Next authorized work is read-only design/review of cached Host-aware dispatch within originalownedpass/global8/peer2 bounds, no new queue capacity/TTL/worker/pool, no physical routing identity leakage into business wake model. NativeActor/Storage agents review concrete API, cached-route epoch invalidation and actual cancellation/leaseCAS before implementation. Source remains frozen until that review.


### r153 cached Host-aware publication — implementation authorized, no runtime claim

Concrete proposal `/tmp/imv2-r152-host-aware-relay-design.md` and independent storage review accepted. Only group-event wake batch path changes this round; userSync retains scalar shared gates. Protocol gains required batch method with ordinal/result/throwing settlement callback; actor publisher overrides with native private preparation/scheduling, local/test publishers use default bounded execution. Business wake/lease models do not contain physical Host/route keys.

Native prepare and publish actual children share original8 work slots. Prepared descriptors occupy only state in the original claimed input array; cached resolve/topic construction once per item, no full-input preparation barrier or held SQL/native permit. Selection uses full descriptor.endpoint.identity exactly matching Sender peer accounting, at most2 dispatched per peer; Fanout durable8 and Sender publish12/peer2 remain authoritative. Async unknown preparations do not promise cross-room FIFO. Transport currenttoken/descriptor/expiry/CAS remain final checks; stale action is original-lease retry, not a second resolve under a changed key.

Relay callbacks consume exact original ordinal once, apply unchanged lease token/revision mark/retry, propagate fatal persistence errors, and failclosed on duplicate/invalid or missing successful callbacks. Cancellation stops new work and drains submitted local awaits; unsubmitted original claims recover on unchanged15s TTL. Source changes split between actor publisher/tests and business contract/Relay/tests owners, root builds/tests/services remain exclusive. No r153 static/test/build/runtime result yet.
