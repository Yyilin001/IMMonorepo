import ConversationListKit
import Observation
import UIKit

enum V2ConversationLoadScenario: String, CaseIterable {
    case everyday = "日常收发"
    case burst = "群聊消息突发"
    case reorder = "大列表随机重排"
    case growth = "持续新增会话"
    case seek = "大列表跳转浏览"

    var usesWindow: Bool { self == .everyday || self == .burst }
    var sizes: [Int] { usesWindow ? [50, 100, 300] : [1_000, 10_000, 50_000] }
    var rates: [Int] {
        switch self {
        case .everyday: [1, 5, 10, 30]
        case .burst, .reorder, .growth: [20, 100, 200, 500]
        case .seek: [1, 3, 5, 10]
        }
    }
    var detail: String {
        switch self {
        case .everyday: "在有序窗口中模拟收发消息、更新未读和最近会话排序。"
        case .burst: "每秒集中投递一批消息到 5 个活跃群聊，观察首屏重排。"
        case .reorder: "随机选取已有会话更新消息，通过排序 actor 将它们移到列表顶部。"
        case .growth: "从选定的初始规模开始，分批在顶部插入新会话。"
        case .seek: "自动跳到可复现的随机位置，测试长距离滚动时的可见区读取与单元格复用。"
        }
    }
}

struct V2ConversationLoadConfig {
    let scenario: V2ConversationLoadScenario
    var count: Int
    var rate: Int
    var seconds = 15

    init(_ scenario: V2ConversationLoadScenario = .everyday) {
        self.scenario = scenario
        count = scenario.sizes[1]
        rate = scenario.rates[1]
    }
}

struct V2ConversationLoadRow: Identifiable, Equatable, Sendable {
    let id: Int
    var event = 0
    var unread = 0
    var isPinned = false
    var isMuted = false
    var isArchived = false
    // Zero selects the generated preview. Manual messages live only in visited rooms.
    var localSendRevision = 0

    func presentation(at start: Date, sent: (text: String, date: Date)? = nil) -> V2ConversationListItem {
        let outgoing = event > 0 && event.isMultiple(of: 4)
        let preview = event == 0 ? "最近一次讨论的消息摘要" : (outgoing ? "收到，稍后回复" : "新的群聊消息") + " · \(event)"
        return .init(id: "local-perf-\(id)", title: "模拟会话 \(id + 1)", preview: sent?.text ?? preview,
                     lastActivity: sent?.date ?? (event == 0 ? start.addingTimeInterval(-Double(id)) : start),
                     isOutgoing: sent != nil || outgoing, kind: .group, isPinned: isPinned, muteUntil: isMuted ? .distantFuture : nil,
                     unreadCount: UInt64(unread))
    }
}

/// Each run owns its sources, clock and input stream. No account or database service is involved.
@MainActor @Observable
final class V2ConversationPerformanceRun {
    enum Phase: String {
        case idle = "待开始", preparing = "正在准备数据", displaying = "正在显示首屏"
        case paused = "查看聊天中", running = "测试中", finished = "测试完成", stopped = "已停止", failed = "测试未能完成"
    }

    struct Metrics {
        var elapsed = 0.0
        var events = 0
        var cells = 0
        var count = 0
        var frameP95: Double?
        var fps: Double?
        var throughput: Double { elapsed > 0 ? Double(events) / elapsed : 0 }
    }

    let config: V2ConversationLoadConfig
    let referenceDate = Date()
    private(set) var phase: Phase = .idle
    private(set) var metrics = Metrics()
    private(set) var preparationMS: Double?
    private let ordered = OrderedListWindow<V2ConversationLoadRow>()
    private let ranked = RankedListViewport<V2ConversationLoadRow>()
    var source: any FixedPositionViewportDataSource<V2ConversationLoadRow> { config.scenario.usesWindow ? ordered : ranked }

