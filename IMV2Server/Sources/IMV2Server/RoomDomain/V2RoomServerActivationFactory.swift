import FluentKit
import Foundation
import IMV2ActorContracts
import IMV2ActorRuntime
import IMV2Core
import SQLKit

/// One value per configured physical owner. Pool handles, credit caches and
/// batchers are shared across activations; they are not allocated per room.
public struct V2RoomServerOwnerResources: Sendable {
    let database: any Database
    let writes: PostgresV2RoomWriteStore
    let edits: PostgresV2MessageEditStore
    let withdrawals: PostgresV2MessageWithdrawalStore
    let reactions: PostgresV2MessageReactionStore
    let identities: any V2MembershipIdentitySnapshotValidating
    let invitationIdentities: any V2GroupInvitationIdentityReading
    let receipts: V2ActorRoomReceiptExecutor
    let receiptBatcher: V2HostRoomReceiptBatcher
    let queries: V2ActorRoomQueryExecutor
    let recovery: V2HostRoomRecoveryQueryBatcher
    let sends: V2ActorGrantedSendBatchAdapter
    let capacity: V2CapacityProfile
    let messageLimits: V2MessageCommandLimits
    let maximumEditBytes: Int

    public init(database: any Database, writes: PostgresV2RoomWriteStore,
                sendBatcher: any V2ActorGrantedSendBatching,
                membershipIdentities: any V2MembershipIdentitySnapshotValidating,
                invitationIdentities: any V2GroupInvitationIdentityReading,
                receiptShadowForwarder: any V2UserShardProjectionShadowing,
                capacityProfile: V2CapacityProfile, messageLimits: V2MessageCommandLimits,
                maximumEditBytes: Int, contentReviewMode: V2ContentReviewMode,
                queryBatchConfiguration: V2HostRoomRecoveryQueryBatcher.Configuration,
                receiptBatchConfiguration: V2ReadReceiptBatcher.Configuration = .init(
                    maximumBatchSize: 64, maximumDelay: .milliseconds(2),
                    maximumInFlightBatches: 4, maximumPendingRequests: 256),
                databaseWorkAdmission: V2DatabaseWorkAdmissionController? = nil) throws {
        guard maximumEditBytes > 0 else {
            throw V2ActorContractError.invalidConfiguration("room edit bytes")
        }
        self.database = database
        self.writes = writes
        self.edits = .init(database: database, contentReviewMode: contentReviewMode,
                           identities: membershipIdentities)
        self.withdrawals = .init(database: database)
        self.reactions = .init(database: database)
        self.identities = membershipIdentities
        self.invitationIdentities = invitationIdentities
        let receipts = V2ActorRoomReceiptExecutor(database: database, shadowForwarder: receiptShadowForwarder)
        self.receipts = receipts
        self.receiptBatcher = .init(executor: receipts,
            configuration: receiptBatchConfiguration,
            databaseWorkAdmission: databaseWorkAdmission)
        let queries = V2ActorRoomQueryExecutor(database: database)
        self.queries = queries
        self.recovery = .init(executor: queries, configuration: queryBatchConfiguration)
        self.sends = .init(batcher: sendBatcher)
        self.capacity = capacityProfile
        self.messageLimits = messageLimits
        self.maximumEditBytes = maximumEditBytes
    }
}

/// The server owns concrete domain handlers. Runtime owns scheduling and
/// lifecycle, and Cluster owns authentication/transport; neither imports Server.
public struct V2RoomServerActivationFactory: Sendable {
    private let owners: [String: V2RoomServerOwnerResources]
    private let safetyActorUserID: UserID?
    private let now: @Sendable () -> Date

    public init(owners: [String: V2RoomServerOwnerResources], safetyActorUserID: UserID?,
                now: @escaping @Sendable () -> Date = Date.init) throws {
        guard !owners.isEmpty else { throw V2ActorContractError.invalidConfiguration("room owner resources") }
        for key in owners.keys { _ = try V2RoomDataOwner(shardID: key, epoch: 0) }
        self.owners = owners
        self.safetyActorUserID = safetyActorUserID
        self.now = now
    }

    public func runtimeFactory() -> V2RoomActivationFactory<V2RoomRequest, V2RoomResponse> {
        .init { token in
            let instance = V2RoomServerActivation(token: token, resources: owners[token.owner.shardID],
                safetyActorUserID: safetyActorUserID, now: now)
            return .init(restore: { try await instance.restore(deadline: $0) },
                execute: { await instance.execute($0) },
                invalidateReservation: { await instance.invalidate($0) },
                close: { await instance.close() })
        }
    }
}

