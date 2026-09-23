# G5 隔离真实发送 canary

`IMV2/scripts/test_v2_virtual_actor_capacity_canary.py` 用同一份容量 fixture 对冻结 main 或 candidate 各执行一次真实 TLS/protobuf Gateway 发送。它不编译、不修改源码，不依赖用户默认 Compose；每次随机创建 `imv2-va-cap-*` 项目、loopback 随机端口、control + N 个 owner PG、Gateway 和单次 loader，最后只销毁该项目的容器/卷。源码 checkout 必须干净且与 `--source-sha` 完全相等。Gateway 和 loader 都来自显式 Linux Release 产品目录；runner 用已完成的 `result.json` 核对源码、lockfile、固定 Swift 镜像和 ELF SHA-256，再复制到本次私有运行目录并重新哈希。

正式对照应给 main 与 candidate **同一个修正 TCP socket option 的 Release loader**；它可以来自独立于服务源码的构建。传 `--loader-products-dir` 与 `--loader-build-result` 两项，runner 会核对并在结果中记录 loader 自身的 source/lockfile/build-result/ELF SHA。未传时才使用所选版本的原始 loader。冻结 main 的原始 loader 把 TCP_NODELAY 误传为 SOL_SOCKET/SO_DEBUG，在普通 Linux 容器中会因 EPERM 失败。`--legacy-loader-net-admin` 仅供临时诊断已冻结原始 main 二进制，且只给一次性 loader 容器 NET_ADMIN；正式 canary 和容量采样均不使用该参数。

示例（路径由构建负责人提供，fixture 用同一个私有目录）：

```sh
python3 IMV2/scripts/test_v2_virtual_actor_capacity_canary.py \
  --source-checkout /path/to/clean/main-or-candidate \
  --source-sha FULL_40_CHARACTER_SOURCE_SHA \
  --release-dir /path/to/that-revisions/products \
  --build-result /path/to/that-revisions/result.json \
  --loader-products-dir /path/to/corrected-loader/products \
  --loader-build-result /path/to/corrected-loader/result.json \
  --fixture-dir /path/to/the-same-private-fixture \
  --layout hot --docker-context colima-imv2-vapor5 \
  --artifact-dir /path/to/new-private-artifact-dir
```

可先加 `--preflight-only`，此时只读源码、build metadata、二进制和 fixture，既不创建 artifact 目录也不调用 Docker。正式执行会从 **目标 checkout** 的 canonical `schema.sql` 安装每个独立的 `imv2_va_*` 数据库，再写入 seed 对应的 disposable 标记及 fixture SQL。控制库放 auth/profile/route，owner 库放 group/room/membership/admission；Gateway 的 HMAC key 只通过私有 env/Compose 传入。candidate 如在 Compose 中要求 Room Actor 配置，则由目标 checkout 的配置生成器创建仅有 Gateway host 的 TLS+签名配置；main 不需 Actor。客户端和 Gateway TLS 使用本次独立 CA。标准输出只有结果和证据目录，不打印 token、key 或容器化配置。

验收条件：native `IMV2GatewayLoadGenerator` 报告全部连接已认证、`messagesSent == messagesAcknowledged == 1`、`directRoomAttempted == 0` 且没有业务/连接失败；所有 owner 库合计恰有一条 `im_v2.messages`，其发送者在 fixture 用户集合、房间在 `targetRoomIDs` 集合、序号为 1，所在 owner 与控制库 `room_owner_routes` 完全一致。`result.json` 记录 source/lockfile/schema/镜像/ELF/fixture/roommap 摘要和唯一 SQL 效果；负载报告保存在 0700 artifact 目录。该 canary 仅证明 fixture 能在两版真实服务路径发送，不是性能值或吞吐阈值。