    @ObservationIgnored weak var controller: FixedPositionListController<V2ConversationLoadRow>?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let frames = FrameSampler()
    @ObservationIgnored private var window: [V2ConversationLoadRow] = []
    // Synthetic IDs are dense, including archived and newly inserted conversations.
    @ObservationIgnored private var rowsByID: [V2ConversationLoadRow] = []
    @ObservationIgnored private var pinnedCount = 0
    @ObservationIgnored private var mutatingList = false
    @ObservationIgnored private var mutationWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var startTime = 0.0
    @ObservationIgnored private var nextTick = 1
    @ObservationIgnored private var chats: [Int: V2ConversationPerformanceChat] = [:]
    @ObservationIgnored private var delivered = 0
    @ObservationIgnored private var configured = 0
    @ObservationIgnored private var randomState: UInt64 = 0x5377696674

    init(_ config: V2ConversationLoadConfig) { self.config = config }

    func prepare() {
        guard phase == .idle else { return }
        phase = .preparing
        task = Task {
            let start = CACurrentMediaTime()
            do {
                let rows = try await Self.makeRows(count: config.count)
                try Task.checkCancellation()
                if config.scenario.usesWindow {
                    window = rows
                    ordered.replace(with: rows)
                } else {
                    let engine = RankedViewportEngine<Int>()
                    try await Self.buildIndex(engine, count: rows.count)
                    try Task.checkCancellation()
                    ranked.install(engine: engine, totalCount: rows.count, pinnedCount: 0, rows: rows, primesLeadingBindings: true)
                }
                try Task.checkCancellation()
                rowsByID = rows
                metrics.count = rows.count
                preparationMS = (CACurrentMediaTime() - start) * 1_000
                phase = .displaying
            } catch is CancellationError { } catch { phase = .failed }
        }
    }

    @concurrent private static func makeRows(count: Int) async throws -> [V2ConversationLoadRow] {
        var rows: [V2ConversationLoadRow] = []
        rows.reserveCapacity(count)
        for id in 0..<count {
            if id.isMultiple(of: 1024) { try Task.checkCancellation() }
            rows.append(.init(id: id))
        }
        return rows
    }

    @concurrent private static func buildIndex(_ engine: RankedViewportEngine<Int>, count: Int) async throws {
        try Task.checkCancellation()
        await engine.replace(with: Array(0..<count))
    }

    func presentation(for row: V2ConversationLoadRow) -> V2ConversationListItem {
        row.presentation(at: referenceDate, sent: row.localSendRevision == 0 ? nil : chats[row.id]?.lastSent)
    }

    func openChat(id: Int) -> Bool {
        guard rowsByID.indices.contains(id), !rowsByID[id].isArchived else { return false }
        if phase == .displaying || phase == .running {
            task?.cancel()
            end(.paused)
        }
        let row = rowsByID[id]
        let item = presentation(for: row)
        let chat = chats[id] ?? V2ConversationPerformanceChat(summary: item) { [weak self] in
            await self?.recordLocalSend(id: id)
        }
        chat.visit(item, event: row.event)
        chats[id] = chat
        return true
    }

    func detailStore(for id: Int) -> V2ConversationDetailStore? { chats[id]?.makeDetailStore() }

    func returnFromChat() {
        guard phase == .paused else { return }
        phase = .displaying
        // The controller may already have reported its visible rows during the pop.
        if controller?.viewIfLoaded?.window != nil { firstRowsVisible() }
    }

    func markChatRead(id: Int) async {
        await withListMutation {
            guard rowsByID.indices.contains(id), !rowsByID[id].isArchived, rowsByID[id].unread > 0 else { return }
            var row = rowsByID[id]
            row.unread = 0
            publishRow(row)
        }
    }

    private func recordLocalSend(id: Int) async {
        await withListMutation {
            guard rowsByID.indices.contains(id), !rowsByID[id].isArchived else { return }
            var row = rowsByID[id]
            row.localSendRevision += 1
            row.unread = 0
            publishRow(row, at: row.isPinned ? 0 : pinnedCount)
        }
    }

