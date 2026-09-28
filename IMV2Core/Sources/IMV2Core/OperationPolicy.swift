import Foundation

public enum V2ReadRetention: String, Codable, Sendable {
    case persistentProjection, businessSnapshot, presentationLease, onlineOnly
}
public enum V2ReadConsistency: Equatable, Codable, Sendable {
    case cached, refresh, authority(minimumRevision: UInt64?)
}
public enum V2ReplayCapability: String, Codable, Sendable {
    case forbidden, sameIdentity, monotonicTarget
}
public enum V2OperationMergeRule: String, Codable, Sendable {
    case never, unfrozenTarget, maximumWatermark
}
public struct V2CommandPolicy: Equatable, Sendable {
    public let kind: V2OperationKind
    public let firstSubmissionWindowMilliseconds: UInt64?
    public let replay: V2ReplayCapability
    public let mergeRule: V2OperationMergeRule
    /// Per recovery round; lifetime attempts remain cumulative. Only an explicit user restart opens a new round.
    public let maximumAutomaticAttempts: UInt32
    public let maximumPayloadBytes: UInt64

    public static func registered(for kind: V2OperationKind) -> Self {
        let window: UInt64?
        let merge: V2OperationMergeRule
        switch kind {
        case .readReceipt: window = nil; merge = .maximumWatermark
        case .conversationPreference, .messageFavorite: window = 7 * 86_400_000; merge = .unfrozenTarget
        case .sendMessage, .forwardMessage, .profileUpdate, .contactAlias, .groupNickname, .mediaUpload:
            window = 86_400_000; merge = .never
        case .reaction: window = 86_400_000; merge = .unfrozenTarget
        case .editMessage, .withdrawMessage, .directRoom, .groupRoom, .relationship, .groupJoinRequest:
            window = 600_000; merge = .never
        case .membership, .moderation, .memberMute, .moderatedMemberRemoval, .userBlock, .strangerMessagePreference, .userAddPreference,
             .readReceiptPreference, .liveActivityPreference, .pinnedMessage, .groupAnnouncement,
             .groupPermission, .groupRole, .groupInvite, .groupJoinDecision, .groupAvatar:
            window = 120_000; merge = .never
        }
        return Self(kind: kind, firstSubmissionWindowMilliseconds: window,
                    replay: kind == .readReceipt ? .monotonicTarget : .sameIdentity,
                    mergeRule: merge, maximumAutomaticAttempts: 5, maximumPayloadBytes: kind == .groupRoom ? 8_388_608 : 1_048_576)
    }

    /// A deadline gates first submission only. An attempted identity always needs recovery.
    public func actionAtDeadline(submission: V2OperationSubmissionEvidence) -> V2OperationDeadlineAction {
        switch submission {
        case .neverSubmitted: .expireUnsubmitted
        case .submissionStarted: .recoverOriginalIdentity
        }
    }
}
public enum V2OperationSubmissionEvidence: String, Codable, Sendable { case neverSubmitted, submissionStarted }
public enum V2OperationDeadlineAction: String, Codable, Sendable { case expireUnsubmitted, recoverOriginalIdentity }

public struct V2QueryPolicy: Equatable, Sendable {
    public let retention: V2ReadRetention
    public let consistency: V2ReadConsistency
    public let maximumResponseBytes: UInt64
    public init(retention: V2ReadRetention, consistency: V2ReadConsistency, maximumResponseBytes: UInt64) throws {
        guard maximumResponseBytes > 0 else { throw V2CoreError.invalidPositiveValue }
        self.retention = retention; self.consistency = consistency; self.maximumResponseBytes = maximumResponseBytes
    }
}
public enum V2TransferMode: String, Codable, Sendable { case foreground, backgroundAuthorized }
public struct V2TransferPolicy: Equatable, Sendable {
    public let mode: V2TransferMode
    public let maximumBytes: UInt64
    public let maximumConcurrentParts: UInt32
    public init(mode: V2TransferMode, maximumBytes: UInt64, maximumConcurrentParts: UInt32) throws {
        guard maximumBytes > 0, maximumConcurrentParts > 0 else { throw V2CoreError.invalidPositiveValue }
        self.mode = mode; self.maximumBytes = maximumBytes; self.maximumConcurrentParts = maximumConcurrentParts
    }
}

/// Authentication has a separate replay boundary; a one-time proof never becomes a command retry.
public enum V2AuthenticationPolicy: Equatable, Sendable {
    case oneTimeProof
    case credentialOperation
    public var replay: V2ReplayCapability {
        switch self {
        case .oneTimeProof: .forbidden
        case .credentialOperation: .sameIdentity
        }
    }
}
