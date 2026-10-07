@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2Core
import IMV2ActorContracts
import Testing
@testable import IMV2Server
@testable import IMV2ServerInfrastructure

@Suite("Forward routing keeps one authoritative owner per pair")
struct V2ActorForwardRoutingTests {
    @Test("pending cross-owner pairs enqueue every target before returning retryable status", arguments: [false, true])
    func crossOwnerPending(paused: Bool) async throws {
        let sourceRoom = RoomID(uuid: UUID()), targets = (0..<4).map { _ in RoomID(uuid: UUID()) }
        var routes = [sourceRoom: "a"]; for target in targets { routes[target] = "b" }
        let cross = ForwardCrossRouteProbe(paused: paused)
        let service = try V2ActorForwardingCoordinator(router: ForwardRouteDirectory(routes),
            physicalStoreKeyByShard: ["a": "database-a", "b": "database-b"],
            pair: .init { _, _ in
                Issue.record("Cross-owner work entered the local pair executor")
                throw ForwardRouteTestError.unavailable
            }, crossOwner: cross, maximumTargetConcurrency: 2, deadline: { .now + .seconds(5) })
        let sources = try (0..<3).map { _ in try V2ForwardMessageReference(roomID: sourceRoom, messageID: .init(uuid: UUID()), revision: .init(1)) }
        let command = try V2ForwardMessagesCommand(operationID: .init(uuid: UUID()), sources: sources, targetRoomIDs: targets)
        let actor = UserID(uuid: UUID())
        await #expect(throws: paused ? V2ForwardPendingError.paused : V2ForwardPendingError.pending) {
            try await service.forward(actorUserID: actor, command: command)
        }
        #expect(await cross.calls == 12)
        await cross.complete()
        let completed = try await service.forward(actorUserID: actor, command: command)
        #expect(completed.map(\.sourceMessageID) == sources.flatMap { source in targets.map { _ in source.messageID } })
        #expect(completed.map(\.targetRoomID) == sources.flatMap { _ in targets })
        #expect(completed.allSatisfy { $0.errorCode == nil })
    }

    @Test("mixed owners preserve source/target result order and bound target concurrency")
    func mixedOwners() async throws {
        let roomA = RoomID(uuid: UUID()), roomB = RoomID(uuid: UUID())
        let targets = (0..<4).map { _ in RoomID(uuid: UUID()) }
        var directory = [roomA: "a", roomB: "b"]
        for (index, target) in targets.enumerated() { directory[target] = index % 2 == 0 ? "a" : "b" }
        let router = ForwardRouteDirectory(directory)
        let monitor = ForwardRouteMonitor()
        let ownerA = ForwardRouteOwner(monitor: monitor), ownerB = ForwardRouteOwner(monitor: monitor)
        let locations = directory
        let service = try V2ActorForwardingCoordinator(router: router,
            physicalStoreKeyByShard: ["a": "database-a", "b": "database-b"],
            pair: .init { pair, _ in
                let shard = locations[pair.source.roomID]
                #expect(shard == locations[pair.targetRoomID])
                let owner = shard == "a" ? ownerA : ownerB
                let part = try V2ForwardMessagesCommand(operationID: pair.operationID,
                    sources: [pair.source], targetRoomIDs: [pair.targetRoomID])
                let result = try await owner.forward(actorUserID: pair.actorUserID, command: part)
                return .init(domain: try #require(result.first))
            }, crossOwner: ForwardCrossRouteUnavailable(), maximumTargetConcurrency: 2,
            deadline: { .now + .seconds(5) })
        let sources = try [roomA, roomB, roomA].map { V2ForwardMessageReference(roomID: $0, messageID: .init(uuid: UUID()), revision: try .init(7)) }
        let command = try V2ForwardMessagesCommand(operationID: .init(uuid: UUID()), sources: sources, targetRoomIDs: targets)
        let actor = UserID(uuid: UUID())
        let results = try await service.forward(actorUserID: actor, command: command)
        #expect(results.count == 12)
        for (sourceIndex, source) in sources.enumerated() {
            for (targetIndex, target) in targets.enumerated() {
                let result = results[sourceIndex * targets.count + targetIndex]
                #expect(result.sourceMessageID == source.messageID && result.targetRoomID == target)
                #expect(result.errorCode == (directory[source.roomID] == directory[target] ? nil : "UNAVAILABLE"))
            }
        }
        #expect(await monitor.peak == 2)
        #expect(await router.batchReads == 1)
        #expect(await router.pointReads == 0)
        for (owner, shard) in [(ownerA, "a"), (ownerB, "b")] {
            let calls = await owner.calls
            #expect(!calls.isEmpty)
            #expect(calls.allSatisfy { $0.actor == actor && $0.command.operationID == command.operationID })
            #expect(calls.allSatisfy { $0.command.sources.allSatisfy { directory[$0.roomID] == shard } })
            #expect(calls.allSatisfy { $0.command.targetRoomIDs.allSatisfy { directory[$0] == shard } })
            for target in targets where directory[target] == shard {
                let actual = calls.filter { $0.command.targetRoomIDs == [target] }.flatMap { $0.command.sources }
                #expect(actual == sources.filter { directory[$0.roomID] == shard })
            }
        }
    }

    @Test("co-located logical owners fail a directory outage before calling a message store")
    func coLocated() async throws {
        let router = ForwardRouteDirectory([:], unavailable: true)
        let owner = ForwardRouteOwner(monitor: ForwardRouteMonitor())
        let service = try V2ActorForwardingCoordinator(router: router,
            physicalStoreKeyByShard: ["a": "physical-one", "b": "physical-one"],
            pair: forwardRoutePairPort(owner), crossOwner: ForwardCrossRouteUnavailable(),
            deadline: { .now + .seconds(5) })
        let command = try makeCommand()
        await #expect(throws: ForwardRouteTestError.unavailable) {
            _ = try await service.forward(actorUserID: .init(uuid: UUID()), command: command)
        }
        #expect(await router.batchReads == 1)
        #expect(await router.pointReads == 0)
        #expect(await owner.calls.isEmpty)
    }

    @Test("logical owners sharing storage still route every pair through durable forwarding")
    func colocatedBatch() async throws {
        let sources = try (0..<3).map { _ in try V2ForwardMessageReference(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID()), revision: .init(1)) }
        let targets = (0..<4).map { _ in RoomID(uuid: UUID()) }
        let command = try V2ForwardMessagesCommand(operationID: .init(uuid: UUID()), sources: sources, targetRoomIDs: targets)
        var locations = Dictionary(uniqueKeysWithValues: sources.map { ($0.roomID, "source") })
        for target in targets { locations[target] = "target" }
        let directory = ForwardRouteDirectory(locations), owner = ForwardRouteOwner(monitor: ForwardRouteMonitor())
        let cross = ForwardCrossRouteProbe(paused: false)
        await cross.complete()
        let service = try V2ActorForwardingCoordinator(router: directory,
            physicalStoreKeyByShard: ["source": "one", "target": "one"],
            pair: forwardRoutePairPort(owner), crossOwner: cross, deadline: { .now + .seconds(5) })
        let results = try await service.forward(actorUserID: .init(uuid: UUID()), command: command)
        #expect(results.count == 12)
        #expect(await owner.calls.isEmpty)
        #expect(await cross.calls == 12)
        #expect(results.map(\.sourceMessageID) == sources.flatMap { source in targets.map { _ in source.messageID } })
        #expect(results.map(\.targetRoomID) == sources.flatMap { _ in targets })
        #expect(await directory.batchReads == 1)
        #expect(await directory.pointReads == 0)
    }

    @Test("physical aliases do not grant a pair reservation across logical owners")
    func mixedTopologyColocation() async throws {
        let command = try makeCommand()
        let router = ForwardRouteDirectory([command.sources[0].roomID: "b-source", command.targetRoomIDs[0]: "b-target"])
        let a = ForwardRouteOwner(monitor: ForwardRouteMonitor()), b = ForwardRouteOwner(monitor: ForwardRouteMonitor())
        let cross = ForwardCrossRouteProbe(paused: false)
        await cross.complete()
        let service = try V2ActorForwardingCoordinator(router: router,
            physicalStoreKeyByShard: ["a": "physical-a", "b-source": "physical-b", "b-target": "physical-b"],
            pair: forwardRoutePairPort(b), crossOwner: cross, deadline: { .now + .seconds(5) })
        let results = try await service.forward(actorUserID: .init(uuid: UUID()), command: command)
        #expect(results.count == 1 && results[0].errorCode == nil)
        #expect(await router.batchReads == 1)
        #expect(await a.calls.isEmpty)
        #expect(await b.calls.isEmpty)
        #expect(await cross.calls == 1)
        #expect(await router.pointReads == 0)
    }

    @Test("one missing room does not discard valid pairs or trigger an owner scan")
    func missingRoom() async throws {
        let command = try makeCommand()
        let missing = RoomID(uuid: UUID())
        let directory = ForwardRouteDirectory([command.sources[0].roomID: "a", command.targetRoomIDs[0]: "a"])
        let a = ForwardRouteOwner(monitor: ForwardRouteMonitor()), b = ForwardRouteOwner(monitor: ForwardRouteMonitor())
        let service = try V2ActorForwardingCoordinator(router: directory,
            physicalStoreKeyByShard: ["a": "database-a", "b": "database-b"],
            pair: forwardRoutePairPort(a), crossOwner: ForwardCrossRouteUnavailable(),
            deadline: { .now + .seconds(5) })
        let partial = try V2ForwardMessagesCommand(operationID: command.operationID, sources: command.sources, targetRoomIDs: command.targetRoomIDs + [missing])
        let results = try await service.forward(actorUserID: .init(uuid: UUID()), command: partial)
        #expect(results.map(\.errorCode) == [nil, "NOT_FOUND"])
        #expect(await directory.batchReads == 1)
        #expect(await directory.pointReads == 3)
        #expect(await a.calls.count == 1)
        #expect(await b.calls.isEmpty)
    }

    @Test("directory and owner failures never fall back to another database", arguments: [false, true])
    func noOwnerFallback(directoryFailure: Bool) async throws {
        let command = try makeCommand()
        let router = ForwardRouteDirectory([command.sources[0].roomID: "a", command.targetRoomIDs[0]: "a"], unavailable: directoryFailure)
        let a = ForwardRouteOwner(monitor: ForwardRouteMonitor(), unavailable: true)
        let b = ForwardRouteOwner(monitor: ForwardRouteMonitor())
        let service = try V2ActorForwardingCoordinator(router: router,
            physicalStoreKeyByShard: ["a": "database-a", "b": "database-b"],
            pair: forwardRoutePairPort(a), crossOwner: ForwardCrossRouteUnavailable(),
            deadline: { .now + .seconds(5) })
        await #expect(throws: ForwardRouteTestError.unavailable) {
            try await service.forward(actorUserID: .init(uuid: UUID()), command: command)
        }
        #expect(await a.calls.count == (directoryFailure ? 0 : 1))
        #expect(await router.pointReads == 0)
        #expect(await b.calls.isEmpty)
    }

    @Test("an unconfigured persisted owner fails before any message store call")
    func unknownOwner() async throws {
        let command = try makeCommand()
        let router = ForwardRouteDirectory([command.sources[0].roomID: "unconfigured", command.targetRoomIDs[0]: "a"])
        let a = ForwardRouteOwner(monitor: ForwardRouteMonitor()), b = ForwardRouteOwner(monitor: ForwardRouteMonitor())
        let service = try V2ActorForwardingCoordinator(router: router,
            physicalStoreKeyByShard: ["a": "database-a", "b": "database-b"],
            pair: forwardRoutePairPort(a), crossOwner: ForwardCrossRouteUnavailable(),
            deadline: { .now + .seconds(5) })
        await #expect(throws: V2RoomShardStorageRegistryError.unknownShardID) {
            try await service.forward(actorUserID: .init(uuid: UUID()), command: command)
        }
        #expect(await a.calls.isEmpty)
        #expect(await b.calls.isEmpty)
    }

    private func makeCommand() throws -> V2ForwardMessagesCommand {
        try .init(operationID: .init(uuid: UUID()), sources: [.init(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID()), revision: .init(1))], targetRoomIDs: [.init(uuid: UUID())])
    }

    @Test("cancelling the current coordinator joins its admitted pair task")
    func actorCoordinatorCancellation() async throws {
        let command = try makeCommand(), monitor = ForwardRouteMonitor()
        let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        defer { entered.continuation.finish() }
        let service = try V2ActorForwardingCoordinator(router: ForwardRouteDirectory([
            command.sources[0].roomID: "a", command.targetRoomIDs[0]: "a"]),
            physicalStoreKeyByShard: ["a": "database-a"], pair: .init { _, _ in
                await monitor.enter()
                entered.continuation.yield(())
                do { try await Task.sleep(for: .seconds(5)) }
                catch { await monitor.leave(); throw error }
                await monitor.leave()
                Issue.record("Cancelled pair was allowed to finish")
                throw ForwardRouteTestError.unavailable
            }, crossOwner: ForwardCrossRouteUnavailable(), deadline: { .now + .seconds(10) })
        let task = Task { try await service.forward(actorUserID: .init(uuid: UUID()), command: command) }
        var signals = entered.stream.makeAsyncIterator()
        _ = await signals.next()
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled forwarding returned results") }
        catch is CancellationError { }
        #expect(await monitor.active == 0)
    }
}

