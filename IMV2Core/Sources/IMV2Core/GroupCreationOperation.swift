import Foundation

public enum V2GroupCreationValidationError: Error, Equatable, Sendable { case invalidIntent, invalidPage, invalidProgress, invalidReceipt }

/// The audience excludes the owner. UUID spelling, ordering and digest schema are
/// shared by clients and both database owners; JSON encoding is never hashed.
public enum V2GroupCreationAudience {
    public static let maximumPageMembers = 512
    public static func canonical(_ members: [UserID], actorUserID: UserID) throws -> [UserID] {
        guard actorUserID.uuidValue != nil, members.count < V2GroupCapacityPolicy.largeMaximumMembers,
              members.allSatisfy({ $0.uuidValue != nil && $0 != actorUserID }),
              Set(members).count == members.count else { throw V2GroupCreationValidationError.invalidIntent }
        return members.sorted { $0.uuidValue!.uuidString < $1.uuidValue!.uuidString }
    }
    /// The supplied prefix must already be canonical, so a server cannot silently
    /// reorder an accepted page and report a cursor for different input.
    public static func digest(_ canonicalMembers: [UserID]) throws -> V2OperationFingerprint {
        guard canonicalMembers.count < V2GroupCapacityPolicy.largeMaximumMembers,
              canonicalMembers.allSatisfy({ $0.uuidValue != nil }),
              Set(canonicalMembers).count == canonicalMembers.count,
              canonicalMembers == canonicalMembers.sorted(by: { $0.uuidValue!.uuidString < $1.uuidValue!.uuidString }) else { throw V2GroupCreationValidationError.invalidPage }
        return try .init(kind: .groupRoom, fields: [.init("schema", .text("audience-prefix-v1")), .init("members", .orderedText(canonicalMembers.map { $0.uuidValue!.uuidString.lowercased() }))])
    }
    public static func prefixDigest(_ canonicalMembers: [UserID], acceptedMemberCount: Int) throws -> V2OperationFingerprint {
        guard (0...canonicalMembers.count).contains(acceptedMemberCount) else { throw V2GroupCreationValidationError.invalidProgress }
        _ = try digest(canonicalMembers)
        return try digest(Array(canonicalMembers.prefix(acceptedMemberCount)))
    }
}

public struct V2GroupCreationIntent: Codable, Equatable, Sendable {
    public static let maximumTitleUTF8Bytes = 120
    public let identity: V2OperationIdentity
    public let title: String
    public let capacityClass: V2GroupCapacityClass
    public let initialMemberCount: Int
    public let audienceDigest: V2OperationFingerprint
    public let firstSubmissionDeadlineMilliseconds: UInt64
    public init(identity: V2OperationIdentity, title: String, capacityClass: V2GroupCapacityClass, initialMemberCount: Int, audienceDigest: V2OperationFingerprint, firstSubmissionDeadlineMilliseconds: UInt64) throws {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard identity.kind == .groupRoom, identity.accountID.uuidValue != nil, UUID(uuidString: identity.operation.rawOperationID) != nil,
              !normalized.isEmpty, normalized.utf8.count <= Self.maximumTitleUTF8Bytes,
              !normalized.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              initialMemberCount >= 0, initialMemberCount < V2GroupCapacityPolicy.largeMaximumMembers,
              V2GroupCapacityPolicy().acceptsInitialMemberCount(initialMemberCount + 1, mode: capacityClass),
              firstSubmissionDeadlineMilliseconds > 0, firstSubmissionDeadlineMilliseconds <= UInt64(Int64.max) else { throw V2GroupCreationValidationError.invalidIntent }
        self.identity = identity; self.title = normalized; self.capacityClass = capacityClass; self.initialMemberCount = initialMemberCount
        self.audienceDigest = audienceDigest; self.firstSubmissionDeadlineMilliseconds = firstSubmissionDeadlineMilliseconds
    }
    public var fingerprint: V2OperationFingerprint { get throws {
        try .init(kind: .groupRoom, fields: [.init("identity", .text(identity.storageKey)), .init("title", .text(title)), .init("capacity", .text(capacityClass.rawValue)), .init("memberCount", .unsigned(UInt64(initialMemberCount))), .init("audience", .bytes(audienceDigest.digest)), .init("deadline", .unsigned(firstSubmissionDeadlineMilliseconds))])
    } }
    private enum CodingKeys: CodingKey { case identity, title, capacityClass, initialMemberCount, audienceDigest, firstSubmissionDeadlineMilliseconds }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(identity: c.decode(V2OperationIdentity.self, forKey: .identity), title: c.decode(String.self, forKey: .title), capacityClass: c.decode(V2GroupCapacityClass.self, forKey: .capacityClass), initialMemberCount: c.decode(Int.self, forKey: .initialMemberCount), audienceDigest: c.decode(V2OperationFingerprint.self, forKey: .audienceDigest), firstSubmissionDeadlineMilliseconds: c.decode(UInt64.self, forKey: .firstSubmissionDeadlineMilliseconds))
    }
}

