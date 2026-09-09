import Foundation
import IMV2Core
import Testing
@testable import IMV2Server

@Suite("Forward routing keeps one authoritative owner per pair")
struct V2RoutedForwardMessagesServiceTests {
    @Test("pending cross-owner pairs enqueue every target before returning retryable status", arguments: [false, true])
    func crossOwnerPending(paused: Bool) async throws {
        let sourceRoom = RoomID(uuid: UUID()), targets = (0..<4).map { _ in RoomID(uuid: UUID()) }
        var routes = [sourceRoom: "a"]; for target in targets { routes[target] = "b" }
        let cross = ForwardCrossRouteProbe(paused: paused)
        let owners = ["a": ForwardRouteOwner(monitor: ForwardRouteMonitor()), "b": ForwardRouteOwner(monitor: ForwardRouteMonitor())]
        let service = try V2RoutedForwardMessagesService(router: ForwardRouteDirectory(routes), owners: owners,
            maximumTargetConcurrency: 2, crossOwner: cross)
        let sources = try (0..<3).map { _ in try V2ForwardMessageReference(roomID: sourceRoom, messageID: .init(uuid: UUID()), revision: .init(1)) }
        let command = try V2ForwardMessagesCommand(operationID: .init(uuid: UUID()), sources: sources, targetRoomIDs: targets)
        let actor = UserID(uuid: UUID())
        await #expect(throws: paused ? V2ForwardPendingError.paused : V2ForwardPendingError.pending) {
            try await service.forward(actorUserID: actor, command: command)
        }
        #expect(await cross.calls == 12)
        #expect(await owners["a"]!.calls.isEmpty)
        #expect(await owners["b"]!.calls.isEmpty)
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
        let service = try V2RoutedForwardMessagesService(router: router, owners: ["a": ownerA, "b": ownerB], maximumTargetConcurrency: 2)
        let sources = try [roomA, roomB, roomA].map { V2ForwardMessageReference(roomID: $0, messageID: .init(uuid: UUID()), revision: try .init(7)) }
        let command = try V2ForwardMessagesCommand(operationID: .init(uuid: UUID()), sources: sources, targetRoomIDs: targets)
        let actor = UserID(uuid: UUID())
        let results = try await service.forward(actorUserID: actor, command: command)
        #expect(results.count == 12)
        for (sourceIndex, source) in sources.enumerated() {
            for (targetIndex, target) in targets.enumerated() {
                let result = results[sourceIndex * targets.count + targetIndex]
                #expect(result.sourceMessageID == source.messageID && result.targetRoomID == target)
                #expect(result.errorCode == (directory[source.roomID] == directory[target] ? nil : "CROSS_OWNER_FORWARD_UNAVAILABLE"))
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
        let service = try V2RoutedForwardMessagesService(router: router, owners: ["a": owner, "b": owner], physicalStoreKeyByShard: ["a": "physical-one", "b": "physical-one"])
        let command = try makeCommand()
        await #expect(throws: ForwardRouteTestError.unavailable) {
            _ = try await service.forward(actorUserID: .init(uuid: UUID()), command: command)
        }
        #expect(await router.batchReads == 1)
        #expect(await router.pointReads == 0)
        #expect(await owner.calls.isEmpty)
    }

