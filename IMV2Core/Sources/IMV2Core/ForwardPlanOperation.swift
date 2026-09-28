import Foundation

public enum V2ForwardPlanValidationError: Error, Equatable, Sendable { case invalidPlan, invalidReceipt, invalidProgress }

public struct V2ForwardPlanOperationCommand: Codable, Equatable, Sendable {
    public let actorUserID: UserID
    public let command: V2ForwardMessagesCommand
    public let firstSubmissionDeadlineMilliseconds: UInt64
    public init(actorUserID: UserID, command: V2ForwardMessagesCommand, firstSubmissionDeadlineMilliseconds: UInt64) throws {
        try validateMessageOperationDeadline(firstSubmissionDeadlineMilliseconds)
        _ = try V2OperationIdentity(accountID: actorUserID, scope: .account(actorUserID), operation: .forwardMessage(command.operationID))
        self.actorUserID = actorUserID
        self.command = command
        self.firstSubmissionDeadlineMilliseconds = firstSubmissionDeadlineMilliseconds
    }
    public static let sourcesPerChild = 20
    public var operationID: MessageForwardOperationID { command.operationID }
    public var childCount: UInt64 { UInt64((command.sources.count + Self.sourcesPerChild - 1) / Self.sourcesPerChild * command.targetRoomIDs.count) }
    public var identity: V2OperationIdentity { get throws {
        try .init(accountID: actorUserID, scope: .account(actorUserID), operation: .forwardMessage(operationID))
    } }
    public var fingerprint: V2OperationFingerprint { get throws {
        try .init(kind: .forwardMessage, fields: [
            .init("identity", .text(identity.storageKey)),
            .init("sources", .orderedText(command.sources.flatMap { [$0.roomID.rawValue, $0.messageID.rawValue, String($0.revision.rawValue)] })),
            .init("targets", .orderedText(command.targetRoomIDs.map(\.rawValue))),
            .init("sourcesPerChild", .unsigned(UInt64(Self.sourcesPerChild))),
            .init("firstSubmissionDeadline", .unsigned(firstSubmissionDeadlineMilliseconds))
        ])
    } }
    public func childCommand(index: UInt64) throws -> V2ForwardMessagesCommand {
        guard index < childCount else { throw V2ForwardPlanValidationError.invalidPlan }
        let offset = Int(index) / command.targetRoomIDs.count * Self.sourcesPerChild
        return try .init(operationID: V2ForwardChunkIdentity.operationID(planID: operationID, chunkIndex: index),
            sources: Array(command.sources[offset..<min(offset + Self.sourcesPerChild, command.sources.count)]),
            targetRoomIDs: [command.targetRoomIDs[Int(index) % command.targetRoomIDs.count]])
    }
    private enum CodingKeys: String, CodingKey { case actorUserID, command, firstSubmissionDeadlineMilliseconds }
    public init(from decoder: any Decoder) throws {
        let v = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(actorUserID: v.decode(UserID.self, forKey: .actorUserID), command: v.decode(V2ForwardMessagesCommand.self, forKey: .command), firstSubmissionDeadlineMilliseconds: v.decode(UInt64.self, forKey: .firstSubmissionDeadlineMilliseconds))
    }
}

public enum V2ForwardPlanItemRejection: String, Codable, Equatable, Sendable {
    case sourceUnavailable, sourceRevisionConflict, permissionDenied, targetUnavailable
    case resourceUnavailable, contentRejected, capacityExceeded, closedBeforeExecution, identityConflict
}
public enum V2ForwardPlanItemOutcome: Codable, Equatable, Sendable {
    case accepted(V2MessageOperationAcceptance), rejected(V2ForwardPlanItemRejection)
}
public struct V2ForwardPlanItemResult: Codable, Equatable, Sendable {
    public let sourceMessageID: MessageID
    public let targetRoomID: RoomID
    public let outcome: V2ForwardPlanItemOutcome
    public init(sourceMessageID: MessageID, targetRoomID: RoomID, outcome: V2ForwardPlanItemOutcome) throws {
        self.sourceMessageID = sourceMessageID
        self.targetRoomID = targetRoomID
        self.outcome = outcome
    }
    private enum CodingKeys: String, CodingKey { case sourceMessageID, targetRoomID, outcome }
    public init(from decoder: any Decoder) throws {
        let v = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(sourceMessageID: v.decode(MessageID.self, forKey: .sourceMessageID), targetRoomID: v.decode(RoomID.self, forKey: .targetRoomID), outcome: v.decode(V2ForwardPlanItemOutcome.self, forKey: .outcome))
    }
}

