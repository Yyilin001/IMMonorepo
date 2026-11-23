# IM V2 网关

`IMV2ServerApp` 是独立的 V2 TLS 网关，不依赖外部路由、数据表、线协议或迁移路径。

跨组件数据流，以及实现证据与发布证据的区别，见[当前系统架构](../docs/current-system-map.md)和 [V2 文档入口](../IMV2/docs/README.md)。

阿里云对象存储的解耦装配、环境配置和真实验证入口，见 [OSS 接入与验证](../docs/proposals/aliyun-oss-integration.md)及 [oss.env.example](oss.env.example)。

## 部署准备

服务端使用 Swift 6.4.2，macOS 环境要求 macOS 26.2 或更高版本，并固定使用 Vapor 5.0.0-beta.3。Linux 编译和 CI 使用同一份 Swift 6.4.2 Jammy 镜像，部署使用同版本的 Jammy slim 运行镜像。数据库所有权、关闭顺序、依赖边界与验证要求见 [Vapor 5 迁移合同](../IMV2/docs/00-foundation/vapor5-migration.md)。

1. 创建空 PostgreSQL 数据库并安装唯一的当前结构：`psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f IMV2/sql/schema.sql`。部署前，在隔离 Docker PostgreSQL 上运行 `bash scripts/test_v2_postgres_schema_bootstrap.sh`，检查空库初始化、当前结构合同，以及结构导出/恢复等价性。使用现有 PostgreSQL 时，设置 `IMV2_SCHEMA_BOOTSTRAP_NATIVE=1`、`PGHOST`、`PGPORT`、`PGUSER` 和必要凭据，将 PostgreSQL 16 的 `psql`、`pg_dump` 加入 `PATH`。原生检查会创建并删除两个唯一命名的测试数据库，要求具有建库权限。尚未发布的项目只安装当前结构，历史升级脚本和混合版本部署路径已移除。
2. 通过部署密钥存储提供 PEM 证书链和私钥文件。
3. 提供至少 32 字节的随机访问令牌 HMAC 密钥，使用 Base64 编码。网关仅持久化高熵不透明访问令牌的 HMAC 摘要。
4. 部署独立可信的账户/设备凭据签发服务，为其提供独立的随机 32 字节 ChaChaPoly 重放信封密钥。它在验证账户认证因素后调用 `V2PostgresDeviceCredentialService`；网关进程不得持有签发方的信封密钥。网关不接受客户端载荷提供的用户 ID。只有注入生产 `V2AccountAssertionVerifier`、TLS/限流策略、入口授权与客户端限流密钥，以及密钥供应机制后，才能在账户服务监听器上挂载 `V2VaporDeviceCredentialRoutes`；不得注册到实时网关监听器。

   选定的主认证因素是生产 WebAuthn 验证器。现有 `V2HMACAccountAssertionIssuer` 提供有效期 90 秒、绑定设备的签发交接，本身不验证通行密钥。备用 `V2PasswordAccountRoutes` 保存 Argon2id PHC 验证记录，并通过有界密码工作器，以相同计算成本拒绝未知账户。账户服务还需要独立的推送端点信封密钥，以加密保存不透明 APNs 令牌；不得将该密钥放入 iOS App 或客户端可见配置。
5. 为 Gateway 和 Account 提供 `IMV2_ROOM_ACTOR_CONFIGURATION_FILE`。Gateway 可以承载房间或使用仅调用身份，Account 必须使用仅调用身份。按[房间虚拟 Actor 合同](../docs/reviews/room-virtual-actor-contract.md)提供节点签名密钥、私有 CA 信任和匹配 DNS 的双向 TLS 证书。本地服务脚本会自动创建隔离测试身份。
6. 设置 [`.env.example`](.env.example) 中所有必需变量，再运行 V2 应用。

打包部署前，检查仓库中的三份环境示例仍与严格的运行时构造器匹配：

```sh
./scripts/check_v2_runtime_env_examples.sh
```

## 单活 Room Core 部署

用一个 `IMV2ServerApp` 进程同时运行 TCP Gateway 和 Room Core。Room、用户和控制存储共用一个 PostgreSQL database 的 `im_v2` schema。所有进程使用相同的 Room、用户存储 ID，业务侧只配置一个 Room 存储和一个用户存储。按上文安装当前 schema，再安装实时 journal。

