import Foundation
import Synchronization
import IMV2ServerContracts
import IMV2ActorContracts

/// Labels are closed enums. Room, user, peer, ActorID and SQL owner names never
/// enter this metrics state or the public Prometheus document.
public final class V2ActorRealtimeMetrics: V2ActorRealtimeMetricsSource, Sendable {
    private let state = Mutex(V2ActorRealtimeMetricsSnapshot())
    // Fixed 256 partition keys. Callback observations follow registered actual
    // delivery owners: each owner has at most its existing admitted worker
    // capacity, one sender invocation per worker. Shared metrics reuse adds
    // owners, not a second diagnostic admission gate or a process-wide trap.
    // UUIDs are private ownership guards, never exported metric labels.
    private struct SkewState {
        var snapshot = V2ActorRealtimeSkewSnapshot()
        var loads: [Int: (epoch: Int64, bindings: Int, topics: Int)] = [:]
        var publications: [Int: Int] = [:]
        struct DeliveryOwner {
            let capacity: Int
            var targets: [UUID: (kind: V2ActorRealtimeRouteQueryKind, started: ContinuousClock.Instant)] = [:]
        }
        var deliveryOwners: [UUID: DeliveryOwner] = [:]
    }
    private let skewState = Mutex(SkewState())
    public init() {}
    public func actorRealtimeMetricsSnapshot() async -> V2ActorRealtimeMetricsSnapshot {
        var value = state.withLock { $0 }
        let now = ContinuousClock.now
        value.skew = skewState.withLock { stored in
            var result = stored.snapshot
            result.partitionRetainedBindingsMax = stored.loads.values.map(\.bindings).max() ?? 0
            result.partitionRetainedTopicsMax = stored.loads.values.map(\.topics).max() ?? 0
            result.partitionPublicationsActiveMax = stored.publications.values.max() ?? 0
            result.deliveryObservationOwners = stored.deliveryOwners.count
            result.deliveryObservationCapacity = stored.deliveryOwners.values.reduce(0) { $0 + $1.capacity }
            for owner in stored.deliveryOwners.values {
                for (kind, started) in owner.targets.values {
                    result.deliveryTargets[kind, default: .init()].oldestActiveMilliseconds = max(
                        result.deliveryTargets[kind, default: .init()].oldestActiveMilliseconds,
                        Self.milliseconds(started.duration(to: now)))
                }
            }
            return result
        }
        return value
    }
    public func partitionInstalled(_ token: V2RealtimeShardToken) {
        skewState.withLock {
            guard (0..<256).contains(token.partitionID) else {
                $0.snapshot.skewObservationOwnershipViolations &+= 1; return
            }
            $0.loads[token.partitionID] = (token.epoch, 0, 0)
        }
    }
    public func partitionRetainedLoad(_ token: V2RealtimeShardToken, bindings: Int, topics: Int) {
        skewState.withLock {
            guard bindings >= 0, topics >= 0 else {
                $0.snapshot.skewObservationOwnershipViolations &+= 1; return
            }
            guard $0.loads[token.partitionID]?.epoch == token.epoch else { return }
            $0.loads[token.partitionID] = (token.epoch, bindings, topics)
            $0.snapshot.partitionRetainedBindingsPeakLifetime = max($0.snapshot.partitionRetainedBindingsPeakLifetime, bindings)
            $0.snapshot.partitionRetainedTopicsPeakLifetime = max($0.snapshot.partitionRetainedTopicsPeakLifetime, topics)
        }
    }
    public func partitionRetired(_ token: V2RealtimeShardToken) {
        skewState.withLock {
            if $0.loads[token.partitionID]?.epoch == token.epoch { $0.loads.removeValue(forKey: token.partitionID) }
        }
    }
    public func partitionPublicationStarted(_ partitionID: Int) {
        skewState.withLock {
            guard (0..<256).contains(partitionID) else {
                $0.snapshot.skewObservationOwnershipViolations &+= 1; return
            }
            $0.publications[partitionID, default: 0] += 1
            $0.snapshot.partitionPublicationsActivePeakLifetime = max(
                $0.snapshot.partitionPublicationsActivePeakLifetime, $0.publications[partitionID, default: 0])
        }
    }
    public func partitionPublicationSettled(_ partitionID: Int) {
        skewState.withLock {
            guard $0.publications[partitionID, default: 0] > 0 else {
                $0.snapshot.skewObservationOwnershipViolations &+= 1; return
            }
            $0.publications[partitionID, default: 0] -= 1
            if $0.publications[partitionID] == 0 { $0.publications.removeValue(forKey: partitionID) }
        }
    }
    public func publicationRecipients(kind: V2RealtimeTopicKind, count: Int) {
        skewState.withLock {
            guard count >= 0 else {
                $0.snapshot.skewObservationOwnershipViolations &+= 1; return
            }
            let key = Self.metricKind(kind)
            $0.snapshot.recipientSets[key, default: .init()].sets &+= 1
            $0.snapshot.recipientSets[key, default: .init()].members &+= UInt64(count)
            if count == 0 { $0.snapshot.recipientSets[key, default: .init()].emptySets &+= 1 }
            $0.snapshot.recipientSets[key, default: .init()].membersMaxLifetime = max(
                $0.snapshot.recipientSets[key, default: .init()].membersMaxLifetime, count)
        }
    }
    /// Called only by the actual delivery owner's lifecycle; not a public
    /// arbitrary-event recorder. Capacity is the owner's existing business gate.
    func registerDeliveryObservationOwner(capacity: Int) -> UUID {
        let id = UUID()
        skewState.withLock { $0.deliveryOwners[id] = .init(capacity: capacity) }
        return id
    }
    func retireDeliveryObservationOwner(_ owner: UUID) {
        skewState.withLock {
            // Actual shutdown drains workers first. A bad lifecycle call is
            // observable and retains ownership instead of dropping active data.
            guard let source = $0.deliveryOwners[owner] else { return }
            guard source.targets.isEmpty else {
                $0.snapshot.skewObservationOwnershipViolations &+= 1; return
            }
            $0.deliveryOwners.removeValue(forKey: owner)
        }
    }
    func deliveryTargetStarted(owner: UUID, kind: V2RealtimeTopicKind) -> UUID? {
        let id = UUID(), key = Self.metricKind(kind), now = ContinuousClock.now
        return skewState.withLock {
            guard var source = $0.deliveryOwners[owner] else {
                $0.snapshot.skewObservationOwnershipViolations &+= 1; return nil
            }
            // No diagnostics precondition/refusal: the actual run hook is
            // already bounded by this owner's worker gate. If that invariant
            // is ever broken, expose it and still preserve the real observation.
            if source.targets.count >= source.capacity { $0.snapshot.skewObservationOwnershipViolations &+= 1 }
            source.targets[id] = (key, now); $0.deliveryOwners[owner] = source
            $0.snapshot.deliveryTargets[key, default: .init()].active += 1
            return id
        }
    }
    func deliveryTargetSettled(owner: UUID, id: UUID) {
        let now = ContinuousClock.now
        skewState.withLock {
            guard let target = $0.deliveryOwners[owner]?.targets.removeValue(forKey: id) else { return }
            let duration = Self.milliseconds(target.started.duration(to: now))
            $0.snapshot.deliveryTargets[target.kind, default: .init()].active -= 1
            $0.snapshot.deliveryTargets[target.kind, default: .init()].completed &+= 1
            $0.snapshot.deliveryTargets[target.kind, default: .init()].totalMilliseconds += duration
            $0.snapshot.deliveryTargets[target.kind, default: .init()].maxMillisecondsLifetime = max(
                $0.snapshot.deliveryTargets[target.kind, default: .init()].maxMillisecondsLifetime, duration)
        }
    }
    private static func metricKind(_ kind: V2RealtimeTopicKind) -> V2ActorRealtimeRouteQueryKind {
        switch kind {
        case .roomEvents: .roomEvents
        case .userSync: .userSync
        case .userPresence: .userPresence
        case .roomTyping: .roomTyping
        }
    }
    private static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return max(0, Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15)
    }
    public func registrations(_ count: Int) { state.withLock { $0.registrations = count } }
    public func interests(delta: Int) { state.withLock { $0.interests += delta } }
    public func operation(_ operation: V2ActorRealtimeOperation, result: V2ActorRealtimeResult, elapsed: Duration) {
        let duration = elapsed.components
        let seconds = max(0, Double(duration.seconds) + Double(duration.attoseconds) / 1e18)
        state.withLock {
            $0.operations[operation, default: [:]][result, default: 0] += 1
            $0.operationSeconds[operation, default: 0] += seconds
        }
    }
    public func shardCapacityRejected(_ reason: V2ActorRealtimeShardCapacityRejection) { state.withLock { $0.shardCapacityRejections[reason, default: 0] &+= 1 } }
    public func rpc(_ result: V2ActorRealtimeRPCResult) { state.withLock { $0.rpc[result, default: 0] += 1 } }
    public func queue(_ queue: V2ActorRealtimeQueue, items: Int, bytes: Int) {
        state.withLock {
            $0.queues[queue, default: .init()].items += items
            $0.queues[queue, default: .init()].bytes += bytes
        }
    }
    public func sessionRotation(_ reason: V2ActorRealtimeSessionRotationReason) {
        state.withLock { $0.sessionRotations[reason, default: 0] += 1 }
    }
    /// Records one actual retained activation waiter completion, not a caller
    /// retry or an activation that was already ready on admission.
    public func activationSettled(_ result: V2ActorRealtimeActivationResult) {
        state.withLock { $0.activationSettlements[result, default: 0] += 1 }
    }
    public func headRead(kind: V2ActorRealtimeRouteQueryKind, result: V2ActorRealtimeHeadReadResult,
                         topics: Int, outcomes: [V2RealtimeRecoveryHeadOutcome], elapsed: Duration) {
        let duration = elapsed.components
        let milliseconds = max(0, Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15)
        state.withLock {
            var item = $0.headReads[kind, default: .init()]
            item.results[result, default: 0] += 1
            item.topics += UInt64(max(0, topics))
            for outcome in outcomes {
                let result: V2ActorRealtimeHeadReadResult
                switch outcome {
                case .available: result = .success
                case .unavailable(.wrongOwner): result = .wrongOwner
                case .unavailable(.dependency): result = .dependency
                case .unavailable(.invalid): result = .invalid
                }
                item.topicResults[result, default: 0] += 1
            }
            item.totalMilliseconds += milliseconds
            item.maxMilliseconds = max(item.maxMilliseconds, milliseconds)
            $0.headReads[kind] = item
        }
    }
    public func coverageLost() { state.withLock { $0.coverageLosses += 1 } }
    public func bodyDegraded() { state.withLock { $0.degradedBodies += 1 } }
    public func admissionRejected() { state.withLock { $0.admissionRejected += 1 } }
}

