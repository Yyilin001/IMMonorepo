@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2Core
import IMV2ActorContracts
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing
import Synchronization
@testable import IMV2ServerGateway

@Suite("Account notification service", .timeLimit(.minutes(1)))
struct V2AccountRoomChangeServiceTests {
    @Test("revocation history overflow retires coverage and releases all Owner references", arguments: [false, true])
    func historyOverflowReleasesCoverage(ready: Bool) async throws {
        let routes = AccountOnlineDeliveryProbe(), sink = AccountNotificationSink()
        let rooms = try [entry(), entry()]
        let directory = AccountMembershipDirectoryProbe(entries: rooms)
        let service = try V2AccountRoomChangeService(states: AccountStateReader(),
            directoryPage: { _, _ in await directory.page() }, maximumRevokedRoomsPerAccount: 1,
            onlineDelivery: .init(activate: { user, room, reference in try await routes.activate(user, room, reference) },
                deactivate: { reference in await routes.deactivate(reference) }))
        let ticket = try await service.begin(userID: .init(uuid: UUID()), connectionID: UUID(),
            send: { await sink.send($0) }, close: { await sink.close() })
        try await service.bootstrap(ticket)
        if ready { await service.resume(ticket) }
        #expect(await routes.count == 2)
        await directory.replace([])
        await service.refreshServerMemberships(userID: ticket.userID)
        let deadline = ContinuousClock.now + .seconds(2)
        while await sink.closes == 0, ContinuousClock.now < deadline { await Task.yield() }
        #expect(await sink.closes == 1)
        #expect(await routes.count == 0)
        #expect(await sink.notifications == (ready ? [.resyncRequired(epoch: ticket.epoch)] : []))
        await service.shutdown()
    }