public enum V2ForwardPlanChildOutcome: Codable, Equatable, Sendable {
    case completed([V2ForwardPlanItemResult]), cancelledBeforeStart
}
public struct V2ForwardPlanChildReceipt: Codable, Equatable, Sendable {
    public let parentIdentity: V2OperationIdentity
    public let parentFingerprint: V2OperationFingerprint
    public let index: UInt64
    public let operationID: MessageForwardOperationID
    public let outcome: V2ForwardPlanChildOutcome
    public let resolvedAtMilliseconds: UInt64
    public init(parentIdentity: V2OperationIdentity, parentFingerprint: V2OperationFingerprint, index: UInt64, operationID: MessageForwardOperationID, outcome: V2ForwardPlanChildOutcome, resolvedAtMilliseconds: UInt64) throws {
        guard parentIdentity.kind == .forwardMessage, case .account = parentIdentity.scope,
              case .forwardMessage(let planID) = parentIdentity.operation, index < 50,
              operationID == (try V2ForwardChunkIdentity.operationID(planID: planID, chunkIndex: index)),
              resolvedAtMilliseconds > 0, resolvedAtMilliseconds <= UInt64(Int64.max) else { throw V2ForwardPlanValidationError.invalidReceipt }
        if case .completed(let items) = outcome {
            guard !items.isEmpty, items.count <= 20,
                  Set(items.map(\.sourceMessageID)).count == items.count,
                  Set(items.map(\.targetRoomID)).count == 1 else { throw V2ForwardPlanValidationError.invalidReceipt }
        }
        self.parentIdentity = parentIdentity
        self.parentFingerprint = parentFingerprint
        self.index = index
        self.operationID = operationID
        self.outcome = outcome
        self.resolvedAtMilliseconds = resolvedAtMilliseconds
    }
    public func validates(command: V2ForwardPlanOperationCommand) -> Bool {
        guard parentIdentity == (try? command.identity), parentFingerprint == (try? command.fingerprint),
              let child = try? command.childCommand(index: index), operationID == child.operationID else { return false }
        if case .completed(let items) = outcome {
            return items.count == child.sources.count && zip(items, child.sources).allSatisfy {
                $0.0.sourceMessageID == $0.1.messageID && $0.0.targetRoomID == child.targetRoomIDs[0]
            }
        }
        return true
    }
    private enum CodingKeys: String, CodingKey { case parentIdentity, parentFingerprint, index, operationID, outcome, resolvedAtMilliseconds }
    public init(from decoder: any Decoder) throws {
        let v = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(parentIdentity: v.decode(V2OperationIdentity.self, forKey: .parentIdentity), parentFingerprint: v.decode(V2OperationFingerprint.self, forKey: .parentFingerprint), index: v.decode(UInt64.self, forKey: .index), operationID: v.decode(MessageForwardOperationID.self, forKey: .operationID), outcome: v.decode(V2ForwardPlanChildOutcome.self, forKey: .outcome), resolvedAtMilliseconds: v.decode(UInt64.self, forKey: .resolvedAtMilliseconds))
    }
}

public enum V2ForwardPlanChildState: Codable, Equatable, Sendable {
    case pending
    /// The durable owner handoff has been admitted; cancellation cannot claim it never started.
    case processing
    case resolved(V2ForwardPlanChildReceipt)
}
public struct V2ForwardPlanChildProgress: Codable, Equatable, Sendable {
    public let index: UInt64
    public let operationID: MessageForwardOperationID
    public let state: V2ForwardPlanChildState
    public init(index: UInt64, operationID: MessageForwardOperationID, state: V2ForwardPlanChildState) throws {
        guard index < 50 else { throw V2ForwardPlanValidationError.invalidProgress }
        if case .resolved(let receipt) = state {
            guard receipt.index == index, receipt.operationID == operationID else { throw V2ForwardPlanValidationError.invalidProgress }
        }
        self.index = index
        self.operationID = operationID
        self.state = state
    }
    private enum CodingKeys: String, CodingKey { case index, operationID, state }
    public init(from decoder: any Decoder) throws {
        let v = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(index: v.decode(UInt64.self, forKey: .index), operationID: v.decode(MessageForwardOperationID.self, forKey: .operationID), state: v.decode(V2ForwardPlanChildState.self, forKey: .state))
    }
}

