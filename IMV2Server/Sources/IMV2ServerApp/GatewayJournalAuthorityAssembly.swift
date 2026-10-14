import Foundation
import IMV2Core
import IMV2ActorContracts
import IMV2ServerContracts
import IMV2ServerApplication
import IMV2ServerInfrastructure
import IMV2ServerGateway

enum GatewayJournalAuthorityError: String, Error {
    case coverageChanged, sourceLeaseChanged, sourceExpired, userSelectionChanged
    case userFloorRejected, roomBindingRejected, userBindingRejected
    case snapshotRejected, snapshotNotApplied
}

/// Production cold recovery validates local acknowledged interest coverage,
/// source-local database ownership, and a same-MVCC authoritative snapshot.
/// None of those witnesses can be installed by the remote RPC payload.
enum GatewayJournalAuthorityAssembly {
    static func recovery(catalog: GatewayJournalSourceCatalog,
                         coordinator: V2RealtimeInterestCoordinator,
                         registry: V2DeviceConnectionRegistry,
                         receiver: V2GatewayJournalProjectionReceiver) -> GatewayJournalRecoveryCoordinator {
        let sourceCount = Set(catalog.logicalAliases.compactMap { try? catalog.entry(logicalAlias: $0).identity.sourceID }).count
        return GatewayJournalRecoveryCoordinator(maximumSources: max(1, sourceCount) * 256,
            isCurrent: { work, _ in
                if GatewayJournalDiagnostics.enabled {
                    switch receiver.assessedRecoveryCheckpoint(source: work.batch.source, fence: work.batch.fence,
                        minimumCut: work.minimumCut) {
                    case .success: return true
                    case .failure(let reason): GatewayJournalDiagnostics.failure(reason); return false
                    }
                }
                return receiver.recoveryCheckpoint(source: work.batch.source, fence: work.batch.fence,
                    minimumCut: work.minimumCut) != nil
            }, execute: { work in
                try await recover(catalog: catalog, coordinator: coordinator, registry: registry,
                    receiver: receiver, request: work.batch, serviceID: work.service,
                    minimumCut: work.minimumCut, controls: work.controls, baseline: work.baseline)
            })
    }
    static func build(catalog: GatewayJournalSourceCatalog,
                      coordinator: V2RealtimeInterestCoordinator,
                      registry: V2DeviceConnectionRegistry,
                      receiver: V2GatewayJournalProjectionReceiver,
                      recovery: GatewayJournalRecoveryCoordinator) -> V2GatewayJournalAuthorityIngress {
        let sourceCount = Set(catalog.logicalAliases.compactMap {
            try? catalog.entry(logicalAlias: $0).identity.sourceID
        }).count
        return V2GatewayJournalAuthorityIngress(receiver: receiver, maximumSources: max(1, sourceCount) * 256,
        recoverControls: { request, serviceID, minimumCut, controls in
            _ = try await recovery.run(.init(batch: request, service: serviceID, minimumCut: minimumCut,
                interestRevision: await registry.journalUserControlInterestRevision(partitionID: request.source.partitionID),
                controls: controls))
        }, recover: { _, _, _ in throw V2RealtimeJournalError.invalidInput },
        notify: { _ in })
    }
    static func refresh(catalog: GatewayJournalSourceCatalog,
                        coordinator: V2RealtimeInterestCoordinator,
                        registry: V2DeviceConnectionRegistry,
                        receiver: V2GatewayJournalProjectionReceiver,
                        source: V2RealtimeJournalSource,
                        gatewayIdentity: V2GatewayRealtimeIdentity,
                        recovery: GatewayJournalRecoveryCoordinator,
                        minimumCut: Int64 = 0,
                        controls: V2GatewayJournalRecoveryControls = .init(),
                        sourceProof: GatewayJournalSourceCatalog.SourceProof? = nil) async throws {
        guard let coverage = coordinator.journalCoverage(partitionID: source.partitionID) else {
            throw GatewayJournalAuthorityError.coverageChanged
        }
        let entry = try catalog.entry(logicalAlias: source.sourceID)
        guard entry.identity.databaseIncarnation == source.incarnationID else { throw GatewayJournalSourceCatalog.CatalogError.identityChanged }
        let fence: V2RealtimeJournalProjectionFence
        if let live = receiver.recoveryBindingSnapshot(source: source),
           live.fence.publisherIncarnationID == coverage.token.host.incarnationID,
           live.fence.routingPartitionEpoch == coverage.token.epoch,
           live.fence.routingLeaseToken == coverage.token.leaseToken,
           live.fence.sessionID == coverage.sessionID, live.fence.interestGeneration == coverage.revision,
           live.fence.gatewayIncarnationID == gatewayIdentity.incarnationID,
           sourceProof.map({ $0.identity == entry.identity && $0.validUntil > .now
               && GatewayJournalRuntime.matchesSourceLease($0.lease, fence: live.fence, host: coverage.token.host) }) ?? true,
           coordinator.confirmsJournalCoverage(coverage) {
            fence = live.fence
        } else {
            let observed: GatewayJournalSourceCatalog.SourceProof?
            if let sourceProof { observed = sourceProof }
            else { observed = try await catalog.sourceProofs(logicalAlias: source.sourceID, partitionIDs: [source.partitionID])[source.partitionID] }
            guard let observed, observed.identity == entry.identity, observed.validUntil > .now,
                  observed.value.partitionID == source.partitionID, observed.lease.partitionID == source.partitionID,
                  observed.lease.identity == coverage.token.host, coordinator.confirmsJournalCoverage(coverage) else {
                throw GatewayJournalAuthorityError.sourceLeaseChanged
            }
            let lease = observed.lease
            fence = V2RealtimeJournalProjectionFence(publisherIncarnationID: lease.identity.incarnationID,
                sourceLeaseEpoch: lease.epoch, sourceLeaseToken: lease.token,
                sourceLeaseExpiresAt: Date().addingTimeInterval(lease.remainingLeaseSeconds),
                routingPartitionEpoch: coverage.token.epoch, routingLeaseToken: coverage.token.leaseToken,
                sessionID: coverage.sessionID, interestGeneration: coverage.revision,
                gatewayIncarnationID: gatewayIdentity.incarnationID)
        }
        let request = V2RealtimeJournalProjectionBatch(source: source, fence: fence,
            payload: .baseline(minimumCut: minimumCut))
        _ = try await recovery.run(.init(batch: request, service: coverage.token.host.serviceID,
            minimumCut: minimumCut,
            interestRevision: await registry.journalUserControlInterestRevision(partitionID: source.partitionID),
            controls: controls))
    }