隔离测试：`python3 IMV2/scripts/test_v2_virtual_actor_capacity_canary_runner.py` 验证源 SHA、build-result、ELF 及 fixture hash 的拒绝路径，不启动 Docker。2026-09-24 冻结 main 与 candidate 已用同一修正 Release loader `98b70dd5...`、同一 fixture、同一 `colima-imv2-vapor5` context，在各自随机项目真实运行且无 NET_ADMIN：两版均 4/4 认证、1/1 ACK、0 开房、owner SQL 各仅一行 seq1。私有证据分别在 `/Users/yyl/.codex/virtual-actor-builds/capacity-canary-main-corrected-20260924/result.json` 与 `/Users/yyl/.codex/virtual-actor-builds/capacity-canary-candidate-corrected-20260924/result.json`，均 `passed=true`，项目卷已清理。这是功能 canary，不是容量采样。

新增 `--canary-connections 100 --canary-recovery --layout mixed` 使用独立、固定 SHA `c7d7dbcb492d7f4c05108165f02f007d26effe3bee61fc3af76450b388f353e3` 的 10 秒派生场景：每秒 1 次发送、两类现有批查询各 2 次，不执行 roomLog/sync。它要求 100 个认证、零业务/连接错误、两类批查询均有成功房间项、所有发送都获 ACK，且 owner SQL 消息数、房间序号和授权/route 与客户端凭证一致。默认单发送 canary 的连接数与验收仍保持不变。2026-09-24 同一 fixture `/Users/yyl/.codex/virtual-actor-builds/capacity-fixtures-v2/multi-owner`、共用 Release loader `72d27c4e9358483705136a68ada2a04d2673bf6b566978065aac5bc7f3221364` 在 `colima-imv2-vapor5` 上依次验证冻结 main f1 与 candidate 576：两版均 100/100 认证、9/9 ACK、两个 owner 合计 9 条消息、RoomSyncStateBatch 与 RoomLatestVisibleBatch 各 60 个成功房间项、零新开房与零错误。证据在 `/Users/yyl/.codex/virtual-actor-builds/capacity-recovery-canary-main-low-20260924/result.json` 和 `/Users/yyl/.codex/virtual-actor-builds/capacity-recovery-canary-candidate-low-20260924/result.json`，各自私有 Compose 项目已清理。首次较高负载的 main 尝试保留在 `capacity-recovery-canary-main-20260924`，当时另一套测试争用 4 CPU VM，20 次发送中 1 次获可重试 `UNAVAILABLE`，严格判失败；没有把它冒充通过。两次成功运行仅是功能验证，未采容量值。

每次 Gateway 启动后，runner 只读采集 Docker 的 NCPU/MemTotal/KernelVersion、boot ID、项目 PG/Gateway 容器 ID 与 StartedAt、三库的白名单 PostgreSQL 设置和 fixture 数量，保存在私有 `runtime-provenance.json` 并记录 SHA。功能 canary 可在其他机器运行但标记为非正式采样；正式 measurement 要求 Docker 实际 4 CPU、16 GiB 档且 `pg_stat_statements.track=all`。上述功能 VM 实测 4 CPU、11.66 GiB，故结果 `formalSamplingEligible=false`。

同一 runner 的显式 `--measurement-workload hot|same-owner|mixed|cold|fault` 使用相同的 source、Release products、fixture 校验与私有 Compose 隔离。另加 `--measurement-connections N`、可选 `--measurement-rate-scale R`；必须提供独立修正 loader。它从固定 template 生成并记录新 scenario SHA，不改 `capacity-main-v1.json` 中历史 scenario digest；三阶段严格为 120 秒 warmup、300 秒 steady、60 秒 cooldown。hot fixture 必须恰一房，same-owner fixture 必须恰一物理 owner。mixed 生成 send/roomLog/syncPull/receipt、`RoomSyncStateBatch` 和 `RoomLatestVisibleBatch` 流量；仅在 steady 阶段两类请求均返回已验证的成功房间项时才标记 `batchRecoveryQueriesCovered=true`。runner 拒绝没有这两类调度能力的旧 loader 二进制。

