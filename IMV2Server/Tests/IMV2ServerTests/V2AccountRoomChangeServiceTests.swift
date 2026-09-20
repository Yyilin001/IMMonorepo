import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

@Suite("Account notification service", .timeLimit(.minutes(1)))
struct V2AccountRoomChangeServiceTests {
    @Test("a stalled device overflows independently while its sibling keeps receiving", arguments: [2, 4096])
    func slowDeviceDoesNotBlockSibling(capacity: Int) async throws {
        let broker = AccountInterestProbe(), reader = AccountStateReader()
        let slow = AccountNotificationSink(pauseFirstWrite: true), fast = AccountNotificationSink()
        let interests = V2SharedGroupEventWakeInterests(underlying: broker)
        let service = try V2AccountRoomChangeService(states: reader, interests: interests, maximumPendingRooms: capacity)
        let user = UserID(uuid: UUID())
        let a = try await service.begin(userID: user, connectionID: UUID(),
            send: { await slow.send($0) }, close: { await slow.close() })
        let b = try await service.begin(userID: user, connectionID: UUID(),
            send: { await fast.send($0) }, close: { await fast.close() })
        let rooms = try (0..<(capacity + 3)).map { _ in try entry() }
        for offset in stride(from: 0, to: rooms.count, by: 100) {
            let page = Array(rooms[offset..<min(offset + 100, rooms.count)])
            try await service.install(page, ticket: a)
            try await service.install(page, ticket: b)
        }
        await service.resume(a)
        await service.resume(b)
        for (index, room) in rooms.enumerated() {
            await service.notify(roomID: room.roomID)
            await fast.waitForNotification(count: index + 1)
            if index == 0 { await slow.waitForNotification() }
        }
        let delivered = await fast.notifications
        let expected = rooms.enumerated().map { index, room in
            V2AccountRoomNotification.changed(epoch: b.epoch, sequence: UInt64(index + 1),
                roomID: room.roomID, highWatermark: 8)
        }
        #expect(delivered == expected)
        await slow.waitForNotification()
        #expect(await slow.notifications.count == 1)
        #expect(await fast.closes == 0)
        await slow.resumeWrites()
        await slow.waitForClose()
        #expect(await slow.notifications.last == .resyncRequired(epoch: a.epoch))
        #expect(await slow.notifications.count == 2)
        #expect(await broker.rooms.count == rooms.count)
        // The remaining device still owns shared membership and broker interests.
        await service.notify(roomID: rooms[0].roomID)
        await fast.waitForNotification(count: rooms.count + 1)
        #expect(await fast.notifications.last == .changed(epoch: b.epoch, sequence: UInt64(rooms.count + 1),
            roomID: rooms[0].roomID, highWatermark: 8))
        await service.shutdown()
        #expect(await broker.rooms.isEmpty)
        await interests.shutdown()
    }

    @Test("coverage loss fences an authorization read already in flight")
    func coverageLostDuringAuthorization() async throws {
        let broker = AccountInterestProbe(), reader = AccountStateReader(), sink = AccountNotificationSink()
        let interests = V2SharedGroupEventWakeInterests(underlying: broker)
        let service = try V2AccountRoomChangeService(states: reader, interests: interests)
        let ticket = try await service.begin(userID: .init(uuid: UUID()), connectionID: UUID(),
            send: { await sink.send($0) }, close: { await sink.close() })
        let room = try entry()
        try await service.install([room], ticket: ticket)
        await service.resume(ticket)
        await reader.pauseNextRead()
        await service.notify(roomID: room.roomID)
        await reader.waitForRead()
        await service.invalidateCoverage()
        await reader.releaseRead()
        await sink.waitForClose()
        await service.shutdown()
        #expect(await sink.notifications == [.resyncRequired(epoch: ticket.epoch)])
        #expect(await broker.rooms.isEmpty)
        await interests.shutdown()
    }

    @Test("a replacement connection cannot inherit an account cache being invalidated")
    func recoveringAccountFence() async throws {
        let broker = AccountInterestProbe(), reader = AccountStateReader()
        let oldSink = AccountNotificationSink(), newSink = AccountNotificationSink()
        let interests = V2SharedGroupEventWakeInterests(underlying: broker)
        let service = try V2AccountRoomChangeService(states: reader, interests: interests)
        let user = UserID(uuid: UUID())
        let old = try await service.begin(userID: user, connectionID: UUID(),
            send: { await oldSink.send($0) }, close: { await oldSink.close() })
        let room = try entry()
        try await service.install([room], ticket: old)
        await service.invalidate(userID: user)
        await #expect(throws: V2AccountRoomChangeService.Failure.staleConnection) {
            try await service.begin(userID: user, connectionID: UUID(),
                send: { await newSink.send($0) }, close: { await newSink.close() })
        }
        await service.resume(old)
        await oldSink.waitForClose()
        let fresh = try await service.begin(userID: user, connectionID: UUID(),
            send: { await newSink.send($0) }, close: { await newSink.close() })
        #expect(fresh.epoch != old.epoch)
        try await service.install([room], ticket: fresh)
        await service.resume(fresh)
        await service.notify(roomID: room.roomID)
        await newSink.waitForNotification()
        #expect(await newSink.notifications.first == .changed(epoch: fresh.epoch, sequence: 1,
            roomID: room.roomID, highWatermark: 8))
        await service.shutdown()
        await interests.shutdown()
    }

    @Test("coverage loss during broker activation rejects the directory page")
    func coverageLostDuringInstall() async throws {
        let broker = AccountInterestProbe(), reader = AccountStateReader(), sink = AccountNotificationSink()
        let interests = V2SharedGroupEventWakeInterests(underlying: broker)
        let service = try V2AccountRoomChangeService(states: reader, interests: interests)
        let ticket = try await service.begin(userID: .init(uuid: UUID()), connectionID: UUID(),
            send: { await sink.send($0) }, close: { await sink.close() })
        let room = try entry()
        await broker.pauseNext()
        let installation = Task { try await service.install([room], ticket: ticket) }
        await broker.waitUntilPaused()
        await service.invalidateCoverage()
        await broker.resume()
        await #expect(throws: V2AccountRoomChangeService.Failure.staleConnection) { try await installation.value }
        await service.resume(ticket)
        await sink.waitForClose()
        #expect(await sink.notifications == [.resyncRequired(epoch: ticket.epoch)])
        #expect(await broker.rooms.isEmpty)
        await service.shutdown()
        await interests.shutdown()
    }

    @Test("closing one device during installation preserves another device's shared coverage")
    func deviceClosesDuringInstall() async throws {
        let broker = AccountInterestProbe(), reader = AccountStateReader()
        let firstSink = AccountNotificationSink(), secondSink = AccountNotificationSink()
        let interests = V2SharedGroupEventWakeInterests(underlying: broker)
        let service = try V2AccountRoomChangeService(states: reader, interests: interests)
        let user = UserID(uuid: UUID())
        let first = try await service.begin(userID: user, connectionID: UUID(),
            send: { await firstSink.send($0) }, close: { await firstSink.close() })
        let second = try await service.begin(userID: user, connectionID: UUID(),
            send: { await secondSink.send($0) }, close: { await secondSink.close() })
        let room = try entry()
        await broker.pauseNext()
        let installation = Task { try await service.install([room], ticket: first) }
        await broker.waitUntilPaused()
        await service.stop(first)
        await broker.resume()
        await #expect(throws: V2AccountRoomChangeService.Failure.staleConnection) { try await installation.value }
        #expect(await broker.rooms.contains(room.roomID))
        await service.resume(second)
        await service.notify(roomID: room.roomID)
        await secondSink.waitForNotification()
        #expect(await secondSink.notifications.first == .changed(epoch: second.epoch, sequence: 1,
            roomID: room.roomID, highWatermark: 8))
        #expect(await secondSink.closes == 0)
        await service.shutdown()
        await interests.shutdown()
    }

    @Test("room 129 is delivered only after Ready and confirmed broker activation")
    func completeCoverage() async throws {
        let broker = AccountInterestProbe(), reader = AccountStateReader(), sink = AccountNotificationSink()
        let interests = V2SharedGroupEventWakeInterests(underlying: broker)
        let service = try V2AccountRoomChangeService(states: reader, interests: interests)
        let ticket = try await service.begin(userID: .init(uuid: UUID()), connectionID: UUID(),
            send: { await sink.send($0) }, close: { await sink.close() })
        let rooms = try (0..<129).map { _ in try entry() }
        try await service.install(Array(rooms.prefix(100)), ticket: ticket)
        try await service.install(Array(rooms.dropFirst(100)), ticket: ticket)
        #expect(await broker.rooms.count == 129)
        await service.notify(roomID: rooms[128].roomID)
        await reader.waitForRead()
        #expect(await sink.notifications.isEmpty)
        await service.resume(ticket)
        await sink.waitForNotification()
        #expect(await sink.notifications.first == .changed(epoch: ticket.epoch, sequence: 1,
            roomID: rooms[128].roomID, highWatermark: 8))
        await service.shutdown()
        #expect(await broker.rooms.isEmpty)
        await interests.shutdown()
    }

    @Test("a failed write stops draining and releases account broker demand")
    func failedWriter() async throws {
        let broker = AccountInterestProbe(), reader = AccountStateReader()
        let sink = AccountNotificationSink(accepts: false)
        let interests = V2SharedGroupEventWakeInterests(underlying: broker)
        let service = try V2AccountRoomChangeService(states: reader, interests: interests)
        let ticket = try await service.begin(userID: .init(uuid: UUID()), connectionID: UUID(),
            send: { await sink.send($0) }, close: { await sink.close() })
        let room = try entry()
        try await service.install([room], ticket: ticket)
        await service.resume(ticket)
        await service.notify(roomID: room.roomID)
        await sink.waitForClose()
        #expect(await sink.notifications.count == 1)
        #expect(await broker.rooms.isEmpty)
        await service.stop(ticket)
        #expect(await sink.closes == 1)
        await service.shutdown()
        await interests.shutdown()
    }

    @Test("authorization loss emits a recovery boundary instead of room metadata")
    func unavailable() async throws {
        let broker = AccountInterestProbe(), reader = AccountStateReader(unavailable: true)
        let sink = AccountNotificationSink()
        let interests = V2SharedGroupEventWakeInterests(underlying: broker)
        let service = try V2AccountRoomChangeService(states: reader, interests: interests)
        let ticket = try await service.begin(userID: .init(uuid: UUID()), connectionID: UUID(),
            send: { await sink.send($0) }, close: { await sink.close() })
        let room = try entry()
        try await service.install([room], ticket: ticket)
        await service.resume(ticket)
        await service.notify(roomID: room.roomID)
        await sink.waitForClose()
        #expect(await sink.notifications == [.resyncRequired(epoch: ticket.epoch)])
        #expect(await broker.rooms.isEmpty)
        await service.shutdown()
        await interests.shutdown()
    }

    @Test("personal discovery installs a room outside the scanned directory")
    func discoveryInstallsRoom() async throws {
        let broker = AccountInterestProbe(), reader = AccountStateReader(), sink = AccountNotificationSink()
        let interests = V2SharedGroupEventWakeInterests(underlying: broker)
        let service = try V2AccountRoomChangeService(states: reader, interests: interests)
        let ticket = try await service.begin(userID: .init(uuid: UUID()), connectionID: UUID(),
            send: { await sink.send($0) }, close: { await sink.close() })
        let room = try entry()
        await service.resume(ticket)
        try await service.refreshMemberships([.init(roomID: room.roomID, removedThrough: nil)], ticket: ticket)
        #expect(await broker.rooms.contains(room.roomID))
        await sink.waitForNotification()
        #expect(await sink.notifications.first == .changed(epoch: ticket.epoch, sequence: 1, roomID: room.roomID, highWatermark: 8))
        await service.shutdown()
        await interests.shutdown()
    }

    @Test("a confirmed removal releases only that room without restarting personal sync")
    func membershipRemoval() async throws {
        let broker = AccountInterestProbe(), reader = AccountStateReader(unavailable: true), sink = AccountNotificationSink()
        let interests = V2SharedGroupEventWakeInterests(underlying: broker)
        let service = try V2AccountRoomChangeService(states: reader, interests: interests)
        let ticket = try await service.begin(userID: .init(uuid: UUID()), connectionID: UUID(),
            send: { await sink.send($0) }, close: { await sink.close() })
        let removed = try entry(), retained = try entry()
        try await service.install([removed, retained], ticket: ticket)
        try await service.refreshMemberships([.init(roomID: removed.roomID, removedThrough: 2)], ticket: ticket)
        #expect(await broker.rooms == [retained.roomID])
        #expect(await sink.notifications.isEmpty)
        #expect(await sink.closes == 0)
        await service.shutdown()
        await interests.shutdown()
    }

    @Test("an old removal event uses current rejoined authorization")
    func oldRemovalAfterRejoin() async throws {
        let broker = AccountInterestProbe(), reader = AccountStateReader(revision: 3), sink = AccountNotificationSink()
        let interests = V2SharedGroupEventWakeInterests(underlying: broker)
        let service = try V2AccountRoomChangeService(states: reader, interests: interests)
        let ticket = try await service.begin(userID: .init(uuid: UUID()), connectionID: UUID(),
            send: { await sink.send($0) }, close: { await sink.close() })
        let room = try entry()
        await service.resume(ticket)
        try await service.refreshMemberships([.init(roomID: room.roomID, removedThrough: 2)], ticket: ticket)
        await sink.waitForNotification()
        #expect(await sink.notifications.first == .changed(epoch: ticket.epoch, sequence: 1, roomID: room.roomID, highWatermark: 8))
        #expect(await broker.rooms.contains(room.roomID))
        #expect(await sink.closes == 0)
        await service.shutdown()
        await interests.shutdown()
    }

    @Test("detached writer cleanup retains lifecycle ownership until interests are released")
    func detachedCleanupIsOwned() async throws {
        let broker = AccountInterestProbe(), reader = AccountStateReader(), sink = AccountNotificationSink(accepts: false)
        let interests = V2SharedGroupEventWakeInterests(underlying: broker)
        let service = try V2AccountRoomChangeService(states: reader, interests: interests)
        let ticket = try await service.begin(userID: .init(uuid: UUID()), connectionID: UUID(),
            send: { await sink.send($0) }, close: { await sink.close() })
        let room = try entry()
        try await service.install([room], ticket: ticket)
        await broker.pauseNextDeactivation()
        await service.resume(ticket)
        await service.notify(roomID: room.roomID)
        await broker.waitUntilPaused()
        await #expect(throws: V2AccountRoomChangeService.Failure.staleConnection) {
            try await service.begin(userID: ticket.userID, connectionID: ticket.connectionID,
                send: { _ in true }, close: {})
        }
        let stopping = Task { await service.stop(ticket) }
        await broker.resume()
        await stopping.value
        #expect(await broker.rooms.isEmpty)
        await service.shutdown()
        await interests.shutdown()
    }

    private func entry() throws -> V2UserRoomDirectoryEntry {
        try .init(roomID: .init(uuid: UUID()), roomKind: .group, viewerMembershipRevision: 1, ownerEpoch: 1)
    }
}