    @Test("automatic bootstrap failure closes connections without waiting for directory Ready")
    func automaticBootstrapFailureBeforeReady() async throws {
        let reader = AccountStateReader(), sink = AccountNotificationSink()
        let service = try V2AccountRoomChangeService(states: reader,
            directoryPage: { _, _ in throw V2RoomRecoveryReadError.topologyChanged }, onlineDelivery: .init(activate: { _, _, _ in }, deactivate: { _ in }))
        let ticket = try await service.begin(userID: .init(uuid: UUID()), connectionID: UUID(),
            send: { await sink.send($0) }, close: { await sink.close() })
        try await service.bootstrap(ticket, waitForCompletion: false)
        let deadline = ContinuousClock.now + .seconds(2)
        while await sink.closes == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await sink.closes == 1)
        #expect(await sink.notifications.isEmpty)
        await service.stop(ticket)
        await service.shutdown()
    }

    @Test("coverage invalidation between Ready approval and write confirmation retains its boundary")
    func coverageLossWhileReadyResponseIsPending() async throws {
        let sink = AccountNotificationSink()
        let service = try V2AccountRoomChangeService(states: AccountStateReader(),
            directoryPage: { _, _ in .init(rooms: [], nextCursor: nil, topologyGeneration: "ready-race") }, onlineDelivery: .init(activate: { _, _, _ in }, deactivate: { _ in }))
        let ticket = try await service.begin(userID: .init(uuid: UUID()), connectionID: UUID(),
            send: { await sink.send($0) }, close: { await sink.close() })
        try await service.bootstrap(ticket)
        try await service.requireBootstrapReady(ticket)
        try await service.reserveReadyResponse(ticket)
        await service.invalidate(userID: ticket.userID)
        for _ in 0..<100 { await Task.yield() }
        #expect(await sink.closes == 0)
        #expect(await sink.notifications.isEmpty)
        await service.resume(ticket)
        let deadline = ContinuousClock.now + .seconds(2)
        while await sink.closes == 0, ContinuousClock.now < deadline { await Task.yield() }
        #expect(await sink.closes == 1)
        #expect(await sink.notifications == [.resyncRequired(epoch: ticket.epoch)])
        await service.shutdown()
    }

    @Test("membership removal fences a late online route activation without removing a successor",
        arguments: [(false, false), (true, false), (false, true), (true, true)])
    func removalDuringOnlineActivation(rejoin: Bool, activationFails: Bool) async throws {
        let reader = AccountStateReader(), routes = AccountOnlineDeliveryProbe()
        let service = try V2AccountRoomChangeService(states: reader,
            directoryPage: { _, _ in .init(rooms: [], nextCursor: nil, topologyGeneration: "race") },
            onlineDelivery: .init(activate: { user, room, reference in try await routes.activate(user, room, reference) },
                deactivate: { reference in await routes.deactivate(reference) }))
        let ticket = try await service.begin(userID: UserID(uuid: UUID()), connectionID: UUID(), send: { _ in true }, close: {})
        try await service.bootstrap(ticket)
        let room = try entry()
        await routes.pauseNextActivation(fails: activationFails)
        let install = Task { try await service.install([room], ticket: ticket) }
        await routes.waitForActivation()
        await reader.setUnavailable(true)
        await service.requestServerMembershipRefresh(userID: ticket.userID, rooms: [room.roomID])
        let deadline = ContinuousClock.now + .seconds(2)
        while !(await service.connections(covering: [room.roomID])).isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await service.connections(covering: [room.roomID]).isEmpty)
        if rejoin {
            let successor = try V2UserRoomDirectoryEntry(roomID: room.roomID, roomKind: .group,
                viewerMembershipRevision: room.viewerMembershipRevision + 1, ownerEpoch: room.ownerEpoch)
            try await service.install([successor], ticket: ticket)
        }
        await routes.resumeActivation()
        try await install.value
        #expect(await routes.count == (rejoin ? 1 : 0))
        #expect(await routes.rooms == (rejoin ? [room.roomID] : []))
        await service.stop(ticket)
        await service.shutdown()
    }

    @Test("an older unavailable membership result cannot revoke a newer installed grant")
    func staleRemovalPreservesNewMembership() async throws {
        let reader = AccountStateReader(), routes = AccountOnlineDeliveryProbe()
        let initial = try entry(), user = UserID(uuid: UUID())
        let service = try V2AccountRoomChangeService(states: reader,
            directoryPage: { _, _ in .init(rooms: [initial], nextCursor: nil, topologyGeneration: "race") },
            onlineDelivery: .init(activate: { user, room, reference in try await routes.activate(user, room, reference) },
                deactivate: { reference in await routes.deactivate(reference) }))
        let ticket = try await service.begin(userID: user, connectionID: UUID(), send: { _ in true }, close: {})
        try await service.bootstrap(ticket)
        await reader.setUnavailable(true)
        await reader.pauseNextRead()
        await service.requestServerMembershipRefresh(userID: user, rooms: [initial.roomID])
        await reader.waitForRead()
        let successor = try V2UserRoomDirectoryEntry(roomID: initial.roomID, roomKind: .group,
            viewerMembershipRevision: initial.viewerMembershipRevision + 1, ownerEpoch: initial.ownerEpoch)
        try await service.install([successor], ticket: ticket)
        await reader.releaseRead()
        // The following read proves the first batch has finished, rather than
        // merely observing the successor before the stale result is processed.
        let nextRoom = RoomID(uuid: UUID())
        await service.requestServerMembershipRefresh(userID: user, rooms: [nextRoom])
        let deadline = ContinuousClock.now + .seconds(2)
        while await reader.requestedRoomBatches.count < 2, ContinuousClock.now < deadline { await Task.yield() }
        #expect(await reader.requestedRoomBatches == [[initial.roomID], [nextRoom]])
        #expect(await routes.rooms == [initial.roomID])
        await service.stop(ticket)
        await service.shutdown()
    }

    @Test("membership changes during a suspended read are retained by the account worker")
    func targetedMembershipChangeDuringRead() async throws {
        let reader = AccountStateReader(), routes = AccountOnlineDeliveryProbe()
        let scans = Mutex(0)
        let service = try V2AccountRoomChangeService(states: reader,
            directoryPage: { _, _ in
                scans.withLock { $0 += 1 }
                return .init(rooms: [], nextCursor: nil, topologyGeneration: "targeted")
            }, onlineDelivery: .init(activate: { user, room, reference in try await routes.activate(user, room, reference) },
                deactivate: { reference in await routes.deactivate(reference) }))
        let user = UserID(uuid: UUID()), a = RoomID(uuid: UUID()), b = RoomID(uuid: UUID())
        let ticket = try await service.begin(userID: user, connectionID: UUID(), send: { _ in true }, close: {})
        try await service.bootstrap(ticket)
        await reader.pauseNextRead()
        await service.requestServerMembershipRefresh(userID: user, rooms: [a])
        await reader.waitForRead()
        // The first read is still suspended; these must dirty the owned worker.
        for _ in 0..<100 { await service.requestServerMembershipRefresh(userID: user, rooms: [b]) }
        await reader.releaseRead()
        let deadline = ContinuousClock.now + .seconds(2)
        while await routes.rooms != [a, b], ContinuousClock.now < deadline { await Task.yield() }
        #expect(await routes.rooms == [a, b])
        #expect(await reader.requestedRoomBatches == [[a], [b]])
        #expect(scans.withLock { $0 } == 1)
        await service.stop(ticket)
        await service.shutdown()
    }

    @Test("one membership change stays targeted with existing account coverage", arguments: [0, 1000])
    func targetedMembershipChange(existingRoomCount: Int) async throws {
        let reader = AccountStateReader(), routes = AccountOnlineDeliveryProbe()
        let scans = Mutex(0)
        let service = try V2AccountRoomChangeService(states: reader,
            directoryPage: { _, _ in
                scans.withLock { $0 += 1 }
                return .init(rooms: [], nextCursor: nil, topologyGeneration: "targeted")
            }, onlineDelivery: .init(activate: { user, room, reference in try await routes.activate(user, room, reference) },
                deactivate: { reference in await routes.deactivate(reference) }))
        let user = UserID(uuid: UUID()), room = RoomID(uuid: UUID())
        let ticket = try await service.begin(userID: user, connectionID: UUID(), send: { _ in true }, close: {})
        try await service.bootstrap(ticket)
        let existing = try (0..<existingRoomCount).map { _ in try entry() }
        for offset in stride(from: 0, to: existing.count, by: 100) {
            try await service.install(Array(existing[offset..<min(offset + 100, existing.count)]), ticket: ticket)
        }
        let originalRooms = Set(existing.map(\.roomID))
        await service.requestServerMembershipRefresh(userID: user, rooms: [room])
        let deadline = ContinuousClock.now + .seconds(2)
        while await routes.rooms != originalRooms.union([room]), ContinuousClock.now < deadline { await Task.yield() }
        #expect(await routes.rooms == originalRooms.union([room]))
        #expect(scans.withLock { $0 } == 1)
        await reader.setUnavailable(true)
        await service.requestServerMembershipRefresh(userID: user, rooms: [room])
        let removalDeadline = ContinuousClock.now + .seconds(2)
        while await routes.rooms != originalRooms, ContinuousClock.now < removalDeadline { await Task.yield() }
        #expect(await routes.rooms == originalRooms)
        #expect(scans.withLock { $0 } == 1)
        #expect(await reader.requestedRoomBatches == [[room], [room]])
        await service.stop(ticket)
        await service.shutdown()
    }

    @Test("membership refresh admission does not wait for room registration and shutdown owns its cleanup")
    func membershipRefreshAdmission() async throws {
        let reader = AccountStateReader(), routes = AccountOnlineDeliveryProbe()
        let directory = AccountMembershipDirectoryProbe(entries: [])
        let service = try V2AccountRoomChangeService(states: reader,
            directoryPage: { _, _ in await directory.page() },
            onlineDelivery: .init(activate: { user, room, reference in try await routes.activate(user, room, reference) },
                deactivate: { reference in await routes.deactivate(reference) }))
        let ticket = try await service.begin(userID: UserID(uuid: UUID()), connectionID: UUID(), send: { _ in true }, close: {})
        try await service.bootstrap(ticket)
        await directory.replace([try entry()])
        await routes.pauseNextActivation()
        await service.requestServerMembershipRefresh(userID: ticket.userID)
        await routes.waitForActivation()
        // Repeated control changes only mark the existing account worker dirty.
        await service.requestServerMembershipRefresh(userID: ticket.userID)
        let shutdown = Task { await service.shutdown() }
        await routes.resumeActivation()
        await shutdown.value
        #expect(await routes.count == 0)
    }

    @Test("server membership refresh replaces room routes without a client pull")
    func serverMembershipChanges() async throws {
        let reader = AccountStateReader(), routes = AccountOnlineDeliveryProbe()
        let a = try entry(), b = try entry(), user = UserID(uuid: UUID())
        let directory = AccountMembershipDirectoryProbe(entries: [a])
        let service = try V2AccountRoomChangeService(states: reader,
            directoryPage: { _, _ in await directory.page() },
            onlineDelivery: .init(activate: { user, room, reference in try await routes.activate(user, room, reference) },
                deactivate: { reference in await routes.deactivate(reference) }))
        let ticket = try await service.begin(userID: user, connectionID: UUID(), send: { _ in true }, close: {})
        try await service.bootstrap(ticket)
        #expect(await routes.rooms == [a.roomID])
        await directory.replace([b])
        await service.refreshServerMemberships(userID: user)
        #expect(await routes.rooms == [b.roomID])
        await service.stop(ticket)
        #expect(await routes.count == 0)
        await service.shutdown()
    }

    @Test("account room delivery is shared by devices and released after the last device")
    func sharedOnlineDeliveryLifecycle() async throws {
        let reader = AccountStateReader(), routes = AccountOnlineDeliveryProbe()
        let room = try entry(), user = UserID(uuid: UUID())
        let scans = Mutex(0), retirements = Mutex(0)
        let service = try V2AccountRoomChangeService(states: reader,
            directoryPage: { _, _ in
                scans.withLock { $0 += 1 }
                return .init(rooms: [room], nextCursor: nil, topologyGeneration: "stable")
            },
            onlineDelivery: .init(activate: { user, room, reference in try await routes.activate(user, room, reference) },
                deactivate: { reference in await routes.deactivate(reference) }))
        let a = try await service.begin(userID: user, connectionID: UUID(), send: { _ in true }, close: { retirements.withLock { $0 += 1 } })
        let b = try await service.begin(userID: user, connectionID: UUID(), send: { _ in true }, close: { retirements.withLock { $0 += 1 } })
        async let first: Void = service.bootstrap(a)
        async let second: Void = service.bootstrap(b)
        _ = try await (first, second)
        try await service.bootstrap(b)
        #expect(await routes.count == 1)
        #expect(scans.withLock { $0 } == 1)
        await service.invalidate(userID: user)
        let deadline = ContinuousClock.now + .seconds(2)
        while retirements.withLock({ $0 }) < 2, ContinuousClock.now < deadline { await Task.yield() }
        #expect(retirements.withLock { $0 } == 2)
        #expect(await routes.count == 0)
        let nextA = try await service.begin(userID: user, connectionID: a.connectionID, send: { _ in true }, close: {})
        let nextB = try await service.begin(userID: user, connectionID: b.connectionID, send: { _ in true }, close: {})
        #expect(nextA.epoch != a.epoch && nextB.epoch != b.epoch)
        async let rebuiltA: Void = service.bootstrap(nextA)
        async let rebuiltB: Void = service.bootstrap(nextB)
        _ = try await (rebuiltA, rebuiltB)
        #expect(await routes.count == 1)
        #expect(scans.withLock { $0 } == 2)
        // Late cleanup from retired device scopes must not remove successors.
        await service.stop(a)
        await service.stop(b)
        #expect(await routes.count == 1)
        await service.stop(nextA)
        #expect(await routes.count == 1)
        await service.stop(nextB)
        #expect(await routes.count == 0)
        await service.shutdown()
    }

    @Test("server bootstrap rejects a changed membership directory topology")
    func bootstrapTopologyChange() async throws {
        let reader = AccountStateReader(), sink = AccountNotificationSink()
        let room = try entry()
        let service = try V2AccountRoomChangeService(states: reader,
            directoryPage: { _, cursor in
                .init(rooms: cursor == nil ? [room] : [], nextCursor: cursor == nil ? "next" : nil,
                    topologyGeneration: cursor == nil ? "before" : "after")
            }, onlineDelivery: .init(activate: { _, _, _ in }, deactivate: { _ in }))
        let ticket = try await service.begin(userID: .init(uuid: UUID()), connectionID: UUID(),
            send: { await sink.send($0) }, close: { await sink.close() })
        await #expect(throws: V2RoomRecoveryReadError.topologyChanged) {
            try await service.bootstrap(ticket)
        }
        // The Registry owns rollback of the exact session after bootstrap fails.
        await service.stop(ticket)
        #expect(await sink.notifications.isEmpty)
        await service.shutdown()
    }

    @Test("Owner bootstrap covers 2 rooms before Ready without legacy notification work")
    func serverOwnedCoverage() async throws {
        let reader = AccountStateReader(), sink = AccountNotificationSink()
        let routes = AccountOnlineDeliveryProbe()
        let rooms = try (0..<2).map { _ in try entry() }
        let service = try V2AccountRoomChangeService(states: reader,
            directoryPage: { _, cursor in
                let page = cursor == nil ? Array(rooms.prefix(100)) : Array(rooms.dropFirst(100))
                return .init(rooms: page, nextCursor: cursor == nil && rooms.count > 100 ? "second" : nil,
                    topologyGeneration: "stable")
            }, onlineDelivery: .init(activate: { user, room, reference in try await routes.activate(user, room, reference) },
                deactivate: { reference in await routes.deactivate(reference) }))
        let ticket = try await service.begin(userID: .init(uuid: UUID()), connectionID: UUID(),
            send: { await sink.send($0) }, close: { await sink.close() })
        try await service.bootstrap(ticket)
        #expect(await routes.rooms == Set(rooms.map(\.roomID)))
        #expect(await sink.notifications.isEmpty)
        await service.resume(ticket)
        #expect(await sink.notifications.isEmpty)
        #expect(await reader.requestedRoomBatches.isEmpty)
        await service.shutdown()
        #expect(await routes.count == 0)
    }

    @Test("a replacement connection cannot inherit an account cache being invalidated")
    func recoveringAccountFence() async throws {
        let reader = AccountStateReader(), routes = AccountOnlineDeliveryProbe()
        let oldSink = AccountNotificationSink(pauseFirstWrite: true), newSink = AccountNotificationSink()
        let service = try V2AccountRoomChangeService(states: reader,
            onlineDelivery: .init(activate: { user, room, reference in try await routes.activate(user, room, reference) },
                deactivate: { reference in await routes.deactivate(reference) }))
        let user = UserID(uuid: UUID())
        let old = try await service.begin(userID: user, connectionID: UUID(),
            send: { await oldSink.send($0) }, close: { await oldSink.close() })
        let room = try entry()
        try await service.install([room], ticket: old)
        await service.resume(old)
        await service.invalidate(userID: user)
        await #expect(throws: V2AccountRoomChangeService.Failure.staleConnection) {
            try await service.begin(userID: user, connectionID: UUID(),
                send: { await newSink.send($0) }, close: { await newSink.close() })
        }
        await oldSink.waitForNotification()
        await oldSink.resumeWrites()
        await oldSink.waitForClose()
        let fresh = try await service.begin(userID: user, connectionID: UUID(),
            send: { await newSink.send($0) }, close: { await newSink.close() })
        #expect(fresh.epoch != old.epoch)
        try await service.install([room], ticket: fresh)
        await service.resume(fresh)
        #expect(await newSink.notifications.isEmpty)
        #expect(await routes.rooms == [room.roomID])
        await service.shutdown()
    }

    @Test("coverage loss during Owner activation rejects the directory page")
    func coverageLostDuringInstall() async throws {
        let reader = AccountStateReader(), sink = AccountNotificationSink()
        let routes = AccountOnlineDeliveryProbe()
        let service = try V2AccountRoomChangeService(states: reader,
            onlineDelivery: .init(activate: { user, room, reference in try await routes.activate(user, room, reference) },
                deactivate: { reference in await routes.deactivate(reference) }))
        let ticket = try await service.begin(userID: .init(uuid: UUID()), connectionID: UUID(),
            send: { await sink.send($0) }, close: { await sink.close() })
        let room = try entry()
        await routes.pauseNextActivation()
        let installation = Task { try await service.install([room], ticket: ticket) }
        await routes.waitForActivation()
        await service.invalidateCoverage()
        await routes.resumeActivation()
        await #expect(throws: V2AccountRoomChangeService.Failure.staleConnection) { try await installation.value }
        await service.resume(ticket)
        await sink.waitForClose()
        #expect(await sink.notifications.isEmpty)
        #expect(await routes.count == 0)
        await service.shutdown()
    }

    @Test("closing one device during installation preserves another device's shared coverage")
    func deviceClosesDuringInstall() async throws {
        let reader = AccountStateReader(), routes = AccountOnlineDeliveryProbe()
        let firstSink = AccountNotificationSink(), secondSink = AccountNotificationSink()
        let service = try V2AccountRoomChangeService(states: reader,
            onlineDelivery: .init(activate: { user, room, reference in try await routes.activate(user, room, reference) },
                deactivate: { reference in await routes.deactivate(reference) }))
        let user = UserID(uuid: UUID())
        let first = try await service.begin(userID: user, connectionID: UUID(),
            send: { await firstSink.send($0) }, close: { await firstSink.close() })
        let second = try await service.begin(userID: user, connectionID: UUID(),
            send: { await secondSink.send($0) }, close: { await secondSink.close() })
        let room = try entry()
        await routes.pauseNextActivation()
        let installation = Task { try await service.install([room], ticket: first) }
        await routes.waitForActivation()
        await service.stop(first)
        await routes.resumeActivation()
        await #expect(throws: V2AccountRoomChangeService.Failure.staleConnection) { try await installation.value }
        #expect(await routes.rooms == [room.roomID])
        try await service.install([room], ticket: second)
        await service.resume(second)
        #expect(await secondSink.notifications.isEmpty)
        #expect(await secondSink.closes == 0)
        #expect(await routes.count == 1)
        await service.stop(second)
        #expect(await routes.count == 0)
        await service.shutdown()
    }

    @Test("device departure before or after ticket removal preserves sibling coverage", arguments: [false, true])
    func departedBootstrapFailurePreservesSibling(physicalRemovalFirst: Bool) async throws {
        let routes = AccountOnlineDeliveryProbe(), room = try entry()
        let sink = AccountNotificationSink()
        let service = try V2AccountRoomChangeService(states: AccountStateReader(),
            directoryPage: { _, _ in .init(rooms: [room], nextCursor: nil, topologyGeneration: "handover") },
            onlineDelivery: .init(activate: { user, room, reference in try await routes.activate(user, room, reference) },
                deactivate: { reference in await routes.deactivate(reference) }))
        let first = try await service.begin(userID: .init(uuid: UUID()), connectionID: UUID(), send: { _ in true }, close: {})
        await routes.pauseNextActivation(failure: physicalRemovalFirst ? .refused(.unavailable) : .closed)
        try await service.bootstrap(first, waitForCompletion: false)
        await routes.waitForActivation()
        let second = try await service.begin(userID: first.userID, connectionID: UUID(),
            send: { await sink.send($0) }, close: { await sink.close() })
        if physicalRemovalFirst {
            await routes.resumeActivation()
            // The physical Registry has removed the socket, but its ticket
            // cleanup has not run yet. Retry must preserve the account.
            while await routes.activationAttempts < 2 { await Task.yield() }
            await service.stop(first)
        } else {
            await service.stop(first)
            await routes.resumeActivation()
        }
        try await service.bootstrap(second)
        try await service.requireBootstrapReady(second)
        #expect(await routes.activationAttempts == 2)
        #expect(await routes.rooms == [room.roomID])
        #expect(await sink.closes == 0)
        await service.stop(second)
        #expect(await routes.count == 0)
        await service.shutdown()
    }

    @Test("Owner bootstrap covers 129 rooms before Ready without legacy notification work")
    func completeCoverage() async throws {
        let reader = AccountStateReader(), sink = AccountNotificationSink()
        let routes = AccountOnlineDeliveryProbe()
        let rooms = try (0..<129).map { _ in try entry() }
        let service = try V2AccountRoomChangeService(states: reader,
            directoryPage: { _, cursor in
                let page = cursor == nil ? Array(rooms.prefix(100)) : Array(rooms.dropFirst(100))
                return .init(rooms: page, nextCursor: cursor == nil && rooms.count > 100 ? "second" : nil,
                    topologyGeneration: "stable")
            }, onlineDelivery: .init(activate: { user, room, reference in try await routes.activate(user, room, reference) },
                deactivate: { reference in await routes.deactivate(reference) }))
        let ticket = try await service.begin(userID: .init(uuid: UUID()), connectionID: UUID(),
            send: { await sink.send($0) }, close: { await sink.close() })
        try await service.bootstrap(ticket)
        #expect(await routes.rooms == Set(rooms.map(\.roomID)))
        #expect(await sink.notifications.isEmpty)
        await service.resume(ticket)
        #expect(await sink.notifications.isEmpty)
        #expect(await reader.requestedRoomBatches.isEmpty)
        await service.shutdown()
        #expect(await routes.count == 0)
    }

    @Test("a failed write stops draining and releases account Owner routes")
    func failedWriter() async throws {
        let reader = AccountStateReader()
        let sink = AccountNotificationSink(accepts: false)
        let routes = AccountOnlineDeliveryProbe()
        let service = try V2AccountRoomChangeService(states: reader,
            onlineDelivery: .init(activate: { user, room, reference in try await routes.activate(user, room, reference) },
                deactivate: { reference in await routes.deactivate(reference) }))
        let ticket = try await service.begin(userID: .init(uuid: UUID()), connectionID: UUID(),
            send: { await sink.send($0) }, close: { await sink.close() })
        let room = try entry()
        try await service.install([room], ticket: ticket)
        await service.resume(ticket)
        await service.invalidate(userID: ticket.userID)
        await sink.waitForClose()
        #expect(await sink.notifications.count == 1)
        #expect(await routes.count == 0)
        await service.stop(ticket)
        #expect(await sink.closes == 1)
        await service.shutdown()
    }

    @Test("membership removal retires only its Owner route without invalidating the account")
    func unavailable() async throws {
        let reader = AccountStateReader()
        let sink = AccountNotificationSink()
        let routes = AccountOnlineDeliveryProbe()
        let service = try V2AccountRoomChangeService(states: reader, directoryPage: { _, _ in .init(rooms: [], nextCursor: nil, topologyGeneration: "stable") },
            onlineDelivery: .init(activate: { user, room, reference in try await routes.activate(user, room, reference) },
                deactivate: { reference in await routes.deactivate(reference) }))
        let ticket = try await service.begin(userID: .init(uuid: UUID()), connectionID: UUID(),
            send: { await sink.send($0) }, close: { await sink.close() })
        let room = try entry()
        try await service.install([room], ticket: ticket)
        await service.resume(ticket)
        await reader.setUnavailable(true)
        await service.requestServerMembershipRefresh(userID: ticket.userID, rooms: [room.roomID])
        let deadline = ContinuousClock.now + .seconds(2)
        while await routes.count != 0, ContinuousClock.now < deadline { await Task.yield() }
        #expect(await routes.count == 0)
        #expect(await service.connections(covering: [room.roomID]).isEmpty)
        #expect(await sink.notifications.isEmpty)
        #expect(await sink.closes == 0)
        await service.shutdown()
    }

    @Test("detached writer cleanup retains lifecycle ownership until Owner routes are released")
    func detachedCleanupIsOwned() async throws {
        let reader = AccountStateReader(), sink = AccountNotificationSink(accepts: false)
        let routes = AccountOnlineDeliveryProbe()
        let service = try V2AccountRoomChangeService(states: reader,
            onlineDelivery: .init(activate: { user, room, reference in try await routes.activate(user, room, reference) },
                deactivate: { reference in await routes.deactivate(reference) }))
        let ticket = try await service.begin(userID: .init(uuid: UUID()), connectionID: UUID(),
            send: { await sink.send($0) }, close: { await sink.close() })
        let room = try entry()
        try await service.install([room], ticket: ticket)
        await routes.pauseNextDeactivation()
        await service.resume(ticket)
        await service.invalidate(userID: ticket.userID)
        await routes.waitForDeactivation()
        await #expect(throws: V2AccountRoomChangeService.Failure.staleConnection) {
            try await service.begin(userID: ticket.userID, connectionID: ticket.connectionID,
                send: { _ in true }, close: {})
        }
        let stopping = Task { await service.stop(ticket) }
        await routes.resumeDeactivation()
        await stopping.value
        #expect(await routes.count == 0)
        await service.shutdown()
    }

    @Test("membership refresh retains changes while initial coverage owns installation")
    func refreshWaitsForInitialBootstrap() async throws {
        let reader = AccountStateReader(), initial = try entry()
        let routes = AccountOnlineDeliveryProbe()
        let added = RoomID(uuid: UUID())
        let service = try V2AccountRoomChangeService(states: reader,
            directoryPage: { _, _ in .init(rooms: [initial], nextCursor: nil, topologyGeneration: "bootstrap") },
            onlineDelivery: .init(activate: { user, room, reference in try await routes.activate(user, room, reference) },
                deactivate: { reference in await routes.deactivate(reference) }))
        let ticket = try await service.begin(userID: UserID(uuid: UUID()), connectionID: UUID(), send: { _ in true }, close: {})
        await routes.pauseNextActivation()
        let bootstrap = Task { try await service.bootstrap(ticket) }
        await routes.waitForActivation()
        await service.requestServerMembershipRefresh(userID: ticket.userID, rooms: [added])
        for _ in 0..<100 { await Task.yield() }
        #expect(await reader.requestedRoomBatches.isEmpty)
        await routes.resumeActivation()
        try await bootstrap.value
        let deadline = ContinuousClock.now + .seconds(2)
        while await routes.rooms != [initial.roomID, added], ContinuousClock.now < deadline { await Task.yield() }
        #expect(await routes.rooms == [initial.roomID, added])
        #expect(await reader.requestedRoomBatches.contains([added]))
        await service.stop(ticket)
        await service.shutdown()
    }

    @Test("authentication starts owned coverage without waiting for temporary Owner admission or route recovery",
        arguments: [V2RoomSubscriptionFailure.overloaded, .unavailable])
    func bootstrapRecoversOwnerBusyWithoutRepeatingDiscovery(reason: V2RoomSubscriptionFailure) async throws {
        let reader = AccountStateReader(), routes = AccountOnlineDeliveryProbe()
        let initial = try entry(), scans = Mutex(0)
        let service = try V2AccountRoomChangeService(states: reader,
            directoryPage: { _, _ in
                scans.withLock { $0 += 1 }
                return .init(rooms: [initial], nextCursor: nil, topologyGeneration: "busy")
            }, onlineDelivery: .init(activate: { user, room, reference in try await routes.activate(user, room, reference) },
                deactivate: { reference in await routes.deactivate(reference) }))
        let ticket = try await service.begin(userID: UserID(uuid: UUID()), connectionID: UUID(), send: { _ in true }, close: {})
        await routes.refuseNextActivations(2, reason: reason)
        try await service.bootstrap(ticket, waitForCompletion: false)
        #expect(await routes.activationAttempts < 3)
        await #expect(throws: V2RealtimePublicationBackpressure.receiverQueue) {
            try await service.requireBootstrapReady(ticket)
        }
        // No second bootstrap, directory listener or client pull drives retries.
        let deadline = ContinuousClock.now + .seconds(3)
        while await routes.count == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        try await service.requireBootstrapReady(ticket)
        #expect(await routes.activationAttempts == 3)
        #expect(await routes.count == 1)
        #expect(scans.withLock { $0 } == 1)
        for _ in 0..<100 { await Task.yield() }
        #expect(await reader.requestedRoomBatches.isEmpty)
        await service.stop(ticket)
        #expect(await routes.count == 0)
        await service.shutdown()
    }

    @Test("device retirement joins unavailable Owner installation before a successor begins")
    func unavailableOwnerRetryStopsWithItsDevice() async throws {
        let routes = AccountOnlineDeliveryProbe(), initial = try entry()
        let service = try V2AccountRoomChangeService(states: AccountStateReader(),
            directoryPage: { _, _ in .init(rooms: [initial], nextCursor: nil, topologyGeneration: "retirement") },
            onlineDelivery: .init(activate: { user, room, reference in try await routes.activate(user, room, reference) },
                deactivate: { reference in await routes.deactivate(reference) }))
        let ticket = try await service.begin(userID: .init(uuid: UUID()), connectionID: UUID(), send: { _ in true }, close: {})
        await routes.refuseNextActivations(Int.max, reason: .unavailable)
        try await service.bootstrap(ticket, waitForCompletion: false)
        let deadline = ContinuousClock.now + .seconds(2)
        while await routes.activationAttempts == 0, ContinuousClock.now < deadline { await Task.yield() }
        #expect(await routes.activationAttempts > 0)
        await service.stop(ticket)
        #expect(await service.connections(covering: [initial.roomID]).isEmpty)
        #expect(await routes.count == 0)
        await routes.refuseNextActivations(0)
        let successor = try await service.begin(userID: ticket.userID, connectionID: ticket.connectionID,
            send: { _ in true }, close: {})
        try await service.bootstrap(successor)
        #expect(successor.epoch != ticket.epoch)
        #expect(await routes.count == 1)
        await service.stop(ticket)
        #expect(await routes.count == 1)
        await service.stop(successor)
        #expect(await routes.count == 0)
        await service.shutdown()
    }

    private func entry() throws -> V2UserRoomDirectoryEntry {
        try .init(roomID: .init(uuid: UUID()), roomKind: .group, viewerMembershipRevision: 1, ownerEpoch: 1)
    }
}