public enum V2ForwardPlanExecutionState: String, Codable, Equatable, Sendable { case waitingToStart, processing, cancelling, completed }

public struct V2ForwardPlanProgress: Codable, Equatable, Sendable {
    public let identity: V2OperationIdentity
    public let fingerprint: V2OperationFingerprint
    public let executionState: V2ForwardPlanExecutionState
    public let children: [V2ForwardPlanChildProgress]
    public init(identity: V2OperationIdentity, fingerprint: V2OperationFingerprint, executionState: V2ForwardPlanExecutionState, children: [V2ForwardPlanChildProgress]) throws {
        guard identity.kind == .forwardMessage, case .account = identity.scope,
              !children.isEmpty, children.count <= 50,
              children.enumerated().allSatisfy({ $0.element.index == UInt64($0.offset) }) else { throw V2ForwardPlanValidationError.invalidProgress }
        if executionState == .completed {
            guard children.allSatisfy({ if case .resolved = $0.state { true } else { false } }) else { throw V2ForwardPlanValidationError.invalidProgress }
        }
        if executionState == .waitingToStart {
            guard children.allSatisfy({ $0.state == .pending }) else { throw V2ForwardPlanValidationError.invalidProgress }
        }
        self.identity = identity
        self.fingerprint = fingerprint
        self.executionState = executionState
        self.children = children
    }
    public func validates(command: V2ForwardPlanOperationCommand) -> Bool {
        guard identity == (try? command.identity), fingerprint == (try? command.fingerprint),
              children.count == Int(command.childCount) else { return false }
        guard children.allSatisfy({ child in
            guard let frozen = try? command.childCommand(index: child.index), frozen.operationID == child.operationID else { return false }
            if case .resolved(let receipt) = child.state { return receipt.validates(command: command) }
            return true
        }) else { return false }
        var messages = Set<MessageID>(), sequences = Set<String>()
        for child in children {
            if case .resolved(let receipt) = child.state, case .completed(let items) = receipt.outcome {
                for item in items {
                    if case .accepted(let proof) = item.outcome {
                        guard messages.insert(proof.messageID).inserted,
                              sequences.insert(item.targetRoomID.rawValue + "/" + String(proof.roomSequence)).inserted else { return false }
                    }
                }
            }
        }
        return true
    }
    /// A newer query cannot erase or replace an already verified original child result.
    public func canAdvance(from old: Self, command: V2ForwardPlanOperationCommand) -> Bool {
        guard validates(command: command), old.validates(command: command) else { return false }
        if old.executionState == .completed && executionState != .completed { return false }
        if old.executionState == .cancelling && ![.cancelling, .completed].contains(executionState) { return false }
        if old.executionState == .processing && executionState == .waitingToStart { return false }
        return zip(old.children, children).allSatisfy { before, after in
            switch before.state {
            case .resolved: return before.state == after.state
            case .processing:
                if after.state == .pending { return false }
                if case .resolved(let receipt) = after.state, case .cancelledBeforeStart = receipt.outcome { return false }
                return true
            case .pending: return true
            }
        }
    }
    private enum CodingKeys: String, CodingKey { case identity, fingerprint, executionState, children }
    public init(from decoder: any Decoder) throws {
        let v = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(identity: v.decode(V2OperationIdentity.self, forKey: .identity), fingerprint: v.decode(V2OperationFingerprint.self, forKey: .fingerprint), executionState: v.decode(V2ForwardPlanExecutionState.self, forKey: .executionState), children: v.decode([V2ForwardPlanChildProgress].self, forKey: .children))
    }
}

