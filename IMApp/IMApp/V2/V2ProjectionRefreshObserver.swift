import Foundation
import IMV2ClientKit

/// 投影刷新观察器。
///
/// 每个页面持有一个读取者与一个串行刷新工作器。普通失效会合并为一次待处理刷新；
/// 紧急失效会立即取消当前刷新，工作器先将其排空再开始最新读取。
/// 因而不会出现重叠读取、游离的刷新任务，也不会堆积无界的已取消任务。
@MainActor
final class V2ProjectionRefreshObserver {
    private let refresh: @MainActor @Sendable (V2ProjectionChangeNotifier.Request) async -> Void
    private var pending = false
    private var pendingRequest: V2ProjectionChangeNotifier.Request?
    private var activeRequest: V2ProjectionChangeNotifier.Request?
    private var active: Task<Void, Never>?
    private var waiter: (id: UUID, continuation: CheckedContinuation<Bool, Never>)?

    /// 以刷新闭包构造观察器。
    ///
    /// - Parameter refresh: 实际执行的刷新闭包。
    init(refresh: @escaping @MainActor @Sendable (V2ProjectionChangeNotifier.Request) async -> Void) { self.refresh = refresh }
    convenience init(refresh: @escaping @MainActor @Sendable () async -> Void) { self.init { _ in await refresh() } }

    /// 以一次性观察器运行指定订阅。
    ///
    /// - Parameters:
    ///   - updates: 投影变更订阅。
    ///   - refresh: 实际执行的刷新闭包。
    static func run(_ updates: V2ProjectionChangeNotifier.Subscription,
                    refresh: @escaping @MainActor @Sendable (V2ProjectionChangeNotifier.Request) async -> Void) async {
        await V2ProjectionRefreshObserver(refresh: refresh).run(updates)
    }

    static func run(_ updates: V2ProjectionChangeNotifier.Subscription,
                    refresh: @escaping @MainActor @Sendable () async -> Void) async {
        await V2ProjectionRefreshObserver(refresh: refresh).run(updates)
    }

    /// 运行指定订阅直至结束。
    ///
    /// 订阅消费与刷新工作并行；任一方先结束都会取消另一方，
    /// 而任务组退出前会等待两者收敛，包括正在进行的读取。
    ///
    /// - Parameter updates: 投影变更订阅。
    func run(_ updates: V2ProjectionChangeNotifier.Subscription) async {
        let owner = self
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await request in updates {
                    guard !Task.isCancelled else { return }
                    await owner.submit(request)
                }
            }
            group.addTask { await owner.work() }
            _ = await group.next()
            group.cancelAll()
            // The group drains both children; work also drains its active read.
        }
    }

    /// 提交一次变更请求。
    ///
    /// 普通请求只标记待处理；紧急请求会立即取消当前刷新。
    /// 已有等待者时立即唤醒它，使其尽快开始新一轮读取。
    ///
    /// - Parameter request: 变更请求。
    func submit(_ request: V2ProjectionChangeNotifier.Request) {
        guard !Task.isCancelled else { return }
        pending = true
        var next = request
        if request.requiresImmediateRefresh, let activeRequest {
            next = Self.merging(activeRequest, request)
        }
        if let old = pendingRequest {
            pendingRequest = .init(generation: request.generation,
                requiresImmediateRefresh: old.requiresImmediateRefresh || next.requiresImmediateRefresh,
                conversationCommit: V2ConversationCommitMeasurement.earliest(old.conversationCommit, next.conversationCommit),
                scopes: old.scopes.union(next.scopes), roomIDs: Self.mergeRoomIDs(old.roomIDs, next.roomIDs))
        } else { pendingRequest = next }
        if request.requiresImmediateRefresh { active?.cancel() }
        if let waiter {
            self.waiter = nil
            pending = false
            waiter.continuation.resume(returning: true)
        }
    }

    /// 串行执行待处理刷新，直到任务被取消。
    ///
    /// 每轮都先等待待处理标记或取消信号，再启动一次刷新任务并等待其完成，
    /// 确保同一时刻只有一次读取在进行。
    private func work() async {
        while !Task.isCancelled, await takePending() {
            guard !Task.isCancelled else { return }
            let refresh = refresh
            let request = pendingRequest ?? .init(generation: 0, requiresImmediateRefresh: false)
            pendingRequest = nil
            activeRequest = request
            let task = Task { @MainActor in
                guard !Task.isCancelled else { return }
                await V2ProjectionVisibilityScope.$conversationCommit.withValue(request.conversationCommit) { await refresh(request) }
            }
            active = task
            await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
            active = nil
            activeRequest = nil
        }
    }

    private static func mergeRoomIDs(_ lhs: Set<String>?, _ rhs: Set<String>?) -> Set<String>? {
        guard let lhs, let rhs else { return nil }
        let merged = lhs.union(rhs)
        return merged.count <= 32 ? merged : nil
    }

    private static func merging(_ lhs: V2ProjectionChangeNotifier.Request, _ rhs: V2ProjectionChangeNotifier.Request) -> V2ProjectionChangeNotifier.Request {
        .init(generation: rhs.generation, requiresImmediateRefresh: lhs.requiresImmediateRefresh || rhs.requiresImmediateRefresh,
              conversationCommit: V2ConversationCommitMeasurement.earliest(lhs.conversationCommit, rhs.conversationCommit),
              scopes: lhs.scopes.union(rhs.scopes), roomIDs: mergeRoomIDs(lhs.roomIDs, rhs.roomIDs))
    }

    /// 等待并消费一次待处理标记。
    ///
    /// 已被取消或已有待处理标记时立即返回；否则登记等待者，
    /// 并在取消时唤醒它以结束等待。
    ///
    /// - Returns: 需要执行一次刷新时为 `true`。
    private func takePending() async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: false) }
                else if pending { pending = false; continuation.resume(returning: true) }
                else { waiter = (id, continuation) }
            }
        }, onCancel: { Task { await self.cancelWaiter(id) } })
    }

    /// 取消指定等待者并让其结束等待。
    ///
    /// - Parameter id: 等待者标识；不匹配时不做处理。
    private func cancelWaiter(_ id: UUID) {
        guard waiter?.id == id else { return }
        waiter?.continuation.resume(returning: false)
        waiter = nil
    }
}
