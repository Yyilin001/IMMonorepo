import Foundation
import IMV2Core

public enum V2PendingSocialCommandKind: String, Equatable, Sendable { case relationship, userBlock, strangerMessagePreference, userAddPreference, readReceiptPreference }

public struct V2PendingSocialCommand: Equatable, Sendable {
    public enum State: String, Equatable, Sendable { case pending, acknowledged, rejected }
    public let operationID: String
    public let kind: V2PendingSocialCommandKind
    public let targetUserID: UserID?
    public let relationshipAction: V2RelationshipAction?
    public let blockAction: V2UserBlockAction?
    public let strangerPermission: V2StrangerMessagePermission?
    public let userAddPermission: V2UserAddPermission?
    public let allowsDirectReadReceipts: Bool?
    public let allowsGroupReadReceipts: Bool?
    public let state: State
    public let attemptCount: Int
    public let nextAttemptAt: Date
    public let terminalCode: String?

    public init(operationID: String, kind: V2PendingSocialCommandKind, targetUserID: UserID?, relationshipAction: V2RelationshipAction?, blockAction: V2UserBlockAction?, strangerPermission: V2StrangerMessagePermission?, userAddPermission: V2UserAddPermission? = nil, allowsDirectReadReceipts: Bool? = nil, allowsGroupReadReceipts: Bool? = nil, state: State, attemptCount: Int, nextAttemptAt: Date, terminalCode: String?) throws {
        let hasValidPayload: Bool
        switch kind {
        case .relationship: hasValidPayload = targetUserID != nil && relationshipAction != nil && blockAction == nil && strangerPermission == nil && userAddPermission == nil && allowsDirectReadReceipts == nil && allowsGroupReadReceipts == nil
        case .userBlock: hasValidPayload = targetUserID != nil && relationshipAction == nil && blockAction != nil && strangerPermission == nil && userAddPermission == nil && allowsDirectReadReceipts == nil && allowsGroupReadReceipts == nil
        case .strangerMessagePreference: hasValidPayload = targetUserID == nil && relationshipAction == nil && blockAction == nil && strangerPermission != nil && userAddPermission == nil && allowsDirectReadReceipts == nil && allowsGroupReadReceipts == nil
        case .userAddPreference: hasValidPayload = targetUserID == nil && relationshipAction == nil && blockAction == nil && strangerPermission == nil && userAddPermission != nil && allowsDirectReadReceipts == nil && allowsGroupReadReceipts == nil
        case .readReceiptPreference: hasValidPayload = targetUserID == nil && relationshipAction == nil && blockAction == nil && strangerPermission == nil && userAddPermission == nil && allowsDirectReadReceipts != nil && allowsGroupReadReceipts != nil
        }
        let hasValidTerminalState = state == .rejected ? terminalCode != nil : terminalCode == nil
        guard UUID(uuidString: operationID) != nil, attemptCount >= 0, hasValidPayload, hasValidTerminalState
        else { throw V2ClientCommandError.commandConflict }
        self.operationID = operationID; self.kind = kind; self.targetUserID = targetUserID; self.relationshipAction = relationshipAction; self.blockAction = blockAction; self.strangerPermission = strangerPermission; self.userAddPermission = userAddPermission; self.allowsDirectReadReceipts = allowsDirectReadReceipts; self.allowsGroupReadReceipts = allowsGroupReadReceipts; self.state = state; self.attemptCount = attemptCount; self.nextAttemptAt = nextAttemptAt; self.terminalCode = terminalCode
    }
}

public protocol V2LocalSocialCommandStore: Sendable {
    func enqueue(_ command: V2PendingSocialCommand) async throws
    /// Equivalent global preference or relationship intents retain one
    /// operation ID while pending, including across an app restart.
    func enqueueOrReusePendingSocialCommand(_ command: V2PendingSocialCommand) async throws -> V2PendingSocialCommand
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
    private let readReceiptTransport: (any V2ClientReadReceiptTransport)?
    private let makeUUID: @Sendable () -> UUID
    private let now: @Sendable () -> Date
    private let retryDelay: TimeInterval