public struct V2GroupCreationAppendRequest: Codable, Equatable, Sendable {
    public let intent: V2GroupCreationIntent
    public let offset: Int
    public let memberUserIDs: [UserID]
    public let pageFingerprint: V2OperationFingerprint
    public init(intent: V2GroupCreationIntent, offset: Int, memberUserIDs: [UserID]) throws {
        guard offset >= 0, !memberUserIDs.isEmpty, memberUserIDs.count <= V2GroupCreationAudience.maximumPageMembers,
              offset < intent.initialMemberCount, offset % V2GroupCreationAudience.maximumPageMembers == 0,
              memberUserIDs.count == min(V2GroupCreationAudience.maximumPageMembers, intent.initialMemberCount - offset),
              !memberUserIDs.contains(intent.identity.accountID) else { throw V2GroupCreationValidationError.invalidPage }
        _ = try V2GroupCreationAudience.digest(memberUserIDs)
        self.intent = intent; self.offset = offset; self.memberUserIDs = memberUserIDs
        self.pageFingerprint = try .init(kind: .groupRoom, fields: [.init("intent", .bytes(intent.fingerprint.digest)), .init("offset", .unsigned(UInt64(offset))), .init("members", .orderedText(memberUserIDs.map { $0.uuidValue!.uuidString.lowercased() }))])
    }
    private enum CodingKeys: CodingKey { case intent, offset, memberUserIDs, pageFingerprint }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(intent: c.decode(V2GroupCreationIntent.self, forKey: .intent), offset: c.decode(Int.self, forKey: .offset), memberUserIDs: c.decode([UserID].self, forKey: .memberUserIDs))
        guard pageFingerprint == (try c.decode(V2OperationFingerprint.self, forKey: .pageFingerprint)) else { throw V2GroupCreationValidationError.invalidPage }
    }
}

