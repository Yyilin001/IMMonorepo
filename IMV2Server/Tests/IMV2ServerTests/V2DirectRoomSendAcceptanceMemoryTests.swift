import Foundation
import Testing
import IMV2ActorContracts
import IMV2Core
import IMV2ServerContracts
import IMV2ServerApplication
@testable import IMV2ServerInfrastructure

struct V2DirectRoomSendAcceptanceMemoryTests {
    @Test("concurrent room reads and retirement do not affect another activation")
    func independentActivations() async throws {
        let memory = V2DirectRoomSendAcceptanceMemory()
        let first = try Fixture(sequence: 7), second = try Fixture(sequence: 31)
        memory.install(first.initialization); memory.install(second.initialization)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<64 {
                group.addTask {
                    let row = try #require(try memory.preflight(command: second.command, token: second.token,
                        policy: second.policy, ordinal: 0, now: Date()))
                    #expect(row.room.roomSequence == 31)
                }
                group.addTask {
                    memory.invalidate(first.token)
                    memory.install(first.initialization)
                }
            }
            try await group.waitForAll()
        }
        memory.invalidate(first.token)
        #expect(memory.needsInitialization(token: first.token))
        #expect(!memory.needsInitialization(token: second.token))
        #expect(try memory.accept(command: second.command, token: second.token, policy: second.policy, now: Date()) != nil)
    }

    @Test("changed policy invalidates the cached cursor before execution")
    func changedPolicy() throws {
        let memory = V2DirectRoomSendAcceptanceMemory(), fixture = try Fixture(sequence: 7)
        memory.install(fixture.initialization)
        #expect(try memory.accept(command: fixture.command, token: fixture.token, policy: fixture.policy, now: Date()) != nil)
        let blocked = V2DirectSendControlPolicy(sender: fixture.policy.sender, recipient: fixture.policy.recipient,
            blocked: true, isFriend: true, allowsStrangers: false)
        #expect(try memory.preflight(command: fixture.command, token: fixture.token, policy: blocked, ordinal: 0, now: Date()) == nil)
        #expect(memory.needsInitialization(token: fixture.token))
    }

    @Test("a revoked cursor cannot be used for the optimized write")
    func invalidCursor() throws {
        let memory = V2DirectRoomSendAcceptanceMemory(), fixture = try Fixture(sequence: 7)
        memory.install(fixture.initialization)
        memory.invalidateCursor(fixture.token)
        #expect(try memory.preflight(command: fixture.command, token: fixture.token, policy: fixture.policy, ordinal: 0, now: Date()) == nil)
        #expect(memory.needsInitialization(token: fixture.token))
        memory.install(fixture.initialization)
        let row = try #require(try memory.preflight(command: fixture.command, token: fixture.token,
            policy: fixture.policy, ordinal: 0, now: Date()))
        #expect(row.room.roomSequence == 7)
    }

    private struct Fixture: Sendable {
        let token: V2RoomActivationToken
        let initialization: V2RoomSendInitialization
        let command: V2SendMessageCommand
        let policy: V2DirectSendControlPolicy
        init(sequence: Int64) throws {
            let sender = UUID(), recipient = UUID(), room = RoomID(uuid: UUID())
            token = try .init(roomID: room, owner: .init(shardID: "room-test", epoch: 0),
                activationEpoch: .init(1), host: .init(hostID: .init(uuid: UUID()), incarnationID: UUID()))
            initialization = .init(token: token, kind: "direct", directState: .init(
                membershipRevision: 1, frozenAt: nil, roomSequence: sequence, timelineSequence: sequence,
                roomShardID: "room-test", capacityProfileID: "test", capacityClass: .standard,
                directPolicyRevision: 1, lower: sender, higher: recipient, lowerReplied: true, higherReplied: true,
                lowerVisible: true, higherVisible: true, lowerCanSend: true, higherCanSend: true,
                members: 2, totalMembers: 2, lowerMute: nil, higherMute: nil))
            command = try .init(roomID: room, senderUserID: .init(uuid: sender), clientMessageID: .init(uuid: UUID()),
                text: "memory", limits: .init(maxUTF8Bytes: 64))
            policy = .init(sender: .init(userID: sender, isActive: true, specialKind: nil, specialStatus: nil,
                    allowsServiceMessages: nil, allowsCustomerMessages: nil),
                recipient: .init(userID: recipient, isActive: true, specialKind: nil, specialStatus: nil,
                    allowsServiceMessages: nil, allowsCustomerMessages: nil), blocked: false, isFriend: true, allowsStrangers: false)
        }
    }
}