    private func publishRow(_ row: V2ConversationLoadRow, at target: Int? = nil) {
        rowsByID[row.id] = row
        if config.scenario.usesWindow {
            guard let index = window.firstIndex(where: { $0.id == row.id }) else { return }
            if let target {
                window.remove(at: index)
                window.insert(row, at: target)
            } else {
                window[index] = row
            }
            ordered.replace(with: window)
        } else {
            ranked.enqueueRealtimeUpdate(row, targetPosition: target)
        }
    }

    func cellConfigured() { if phase == .running { configured += 1 } }

    func firstRowsVisible() {
        guard phase == .displaying else { return }
        phase = .running
        startTime = CACurrentMediaTime() - metrics.elapsed
        frames.start()
        task = Task {
            do {
                try await drive()
                try Task.checkCancellation()
                end(.finished)
            } catch is CancellationError { } catch { if !Task.isCancelled { end(.failed) } }
        }
    }

    func stop() {
        guard [.idle, .preparing, .displaying, .paused, .running].contains(phase) else { return }
        task?.cancel()
        end(.stopped)
    }

    private func end(_ finalPhase: Phase) {
        if phase == .running { publishMetrics() }
        frames.stop()
        phase = finalPhase
        task = nil
    }

    private func drive() async throws {
        // Schedule against absolute deadlines. Skip missed delivery slots under load so
        // actual throughput reflects backpressure rather than a tight catch-up loop.
        let interval = switch config.scenario {
        case .burst: 1.0
        case .seek: 1.0 / Double(config.rate)
        default: 0.1
        }
        let ticks = Int((Double(config.seconds) / interval).rounded())
        let clock = ContinuousClock()
        let origin = clock.now.advanced(by: .seconds(startTime - CACurrentMediaTime()))
        var lastReport = CACurrentMediaTime()
        while nextTick <= ticks {
            var tick = nextTick
            try await clock.sleep(until: origin.advanced(by: .seconds(Double(tick) * interval)))
            try Task.checkCancellation()
            let elapsed = CACurrentMediaTime() - startTime
            tick = min(ticks, max(tick, Int(elapsed / interval)))
            let end = Int((Double(tick) * interval * Double(config.rate)).rounded(.toNearestOrAwayFromZero))
            let previous = Int((Double(tick - 1) * interval * Double(config.rate)).rounded(.toNearestOrAwayFromZero))
            nextTick = tick + 1
            try await deliver(count: end - previous)
            try Task.checkCancellation()
            if CACurrentMediaTime() - lastReport >= 1 {
                publishMetrics()
                lastReport = CACurrentMediaTime()
            }
        }
    }

    private enum RunError: Error { case rejectedInsertion, missingList }

    /// Structural changes suspend on the sorting actor. Keep gestures and simulator
    /// batches in arrival order across that suspension.
    private func withListMutation(_ operation: () async throws -> Void) async rethrows {
        if mutatingList {
            await withCheckedContinuation { mutationWaiters.append($0) }
        }
        mutatingList = true
        defer {
            if mutationWaiters.isEmpty { mutatingList = false }
            else { mutationWaiters.removeFirst().resume() }
        }
        try await operation()
    }

    func applySwipe(_ action: V2ConversationSwipeAction, to id: Int) async {
        await withListMutation {
            guard rowsByID.indices.contains(id), !rowsByID[id].isArchived else { return }
            var row = rowsByID[id]
            let destination: Int?
            var nextPinnedCount = pinnedCount
            switch action {
            case .mute(let value):
                guard row.isMuted != value else { return }
                row.isMuted = value
                publishRow(row)
                return
            case .pin(let value):
                guard row.isPinned != value else { return }
                row.isPinned = value
                nextPinnedCount += value ? 1 : -1
                destination = value ? 0 : nextPinnedCount
            case .archive(let value):
                guard value else { return }
                if row.isPinned { nextPinnedCount -= 1 }
                row.isArchived = true
                row.isPinned = false
                destination = nil
            }

            if config.scenario.usesWindow {
                window.removeAll { $0.id == id }
                if let destination { window.insert(row, at: destination) }
                ordered.replace(with: window)
            } else {
                let insertions = destination.map { [RankedListViewport<V2ConversationLoadRow>.StructuralInsertion(row: row, position: $0)] } ?? []
                guard await ranked.applyStructuralChange(removing: [id], inserting: insertions,
                                                        pinnedCountAfterMutation: nextPinnedCount) != nil else { return }
            }
            rowsByID[id] = row
            pinnedCount = nextPinnedCount
            metrics.count = source.totalCount
        }
    }