```sh
bash IMV2/scripts/install_v2_realtime_journal.sh -- "$IM_V2_DATABASE_URL"
python3 IMV2/scripts/prepare_v2_room_actor_configuration.py --single-core \
  --identity-seed "$IMV2_DEPLOYMENT_UUID" \
  --output-dir /run/imv2-actors --mount-root /run/im-v2-room-actor \
  --host gateway=gateway.internal:7337 \
  --caller account=account.internal:7338 \
  --caller operator=operator.internal:7339 \
  --shards rooms-primary --user-buckets users-primary
```

首次部署时为 `IMV2_DEPLOYMENT_UUID` 生成并保存一个 UUID，后续生成配置时沿用该值和 Core 名称，以保留数据库记录的 Core 逻辑身份。每个进程只挂载自己的凭据目录。配置 Gateway 的 `IM_V2_GATEWAY_NODE_ID=gateway`，Room 创建池为 `rooms-primary`，用户写入桶为 `users-primary`。空库写入 epoch 1 的 `im_v2.user_shard_router_configuration`，并按部署容量预置 `rooms-primary` 的准入租约。Room、用户和控制存储使用安装到主库中的同一个 journal 源。数据库总连接预算要给 Core 权限会话留一条连接。

生成的 `singleCore` 文档固定一个 Core，并包含各调用方的 mTLS 身份。调用方在固定地址验证 Core 的当前进程身份。收件游标和同步数据保存在主库。

### 单台独立接入 Gateway

Core 与接入层分开部署时，可以只运行一台面向客户端的 Gateway。首次生成配置的示例如下。

```sh
python3 IMV2/scripts/prepare_v2_room_actor_configuration.py --single-core \
  --output-dir /run/imv2-actors --mount-root /run/im-v2-room-actor \
  --host room-core=room-core.internal:7337 \
  --gateway gateway-0=gateway-0.internal:7337 \
  --caller account=account.internal:7338 \
  --shards rooms-primary --user-buckets users-primary
```

把客户端 TLS 流量全部送到 `gateway-0`，Core 的客户端监听只绑定回环地址。两个进程分别使用自己的节点身份和凭据目录。按目标连接数设置 Gateway 的 `IM_V2_MAX_CONNECTIONS`，并将 `IM_V2_RATE_LIMIT_MAX_TRACKED_IDENTITIES` 至少设为该上限的两倍。例如 5 万在线的测试可设为 60,000 和 120,000，环境变量中填写不带逗号的十进制整数。为监听器、内部 RPC 和数据库连接预留文件描述符。单台接入节点重启时，其全部客户端都要重连并恢复订阅。

### 增加接入 Gateway

独立部署 Core 时，配置中的唯一 `--host` 指向该 Core，每台接入节点使用各自的 `--gateway`。已有 TCP 连接继续由原 Gateway 持有，负载均衡器将新连接分给就绪的节点。扩容前后应看到相同的 Core 写入代次和实例标记，房间仍归原 Core。

以下示例给上一节的单台独立接入部署新增 `gateway-2`。先让现有节点能通过内部 DNS 解析它的地址。在保管完整私有部署目录的主机上运行配置工具，列出原有 Core、所有调用方、所有已登记的 Gateway，再追加新节点。沿用首次部署的存储 ID、策略分区数、房间容量和进程内凭据挂载路径。

```sh
python3 IMV2/scripts/prepare_v2_room_actor_configuration.py --single-core \
  --extend-from /run/imv2-actors --output-dir /run/imv2-actors-next \
  --mount-root /run/im-v2-room-actor \
  --host room-core=room-core.internal:7337 \
  --gateway gateway-0=gateway-0.internal:7337 \
  --caller account=account.internal:7338 \
  --gateway gateway-2=gateway-2.internal:7340 \
  --shards rooms-primary --user-buckets users-primary
```

1. 输出目录必须是新路径。工具会沿用 CA、既有节点的签名身份和 TLS 凭据，并为新增 Gateway 签发凭据。为每个既有节点分发它自己的新 `configuration.json`，在已挂载的节点目录中写入临时文件后原子重命名。Core 和接入 Gateway 会重新读取已授权的 Gateway 名单，扩容期间可继续处理现有连接。
2. 启动新 Gateway，使用相同的 `IMV2ServerApp`、主库和存储 ID，将新节点专属目录挂载到 `/run/im-v2-room-actor`，设置 `IMV2_ROOM_ACTOR_CONFIGURATION_FILE=/run/im-v2-room-actor/configuration.json` 和 `IM_V2_GATEWAY_NODE_ID=gateway-2`，配置客户端 TLS、访问令牌密钥和指标端口。
3. 在 Core 和各 Gateway 的 `/metrics` 检查 `im_v2_actor_realtime_reachable_nodes` 已覆盖新增节点，确认新 Gateway 的 TLS 就绪后再将其接入负载均衡。全局持久任务指标由 Core 导出，各 Gateway 导出本机连接、设备撤销积压、同步准入和连接池指标。保存完整的新私有目录，作为下一次扩容的 `--extend-from` 输入。