public func v2RenderPrometheusActorRealtimeMetrics(_ snapshot: V2ActorRealtimeMetricsSnapshot) -> String {
    var lines: [String] = []
    func scalar(_ name: String, _ value: some CustomStringConvertible, type: String) {
        lines.append("# TYPE \(name) \(type)"); lines.append("\(name) \(value)")
    }
    scalar("im_v2_actor_realtime_delivery_observation_owners", snapshot.skew.deliveryObservationOwners, type: "gauge")
    scalar("im_v2_actor_realtime_delivery_observation_capacity", snapshot.skew.deliveryObservationCapacity, type: "gauge")
    lines.append("# HELP im_v2_actor_realtime_skew_observation_ownership_violations_total Observation lifecycle mismatch; nonzero prevents complete active/oldest accounting claims, not business rejection.")
    scalar("im_v2_actor_realtime_skew_observation_ownership_violations_total", snapshot.skew.skewObservationOwnershipViolations, type: "counter")
    lines.append("# HELP im_v2_actor_realtime_partition_retained_bindings_max Maximum local retained installed bindings; not live Ready authority. Expiry follows existing reclaim.")
    scalar("im_v2_actor_realtime_partition_retained_bindings_max", snapshot.skew.partitionRetainedBindingsMax, type: "gauge")
    scalar("im_v2_actor_realtime_partition_retained_topics_max", snapshot.skew.partitionRetainedTopicsMax, type: "gauge")
    scalar("im_v2_actor_realtime_partition_retained_bindings_peak_lifetime", snapshot.skew.partitionRetainedBindingsPeakLifetime, type: "gauge")
    scalar("im_v2_actor_realtime_partition_retained_topics_peak_lifetime", snapshot.skew.partitionRetainedTopicsPeakLifetime, type: "gauge")
    scalar("im_v2_actor_realtime_partition_publications_active_max", snapshot.skew.partitionPublicationsActiveMax, type: "gauge")
    scalar("im_v2_actor_realtime_partition_publications_active_peak_lifetime", snapshot.skew.partitionPublicationsActivePeakLifetime, type: "gauge")
    lines.append("# HELP im_v2_actor_realtime_publication_recipient_members_max_lifetime Maximum filtered Gateway-session recipient set in process lifetime, not devices or delivered frames.")
    lines.append("# HELP im_v2_actor_realtime_delivery_target_duration_milliseconds_max_lifetime Maximum actual local callback duration in process lifetime, including failures; not remote completion or client ACK.")
    lines.append("# HELP im_v2_actor_realtime_delivery_target_oldest_active_milliseconds Oldest actual local callback still awaiting return; caller cancellation does not release it.")
    lines.append("# TYPE im_v2_actor_realtime_publication_recipient_sets_total counter")
    lines.append("# TYPE im_v2_actor_realtime_publication_recipient_members_total counter")
    lines.append("# TYPE im_v2_actor_realtime_publication_recipient_empty_sets_total counter")
    lines.append("# TYPE im_v2_actor_realtime_publication_recipient_members_max_lifetime gauge")
    lines.append("# TYPE im_v2_actor_realtime_delivery_target_active gauge")
    lines.append("# TYPE im_v2_actor_realtime_delivery_target_oldest_active_milliseconds gauge")
    lines.append("# TYPE im_v2_actor_realtime_delivery_target_duration_milliseconds_count counter")
    lines.append("# TYPE im_v2_actor_realtime_delivery_target_duration_milliseconds_sum counter")
    lines.append("# TYPE im_v2_actor_realtime_delivery_target_duration_milliseconds_max_lifetime gauge")
    for kind in V2ActorRealtimeRouteQueryKind.allCases {
        let recipients = snapshot.skew.recipientSets[kind, default: .init()]
        let target = snapshot.skew.deliveryTargets[kind, default: .init()]
        lines.append("im_v2_actor_realtime_publication_recipient_sets_total{kind=\"\(kind.rawValue)\"} \(recipients.sets)")
        lines.append("im_v2_actor_realtime_publication_recipient_members_total{kind=\"\(kind.rawValue)\"} \(recipients.members)")
        lines.append("im_v2_actor_realtime_publication_recipient_empty_sets_total{kind=\"\(kind.rawValue)\"} \(recipients.emptySets)")
        lines.append("im_v2_actor_realtime_publication_recipient_members_max_lifetime{kind=\"\(kind.rawValue)\"} \(recipients.membersMaxLifetime)")
        lines.append("im_v2_actor_realtime_delivery_target_active{kind=\"\(kind.rawValue)\"} \(target.active)")
        lines.append("im_v2_actor_realtime_delivery_target_oldest_active_milliseconds{kind=\"\(kind.rawValue)\"} \(target.oldestActiveMilliseconds)")
        lines.append("im_v2_actor_realtime_delivery_target_duration_milliseconds_count{kind=\"\(kind.rawValue)\"} \(target.completed)")
        lines.append("im_v2_actor_realtime_delivery_target_duration_milliseconds_sum{kind=\"\(kind.rawValue)\"} \(target.totalMilliseconds)")
        lines.append("im_v2_actor_realtime_delivery_target_duration_milliseconds_max_lifetime{kind=\"\(kind.rawValue)\"} \(target.maxMillisecondsLifetime)")
    }
    scalar("im_v2_actor_realtime_registrations", snapshot.registrations, type: "gauge")
    scalar("im_v2_actor_realtime_interests", snapshot.interests, type: "gauge")
    lines.append("# TYPE im_v2_actor_realtime_ingress_items gauge")
    lines.append("# TYPE im_v2_actor_realtime_ingress_bytes gauge")
    for queue in V2ActorRealtimeQueue.allCases {
        let usage = snapshot.queues[queue, default: .init()]
        lines.append("im_v2_actor_realtime_ingress_items{queue=\"\(queue.rawValue)\"} \(usage.items)")
        lines.append("im_v2_actor_realtime_ingress_bytes{queue=\"\(queue.rawValue)\"} \(usage.bytes)")
    }
    lines.append("# TYPE im_v2_actor_realtime_store_operations_total counter")
    lines.append("# TYPE im_v2_actor_realtime_store_seconds_total counter")
    for operation in V2ActorRealtimeOperation.allCases {
        for result in V2ActorRealtimeResult.allCases {
            lines.append("im_v2_actor_realtime_store_operations_total{operation=\"\(operation.rawValue)\",result=\"\(result.rawValue)\"} \(snapshot.operations[operation]?[result] ?? 0)")
        }
        lines.append("im_v2_actor_realtime_store_seconds_total{operation=\"\(operation.rawValue)\"} \(snapshot.operationSeconds[operation, default: 0])")
    }
    lines.append("# TYPE im_v2_actor_realtime_session_rotation_total counter")
    for reason in V2ActorRealtimeSessionRotationReason.allCases {
        lines.append("im_v2_actor_realtime_session_rotation_total{reason=\"\(reason.rawValue)\"} \(snapshot.sessionRotations[reason, default: 0])")
    }
    lines.append("# HELP im_v2_actor_realtime_activation_settled_total Actual retained activation waiter completions; immediate already-ready activations are excluded.")
    lines.append("# TYPE im_v2_actor_realtime_activation_settled_total counter")
    for result in V2ActorRealtimeActivationResult.allCases {
        lines.append("im_v2_actor_realtime_activation_settled_total{result=\"\(result.rawValue)\"} \(snapshot.activationSettlements[result, default: 0])")
    }
    scalar("im_v2_actor_realtime_waiter_stale_total", snapshot.activationSettlements[.stale, default: 0], type: "counter")
    let headPrefix = "im_v2_actor_realtime_head_read"
    lines.append("# HELP \(headPrefix)_duration_milliseconds_sum Actual per-kind head-read calls, including route validation, SQL acquisition and decoding; not SQL execution time alone.")
    for suffix in ["results_total", "topic_results_total", "topics_total", "duration_milliseconds_sum", "duration_milliseconds_count"] {
        lines.append("# TYPE \(headPrefix)_\(suffix) counter")
    }
    lines.append("# TYPE \(headPrefix)_duration_milliseconds_max gauge")
    for kind in V2ActorRealtimeRouteQueryKind.allCases {
        let item = snapshot.headReads[kind, default: .init()]
        let label = "kind=\"\(kind.rawValue)\""
        for result in V2ActorRealtimeHeadReadResult.allCases {
            lines.append("\(headPrefix)_results_total{\(label),result=\"\(result.rawValue)\"} \(item.results[result, default: 0])")
            lines.append("\(headPrefix)_topic_results_total{\(label),result=\"\(result.rawValue)\"} \(item.topicResults[result, default: 0])")
        }
        lines.append("\(headPrefix)_topics_total{\(label)} \(item.topics)")
        lines.append("\(headPrefix)_duration_milliseconds_sum{\(label)} \(item.totalMilliseconds)")
        lines.append("\(headPrefix)_duration_milliseconds_count{\(label)} \(item.results.values.reduce(UInt64(0), +))")
        lines.append("\(headPrefix)_duration_milliseconds_max{\(label)} \(item.maxMilliseconds)")
    }
    lines.append("# TYPE im_v2_actor_realtime_rpc_total counter")
    for result in V2ActorRealtimeRPCResult.allCases { lines.append("im_v2_actor_realtime_rpc_total{result=\"\(result.rawValue)\"} \(snapshot.rpc[result, default: 0])") }
    scalar("im_v2_actor_realtime_coverage_losses_total", snapshot.coverageLosses, type: "counter")
    scalar("im_v2_actor_realtime_body_degraded_total", snapshot.degradedBodies, type: "counter")
    scalar("im_v2_actor_realtime_admission_rejected_total", snapshot.admissionRejected, type: "counter")
    scalar("im_v2_actor_realtime_subscription_control_active", snapshot.subscriptionControlActive, type: "gauge")
    scalar("im_v2_actor_realtime_subscription_control_queued", snapshot.subscriptionControlQueued, type: "gauge")
    lines.append("# HELP im_v2_actor_realtime_recovery_active Actual recovery cohorts including head reads, retained hints and Ready callbacks, held until complete task settlement.")
    scalar("im_v2_actor_realtime_recovery_active", snapshot.recoveryActive, type: "gauge")
    lines.append("# HELP im_v2_actor_realtime_recovery_queued Partitions queued for a recovery slot, not topic or connection counts.")
    scalar("im_v2_actor_realtime_recovery_queued", snapshot.recoveryQueued, type: "gauge")
    scalar("im_v2_actor_realtime_activation_waiters", snapshot.activationWaiters, type: "gauge")
    scalar("im_v2_actor_realtime_desired_partitions", snapshot.desiredPartitions, type: "gauge")
    scalar("im_v2_actor_realtime_installed_partitions", snapshot.installedPartitions, type: "gauge")
    scalar("im_v2_actor_realtime_service_qualified", snapshot.serviceQualified, type: "gauge")
    scalar("im_v2_actor_realtime_service_qualification_remaining_seconds", snapshot.serviceQualificationRemainingSeconds, type: "gauge")
    scalar("im_v2_actor_realtime_partition_control_failed_ticks_total", snapshot.partitionControlFailedTicks, type: "counter")
    lines.append("# TYPE im_v2_actor_realtime_shard_capacity_rejected_total counter")
    for reason in V2ActorRealtimeShardCapacityRejection.allCases {
        lines.append("im_v2_actor_realtime_shard_capacity_rejected_total{reason=\"\(reason.rawValue)\"} \(snapshot.shardCapacityRejections[reason, default: 0])")
    }
    if let transport = snapshot.transport {
        scalar("im_v2_actor_realtime_cache_hits_total", transport.cacheHits, type: "counter")
        scalar("im_v2_actor_realtime_cache_misses_total", transport.cacheMisses, type: "counter")
        scalar("im_v2_actor_realtime_cache_invalidations_total", transport.cacheInvalidations, type: "counter")
        lines.append("# TYPE im_v2_actor_realtime_receptionist_lookups_total counter")
        lines.append("im_v2_actor_realtime_receptionist_lookups_total{source=\"background_discovery\"} \(transport.backgroundReceptionistLookups)")
        lines.append("im_v2_actor_realtime_receptionist_lookups_total{source=\"foreground_resolve\"} \(transport.foregroundReceptionistLookups)")
        scalar("im_v2_actor_realtime_discovery_passes_total", transport.discoveryPasses, type: "counter")
        scalar("im_v2_actor_realtime_discovery_active", transport.discoveryActive, type: "gauge")
        scalar("im_v2_actor_realtime_cached_partitions", transport.cachedPartitions, type: "gauge")
        scalar("im_v2_actor_realtime_reachable_nodes", transport.reachableNodes, type: "gauge")
        scalar("im_v2_actor_realtime_control_started_total", transport.controlStarted, type: "counter")
        scalar("im_v2_actor_realtime_control_settled_total", transport.controlSettled, type: "counter")
        scalar("im_v2_actor_realtime_control_active", transport.controlActive, type: "gauge")
        scalar("im_v2_actor_realtime_control_queued", transport.controlQueued, type: "gauge")
        scalar("im_v2_actor_realtime_control_queue_seconds_sum", transport.controlQueueSeconds, type: "counter")
        scalar("im_v2_actor_realtime_control_queue_seconds_count", transport.controlQueueSettled, type: "counter")
        scalar("im_v2_actor_realtime_publish_started_total", transport.publishStarted, type: "counter")
        scalar("im_v2_actor_realtime_publish_settled_total", transport.publishSettled, type: "counter")
        scalar("im_v2_actor_realtime_publish_active", transport.publishActive, type: "gauge")
        scalar("im_v2_actor_realtime_rpc_capacity_rejected_total", transport.rpcRejected, type: "counter")
        lines.append("# TYPE im_v2_actor_realtime_sender_capacity_rejected_total counter")
        for lane in V2RealtimeRPCAdmissionLane.allCases {
            for reason in V2RealtimeRPCAdmissionRejection.allCases {
                lines.append("im_v2_actor_realtime_sender_capacity_rejected_total{lane=\"\(lane.rawValue)\",reason=\"\(reason.rawValue)\"} \(transport.capacityRejections[lane]?[reason] ?? 0)")
            }
        }
        scalar("im_v2_actor_realtime_pending_handshakes", transport.pendingHandshakes, type: "gauge")
    }
    return lines.joined(separator: "\n") + "\n"
}
