import Foundation
import Synchronization
import Testing
import IMV2Core
import IMV2ActorContracts
@testable import IMV2ServerApplication
import IMV2ServerContracts

@Suite("Actor realtime in-memory partitions", .timeLimit(.minutes(1)))
struct V2ActorRealtimeRoutingTests {
    @Test func shardQualificationRevocationCannotResurrectInstalledToken() async throws {
        let host = descriptor("host"), gateway = descriptor("subscriber")
        let qualification = try V2ActorServiceQualification(localNodeID: "host", roster: ["host", "peer"])
        let first = try #require(qualification.update(witnesses: ["peer": .now + .seconds(20)]))
        let topic = V2RealtimeTopic(kind: .roomEvents, id: UUID().uuidString, owner: try .init(shardID: "rooms", epoch: 1))
        let token = V2RealtimeShardToken(partitionID: V2RealtimeTopicKey(topic).partitionID(), host: host.identity, epoch: 1, leaseToken: UUID())
        let service = V2RealtimeShardService(qualification: qualification, send: { _, _ in .accepted })
        await service.install(token: token, deadline: .now + .seconds(30), qualificationGeneration: first.generation)
        let session = V2RealtimeShardSession(gateway: gateway, sessionID: UUID(), sessionGeneration: 1)
        let heartbeat = try control(token, session, base: 0, mutation: .renew)
        let publication = V2RealtimeShardPublishRequest(token: token, topic: topic, payload: .roomWake(roomID: try RoomID(topic.id), highWatermark: 1))
        #expect(try await service.publish(publication) == .noSubscribers)
        qualification.revoke()
        #expect(try await service.control(heartbeat).status == .retiredEpoch)
        #expect(try await service.publish(publication) == .retiredEpoch)
        let successor = try #require(qualification.update(witnesses: ["peer": .now + .seconds(20)]))
        #expect(successor.generation != first.generation)
        await service.install(token: token, deadline: .now + .seconds(30), qualificationGeneration: first.generation)
        await service.install(token: token, deadline: .now + .seconds(30), qualificationGeneration: successor.generation)
        #expect(try await service.publish(publication) == .retiredEpoch)
        let next = V2RealtimeShardToken(partitionID: token.partitionID, host: token.host, epoch: 2, leaseToken: UUID())
        await service.install(token: next, deadline: .now + .seconds(30), qualificationGeneration: successor.generation)
        #expect(try await service.publish(.init(token: next, topic: topic, payload: publication.payload)) == .noSubscribers)
        await service.shutdown()
    }

