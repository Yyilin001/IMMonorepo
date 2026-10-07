import Foundation
import IMV2ActorContracts
import IMV2Core
import IMV2ServerContracts

/// Full subscription identity. A topic alone cannot identify a connection's
/// authority, and a connection ID alone cannot identify a subscription lifetime.
struct V2RealtimeRecoveryKey: Hashable, Sendable {
    let connection: UUID
    let kind: V2RealtimeTopicKind
    let id: String

    init(connection: UUID, kind: V2RealtimeTopicKind, id: String) {
        self.connection = connection; self.kind = kind
        // Local scopes use domain UUID spelling; incoming normalized SQL topic
        // keys must locate the same scope without changing its wire lifecycle.
        self.id = UUID(uuidString: id)?.uuidString ?? id
    }

    var wireScope: IMV2RealtimeCoverage.Scope {
        switch kind {
        case .userSync: .account
        case .roomEvents: .room
        case .userPresence: .presence
        case .roomTyping: .typing
        }
    }
}

/// A snapshot from the identity owner, not a second mutable connection index.
/// Every consumer must revalidate its captured lifecycle after an await.
struct V2RealtimeRecoveryConnectionContext: Sendable {
    let handle: V2ConnectionDirectory.Handle
    let accountScope: UUID?
    let registeredAt: ContinuousClock.Instant

    init(handle: V2ConnectionDirectory.Handle, accountScope: UUID?,
         registeredAt: ContinuousClock.Instant = .now) {
        self.handle = handle
        self.accountScope = accountScope
        self.registeredAt = registeredAt
    }
}

/// Prepared permission result carries its original absolute expiry across the
/// outbound handoff. Retention never refreshes the observation's authority.
struct V2PreparedPresenceHandoff: Sendable {
    let connection: UUID
    let lifecycle: UInt64
    let generation: UInt64
    let request: V2PresenceObservationRequest
    let stream: V2GatewayByteStream
    let state: V2PresenceState
    let deadline: ContinuousClock.Instant
}

/// Recovery can request a prepared observation, but it
/// cannot mutate connection indexes. Scope compensation uses the original
/// lifecycle and account owner; late work must not release a successor owner.
struct V2RealtimeRecoveryPorts: Sendable {
    let preparePresence: @Sendable (V2RealtimeRecoveryKey, UInt64, UInt64) async throws -> V2PreparedPresenceHandoff
    let compensateScope: @Sendable (V2RealtimeRecoveryKey, UInt64, UUID?, UserID) async -> Void
}
