# 显式单次 Gateway 恢复 burst driver

状态：2026-09-28 非空积压注入的2连接隔离贯通已通过，整体句柄52165 exit0。1个房间真实注入1条消息，两原订阅均从序列0追到1、gap为0；专属服务与PG已清理。首次编译失败日志保留。10k首轮39469在注册准备阶段失败，尚无10k连接恢复或完整F18结论。

protocol44 后业务发送走 Account typed HTTP，Gateway TLS 负责认证、订阅和同步读取。
消息延迟包括 HTTP 受理/原证明核对；旧 TCP-only 发送吞吐不能作为当前混合链路容量证据。
工具每条发送保留冻结身份，遇不确定结果有界查询；失败不以新身份自动补发。

实现位于 `IMV2Server/Sources/IMV2GatewayLoadGenerator/main.swift`。默认模式不启用
burst，既有随机重连场景保持原行为。此模式复用真实 TLS/认证、房间订阅及游标补拉，
不是 App 调度器模拟器，也不验证客户端 2k 持久 backlog。

## 参数和执行边界

- `--recovery-burst 1`：初始认证和房间 warmup 后，仅执行一次整体断线/恢复。
- `--recovery-burst-workers 128`：恢复并发工人数，范围 1–本轮 `--connections`（最高 10000）。
- `--recovery-burst-max-attempts 1`：每连接最多尝试 1–3 次；重试有短暂、按连接错开的间隔。
- `--recovery-burst-offline-seconds 0`：断线后等待 0–300 秒，可让独立 peer 产生真实持久积压。
- `--recovery-burst-observe-seconds 60`：屏障释放后共用 1–300 秒截止，包含连接、认证和追赶观察。
- `--recovery-burst-offline-messages-per-room 1`：全部旧socket关闭后，按唯一订阅房间注入真实typed HTTP消息；默认0关闭，最多16，整阶段最多100000条。冻结原命令身份与期限，校验原回执序列严格高于断线前游标。
- `--recovery-burst-offline-write-workers 8`：注入滑动并发1–32，房间去重后选择其真实成员凭据。
- `--recovery-burst-offline-write-deadline-seconds 60`：注入阶段实际单调时钟截止1–300秒；超时取消并排空请求，失败计入报告且不能成功退出。
- 原 `--connections` 范围仍是 1–10000；`--event-loops` 范围仍是 1–4。

必须提供 scenario，所有 phase 的 `reconnectPercentPerMinute` 必须为 0，且开启
`--room-log-reads 1`。凭据必须含每个目标已解析的 `targetRoomIDs`，数量与
`--targets-per-connection` 一致。driver 不在恢复时临时新建房间或替换观察基线。

所有关闭先提交、再统一等待关闭结果；所有恢复 workers 到达屏障后一起释放。
默认 workers 从有界队列领取连接，因而后续连接实际启动会晚于第一批。F18 同刻恢复模板显式
设置 workers=connections，让全部连接各有一个屏障参与者；单机线程/CPU 调度仍会使实际
启动存在分布。报告保留每连接每次
实际开始偏移，不能把共同屏障解释为 10000 次 TLS 同时开始。若需要跨进程同步，当前
屏障只覆盖一个 driver 进程；partitioned shell 的共同 epoch 不提供跨进程恢复屏障。

重连沿用断线前房间 cursor；重新订阅取得权威 high watermark 后实际补拉。恢复时不会
使用 tail 初始化跳到新水位。已认证连接与已追赶到订阅目标分别计量。观察截止内无订阅
目标、断开或 cursor 未到目标均归未完成；任何连接认证未成功或房间未完成会令此运行
返回失败并保留报告。失败/取消的连接在 worker 返回前关闭，初始 socket 建立及认证
都受原共用截止约束；整个运行最后仍排空剩余连接和 EventLoopGroup。

## 复用命令模板

以下仅是准备好隔离环境后的命令模板，尚未执行。`<binary>` 是预先构建的
`IMV2GatewayLoadGenerator`，不得将开发凭据/部署作为默认目标。

```bash
<binary> \
  --host <isolated-gateway-host> --port <tls-port> --server-name <certificate-name> \
  --account-base-url <isolated-account-https-url> --ca-path <test-ca.pem> \
  --credentials <10000-device-credentials.jsonl> --report <new-report.json> \
  --revision <exact-source-revision> --connections 10000 \
  --ramp-per-second 200 --ramp-batch-size 100 --event-loops 4 \
  --targets-per-connection 1 --target-offset 1 --room-log-reads 1 \
  --room-log-initial-cursor tail --room-log-read-trigger availability_hint \
  --sync-reads 1 --messages-per-second 0 \
  --scenario IMV2/load-scenarios/high-active-50000-uuid-connection-canary.json \
  --recovery-burst 1 --recovery-burst-workers 10000 \
  --recovery-burst-max-attempts 1 --recovery-burst-offline-seconds 10 \
  --recovery-burst-observe-seconds 60 \
  --recovery-burst-offline-messages-per-room 1 \
  --recovery-burst-offline-write-workers 8 \
  --recovery-burst-offline-write-deadline-seconds 60
```

环境须包含真实隔离 Account/Gateway、control/owner PostgreSQL、所需消息基础设施、
受信测试 CA、足够 FD/端口及不会成为瓶颈的负载机。凭据有效期须覆盖初始 ramp、warmup、
离线与恢复窗。模板通过显式离线注入产生积压；省略注入且没有独立peer写入时仍不能证明积压恢复。

## 报告和限制

