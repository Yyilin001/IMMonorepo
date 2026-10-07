import Foundation
import IMV2ActorContracts

public enum V2ActorRealtimeQueue: String, CaseIterable, Sendable { case body, recovery, activity }
public enum V2ActorRealtimeOperation: String, CaseIterable, Sendable {
    case register, renew, routes
    case partitionClaim = "partition_claim"
    case partitionRenew = "partition_renew"
    case partitionRelease = "partition_release"
    case partitionConfirm = "partition_confirm"
}
public enum V2ActorRealtimeResult: String, CaseIterable, Sendable { case succeeded, failed }
public enum V2ActorRealtimeRPCResult: String, CaseIterable, Sendable { case accepted, acceptedAsWatermark, rejected, failed, overloaded }
public struct V2ActorRealtimeQueueUsage: Sendable {
    public var items: Int = 0
    public var bytes: Int = 0
    public init() {}
}
/// Fixed topic categories only; no room, user or physical-owner identifiers.
public enum V2ActorRealtimeRouteQueryKind: String, CaseIterable, Sendable {
    case roomEvents = "room_events"
    case userSync = "user_sync"
    case userPresence = "user_presence"
    case roomTyping = "room_typing"
}

/// One admitted route-store call remains active until that actual call returns.
/// Duration includes acquisition and decoding, not just database execution.
public struct V2ActorRealtimeRouteQuerySnapshot: Sendable {
    public var active: Int = 0
    public var started: UInt64 = 0
    public var succeeded: UInt64 = 0
    public var failed: UInt64 = 0
    public var capacityRejected: UInt64 = 0
    /// Successful queries whose actual returned route array was empty.
    public var empty: UInt64 = 0
    public var totalMilliseconds: Double = 0
    public var maxMilliseconds: Double = 0
    public init() {}
}

public enum V2ActorRealtimeSessionRotationReason: String, CaseIterable, Sendable {
    case tokenChange = "token_change", failure, expiry
}
public enum V2ActorRealtimeActivationResult: String, CaseIterable, Sendable {
    case ready, stale, cancelled, failed, closed
}

public enum V2ActorRealtimeHeadReadResult: String, CaseIterable, Sendable {
    case success, wrongOwner = "wrong_owner", dependency, invalid
}
/// One actual read-heads invocation per kind, including router validation and
/// physical SQL acquisition/decoding. Topic counts are inputs, not SQL rows.
/// Mixed calls use dependency > wrongOwner > invalid > success precedence;
/// topicResults retains the exact per-topic classification without losing
/// healthy siblings. Neither count denotes the number of SQL statements.
public struct V2ActorRealtimeHeadReadSnapshot: Sendable {
    public var results: [V2ActorRealtimeHeadReadResult: UInt64] = [:]
    public var topicResults: [V2ActorRealtimeHeadReadResult: UInt64] = [:]
    public var topics: UInt64 = 0
    public var totalMilliseconds: Double = 0
    public var maxMilliseconds: Double = 0
    public init() {}
}