/// No membership, policy, content or cursor snapshot is used as permanent
/// authority here. Recovery rebuilds handlers and validates the durable room;
/// each operation reads its current facts under its own activation fence.
private actor V2RoomServerActivation {
    private let token: V2RoomActivationToken
    private let resources: V2RoomServerOwnerResources?
    private let safetyActorUserID: UserID?
    private let now: @Sendable () -> Date
    private var handlers: Handlers?
    private var closed = false

    init(token: V2RoomActivationToken, resources: V2RoomServerOwnerResources?,
         safetyActorUserID: UserID?, now: @escaping @Sendable () -> Date) {
        self.token = token
        self.resources = resources
        self.safetyActorUserID = safetyActorUserID
        self.now = now
    }

    func restore(deadline: ContinuousClock.Instant) async throws {
        guard !closed, handlers == nil, let resources else {
            throw V2RoomCallFailure.notAccepted(.unavailable)
        }
        guard ContinuousClock.now < deadline else { throw V2RoomCallFailure.notAccepted(.deadlineExceeded) }
        let created = try Handlers(token: token, resources: resources, now: now)
        let token = self.token
        try await V2RoomSQLDeadline.withDeadline(deadline) {
            try await v2WithRoomScopedTransaction(database: resources.database) { transaction in
                guard let sql = transaction as? any SQLDatabase else {
                    throw V2SchemaReadinessError.unsupportedDatabase
                }
                try await v2RequireRoomActivation(token: token, sql: sql)
            }
        }
        guard !closed, ContinuousClock.now < deadline else {
            throw V2RoomCallFailure.notAccepted(.deadlineExceeded)
        }
        handlers = created
    }

    func execute(_ turn: V2RoomTurn<V2RoomRequest>) async -> V2RoomTransactionCompletion<[V2RoomResponse]> {
        guard !closed, let handlers, let resources else { return .rolledBack(.notReady) }
        guard turn.context.token == token, !turn.items.isEmpty,
              turn.items.allSatisfy({ $0.request.roomID == token.roomID }),
              zip(turn.items, turn.items.dropFirst()).allSatisfy({ pair in pair.0.ordinal < pair.1.ordinal }) else {
            return .rolledBack(.invalidRequest)
        }
        // The lane only groups contiguous sends. Refuse an invalid turn before
        // entering any store, rather than partially executing mixed barriers.
        guard turn.items.count == 1 || turn.items.allSatisfy({ $0.request.canShareSendTurn }) else {
            return .rolledBack(.invalidRequest)
        }
        guard turn.items.allSatisfy({ ContinuousClock.now < $0.deadline }) else {
            return .rolledBack(.deadlineExceeded)
        }
        let callDeadline = turn.items.map(\.deadline).min()!
        do {
            return try await V2RoomSQLDeadline.withDeadline(callDeadline) {
                if turn.items.allSatisfy({ $0.request.canShareSendTurn }) {
                    let sends = turn.items.compactMap { item -> V2ActorSendMessageWire? in
                        if case .messaging(.send(let send)) = item.request { return send }
                        return nil
                    }
                    let results = try await handlers.messages.executeGrantedSendTurn(sends,
                        batchDeadline: turn.context.batchDeadline,
                        callDeadline: callDeadline, using: resources.sends)
                    guard results.count == turn.items.count else { return .outcomeUnknown }
                    return .committed(results.map(V2RoomResponse.messaging))
                }
                let item = turn.items[0]
                let response = try await dispatch(item.request, handlers: handlers, resources: resources,
                    batchDeadline: turn.context.batchDeadline, callDeadline: item.deadline)
                return .committed([response])
            }
        } catch {
            return v2RoomDomainCompletion(error)
        }
    }

    private func dispatch(_ request: V2RoomRequest, handlers: Handlers,
                          resources: V2RoomServerOwnerResources,
                          batchDeadline: ContinuousClock.Instant,
                          callDeadline: ContinuousClock.Instant) async throws -> V2RoomResponse {
        switch request {
        case .forward(let command):
            do { return .forward(try await handlers.forwarding.execute(command)) }
            catch V2ForwardExportError.ownerChanged, V2ForwardInboxError.ownerChanged {
                throw V2RoomActivationLeaseError.activationChanged
            } catch {
                if let failure = V2ActorForwardFailureWire(domainError: error) { return .forward(.failure(failure)) }
                throw error
            }
        case .mediaAuthorization(let query):
            do { return .mediaAuthorization(try await handlers.media.execute(query)) }
            catch V2MediaStoreError.downloadNotAuthorized { return .mediaAuthorization(.notVisible) }
        case .maintenance(let command):
            return .maintenance(try await handlers.maintenance.execute(command, token: token))
        case .messaging(let command):
            return .messaging(try await handlers.messages.execute(command))
        case .administration(let command):
            do {
                if case .trustedSafety(let value) = command {
                    guard let safetyActorUserID else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
                    return .administration(try await handlers.administration.executeTrustedSafety(value,
                        authority: .init(safetyActorUserID: safetyActorUserID)))
                }
                return .administration(try await handlers.administration.executeUser(command))
            } catch {
                if let failure = V2ActorAdministrationFailureWire(domainError: error) {
                    return .administration(.failure(failure))
                }
                throw error
            }
        case .administrationQuery(let query):
            do { return .administration(try await handlers.administration.execute(query)) }
            catch {
                if let failure = V2ActorAdministrationFailureWire(domainError: error) {
                    return .administration(.failure(failure))
                }
                throw error
            }
        case .receipt(let command):
            return .receipt(try await resources.receiptBatcher.record(.init(command: command, token: token,
                batchDeadline: batchDeadline, callDeadline: callDeadline, ingressAt: now())))
        case .receiptQuery(let query):
            return .receipt(try await resources.receipts.query(query, token: token))
        case .roomLog(let query):
            do { return .roomLog(try await resources.queries.log(query, token: token)) }
            catch let failure as V2GroupEventLogError { return .roomLog(.failure(.init(failure))) }
        case .directory(let query):
            return .directory(try await resources.queries.directory(query, token: token))
        case .recovery(let query):
            let granted = V2GrantedRoomReadTurn(token: token, actorUserID: query.actorUserID,
                batchDeadline: batchDeadline, callDeadline: callDeadline)
            switch query.kind {
            case .state: return .recovery(.state(.init(try await resources.recovery.state(granted))))
            case .latestVisible: return .recovery(.latestVisible(.init(try await resources.recovery.latestVisible(granted))))
            }
        case .specialAccountAudit(let command):
            return .specialAccountAudit(try await handlers.audit.execute(command))
        case .invitation(let command):
            do { return .invitation(try await handlers.invitations.execute(command)) }
            catch let failure as V2GroupInvitationServiceError { return .invitation(.failure(.init(domain: failure))) }
            catch let failure as V2GroupInvitationValidationError { return .invitation(.failure(.init(validationError: failure))) }
        case .invitationQuery(let query):
            do { return .invitation(try await handlers.invitations.execute(query)) }
            catch let failure as V2GroupInvitationServiceError { return .invitation(.failure(.init(domain: failure))) }
            catch let failure as V2GroupInvitationValidationError { return .invitation(.failure(.init(validationError: failure))) }
        }
    }

    func invalidate(_ reservation: V2RoomReservation) async {
        guard reservation.token == token, !closed else { return }
        await resources?.writes.invalidateActorHints(token: token)
    }

    func close() async {
        guard !closed else { return }
        closed = true
        handlers = nil
        await resources?.writes.closeActorState(token: token)
        await resources?.sends.retire(token)
    }

    private struct Handlers: Sendable {
        let messages: V2RoomMessagingExecutor
        let administration: V2RoomAdministrationDomainExecutor
        let audit: V2RoomSpecialAccountAuditExecutor
        let invitations: V2RoomInvitationDomainExecutor
        let maintenance: V2ActorRoomMaintenanceExecutor
        let forwarding: V2RoomForwardDomainExecutor
        let media: V2RoomMediaAuthorizationDomainExecutor

        init(token: V2RoomActivationToken, resources: V2RoomServerOwnerResources,
             now: @escaping @Sendable () -> Date) throws {
            forwarding = try .init(database: resources.database, token: token, write: resources.writes,
                capacityProfile: resources.capacity, limits: resources.messageLimits, now: now)
            media = try .init(database: resources.database, token: token)
            maintenance = .init(database: resources.database, now: now)
            messages = try .init(token: token, writes: resources.writes, edits: resources.edits,
                withdrawals: resources.withdrawals, reactions: resources.reactions,
                capacityProfile: resources.capacity, limits: resources.messageLimits,
                maximumEditBytes: resources.maximumEditBytes, now: now)
            administration = try .init(database: resources.database, token: token,
                capacityProfile: resources.capacity, membershipIdentities: resources.identities, now: now)
            audit = try .init(token: token, store: .init(database: resources.database), now: now)
            invitations = try .init(database: resources.database, token: token,
                identities: resources.invitationIdentities, capacityProfile: resources.capacity, now: now)
        }
    }
}