    @concurrent private static func recover(catalog: GatewayJournalSourceCatalog,
                                coordinator: V2RealtimeInterestCoordinator,
                                registry: V2DeviceConnectionRegistry,
                                receiver: V2GatewayJournalProjectionReceiver,
                                request: V2RealtimeJournalProjectionBatch,
                                serviceID: String, minimumCut: Int64,
                                controls: V2GatewayJournalRecoveryControls,
                                baseline: GatewayJournalRecoveryCoordinator.Proof?) async throws -> GatewayJournalRecoveryCoordinator.Proof {
            let recoverySpan = GatewayJournalDiagnostics.begin()
            defer { GatewayJournalDiagnostics.end(recoverySpan, stage: .recovery) }
            guard let coverage = coordinator.journalCoverage(partitionID: request.source.partitionID),
                  coverage.token.epoch == request.fence.routingPartitionEpoch,
                  coverage.token.leaseToken == request.fence.routingLeaseToken,
                  coverage.sessionID == request.fence.sessionID,
                  coverage.revision == request.fence.interestGeneration,
                  coverage.token.host.incarnationID == request.fence.publisherIncarnationID,
                  coverage.token.host.serviceID == serviceID else { throw GatewayJournalAuthorityError.coverageChanged }
            let entry = try catalog.entry(logicalAlias: request.source.sourceID)
            guard entry.identity.databaseIncarnation == request.source.incarnationID else {
                throw GatewayJournalSourceCatalog.CatalogError.identityChanged
            }
            let proofSpan = GatewayJournalDiagnostics.begin()
            let proofs: [Int: GatewayJournalSourceCatalog.SourceProof]
            do {
                defer { GatewayJournalDiagnostics.end(proofSpan, stage: .proof) }
                proofs = try await catalog.sourceProofs(logicalAlias: request.source.sourceID,
                    partitionIDs: [request.source.partitionID])
            }
            guard let proof = proofs[request.source.partitionID],
                GatewayJournalRuntime.matchesSourceLease(proof.lease, fence: request.fence, host: coverage.token.host),
                coordinator.confirmsJournalCoverage(coverage) else {
                receiver.retire(source: request.source, fence: request.fence)
                throw GatewayJournalAuthorityError.sourceLeaseChanged
            }
            let deadline = min(coverage.deadline, proof.validUntil)
            guard deadline > .now else { throw GatewayJournalAuthorityError.sourceExpired }
            let requestedAt = ContinuousClock.now
            let selectionSpan = GatewayJournalDiagnostics.begin()
            let selection = await registry.journalUserControlInterests(partitionID: request.source.partitionID)
            GatewayJournalDiagnostics.end(selectionSpan, stage: .selection)
            let requested = selection.interests
            let users = Set(requested.map(\.userID))
            guard Set(controls.versions.keys).isSubset(of: users) else { throw GatewayJournalAuthorityError.userSelectionChanged }
            var selected = requested
            var effectiveControls = controls
            var incrementalCut: Int64?
            let sameInterests = baseline?.interestRevision == selection.revision
            let knownUsers = sameInterests && users.allSatisfy({ baseline?.versions[$0] != nil })
            let liveFloors = knownUsers && receiver.retainsRecoveryFloors(source: request.source, fence: request.fence,
                versions: baseline!.versions.filter { users.contains($0.key) })
            if GatewayJournalDiagnostics.enabled {
                if baseline != nil {
                    if !sameInterests { GatewayJournalDiagnostics.fallback(.interestChanged) }
                    else if !knownUsers { GatewayJournalDiagnostics.fallback(.missingUser) }
                    else if !liveFloors { GatewayJournalDiagnostics.fallback(.floorsUnavailable) }
                } else { GatewayJournalDiagnostics.fallback(.noBaseline) }
            }
            if let baseline, liveFloors {
                let target = max(minimumCut, baseline.cut, proof.value.publishedThrough)
                var plan = GatewayJournalControlCatchUp(through: baseline.cut, target: target, controls: controls,
                    localUsers: users, installedVersions: baseline.versions)
                var valid = proof.value.trimmedThrough <= baseline.cut && proof.value.publishedThrough >= target
                for _ in 0..<4 where valid && plan.through < target {
                    let range = try await entry.store.replay(partitionID: request.source.partitionID, after: plan.through, limit: 128)
                    valid = plan.append(range, partitionID: request.source.partitionID)
                }
                let currentRevision = await registry.journalUserControlInterestRevision(partitionID: request.source.partitionID)
                valid = valid && plan.through == target && plan.selectedUsers.isSubset(of: users)
                    && deadline > .now && coordinator.confirmsJournalCoverage(coverage)
                    && currentRevision == selection.revision
                    && receiver.retainsRecoveryFloors(source: request.source, fence: request.fence, versions: baseline.versions.filter { users.contains($0.key) })
                if valid {
                    selected = requested.filter { plan.selectedUsers.contains($0.userID) }
                    effectiveControls = plan.controls
                    incrementalCut = target
                    if selected.isEmpty,
                       let liveCut = receiver.recoveryCheckpoint(source: request.source, fence: request.fence, minimumCut: 0),
                       receiver.renew(source: request.source, serviceID: serviceID, fence: request.fence,
                           deadline: deadline, current: { coordinator.confirmsJournalCoverage(coverage) }) {
                        let advance = V2RealtimeJournalProjectionBatch(source: request.source, fence: request.fence,
                            payload: .changes(fromExclusive: liveCut, throughInclusive: max(liveCut, target), entries: []))
                        if case .applied(let receipt) = receiver.applyJournalProjection(advance, authenticatedServiceID: serviceID) {
                            GatewayJournalRecoveryCoordinator.record(.replayAdvanced)
                            return .init(cut: receipt.appliedThrough, interestRevision: selection.revision,
                                versions: baseline.versions, devices: baseline.devices, controls: baseline.controls)
                        }
                    }
                    GatewayJournalRecoveryCoordinator.record(selected.isEmpty ? .replayAdvanced : .incrementalLoaded)
                } else {
                    GatewayJournalDiagnostics.fallback(.replayInvalid)
                    GatewayJournalRecoveryCoordinator.record(.replayFallback)
                }
            }
            if incrementalCut == nil { GatewayJournalRecoveryCoordinator.record(.snapshotLoaded) }
            var versions: [UserID: UInt64] = incrementalCut == nil ? [:] : baseline?.versions ?? [:]
            var userCut: Int64? = incrementalCut
            if !selected.isEmpty {
                // Connection order has no authorization semantics. Raw UUID
                // bytes give a stable order without formatting a String per comparison.
                let tickets = Array(selected).sorted { lhs, rhs in
                    withUnsafeBytes(of: lhs.connectionID.uuid) { left in
                        withUnsafeBytes(of: rhs.connectionID.uuid) { right in left.lexicographicallyPrecedes(right) }
                    }
                }
                for offset in stride(from: 0, to: tickets.count, by: 128) {
                    let selected = Set(tickets[offset..<min(offset + 128, tickets.count)])
                    GatewayJournalRecoveryCoordinator.record(.selectedConnections, amount: UInt64(selected.count))
                    let selectedUsers = Set(selected.map(\.userID))
                    let selectedDevices = Set(selected.compactMap { ticket -> V2RealtimeJournalDeviceKey? in
                        guard let user = ticket.userID.uuidValue, let device = ticket.deviceID.uuidValue else { return nil }
                        return .init(userID: user, deviceID: device)
                    })
                    let snapshotSpan = GatewayJournalDiagnostics.begin()
                    let witness: GatewayJournalSourceCatalog.UserSnapshotWitness
                    do {
                        defer { GatewayJournalDiagnostics.end(snapshotSpan, stage: .snapshot) }
                        witness = try await catalog.userSnapshot(source: request.source, userIDs: selectedUsers,
                            deviceIDs: Array(selectedDevices), minimumPublishedThrough: incrementalCut ?? minimumCut)
                    }
                    guard let cut = witness.snapshot.cuts.first(where: { $0.partitionID == request.source.partitionID })?.publishedThrough else {
                        throw V2RealtimeJournalError.corruptPersistenceState
                    }
                    if incrementalCut == nil { userCut = min(userCut ?? cut, cut) }
                    let applySpan = GatewayJournalDiagnostics.begin()
                    let applied = await registry.applyAuthoritativeUserControl(witness.snapshot,
                    source: request.source, expectedIdentity: entry.identity,
                    isAuthenticationSource: witness.isAuthenticationSource,
                    minimumControlVersions: effectiveControls.versions.filter { selectedUsers.contains($0.key) },
                    credentialChangedDeviceKeys: effectiveControls.devices.intersection(selectedDevices),
                    membershipChangedRooms: effectiveControls.membershipRooms.filter { selectedUsers.contains($0.key) },
                    membershipChangeVersions: effectiveControls.membershipVersions.filter { selectedUsers.contains($0.key) }, requested: selected,
                    requestedAt: requestedAt, deadline: deadline,
                    isCurrent: { coordinator.confirmsJournalCoverage(coverage) })
                    GatewayJournalDiagnostics.end(applySpan, stage: .applyUsers)
                    guard let applied else { throw GatewayJournalAuthorityError.userFloorRejected }
                    versions.merge(applied.versions) { max($0, $1) }
                }
            }
            // Empty user selection still proves the source cut without any
            // room head, permission or membership-grant query.
            if userCut == nil {
                guard proof.value.publishedThrough >= minimumCut else { throw V2RealtimeJournalError.authorityLost }
                userCut = proof.value.publishedThrough
            }
            let snapshot = V2RealtimeJournalProjectionBatch(source: request.source, fence: request.fence,
                payload: .snapshot(cut: userCut!, rooms: []))
            guard deadline > .now, coordinator.confirmsJournalCoverage(coverage) else { throw GatewayJournalAuthorityError.coverageChanged }
            let current = await registry.journalUserControlInterests(partitionID: request.source.partitionID)
            // Revocations/removals are covered by this read. A new lifecycle is
            // not, even when the user topic's routing generation stayed unchanged.
            guard current.interests.isSubset(of: requested) else { throw GatewayJournalAuthorityError.userSelectionChanged }
            let currentUsers = Set(current.interests.map(\.userID))
            try Task.checkCancellation()
            let installSpan = GatewayJournalDiagnostics.begin()
            defer { GatewayJournalDiagnostics.end(installSpan, stage: .install) }
            if incrementalCut != nil, let baseline {
                guard receiver.retainsRecoveryFloors(source: request.source, fence: request.fence,
                    versions: baseline.versions.filter { users.contains($0.key) }) else { throw GatewayJournalAuthorityError.userBindingRejected }
            }
            guard receiver.install(source: request.source, serviceID: serviceID, fence: request.fence,
                    deadline: deadline, rooms: [], viewers: [],
                    current: { coordinator.confirmsJournalCoverage(coverage) }) else { throw GatewayJournalAuthorityError.roomBindingRejected }
            guard receiver.installUserControlFloors(source: request.source, fence: request.fence,
                    versions: versions.filter { currentUsers.contains($0.key) },
                    isAuthenticationSource: entry.isAuthenticationSource) else { throw GatewayJournalAuthorityError.userBindingRejected }
            guard receiver.authorizeSnapshot(snapshot) else { throw GatewayJournalAuthorityError.snapshotRejected }
            guard case .applied = receiver.applyJournalProjection(snapshot, authenticatedServiceID: serviceID) else { throw GatewayJournalAuthorityError.snapshotNotApplied }
            return .init(cut: userCut!, interestRevision: current.revision, versions: versions,
                devices: Set(requested.compactMap { interest in
                    guard let user = interest.userID.uuidValue, let device = interest.deviceID.uuidValue else { return nil }
                    return V2RealtimeJournalDeviceKey(userID: user, deviceID: device)
                }).union(effectiveControls.devices), controls: effectiveControls)
    }

}