private actor AccountInterestProbe: V2GroupEventWakeInterestManaging {
    private(set) var rooms: Set<RoomID> = []
    private var shouldPause = false
    private var shouldPauseDeactivation = false
    private var paused: CheckedContinuation<Void, Never>?
    private var pauseWaiter: CheckedContinuation<Void, Never>?
    func pauseNext() { shouldPause = true }
    func pauseNextDeactivation() { shouldPauseDeactivation = true }
    func waitUntilPaused() async {
        if paused != nil { return }
        await withCheckedContinuation { pauseWaiter = $0 }
    }
    func resume() { paused?.resume(); paused = nil }
    func activate(roomID: RoomID) async throws {
        if shouldPause {
            shouldPause = false
            await withCheckedContinuation { continuation in
                paused = continuation
                pauseWaiter?.resume(); pauseWaiter = nil
            }
        }
        rooms.insert(roomID)
    }
    func deactivate(roomID: RoomID) async {
        if shouldPauseDeactivation {
            shouldPauseDeactivation = false
            await withCheckedContinuation { continuation in
                paused = continuation
                pauseWaiter?.resume(); pauseWaiter = nil
            }
        }
        rooms.remove(roomID)
    }
}

private actor AccountStateReader: V2RoomStateReading {
    let unavailable: Bool
    let revision: UInt64
    private var pauseRead = false
    private var readGate: CheckedContinuation<Void, Never>?
    func pauseNextRead() { pauseRead = true }
    func releaseRead() { readGate?.resume(); readGate = nil }
    private var read = false
    private var waiter: CheckedContinuation<Void, Never>?
    init(unavailable: Bool = false, revision: UInt64 = 1) { self.unavailable = unavailable; self.revision = revision }
    func states(roomIDs: [RoomID], actorUserID: UserID) async throws -> [RoomID: V2RoomStateReadResult] {
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