热更新支持追加接入节点。替换既有节点的身份或地址、轮换证书或替换 Core，需单独安排部署。

### Core 停机和异常恢复

正常替换 Core 时，给持有房间写入权的进程发 TERM，等待进程和业务 SQL 全部退出。成功排空后 Core 会清除当前标记，后续进程使用递增的 epoch。异常退出或 PG 权限会话断开时，数据库保留旧进程标记并阻止新 Core 接管。

崩溃恢复前，先确认旧进程退出且不会被编排器重拉，再确认主库已无该进程的 SQL 会话。旧进程的标记来自 `im_v2.room_core_writer.incarnation`，会话的 `application_name` 为 `imva:` 加去掉连字符的小写 UUID。用有写权限的维护会话执行以下事务，绑定已排除的 UUID。只在返回一行且提交成功后启动新的 Core。

```sql
BEGIN;
SELECT pg_advisory_xact_lock(1229805106, 1);
UPDATE im_v2.room_core_writer
   SET incarnation = NULL
 WHERE singleton AND incarnation = :'excluded_incarnation'::uuid
   AND NOT EXISTS (
       SELECT 1 FROM pg_stat_activity
       WHERE datname = current_database()
         AND application_name = 'imva:' || replace(incarnation::text, '-', '')
   )
RETURNING epoch;
COMMIT;
```

性能对照使用[改造前基线](../IMV2/docs/09-capacity/single-room-core-baseline.md)。原生测试工具的 `--single-core --nodes 2 --kind candidate --allow-small-canary` 参数可运行双 Gateway 收发验证。第一个 Gateway 承担 Core，其余 Gateway 使用接入身份。

## 持久任务的运维重放

`IMV2OperatorServerApp` 是独立、仅监听回环地址的控制面程序，每次重放一条明确暂停的房间发件箱或扇出投递记录。它使用专属访问令牌密钥和操作主体，不共享公开网关监听器，并将重放审计证据与状态变更原子写入。

配置见 [`operator-replay.env.example`](operator-replay.env.example)，操作步骤见[运维重放手册](../IMV2/docs/10-operations/durable-work-operator-replay.md)。不要直接公开该端口，应通过已批准的堡垒机或双向 TLS 运维代理访问。

## Web 管理服务

`IMV2AdminServerApp` 是独立、仅监听回环地址的管理 HTTP 服务，提供管理员登录、用户查询、账户禁用和操作审计。管理员身份独立于普通 IM 用户，通过现有 Policy Owner 禁用用例执行业务变更。浏览器不持有 Operator 密钥。

部署需显式安装 [`admin-schema.sql`](../IMV2/sql/admin-schema.sql)，按 [`admin.env.example`](admin.env.example) 提供管理员哈希配置与独立 Actor 调用身份，并由同域 HTTPS 代理托管 [`IMAdminWeb`](../IMAdminWeb/README.md)。完整配置、权限、未知结果恢复和验证命令见前端 README。

## 账户认证服务

`IMV2AccountServerApp` 是独立、仅监听回环地址的进程，负责账户认证因素验证与设备凭据签发，不属于实时网关进程。使用 [`account.env.example`](account.env.example) 配置，安装相同的 V2 数据库结构，再启动：

```sh
swift run --package-path IMV2Server IMV2AccountServerApp
```

在回环监听器前部署受管理的 HTTPS 反向代理。代理持有公开证书，并在转发前覆盖账户入口证明和客户端地址请求头。账户进程在该认证边界之后执行跨副本请求预算，避免直接回环调用访问高成本接口。iOS App 只接受 HTTPS 账户基础 URL，不得直接指向内部 HTTP 监听器。

密码认证使用 Argon2id v19：64 MiB 内存、三轮计算、一个并行通道、16 字节随机盐和 32 字节摘要。输入长度为 12–1024 个 UTF-8 字节，拒绝 NUL，不裁剪、不规范化、不截断。未知账户的固定模拟验证记录使用相同策略，无需配置模拟哈希环境变量。应用持有的单一工作池允许两个 KDF 调用并发；饱和时返回带 `no-store` 和 `Retry-After` 的 503。已运行 KDF 即使取消，也要到计算返回后才释放名额。

