import Foundation
import IMV2ActorContracts

/// The service-role check lives at the authenticated boundary. This executor
/// binds its room authority independently of all fields supplied in the packet.
public struct V2RoomSpecialAccountAuditExecutor: Sendable {
    private let token: V2RoomActivationToken
    private let store: PostgresV2SpecialAccountMessagingStore
    private let now: @Sendable () -> Date

    public init(token: V2RoomActivationToken, store: PostgresV2SpecialAccountMessagingStore,
                now: @escaping @Sendable () -> Date = Date.init) throws {
        self.token = token
        self.store = store.usingActivationScope(try .init(tokens: [token]))
        self.now = now
    }

    public func execute(_ request: V2ActorSpecialAccountAuditWire) async throws -> V2ActorSpecialAccountAuditResultWire {
        guard request.roomID == token.roomID else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
        do {
            let input = try request.toDomain()
            try await store.record(request: input.request, account: input.account,
                                   roomID: input.roomID, outcome: input.outcome, now: now())
            return .recorded
        } catch let error as V2SpecialAccountMessagingError {
            return .failure(.init(error))
        }
    }
}

public extension V2ActorSpecialAccountFailureWire {
    init(_ error: V2SpecialAccountMessagingError) {
        switch error {
        case .invalidRequest: self = .invalidRequest
        case .accountUnavailable: self = .accountUnavailable
        case .deliveryDenied: self = .deliveryDenied
        case .idempotencyConflict: self = .idempotencyConflict
        case .unavailable: self = .unavailable
        case .corruptPersistenceState: self = .corruptPersistenceState
        }
    }

    func domainError() -> V2SpecialAccountMessagingError {
        switch self {
        case .invalidRequest: .invalidRequest
        case .accountUnavailable: .accountUnavailable
        case .deliveryDenied: .deliveryDenied
        case .idempotencyConflict: .idempotencyConflict
        case .unavailable: .unavailable
        case .corruptPersistenceState: .corruptPersistenceState
        }
    }
}