public struct V2ForwardPlanCompletionSummary: Codable, Equatable, Sendable {
    public let childCount: UInt64
    public let succeededItemCount: UInt64
    public let rejectedItemCount: UInt64
    public let cancelledItemCount: UInt64
    public let resultDigest: Data
    public init(childCount: UInt64, succeededItemCount: UInt64, rejectedItemCount: UInt64, cancelledItemCount: UInt64, resultDigest: Data) throws {
        guard childCount > 0, childCount <= 50, succeededItemCount <= 1000,
              rejectedItemCount <= 1000, cancelledItemCount <= 1000,
              succeededItemCount + rejectedItemCount + cancelledItemCount > 0,
              succeededItemCount + rejectedItemCount + cancelledItemCount <= 1000,
              resultDigest.count == 32 else { throw V2ForwardPlanValidationError.invalidReceipt }
        self.childCount = childCount
        self.succeededItemCount = succeededItemCount
        self.rejectedItemCount = rejectedItemCount
        self.cancelledItemCount = cancelledItemCount
        self.resultDigest = resultDigest
    }
    public static func derive(command: V2ForwardPlanOperationCommand, progress: V2ForwardPlanProgress) throws -> Self {
        guard progress.validates(command: command), progress.executionState == .completed else { throw V2ForwardPlanValidationError.invalidProgress }
        var succeeded: UInt64 = 0, rejected: UInt64 = 0, cancelled: UInt64 = 0
        var ordered: [String] = []
        for child in progress.children {
            guard case .resolved(let receipt) = child.state else { throw V2ForwardPlanValidationError.invalidProgress }
            ordered += [String(child.index), child.operationID.rawValue]
            switch receipt.outcome {
            case .cancelledBeforeStart:
                ordered.append("cancelledBeforeStart")
                cancelled += UInt64(try command.childCommand(index: child.index).sources.count)
            case .completed(let items):
                ordered.append("completed")
                ordered.append(String(items.count))
                for item in items {
                    ordered += [item.sourceMessageID.rawValue, item.targetRoomID.rawValue]
                    switch item.outcome {
                    case .accepted(let proof):
                        succeeded += 1
                        ordered += ["accepted", proof.messageID.rawValue, String(proof.roomSequence)]
                    case .rejected(let reason):
                        rejected += 1
                        ordered += ["rejected", reason.rawValue]
                    }
                }
            }
        }
        let digest = try V2OperationFingerprint(kind: .forwardMessage, fields: [
            .init("identity", .text(command.identity.storageKey)),
            .init("manifestFingerprint", .bytes(command.fingerprint.digest)),
            .init("orderedResults", .orderedText(ordered))]).digest
        return try .init(childCount: command.childCount, succeededItemCount: succeeded,
            rejectedItemCount: rejected, cancelledItemCount: cancelled, resultDigest: digest)
    }
    private enum CodingKeys: String, CodingKey { case childCount, succeededItemCount, rejectedItemCount, cancelledItemCount, resultDigest }
    public init(from decoder: any Decoder) throws {
        let v = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(childCount: v.decode(UInt64.self, forKey: .childCount), succeededItemCount: v.decode(UInt64.self, forKey: .succeededItemCount), rejectedItemCount: v.decode(UInt64.self, forKey: .rejectedItemCount), cancelledItemCount: v.decode(UInt64.self, forKey: .cancelledItemCount), resultDigest: v.decode(Data.self, forKey: .resultDigest))
    }
}