private enum ForwardRouteTestError: Error { case unavailable }

private func forwardRoutePairPort(_ owner: ForwardRouteOwner) -> V2ActorForwardPairPort {
    .init { pair, _ in
        let command = try V2ForwardMessagesCommand(operationID: pair.operationID,
            sources: [pair.source], targetRoomIDs: [pair.targetRoomID])
        let results = try await owner.forward(actorUserID: pair.actorUserID, command: command)
        return .init(domain: try #require(results.first))
    }
}

private actor ForwardRouteDirectory: V2RoomShardRouting {
    let directory: [RoomID: String]
    let unavailable: Bool
    private(set) var batchReads = 0
    private(set) var pointReads = 0
    init(_ directory: [RoomID: String], unavailable: Bool = false) { self.directory = directory; self.unavailable = unavailable }
    func route(for roomID: RoomID) throws -> V2RoomShardRoute {
        pointReads += 1
        if unavailable { throw ForwardRouteTestError.unavailable }
        guard let shard = directory[roomID] else { throw V2RoomShardRouteError.roomNotFound }
        return try .init(shardID: shard, epoch: 3)
    }
    func routes(for roomIDs: [RoomID]) throws -> [RoomID: V2RoomShardRoute] {
        batchReads += 1
        if unavailable { throw ForwardRouteTestError.unavailable }
        var result: [RoomID: V2RoomShardRoute] = [:]
        for room in roomIDs {
            guard let shard = directory[room] else { throw V2RoomShardRouteError.roomNotFound }
            result[room] = try .init(shardID: shard, epoch: 3)
        }
        return result
    }
}

private actor ForwardRouteMonitor {
    private(set) var active = 0
    private(set) var peak = 0
    func enter() { active += 1; peak = max(peak, active) }
    func leave() { active -= 1 }
}

private actor ForwardRouteOwner {
    struct Call: Sendable { let actor: UserID; let command: V2ForwardMessagesCommand }
    let monitor: ForwardRouteMonitor
    let unavailable: Bool
    private(set) var calls: [Call] = []
    init(monitor: ForwardRouteMonitor, unavailable: Bool = false) { self.monitor = monitor; self.unavailable = unavailable }
    func forward(actorUserID: UserID, command: V2ForwardMessagesCommand) async throws -> [V2ForwardMessageResult] {
        calls.append(.init(actor: actorUserID, command: command))
        if unavailable { throw ForwardRouteTestError.unavailable }
        await monitor.enter()
        do { try await Task.sleep(for: .milliseconds(20)) }
        catch { await monitor.leave(); throw error }
        await monitor.leave()
        return try command.sources.flatMap { source in try command.targetRoomIDs.map { target in
            try .init(sourceMessageID: source.messageID, targetRoomID: target, messageID: source.messageID, roomSequence: 1, errorCode: nil)
        } }
    }
}

private struct ForwardCrossRouteUnavailable: V2CrossOwnerForwarding {
    func forward(actor: UserID, operation: MessageForwardOperationID, source: V2ForwardMessageReference,
        sourceRoute: V2RoomShardRoute, target: RoomID, targetRoute: V2RoomShardRoute) async throws -> V2CrossOwnerForwardOutcome {
        #expect(sourceRoute.shardID != targetRoute.shardID)
        return .completed(try .init(sourceMessageID: source.messageID, targetRoomID: target,
            messageID: nil, roomSequence: nil, errorCode: "UNAVAILABLE"))
    }
}

private actor ForwardCrossRouteProbe: V2CrossOwnerForwarding {
    let paused: Bool
    private(set) var calls = 0
    var completed = false
    init(paused: Bool) { self.paused = paused }
    func complete() { completed = true }
    func forward(actor: UserID, operation: MessageForwardOperationID, source: V2ForwardMessageReference,
                 sourceRoute: V2RoomShardRoute, target: RoomID, targetRoute: V2RoomShardRoute) async throws -> V2CrossOwnerForwardOutcome {
        calls += 1
        if !completed { return .pending(paused: paused) }
        return .completed(try .init(sourceMessageID: source.messageID, targetRoomID: target, messageID: source.messageID, roomSequence: 1, errorCode: nil))
    }
}