cold 使用至少 7500 个 fixture 房间、全部 fixture 用户连接和固定 20 条消息/秒；candidate 在结束时查询每个 owner 的 `room_activation_leases`，必须看到真实 `expires_at IS NULL` 的释放行，且 cooldown 内 active rooms gauge 下降，不能只凭运行时长推断回收。frozen main 没有 Actor 租约表，明确记作不适用。fault 使用两 owner mixed fixture 和纯 `RoomSyncStateBatch`/`RoomLatestVisibleBatch`，各 20 请求/秒；steady 第 60 秒以 10 秒优雅截止停止 owner00，20 秒后启动。实际停机区间两类查询均须同时产生成功与 retry 房间项，恢复后连续 3 个一秒区间两类成功项递增且 retry 不再增加。停机期间跳过 owner00 cgroup 采样；跨重启的 owner00 CPU/进程生命周期内存峰标为不可比较。`pg_stat_statements` 若 reset、计数下降或既有语句消失则失败。fault 主版 freeze 计量单位为成功房间查询项/秒，消息发送、确认与持久效果均须为零。这些场景目前只完成静态和原生场景验证，未作真实容量采样。

负载器每连接对两类恢复批查询合计最多一个在途请求，每个批次至多 32 个 fixture 房间。`--recovery-batch-timeout-seconds` 默认 10、允许 1 到 60；到期会关闭该连接。故障窗口可显式选 45 秒以覆盖服务端 30 秒调用截止，但普通 mixed 保持 10 秒。scenario 进度每秒输出两类批查询的累计成功、retry、unavailable 房间项；故障证据需取注入前后差值，不能把累计总数误作窗口值。

测量时 PG16 在每个专属数据库启用 `pg_stat_statements`，阶段边界只读快照计算 db/user/queryid delta，不 reset；数据是整库 SQL，包括后台和少量观测查询。每 5 秒采集每容器 cgroup v2 累计 CPU、`memory.current`、`memory.peak`、`/proc/1/status` 的 VmRSS 和私有 Gateway `/metrics`，阶段边界也采集。`memory.current` 含文件 cache，不称为 RSS；进程 RSS 只代表 PID 1，PostgreSQL 子 backend 不在其中。输出 `measurement-{warmup,steady,cooldown}.json`、原始 `measurement-snapshots.json`、脱敏 `measurement-compose-settings.json` 及 native 负载报告。Gateway `/metrics` 保持生产规定的容器内 loopback 监听，采集器用 pinned Swift 镜像内的 Python3 经 `docker exec` 读取，不发布 metrics 端口。结果记录随机 project、镜像 ID、二进制/lockfile/fixture/scenario/compose 摘要。采样边界依赖 loader 经 `stdbuf` 输出的 phase marker，观测窗口偏离 120/300/60 超过 10 秒即失败，并保存实际窗口与边界抓取耗时供审查。结果还核对所有连接认证、消息全 ACK、无新开房、owner 房间数不变及持久消息数与 ACK 数相等。

正式顺序由单机独占操作者控制：每个 workload 先跑三次 frozen main calibration，当前由 `assess_v2_virtual_actor_capacity.py freeze` 传入三次 `--main-run DIR` 与新的 `--output`，按已固定的回归策略从 main 中位数派生预算；底层 `freeze_v2_virtual_actor_capacity_calibration.py` 仍可接受显式数字阈值 JSON，但不替代本次固定的策略。脚本核对三份 main 证据的 fixture/scenario/loader 完全相同、steady 300 秒完成和已确认工作量 CV 不超过 10%（fault 为成功房间查询项，其他为消息 ACK），才生成 0600 freeze 文件。candidate 测量必须带 `--measurement-freeze-file` 且 identity/hash 匹配，保证 candidate 结果不能先于 main 冻结。随后按协议执行 `main,candidate,candidate,main,main,candidate` 三对交错。2026-09-24，hot 场景已完成三轮 main 校准并冻结数字预算，main/candidate 交错采样正在执行；其余四种场景仍待正式运行，当前进度与失败尝试见[基线协议](v1-baseline-protocol.md)。
