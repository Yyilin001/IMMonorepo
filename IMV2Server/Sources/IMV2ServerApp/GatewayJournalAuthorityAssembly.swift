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
                receiver.recoveryCheckpoint(source: work.batch.source, fence: work.batch.fence,
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
                        controls: V2GatewayJournalRecoveryControls = .init()) async throws {
        guard let coverage = coordinator.journalCoverage(partitionID: source.partitionID) else {
            throw GatewayJournalAuthorityError.coverageChanged
        }
        let entry = try catalog.entry(logicalAlias: source.sourceID)
        guard entry.identity.databaseIncarnation == source.incarnationID,
              let lease = try await entry.store.currentPublisherLease(partitionID: source.partitionID),
              lease.identity == coverage.token.host, coordinator.confirmsJournalCoverage(coverage) else {
            throw GatewayJournalAuthorityError.sourceLeaseChanged
        }
        let fence = V2RealtimeJournalProjectionFence(publisherIncarnationID: lease.identity.incarnationID,
            sourceLeaseEpoch: lease.epoch, sourceLeaseToken: lease.token,
            sourceLeaseExpiresAt: Date().addingTimeInterval(lease.remainingLeaseSeconds),
            routingPartitionEpoch: coverage.token.epoch, routingLeaseToken: coverage.token.leaseToken,
            sessionID: coverage.sessionID, interestGeneration: coverage.revision,
            gatewayIncarnationID: gatewayIdentity.incarnationID)
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
            let lease = V2RealtimePartitionLease(partitionID: request.source.partitionID,
                identity: coverage.token.host, epoch: request.fence.sourceLeaseEpoch,
                token: request.fence.sourceLeaseToken, remainingLeaseSeconds: 0)
            let observedAt = ContinuousClock.now
            let confirmed = try await entry.store.confirm([lease])
            guard let authority = confirmed.first, confirmed.count == 1,
                  authority.epoch == lease.epoch, authority.token == lease.token,
                  authority.identity == lease.identity, coordinator.confirmsJournalCoverage(coverage) else {
                throw GatewayJournalAuthorityError.sourceLeaseChanged
            }
            let deadline = min(coverage.deadline, observedAt + .seconds(authority.remainingLeaseSeconds))
            guard deadline > .now else { throw GatewayJournalAuthorityError.sourceExpired }
            let requestedAt = ContinuousClock.now
            let selection = await registry.journalUserControlInterests(partitionID: request.source.partitionID)
            let requested = selection.interests
            let users = Set(requested.map(\.userID))
            guard Set(controls.versions.keys).isSubset(of: users) else { throw GatewayJournalAuthorityError.userSelectionChanged }
            if let baseline, baseline.interestRevision == selection.revision,
               receiver.renew(source: request.source, serviceID: serviceID, fence: request.fence,
                    deadline: deadline, current: { coordinator.confirmsJournalCoverage(coverage) }),
               var checkpoint = receiver.recoveryCheckpoint(source: request.source, fence: request.fence, minimumCut: 0) {
                // Bounded replay shares the same actual flight as cold reads.
                // It cannot race another baseline install for this generation.
                for _ in 0..<4 {
                    if checkpoint >= minimumCut {
                        GatewayJournalRecoveryCoordinator.record(.replayAdvanced)
                        return .init(cut: checkpoint, interestRevision: selection.revision,
                            versions: baseline.versions, devices: baseline.devices, controls: baseline.controls)
                    }
                    let range = try await entry.store.replay(partitionID: request.source.partitionID, after: checkpoint, limit: 128)
                    guard deadline > .now, coordinator.confirmsJournalCoverage(coverage),
                          await registry.journalUserControlInterestRevision(partitionID: request.source.partitionID) == selection.revision,
                          let advanced = GatewayJournalControlCatchUp.apply(range, after: checkpoint,
                            source: request.source, fence: request.fence, service: serviceID, localUsers: users, receiver: receiver),
                          advanced > checkpoint else { break }
                    checkpoint = advanced
                }
                if checkpoint >= minimumCut {
                    GatewayJournalRecoveryCoordinator.record(.replayAdvanced)
                    return .init(cut: checkpoint, interestRevision: selection.revision,
                        versions: baseline.versions, devices: baseline.devices, controls: baseline.controls)
                }
                GatewayJournalRecoveryCoordinator.record(.replayFallback)
            }
            GatewayJournalRecoveryCoordinator.record(.snapshotLoaded)
            var versions: [UserID: UInt64] = [:]
            var userCut: Int64?
            if !users.isEmpty {
                // Connection order has no authorization semantics. Raw UUID
                // bytes give a stable order without formatting a String per comparison.
                let tickets = Array(requested).sorted { lhs, rhs in
                    withUnsafeBytes(of: lhs.connectionID.uuid) { left in
                        withUnsafeBytes(of: rhs.connectionID.uuid) { right in left.lexicographicallyPrecedes(right) }
                    }
                }
                for offset in stride(from: 0, to: tickets.count, by: 128) {
                    let selected = Set(tickets[offset..<min(offset + 128, tickets.count)])
                    let selectedUsers = Set(selected.map(\.userID))
                    let selectedDevices = Set(selected.compactMap { ticket -> V2RealtimeJournalDeviceKey? in
                        guard let user = ticket.userID.uuidValue, let device = ticket.deviceID.uuidValue else { return nil }
                        return .init(userID: user, deviceID: device)
                    })
                    let witness = try await catalog.userSnapshot(source: request.source, userIDs: selectedUsers,
                        deviceIDs: Array(selectedDevices), minimumPublishedThrough: minimumCut)
                    guard let cut = witness.snapshot.cuts.first(where: { $0.partitionID == request.source.partitionID })?.publishedThrough else {
                        throw V2RealtimeJournalError.corruptPersistenceState
                    }
                    userCut = min(userCut ?? cut, cut)
                    guard let applied = await registry.applyAuthoritativeUserControl(witness.snapshot,
                    source: request.source, expectedIdentity: entry.identity,
                    isAuthenticationSource: witness.isAuthenticationSource,
                    minimumControlVersions: controls.versions.filter { selectedUsers.contains($0.key) },
                    credentialChangedDeviceKeys: controls.devices.intersection(selectedDevices),
                    membershipChangedRooms: controls.membershipRooms.filter { selectedUsers.contains($0.key) },
                    membershipChangeVersions: controls.membershipVersions.filter { selectedUsers.contains($0.key) }, requested: selected,
                    requestedAt: requestedAt, deadline: deadline,
                    isCurrent: { coordinator.confirmsJournalCoverage(coverage) }) else { throw GatewayJournalAuthorityError.userFloorRejected }
                    versions.merge(applied.versions) { max($0, $1) }
                }
            }
            // Empty user selection still proves the source cut without any
            // room head, permission or membership-grant query.
            if userCut == nil {
                let witness = try await catalog.userSnapshot(source: request.source, userIDs: [],
                    deviceIDs: [], minimumPublishedThrough: minimumCut)
                guard let cut = witness.snapshot.cuts.first(where: { $0.partitionID == request.source.partitionID })?.publishedThrough else {
                    throw V2RealtimeJournalError.corruptPersistenceState
                }
                userCut = cut
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
                }), controls: controls)
    }

}