不支持或旧版 bcrypt 记录执行相同的 KDF 工作，但不能签发密码断言，也不会静默重新哈希；已有记录保留。这套从零构建的部署需要重建测试账户，或通过独立可信的账户恢复后才能重设旧密码，仅知道与 bcrypt 等价的前缀不足以恢复。

账户断言 HMAC 密钥和设备凭据重放信封密钥只属于账户服务，不能进入实时网关。密码验证在 KDF 前，先在 PostgreSQL 中原子扣减按规范账户身份计算的尝试预算，该预算由账户服务副本共享。未完成尝试仍计入预算，认证成功后重置。最大失败次数、窗口和锁定时长由必需的 `IM_V2_PASSWORD_LOGIN_*` 配置提供；锁定返回带 `no-store` 和 `Retry-After` 的 429。

每个账户请求通过入口证明与唯一的入口生成客户端地址验证后，都受 `IM_V2_ACCOUNT_CLIENT_RATE_LIMIT_*` 固定窗口预算限制。PostgreSQL 仅保存使用独立 `IM_V2_ACCOUNT_CLIENT_RATE_LIMIT_HMAC_KEY_BASE64` 推导的 HMAC 摘要，不保存明文地址；过期窗口按有界批次删除。生产入口仍需提供已批准的可信代理链及外层 DDoS/滥用防护；审计、恢复和已实现的账户禁用运维路径仍需生产批准及演练。

客户端通行密钥流程已有完整的挑战/断言传输边界，但该程序尚未挂载公开 WebAuthn 端点；开放端点需要经过审计的服务端验证器和一次性挑战存储。当前可部署的初始账户路径为密码备用认证。“账户安全”提供密码修改和离线恢复码，接口行为、断言版本、迁移与验证见[生命周期合同](../docs/reviews/account-authentication-lifecycle.md)。

每个账户请求必须携带 Base64 入口授权密钥和由同一 HTTPS 代理注入的有效客户端地址。账户进程在限流前拒绝直接回环请求、重复请求头和无效地址，探针及工具也不得绕过代理。仓库中的本地 Nginx 配置从直接连接对端获取地址，并显式覆盖转发地址和入口授权头。生产拓扑位于其他七层代理之后时，必须显式配置并验证可信代理链，不能直接复制任意转发地址到该请求头。

### 原生客户端的本地开发流程

开发时保持 iOS App 原生运行，使用 Docker 启动其账户依赖：

```sh
bash IMV2/scripts/run_v2_local_account_stack.sh
```

脚本在被 Git 忽略的 `IMV2/.env.local` 中创建本地专用密钥，默认启动一个 Gateway/Core、一个 PostgreSQL 主库以及 Account、Operator 和 Nginx。房间与用户数据共用 `im_v2`，配置与数据库卷分别使用 `IMV2/local-room-actors/single-core` 和 `v2-local-single-core-postgres`。macOS 回环地址仅发布 `https://localhost:8443` 和 TLS 网关 `localhost:7443`。Nginx 与账户进程共享容器网络命名空间，账户进程绑定 `127.0.0.1:8444`，数据库和内部 HTTP 端口留在容器网络。

开发脚本在宿主机保管开发 CA 私钥，Nginx 和网关仅挂载叶证书、叶私钥与公开根证书。首次运行或从旧代理迁移后，将生成的 `IMV2/local-ca/root.crt` 导入所选 iOS 模拟器并启用完全信任。Debug App 已默认使用 `https://localhost:8443`。辅助脚本会输出准确的停止命令，不创建 Python 虚拟环境，也不修改宿主机数据库。

网关绑定 TLS 端口前检查数据库结构是否就绪。它要求 TLS 1.3，配置缺失时直接拒绝启动，不使用开发默认值。

本地服务就绪后，验证 HTTPS 账户认证因素、设备凭据交接与 TLS 网关，全程不打印断言或凭据：

```sh
bash IMV2/scripts/verify_v2_local_account_stack.sh
```

冒烟检查在本地 Docker 卷中创建一个唯一命名账户，不访问公开端点，不将令牌写入磁盘或输出。本地隔离 Compose 项目也会验证同一套服务；该证据仅覆盖本地服务，不代表生产部署批准。

