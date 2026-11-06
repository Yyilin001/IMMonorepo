import Foundation
import IMV2ClientKit
import Observation
import QuartzCore

/// 从 Test1105Project 的值快照与按帧提交方案适配；不复制模拟数据源。
struct V2ConversationListSnapshot: Equatable, Sendable {
    enum Row: Equatable, Identifiable, Sendable {
        enum ID: Hashable, Sendable { case conversation(String), pending(UUID) }
        case conversation(V2ConversationListItem)
        case pending(V2DirectRoomPending, status: String)

        var id: ID {
            switch self {
            case .conversation(let item): .conversation(item.id)
            case .pending(let request, _): .pending(request.work.id)
            }
        }
    }

    struct Input: Equatable, Sendable {
        let conversations: [V2ConversationListItem]
        let pending: [Row]
        let query: String
    }

    let rows: [Row]
    static let empty = Self(rows: [])
}

actor V2ConversationListSnapshotBuilder {
    func build(_ input: V2ConversationListSnapshot.Input) throws -> V2ConversationListSnapshot {
        let query = input.query.trimmingCharacters(in: .whitespacesAndNewlines)
        var rows = input.pending
        for (index, item) in input.conversations.enumerated() {
            if index.isMultiple(of: 100) { try Task.checkCancellation() }
            // 私聊身份仍由可失效的身份展示管线持有，不复制进搜索索引。
            if query.isEmpty || item.preview.localizedStandardContains(query)
                || (item.kind == .group && item.title.localizedStandardContains(query)) {
                rows.append(.conversation(item))
            }
        }
        try Task.checkCancellation()
        return .init(rows: rows)
    }
}

@MainActor
@Observable
final class V2ConversationSnapshotPresentation {
    private(set) var snapshot = V2ConversationListSnapshot.empty
    @ObservationIgnored private let builder = V2ConversationListSnapshotBuilder()
    @ObservationIgnored private let frames: V2ConversationFrameDriver
    @ObservationIgnored private var latestInput: V2ConversationListSnapshot.Input?
    @ObservationIgnored private var input: AsyncStream<V2ConversationListSnapshot.Input>.Continuation?
    @ObservationIgnored private var pending: V2ConversationListSnapshot?
    @ObservationIgnored private var session: UUID?
    @ObservationIgnored private(set) var stagedCount = 0

    init(frames: V2ConversationFrameDriver = .init()) { self.frames = frames }

    func submit(_ next: V2ConversationListSnapshot.Input) {
        latestInput = next
        input?.yield(next)
    }

    /// 页面拥有一个长生命周期消费者。高频输入只替换待处理项，不反复取消构建或饿死显示帧。
    func run() async {
        let token = UUID()
        session = token
        let channel = AsyncStream<V2ConversationListSnapshot.Input>.makeStream(bufferingPolicy: .bufferingNewest(1))
        input?.finish()
        input = channel.continuation
        if let latestInput { channel.continuation.yield(latestInput) }
        defer {
            channel.continuation.finish()
            if session == token {
                input = nil
                pending = nil
                session = nil
                frames.stop()
            }
        }
        for await next in channel.stream {
            do {
                let ready = try await builder.build(next)
                try Task.checkCancellation()
                guard session == token else { return }
                pending = ready
                stagedCount &+= 1
                frames.requestFrame { [weak self] in self?.commitFrame() }
            } catch is CancellationError { return }
            catch { assertionFailure("快照构建出现非取消错误：\(error)"); return }
        }
    }

    private func commitFrame() {
        guard let pending else { return }
        self.pending = nil
        snapshot = pending
    }
}

/// 只提交已完成快照，回调不计算快照。空闲时没有显示链接。
@MainActor
final class V2ConversationFrameDriver: NSObject {
    private var link: CADisplayLink?
    private var onFrame: (@MainActor () -> Void)?
    private let automatic: Bool

    init(automatic: Bool = true) { self.automatic = automatic }
    var hasPendingFrame: Bool { onFrame != nil }

    func requestFrame(_ action: @escaping @MainActor () -> Void) {
        onFrame = action
        if automatic, link == nil {
            let next = CADisplayLink(target: self, selector: #selector(frame))
            next.add(to: .main, forMode: .common)
            link = next
        }
    }

    @objc private func frame(_ link: CADisplayLink) { commitFrame() }

    func commitFrame() {
        let action = onFrame
        stop()
        action?()
    }

    func stop() { link?.invalidate(); link = nil; onFrame = nil }
}
