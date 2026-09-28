import Foundation
import IMV2Core

public enum V2OperationWorkError: Error, Equatable, Sendable {
    case invalidRecord, accountMismatch, identityConflict, capacityExceeded
    case dependencyUnavailable, staleClaim, invalidTransition
}

/// Admission limits apply to active semantic payloads, not rebuildable UI caches.
public struct V2OperationWorkLimits: Sendable {
    public let maximumActiveCount: Int
    public let maximumPayloadBytes: Int64
    public let maximumDependencies: Int
    public init(maximumActiveCount: Int = 2_000, maximumPayloadBytes: Int64 = 32 * 1_024 * 1_024,
                maximumDependencies: Int = 32) {
        precondition(maximumActiveCount > 0 && maximumPayloadBytes > 0 && (0...32).contains(maximumDependencies))
        self.maximumActiveCount = maximumActiveCount
        self.maximumPayloadBytes = maximumPayloadBytes
        self.maximumDependencies = maximumDependencies
    }
}

/// Immutable submission metadata. Domain payloads are inserted in the same SQLite transaction.
struct V2NewOperationWork: Sendable {
    let id: UUID
    let intentID: UUID
    let identity: V2OperationIdentity
    let fingerprint: V2OperationFingerprint
    let orderingKey: String
    let payloadBytes: Int64
    let admissionDeadline: Date?
    let dependencyIDs: [UUID]

    init(id: UUID = UUID(), intentID: UUID, identity: V2OperationIdentity,
         fingerprint: V2OperationFingerprint, orderingKey: String, payloadBytes: Int64,
         admissionDeadline: Date?, dependencyIDs: [UUID] = []) throws {
        guard !orderingKey.isEmpty, orderingKey.utf8.count <= 512,
              !orderingKey.unicodeScalars.contains(where: { $0.value < 32 }), payloadBytes >= 0,
              dependencyIDs.count <= 32, Set(dependencyIDs).count == dependencyIDs.count,
              !dependencyIDs.contains(id), admissionDeadline.map({ $0.timeIntervalSince1970.isFinite }) ?? true
        else { throw V2OperationWorkError.invalidRecord }
        self.id = id; self.intentID = intentID; self.identity = identity; self.fingerprint = fingerprint
        self.orderingKey = orderingKey; self.payloadBytes = payloadBytes
        self.admissionDeadline = admissionDeadline; self.dependencyIDs = dependencyIDs
    }
}

/// A read snapshot never grants permission to send; obtain a durable claim first.
public struct V2OperationWork: Equatable, Sendable {
    public let id: UUID
    public let intentID: UUID
    public let identity: V2OperationIdentity
    public let fingerprint: V2OperationFingerprint
    public let orderingKey: String
    public let localSequence: Int64
    public let execution: V2OperationExecutionState
    public let scheduling: V2OperationSchedulingState
    public let submissionStarted: Bool
    public let attemptCount: Int
    public let submissionRoundAttempts: Int
    public let reconciliationRoundAttempts: Int
    public let submissionRoundDeadline: Date?
    public let reconciliationRoundDeadline: Date?
    public let nextAction: V2OperationWorkAction
    public let nextActionAt: Date
    public let admissionDeadline: Date?
    public let lastErrorCode: String?
    public let revision: Int64
}

public enum V2OperationWorkAction: String, Equatable, Sendable { case submit, reconcile }

/// Constructed only by the store after its write-ahead transaction commits.
public struct V2OperationWorkClaim: Sendable {
    public let work: V2OperationWork
    public let action: V2OperationWorkAction
    public let ownerID: UUID
    let claimID: UUID
}

public enum V2OperationWorkClaimResult: Sendable {
    case claimed(V2OperationWorkClaim)
    case unavailable
    case expiredUnsubmitted
    case needsAttention
}

/// Only a domain adapter that has checked the remote identity, fingerprint and
/// receipt semantics may construct this value. It is not a wire-decoding type.
struct V2VerifiedOperationOutcome: Sendable {
    let identity: V2OperationIdentity
    let fingerprint: V2OperationFingerprint
    let state: V2OperationExecutionState
    let canonicalReceipt: Data

    init<Receipt: Encodable & Sendable>(identity: V2OperationIdentity, fingerprint: V2OperationFingerprint,
                                      state: V2OperationExecutionState, receipt: Receipt) throws {
        guard [.committed, .rejected, .conflicted, .closed].contains(state) else {
            throw V2OperationWorkError.invalidTransition
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(receipt)
        guard !bytes.isEmpty, bytes.count <= 65_536 else { throw V2OperationWorkError.invalidRecord }
        self.identity = identity; self.fingerprint = fingerprint; self.state = state; canonicalReceipt = bytes
    }
}
