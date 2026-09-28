import Foundation
import IMV2Core

/// Wire receipts are immutable proofs; projections alone cannot settle a command.
enum V2PersonalPreferenceReceiptCodec {
    static func decode(_ wire: IMV2PersonalPreferenceReceipt) throws -> V2PersonalPreferenceReceipt {
        guard let version = UInt16(exactly: wire.fingerprintVersion), wire.resolvedAtMs <= UInt64(Int64.max) else {
            throw V2RealtimeTransportError.unexpectedResponse
        }
        let account = try UserID(wire.actorUserID)
        let room = try RoomID(wire.roomID)
        let identity: V2OperationIdentity
        switch wire.kind {
        case .conversationState:
            guard wire.messageID.isEmpty else { throw V2RealtimeTransportError.unexpectedResponse }
            identity = try .init(accountID: account, scope: .room(room), operation: .conversationPreference(.init(wire.operationID)))
        case .messageFavorite:
            identity = try .init(accountID: account, scope: .message(room, .init(wire.messageID)), operation: .messageFavorite(.init(wire.operationID)))
        default: throw V2RealtimeTransportError.unexpectedResponse
        }
        let outcome: V2PersonalPreferenceTerminalOutcome
        switch wire.outcome {
        case .conversationState(let value):
            guard value.updatedAtMs >= 0, value.muteUntilMs >= 0,
                  let revision = V2PersonalPreferenceRevision(rawValue: value.revision) else { throw V2RealtimeTransportError.unexpectedResponse }
            outcome = .committed(.conversationState(try .init(roomID: .init(value.roomID), isPinned: value.isPinned,
                isArchived: value.isArchived, muteUntil: value.muteUntilMs == 0 ? nil : Date(timeIntervalSince1970: Double(value.muteUntilMs) / 1000),
                updatedAt: Date(timeIntervalSince1970: Double(value.updatedAtMs) / 1000), revision: revision)))
        case .messageFavorite(let value):
            guard value.updatedAtMs >= 0, let revision = V2PersonalPreferenceRevision(rawValue: value.revision) else { throw V2RealtimeTransportError.unexpectedResponse }
            outcome = .committed(.messageFavorite(try .init(roomID: .init(value.roomID), messageID: .init(value.messageID),
                isFavorited: value.isFavorited, updatedAt: Date(timeIntervalSince1970: Double(value.updatedAtMs) / 1000), revision: revision)))
        case .rejected(let rejection):
            switch rejection.reason {
            case .revisionConflict:
                guard rejection.hasCurrentRevision, let revision = V2PersonalPreferenceRevision(rawValue: rejection.currentRevision) else { throw V2RealtimeTransportError.unexpectedResponse }
                outcome = .rejected(.revisionConflict(current: revision))
            case .permissionDenied, .notFound, .expiredUnsubmitted:
                guard !rejection.hasCurrentRevision else { throw V2RealtimeTransportError.unexpectedResponse }
                switch rejection.reason {
                case .permissionDenied: outcome = .rejected(.permissionDenied)
                case .notFound: outcome = .rejected(.notFound)
                default: outcome = .rejected(.expiredUnsubmitted)
                }
            default: throw V2RealtimeTransportError.unexpectedResponse
            }
        case .closed(true): outcome = .closed
        default: throw V2RealtimeTransportError.unexpectedResponse
        }
        return try .init(identity: identity, fingerprint: .init(version: version, digest: wire.fingerprint),
                         outcome: outcome, resolvedAtMilliseconds: wire.resolvedAtMs)
    }
}
