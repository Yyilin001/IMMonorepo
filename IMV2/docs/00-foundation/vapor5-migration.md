# Vapor 5 beta 迁移

本分支从 `main` 的 `cd8b77c361cfc2eb7a81850487db0e786b33398d` 开始，迁移范围为 HTTP 框架、数据库资源归属、服务生命周期、测试和构建环境。不包含分布式 Actor 改造。

## 工具链与依赖

- Server 使用 Swift 6.4，macOS 最低版本为 26.2；Linux 使用 Swift 6.4 Jammy。
- Vapor 固定为 `5.0.0-beta.2`，FluentKit 固定为 `1.57.0`。移除依赖 Vapor 4 的 `vapor/fluent` 集成包。
- PostgreSQL 驱动、PostgresNIO、SQLKit、AsyncKit 和 NIO 保留迁移基线中的解析版本；以 `IMV2Server/Package.resolved` 为准。
- PostgresNIO 1.33.1 通过 `Vendor/postgres-nio` 固定源码提供，只有一处等值比较的 Swift 6.4 Linux 编译兼容补丁；其版本和逐文件校验记录在 `UPSTREAM.json`，原因见 [补丁说明](../../../IMV2Server/Vendor/postgres-nio/PATCHES.md)。它由本地 package 提供，因此不再出现在远程锁文件条目中。Collections 保持 1.6.0。
- Server 解析 Crypto 4.5.2。Core 允许 Crypto 3.9 至 5.0 之前的版本，独立 Core 与 ClientKit 的锁文件仍使用 Crypto 3.15.1。客户端最低系统要求保持原有约束。
- Docker 构建和运行阶段、Linux CI 使用同一个 Swift 镜像摘要：`sha256:a6053d2de72091906bfa064f76f145e3f28830664cae250e1b84aa8c499a8ee6`。
- 正常构建与测试使用 `--disable-automatic-resolution`。升级 beta 或其依赖时必须显式更新锁文件，再执行本页的验证。

## 运行时归属

`V2DatabaseResources` 显式持有 FluentKit `Databases`、驱动线程池和事件循环所有权。三个服务根据原有配置创建数据库事件循环，再将其借给资源容器；最终由入口关闭事件循环。并发关闭调用等待同一个清理任务。

`V2EventLoopDatabasePool` 在每个数据库事件循环上创建句柄；原有 `V2EventLoopBalancedDatabase` 继续分配独立操作，并使 transaction、withConnection 和 withSession 留在同一底层数据库句柄。生产连接预算、业务 SQL 和会话参数保持原有配置，继续执行 schema/session/capacity readiness。

Schema readiness 在读取 PostgreSQL catalog 时临时使用空 `search_path`，使约束和索引定义的限定名稳定；检查结束后恢复连接原来的路径。这样本地账户栈中与 schema 同名的 `im_v2` 登录角色也能通过同一契约检查。此修正不修改 canonical schema，也不设置全局连接搜索路径。

`V2HTTPService` 管理 Vapor 服务的运行作用域。通过只含空 `InMemoryProvider` 的 `ConfigReader` 保持已验证监听配置的权威性，防止通用 `HOSTNAME`、`PORT` 或命令行参数覆盖账户、Operator 和 metrics 的回环地址。只有 `listeningAddress` 成功后才报告绑定完成。

停止流程等待 HTTP 请求和响应流完成，再释放它们依赖的资源。账户服务随后取消后台任务、等待密码线程池结束、关闭数据库与事件循环；Gateway 同时管理自身 TLS listener、后台任务、broker 和连接。后台任务超过退出期限时以失败状态终止进程，不在仍运行的事务下方释放数据库资源。

## HTTP 契约

- 使用 HTTPTypes 的 method、status 和 header 类型；请求和响应按 Vapor 5 的值语义处理。
- 身份缓存通过请求认证容器保存，重复 edge proof 和客户端地址头仍拒绝，身份不得跨请求共享。
- JSON body 使用异步读取，保留原有 1/8/16 KB 等路由上限和 413 状态优先级；错误正文和日志继续脱敏。
- Vapor 5 的 `collect()` 不会重新限制已缓冲请求体；注册取消与凭据撤销路由收集后仍显式检查 1 KiB，使超限 JSON 和表单都优先返回 413。
- 本地媒体上传逐块写 staging 文件、计算实际字节数并显式 flush，校验长度后提交；失败与取消丢弃 staging 对象。
- 下载使用 Application 的 FileIO，保留签名 URL、Range、no-store 与二进制响应约定。
- 自建 NIO TLS、Protobuf、压缩帧、DTO、密钥格式和数据库 schema 均不随此次迁移改动。

## 验证入口

本次迁移按约定以本地 Linux 容器作为最终验收环境。隔离测试栈提供三个 PostgreSQL 实例和 NATS，源码只读挂载，构建产物写入独立 volume。迁移重点回归可使用：

```bash
docker compose -p imv2-vapor5-check -f IMV2/docker-compose.isolated-tests.yml \
  run --build --rm \
  -e 'V2_TEST_PACKAGES=IMV2Core IMV2Compression IMV2Server' \
  -e 'V2_SERVER_TEST_FILTER=V2Vapor|V2Password|V2Authenticated|V2Redacted|V2HTTPServiceTests|V2DatabaseResourcesTests|V2EventLoopDatabasePoolTests|V2PostgresGatewayAuthenticatorTests|V2PrometheusTelemetrySinkTests|V2GatewayDomainCommandHandlerTests|V2TaskDrainDeadlineTests|RuntimeConfigurationTests|V2RealNATSRoomWakeTests|PostgresV2NATSInstallationTests|PostgresV2RoomRecoverySchemaTests|registrationCancellationDeadlineAfterLock|editPolicyCommitOrdering|oppositeForwardsUseCanonicalRoomLocks|groupPolicySurvivesReceiptCleanup' \
  swift-tests
```