public enum V2GroupCreationPhase: String, Codable, Equatable, Sendable { case staging, finalizing }
public struct V2GroupCreationProgress: Codable, Equatable, Sendable {
    public let identity: V2OperationIdentity
    public let fingerprint: V2OperationFingerprint
    public let roomID: RoomID
    public let phase: V2GroupCreationPhase
    public let acceptedMemberCount: Int
    public let acceptedPrefixDigest: V2OperationFingerprint
    /// Successfully mirrored frozen members, including the owner; zero while staging.
    public let copiedMemberCount: Int
    public init(intent: V2GroupCreationIntent, roomID: RoomID, phase: V2GroupCreationPhase, acceptedMemberCount: Int, acceptedPrefixDigest: V2OperationFingerprint, copiedMemberCount: Int = 0) throws {
        guard roomID.uuidValue != nil, (0...intent.initialMemberCount).contains(acceptedMemberCount),
              acceptedMemberCount == intent.initialMemberCount || acceptedMemberCount % V2GroupCreationAudience.maximumPageMembers == 0,
              copiedMemberCount == intent.initialMemberCount + 1 || copiedMemberCount % V2GroupCreationAudience.maximumPageMembers == 0, phase != .finalizing || acceptedMemberCount == intent.initialMemberCount,
              (0...intent.initialMemberCount + 1).contains(copiedMemberCount), phase != .staging || copiedMemberCount == 0 else { throw V2GroupCreationValidationError.invalidProgress }
        self.identity = intent.identity; self.fingerprint = try intent.fingerprint; self.roomID = roomID; self.phase = phase
        self.acceptedMemberCount = acceptedMemberCount; self.acceptedPrefixDigest = acceptedPrefixDigest; self.copiedMemberCount = copiedMemberCount
    }
    public func validates(intent: V2GroupCreationIntent, canonicalMembers: [UserID]) -> Bool {
        identity == intent.identity && fingerprint == (try? intent.fingerprint) && roomID.uuidValue != nil && canonicalMembers.count == intent.initialMemberCount && intent.audienceDigest == (try? V2GroupCreationAudience.digest(canonicalMembers)) && acceptedPrefixDigest == (try? V2GroupCreationAudience.prefixDigest(canonicalMembers, acceptedMemberCount: acceptedMemberCount)) && (phase != .finalizing || acceptedMemberCount == intent.initialMemberCount) && (0...intent.initialMemberCount + 1).contains(copiedMemberCount) && (phase != .staging || copiedMemberCount == 0) && (acceptedMemberCount == intent.initialMemberCount || acceptedMemberCount % V2GroupCreationAudience.maximumPageMembers == 0) && (copiedMemberCount == intent.initialMemberCount + 1 || copiedMemberCount % V2GroupCreationAudience.maximumPageMembers == 0)
    }
}
public enum V2GroupCreationRejection: String, Codable, Equatable, Sendable { case submissionExpired, invalidAudience, creationDenied }
public enum V2GroupCreationTerminalOutcome: Codable, Equatable, Sendable {
    /// Returned only after the room owner proof and canonical routing are durable.
    case created(roomID: RoomID, title: String, capacityClass: V2GroupCapacityClass, memberCount: Int)
    case rejected(V2GroupCreationRejection)
    case closed
}
public struct V2GroupCreationReceipt: Codable, Equatable, Sendable {
    public let identity: V2OperationIdentity
    public let fingerprint: V2OperationFingerprint
    public let outcome: V2GroupCreationTerminalOutcome
    public let resolvedAtMilliseconds: UInt64
    public init(intent: V2GroupCreationIntent, outcome: V2GroupCreationTerminalOutcome, resolvedAtMilliseconds: UInt64) throws {
        guard resolvedAtMilliseconds > 0, resolvedAtMilliseconds <= UInt64(Int64.max) else { throw V2GroupCreationValidationError.invalidReceipt }
        if case .created(let room, let title, let capacity, let count) = outcome {
            guard room.uuidValue != nil, title == intent.title, capacity == intent.capacityClass, count == intent.initialMemberCount + 1 else { throw V2GroupCreationValidationError.invalidReceipt }
        }
        self.identity = intent.identity; self.fingerprint = try intent.fingerprint; self.outcome = outcome; self.resolvedAtMilliseconds = resolvedAtMilliseconds
    }
    public func validates(intent: V2GroupCreationIntent) -> Bool {
        guard identity == intent.identity, fingerprint == (try? intent.fingerprint), resolvedAtMilliseconds > 0, resolvedAtMilliseconds <= UInt64(Int64.max) else { return false }
        if case .created(let room, let title, let capacity, let count) = outcome { return room.uuidValue != nil && title == intent.title && capacity == intent.capacityClass && count == intent.initialMemberCount + 1 }
        return true
    }
}
public struct V2GroupCreationRecoveryRequest: Codable, Equatable, Sendable {
    public let intent: V2GroupCreationIntent
    public let action: V2OperationRecoveryRequest.Action
    public init(intent: V2GroupCreationIntent, action: V2OperationRecoveryRequest.Action) { self.intent = intent; self.action = action }
}
public enum V2GroupCreationOperationResult: Codable, Equatable, Sendable {
    case progress(V2GroupCreationProgress)
    case receipt(V2GroupCreationReceipt)
    case unresolved
    case fingerprintConflict
    case deferred(V2MessageOperationRetryHint)
}