    @Test("colocated routes retain one complete source batch across target lanes")
    func colocatedBatch() async throws {
        let sources = try (0..<3).map { _ in try V2ForwardMessageReference(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID()), revision: .init(1)) }
        let targets = (0..<4).map { _ in RoomID(uuid: UUID()) }
        let command = try V2ForwardMessagesCommand(operationID: .init(uuid: UUID()), sources: sources, targetRoomIDs: targets)
        var locations = Dictionary(uniqueKeysWithValues: sources.map { ($0.roomID, "source") })
        for target in targets { locations[target] = "target" }
        let directory = ForwardRouteDirectory(locations), owner = ForwardRouteOwner(monitor: ForwardRouteMonitor())
        let service = try V2RoutedForwardMessagesService(router: directory, owners: ["source": owner, "target": owner], physicalStoreKeyByShard: ["source": "one", "target": "one"])
        let results = try await service.forward(actorUserID: .init(uuid: UUID()), command: command)
        #expect(results.count == 12)
        #expect(await owner.calls.map(\.command) == [command])
        #expect(await owner.receivedRoutes.first?.count == 7)
        #expect(await directory.batchReads == 1)
        #expect(await directory.pointReads == 0)
    }

    @Test("two logical owners sharing the second physical database use one local acceptance path")
    func mixedTopologyColocation() async throws {
        let command = try makeCommand()
        let router = ForwardRouteDirectory([command.sources[0].roomID: "b-source", command.targetRoomIDs[0]: "b-target"])
        let a = ForwardRouteOwner(monitor: ForwardRouteMonitor()), b = ForwardRouteOwner(monitor: ForwardRouteMonitor())
        let service = try V2RoutedForwardMessagesService(
            router: router, owners: ["a": a, "b-source": b, "b-target": b],
            physicalStoreKeyByShard: ["a": "physical-a", "b-source": "physical-b", "b-target": "physical-b"]
        )
        let results = try await service.forward(actorUserID: .init(uuid: UUID()), command: command)
        #expect(results.count == 1 && results[0].errorCode == nil)
        #expect(await router.batchReads == 1)
        #expect(await a.calls.isEmpty)
        #expect(await b.calls.map(\.command) == [command])
        let scopes = await b.receivedRoutes
        #expect(scopes.count == 1)
        #expect(scopes[0][command.sources[0].roomID] == (try .init(shardID: "b-source", epoch: 3)))
        #expect(scopes[0][command.targetRoomIDs[0]] == (try .init(shardID: "b-target", epoch: 3)))
    }

    @Test("one missing room does not discard valid pairs or trigger an owner scan")
    func missingRoom() async throws {
        let command = try makeCommand()
        let missing = RoomID(uuid: UUID())
        let directory = ForwardRouteDirectory([command.sources[0].roomID: "a", command.targetRoomIDs[0]: "a"])
        let a = ForwardRouteOwner(monitor: ForwardRouteMonitor()), b = ForwardRouteOwner(monitor: ForwardRouteMonitor())
        let service = try V2RoutedForwardMessagesService(router: directory, owners: ["a": a, "b": b])
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
        let service = try V2RoutedForwardMessagesService(router: router, owners: ["a": a, "b": b])
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
        let service = try V2RoutedForwardMessagesService(router: router, owners: ["a": a, "b": b])
        await #expect(throws: V2RoomShardStorageRegistryError.unknownShardID) {
            try await service.forward(actorUserID: .init(uuid: UUID()), command: command)
        }
        #expect(await a.calls.isEmpty)
        #expect(await b.calls.isEmpty)
    }

    private func makeCommand() throws -> V2ForwardMessagesCommand {
        try .init(operationID: .init(uuid: UUID()), sources: [.init(roomID: .init(uuid: UUID()), messageID: .init(uuid: UUID()), revision: .init(1))], targetRoomIDs: [.init(uuid: UUID())])
    }
}

private enum ForwardRouteTestError: Error { case unavailable }

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
    private var active = 0
    private(set) var peak = 0
    func enter() { active += 1; peak = max(peak, active) }
    func leave() { active -= 1 }
}

private actor ForwardRouteOwner: V2OwnerValidatedForwardMessagesHandling {
    struct Call: Sendable { let actor: UserID; let command: V2ForwardMessagesCommand }
    private(set) var receivedRoutes: [[RoomID: V2RoomShardRoute]] = []
    func forwardOwnerValidated(actorUserID: UserID, command: V2ForwardMessagesCommand, ownerRoutes: [RoomID: V2RoomShardRoute]) async throws -> [V2ForwardMessageResult] {
        receivedRoutes.append(ownerRoutes)
        return try await forward(actorUserID: actorUserID, command: command)
    }
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
