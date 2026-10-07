import Testing
@testable import IMV2Core

@Suite("Room synchronization observations")
struct RoomSynchronizationStateTests {
    private let room = RoomID(uuid: .init(uuidString: "00000000-0000-0000-0000-000000000001")!)

    private func state(head: UInt64 = 10, read: UInt64 = 3, own: UInt64 = 2,
                       member: UInt64 = 1, owner: UInt64 = 0, trim: UInt64 = 0) throws -> V2RoomSynchronizationState {
        try .init(roomID: room, ownerEpoch: owner, viewerMembershipRevision: member,
                  head: head, trimmedThrough: trim, readThrough: read, latestOwnMessageSequence: own)
    }

    @Test("a delayed head cannot overwrite a newer read watermark")
    func incomparableObservations() throws {
        let read = try state(head: 10, read: 9)
        let message = try state(head: 11, read: 3)
        #expect(try message.disposition(replacing: read) == .reconcile)
        #expect(try read.disposition(replacing: message) == .reconcile)
        let resolved = try state(head: 11, read: 9)
        #expect(resolved.unreadCount == 2)
        #expect(try resolved.disposition(replacing: read) == .advance)
        #expect(try resolved.disposition(replacing: message) == .advance)
    }

    @Test("replays, stale owners and newer membership intervals remain distinct")
    func versionFences() throws {
        let first = try state()
        let later = try state(head: 12, read: 10, member: 3, owner: 2, trim: 4)
        #expect(try first.disposition(replacing: first) == .unchanged)
        #expect(try first.disposition(replacing: later) == .superseded)
        #expect(try later.disposition(replacing: first) == .advance)
        #expect(try state(head: 13, owner: 0).disposition(replacing: later) == .reconcile)
    }

    @Test("own messages and zero heads preserve the existing unread contract")
    func unread() throws {
        #expect(try state(own: 9).unreadCount == 1)
        #expect(try state(head: 0, read: 0, own: 0).unreadCount == 0)
        #expect(try state(head: UInt64(Int64.max), read: 0, own: 0).unreadCount == UInt64(Int64.max))
    }

    @Test("malformed or unpersistable observations fail at construction")
    func rejectsInvalidStates() throws {
        #expect(try state(member: 0).viewerMembershipRevision == 0)
        #expect(throws: V2RoomSynchronizationError.invalidState) { try state(read: 11) }
        #expect(throws: V2RoomSynchronizationError.invalidState) { try state(own: 11) }
        #expect(throws: V2RoomSynchronizationError.invalidState) { try state(trim: 11) }
        #expect(throws: V2RoomSynchronizationError.invalidState) { try state(head: UInt64.max) }
        #expect(throws: V2RoomSynchronizationError.invalidState) { try state(owner: UInt64.max) }
    }
}