## 普通私聊跨房间合批

Room Host 启动时读取 `IM_V2_MESSAGE_WRITE_CROSS_ROOM_LIMIT`，取值为 1 到 16，默认 1。空闲写连接从同一分片的就绪队列领取完整的房间轮次，单批消息数受该参数限制。只有一个就绪房间时立即执行。跨房间事务只包含已授权且无需变更策略的普通私聊，沿用请求的截止时间和 64 KiB 保留字节预算。

每个房间的序号、消息、永久完成记录和投递 outbox 在同一 PostgreSQL 事务中提交。确认提交后分别返回各自的 ACK。停机把上限改回 1 即可回退，无需改动分片映射或数据库 schema。`im_v2_send_operation_store_cross_room_commits_total` 按同一事务中的房间数计数。

容量测试可给发送进程设置 `--message-audit-max-rows N`。结束时压测器将房间、发送者、操作 ID、返回的消息 ID 与序号写到 `<report>.messages.csv`。N 限制每个进程的记录数，超过预算时审计失败。将每个发送进程的文件传给 `--ledger`，将每个权威房间 database 的 libpq service 名传给 `--room-service`，逐条核对 ACK 和永久完成记录，同时统计结果未知但已提交的操作。[对账脚本](../IMV2/scripts/verify_v2_load_message_audit.py)

## 运维说明

