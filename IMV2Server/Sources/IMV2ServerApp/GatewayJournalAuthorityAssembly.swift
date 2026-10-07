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
    static func build(catalog: GatewayJournalSourceCatalog,
                      coordinator: V2RealtimeInterestCoordinator,
                      registry: V2DeviceConnectionRegistry,
                      receiver: V2GatewayJournalProjectionReceiver) -> V2GatewayJournalAuthorityIngress {
        let sourceCount = Set(catalog.logicalAliases.compactMap {
            try? catalog.entry(logicalAlias: $0).identity.sourceID
        }).count
        return V2GatewayJournalAuthorityIngress(receiver: receiver, maximumSources: max(1, sourceCount) * 256,
        recoverControls: { request, serviceID, minimumCut, controls in
            try await recover(catalog: catalog, coordinator: coordinator, registry: registry,
                receiver: receiver, request: request, serviceID: serviceID,
                minimumCut: minimumCut, controls: controls)
        }, recover: { _, _, _ in throw V2RealtimeJournalError.invalidInput },
        notify: { _ in })
    }
    static func refresh(catalog: GatewayJournalSourceCatalog,
                        coordinator: V2RealtimeInterestCoordinator,
                        registry: V2DeviceConnectionRegistry,
                        receiver: V2GatewayJournalProjectionReceiver,
                        source: V2RealtimeJournalSource,
                        gatewayIdentity: V2GatewayRealtimeIdentity,
                        minimumCut: Int64 = 0) async throws {
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
        try await recover(catalog: catalog, coordinator: coordinator, registry: registry,
            receiver: receiver, request: request,
            serviceID: coverage.token.host.serviceID, minimumCut: minimumCut,
            controls: .init())
    }

    private static func recover(catalog: GatewayJournalSourceCatalog,
                                coordinator: V2RealtimeInterestCoordinator,
                                registry: V2DeviceConnectionRegistry,
                                receiver: V2GatewayJournalProjectionReceiver,
                                request: V2RealtimeJournalProjectionBatch,
                                serviceID: String, minimumCut: Int64,
                                controls: V2GatewayJournalRecoveryControls) async throws {
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
            let requested = await registry.journalUserControlInterests().filter { interest in
                V2RealtimeTopicKey(kind: .userSync, id: interest.userID.rawValue).partitionID() == request.source.partitionID
            }
            let users = Set(requested.map(\.userID))
            guard Set(controls.versions.keys).isSubset(of: users) else { throw GatewayJournalAuthorityError.userSelectionChanged }
            var versions: [UserID: UInt64] = [:]
            var userCut: Int64?
            if !users.isEmpty {
                let tickets = Array(requested).sorted { $0.connectionID.uuidString < $1.connectionID.uuidString }
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
            guard receiver.install(source: request.source, serviceID: serviceID, fence: request.fence,
                    deadline: deadline, rooms: [], viewers: [],
                    current: { coordinator.confirmsJournalCoverage(coverage) }) else { throw GatewayJournalAuthorityError.roomBindingRejected }
            guard receiver.installUserControlFloors(source: request.source, fence: request.fence, versions: versions,
                    isAuthenticationSource: entry.isAuthenticationSource) else { throw GatewayJournalAuthorityError.userBindingRejected }
            guard receiver.authorizeSnapshot(snapshot) else { throw GatewayJournalAuthorityError.snapshotRejected }
            guard case .applied = receiver.applyJournalProjection(snapshot, authenticatedServiceID: serviceID) else { throw GatewayJournalAuthorityError.snapshotNotApplied }

    }

}
