import ConversationListKit
import Testing
@testable import IMApp

@MainActor
@Suite(.serialized)
struct V2ConversationPerformanceRunTests {
    @Test(arguments: [V2ConversationLoadScenario.everyday, .burst, .reorder, .growth])
    func deliversConfiguredWorkload(_ scenario: V2ConversationLoadScenario) async throws {
        var config = V2ConversationLoadConfig(scenario)
        config.seconds = 1
        if scenario == .growth { config.count = 50_000 }
        let run = V2ConversationPerformanceRun(config)
        defer { run.stop() }
        run.prepare()
        try await wait { run.phase == .displaying }
        #expect(run.source.totalCount == config.count)
        run.firstRowsVisible()
        try await wait { run.phase == .finished }
        let delivered = run.metrics.events
        #expect(delivered > 0 && delivered <= config.rate)
        #expect(run.metrics.count == config.count + (scenario == .growth ? delivered : 0))
        run.source.commitFrame(in: [0..<1])
        try await wait { run.source.row(at: 0)?.event == delivered }
        if scenario == .burst { #expect((run.source.row(at: 0)?.id ?? 5) < 5) }
    }

    @Test(arguments: [V2ConversationLoadScenario.burst, .reorder, .growth])
    func swipesSurviveIncomingEvents(_ scenario: V2ConversationLoadScenario) async throws {
        var config = V2ConversationLoadConfig(scenario)
        config.seconds = 1
        config.count = 5
        let run = V2ConversationPerformanceRun(config)
        defer { run.stop() }
        run.prepare()
        try await wait { run.phase == .displaying }
        let capturedID = try #require(run.source.row(at: 3)?.id)
        run.firstRowsVisible()
        await run.applySwipe(.pin(true), to: capturedID)
        await run.applySwipe(.mute(true), to: capturedID)
        await run.applySwipe(.archive(true), to: 0)
        try await wait { run.phase == .finished }
        let count = run.source.totalCount
        #expect(count == 4 + (scenario == .growth ? run.metrics.events : 0))
        run.source.commitFrame(in: [0..<count])
        try await wait {
            let rows = (0..<count).compactMap { run.source.row(at: $0) }
            return rows.count == count && rows.first?.id == capturedID && rows.first?.isMuted == true
                && rows.first?.isPinned == true && !rows.contains { $0.id == 0 }
                && rows.contains { $0.event > 0 }
        }
        await run.applySwipe(.mute(false), to: capturedID)
        await run.applySwipe(.pin(false), to: capturedID)
        run.source.commitFrame(in: [0..<count])
        try await wait { run.source.row(at: 0)?.isPinned == false && run.source.row(at: 0)?.isMuted == false }
        let lastID = try #require(run.source.row(at: count - 1)?.id)
        await run.applySwipe(.archive(true), to: lastID)
        await run.applySwipe(.pin(true), to: lastID)
        #expect(run.source.totalCount == count - 1 && run.metrics.count == count - 1)
    }

    @Test(arguments: [V2ConversationLoadScenario.everyday, .growth])
    func chatUsesBoundRoomAndOnlyCountsVisibleListTime(_ scenario: V2ConversationLoadScenario) async throws {
        var config = V2ConversationLoadConfig(scenario)
        config.count = 5
        config.seconds = 2
        let run = V2ConversationPerformanceRun(config)
        defer { run.stop() }
        run.prepare()
        try await wait { run.phase == .displaying }
        run.firstRowsVisible()
        try await Task.sleep(for: .milliseconds(250))
        run.source.commitFrame(in: [0..<run.source.totalCount])
        try await wait { run.source.row(at: 0)?.event ?? 0 > 0 }
        let row = try #require(run.source.row(at: 0))
        let item = run.presentation(for: row)
        #expect(run.openChat(id: row.id))
        #expect(run.phase == .paused)
        let elapsed = run.metrics.elapsed
        let delivered = run.metrics.events
        await run.markChatRead(id: row.id)
        let detail = try #require(run.detailStore(for: row.id))
        await detail.refresh()
        #expect(detail.title == item.title && detail.messages.last?.text == item.preview)
        detail.composer.draft = "本轮本地消息"
        await detail.sendDraft()
        #expect(detail.messages.last?.text == "本轮本地消息")
        try await Task.sleep(for: .milliseconds(150))
        #expect(run.metrics.elapsed == elapsed && run.metrics.events == delivered)
        #expect(run.openChat(id: row.id))
        let reopened = try #require(run.detailStore(for: row.id))
        await reopened.refresh()
        #expect(reopened.messages == detail.messages)
        #expect(run.openChat(id: row.id == 0 ? 1 : 0))
        let other = try #require(run.detailStore(for: row.id == 0 ? 1 : 0))
        await other.refresh()
        #expect(!other.messages.contains { $0.text == "本轮本地消息" })
        run.returnFromChat()
        run.firstRowsVisible()
        try await wait { run.phase == .finished }
        #expect(run.metrics.events > delivered && run.metrics.events <= config.rate * config.seconds)
        #expect(run.openChat(id: row.id))
        run.returnFromChat()
        #expect(run.phase == .finished)
    }

    @Test func stoppingPreparationDoesNotStartALateRun() async throws {
        let run = V2ConversationPerformanceRun(.init(.reorder))
        run.prepare()
        run.stop()
        try await Task.sleep(for: .milliseconds(200))
        run.firstRowsVisible()
        #expect(run.phase == .stopped)
        #expect(run.source.totalCount == 0 && run.metrics.events == 0)
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }
}
