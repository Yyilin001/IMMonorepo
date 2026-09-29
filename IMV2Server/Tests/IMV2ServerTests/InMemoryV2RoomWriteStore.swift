@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure

/// Test fixture only. Production acceptance uses the PostgreSQL store below;
/// keeping this implementation actor-isolated makes service tests deterministic
/// without pretending that in-memory state is a durable backend.
actor InMemoryV2RoomWriteStore: V2RoomWriteStore {
    private var rooms: [RoomID: V2RoomCommandState]
    private var shardStates: [RoomID: ShardAdmissionState]
    private var capacityProfileIDs: [RoomID: String]
    private let authorizedActors: Set<UserID>
    private let mediaPresentationResolver: @Sendable ([V2MediaReference]) throws -> [V2MediaPresentation]

    init(
        seed: [(V2RoomCommandState, ShardAdmissionState)],
        authorizedActors: Set<UserID>,
        capacityProfileID: String = "standard",
        mediaPresentationResolver: @escaping @Sendable ([V2MediaReference]) throws -> [V2MediaPresentation] = { media in
            guard media.isEmpty else { throw V2RoomWriteStoreError.corruptPersistenceState }
            return []
        }
    ) {
        self.rooms = Dictionary(uniqueKeysWithValues: seed.map { ($0.0.roomID, $0.0) })
        self.shardStates = Dictionary(uniqueKeysWithValues: seed.map { ($0.0.roomID, $0.1) })
        self.capacityProfileIDs = Dictionary(uniqueKeysWithValues: seed.map { ($0.0.roomID, capacityProfileID) })
        self.authorizedActors = authorizedActors
        self.mediaPresentationResolver = mediaPresentationResolver
    }

    func accept(
        command: V2SendMessageCommand,
        capacityProfile: V2CapacityProfile,
        identifiers: V2AcceptanceIdentifiers,
        now: Date
    ) throws -> V2SendMessageOutcome {
        guard let room = rooms[command.roomID], let shard = shardStates[command.roomID] else {
            throw V2RoomWriteStoreError.roomNotFound
        }
        guard capacityProfileIDs[command.roomID] == capacityProfile.id else {
            throw V2RoomWriteStoreError.capacityProfileMismatch
        }
        let dedupe = V2CommandDeduplicationKey(roomID: command.roomID, senderUserID: command.senderUserID, clientMessageID: command.clientMessageID)
        if room.acceptedCommands[dedupe] != nil {
            return try reduce(command: command, room: room, shard: shard, capacityProfile: capacityProfile, identifiers: identifiers, now: now)
        }
        guard authorizedActors.contains(command.senderUserID) else {
            throw V2RoomWriteStoreError.actorNotEligible
        }
        return try reduce(command: command, room: room, shard: shard, capacityProfile: capacityProfile, identifiers: identifiers, now: now)
    }

    private func reduce(
        command: V2SendMessageCommand,
        room: V2RoomCommandState,
        shard: ShardAdmissionState,
        capacityProfile: V2CapacityProfile,
        identifiers: V2AcceptanceIdentifiers,
        now: Date
    ) throws -> V2SendMessageOutcome {
        let result = try V2SendMessageReducer.reduce(
            command: command,
            roomState: room,
            shardState: shard,
            profile: capacityProfile.limits,
            identifiers: identifiers,
            now: now
        )
        switch result {
        case .accepted(let transaction):
            let accepted = transaction.acceptedMessage.materialized(
                mediaPresentations: try mediaPresentationResolver(transaction.acceptedMessage.media)
            )
            rooms[command.roomID] = transaction.nextRoomState
            shardStates[command.roomID] = transaction.nextShardState
            return .accepted(accepted)
        case .idempotent(let message):
            return .idempotent(message.materialized(
                mediaPresentations: try mediaPresentationResolver(message.media)
            ).receipt)
        case .idempotencyConflict:
            return .idempotencyConflict
        case .rateLimited(let seconds):
            return .rateLimited(retryAfterSeconds: seconds)
        case .unavailable(let reason):
            return .unavailable(reason)
        }
    }

    func state(for roomID: RoomID) -> (V2RoomCommandState, ShardAdmissionState)? {
        guard let room = rooms[roomID], let shard = shardStates[roomID] else { return nil }
        return (room, shard)
    }
}
