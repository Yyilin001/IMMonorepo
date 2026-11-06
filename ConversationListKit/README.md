# ConversationListKit

从 SuperChat 的会话列表抽出的 Swift 包，仅依赖系统框架。排序和视口数据源可在 macOS 上独立运行，iOS 17 及以上可使用 UIKit 渲染器。

`FixedPositionListController<Row>` 按屏幕位置复用原生 cell，按显示帧合并更新。滚动时只向数据源请求可见区及邻近位置，数量变化只增删尾部槽位。原生侧滑菜单按行 ID 持有目标。若实时排序会把另一行移到菜单下，控制器暂缓可见行的位置变化，内容及后台排序继续更新。收起菜单后应用最新顺序，目标已移除时关闭菜单并忽略迟到的操作。行的 `Equatable` 比较应包含业务 ID 和所有影响显示、交互的字段。

## 数据源

- **已排序的分页窗口**。创建 `OrderedListWindow(rows)` 传给控制器。每次数据变化调用 `replace(with:)`。同一显示帧只渲染最新窗口。
- **高频增量事件**。使用 `RankedListViewport<Row>`，其中 `Row` 遵循 `Identifiable` 和 `Sendable`。用唯一 ID 的有序快照初始化 `RankedViewportEngine<Row.ID>`，再用同一批行和代次调用视口的 `install`。通过 `enqueueRealtimeUpdate` 提交内容及目标位置，通过 `applyStructuralChange` 提交增删。视口按帧将移动和区间读取一起交给排序 actor，过期的结果不会覆盖新安装的快照。每个独立滚动的列表使用自己的视口实例。

`RankedViewportEngine` 内部使用 `KeyedOrderTree`。移动一个元素的期望复杂度为 O(log n)，读取连续 k 个位置的期望复杂度为 O(log n + k)。

迁移前的 IMApp 使用第一种数据源消费 SQLite 返回的全量有序会话快照。该组件已独立保存到 https://github.com/Yyilin001/ConversationListKit 。当前正式会话页使用 `V2ConversationSnapshotList`（后台不可变快照、按帧提交、SwiftUI List）；本包仍供旧性能实验页与组件回归测试作为对照。搜索、置顶规则、头像授权、导航和按会话 ID 恢复滚动位置继续由应用管理。

在本目录运行 `swift test` 可验证排序、区间读取、实时更新合并与结构替换。UIKit 的帧合并、复用、分页恢复及交互测试随 IMApp 在 iOS 模拟器运行。