    private func deliver(count: Int) async throws {
        guard count > 0 else { return }
        try await withListMutation {
            try Task.checkCancellation()
            switch config.scenario {
            case .seek:
                guard source.totalCount > 0 else { return }
                guard let controller else { throw RunError.missingList }
                controller.scrollToItem(at: randomIndex(limit: source.totalCount))
                delivered += 1
            case .growth:
                let insertions = (0..<count).map {
                    RankedListViewport<V2ConversationLoadRow>.StructuralInsertion(
                        row: .init(id: rowsByID.count + $0, event: delivered + $0 + 1, unread: 1), position: pinnedCount)
                }
                guard await ranked.applyStructuralChange(removing: [], inserting: insertions) != nil else { throw RunError.rejectedInsertion }
                rowsByID.append(contentsOf: insertions.map(\.row))
                delivered += count
                if phase == .stopped || phase == .paused {
                    // Stopping can coincide with an insertion already committed by the actor.
                    metrics.events = delivered
                    metrics.count = source.totalCount
                }
            case .everyday, .burst, .reorder:
                let limit = config.scenario == .burst ? min(5, config.count) : config.count
                var updates: [RankedListViewport<V2ConversationLoadRow>.RealtimeUpdate] = []
                for _ in 0..<count {
                    let id = randomIndex(limit: limit)
                    var row = rowsByID[id]
                    guard !row.isArchived else { continue }
                    delivered += 1
                    row.localSendRevision = 0
                    row.event = delivered
                    row.unread = delivered.isMultiple(of: 4) ? 0 : row.unread + 1
                    rowsByID[id] = row
                    let target = row.isPinned ? 0 : pinnedCount
                    if config.scenario.usesWindow {
                        if let index = window.firstIndex(where: { $0.id == id }) { window.remove(at: index) }
                        window.insert(row, at: target)
                    } else {
                        updates.append(.init(row: row, targetPosition: target))
                    }
                }
                if config.scenario.usesWindow { ordered.replace(with: window) }
                else { ranked.enqueueRealtimeUpdates(updates) }
            }
        }
    }

    private func randomIndex(limit: Int) -> Int {
        randomState = randomState &* 6364136223846793005 &+ 1442695040888963407
        return Int((randomState >> 32) % UInt64(limit))
    }

    private func publishMetrics() {
        metrics = .init(elapsed: CACurrentMediaTime() - startTime, events: delivered, cells: configured,
                        count: source.totalCount, frameP95: frames.p95, fps: frames.fps)
    }

    @MainActor private final class FrameSampler {
        private var link: CADisplayLink?
        private var previous: CFTimeInterval?
        private var intervals: [Double] = []

        func start() {
            let link = CADisplayLink(target: self, selector: #selector(sample(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }

        @objc private func sample(_ link: CADisplayLink) {
            if let previous, link.timestamp > previous { intervals.append(link.timestamp - previous) }
            previous = link.timestamp
        }

        var p95: Double? {
            guard !intervals.isEmpty else { return nil }
            return intervals.sorted()[Int(ceil(Double(intervals.count) * 0.95)) - 1] * 1_000
        }
        var fps: Double? {
            intervals.isEmpty ? nil : Double(intervals.count) / intervals.reduce(0, +)
        }
        func stop() { link?.invalidate(); link = nil; previous = nil }
    }
}
