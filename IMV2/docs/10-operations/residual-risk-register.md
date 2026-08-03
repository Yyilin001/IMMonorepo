# V2 残余风险登记表

状态：代码已完成以下可在仓库内安全验证的收敛；本文件登记不能靠局部重构或本机测试
诚实关闭的剩余风险。每项都包含当前隔离措施和可验证的退出条件，不能因为实现存在而
自动视为已上线。

## 已关闭

| 项目 | 处置 | 验证 |
| --- | --- | --- |
| Linux CI 无法启动 Swift 测试脚本、编译 GRDB 或建立当前 V2 SQLite/PostgreSQL 基线 | workflow 统一用 `bash` 调用受版本控制的脚本，并在 Swift 容器安装 `libsqlite3-dev`；fresh SQLite schema 不再走 SQLite 3.37 不兼容的 `ADD COLUMN ... CHECK` 路径；PostgreSQL migration 移除指向不存在 `users` 表的外键，并用设备复合外键约束 presence 身份 | 本机 disposable PostgreSQL 全量 245 项 Server 测试；GitHub Actions `swift-and-postgres` job |
| 会话搜索状态与会话 UI 同文件 | `V2ConversationSearchStore` 独立为主线程状态对象；UI 仅消费其快照 | iOS generic simulator build |
| NATS/NIO handler 与网关指标使用 `@unchecked Sendable` | NATS parser state 改由 `NIOLoopBoundBox` 绑定到所属 event loop，越界访问会触发 NIO 运行时前置条件；网关指标改由 `Synchronization.Mutex` 封装所有可变状态。生产源码不再包含 `@unchecked Sendable`。 | NATS broker integration、静默 broker timeout、12×400 并发指标压力测试 |
| 会话详情、媒体/群管理 UI 与本地命令/搜索索引集中在超大源文件 | 详情 Store、群管理视图、媒体视图、命令队列与消息搜索索引均拆为独立文件；SQLite pool 仍仅由 `GRDBV2LocalSyncStore` actor 拥有，跨文件 extension 不绕开事务边界。 | ClientKit command/search 回归；iOS generic simulator build |
| 首发后可能回写历史 SQL migration | 当前迁移线已冻结为 `IMV2/sql/migration-baseline.lock.sha256`。每次 Swift/isolated gate 都校验锁定历史的 hash，只允许新增编号大于现有最高号的 migration。 | baseline-lock 正/反例脚本：篡改 `0001_core.sql`、插入旧编号均必须失败 |

## 仍打开的项目

| ID | 风险与边界 | 当前隔离措施 | 关闭条件 |
| --- | --- | --- | --- |
| R-004 | 双安装端到端验证依赖本机 Docker、Xcode、两个 simulator 与本地 CA，尚未是托管 CI 门禁。 | `IMApp/Scripts/verify_local_account_two_install_e2e.sh` 提供可重复的受控本机验证；常规 CI 保留 package、PostgreSQL integration 和 iOS build。 | 配置受保护的 macOS runner、Docker/模拟器隔离和临时 CA 生命周期后，将该脚本或等效测试纳入 nightly/release gate。 |
| R-005 | GitHub Actions 的 iOS job 当前只做 generic simulator build；`IMAppTests` 需要可启动的具体 simulator，尚不是远端单元测试门禁。 | 已在本机 iPhone simulator 执行 `V2ConversationStoreTests`；workflow 仍能编译 app、unit-test bundle 和 UI-test bundle。 | 在 macOS runner 固定可用 runtime/device，并把完整 `IMAppTests`（至少 conversation store suite）加入每次 push 的 test gate。 |

## 维护规则

修复某项时必须同时更新本表的“当前隔离措施”和“关闭条件”，并附上可复现的测试或
运行证据。新增的 `@unchecked Sendable`、修改 migration baseline lock 中的历史 SQL、或绕开
release gate 都必须先登记为新的 ID，不能作为临时实现默默进入主线。