    @Test("snapshot is atomic, controls are contiguous and old sessions cannot resurrect")
    func snapshotAndSessionFences() async throws {
        let gateway = descriptor("subscriber"), host = descriptor("host")
        let owner = try V2RoomDataOwner(shardID: "room-data", epoch: 1)
        let topic = V2RealtimeTopic(kind: .roomEvents, id: UUID().uuidString, owner: owner)
        let key = V2RealtimeTopicKey(topic)
        let token = V2RealtimeShardToken(partitionID: key.partitionID(), host: host.identity, epoch: 1, leaseToken: UUID())
        let deliveries = RealtimeDeliveryRecorder()
        let service = V2RealtimeShardService(maximumInterests: 2, maximumBytes: 2_048, send: { _, batch in await deliveries.record(batch); return .accepted })
        let unpublished = V2RealtimeShardPublishRequest(token: token, topic: topic,
            payload: .roomWake(roomID: try RoomID(topic.id), highWatermark: 1))
        #expect(try await service.publish(unpublished) == .notInstalled)
        await service.install(token: token, deadline: .now + .seconds(30))
        let session = V2RealtimeShardSession(gateway: gateway, sessionID: UUID(), sessionGeneration: 1)
        let interest = V2RealtimeShardInterest(key: key, interestGeneration: 1)
        let digest = try V2RealtimeShardFingerprint.snapshot([interest]), snapshot = UUID()
        let first = try control(token, session, base: 0, mutation: .snapshotChunk(snapshotID: snapshot, index: 0, total: 2, digest: digest, interests: [interest]))
        #expect(try await service.control(first).appliedRevision == 0)
        let publish = V2RealtimeShardPublishRequest(token: token, topic: topic,
            payload: .roomWake(roomID: try RoomID(topic.id), highWatermark: 1))
        #expect(try await service.publish(publish) == .noSubscribers)
        #expect(try await service.control(first).appliedRevision == 0) // Identical staged retry.
        let heartbeat = try control(token, session, base: 0, mutation: .renew)
        #expect(try await service.control(heartbeat).appliedRevision == 0)
        #expect(try await service.publish(publish) == .noSubscribers) // Heartbeat leaves staging atomic.
        let last = try control(token, session, base: 0, mutation: .snapshotChunk(snapshotID: snapshot, index: 1, total: 2, digest: digest, interests: []))
        #expect(try await service.control(last).appliedRevision == 1)
        #expect(try await service.publish(publish) == .accepted)
        let gap = try control(token, session, base: 2, mutation: .delta([]))
        #expect(try await service.control(gap).status == .requiresSnapshot)
        let close = try control(token, session, base: 1, mutation: .close)
        #expect(try await service.control(close).appliedRevision == 2)
        #expect(try await service.control(heartbeat).status == .requiresSnapshot)
        #expect(try await service.publish(publish) == .noSubscribers)
        let replacement = V2RealtimeShardSession(gateway: gateway, sessionID: UUID(), sessionGeneration: 2)
        let reinstalled = V2RealtimeShardInterest(key: key, interestGeneration: 2)
        let install = try control(token, replacement, base: 0, mutation: .snapshotChunk(snapshotID: UUID(), index: 0, total: 1,
            digest: V2RealtimeShardFingerprint.snapshot([reinstalled]), interests: [reinstalled]))
        #expect(try await service.control(install).appliedRevision == 1)
        #expect(try await service.control(close).status == .requiresSnapshot)
        #expect(try await service.control(first).status == .requiresSnapshot)
        #expect(try await service.publish(publish) == .accepted)
        let delivered = await deliveries.batches
        #expect(delivered.count == 2)
        #expect(delivered.last?.deliveries.first?.sessionID == replacement.sessionID)
        #expect(delivered.last?.deliveries.first?.interestGeneration == 2)
        #expect(delivered.last?.deliveries.first?.gatewayIncarnation == gateway.identity.incarnationID)
        #expect(delivered.last?.deliveries.first?.partitionEpoch == token.epoch)
        for generation in 3...8 {
            let next = V2RealtimeShardSession(gateway: gateway, sessionID: UUID(), sessionGeneration: Int64(generation))
            let item = V2RealtimeShardInterest(key: key, interestGeneration: Int64(generation))
            let installed = try control(token, next, base: 0, mutation: .snapshotChunk(snapshotID: UUID(), index: 0, total: 1,
                digest: V2RealtimeShardFingerprint.snapshot([item]), interests: [item]))
            #expect(try await service.control(installed).status == .applied)
            let closed = try control(token, next, base: 1, mutation: .close)
            #expect(try await service.control(closed).status == .applied)
            #expect(try await service.control(closed).status == .applied) // Compact tombstone preserves exact retry.
        }
        #expect(try await service.control(first).status == .requiresSnapshot)
        // Closed identities retain fences, but release descriptor/staging bytes.
        // Exhaustion asks the lease controller for a new epoch rather than
        // silently reclaiming a slot and accepting delayed old snapshots.
        let emptyDigest = try V2RealtimeShardFingerprint.snapshot([])
        for index in 0..<255 {
            let wire = V2RealtimeShardSession(gateway: descriptor("restart-\(index)"), sessionID: UUID(), sessionGeneration: 1)
            let install = try control(token, wire, base: 0, mutation: .snapshotChunk(snapshotID: UUID(), index: 0,
                total: 1, digest: emptyDigest, interests: []))
            #expect(try await service.control(install).status == .applied)
            #expect(try await service.control(control(token, wire, base: 1, mutation: .close)).status == .applied)
        }
        #expect(await service.partitionsNeedingRollover().isEmpty)
        let overflow = V2RealtimeShardSession(gateway: descriptor("overflow"), sessionID: UUID(), sessionGeneration: 1)
        let malformed = try control(token, overflow, base: 0, mutation: .snapshotChunk(snapshotID: UUID(), index: 0,
            total: 1, digest: Data(), interests: []))
        #expect(try await service.control(malformed).status == .requiresSnapshot)
        #expect(await service.partitionsNeedingRollover().isEmpty)
        let exhausted = try control(token, overflow, base: 0, mutation: .snapshotChunk(snapshotID: UUID(), index: 0,
            total: 1, digest: emptyDigest, interests: []))
        #expect(try await service.control(exhausted).status == .overloaded)
        #expect(await service.partitionsNeedingRollover() == [token.partitionID])
        #expect(try await service.control(first).status == .requiresSnapshot)
        await service.retire(token: token)
        #expect(await service.partitionsNeedingRollover().isEmpty)
        #expect(try await service.publish(publish) == .retiredEpoch)
        await service.install(token: token, deadline: .now + .seconds(30))
        #expect(try await service.publish(publish) == .retiredEpoch) // Explicitly retired token cannot be reinstalled.
        let nextEpoch = V2RealtimeShardToken(partitionID: token.partitionID, host: token.host, epoch: token.epoch + 1, leaseToken: UUID())
        await service.install(token: nextEpoch, deadline: .now + .seconds(30))
        #expect(try await service.control(control(nextEpoch, overflow, base: 0, mutation: .snapshotChunk(snapshotID: UUID(), index: 0,
            total: 1, digest: emptyDigest, interests: []))).status == .applied)
        #expect(try await service.control(first).status == .retiredEpoch)
        #expect(await service.partitionsNeedingRollover().isEmpty)
        await service.shutdown()
    }

    @Test("one failed peer preserves publication failure after every actual peer settles")
    func partialPeerFailureIsNotAccepted() async throws {
        let host = descriptor("host"), healthy = descriptor("healthy"), slow = descriptor("slow")
        let owner = try V2RoomDataOwner(shardID: "room-data", epoch: 1)
        let room = try RoomID(UUID().uuidString)
        let topic = V2RealtimeTopic(kind: .roomEvents, id: room.rawValue, owner: owner)
        let key = V2RealtimeTopicKey(topic)
        let token = V2RealtimeShardToken(partitionID: key.partitionID(), host: host.identity, epoch: 1, leaseToken: UUID())
        let actual = RealtimeDeliveryRecorder(), slowGate = RealtimeBarrier()
        let metrics = V2ActorRealtimeMetrics()
        let service = V2RealtimeShardService(metrics: metrics, send: { descriptor, batch in
            await actual.record(batch)
            if descriptor.identity.nodeID == "slow" { await slowGate.enter(); return .overloaded }
            return .accepted
        })
        await service.install(token: token, deadline: .now + .seconds(30))
        #expect(try await service.publish(.init(token: token, topic: topic,
            payload: .roomWake(roomID: room, highWatermark: 1))) == .noSubscribers)
        let interests = [V2RealtimeShardInterest(key: key, interestGeneration: 1)]
        for gateway in [healthy, slow] {
            let session = V2RealtimeShardSession(gateway: gateway, sessionID: UUID(), sessionGeneration: 1)
            let request = try control(token, session, base: 0, mutation: .snapshotChunk(snapshotID: UUID(), index: 0, total: 1,
                digest: V2RealtimeShardFingerprint.snapshot(interests), interests: interests))
            #expect(try await service.control(request).status == .applied)
        }
        let publication = Task { try await service.publish(.init(token: token, topic: topic,
            payload: .roomWake(roomID: room, highWatermark: 2))) }
        var failure: (any Error)?
        do {
            // Bounded observation includes actual sender entry, not a sleep
            // standing in for an assumed queued callback.
            let end = ContinuousClock.now + .seconds(2)
            while true {
                let observed = await metrics.actorRealtimeMetricsSnapshot().skew
                let slowEntered = await slowGate.entries
                if observed.deliveryTargets[.roomEvents]?.completed == 1 && slowEntered == 1 { break }
                guard ContinuousClock.now < end else { throw V2RealtimeDirectoryError.invalidInput }
                await Task.yield()
            }
            #expect(await slowGate.entries == 1)
            let held = await metrics.actorRealtimeMetricsSnapshot().skew
            #expect(held.partitionRetainedBindingsMax == 2 && held.partitionRetainedTopicsMax == 1)
            #expect(held.partitionPublicationsActiveMax == 1)
            #expect(held.recipientSets[.roomEvents]?.sets == 2 && held.recipientSets[.roomEvents]?.members == 2
                && held.recipientSets[.roomEvents]?.emptySets == 1)
            #expect(held.recipientSets[.roomEvents]?.membersMaxLifetime == 2)
            #expect(held.deliveryTargets[.roomEvents]?.active == 1)
            #expect(held.deliveryObservationOwners == 1 && held.deliveryObservationCapacity == 16)
            #expect(held.skewObservationOwnershipViolations == 0)
            #expect((held.deliveryTargets[.roomEvents]?.oldestActiveMilliseconds ?? 0) >= 0)
            publication.cancel()
            #expect(await metrics.actorRealtimeMetricsSnapshot().skew.deliveryTargets[.roomEvents]?.active == 1)
        } catch { failure = error }
        // Even an assertion/setup failure drains the real held callback.
        await slowGate.release()
        let publicationResult = await publication.result
        await service.shutdown()
        let finished = await metrics.actorRealtimeMetricsSnapshot().skew
        #expect(finished.partitionRetainedBindingsMax == 0 && finished.partitionRetainedTopicsMax == 0)
        #expect(finished.partitionRetainedBindingsPeakLifetime == 2 && finished.partitionRetainedTopicsPeakLifetime == 1)
        #expect(finished.partitionPublicationsActiveMax == 0 && finished.partitionPublicationsActivePeakLifetime == 1)
        #expect(finished.deliveryTargets[.roomEvents]?.active == 0 && finished.deliveryTargets[.roomEvents]?.completed == 2)
        #expect(finished.deliveryTargets[.roomEvents]?.oldestActiveMilliseconds == 0)
        #expect(finished.deliveryObservationOwners == 0 && finished.deliveryObservationCapacity == 0)
        #expect(finished.skewObservationOwnershipViolations == 0)
        #expect((finished.deliveryTargets[.roomEvents]?.maxMillisecondsLifetime ?? 0) > 0)
        #expect(await actual.batches.count == 2)
        if let failure { throw failure }
        #expect(try publicationResult.get() == .overloaded)
    }

    @Test("shared subscribe settles before head and cancelled waiter never cancels Ready barrier")
    func subscriptionHeadBarrierAndCancellation() async throws {
        let gateway = descriptor("subscriber"), host = descriptor("host")
        let owner = try V2RoomDataOwner(shardID: "room-data", epoch: 1)
        let topic = V2RealtimeTopic(kind: .roomEvents, id: UUID().uuidString, owner: owner)
        let key = V2RealtimeTopicKey(topic)
        let token = V2RealtimeShardToken(partitionID: key.partitionID(), host: host.identity, epoch: 1, leaseToken: UUID())
        let service = V2RealtimeShardService(send: { _, _ in .accepted })
        await service.install(token: token, deadline: .now + .seconds(30))
        let transport = RealtimeMemoryTransport(service: service, route: shardDescriptor(token, host))
        let gate = RealtimeBarrier()
        let coordinator = V2RealtimeInterestCoordinator(descriptor: gateway, transport: transport,
            readHeads: { topics in await gate.enter(); return Dictionary(uniqueKeysWithValues: topics.map { ($0, V2RealtimeRecoveryHeadOutcome.available(7)) }) },
            recovered: { Set($0.keys) }, coverageLost: { _, _ in })
        let first = Task { try await coordinator.activate(topic) }
        await gate.waitUntilEntered()
        #expect(await transport.controls == 1)
        #expect(!coordinator.isReady(topic))
        let installed = try #require(coordinator.journalCoverage(partitionID: key.partitionID()))
        #expect(installed.token == token && installed.revision == 1)
        #expect(installed.interests.count == 1 && installed.interests[key] != nil)
        #expect(coordinator.confirmsJournalCoverage(installed))
        let second = Task { try await coordinator.activate(topic) }
        let deadline = ContinuousClock.now + .seconds(2)
        while await coordinator.pressureSnapshot().activationWaiters < 2, ContinuousClock.now < deadline { await Task.yield() }
        #expect(await coordinator.pressureSnapshot().activationWaiters == 2)
        second.cancel()
        do { try await second.value; Issue.record("cancelled subscriber must not finish Ready") }
        catch { #expect(error is CancellationError) }
        #expect(await transport.controls == 1)
        let stopped = Task { await coordinator.shutdown() }
        for _ in 0..<10 { await Task.yield() }
        #expect(await gate.isHeld)
        await gate.release()
        do { try await first.value; Issue.record("shutdown must reject late Ready") } catch {}
        await stopped.value
        #expect(!coordinator.isReady(topic))
        #expect(coordinator.journalCoverage(partitionID: key.partitionID()) == nil)
        #expect(!coordinator.confirmsJournalCoverage(installed))
        await service.shutdown()
    }

    @Test("Ready promises installed coverage and scheduled head recovery, with exact confirmation CAS")
    func readyConfirmationCarriesBarrierAndRevokesOnScopeEnd() async throws {
        let gateway = descriptor("subscriber"), host = descriptor("host")
        let owner = try V2RoomDataOwner(shardID: "room-data", epoch: 1)
        let topic = V2RealtimeTopic(kind: .roomEvents, id: UUID().uuidString, owner: owner)
        let token = V2RealtimeShardToken(partitionID: V2RealtimeTopicKey(topic).partitionID(), host: host.identity, epoch: 1, leaseToken: UUID())
        let service = V2RealtimeShardService(send: { _, _ in .accepted })
        await service.install(token: token, deadline: .now + .seconds(30))
        let transport = RealtimeMemoryTransport(service: service, route: shardDescriptor(token, host))
        let scheduled = RealtimeBarrier()
        let coordinator = V2RealtimeInterestCoordinator(descriptor: gateway, transport: transport, maximumDesiredInterests: 1,
            readHeads: { Dictionary(uniqueKeysWithValues: $0.map { ($0, V2RealtimeRecoveryHeadOutcome.available(17)) }) },
            recovered: { heads in #expect(heads.values.allSatisfy { $0 == 17 }); await scheduled.enter(); return Set(heads.keys) }, coverageLost: { _, _ in })
        let journalChanges = Mutex<[V2RealtimeInterestCoordinator.JournalCoverageChange]>([])
        coordinator.configureJournalCoverageObserver { event in journalChanges.withLock { $0.append(event) } }
        let activation = Task { try await coordinator.activate(topic) }
        await scheduled.waitUntilEntered()
        #expect(coordinator.currentConfirmation(kind: topic.kind, id: topic.id) == nil)
        #expect(await coordinator.pressureSnapshot().controlInFlight == 0)
        await scheduled.release()
        try await activation.value
        let confirmation = try #require(coordinator.currentConfirmation(kind: topic.kind, id: topic.id))
        #expect(confirmation.highWatermark == 17)
        #expect(coordinator.confirms(topic: topic, confirmation: confirmation))
        #expect(coordinator.confirmsCurrent(kind: topic.kind, id: topic.id, confirmation: confirmation))
        let interestProof = try #require(coordinator.journalInterest(topic: topic))
        #expect(interestProof.generation == confirmation.interestGeneration)
        #expect(coordinator.confirmsJournalInterest(interestProof))
        #expect(coordinator.activeJournalCoverages().count == 1)
        coordinator.configureTrustedJournalRenewal { expected in coordinator.confirmsJournalCoverage(expected) }
        await coordinator.maintainCoverage()
        await transport.waitForRenewal()
        let renewalDeadline = ContinuousClock.now + .seconds(3)
        while !journalChanges.withLock({ $0.contains { if case .renewed = $0 { return true }; return false } }), ContinuousClock.now < renewalDeadline { await Task.yield() }
        let renewed = journalChanges.withLock { $0.contains { if case .renewed = $0 { return true }; return false } }
        #expect(renewed)
        #expect(coordinator.confirmsJournalInterest(interestProof))
        await coordinator.deactivate(topic)
        #expect(!coordinator.confirmsJournalInterest(interestProof))
        let invalidated = journalChanges.withLock { $0.contains { if case .invalidated(let id) = $0 { return id == token.partitionID }; return false } }
        #expect(invalidated)
        #expect(!coordinator.confirmsCurrent(kind: topic.kind, id: topic.id, confirmation: confirmation))
        #expect(await coordinator.pressureSnapshot().desiredInterests == 0)
        let alternate = try #require((1...4_096).lazy.map { index in
            V2RealtimeTopic(kind: .roomEvents, id: String(format: "00000000-0000-0000-0000-%012x", index), owner: owner)
        }.first { V2RealtimeTopicKey($0).partitionID() == token.partitionID && $0 != topic })
        try await coordinator.activate(alternate) // Removed topic cannot permanently consume the cap of one.
        await coordinator.deactivate(alternate)
        try await coordinator.activate(topic)
        let replacement = try #require(coordinator.currentConfirmation(kind: topic.kind, id: topic.id))
        #expect(replacement.interestGeneration > confirmation.interestGeneration)
        let late = V2RealtimeDelivery(topic: topic, partitionID: token.partitionID, partitionEpoch: token.epoch,
            sessionID: confirmation.sessionID, interestGeneration: confirmation.interestGeneration,
            gatewayIncarnation: gateway.identity.incarnationID, payload: .roomWake(roomID: try RoomID(topic.id), highWatermark: 17))
        #expect(!coordinator.accepts(late))
        #expect(!coordinator.confirms(topic: topic, confirmation: confirmation))
        await coordinator.shutdown(); await service.shutdown()
    }

    @Test("transient publication capacity cannot exhaust durable publication permits")
    func transientIsolationAndActualDrain() async throws {
        let host = descriptor("host")
        let owner = try V2RoomDataOwner(shardID: "user-data", epoch: 1)
        let gate = RealtimeBarrier()
        let transport = RealtimePublicationProbe(host: host, gate: gate)
        let dispatcher = V2RealtimeFanoutDispatcher(transport: transport)
        let users = (0..<5).map { _ in UUID().uuidString }
        let calls = users.prefix(4).map { id in Task {
            try await dispatcher.publish(topic: .init(kind: .userPresence, id: id, owner: owner), payload: .presence(userID: try UserID(id)))
        } }
        await transport.waitForFour()
        await #expect(throws: V2RealtimePublicationBackpressure.self) {
            try await dispatcher.publish(topic: .init(kind: .userPresence, id: users[4], owner: owner), payload: .presence(userID: try UserID(users[4])))
        }
        let room = try RoomID(UUID().uuidString)
        try await dispatcher.publish(topic: .init(kind: .roomEvents, id: room.rawValue, owner: owner), payload: .roomWake(roomID: room, highWatermark: 1))
        #expect(await transport.durable == 1)
        let stop = Task { await dispatcher.shutdown() }
        for _ in 0..<10 { await Task.yield() }
        #expect(await transport.active == 4)
        await gate.release()
        for call in calls { try await call.value }
        await stop.value
        #expect(await transport.active == 0)
    }

    @Test("token and owner replacements settle only obsolete activation generations", arguments: [false, true])
    func replacedActivationGenerationTerminates(replaceOwner: Bool) async throws {
        let gateway = descriptor("subscriber"), host = descriptor("host")
        let owner = try V2RoomDataOwner(shardID: "room-data", epoch: 1)
        let topic = V2RealtimeTopic(kind: .roomEvents, id: UUID().uuidString, owner: owner)
        let partition = V2RealtimeTopicKey(topic).partitionID()
        var sibling = V2RealtimeTopic(kind: .roomEvents, id: UUID().uuidString, owner: owner)
        while V2RealtimeTopicKey(sibling).partitionID() != partition {
            sibling = .init(kind: .roomEvents, id: UUID().uuidString, owner: owner)
        }
        var independent = V2RealtimeTopic(kind: .roomEvents, id: UUID().uuidString, owner: owner)
        while V2RealtimeTopicKey(independent).partitionID() == partition {
            independent = .init(kind: .roomEvents, id: UUID().uuidString, owner: owner)
        }
        let stableSibling = sibling, stableIndependent = independent
        let transport = RealtimeReplacementTransport(host: host)
        let gate = RealtimeBarrier(), metrics = V2ActorRealtimeMetrics()
        let coordinator = V2RealtimeInterestCoordinator(descriptor: gateway, transport: transport, metrics: metrics,
            readHeads: { topics in
                if replaceOwner && topics.contains(topic) { await gate.enter() }
                return Dictionary(uniqueKeysWithValues: topics.map { ($0, V2RealtimeRecoveryHeadOutcome.available(7)) })
            }, recovered: { Set($0.keys) }, coverageLost: { _, _ in })
        try await coordinator.activate(stableIndependent)
        let independentConfirmation = try #require(coordinator.currentConfirmation(kind: stableIndependent.kind, id: stableIndependent.id))
        let old: Task<Void, any Error>
        let successor: V2RealtimeTopic
        if replaceOwner {
            old = Task { try await coordinator.activate(topic) }
            await gate.waitUntilEntered()
            successor = .init(kind: topic.kind, id: topic.id, owner: try .init(shardID: "room-data", epoch: 2))
        } else {
            try await coordinator.activate(topic)
            await transport.replaceEpoch(partition)
            successor = stableSibling
            old = Task { try await coordinator.activate(stableSibling) }
        }
        let replacement: Task<Void, any Error>?
        if replaceOwner { replacement = Task { try await coordinator.activate(successor) } }
        else { replacement = nil }
        // Bounded observation ensures a regression cleans up instead of hanging
        // while awaiting a continuation that can no longer become Ready.
        let until = ContinuousClock.now + .seconds(2)
        while await metrics.actorRealtimeMetricsSnapshot().activationSettlements[.stale, default: 0] == 0,
              ContinuousClock.now < until { await Task.yield() }
        let stale = await metrics.actorRealtimeMetricsSnapshot().activationSettlements[.stale, default: 0]
        #expect(stale == 1)
        if stale == 0 {
            await gate.release(); old.cancel(); replacement?.cancel()
            await coordinator.shutdown(); _ = try? await old.value; _ = try? await replacement?.value
            return
        }
        do { try await old.value; Issue.record("obsolete activation must terminate stale") }
        catch { #expect((error as? V2RealtimeInterestCoordinator.Failure).map { if case .stale = $0 { true } else { false } } == true) }
        await gate.release()
        if let replacement { try await replacement.value }
        else { try await coordinator.activate(successor) }
        #expect(coordinator.isReady(successor))
        #expect(coordinator.confirms(topic: stableIndependent, confirmation: independentConfirmation))
        #expect(await coordinator.pressureSnapshot().activationWaiters == 0)
        await coordinator.shutdown()
    }

    @Test("head barriers do not hold control or renewal, and shutdown drains the actual barrier")
    func headBarrierDoesNotBlockControlOrRenewal() async throws {
        let gateway = descriptor("subscriber"), host = descriptor("host")
        let owner = try V2RoomDataOwner(shardID: "room-data", epoch: 1)
        let first = V2RealtimeTopic(kind: .roomEvents, id: UUID().uuidString, owner: owner)
        let partition = V2RealtimeTopicKey(first).partitionID()
        var second = V2RealtimeTopic(kind: .roomEvents, id: UUID().uuidString, owner: owner)
        while V2RealtimeTopicKey(second).partitionID() != partition {
            second = .init(kind: .roomEvents, id: UUID().uuidString, owner: owner)
        }
        let sibling = second
        let token = V2RealtimeShardToken(partitionID: partition, host: host.identity, epoch: 1, leaseToken: UUID())
        let service = V2RealtimeShardService(send: { _, _ in .accepted })
        await service.install(token: token, deadline: .now + .seconds(30))
        let transport = RealtimeMemoryTransport(service: service, route: shardDescriptor(token, host))
        let gate = RealtimeBarrier()
        let coordinator = V2RealtimeInterestCoordinator(descriptor: gateway, transport: transport,
            readHeads: { topics in await gate.enter(); return Dictionary(uniqueKeysWithValues: topics.map { ($0, .available(7)) }) },
            recovered: { Set($0.keys) }, coverageLost: { _, _ in })
        let a = Task { try await coordinator.activate(first) }
        await gate.waitUntilEntered()
        let b = Task { try await coordinator.activate(sibling) }
        await transport.waitForControls(2)
        await transport.waitForRenewal()
        #expect(await gate.isHeld)
        #expect(await coordinator.pressureSnapshot().recoveryInFlight == 1)
        #expect(await coordinator.pressureSnapshot().controlInFlight == 0)
        let stop = Task { await coordinator.shutdown() }
        let until = ContinuousClock.now + .seconds(2)
        while await coordinator.pressureSnapshot().activationWaiters > 0, ContinuousClock.now < until { await Task.yield() }
        #expect(await coordinator.pressureSnapshot().activationWaiters == 0)
        #expect(await coordinator.pressureSnapshot().recoveryInFlight == 1)
        await gate.release()
        do { try await a.value; Issue.record("late head became Ready during shutdown") } catch {}
        do { try await b.value; Issue.record("queued head became Ready during shutdown") } catch {}
        await stop.value
        #expect(await coordinator.pressureSnapshot().recoveryInFlight == 0)
        await service.shutdown()
    }

    @Test("recovery slots remain owned after waiter cancellation until the actual heads settle")
    func boundedRecoveryOwnsActualWorkDuringDrain() async throws {
        let gateway = descriptor("subscriber"), host = descriptor("host")
        let owner = try V2RoomDataOwner(shardID: "room-data", epoch: 1)
        let service = V2RealtimeShardService(send: { _, _ in .accepted })
        var topics: [V2RealtimeTopic] = [], routes: [Int: V2RealtimeShardDescriptor] = [:]
        while topics.count < 5 {
            let topic = V2RealtimeTopic(kind: .roomEvents, id: UUID().uuidString, owner: owner)
            let partition = V2RealtimeTopicKey(topic).partitionID()
            guard routes[partition] == nil else { continue }
            let token = V2RealtimeShardToken(partitionID: partition, host: host.identity, epoch: 1, leaseToken: UUID())
            await service.install(token: token, deadline: .now + .seconds(30))
            routes[partition] = shardDescriptor(token, host); topics.append(topic)
        }
        let transport = RealtimeMemoryTransport(service: service, routes: routes), gate = RealtimeBarrier()
        let coordinator = V2RealtimeInterestCoordinator(descriptor: gateway, transport: transport,
            readHeads: { topics in await gate.enter(); return Dictionary(uniqueKeysWithValues: topics.map { ($0, .available(1)) }) },
            recovered: { Set($0.keys) }, coverageLost: { _, _ in })
        let tasks = topics.map { topic in Task { try await coordinator.activate(topic) } }
        await gate.waitForEntries(4)
        await transport.waitForControls(5)
        let queuedUntil = ContinuousClock.now + .seconds(2)
        while await coordinator.pressureSnapshot().recoveryQueued < 1, ContinuousClock.now < queuedUntil { await Task.yield() }
        #expect(await coordinator.pressureSnapshot().recoveryInFlight == 4)
        #expect(await coordinator.pressureSnapshot().recoveryQueued == 1)
        for task in tasks { task.cancel() }
        for task in tasks { do { try await task.value; Issue.record("cancelled waiter completed Ready") } catch { #expect(error is CancellationError) } }
        #expect(await coordinator.pressureSnapshot().recoveryInFlight == 4)
        let stop = Task { await coordinator.shutdown() }
        // A post-shutdown activation proves shutdown has closed admission;
        // this does not release any real head task.
        let until = ContinuousClock.now + .seconds(2)
        var closed = false
        while ContinuousClock.now < until {
            do { try await coordinator.start(); await Task.yield() }
            catch { closed = true; break }
        }
        #expect(closed)
        await gate.release(); await stop.value
        #expect(await gate.entries == 4)
        #expect(await coordinator.pressureSnapshot().recoveryInFlight == 0)
        await service.shutdown()
    }

    @Test("unavailable topic settles locally without rotating a healthy installed session")
    func partialHeadFailurePreservesHealthyTopic() async throws {
        let gateway = descriptor("subscriber"), host = descriptor("host")
        let owner = try V2RoomDataOwner(shardID: "room-data", epoch: 1)
        let bad = V2RealtimeTopic(kind: .roomEvents, id: UUID().uuidString, owner: owner)
        let partition = V2RealtimeTopicKey(bad).partitionID()
        var other = V2RealtimeTopic(kind: .roomEvents, id: UUID().uuidString, owner: owner)
        while V2RealtimeTopicKey(other).partitionID() != partition { other = .init(kind: .roomEvents, id: UUID().uuidString, owner: owner) }
        let good = other
        let token = V2RealtimeShardToken(partitionID: partition, host: host.identity, epoch: 1, leaseToken: UUID())
        let service = V2RealtimeShardService(send: { _, _ in .accepted })
        await service.install(token: token, deadline: .now + .seconds(30))
        let transport = RealtimeMemoryTransport(service: service, route: shardDescriptor(token, host))
        let heads = RealtimeHeadState(unavailable: [bad]), loss = RealtimeBarrier()
        let coordinator = V2RealtimeInterestCoordinator(descriptor: gateway, transport: transport,
            readHeads: { await heads.read($0) }, recovered: { Set($0.keys) },
            coverageLost: { topics, _ in #expect(topics == [bad]); await loss.enter() })
        do { try await coordinator.activate([bad, good]); Issue.record("unavailable topic must settle recovering") }
        catch { #expect((error as? V2RealtimeInterestCoordinator.Failure).map { if case .recovering = $0 { true } else { false } } == true) }
        // The failed topic settles the batch waiter before the independent
        // healthy recovery necessarily finishes. Await its existing exact
        // activation barrier before asserting the healthy Ready promise.
        try await coordinator.activate(good)
        #expect(!coordinator.isReady(bad)); #expect(coordinator.isReady(good))
        #expect(await transport.controls == 1)
        #expect(await coordinator.pressureSnapshot().activationWaiters == 0)
        await heads.setUnavailable([])
        await coordinator.maintainCoverage(recheckHeads: true)
        try await coordinator.activate(bad)
        #expect(coordinator.isReady(bad))
        let until = ContinuousClock.now + .seconds(2)
        while await coordinator.pressureSnapshot().recoveryInFlight > 0, ContinuousClock.now < until { await Task.yield() }
        let healthy = try #require(coordinator.currentConfirmation(kind: good.kind, id: good.id))
        await heads.setUnavailable([bad])
        await coordinator.maintainCoverage(recheckHeads: true)
        await loss.waitUntilEntered()
        #expect(!coordinator.isReady(bad)); #expect(coordinator.isReady(good))
        #expect(coordinator.currentConfirmation(kind: good.kind, id: good.id)?.sessionID == healthy.sessionID)
        #expect(await coordinator.pressureSnapshot().recoveryInFlight == 1) // actual lost callback is still held
        await heads.setUnavailable([])
        await loss.release()
        let settledUntil = ContinuousClock.now + .seconds(2)
        while await coordinator.pressureSnapshot().recoveryInFlight > 0, ContinuousClock.now < settledUntil { await Task.yield() }
        #expect(await coordinator.pressureSnapshot().recoveryInFlight == 0)
        let restored = Task { try await coordinator.activate(bad) }
        let waiterUntil = ContinuousClock.now + .seconds(2)
        while await coordinator.pressureSnapshot().activationWaiters == 0, ContinuousClock.now < waiterUntil { await Task.yield() }
        await coordinator.maintainCoverage(recheckHeads: true)
        try await restored.value
        #expect(coordinator.isReady(bad)); #expect(coordinator.isReady(good))
        #expect(coordinator.currentConfirmation(kind: bad.kind, id: bad.id)?.sessionID == healthy.sessionID)
        await coordinator.shutdown(); await service.shutdown()
    }

    private func descriptor(_ name: String) -> V2GatewayRealtimeDescriptor {
        .init(identity: .init(nodeID: name, serviceID: name, incarnationID: UUID()), endpointReference: Data([1]), address: "127.0.0.1", port: 7337)
    }
    private func shardDescriptor(_ token: V2RealtimeShardToken, _ host: V2GatewayRealtimeDescriptor) -> V2RealtimeShardDescriptor {
        .init(token: token, endpointReference: host.endpointReference, address: host.address, port: host.port, remainingLeaseMilliseconds: 30_000)
    }
    private func control(_ token: V2RealtimeShardToken, _ session: V2RealtimeShardSession, base: Int64,
                         mutation: V2RealtimeShardMutation) throws -> V2RealtimeShardControlRequest {
        let next: Int64
        if case .renew = mutation { next = base } else { next = base + 1 }
        return .init(token: token, session: session, baseRevision: base, nextRevision: next, mutation: mutation,
            payloadFingerprint: try V2RealtimeShardFingerprint.control(token: token, session: session, baseRevision: base, nextRevision: next, mutation: mutation))
    }
}

private actor RealtimeDeliveryRecorder {
    var batches: [V2RealtimeBatch] = []
    func record(_ batch: V2RealtimeBatch) { batches.append(batch) }
}
private actor RealtimeBarrier {
    private var held = true
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var entered = false
    private(set) var entries = 0
    private var entryObservers: [(Int, CheckedContinuation<Void, Never>)] = []
    private var observers: [CheckedContinuation<Void, Never>] = []
    var isHeld: Bool { held }
    func enter() async {
        entries += 1
        let reached = entryObservers.filter { $0.0 <= entries }; entryObservers.removeAll { $0.0 <= entries }
        for observer in reached { observer.1.resume() }
        entered = true; let old = observers; observers.removeAll(); for observer in old { observer.resume() }
        if held { await withCheckedContinuation { waiters.append($0) } }
    }
    func waitForEntries(_ count: Int) async {
        if entries < count { await withCheckedContinuation { entryObservers.append((count, $0)) } }
    }
    func waitUntilEntered() async { if !entered { await withCheckedContinuation { observers.append($0) } } }
    func release() { held = false; let old = waiters; waiters.removeAll(); for waiter in old { waiter.resume() } }
}
private actor RealtimeMemoryTransport: V2RealtimeShardTransport {
    let service: V2RealtimeShardService
    let routes: [Int: V2RealtimeShardDescriptor]
    var controls = 0
    private var renewals = 0
    private var mutations = 0
    private var controlObservers: [(Int, CheckedContinuation<Void, Never>)] = []
    private var renewalObservers: [CheckedContinuation<Void, Never>] = []
    func waitForControls(_ count: Int) async {
        if mutations < count { await withCheckedContinuation { controlObservers.append((count, $0)) } }
    }
    func waitForRenewal() async {
        if renewals == 0 { await withCheckedContinuation { renewalObservers.append($0) } }
    }
    init(service: V2RealtimeShardService, route: V2RealtimeShardDescriptor) { self.service = service; self.routes = [route.token.partitionID: route] }
    init(service: V2RealtimeShardService, routes: [Int: V2RealtimeShardDescriptor]) { self.service = service; self.routes = routes }
    func resolve(partitionID: Int) async throws -> V2RealtimeShardDescriptor {
        guard let route = routes[partitionID] else { throw V2RealtimeInterestCoordinator.Failure.missingOwner }
        return route
    }
    func control(_ descriptor: V2RealtimeShardDescriptor, request: V2RealtimeShardControlRequest) async throws -> V2RealtimeShardControlReply {
        controls += 1
        let reply = try await service.control(request)
        if case .renew = request.mutation {} else { mutations += 1 }
        let ready = controlObservers.filter { $0.0 <= mutations }; controlObservers.removeAll { $0.0 <= mutations }
        for observer in ready { observer.1.resume() }
        if case .renew = request.mutation {
            renewals += 1; let old = renewalObservers; renewalObservers.removeAll(); for observer in old { observer.resume() }
        }
        return reply
    }
    func publish(_ descriptor: V2RealtimeShardDescriptor, request: V2RealtimeShardPublishRequest) async throws -> V2RealtimeShardPublishReply { try await service.publish(request) }
    func invalidate(_ descriptor: V2RealtimeShardDescriptor) async {}
}
private actor RealtimePublicationProbe: V2RealtimeShardTransport {
    let host: V2GatewayRealtimeDescriptor; let gate: RealtimeBarrier
    var active = 0; var durable = 0
    var observers: [CheckedContinuation<Void, Never>] = []
    init(host: V2GatewayRealtimeDescriptor, gate: RealtimeBarrier) { self.host = host; self.gate = gate }
    func resolve(partitionID: Int) async throws -> V2RealtimeShardDescriptor {
        .init(token: .init(partitionID: partitionID, host: host.identity, epoch: 1, leaseToken: UUID()),
            endpointReference: host.endpointReference, address: host.address, port: host.port, remainingLeaseMilliseconds: 30_000)
    }
    func control(_ descriptor: V2RealtimeShardDescriptor, request: V2RealtimeShardControlRequest) async throws -> V2RealtimeShardControlReply {
        .init(appliedRevision: request.nextRevision, remainingSessionMilliseconds: 30_000, status: .applied)
    }
    func publish(_ descriptor: V2RealtimeShardDescriptor, request: V2RealtimeShardPublishRequest) async throws -> V2RealtimeShardPublishReply {
        if request.topic.kind == .roomEvents { durable += 1; return .accepted }
        active += 1
        if active == 4 { let old = observers; observers.removeAll(); for waiter in old { waiter.resume() } }
        await gate.enter(); active -= 1; return .accepted
    }
    func waitForFour() async { if active < 4 { await withCheckedContinuation { observers.append($0) } } }
    func invalidate(_ descriptor: V2RealtimeShardDescriptor) async {}
}

private actor RealtimeReplacementTransport: V2RealtimeShardTransport {
    let host: V2GatewayRealtimeDescriptor
    private var tokens: [Int: V2RealtimeShardToken] = [:]
    init(host: V2GatewayRealtimeDescriptor) { self.host = host }
    func replaceEpoch(_ partition: Int) {
        tokens[partition] = .init(partitionID: partition, host: host.identity, epoch: 2, leaseToken: UUID())
    }
    func resolve(partitionID: Int) async throws -> V2RealtimeShardDescriptor {
        let token = tokens[partitionID] ?? .init(partitionID: partitionID, host: host.identity, epoch: 1, leaseToken: UUID())
        tokens[partitionID] = token
        // Each subsequent demand authoritatively refreshes the cached route.
        return .init(token: token, endpointReference: host.endpointReference, address: host.address,
                     port: host.port, remainingLeaseMilliseconds: 9_000)
    }
    func control(_ descriptor: V2RealtimeShardDescriptor, request: V2RealtimeShardControlRequest) async throws -> V2RealtimeShardControlReply {
        .init(appliedRevision: request.nextRevision, remainingSessionMilliseconds: 9_000, status: .applied)
    }
    func publish(_ descriptor: V2RealtimeShardDescriptor, request: V2RealtimeShardPublishRequest) async throws -> V2RealtimeShardPublishReply { .accepted }
    func invalidate(_ descriptor: V2RealtimeShardDescriptor) async {}
}

private actor RealtimeHeadState {
    private var unavailable: Set<V2RealtimeTopic>
    init(unavailable: Set<V2RealtimeTopic>) { self.unavailable = unavailable }
    func setUnavailable(_ topics: Set<V2RealtimeTopic>) { unavailable = topics }
    func read(_ topics: [V2RealtimeTopic]) -> [V2RealtimeTopic: V2RealtimeRecoveryHeadOutcome] {
        Dictionary(uniqueKeysWithValues: topics.map {
            ($0, unavailable.contains($0) ? .unavailable(.dependency) : .available(9))
        })
    }
}