JSON 的 `recoveryBurst` 包含屏障墙钟、实际单调时钟开始偏移、工人数、attempts/失败、
认证成功与未成功、实际观察耗时，以及观察期间的 Sync/room pull 请求、可重试拒绝和
批量恢复计数。`attemptAmplification` 为连接尝试数除以请求连接数；这不是业务工作整体
重试放大系数。`roomsWithCursorBacklog` 区分确有 cursor 差距的目标与空恢复。
`cursorTargetUncompletedOrUnknownRooms` 必须为0。启用注入后，driver和专用Python入口均要求全部原订阅逐条满足 `beforeSequence < injectedThrough <= recoveryTarget <= appliedSequence` 且 `remainingGap == 0`。`offlineWritesRequested/Accepted/Failed` 记录真实写入结果，`offlineInjectedRooms`按唯一房间计数，`offlineWriteReceipts`与`cursorProgress`保留回执序列及原连接映射；2个连接共用1个房间时不重复注入、仍核验2条订阅。

目标只代表各连接重新订阅时取得的水位；不证明整个观察窗内所有新增消息都已经可见。
HTTP submit/reconcile、资源恢复、App account retry token budget、公平性与 2k backlog
仍须独立实测，不能由这个 TLS driver 或此前原始字节慢连接实验推导。

## 本机独立临时环境专用入口

`scripts/verify_v2_live_account_authorization.py --output <新的本地证据目录> --gateway-recovery-connections 2`
先走与 10000 相同的真实注册/开房/恢复路径；将连接数改为 10000 才是 10k 真实 TLS
clients。该参数范围 2…10000，独占模式，不能与 App/UI、远程环境或其他授权故障参数混用。
脚本会构建当前 Account/Gateway/driver，创建独立临时 PostgreSQL 和测试 CA/HTTPS，选择临时
Gateway 端口。它不启动开发 Compose、不读取 `.env`，也不创建模拟器。

凭据使用现有真实注册脚本，单批最多 5000，私有 JSONL 权限 0600；原注册取消恢复 sidecar
保留到统一 cleanup。注册耗时造成 access token 过期时，使用原设备 refreshCredential 调用
现有刷新脚本，保留原注册/撤销恢复证据，不延长签名或重建身份。各阶段开始前要求最早到期的凭据仍覆盖该阶段总预算加50秒余量；10000连接时预热要求575秒、burst要求705秒。刷新一次后仍不满足即失败。默认 token 900 秒有效期
不会被脚本改大。所有秘密只在临时目录；证据仅保存报告、阶段日志及非秘密源码 hash。

现有非 burst canary 先通过 typed directRoom HTTP 操作真实开房，报告每个 connectionIndex
的 room cursor；脚本验证连接总量、唯一原账号/设备及每连接恰好一个合法房间映射后，才
写入原凭据的 targetRoomIDs。缺项、重复索引、越界或过期拒绝继续。随后执行一次整体
断线/屏障恢复，要求全部 requested clients 重新认证且无未知/未完成 cursor target。
小 N 显式使用对应 worker 数，不沿用默认 128。共享 canary 在专用临时副本中采用 300 秒
warmup、10 秒无发送阶段。阶段总预算按连接数派生：两段 `ceil(N/200)` 分别用于初始连接和工作启动节奏，另加60秒建立延迟预算、300秒房间预热、10秒场景、20秒排空、10秒保持、`0.05*ceil(N/100)` 秒关闭节奏及20秒报告/清理预算，整体向上取整。burst另加60秒离线写入、10秒离线等待、60秒恢复观察；10000连接分别为525秒和655秒。速率设置只约束启动间隔，不保证握手耗时上界，超过总预算明确失败。

仅该临时环境将注册 HTTP 限流容量设为 100000/窗口、room command/admission 容量设为
10000/窗口，Gateway 连接硬上限仍为现有 10000；权限、CAS、原操作证明、token 校验不变。
这不是生产容量建议。实际机器 FD、CPU/RSS、PG 预算不足时运行会失败，不以删断言通过。

只有所有原订阅非空追赶通过后，`gateway-recovery-scope.json`才写入`connectionRecoveryOnly=false`、`backlogWasInjected=true`；`fullF18Passed`仍为false，因为本地贯通不能替代App完整故障矩阵及部署容量。新增FD前置条件为2*N+1024，公开构建输入SHA256覆盖服务端/Actor/Core、协议/schema和相关脚本，不读取.env或临时密钥。当前隔离同库配置预算Account16、Gateway72，总88低于临时PG160；这不是生产容量建议。
它记录 baselineRevision/workspaceDirty（脏工作区不冒充 clean HEAD）及上述公开构建输入的 SHA256；完整复现仍需保存对应源码和环境配置。首次2连接命令在构建阶段退出，日志为 `/tmp/weak-network-nonempty-recovery-small2/build.log`。修复后集中验证输出 `/tmp/weak-network-nonempty-recovery-small2-confirmation`：注册、预热、恢复分别1.061秒、22.903秒、96.208秒，均exit0且未超时；恢复尝试2次、放大系数1。原始报告、范围、输入指纹、阶段摘要和清理日志均保留。

各子阶段均保留 `gateway-recovery-stages.json` 中的阶段名、退出码、耗时、截止预算和超时标志；注册/刷新原始日志随私有目录清除，摘要不复制凭据、请求体或命令行。失败时终止本次以 `start_new_session` 创建的进程组，即使父进程已退出也清理其子进程。上述预算与正常清理已随smallN2集中贯通；失败进程组清理分支本轮未注入故障，不作为该分支运行证据。

10k首轮输出 `/tmp/weak-network-nonempty-recovery-10000`：注册阶段exit4，503共10次，未进入连接恢复。专用注册准备现固定2并发，与生产密码哈希准入上限2一致；manifest记录两个值。通用prepare默认仍16，生产配置与恢复连接数10000不变。此修复尚未重跑。
