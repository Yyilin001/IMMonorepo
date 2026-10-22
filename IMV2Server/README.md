# IM V2 网关

`IMV2ServerApp` 是独立的 V2 TLS 网关，不依赖外部路由、数据表、线协议或迁移路径。

跨组件数据流，以及实现证据与发布证据的区别，见[当前系统架构](../docs/current-system-map.md)和 [V2 文档入口](../IMV2/docs/README.md)。

阿里云对象存储的解耦装配、环境配置和真实验证入口，见 [OSS 接入与验证](../docs/proposals/aliyun-oss-integration.md)及 [oss.env.example](oss.env.example)。

## 部署准备

服务端要求 Swift 6.4；macOS 环境要求 macOS 26.2 或更高版本，并固定使用 Vapor 5.0.0-beta.3。Linux 镜像与 CI 使用相同摘要的 Swift 6.4 Jammy 镜像。数据库所有权、关闭顺序、依赖边界与验证要求见 [Vapor 5 迁移合同](../IMV2/docs/00-foundation/vapor5-migration.md)。

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

## 持久任务的运维重放

`IMV2OperatorServerApp` 是独立、仅监听回环地址的控制面程序，每次重放一条明确暂停的房间发件箱或扇出投递记录。它使用专属访问令牌密钥和操作主体，不共享公开网关监听器，并将重放审计证据与状态变更原子写入。

配置见 [`operator-replay.env.example`](operator-replay.env.example)，操作步骤见[运维重放手册](../IMV2/docs/10-operations/durable-work-operator-replay.md)。不要直接公开该端口，应通过已批准的堡垒机或双向 TLS 运维代理访问。

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

每个账户请求必须携带 Base64 入口授权密钥和由同一 HTTPS 代理注入的有效客户端地址。账户进程在限流前拒绝直接回环请求、重复请求头和无效地址，探针及工具也不得绕过代理。仓库中的本地 Caddy 配置从直接连接对端获取地址，其正常反向代理行为会丢弃客户端提供的 `X-Forwarded-*` 值。生产拓扑位于其他七层代理之后时，必须显式配置并验证可信代理链，不能直接复制任意转发地址到该请求头。

### 原生客户端的本地开发流程

开发时保持 iOS App 原生运行，使用 Docker 启动其账户依赖：

```sh
bash IMV2/scripts/run_v2_local_account_stack.sh
```

脚本在被 Git 忽略的 `IMV2/.env.local` 中创建本地专用密钥，启动 PostgreSQL、账户进程和原生 V2 TLS 网关。macOS 回环地址仅发布 `https://localhost:8443` 和 TLS 网关 `localhost:7443`。Caddy 与账户进程共享容器网络命名空间，因此账户进程仍仅绑定 `127.0.0.1:8444`；数据库和内部 HTTP 端口不发布到 macOS。

首次运行时，将生成的 `IMV2/local-ca/root.crt` 导入所选 iOS 模拟器并启用完全信任。Debug App 已默认使用 `https://localhost:8443`。辅助脚本会输出准确的停止命令，不创建 Python 虚拟环境，也不修改宿主机数据库。

网关绑定 TLS 端口前检查数据库结构是否就绪。它要求 TLS 1.3，配置缺失时直接拒绝启动，不使用开发默认值。

本地服务就绪后，验证 HTTPS 账户认证因素、设备凭据交接与 TLS 网关，全程不打印断言或凭据：

```sh
bash IMV2/scripts/verify_v2_local_account_stack.sh
```

冒烟检查在本地 Docker 卷中创建一个唯一命名账户，不访问公开端点，不将令牌写入磁盘或输出。本地隔离 Compose 项目也会验证同一套服务；该证据仅覆盖本地服务，不代表生产部署批准。

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
- 普通编辑、作者撤回和表情回应追加有序房间事件，使用不可变受理事实与当前操作授权；房间读取同时执行受理时和事件时的可见性约束。缺少受理事实时，在变更状态前拒绝新操作。已完成操作重放仍保持幂等。房间续读可以扫描不可见事件；新编辑携带完整替换状态，使客户端可以跨越已授权的版本缺口。见[变更授权](../docs/reviews/message-mutation-delivery-authority-contract.md)、[读取合同](../docs/reviews/message-mutation-read-contract.md)和[替换合同](../docs/reviews/message-edit-replacement-contract.md)。
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
