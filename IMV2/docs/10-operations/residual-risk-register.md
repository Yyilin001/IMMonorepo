# V2 残余风险登记表

状态：代码已完成以下可在仓库内安全验证的收敛；本文件登记不能靠局部重构或本机测试
诚实关闭的剩余风险。每项都包含当前隔离措施和可验证的退出条件，不能因为实现存在而
自动视为已上线。

## 已关闭

| 项目 | 处置 | 验证 |
| --- | --- | --- |
| Linux CI 无法启动 Swift 测试脚本 | workflow 统一用 `bash` 调用受版本控制的脚本，不依赖 Git 文件模式 | GitHub Actions `swift-and-postgres` job |
| 会话搜索状态与会话 UI 同文件 | `V2ConversationSearchStore` 独立为主线程状态对象；UI 仅消费其快照 | iOS generic simulator build |

## 仍打开的项目

| ID | 风险与边界 | 当前隔离措施 | 关闭条件 |
| --- | --- | --- | --- |
| R-001 | `V2GatewayTransportMetrics` 使用 `NSLock`，以及三个 NATS `ChannelInboundHandler` 因 SwiftNIO 回调模型保留 `@unchecked Sendable`。直接删除标注不能证明 NIO event loop 回调、promise 和 handler 状态的跨线程安全。 | 计量器的全部可变字段只在同一把锁内读写；NATS parser 状态只在所属 `EventLoop` 回调内读写，跨 actor 仅经 `@Sendable` payload 回调/`EventLoopPromise` 边界。继续运行 Server 单元和 integration tests。 | 升级到已提供完整 Sendable 语义的 SwiftNIO API 后，以 event-loop-bound / actor adapter 替换 handler；为每个替换增加并发压力测试，再移除 `@unchecked`。 |
| R-002 | `GRDBV2LocalSyncStore.swift` 仍是约 4k 行的本地持久化 facade，`V2ConversationUI.swift` 仍承载 list/detail UI store 和视图。继续按文本切割会破坏事务、同步顺序或 SwiftUI 状态一致性。 | 搜索 store 与 conversation data source 已先独立；现有 facade 仍通过封闭协议对外暴露，并由 package/Xcode test 覆盖。 | 以事务边界为单位依次提取 media cache、search index、conversation projection repository；UI 再拆 list/detail feature module。每一步须保留数据库迁移测试和 UI snapshot / interaction test。 |
| R-003 | 当前数据库线为绿地（可丢弃）基线，首次真实用户数据/公开 beta 后不能重写已发布 migration。 | 本地和 CI 集成库均显式标为 disposable；迁移说明和测试只针对该前提。 | 首次非一次性环境部署前冻结 migration lineage、记录 schema version，并从此只追加迁移与 upgrade/rollback 演练。 |
| R-004 | 双安装端到端验证依赖本机 Docker、Xcode、两个 simulator 与本地 CA，尚未是托管 CI 门禁。 | `IMApp/Scripts/verify_local_account_two_install_e2e.sh` 提供可重复的受控本机验证；常规 CI 保留 package、PostgreSQL integration 和 iOS build。 | 配置受保护的 macOS runner、Docker/模拟器隔离和临时 CA 生命周期后，将该脚本或等效测试纳入 nightly/release gate。 |
| R-005 | GitHub Actions 的 iOS job 当前只做 generic simulator build；`IMAppTests` 需要可启动的具体 simulator，尚不是远端单元测试门禁。 | 已在本机 iPhone simulator 执行 `V2ConversationStoreTests`；workflow 仍能编译 app、unit-test bundle 和 UI-test bundle。 | 在 macOS runner 固定可用 runtime/device，并把完整 `IMAppTests`（至少 conversation store suite）加入每次 push 的 test gate。 |

## 维护规则

修复某项时必须同时更新本表的“当前隔离措施”和“关闭条件”，并附上可复现的测试或
运行证据。新增的 `@unchecked Sendable`、已发布 schema 的重写、或绕开 release gate
都必须先登记为新的 ID，不能作为临时实现默默进入主线。