public enum V2ForwardPlanRejection: String, Codable, Equatable, Sendable { case expiredUnsubmitted }
public enum V2ForwardPlanTerminalOutcome: Codable, Equatable, Sendable {
    case completed(V2ForwardPlanCompletionSummary), rejected(V2ForwardPlanRejection), closedBeforeStart
}
public struct V2ForwardPlanReceipt: Codable, Equatable, Sendable {
    public let identity: V2OperationIdentity
    public let fingerprint: V2OperationFingerprint
    public let outcome: V2ForwardPlanTerminalOutcome
    public let resolvedAtMilliseconds: UInt64
    public init(identity: V2OperationIdentity, fingerprint: V2OperationFingerprint, outcome: V2ForwardPlanTerminalOutcome, resolvedAtMilliseconds: UInt64) throws {
        guard identity.kind == .forwardMessage, case .account = identity.scope,
              resolvedAtMilliseconds > 0, resolvedAtMilliseconds <= UInt64(Int64.max) else { throw V2ForwardPlanValidationError.invalidReceipt }
        self.identity = identity
        self.fingerprint = fingerprint
        self.outcome = outcome
        self.resolvedAtMilliseconds = resolvedAtMilliseconds
    }
    public func validates(command: V2ForwardPlanOperationCommand) -> Bool {
        identity == (try? command.identity) && fingerprint == (try? command.fingerprint)
    }
    private enum CodingKeys: String, CodingKey { case identity, fingerprint, outcome, resolvedAtMilliseconds }
    public init(from decoder: any Decoder) throws {
        let v = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(identity: v.decode(V2OperationIdentity.self, forKey: .identity), fingerprint: v.decode(V2OperationFingerprint.self, forKey: .fingerprint), outcome: v.decode(V2ForwardPlanTerminalOutcome.self, forKey: .outcome), resolvedAtMilliseconds: v.decode(UInt64.self, forKey: .resolvedAtMilliseconds))
    }
}

public struct V2ForwardPlanResolvedResult: Codable, Equatable, Sendable {
    public let receipt: V2ForwardPlanReceipt
    public let progress: V2ForwardPlanProgress
    public init(receipt: V2ForwardPlanReceipt, progress: V2ForwardPlanProgress) throws {
        guard receipt.identity == progress.identity, receipt.fingerprint == progress.fingerprint,
              progress.executionState == .completed else { throw V2ForwardPlanValidationError.invalidReceipt }
        self.receipt = receipt
        self.progress = progress
    }
    public func validates(command: V2ForwardPlanOperationCommand) -> Bool {
        guard receipt.validates(command: command), progress.validates(command: command),
              progress.executionState == .completed else { return false }
        switch receipt.outcome {
        case .completed(let summary): return summary == (try? V2ForwardPlanCompletionSummary.derive(command: command, progress: progress))
        case .closedBeforeStart, .rejected:
            return progress.children.allSatisfy { if case .resolved(let result) = $0.state,
                case .cancelledBeforeStart = result.outcome { true } else { false } }
        }
    }
    private enum CodingKeys: String, CodingKey { case receipt, progress }
    public init(from decoder: any Decoder) throws {
        let v = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(receipt: v.decode(V2ForwardPlanReceipt.self, forKey: .receipt), progress: v.decode(V2ForwardPlanProgress.self, forKey: .progress))
    }
}

public enum V2ForwardPlanRecoveryAction: String, Codable, Equatable, Sendable { case query, closeIfUnstarted, cancelRemaining }

/// Recovery carries the original frozen manifest: a digest alone cannot enumerate
/// children when closing a parent that never reached the server. HTTP caps this at 64 KiB.
public struct V2ForwardPlanRecoveryRequest: Codable, Equatable, Sendable {
    public let command: V2ForwardPlanOperationCommand
    public let action: V2ForwardPlanRecoveryAction
    public var identity: V2OperationIdentity { get throws { try command.identity } }
    public var fingerprint: V2OperationFingerprint { get throws { try command.fingerprint } }
    public init(command: V2ForwardPlanOperationCommand, action: V2ForwardPlanRecoveryAction) throws {
        _ = try command.identity
        self.command = command; self.action = action
    }
    private enum CodingKeys: String, CodingKey { case command, action }
    public init(from decoder: any Decoder) throws {
        let v = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(command: v.decode(V2ForwardPlanOperationCommand.self, forKey: .command),
                      action: v.decode(V2ForwardPlanRecoveryAction.self, forKey: .action))
    }
}

/// Only bound original receipts are terminal evidence; progress carries independently validated child proofs.
public enum V2ForwardPlanRecoveryResult: Codable, Equatable, Sendable {
    case receipt(V2ForwardPlanResolvedResult), processing(V2ForwardPlanProgress)
    case deferred(V2MessageOperationRetryHint), unresolved, fingerprintConflict
}
