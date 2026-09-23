import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2Core

/// Control-domain room creation. Only bootstrap uses explicit fixed placement;
/// after persistence, all ordinary room capabilities use RoomRef activation.
public struct V2ActorRoomCreationCoordinator: Sendable {
    private let directRoutes: any V2DirectRoomShardRouting
    private let directSelector: V2DirectRoomShardRouter
    private let groupSelector: V2GroupRoomShardSelector
    private let groupIntents: any V2GroupRoomCreationIntentStore
    private let audienceStore: any V2GroupAudienceImportStore
    private let bootstrap: V2ActorCreationBootstrapPort
    private let capacityProfile: V2CapacityProfile
    private let deliveryPolicy: V2GroupCapacityPolicy
    private let audiencePolicy: V2GroupAudienceImportPolicy?
    private let makeUUID: @Sendable () -> UUID
    private let now: @Sendable () -> Date

    public init(controlDatabase: any Database,
                directRoutes: any V2DirectRoomShardRouting,
                directSelector: V2DirectRoomShardRouter,
                groupSelector: V2GroupRoomShardSelector,
                bootstrap: V2ActorCreationBootstrapPort,
                capacityProfile: V2CapacityProfile,
                deliveryPolicy: V2GroupCapacityPolicy = .init(),
                audiencePolicy: V2GroupAudienceImportPolicy? = nil,
                makeUUID: @escaping @Sendable () -> UUID = UUID.init,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.directRoutes = directRoutes
        self.directSelector = directSelector
        self.groupSelector = groupSelector
        self.groupIntents = PostgresV2GroupRoomCreationIntentStore(database: controlDatabase)
        self.audienceStore = PostgresV2GroupAudienceImportStore(database: controlDatabase)
        self.bootstrap = bootstrap
        self.capacityProfile = capacityProfile
        self.deliveryPolicy = deliveryPolicy
        self.audiencePolicy = audiencePolicy
        self.makeUUID = makeUUID
        self.now = now
    }

    public func execute(_ input: V2ActorRoomCreationCommand,
                        deadline: ContinuousClock.Instant) async throws -> V2ActorRoomCreationResult {
        switch input {
        case .openDirect(let request):
            return .direct(.init(domain: try await openDirect(request, deadline: deadline)))
        case .createGroup(let request):
            let service = try groupService(deadline: deadline)
            return .group(.init(domain: try await service.create(
                actorUserID: request.actorUserID, operationID: request.operationID,
                title: request.title, initialMemberUserIDs: request.initialMemberUserIDs)))
        case .beginStaged(let request):
            let audience = try audienceService(deadline: deadline)
            let draft = try await audience.begin(actorUserID: request.actorUserID,
                operationID: request.operationID, title: request.validatedTitle())
            return .draft(.init(domain: draft))
        case .appendStaged(let request):
            let audience = try audienceService(deadline: deadline)
            let draft = try await audience.append(actorUserID: request.actorUserID,
                operationID: request.operationID,
                memberUserIDs: request.validatedMemberUserIDs())
            return .draft(.init(domain: draft))
        case .finalizeStaged(let request):
            let audience = try audienceService(deadline: deadline)
            let result = try await audience.finalize(actorUserID: request.actorUserID,
                operationID: request.operationID)
            return .group(.init(domain: result))
        case .cancelStaged(let request):
            let audience = try audienceService(deadline: deadline)
            try await audience.cancel(actorUserID: request.actorUserID,
                                      operationID: request.operationID)
            return .cancelled
        }
    }

    /// The existing finalizing ledger is replayed through the same typed owner bootstrap port.
    public func recoverFinalizing(limit: Int,
                                  deadline: ContinuousClock.Instant) async throws -> V2GroupAudienceRecoveryReport {
        try await audienceService(deadline: deadline).recoverFinalizing(limit: limit)
    }

    private func openDirect(_ request: V2ActorOpenDirectRoomWire,
                            deadline: ContinuousClock.Instant) async throws -> V2OpenDirectRoomOutcome {
        _ = try request.toDomain()
        let proposedShardID = directSelector.shardID(for: request.actorUserID,
                                                       and: request.targetUserID)
        let candidateRoomID = RoomID(uuid: makeUUID())
        return try await directRoutes.withDirectPairRoute(
            actorUserID: request.actorUserID,
            targetUserID: request.targetUserID,
            proposedShardID: proposedShardID
        ) { route in
            let fixed = V2ActorDirectBootstrapWire(command: request,
                roomID: candidateRoomID, roomShardID: route.shardID)
            guard case .direct(let value) = try await bootstrap.execute(.direct(fixed), deadline) else {
                throw V2GroupRoomCreationIntentStoreError.routeConflict
            }
            let outcome = try value.toDomain()
            let roomID: RoomID?
            switch outcome {
            case .opened(let room), .idempotent(let room): roomID = room.roomID
            case .idempotencyConflict, .unavailable: roomID = nil
            }
            return (outcome, roomID)
        }
    }

    private func groupService(deadline: ContinuousClock.Instant) throws -> V2GroupMessagingService {
        try .init(store: V2ActorGroupCreationStore(intents: groupIntents,
                   selector: groupSelector, bootstrap: bootstrap, deadline: deadline),
                  capacityProfile: capacityProfile, deliveryPolicy: deliveryPolicy,
                  roomShardID: groupSelector.shardIDs[0],
                  identifiers: .init(makeUUID: makeUUID), now: now)
    }

    private func audienceService(deadline: ContinuousClock.Instant) throws -> V2GroupAudienceImportService {
        .init(store: audienceStore, groupMessaging: try groupService(deadline: deadline),
              deliveryPolicy: deliveryPolicy, policy: audiencePolicy, now: now)
    }
}
