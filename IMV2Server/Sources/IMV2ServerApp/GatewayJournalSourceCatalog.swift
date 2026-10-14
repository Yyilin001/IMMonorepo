import Foundation
import FluentKit
import IMV2Core
import IMV2ActorContracts
import IMV2ServerContracts
import IMV2ServerInfrastructure

/// Trusted configuration binds logical service-authorized shard aliases to a
/// physical database's persistent identity. Wire sourceID remains that logical
/// alias; the URL and process incarnation never become database identity.
struct GatewayJournalSourceCatalog: Sendable {
    struct Registration: Sendable {
        let logicalAliases: Set<String>
        let database: any Database
        let schema: String
        let isAuthenticationSource: Bool
        init(logicalAliases: Set<String>, database: any Database, schema: String = "im_v2", isAuthenticationSource: Bool = false) {
            self.logicalAliases = logicalAliases; self.database = database; self.schema = schema
            self.isAuthenticationSource = isAuthenticationSource
        }
    }
    struct Entry: Sendable {
        let logicalAlias: String
        let identity: V2RealtimeJournalSourceIdentity
        let store: PostgresV2RealtimeChangeJournalStore
        let isAuthenticationSource: Bool
    }
    enum CatalogError: Error, Equatable, Sendable {
        case invalidConfiguration, conflictingAlias, conflictingIdentity, unknownSource
        case identityChanged, invalidSnapshot, sourceNotReady
    }
    private let entries: [String: Entry]
    var logicalAliases: Set<String> { Set(entries.keys) }

    static func load(registrations: [Registration]) async throws -> Self {
        guard !registrations.isEmpty, registrations.count <= 256 else { throw CatalogError.invalidConfiguration }
        var entries: [String: Entry] = [:]
        var incarnations: [UUID: UUID] = [:]
        var authenticationIdentities: [V2RealtimeJournalSourceIdentity] = []
        for registration in registrations {
            guard !registration.logicalAliases.isEmpty, registration.logicalAliases.count <= 256,
                  registration.logicalAliases.allSatisfy({ alias in
                      alias.utf8.count <= 128 && alias.range(of: "^[A-Za-z0-9_.:-]+$", options: .regularExpression) != nil
                  }) else { throw CatalogError.invalidConfiguration }
            try await V2RealtimeJournalSchemaReadiness.verify(database: registration.database, schema: registration.schema)
            let store = try PostgresV2RealtimeChangeJournalStore(database: registration.database, schema: registration.schema)
            let identity = try await store.sourceIdentity()
            if registration.isAuthenticationSource { authenticationIdentities.append(identity) }
            if let previous = incarnations[identity.sourceID], previous != identity.databaseIncarnation {
                throw CatalogError.conflictingIdentity
            }
            incarnations[identity.sourceID] = identity.databaseIncarnation
            for alias in registration.logicalAliases {
                if let existing = entries[alias] {
                    guard existing.identity == identity else { throw CatalogError.conflictingAlias }
                } else { entries[alias] = Entry(logicalAlias: alias, identity: identity, store: store, isAuthenticationSource: registration.isAuthenticationSource) }
            }
        }
        guard entries.count <= 512 else { throw CatalogError.invalidConfiguration }
        // Authentication role is a trusted physical source property. A room
        // alias of the same schema cannot hide that schema's device authority.
        entries = entries.mapValues { entry in
            Entry(logicalAlias: entry.logicalAlias, identity: entry.identity, store: entry.store,
                  isAuthenticationSource: authenticationIdentities.contains(entry.identity))
        }
        return Self(entries: entries)
    }

    func entry(logicalAlias: String) throws -> Entry {
        guard let entry = entries[logicalAlias] else { throw CatalogError.unknownSource }
        return entry
    }
    /// One publisher registration per database/schema identity. Other aliases
    /// remain an explicit authorization mapping, never competing publishers.
    func canonicalAlias(for identity: V2RealtimeJournalSourceIdentity) throws -> String {
        guard let alias = entries.values.filter({ $0.identity == identity }).map(\.logicalAlias).sorted().first else {
            throw CatalogError.unknownSource
        }
        return alias
    }
    func authorizedAliases(for canonicalAlias: String) throws -> Set<String> {
        let identity = try entry(logicalAlias: canonicalAlias).identity
        guard try self.canonicalAlias(for: identity) == canonicalAlias else { throw CatalogError.invalidConfiguration }
        return Set(entries.values.filter { $0.identity == identity }.map(\.logicalAlias))
    }
    func source(logicalAlias: String, partitionID: Int) throws -> V2RealtimeJournalSource {
        guard (0..<256).contains(partitionID) else { throw CatalogError.invalidConfiguration }
        let entry = try entry(logicalAlias: logicalAlias)
        return .init(sourceID: logicalAlias, incarnationID: entry.identity.databaseIncarnation, partitionID: partitionID)
    }

    struct UserSnapshotWitness: Sendable {
        let snapshot: V2RealtimeJournalUserSnapshot
        /// Trusted local catalog role; never copied from an RPC body.
        let isAuthenticationSource: Bool
    }
    func userSnapshot(source: V2RealtimeJournalSource, userIDs: Set<UserID>, deviceIDs: [V2RealtimeJournalDeviceKey],
                      minimumPublishedThrough: Int64 = 0) async throws -> UserSnapshotWitness {
        let entry = try entry(logicalAlias: source.sourceID)
        guard source.incarnationID==entry.identity.databaseIncarnation, (0..<256).contains(source.partitionID) else {
            throw CatalogError.unknownSource
        }
        let users = try userIDs.map { user -> UUID in
            guard let uuid=user.uuidValue,
                  V2RealtimeTopicKey(kind: .userSync,id: uuid.uuidString.lowercased()).partitionID()==source.partitionID else {
                throw CatalogError.invalidConfiguration
            }
            return uuid
        }
        let snapshot = try await entry.store.userSnapshot(userIDs: users,deviceIDs: deviceIDs,
            partitionIDs: [source.partitionID],minimumPublishedThrough: [source.partitionID: minimumPublishedThrough])
        guard snapshot.identity==entry.identity else { throw CatalogError.identityChanged }
        return .init(snapshot: snapshot,isAuthenticationSource: entry.isAuthenticationSource)
    }

    struct SourceProof: Sendable {
        let identity: V2RealtimeJournalSourceIdentity
        let value: V2RealtimeJournalPartitionCut
        let lease: V2RealtimePartitionLease
        /// Conservative process-local deadline; never serialize as wall time.
        let validUntil: ContinuousClock.Instant
    }

    func sourceProofs(logicalAlias: String, partitionIDs: [Int]) async throws
        -> [Int: SourceProof] {
        let entry = try entry(logicalAlias: logicalAlias)
        let began = ContinuousClock.now
        GatewayJournalRecoveryCoordinator.record(.sourceProofQueries)
        GatewayJournalRecoveryCoordinator.record(.sourceProofPartitions, amount: UInt64(Set(partitionIDs).count))
        let proofs = try await entry.store.sourceProofs(partitionIDs: partitionIDs)
        var result: [Int: SourceProof] = [:]
        for proof in proofs {
            guard proof.identity == entry.identity else { throw CatalogError.identityChanged }
            let deadline = began + .seconds(proof.lease.remainingLeaseSeconds)
            if deadline > .now {
                result[proof.cut.partitionID] = .init(identity: proof.identity, value: proof.cut, lease: proof.lease, validUntil: deadline)
            }
        }
        return result
    }

}
