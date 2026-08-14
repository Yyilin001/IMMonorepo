# V2 残余风险登记表

状态：代码已完成以下可在仓库内安全验证的收敛；本文件登记不能靠局部重构或本机测试
诚实关闭的剩余风险。每项都包含当前隔离措施和可验证的退出条件，不能因为实现存在而
自动视为已上线。

## 已关闭

| 项目 | 处置 | 验证 |
| --- | --- | --- |
| Linux CI 无法启动 Swift 测试脚本、编译 GRDB 或建立当前 V2 SQLite/PostgreSQL 基线 | workflow 统一用 `bash` 调用受版本控制的脚本，并在 Swift 容器安装 `libsqlite3-dev`；fresh SQLite schema 的 special-account 列不再走 SQLite 3.37 不兼容的 `ADD COLUMN ... CHECK` 路径，改由兼容列定义和 insert/update trigger 保持同一枚举约束；PostgreSQL migration 移除指向不存在 `users` 表的外键，并用设备复合外键约束 presence 身份 | Linux/arm64 SQLite 3.37 ClientKit 181 项 / 36 suites、本机 Server 279 项 / 65 suites，加六条 disposable PostgreSQL 聚焦回归；GitHub Actions `swift-and-postgres` job |
| 会话搜索状态与会话 UI 同文件 | `V2ConversationSearchStore` 独立为主线程状态对象；UI 仅消费其快照 | iOS generic simulator build |
| NATS/NIO handler 与网关指标使用 `@unchecked Sendable` | NATS parser state 改由 `NIOLoopBoundBox` 绑定到所属 event loop，越界访问会触发 NIO 运行时前置条件；网关指标改由 `Synchronization.Mutex` 封装所有可变状态。生产源码不再包含 `@unchecked Sendable`。 | NATS broker integration、静默 broker timeout、12×400 并发指标压力测试 |
| 会话详情、媒体/群管理 UI 与本地命令/搜索索引集中在超大源文件 | 详情 Store、群管理视图、媒体视图、命令队列与消息搜索索引均拆为独立文件；SQLite pool 仍仅由 `GRDBV2LocalSyncStore` actor 拥有，跨文件 extension 不绕开事务边界。 | ClientKit command/search 回归；iOS generic simulator build |
| GitHub Actions 的 iOS job 仅编译、不执行模拟器测试 | iOS jobs 固定使用 `macos-26`、Xcode 26.2、iPhone 17 / iOS 26.2；每次 push/PR 分别执行 generic simulator `build-for-testing`、完整 `IMAppTests` 和确定性登录/注册 `IMAppUITests`。 | 本机 iPhone 17 Pro / iOS 26.5 运行 108 项 unit tests；4 项 UI tests 已按显式关闭 Passkey 的产品配置通过；workflow 声明由同一受版本控制脚本驱动 |
| 首发后可能回写历史 SQL migration | 当前迁移线已冻结为 `IMV2/sql/migration-baseline.lock.sha256`。每次 Swift/isolated gate 都校验锁定历史的 hash，只允许新增编号大于现有最高号的 migration。 | baseline-lock 正/反例脚本：篡改 `0001_core.sql`、插入旧编号均必须失败 |
| snapshot reset 的进程内状态随完整同步历史增长 | Snapshot V3 以每用户 application-MVCC projection/checkpoint 为输入，按稳定 keyset 生成持久化有界页；客户端逐页写 shadow，服务端 ACK 后才激活 live。构建失败、过期、ACK 后崩溃、跨代 ACK 重放、GC 和分片 copy/verify 均有回归。 | Core codec/page 极值、ClientKit reset 故障注入、disposable PostgreSQL Snapshot V3/GC/transfer 回归；完整 ClientKit 与 Server 套件 |
| R-006：`user_sync_log` 追加历史无法安全裁剪 | Snapshot V3/连续 checkpoint、持久化 retained floor、低 cursor/new device 按需 reset、同 user/profile/schema 复用 floor 之上的最新 artifact 并增量追平、撤销设备 capability/cursor 回收、inclusive receipt/token fence、consumer inbox 稳定 sequence、控制投影稳定 effect、shared payload 引用 GC 与迁移 copy/fingerprint 已打通；运行时按用户、序列和行数上限执行 `SKIP LOCKED` compaction，且不枚举设备历史。 | disposable PostgreSQL 覆盖回执首序列不误删、compaction 不改低 cursor、checkpoint 前进后两设备仍按需共享 artifact、撤销设备清理、多批前缀删除、日志为空后的手工 reset watermark、inbox/effect 重试结果与新设备入场；分片 transfer/fingerprint 回归 |

## 仍打开的项目

| ID | 风险与边界 | 当前隔离措施 | 关闭条件 |
| --- | --- | --- | --- |
| R-004 | 双安装端到端验证依赖本机 Docker、Xcode、两个 simulator 与本地 CA，尚未是托管 CI 门禁。 | `IMApp/Scripts/verify_local_account_two_install_e2e.sh` 提供可重复的受控本机验证；常规 CI 保留 package、PostgreSQL integration 和 iOS build。 | 配置受保护的 macOS runner、Docker/模拟器隔离和临时 CA 生命周期后，将该脚本或等效测试纳入 nightly/release gate。 |
| R-007 | 控制命令的 operation ledger 与 `user_projection_effects` 保存稳定幂等结果，磁盘随控制操作数增长；它们不是 sync replay history，不能由 retained-floor compactor 删除。当前没有跨所有 operation 表的一致产品幂等窗口和删除合同。 | effect 仅保存 inline 非 fan-out 控制投影，不复制消息 payload；按物理 user store 聚合 planner estimate 与含 index/TOAST 的 relation bytes，并在 10 GiB 触发容量告警。 | 产品批准统一的最短幂等重放窗口、离线 outbox 最大寿命、法律/审计保留和分片 rollback 窗口；为每类 operation/effect 建立可证明引用安全的有界清理 worker，并通过过期前精确重放、过期后明确拒绝或新操作语义及迁移故障回归。 |

## 维护规则

修复某项时必须同时更新本表的“当前隔离措施”和“关闭条件”，并附上可复现的测试或
运行证据。新增的 `@unchecked Sendable`、修改 migration baseline lock 中的历史 SQL、或绕开
release gate 都必须先登记为新的 ID，不能作为临时实现默默进入主线。