完整隔离测试入口继续保留，按需要执行；本次不把全量容量套件作为验收条件：

```bash
docker compose -p imv2-vapor5-check -f IMV2/docker-compose.isolated-tests.yml \
  up --build --abort-on-container-exit --exit-code-from swift-tests swift-tests
```

测试完成后可用同一个项目名执行 `down --volumes`，清理这次隔离验证创建的数据库和构建缓存。本地账户栈另外验证 TLS 账户接口、网关收发、32 MiB 媒体传输和进程退出。原生测试命令保留供开发时使用：

```bash
swift test --disable-automatic-resolution --package-path IMV2Core
swift test --disable-automatic-resolution --package-path IMV2Compression
swift test --disable-automatic-resolution --package-path IMV2ClientKit --no-parallel
swift test --disable-automatic-resolution --package-path IMV2Server --no-parallel
bash scripts/check_v2_protobuf_generated.sh
bash IMV2/scripts/test_v2_local_environment_contract.sh
bash scripts/check_v2_schema_readiness_tables.sh
bash scripts/check_v2_runtime_env_examples.sh
bash scripts/check_v2_document_links.sh
bash scripts/check_v2_document_structure.sh
```

真实 PostgreSQL 测试必须提供 primary、secondary、control 三个不同的可丢弃数据库 URL，以及 `IMV2_POSTGRES_TEST_DATABASE_IS_DISPOSABLE=1`、`IMV2_REQUIRE_CROSS_STORE_POSTGRES_TESTS=1`；跨实例验证的 primary 与 secondary 使用不同 PostgreSQL 实例。没有数据库变量时的绿色测试结果不证明事务、物理连接或跨 store 行为。

原 PostgreSQL 集成测试拆分为同一个 `.serialized` suite 的多个文件，323 个测试的注解、参数和正文保持一致。Linux debug 测试按单文件批次编译并保留行号调试信息，以控制 Swift 6.4 为大型参数化测试生成 DWARF 的内存开销；生产目标的调试信息设置不受影响。

大型测试模块的编译仍需充足资源：本地 8 GiB、禁用 swap 的容器会在转发集成测试文件上 OOM；允许交换空间后该文件编译完成，观察到约 5 GiB swap 峰值。此资源需求属于测试编译，不能当作服务运行内存预算。

Linux 的 NIO FileSystem 可以用 `O_TMPFILE` 写入匿名暂存文件，上传中没有目录项。取消上传测试同时观察本次测试目录下的文件和 `/proc/self/fd` 中的暂存描述符，并确认取消后两者均被清理。

`V2TelemetryEvent` 使用 `indirect enum`。原始枚举在 Linux Swift 6.4 的 `-O` 构建中，经异步遥测调用可稳定触发崩溃；独立复现不依赖数据库、TLS 或跨模块边界。仅改变枚举存储方式后，10 组各 10 万次调用均保持准确计数。该兼容处理保留原有事件、值语义和 `Sendable`；未来升级工具链时应先重跑独立复现与 Release 网关链路，再考虑移除。现有证据尚不足以断言具体的编译器内部根因。

额外验证包括 Core 在 Crypto 4.5.2 下的同一套契约测试、HTTP 真实 socket 流和取消、Linux release 产品构建与进程停止、现有本地账户栈联调。本次内部项目迁移不以生产容量测试、原生 A/B 或真实设备回归为验收条件，也不从单元测试耗时推导容量结论。

已完成的本地 Linux 测试结果：Core 129 个测试、Compression 8 个测试、Server 迁移重点回归 257 个测试（41 个套件）全部通过。Server 结果包含真实 PostgreSQL、NATS 及重启场景，不是完整 Server 套件的通过声明。

最终统一 Release 镜像 `edfa08e79209` 已通过默认 PostgreSQL `search_path` 下的三服务启动、完整账户/TLS 网关冒烟，以及 32 MiB 媒体上传下载、Range、慢读和断连暂存清理。Account、Operator、Gateway 收到停止信号后均在 1 秒内以状态 0 退出，无 OOM。

本地栈重启使用 `IMV2/scripts/run_v2_local_account_stack.sh` 的既定顺序：Account/Operator、重新创建 Caddy、再创建 Gateway。Caddy 共享 Account 的网络命名空间；只重启 Account 而保留旧 Caddy，可能使宿主机 HTTPS 端口失效。

## 回退边界

保留上述 main 提交和对应锁文件、独立镜像标签及配置。此次迁移不执行 schema migration；回退恢复 main 的代码或镜像与配置。候选版本写入的数据仍需由 main 实际读取验证，不能仅凭无 schema diff 宣称回退完成。

## 上游依据

- [Vapor beta.2 固定源码与依赖](https://github.com/vapor/vapor/tree/5.0.0-beta.2)
- [Application 生命周期](https://github.com/vapor/vapor/blob/5.0.0-beta.2/Sources/Vapor/Application.swift)
- [VaporTesting](https://github.com/vapor/vapor/tree/5.0.0-beta.2/Sources/VaporTesting)
- [FluentKit 1.57.0](https://github.com/vapor/fluent-kit/tree/1.57.0)
