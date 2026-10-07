import Foundation
import Testing
import Synchronization
import IMV2Core
import IMV2ActorContracts
import IMV2ServerContracts
@testable import IMV2ServerInfrastructure

@Suite("Bounded immutable committed facts feed")
struct V2RoomCommittedFactsFeedTests {
    @Test("lost notify does not lose contiguous immutable facts and no asynchronous work is required")
    func immutableFactsSurviveLostNotify() throws {
        let token = try activation()
        let first = message(token: token, sequence: 1)
        let second = message(token: token, sequence: 2)
        let downstream = Observer()
        let feed = V2RoomCommittedFactsFeed(downstream: downstream, notify: { _ in })
        #expect(feed.register(activation: token))
        feed.observeCommittedMessages([.accepted(second), .accepted(first), .idempotent(first.receipt)], activation: token)
        let batch = try #require(feed.take(activation: token))
        #expect(batch.activation == token)
        #expect(batch.messages == [first, second])
        #expect(batch.dirtyHighWatermark == nil)
        #expect(feed.take(activation: token) == batch)
        #expect(feed.highWatermark(activation: token) == 2)
        #expect(feed.take(activation: token) == batch)
        feed.acknowledge(activation: token, consumedThrough: 2)
        #expect(feed.take(activation: token) == nil)
        #expect(downstream.activations.withLock { $0 } == [token])
        feed.finish()
    }

    @Test("count and byte pressure coalesce repair heads instead of dropping durable responsibility")
    func pressureBecomesDirtyRepair() throws {
        let token = try activation()
        let feed = V2RoomCommittedFactsFeed(notify: { _ in }, maximumFactsPerRoom: 2)
        #expect(feed.register(activation: token))
        feed.observeCommittedMessages((1...3).map { .accepted(message(token: token, sequence: UInt64($0))) }, activation: token)
        feed.observeCommittedMessages([.accepted(message(token: token, sequence: 5))], activation: token)
        let dirty = try #require(feed.take(activation: token))
        #expect(dirty.messages.isEmpty && dirty.dirtyHighWatermark == 5)
        #expect(feed.highWatermark(activation: token) == 5)
        // Only an actually consumed repair prefix frees the mailbox.
        feed.acknowledge(activation: token, consumedThrough: 5)
        feed.observeCommittedMessages([.accepted(message(token: token, sequence: 6))], activation: token)
        #expect(feed.take(activation: token)?.messages.map(\.roomSequence) == [6])
        feed.finish()

        let small = V2RoomCommittedFactsFeed(notify: { _ in }, maximumTextBytes: 600)
        #expect(small.register(activation: token))
        small.observeCommittedMessages([.accepted(message(token: token, sequence: 1, text: String(repeating: "x", count: 200)))], activation: token)
        #expect(small.take(activation: token)?.dirtyHighWatermark == 1)
        small.finish()
    }

    @Test("conflicts and controls require durable repair while retired activations cannot enqueue facts")
    func controlsConflictsAndActivationLifecycle() throws {
        let token = try activation()
        let newer = V2RoomActivationToken(roomID: token.roomID, owner: token.owner,
            activationEpoch: try .init(2), host: token.host)
        let feed = V2RoomCommittedFactsFeed(notify: { _ in }, maximumRooms: 1)
        #expect(feed.register(activation: token))
        #expect(!feed.register(activation: newer))
        let first = message(token: token, sequence: 1)
        feed.observeCommittedMessages([.accepted(first), .accepted(first)], activation: token)
        #expect(feed.take(activation: token)?.messages.count == 1)
        feed.observeCommittedMessages([.accepted(first), .accepted(message(token: token, sequence: 1, text: "conflict"))], activation: token)
        #expect(feed.take(activation: token)?.dirtyHighWatermark == 1)
        feed.observeCommittedRoomSequence(roomID: token.roomID, roomSequence: 2, activation: token)
        #expect(feed.take(activation: token)?.dirtyHighWatermark == 2)
        feed.unregister(activation: token)
        #expect(feed.register(activation: newer))
        feed.unregister(activation: token)
        feed.observeCommittedMessages([.accepted(first)], activation: token)
        #expect(feed.take(activation: newer) == nil)
        feed.finish()
        #expect(!feed.register(activation: newer))
        feed.observeCommittedMessages([.accepted(message(token: newer, sequence: 3))], activation: newer)
        #expect(feed.take(activation: newer) == nil)
    }

    @Test("consumption ACK preserves concurrent commits and cannot clear a successor activation")
    func consumptionOwnsResponsibility() throws {
        let token = try activation()
        let feed = V2RoomCommittedFactsFeed(notify: { _ in })
        #expect(feed.register(activation: token))
        feed.observeCommittedMessages([.accepted(message(token: token, sequence: 1))], activation: token)
        let first = try #require(feed.take(activation: token))
        #expect(feed.take(activation: token) == first)
        feed.observeCommittedMessages([.accepted(message(token: token, sequence: 2))], activation: token)
        feed.acknowledge(activation: token, consumedThrough: 1)
        #expect(feed.take(activation: token)?.messages.map(\.roomSequence) == [2])
        feed.observeCommittedRoomSequence(roomID: token.roomID, roomSequence: 3, activation: token)
        feed.acknowledge(activation: token, consumedThrough: 2)
        #expect(feed.take(activation: token)?.dirtyHighWatermark == 3)
        let successor = V2RoomActivationToken(roomID: token.roomID, owner: token.owner,
            activationEpoch: try .init(2), host: token.host)
        feed.unregister(activation: token)
        #expect(feed.register(activation: successor))
        feed.observeCommittedMessages([.accepted(message(token: successor, sequence: 4))], activation: successor)
        feed.acknowledge(activation: token, consumedThrough: 4)
        #expect(feed.take(activation: successor)?.messages.map(\.roomSequence) == [4])
        feed.finish()
    }

    private func activation() throws -> V2RoomActivationToken {
        .init(roomID: RoomID(uuid: UUID()), owner: try .init(shardID: "rooms", epoch: 0),
            activationEpoch: try .init(1), host: .init(hostID: .init(uuid: UUID()), incarnationID: UUID()))
    }
    private func message(token: V2RoomActivationToken, sequence: UInt64, text: String = "committed") -> V2AcceptedMessage {
        .init(messageID: .init(uuid: UUID()), roomID: token.roomID, roomSequence: sequence,
            senderUserID: .init(uuid: UUID()), clientMessageID: .init(uuid: UUID()), text: text,
            mediaPresentations: [], groupCapacityClass: .large, sourceEventID: .init(uuid: UUID()),
            acceptedMembershipRevision: 0, createdAt: Date(timeIntervalSince1970: 1))
    }
    private final class Observer: V2CommittedMessageBatchObserving {
        let activations = Mutex<[V2RoomActivationToken]>([])
        func observeCommittedMessages(_ outcomes: [V2SendMessageOutcome], activation: V2RoomActivationToken) {
            activations.withLock { $0.append(activation) }
        }
    }
}