- `IM_V2_MAX_CONNECTIONS` 限制全部已接受 TLS 连接，包括未认证客户端。`IM_V2_MAX_FRAME_BYTES`、Protobuf 深度、在途请求、入站排队字节和排队块数量均为单连接硬限制；队列压力会关闭连接，客户端通过同步恢复。
- `IM_V2_AUTHENTICATION_TIMEOUT_MS` 是从接受连接到认证完成的绝对期限。缓慢发送碎片不能延长期限。认证与连接准入成功后，先结束期限，再执行同一已解码批次中的后续命令。
- `IM_V2_IDLE_TIMEOUT_MS` 关闭无入站活动的 TLS 会话。前台客户端发送应用心跳，后台客户端依靠重连与同步。期限基于最近收到的字节，包括不完整帧；它不限制命令执行或组帧完成时间。
- 排队帧实际写出时会再次检查前台推送授权。认证过期或连接撤销使待发送快速路径帧失效；客户端通过持久房间游标恢复缺失事件。
- 关闭时先停止并排空连接工作，期间保留依赖和 EventLoop；随后排空工作器与辅助服务，最后释放 EventLoop。超过关闭宽限期时使进程失败，不在未完成工作仍依赖资源时提前释放资源。
- `IM_V2_WORKER_BATCH_SIZE` 与 `IM_V2_WORKER_POLL_INTERVAL_MS` 限制并调度当前持久工作器，包括个人事件投影、房间唤醒、审核、媒体和清理工作。
- 网关 PostgreSQL 工作拆分为显式的前台、同步、投递、投影和维护连接池；每个 EventLoop 上的连接数总和仍受原聚合上限约束。独立的短准入队列会在 Fluent 的较长连接池等待超时之前返回可重试的 `SERVER_BUSY`。投影领取并发、已受理消息批量投影、同步提示合并、指标、灰度与回滚见[单节点性能运维手册](../IMV2/docs/10-operations/single-node-performance-rollout-runbook.md)。
- 个人快照直接从个人投影版本读取载荷，公共内容通过房间日志恢复。不可变房间消息状态仍保留有界压缩与垃圾回收，保留配置为 `IM_V2_MESSAGE_PROJECTION_STATE_RETENTION_SECONDS`。见[个人快照运维](../IMV2/docs/10-operations/personal-snapshot-runbook.md)。
- 私聊和群聊公共消息使用有序房间日志。消息受理与不可变回执在 ACK 前共同提交，重试返回原结果；内容由房间游标恢复。个人状态仍通过持久用户状态事件发件箱与用户投影传播。两条路径都不使用已退役的私聊扇出选择器或投递计划表。
- 房间 Owner / Relay 通过签名 Actor 投递到持有已认证设备连接的 Gateway。账户成员覆盖与详情页订阅分开处理。公共内容由持久房间游标恢复；实时投递不替代持久历史，也不证明客户端已应用。NATS 及其旧房间唤醒配置已退役。见 [Relay 实现](../docs/reviews/room-subscription-relay-implementation.zh-CN.md)和[账户成员覆盖](../docs/reviews/account-membership-incremental-audit.md)。
- `IM_V2_DURABLE_RETRY_*` 提供显式指数退避预算。初始/最大延迟、尝试预算和 0–100% 抖动均为必需部署输入。预算耗尽后，工作进入可告警的 `paused` 持久状态，必须通过受控运维重放处理，不会跳过目标。
- 普通编辑和作者撤回追加有序房间事件，使用不可变受理事实与当前操作授权；房间读取同时执行受理时和事件时的可见性约束。缺少受理事实时，在变更状态前拒绝新操作。已完成操作重放仍保持幂等。房间续读可以扫描不可见事件；新编辑携带完整替换状态，使客户端可以跨越已授权的版本缺口。见[变更授权](../docs/reviews/message-mutation-delivery-authority-contract.md)、[读取合同](../docs/reviews/message-mutation-read-contract.md)和[替换合同](../docs/reviews/message-edit-replacement-contract.md)。
- 成员增加/移除由 Owner 授权，并使用版本围栏。源事务共同记录持久操作结果、房间事件及必要的个人状态发件箱效果；响应丢失后可以重放原操作 ID，不产生第二次成员变更。
- 每个副本的 `IM_V2_GATEWAY_NODE_ID` 必须唯一。它限定重放设备撤销事件和关闭本地实时连接所用的持久游标范围。
- `IM_V2_USER_SHARD_BUCKET`、`IM_V2_USER_SHARD_ROUTER_EPOCH` 和 `IM_V2_USER_SHARD_STORES_JSON` 配置当前静态逻辑桶路由。个人状态投影写入配置的当前存储，控制面效果跨数据库保留持久幂等性。见[静态用户分片部署范围](../IMV2/docs/10-operations/user-shard-migration-runbook.md)。在线复制、切换与回滚不属于当前运行时。
- `IM_V2_DIRECT_ROOM_SHARD_ID` 选择新建双人房间使用的准入池，接受单个池 ID 或有界的逗号分隔列表。无序用户对的哈希选择稳定池，避免双方分别打开时拆成两个会话。配置的每个池必须持有所选容量配置的有效租约。私聊用户对及其房间配置不可变，因此切换 `IM_V2_CAPACITY_PROFILE_ID` 时，需要新测试用户对或重新初始化环境；其他配置下的已有用户对在打开时返回可重试 `UNAVAILABLE`，而非之后消息写入失败。`IM_V2_STRANGER_MESSAGE_MAX_PER_WINDOW` 和 `IM_V2_STRANGER_MESSAGE_WINDOW_SECONDS` 在持久消息事务中执行，普通基线为每 24 小时 3 条消息。
- `IM_V2_GROUP_ROOM_SHARD_ID` 选择原子创建群房间及初始成员时使用的准入池。
- 内容审核有逐消息持久发件箱和租约围栏工作器。`IM_V2_CONTENT_REVIEW_MODE=disabled` 停止创建新任务及启动工作器，不删除已有任务；禁用期间受理的消息不会回填。启用时设置 `enabled` 并配置 `IM_V2_CONTENT_REVIEW_SAFETY_ACTOR_USER_ID`。该身份是审计主体，不是客户端身份，也不要求为房间成员。`...VIOLATION_TERMS` 和 `...ESCALATION_TERMS` 仅为确定性基线；生产 AI/OCR/图片/视频适配器实现相同 `V2ContentReviewing` 边界。后续发现违规时，使用现有有序墓碑事件隐藏内容、撤销消息媒体引用，客户端删除可搜索及携带内容的本地字段。
- 配置的十万成员档位要求通过 [`IMV2/docs/09-capacity/standard-100k.md`](../IMV2/docs/09-capacity/standard-100k.md) 中的实测发布门禁，仅有配置不构成容量证据。
- 容量值必须匹配分配给房间的命名配置，不提供进程级兜底配置。
- 应用收到 `SIGTERM` 时关闭监听器和数据库容器。
- 令牌、HMAC 密钥、凭据重放信封密钥、数据库 URL 和帧载荷不得写入日志。

## 数据库集成验证

数据库集成测试要求显式指定可丢弃数据库：

```sh
IMV2_POSTGRES_TEST_DATABASE_URL='postgres://…' \
IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE=1 \
swift test --package-path IMV2Server
```

需要使用隔离的本地 PostgreSQL 16 并自动清理时，运行：

```sh
bash scripts/run_v2_postgres_integration.sh
```
