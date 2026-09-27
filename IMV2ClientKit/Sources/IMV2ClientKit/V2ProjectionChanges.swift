import Foundation
import Synchronization

/// 投影失效作用域。
///
/// 失效只是「请重新读取持久化投影」的提示，绝不是业务事件本身。
public struct V2ProjectionScopes: OptionSet, Equatable, Sendable {
    /// 位掩码原始值。
    public let rawValue: UInt8

    /// 以位掩码构造作用域集合。
    ///
    /// - Parameter rawValue: 位掩码。
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    /// 会话列表。
    public static let conversations = Self(rawValue: 1 << 0)
    /// 会话详情。
    public static let conversationDetails = Self(rawValue: 1 << 1)
    /// 联系人。
    public static let contacts = Self(rawValue: 1 << 2)
    /// 隐私设置。
    public static let privacy = Self(rawValue: 1 << 3)
    /// 资料、成员资格、关系或隐私变化要求终止当前展示资格。
    public static let presentations = Self(rawValue: 1 << 4)
    /// 群昵称版本变化；仅核对当前关注的作者，不撤销整个账户的展示。
    public static let groupNicknames = Self(rawValue: 1 << 5)
    /// 全部作用域。
    public static let all: Self = [.conversations, .conversationDetails, .contacts, .privacy, .presentations, .groupNicknames]
}

/// 一次投影变更摘要。
public struct V2ProjectionChange: Equatable, Sendable {
    /// 受影响的作用域。
    public let scopes: V2ProjectionScopes
    /// 是否要求立即刷新（相对可延迟的常规刷新）。
    public let requiresImmediateRefresh: Bool

    /// 保存变更摘要。
    ///
    /// - Parameters:
    ///   - scopes: 受影响的作用域。
    ///   - requiresImmediateRefresh: 是否要求立即刷新。
    public init(scopes: V2ProjectionScopes, requiresImmediateRefresh: Bool) {
        self.scopes = scopes
        self.requiresImmediateRefresh = requiresImmediateRefresh
    }
    /// 表示全部作用域且要求立即刷新的变更。
    public static let all = Self(scopes: .all, requiresImmediateRefresh: true)
    /// 表示无变更。
    static let none = Self(scopes: [], requiresImmediateRefresh: false)

    /// 与另一份摘要合并：作用域取并集，立即刷新要求取逻辑或。
    ///
    /// - Parameter other: 另一份摘要。
    /// - Returns: 合并后的摘要。
    public func merging(_ other: Self) -> Self {
        .init(scopes: scopes.union(other.scopes),
              requiresImmediateRefresh: requiresImmediateRefresh || other.requiresImmediateRefresh)
    }
}

/// 投影变更订阅。
///
/// 每个订阅者对应一个迭代器。缓存的唤醒可能被替换，但其待处理作用域与紧急程度会在被消费前
/// 持续取并集，因此界面正忙于渲染时，后到的普通更新不会抹掉先前更严重的失效。
public struct V2ProjectionChangeSubscription: AsyncSequence, Sendable {
    /// 元素类型。
    public typealias Element = V2ProjectionChange
    let identifier: UUID
    let hub: V2ProjectionChangeHub
    let wakes: AsyncStream<Void>

    /// 订阅对应的异步迭代器。
    public struct AsyncIterator: AsyncIteratorProtocol {
        let identifier: UUID
        let hub: V2ProjectionChangeHub
        var wakes: AsyncStream<Void>.Iterator
        /// 等待并取出下一个变更摘要。
        ///
        /// - Returns: 下一个变更摘要；订阅结束时返回 `nil`。
        public mutating func next() async -> V2ProjectionChange? {
            while await wakes.next() != nil {
                if let change = hub.take(identifier) { return change }
            }
            return nil
        }
    }
    /// 创建异步迭代器。
    ///
    /// - Returns: 本订阅的迭代器。
    public func makeAsyncIterator() -> AsyncIterator {
        .init(identifier: identifier, hub: hub, wakes: wakes.makeAsyncIterator())
    }
}

/// 投影变更中枢。
///
/// GRDB 会在其写入队列上调用发布方，而订阅取消与消费可能发生在其他执行器上。
/// 该互斥锁只保护极小的内存槽位，且绝不会跨越 `await`、`yield` 或数据库读取持有。
final class V2ProjectionChangeHub: Sendable {
    private struct Slot {
        var pending: V2ProjectionChange
        let continuation: AsyncStream<Void>.Continuation
    }
    private struct State {
        var closed = false
        var slots: [UUID: Slot] = [:]
    }
    private let state = Mutex(State())

    /// 创建并登记一个新订阅。
    ///
    /// 新订阅会立即收到一次全量失效，避免依赖订阅之前已经提交的事务。
    ///
    /// - Returns: 订阅句柄。
    func subscribe() -> V2ProjectionChangeSubscription {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.onTermination = { [weak self] _ in self?.remove(id) }
        let closed = state.withLock { state in
            guard !state.closed else { return true }
            state.slots[id] = .init(pending: .all, continuation: continuation)
            return false
        }
        if closed { continuation.finish() } else { continuation.yield(()) }
        return .init(identifier: id, hub: self, wakes: stream)
    }

    /// 向全部订阅者发布变更。
    ///
    /// 空作用域的变更会被忽略；其余变更与各订阅者已有的待处理摘要求并集后唤醒对方。
    ///
    /// - Parameter change: 待发布的变更摘要。
    func publish(_ change: V2ProjectionChange) {
        guard !change.scopes.isEmpty else { return }
        let targets = state.withLock { state in
            for (id, slot) in state.slots { state.slots[id]?.pending = slot.pending.merging(change) }
            return state.slots.values.map(\.continuation)
        }
        for target in targets { target.yield(()) }
    }

    /// 取出并清空指定订阅的待处理摘要。
    ///
    /// - Parameter id: 订阅标识。
    /// - Returns: 待处理摘要；没有待处理项时返回 `nil`。
    func take(_ id: UUID) -> V2ProjectionChange? {
        state.withLock { state in
            guard let slot = state.slots[id], !slot.pending.scopes.isEmpty else { return nil }
            state.slots[id]?.pending = .none
            return slot.pending
        }
    }

    /// 移除指定订阅。
    ///
    /// - Parameter id: 订阅标识。
    private func remove(_ id: UUID) { _ = state.withLock { $0.slots.removeValue(forKey: id) } }

    /// 关闭中枢并结束全部订阅。
    func finish() {
        let targets = state.withLock { state in
            state.closed = true
            let targets = state.slots.values.map(\.continuation)
            state.slots.removeAll()
            return targets
        }
        for target in targets { target.finish() }
    }
}