/// One validated publication's filtered Gateway-session set, not client/device
/// count. Physical callback count differs when lane jobs coalesce publications.
public struct V2ActorRealtimeRecipientSetSnapshot: Sendable {
    public var sets: UInt64 = 0
    public var members: UInt64 = 0
    public var emptySets: UInt64 = 0
    public var membersMaxLifetime: Int = 0
    public init() {}
}
/// Actual local callback invocation, including failed returns. RemoteCall
/// timeout is local settlement, not proof of remote task or client settlement.
public struct V2ActorRealtimeDeliveryTargetSnapshot: Sendable {
    public var active: Int = 0
    public var oldestActiveMilliseconds: Double = 0
    public var completed: UInt64 = 0
    public var totalMilliseconds: Double = 0
    public var maxMillisecondsLifetime: Double = 0
    public init() {}
}
public struct V2ActorRealtimeSkewSnapshot: Sendable {
    /// Sum of existing actual delivery-owner capacities; not additional budget.
    public var deliveryObservationOwners: Int = 0
    public var deliveryObservationCapacity: Int = 0
    /// Nonzero invalidates complete active/oldest accounting claims; never a
    /// business rejection, production trap or silently dropped zero sample.
    public var skewObservationOwnershipViolations: UInt64 = 0
    /// Installed index payload retained locally, excluding staging/tombstones.
    /// Expiry removes it on the existing reclaim path, not a new metrics sweep.
    /// Thus these gauges describe retained load, not current Ready authority.
    public var partitionRetainedBindingsMax: Int = 0
    public var partitionRetainedTopicsMax: Int = 0
    public var partitionRetainedBindingsPeakLifetime: Int = 0
    public var partitionRetainedTopicsPeakLifetime: Int = 0
    /// Includes actual calls still settling on a retired partition epoch.
    public var partitionPublicationsActiveMax: Int = 0
    public var partitionPublicationsActivePeakLifetime: Int = 0
    public var recipientSets = Dictionary(uniqueKeysWithValues: V2ActorRealtimeRouteQueryKind.allCases.map {
        ($0, V2ActorRealtimeRecipientSetSnapshot())
    })
    public var deliveryTargets = Dictionary(uniqueKeysWithValues: V2ActorRealtimeRouteQueryKind.allCases.map {
        ($0, V2ActorRealtimeDeliveryTargetSnapshot())
    })
    public init() {}
}

public struct V2ActorRealtimeMetricsSnapshot: Sendable {
    public var skew = V2ActorRealtimeSkewSnapshot()
    public var shardCapacityRejections: [V2ActorRealtimeShardCapacityRejection: UInt64] = [:]
    public var transport: V2RealtimeShardTransportMetricsSnapshot?
    public var subscriptionControlActive = 0
    public var subscriptionControlQueued = 0
    /// Actual recovery cohorts, held through head reads, retained hints and
    /// Ready callbacks until the complete owned task settles.
    public var recoveryActive = 0
    /// Partitions awaiting a recovery slot; not the number of pending topics.
    public var recoveryQueued = 0
    public var activationWaiters = 0
    public var desiredPartitions = 0
    public var installedPartitions = 0
    /// Local permission to serve; independent from PostgreSQL ownership.
    public var serviceQualified = 0
    public var serviceQualificationRemainingSeconds: Double = 0
    public var partitionControlFailedTicks: UInt64 = 0
    public var routeQueries = Dictionary(uniqueKeysWithValues: V2ActorRealtimeRouteQueryKind.allCases.map {
        ($0, V2ActorRealtimeRouteQuerySnapshot())
    })
    public var sessionRotations: [V2ActorRealtimeSessionRotationReason: UInt64] = [:]
    public var activationSettlements: [V2ActorRealtimeActivationResult: UInt64] = [:]
    public var headReads: [V2ActorRealtimeRouteQueryKind: V2ActorRealtimeHeadReadSnapshot] = [:]
    public var registrations: Int = 0
    public var interests: Int = 0
    public var queues: [V2ActorRealtimeQueue: V2ActorRealtimeQueueUsage] = [:]
    public var operations: [V2ActorRealtimeOperation: [V2ActorRealtimeResult: UInt64]] = [:]
    public var operationSeconds: [V2ActorRealtimeOperation: Double] = [:]
    public var rpc: [V2ActorRealtimeRPCResult: UInt64] = [:]
    public var coverageLosses: UInt64 = 0
    public var degradedBodies: UInt64 = 0
    public var admissionRejected: UInt64 = 0
    public init() {}
}
public protocol V2ActorRealtimeMetricsSource: Sendable {
    func actorRealtimeMetricsSnapshot() async -> V2ActorRealtimeMetricsSnapshot
}

/// Counts actual local shard gates, distinct from caller-side Sender admission.
public enum V2ActorRealtimeShardCapacityRejection: String, CaseIterable, Sendable {
    case controlGlobal = "control_global"
    case durablePublications = "durable_publications"
    case transientPublications = "transient_publications"
    case deliveryGlobal = "delivery_global"
    case deliveryActivity = "delivery_activity"
    case deliveryPeer = "delivery_peer"
    case deliveryLane = "delivery_lane"
    case receiverQueue = "receiver_queue"
}
