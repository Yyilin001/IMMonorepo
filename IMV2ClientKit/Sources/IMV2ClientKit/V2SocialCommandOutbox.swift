import Foundation
import IMV2Core

public enum V2PendingSocialCommandKind: String, Equatable, Sendable { case relationship, userBlock, strangerMessagePreference }

public struct V2PendingSocialCommand: Equatable, Sendable {
    public enum State: String, Equatable, Sendable { case pending, acknowledged, rejected }
    public let operationID: String
    public let kind: V2PendingSocialCommandKind
    public let targetUserID: UserID?
    public let relationshipAction: V2RelationshipAction?
    public let blockAction: V2UserBlockAction?
    public let strangerPermission: V2StrangerMessagePermission?
    public let state: State
    public let attemptCount: Int
    public let nextAttemptAt: Date
    public let terminalCode: String?

    public init(operationID: String, kind: V2PendingSocialCommandKind, targetUserID: UserID?, relationshipAction: V2RelationshipAction?, blockAction: V2UserBlockAction?, strangerPermission: V2StrangerMessagePermission?, state: State, attemptCount: Int, nextAttemptAt: Date, terminalCode: String?) throws {
        let hasValidPayload: Bool
        switch kind {
        case .relationship: hasValidPayload = targetUserID != nil && relationshipAction != nil && blockAction == nil && strangerPermission == nil
        case .userBlock: hasValidPayload = targetUserID != nil && relationshipAction == nil && blockAction != nil && strangerPermission == nil
        case .strangerMessagePreference: hasValidPayload = targetUserID == nil && relationshipAction == nil && blockAction == nil && strangerPermission != nil
        }
        let hasValidTerminalState = state == .rejected ? terminalCode != nil : terminalCode == nil
        guard UUID(uuidString: operationID) != nil, attemptCount >= 0, hasValidPayload, hasValidTerminalState
        else { throw V2ClientCommandError.commandConflict }
        self.operationID = operationID; self.kind = kind; self.targetUserID = targetUserID; self.relationshipAction = relationshipAction; self.blockAction = blockAction; self.strangerPermission = strangerPermission; self.state = state; self.attemptCount = attemptCount; self.nextAttemptAt = nextAttemptAt; self.terminalCode = terminalCode
    }
}

public protocol V2LocalSocialCommandStore: Sendable {
    func enqueue(_ command: V2PendingSocialCommand) async throws
    func nextReadySocialCommand(now: Date) async throws -> V2PendingSocialCommand?
    func markSocialCommandAcknowledged(operationID: String) async throws
    func scheduleSocialCommandRetry(operationID: String, nextAttemptAt: Date) async throws
    func rejectSocialCommand(operationID: String, code: String) async throws
}

public enum V2SocialCommandFlushResult: Equatable, Sendable { case idle, acknowledged(String), retryScheduled(String), rejected(String, code: String) }

/// Durable retry boundary for global social commands. Server responses prove
/// command acceptance; the independently delivered sync projection remains
/// the source of truth for the local read model.
public actor V2SocialCommandOutboxEngine {
    private let store: any V2LocalSocialCommandStore
    private let socialTransport: any V2ClientSocialRelationshipTransport
    private let directTransport: any V2ClientDirectMessagingTransport
    private let makeUUID: @Sendable () -> UUID
    private let now: @Sendable () -> Date
    private let retryDelay: TimeInterval

    public init(store: any V2LocalSocialCommandStore, socialTransport: any V2ClientSocialRelationshipTransport, directTransport: any V2ClientDirectMessagingTransport, makeUUID: @escaping @Sendable () -> UUID = UUID.init, now: @escaping @Sendable () -> Date = Date.init, retryDelay: TimeInterval = 1) {
        precondition(retryDelay > 0); self.store = store; self.socialTransport = socialTransport; self.directTransport = directTransport; self.makeUUID = makeUUID; self.now = now; self.retryDelay = retryDelay
    }

    @discardableResult public func enqueueRelationship(targetUserID: UserID, action: V2RelationshipAction) async throws -> V2PendingSocialCommand { try await enqueue(kind: .relationship, target: targetUserID, relationship: action, block: nil, permission: nil) }
    @discardableResult public func enqueueUserBlock(targetUserID: UserID, action: V2UserBlockAction) async throws -> V2PendingSocialCommand { try await enqueue(kind: .userBlock, target: targetUserID, relationship: nil, block: action, permission: nil) }
    @discardableResult public func enqueueStrangerMessagePermission(_ permission: V2StrangerMessagePermission) async throws -> V2PendingSocialCommand { try await enqueue(kind: .strangerMessagePreference, target: nil, relationship: nil, block: nil, permission: permission) }

    private func enqueue(kind: V2PendingSocialCommandKind, target: UserID?, relationship: V2RelationshipAction?, block: V2UserBlockAction?, permission: V2StrangerMessagePermission?) async throws -> V2PendingSocialCommand {
        let command = try V2PendingSocialCommand(operationID: makeUUID().uuidString, kind: kind, targetUserID: target, relationshipAction: relationship, blockAction: block, strangerPermission: permission, state: .pending, attemptCount: 0, nextAttemptAt: now(), terminalCode: nil)
        try await store.enqueue(command); return command
    }

    public func flushOnce() async throws -> V2SocialCommandFlushResult {
        guard let command = try await store.nextReadySocialCommand(now: now()) else { return .idle }
        do {
            switch command.kind {
            case .relationship: _ = try await socialTransport.changeRelationship(operationID: try .init(command.operationID), targetUserID: command.targetUserID!, action: command.relationshipAction!)
            case .userBlock: _ = try await socialTransport.changeUserBlock(operationID: try .init(command.operationID), targetUserID: command.targetUserID!, action: command.blockAction!)
            case .strangerMessagePreference: _ = try await directTransport.setStrangerMessagePermission(operationID: try .init(command.operationID), permission: command.strangerPermission!)
            }
            try Task.checkCancellation()
            try await store.markSocialCommandAcknowledged(operationID: command.operationID)
            return .acknowledged(command.operationID)
        } catch is CancellationError { throw CancellationError() }
        catch let error as V2RealtimeTransportError {
            if case .server(let code, let retryable, _, _) = error, !retryable {
                try await store.rejectSocialCommand(operationID: command.operationID, code: code); return .rejected(command.operationID, code: code)
            }
            let delay: TimeInterval = { if case .server(_, _, let retryAfter, _) = error { return TimeInterval(max(retryAfter, 1)) }; return retryDelay }()
            try await store.scheduleSocialCommandRetry(operationID: command.operationID, nextAttemptAt: now().addingTimeInterval(delay)); return .retryScheduled(command.operationID)
        } catch {
            try await store.scheduleSocialCommandRetry(operationID: command.operationID, nextAttemptAt: now().addingTimeInterval(retryDelay)); return .retryScheduled(command.operationID)
        }
    }
}