    public init(store: any V2LocalSocialCommandStore, socialTransport: any V2ClientSocialRelationshipTransport, directTransport: any V2ClientDirectMessagingTransport, readReceiptTransport: (any V2ClientReadReceiptTransport)? = nil, makeUUID: @escaping @Sendable () -> UUID = UUID.init, now: @escaping @Sendable () -> Date = Date.init, retryDelay: TimeInterval = 1) {
        precondition(retryDelay > 0); self.store = store; self.socialTransport = socialTransport; self.directTransport = directTransport; self.readReceiptTransport = readReceiptTransport; self.makeUUID = makeUUID; self.now = now; self.retryDelay = retryDelay
    }

    @discardableResult public func enqueueRelationship(targetUserID: UserID, action: V2RelationshipAction) async throws -> V2PendingSocialCommand { try await enqueue(kind: .relationship, target: targetUserID, relationship: action, block: nil, permission: nil) }
    @discardableResult public func enqueueUserBlock(targetUserID: UserID, action: V2UserBlockAction) async throws -> V2PendingSocialCommand { try await enqueue(kind: .userBlock, target: targetUserID, relationship: nil, block: action, permission: nil) }
    @discardableResult public func enqueueStrangerMessagePermission(_ permission: V2StrangerMessagePermission) async throws -> V2PendingSocialCommand { try await enqueue(kind: .strangerMessagePreference, target: nil, relationship: nil, block: nil, permission: permission) }
    @discardableResult public func enqueueUserAddPermission(_ permission: V2UserAddPermission) async throws -> V2PendingSocialCommand { try await enqueue(kind: .userAddPreference, target: nil, relationship: nil, block: nil, permission: nil, userAddPermission: permission) }
    @discardableResult public func enqueueReadReceiptPreferences(allowsDirect: Bool, allowsGroup: Bool) async throws -> V2PendingSocialCommand { try await enqueue(kind: .readReceiptPreference, target: nil, relationship: nil, block: nil, permission: nil, allowsDirect: allowsDirect, allowsGroup: allowsGroup) }

    private func enqueue(kind: V2PendingSocialCommandKind, target: UserID?, relationship: V2RelationshipAction?, block: V2UserBlockAction?, permission: V2StrangerMessagePermission?, userAddPermission: V2UserAddPermission? = nil, allowsDirect: Bool? = nil, allowsGroup: Bool? = nil) async throws -> V2PendingSocialCommand {
        let command = try V2PendingSocialCommand(operationID: makeUUID().uuidString, kind: kind, targetUserID: target, relationshipAction: relationship, blockAction: block, strangerPermission: permission, userAddPermission: userAddPermission, allowsDirectReadReceipts: allowsDirect, allowsGroupReadReceipts: allowsGroup, state: .pending, attemptCount: 0, nextAttemptAt: now(), terminalCode: nil)
        return try await store.enqueueOrReusePendingSocialCommand(command)
    }

    /// Attempts only the command associated with one explicit UI action. An
    /// earlier queued social command remains ahead of it; callers then report
    /// a queued state rather than misattributing that earlier result.
    public func flushIfReady(operationID: String) async throws -> V2SocialCommandFlushResult? {
        guard let command = try await store.nextReadySocialCommand(now: now()),
              command.operationID == operationID
        else { return nil }
        return try await flush(command)
    }

    public func flushOnce() async throws -> V2SocialCommandFlushResult {
        guard let command = try await store.nextReadySocialCommand(now: now()) else { return .idle }
        return try await flush(command)
    }

    private func flush(_ command: V2PendingSocialCommand) async throws -> V2SocialCommandFlushResult {
        do {
            switch command.kind {
            case .relationship: _ = try await socialTransport.changeRelationship(operationID: try .init(command.operationID), targetUserID: command.targetUserID!, action: command.relationshipAction!)
            case .userBlock: _ = try await socialTransport.changeUserBlock(operationID: try .init(command.operationID), targetUserID: command.targetUserID!, action: command.blockAction!)
            case .strangerMessagePreference: _ = try await directTransport.setStrangerMessagePermission(operationID: try .init(command.operationID), permission: command.strangerPermission!)
            case .userAddPreference: _ = try await directTransport.setUserAddPermission(operationID: try .init(command.operationID), permission: command.userAddPermission!)
            case .readReceiptPreference:
                guard let readReceiptTransport else { throw V2RealtimeTransportError.unexpectedResponse }
                _ = try await readReceiptTransport.setReadReceiptPreferences(operationID: try .init(command.operationID), allowsDirectReadReceipts: command.allowsDirectReadReceipts!, allowsGroupReadReceipts: command.allowsGroupReadReceipts!)
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