/// Only explicit proof of no accepted business write becomes rollback. Driver,
/// cancellation and post-COMMIT failures conservatively retire the whole turn.
func v2RoomDomainCompletion<Value: Sendable>(_ error: any Error) -> V2RoomTransactionCompletion<Value> {
    if let failure = error as? V2RoomCallFailure {
        switch failure {
        case .notAccepted(let reason), .rolledBack(let reason): return .rolledBack(reason)
        case .outcomeUnknown: return .outcomeUnknown
        }
    }
    if let failure = error as? V2RoomActivationLeaseError {
        switch failure {
        case .roomNotFound: return .rolledBack(.notFound)
        case .ownerChanged, .activationChanged: return .rolledBack(.staleActivation)
        case .leaseExpired: return .rolledBack(.leaseLost)
        case .epochExhausted, .outcomeUnknown: return .outcomeUnknown
        }
    }
    if error is V2RoomOwnerFenceError { return .rolledBack(.staleActivation) }
    if let failure = error as? V2HostRoomRecoveryBatchError {
        switch failure {
        case .busy: return .rolledBack(.overloaded)
        case .deadlineExceeded: return .rolledBack(.deadlineExceeded)
        case .oversized, .corruptResult: return .outcomeUnknown
        }
    }
    return .outcomeUnknown
}