private actor AccountOnlineDeliveryProbe {
    private var routes: [UUID: RoomID] = [:]
    private var refusedActivations = 0
    private(set) var activationAttempts = 0
    private var refusal: V2RoomSubscriptionFailure = .overloaded
    func refuseNextActivations(_ count: Int, reason: V2RoomSubscriptionFailure = .overloaded) {
        refusedActivations = count; refusal = reason
    }
    private var pause = false
    private var pausedActivationFailure: V2GatewayRoomSubscriptionCoordinationError?
    private var activation: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    func pauseNextActivation(fails: Bool = false, failure: V2GatewayRoomSubscriptionCoordinationError? = nil) {
        pause = true; pausedActivationFailure = failure ?? (fails ? .superseded : nil)
    }
    func waitForActivation() async {
        if activation != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func resumeActivation() { activation?.resume(); activation = nil }
    var count: Int { routes.count }
    var rooms: Set<RoomID> { Set(routes.values) }
    func activate(_ user: UserID, _ room: RoomID, _ reference: UUID) async throws {
        activationAttempts += 1
        if refusedActivations > 0 {
            refusedActivations -= 1
            throw V2GatewayRoomSubscriptionCoordinationError.refused(refusal)
        }
        if pause {
            pause = false
            let failure = pausedActivationFailure
            await withCheckedContinuation { activation = $0; waiter?.resume(); waiter = nil }
            if let failure { throw failure }
        }
        routes[reference] = room
    }
    private var pauseDeactivation = false
    private var deactivation: CheckedContinuation<Void, Never>?
    private var deactivationWaiter: CheckedContinuation<Void, Never>?
    func pauseNextDeactivation() { pauseDeactivation = true }
    func waitForDeactivation() async {
        if deactivation != nil { return }
        await withCheckedContinuation { deactivationWaiter = $0 }
    }
    func resumeDeactivation() { deactivation?.resume(); deactivation = nil }
    func deactivate(_ reference: UUID) async {
        if pauseDeactivation {
            pauseDeactivation = false
            await withCheckedContinuation {
                deactivation = $0; deactivationWaiter?.resume(); deactivationWaiter = nil
            }
        }
        routes.removeValue(forKey: reference)
    }
}

private actor AccountMembershipDirectoryProbe {
    private var entries: [V2UserRoomDirectoryEntry]
    init(entries: [V2UserRoomDirectoryEntry]) { self.entries = entries }
    func replace(_ entries: [V2UserRoomDirectoryEntry]) { self.entries = entries }
    func page() -> V2UserRoomDirectoryPage { .init(rooms: entries, nextCursor: nil, topologyGeneration: "stable") }
}

private actor AccountStateReader: V2RoomStateReading {
    var unavailable: Bool
    private(set) var requestedRoomBatches: [[RoomID]] = []
    func setUnavailable(_ value: Bool) { unavailable = value }
    let revision: UInt64
    private var pauseRead = false
    private var readGate: CheckedContinuation<Void, Never>?
    func pauseNextRead() { pauseRead = true }
    func releaseRead() { readGate?.resume(); readGate = nil }
    private var read = false
    private var waiter: CheckedContinuation<Void, Never>?
    init(unavailable: Bool = false, revision: UInt64 = 1) { self.unavailable = unavailable; self.revision = revision }
    func states(roomIDs: [RoomID], actorUserID: UserID) async throws -> [RoomID: V2RoomStateReadResult] {
        requestedRoomBatches.append(roomIDs)
        if pauseRead {
            pauseRead = false
            await withCheckedContinuation { continuation in
                readGate = continuation
                read = true; waiter?.resume(); waiter = nil
            }
        } else { read = true; waiter?.resume(); waiter = nil }
        return try Dictionary(uniqueKeysWithValues: roomIDs.map { room in
            (room, unavailable ? .unavailable : .state(try .init(roomID: room, ownerEpoch: 1,
                viewerMembershipRevision: revision, head: 8, trimmedThrough: 0, readThrough: 0,
                latestOwnMessageSequence: 0)))
        })
    }
    func hasRead() -> Bool { read }
    func waitForRead() async {
        if read { return }
        await withCheckedContinuation { waiter = $0 }
    }
}

private actor AccountNotificationSink {
    let accepts: Bool
    private(set) var notifications: [V2AccountRoomNotification] = []
    private(set) var closes = 0
    private var notificationWaiter: CheckedContinuation<Void, Never>?
    private var closeWaiter: CheckedContinuation<Void, Never>?
    private var pauseFirstWrite: Bool
    private var writeGate: CheckedContinuation<Void, Never>?
    private var notificationTarget = 1
    init(accepts: Bool = true, pauseFirstWrite: Bool = false) {
        self.accepts = accepts; self.pauseFirstWrite = pauseFirstWrite
    }
    func resumeWrites() { writeGate?.resume(); writeGate = nil }
    func send(_ notification: V2AccountRoomNotification) async -> Bool {
        notifications.append(notification)
        if notifications.count >= notificationTarget {
            notificationWaiter?.resume(); notificationWaiter = nil
        }
        if pauseFirstWrite {
            pauseFirstWrite = false
            await withCheckedContinuation { writeGate = $0 }
        }
        return accepts
    }
    func close() {
        closes += 1
        closeWaiter?.resume(); closeWaiter = nil
    }
    func waitForNotification(count: Int = 1) async {
        if notifications.count >= count { return }
        notificationTarget = count
        await withCheckedContinuation { notificationWaiter = $0 }
    }
    func waitForClose() async {
        if closes > 0 { return }
        await withCheckedContinuation { closeWaiter = $0 }
    }
}
