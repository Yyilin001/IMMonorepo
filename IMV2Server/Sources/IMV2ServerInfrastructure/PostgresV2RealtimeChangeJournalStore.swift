import Foundation
import FluentKit
import SQLKit
import IMV2ServerContracts
import IMV2ActorContracts

/// Partition fencing and the journal counter are locked before reading committed
/// outbox rows. No sequence is allocated until its source is visible here.
public struct PostgresV2RealtimeChangeJournalStore: V2RealtimeJournalProjectionStore, V2RealtimeRoomHeadChangeStore, V2RealtimeJournalUserSnapshotStore, V2RealtimeJournalConsumerStore, V2RealtimeJournalPublisherLeaseReading, V2RealtimeRoomHeadAntiEntropyStore {
    private let database: any Database
    private let schema: String
    public init(database: any Database, schema: String = "im_v2") throws {
        guard schema.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else {
            throw V2RealtimeJournalError.invalidInput
        }
        self.database = database; self.schema = schema
    }

    public func currentPublisherLease(partitionID: Int) async throws -> V2RealtimePartitionLease? {
        try validate(partitionID: partitionID, after: 0, limit: 1)
        struct Current: Decodable {
            let partition_id: Int
            let host_id: String
            let service_id: String
            let process_incarnation: UUID
            let lease_epoch: Int64
            let lease_token: UUID
            let remaining_seconds: Double
        }
        guard let row = try await sqlDatabase(database).raw("""
            WITH observed AS MATERIALIZED(SELECT clock_timestamp() AS now)
            SELECT l.partition_id,l.host_id,l.service_id,l.process_incarnation,l.lease_epoch,l.lease_token,
                   extract(epoch FROM l.expires_at-observed.now)::double precision AS remaining_seconds
            FROM \(unsafeRaw: schema).realtime_journal_publisher_leases l CROSS JOIN observed
            WHERE l.partition_id=\(bind: partitionID) AND l.lease_epoch>0 AND l.expires_at>observed.now
            """).first(decoding: Current.self) else { return nil }
        guard row.remaining_seconds.isFinite, row.remaining_seconds>0, row.lease_epoch>0 else {
            throw V2RealtimeJournalError.corruptPersistenceState
        }
        return .init(partitionID: row.partition_id,
            identity: .init(nodeID: row.host_id,serviceID: row.service_id,incarnationID: row.process_incarnation),
            epoch: row.lease_epoch,token: row.lease_token,remainingLeaseSeconds: row.remaining_seconds)
    }

    public struct SourceProof: Sendable {
        public let identity: V2RealtimeJournalSourceIdentity
        public let lease: V2RealtimePartitionLease
        public let cut: V2RealtimeJournalPartitionCut
    }

    /// One statement snapshot covers identity, publisher generation and cuts.
    /// No user/device state, JSON tree, explicit transaction or row lock.
    public func sourceProofs(partitionIDs: [Int]) async throws -> [SourceProof] {
        guard partitionIDs.count <= 256, partitionIDs.allSatisfy({ (0..<256).contains($0) }) else {
            throw V2RealtimeJournalError.invalidInput
        }
        guard !partitionIDs.isEmpty else { return [] }
        struct Row: Decodable {
            let source_id: UUID
            let database_incarnation: UUID
            let partition_id: Int
            let published_through: Int64
            let trimmed_through: Int64
            let host_id: String
            let service_id: String
            let process_incarnation: UUID
            let lease_epoch: Int64
            let lease_token: UUID
            let remaining_seconds: Double
        }
        let rows = try await sqlDatabase(database).raw("""
            WITH observed AS MATERIALIZED(SELECT clock_timestamp() AS now)
            SELECT i.source_id,i.database_incarnation,p.partition_id,p.published_through,p.trimmed_through,
                   l.host_id,l.service_id,l.process_incarnation,l.lease_epoch,l.lease_token,
                   extract(epoch FROM l.expires_at-observed.now)::double precision AS remaining_seconds
            FROM \(unsafeRaw: schema).realtime_journal_source_identity i
            CROSS JOIN observed
            JOIN \(unsafeRaw: schema).realtime_journal_partitions p ON p.partition_id=ANY(\(bind: partitionIDs)::integer[])
            JOIN \(unsafeRaw: schema).realtime_journal_publisher_leases l ON l.partition_id=p.partition_id
            WHERE i.singleton AND l.lease_epoch>0 AND l.expires_at>observed.now
            """).all(decoding: Row.self)
        return try rows.map { row in
            guard row.remaining_seconds.isFinite, row.remaining_seconds > 0,
                  row.published_through >= 0, row.trimmed_through >= 0,
                  row.trimmed_through <= row.published_through else {
                throw V2RealtimeJournalError.corruptPersistenceState
            }
            return .init(identity: .init(sourceID: row.source_id, databaseIncarnation: row.database_incarnation),
                lease: .init(partitionID: row.partition_id,
                    identity: .init(nodeID: row.host_id, serviceID: row.service_id, incarnationID: row.process_incarnation),
                    epoch: row.lease_epoch, token: row.lease_token, remainingLeaseSeconds: row.remaining_seconds),
                cut: .init(partitionID: row.partition_id, publishedThrough: row.published_through, trimmedThrough: row.trimmed_through))
        }
    }

    public func roomHeadSnapshot(roomIDs: [UUID], partitionID: Int) async throws -> V2RealtimeRoomHeadSnapshot {
        guard roomIDs.count <= 256, (0..<256).contains(partitionID),
              roomIDs.allSatisfy({ V2RealtimeTopicKey(kind: .roomEvents, id: $0.uuidString.lowercased()).partitionID() == partitionID }) else {
            throw V2RealtimeJournalError.invalidInput
        }
        // Reuse the authoritative RR read without any viewer/device lookup.
        // Read rooms.room_sequence even when the dirty marker was already ACKed.
        let snapshot = try await projectionSnapshot(roomIDs: roomIDs, viewerKeys: [], partitionIDs: [partitionID])
        guard let cut = snapshot.cuts.first, snapshot.cuts.count == 1,
              Set(snapshot.rooms.map(\.roomID)) == Set(roomIDs) else { throw V2RealtimeJournalError.corruptPersistenceState }
        return .init(identity: snapshot.identity, partitionID: partitionID, cut: cut, rooms: snapshot.rooms)
    }

    public func sourceIdentity() async throws -> V2RealtimeJournalSourceIdentity {
        guard let row = try await sqlDatabase(database).raw("""
            SELECT jsonb_build_object('sourceID',source_id,'databaseIncarnation',database_incarnation)::text AS payload
            FROM \(unsafeRaw: schema).realtime_journal_source_identity WHERE singleton
            """).first(decoding: Payload.self) else { throw V2RealtimeJournalError.corruptPersistenceState }
        return try JSONDecoder().decode(V2RealtimeJournalSourceIdentity.self, from: Data(row.payload.utf8))
    }

    public func projectionSnapshot(roomIDs: [UUID], viewerKeys: [V2RealtimeJournalViewerKey], partitionIDs: [Int],
                                   minimumPublishedThrough: [Int: Int64] = [:]) async throws -> V2RealtimeJournalProjectionSnapshot {
        guard roomIDs.count <= 256, viewerKeys.count <= 4096, partitionIDs.count <= 256,
              partitionIDs.allSatisfy({ (0..<256).contains($0) }),
              minimumPublishedThrough.allSatisfy({ partitionIDs.contains($0.key) && $0.value >= 0 }),
              viewerKeys.allSatisfy({ roomIDs.contains($0.roomID) }) else { throw V2RealtimeJournalError.invalidInput }
        let roomJSON = String(decoding: try JSONEncoder().encode(Array(Set(roomIDs))), as: UTF8.self)
        let viewerJSON = String(decoding: try JSONEncoder().encode(Array(Set(viewerKeys))), as: UTF8.self)
        let partitionJSON = String(decoding: try JSONEncoder().encode(Array(Set(partitionIDs))), as: UTF8.self)
        // This is a read-only transaction. Set its isolation before any SELECT;
        // the generic write retry helper may itself SELECT clock/timeout state.
        return try await database.transaction { db in
            let sql = try sqlDatabase(db)
            try await sql.raw("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY").run()
            try await sql.raw("SET LOCAL statement_timeout = '5000ms'").run()
            guard let row = try await sql.raw("""
                WITH requested_rooms AS (
                    SELECT value::uuid AS room_id FROM jsonb_array_elements_text(\(bind: roomJSON)::jsonb)
                ), requested_viewers AS (
                    SELECT "roomID" AS room_id,"userID" AS user_id
                    FROM jsonb_to_recordset(\(bind: viewerJSON)::jsonb) AS v("roomID" uuid,"userID" uuid)
                ), room_state AS (
                    SELECT q.room_id,coalesce(r.room_sequence,0) AS room_sequence,
                           coalesce(r.owner_epoch,0) AS owner_epoch,r.membership_revision,r.frozen_at,
                           r.room_id IS NOT NULL AS is_present,coalesce(v.version,0) AS control_version
                    FROM requested_rooms q LEFT JOIN \(unsafeRaw: schema).rooms r USING(room_id)
                    LEFT JOIN \(unsafeRaw: schema).realtime_control_versions v
                        ON v.topic_kind='roomEvents' AND v.topic_id=q.room_id::text
                )
                SELECT jsonb_build_object(
                    'identity',jsonb_build_object('sourceID',i.source_id,'databaseIncarnation',i.database_incarnation),
                    'cuts',coalesce((SELECT jsonb_agg(jsonb_build_object(
                        'partitionID',p.partition_id,'publishedThrough',p.published_through,'trimmedThrough',p.trimmed_through)
                        ORDER BY p.partition_id)
                        FROM \(unsafeRaw: schema).realtime_journal_partitions p
                        WHERE p.partition_id IN(SELECT value::integer FROM jsonb_array_elements_text(\(bind: partitionJSON)::jsonb))),'[]'::jsonb),
                    'rooms',coalesce((SELECT jsonb_agg(jsonb_build_object(
                        'roomID',room_id,'roomSequence',room_sequence,'ownerEpoch',owner_epoch,
                        'roomControlVersion',control_version,'frozen',frozen_at IS NOT NULL,'exists',is_present) ORDER BY room_id)
                        FROM room_state),'[]'::jsonb),
                    'viewers',coalesce((SELECT jsonb_agg(jsonb_build_object(
                        'roomID',q.room_id,'userID',q.user_id,
                        'active',coalesce(m.joined_revision<=r.membership_revision
                            AND(m.left_revision IS NULL OR m.left_revision>r.membership_revision),false),
                        'joinedRevision',m.joined_revision,'role',m.role,
                        'roomControlVersion',coalesce(r.control_version,0)) ORDER BY q.room_id,q.user_id)
                        FROM requested_viewers q LEFT JOIN room_state r USING(room_id)
                        LEFT JOIN \(unsafeRaw: schema).room_memberships m ON m.room_id=q.room_id AND m.user_id=q.user_id),'[]'::jsonb)
                )::text AS payload
                FROM \(unsafeRaw: schema).realtime_journal_source_identity i WHERE singleton
                """).first(decoding: Payload.self) else { throw V2RealtimeJournalError.corruptPersistenceState }
            let result = try JSONDecoder().decode(V2RealtimeJournalProjectionSnapshot.self, from: Data(row.payload.utf8))
            guard result.cuts.count == Set(partitionIDs).count,
                  minimumPublishedThrough.allSatisfy({ minimum in
                      result.cuts.contains { $0.partitionID == minimum.key && $0.publishedThrough >= minimum.value }
                  }) else { throw V2RealtimeJournalError.corruptPersistenceState }
            return result
        }
    }

    public func userSnapshot(userIDs: [UUID], deviceIDs: [V2RealtimeJournalDeviceKey], partitionIDs: [Int],
                             minimumPublishedThrough: [Int: Int64] = [:]) async throws -> V2RealtimeJournalUserSnapshot {
        guard userIDs.count <= 256, deviceIDs.count <= 4096, partitionIDs.count <= 256,
              partitionIDs.allSatisfy({ (0..<256).contains($0) }),
              deviceIDs.allSatisfy({ userIDs.contains($0.userID) }),
              minimumPublishedThrough.allSatisfy({ partitionIDs.contains($0.key) && $0.value >= 0 }) else {
            throw V2RealtimeJournalError.invalidInput
        }
        let users = Array(Set(userIDs)).sorted { $0.uuidString < $1.uuidString }
        let devices = Array(Set(deviceIDs))
        let userJSON = String(decoding: try JSONEncoder().encode(users), as: UTF8.self)
        let deviceJSON = String(decoding: try JSONEncoder().encode(devices), as: UTF8.self)
        let partitionJSON = String(decoding: try JSONEncoder().encode(Array(Set(partitionIDs))), as: UTF8.self)
        return try await database.transaction { db in
            let sql = try sqlDatabase(db)
            try await sql.raw("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY").run()
            try await sql.raw("SET LOCAL statement_timeout = '5000ms'").run()
            guard let row = try await sql.raw("""
                WITH requested_users AS (
                    SELECT value::uuid AS user_id FROM jsonb_array_elements_text(\(bind: userJSON)::jsonb)
                ), requested_devices AS (
                    SELECT "userID" AS user_id,"deviceID" AS device_id
                    FROM jsonb_to_recordset(\(bind: deviceJSON)::jsonb) d("userID" uuid,"deviceID" uuid)
                ), observed AS MATERIALIZED (SELECT clock_timestamp() AS now)
                SELECT jsonb_build_object(
                    'identity',jsonb_build_object('sourceID',i.source_id,'databaseIncarnation',i.database_incarnation),
                    'observedAt',extract(epoch FROM observed.now),
                    'requestedUserIDs',\(bind: userJSON)::jsonb,'requestedDeviceKeys',\(bind: deviceJSON)::jsonb,
                    'cuts',coalesce((SELECT jsonb_agg(jsonb_build_object('partitionID',p.partition_id,
                        'publishedThrough',p.published_through,'trimmedThrough',p.trimmed_through) ORDER BY p.partition_id)
                        FROM \(unsafeRaw: schema).realtime_journal_partitions p WHERE p.partition_id IN(
                            SELECT value::integer FROM jsonb_array_elements_text(\(bind: partitionJSON)::jsonb))),'[]'::jsonb),
                    'users',coalesce((SELECT jsonb_agg(jsonb_build_object('userID',q.user_id,
                        'controlVersion',coalesce(v.version,0),
                        'membershipDiscoveryVersion',coalesce(v.membership_discovery_version,0),
                        'sessionControlVersion',coalesce(v.session_control_version,0)) ORDER BY q.user_id)
                        FROM requested_users q LEFT JOIN \(unsafeRaw: schema).realtime_control_versions v
                          ON v.topic_kind='userSync' AND v.topic_id=q.user_id::text),'[]'::jsonb),
                    'devices',coalesce((SELECT jsonb_agg(jsonb_build_object('userID',q.user_id,'deviceID',q.device_id,
                        'latestChangeVersion',coalesce(v.latest_change_version,0)) ORDER BY q.user_id,q.device_id)
                        FROM requested_devices q
                        LEFT JOIN \(unsafeRaw: schema).realtime_device_control_versions v
                          ON v.user_id=q.user_id AND v.device_id=q.device_id),'[]'::jsonb)
                )::text AS payload FROM \(unsafeRaw: schema).realtime_journal_source_identity i CROSS JOIN observed
                WHERE i.singleton
                """).first(decoding: Payload.self) else { throw V2RealtimeJournalError.corruptPersistenceState }
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
            let snapshot = try decoder.decode(V2RealtimeJournalUserSnapshot.self, from: Data(row.payload.utf8))
            guard Set(snapshot.requestedUserIDs) == Set(users), snapshot.users.count == users.count,
                  Set(snapshot.users.map(\.userID)) == Set(users), snapshot.devices.count == devices.count,
                  Set(snapshot.devices.map { V2RealtimeJournalDeviceKey(userID: $0.userID, deviceID: $0.deviceID) }) == Set(devices),
                  snapshot.cuts.count == Set(partitionIDs).count,
                  minimumPublishedThrough.allSatisfy({ minimum in snapshot.cuts.contains {
                      $0.partitionID == minimum.key && $0.publishedThrough >= minimum.value
                  } }) else { throw V2RealtimeJournalError.corruptPersistenceState }
            return snapshot
        }
    }

    private struct StoredConsumer: Decodable {
        let registration: V2RealtimeJournalConsumerRegistration
        let controlCursor: Int64
        let offeredThrough: Int64
    }
    private var consumerRecordSQL: String {
        """
        jsonb_build_object('registration',jsonb_build_object(
          'key',jsonb_build_object('gateway',jsonb_build_object('nodeID',c.gateway_node,'serviceID',c.gateway_service,
              'incarnationID',c.gateway_incarnation),'sessionID',c.session_id,'sessionRevision',c.session_revision),
          'sessionGeneration',c.session_generation,'partitionID',c.partition_id,'roomIDs',to_jsonb(c.room_ids),'userIDs',to_jsonb(c.user_ids),
          'routingEpoch',c.routing_epoch,'routingToken',c.routing_token,
          'coverageExpiresAt',extract(epoch FROM c.coverage_expires_at),'initialControlCursor',0),
          'controlCursor',c.control_cursor,'offeredThrough',c.offered_through)
        """
    }
    private func decodeConsumer(_ payload: Payload) throws -> StoredConsumer {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(StoredConsumer.self, from: Data(payload.payload.utf8))
    }
    private func consumerRecord(_ sql: any SQLDatabase, partitionID: Int, key: V2RealtimeJournalConsumerKey,
                                activeOnly: Bool = true) async throws -> StoredConsumer? {
        guard let row = try await sql.raw("""
            SELECT \(unsafeRaw: consumerRecordSQL)::text AS payload FROM \(unsafeRaw: schema).realtime_journal_consumers c
            WHERE c.partition_id=\(bind: partitionID) AND c.gateway_incarnation=\(bind: key.gateway.incarnationID)
              AND c.gateway_node=\(bind: key.gateway.nodeID) AND c.gateway_service=\(bind: key.gateway.serviceID)
              AND c.session_id=\(bind: key.sessionID) AND c.session_revision=\(bind: key.sessionRevision)
              AND (NOT \(bind: activeOnly) OR c.coverage_expires_at>clock_timestamp()) FOR UPDATE
            """).first(decoding: Payload.self) else { return nil }
        return try decodeConsumer(row)
    }
    public func pendingConsumerPartitions(partitionIDs: [Int], limit: Int) async throws -> [Int] {
        guard partitionIDs.count<=256, partitionIDs.allSatisfy({ (0..<256).contains($0) }),
              (1...256).contains(limit) else { throw V2RealtimeJournalError.invalidInput }
        guard !partitionIDs.isEmpty else { return [] }
        let ids = String(decoding: try JSONEncoder().encode(Array(Set(partitionIDs))), as: UTF8.self)
        struct Pending: Decodable { let partition_id: Int }
        return try await sqlDatabase(database).raw("""
            SELECT DISTINCT partition_id FROM (
                SELECT partition_id FROM \(unsafeRaw: schema).realtime_journal_consumers
                  WHERE offered_through>control_cursor
                UNION ALL
                SELECT h.partition_id FROM \(unsafeRaw: schema).realtime_journal_consumer_heads h
                  JOIN \(unsafeRaw: schema).realtime_journal_consumers c USING(partition_id,gateway_incarnation)

            ) pending WHERE partition_id IN(SELECT value::integer FROM jsonb_array_elements_text(\(bind: ids)::jsonb))
            ORDER BY partition_id LIMIT \(bind: limit)
            """).all(decoding: Pending.self).map(\.partition_id)
    }
    public func registerConsumer(lease: V2RealtimePartitionLease, registration: V2RealtimeJournalConsumerRegistration) async throws {
        try validate(partitionID: lease.partitionID, after: 0, limit: 1)
        let key = registration.key
        guard registration.partitionID==lease.partitionID, key.sessionRevision>0, registration.sessionGeneration>0, registration.routingEpoch>0,
              !key.gateway.nodeID.isEmpty, key.gateway.nodeID.utf8.count<=128,
              !key.gateway.serviceID.isEmpty, key.gateway.serviceID.utf8.count<=128,
              registration.roomIDs.count<=4096, registration.userIDs.count<=4096,
              Set(registration.roomIDs).count==registration.roomIDs.count,
              Set(registration.userIDs).count==registration.userIDs.count,
              registration.initialControlCursor==0, v2PostgresTimestampCanEncode(registration.coverageExpiresAt) else {
            throw V2RealtimeJournalError.invalidInput
        }
        let rooms = String(decoding: try JSONEncoder().encode(registration.roomIDs), as: UTF8.self)
        let users = String(decoding: try JSONEncoder().encode(registration.userIDs), as: UTF8.self)
        try await transaction { db in
            let sql = try sqlDatabase(db)
            try await fence(sql, lease: lease)
            struct Existing: Decodable { let session_revision: Int64; let session_generation: Int64; let session_id: UUID; let routing_epoch: Int64; let routing_token: UUID }
            let existing = try await sql.raw("""
                SELECT session_revision,session_generation,session_id,routing_epoch,routing_token
                FROM \(unsafeRaw: schema).realtime_journal_consumers
                WHERE partition_id=\(bind: lease.partitionID) AND gateway_incarnation=\(bind: key.gateway.incarnationID) FOR UPDATE
                """).first(decoding: Existing.self)
            let same = existing.map { $0.session_generation==registration.sessionGeneration && $0.session_revision==key.sessionRevision && $0.session_id==key.sessionID
                && $0.routing_epoch==registration.routingEpoch && $0.routing_token==registration.routingToken } ?? false
            if let old = existing, !same {
                let newerSession = registration.sessionGeneration>old.session_generation && key.sessionID != old.session_id
                let newerRevision = registration.sessionGeneration==old.session_generation
                    && key.sessionID==old.session_id && key.sessionRevision>old.session_revision
                guard newerSession || newerRevision else { throw V2RealtimeJournalError.invalidInput }
            }
            if same {
                guard let old = try await consumerRecord(sql, partitionID: lease.partitionID, key: key, activeOnly: false),
                      Set(old.registration.roomIDs)==Set(registration.roomIDs), Set(old.registration.userIDs)==Set(registration.userIDs) else {
                    throw V2RealtimeJournalError.invalidInput
                }
            } else {
                // A new exact interest generation starts at zero; only actual
                // authoritative snapshot/application receipts can advance it.
                try await sql.raw("DELETE FROM \(unsafeRaw: schema).realtime_journal_consumers WHERE partition_id=\(bind: lease.partitionID) AND gateway_incarnation=\(bind: key.gateway.incarnationID)").run()
            }
            let inserted = try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).realtime_journal_consumers
                  (partition_id,gateway_incarnation,gateway_node,gateway_service,session_id,session_generation,session_revision,
                   routing_epoch,routing_token,coverage_expires_at,room_ids,user_ids,control_cursor,offered_through)
                SELECT \(bind: lease.partitionID),\(bind: key.gateway.incarnationID),\(bind: key.gateway.nodeID),\(bind: key.gateway.serviceID),
                       \(bind: key.sessionID),\(bind: registration.sessionGeneration),\(bind: key.sessionRevision),\(bind: registration.routingEpoch),\(bind: registration.routingToken),
                       \(bind: registration.coverageExpiresAt),
                       ARRAY(SELECT value::uuid FROM jsonb_array_elements_text(\(bind: rooms)::jsonb)),
                       ARRAY(SELECT value::uuid FROM jsonb_array_elements_text(\(bind: users)::jsonb)),0,p.published_through
                FROM \(unsafeRaw: schema).realtime_journal_partitions p WHERE p.partition_id=\(bind: lease.partitionID)
                  AND \(bind: registration.coverageExpiresAt)>clock_timestamp()
                  AND \(bind: registration.coverageExpiresAt)<=clock_timestamp()+interval '120 seconds'
                ON CONFLICT(partition_id,gateway_incarnation) DO UPDATE SET coverage_expires_at=EXCLUDED.coverage_expires_at
                RETURNING gateway_incarnation
                """).all()
            guard inserted.count==1 else { throw V2RealtimeJournalError.invalidInput }
            if !same {
            // Late registration also seeds latest H that was already acknowledged
            // at the source, so no subscriber can miss a prior handoff.
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).realtime_journal_consumer_heads
                  (partition_id,gateway_incarnation,room_id,room_sequence,owner_epoch,room_control_version,revision)
                SELECT h.partition_id,\(bind: key.gateway.incarnationID),h.room_id,h.room_sequence,h.owner_epoch,h.room_control_version,h.revision
                FROM \(unsafeRaw: schema).realtime_dirty_room_heads h
                WHERE h.partition_id=\(bind: lease.partitionID)
                  AND h.room_id IN(SELECT value::uuid FROM jsonb_array_elements_text(\(bind: rooms)::jsonb))
                ON CONFLICT(partition_id,gateway_incarnation,room_id) DO NOTHING
                """).run()
            }
            try await fence(sql, lease: lease)
        }
    }
    public func registeredConsumers(lease: V2RealtimePartitionLease, afterGatewayIncarnation: UUID?, limit: Int) async throws -> [V2RealtimeJournalConsumerRegistration] {
        guard (1...128).contains(limit) else { throw V2RealtimeJournalError.invalidInput }
        return try await transaction { db in
            let sql = try sqlDatabase(db); try await fence(sql, lease: lease)
            let rows: [Payload]
            if let after = afterGatewayIncarnation {
                rows = try await sql.raw("""
                    SELECT \(unsafeRaw: consumerRecordSQL)::text AS payload FROM \(unsafeRaw: schema).realtime_journal_consumers c
                    WHERE c.partition_id=\(bind: lease.partitionID)
                      AND c.gateway_incarnation>\(bind: after) ORDER BY c.gateway_incarnation LIMIT \(bind: limit)
                    """).all(decoding: Payload.self)
            } else {
                rows = try await sql.raw("""
                    SELECT \(unsafeRaw: consumerRecordSQL)::text AS payload FROM \(unsafeRaw: schema).realtime_journal_consumers c
                    WHERE c.partition_id=\(bind: lease.partitionID)
                    ORDER BY c.gateway_incarnation LIMIT \(bind: limit)
                    """).all(decoding: Payload.self)
            }
            try await fence(sql, lease: lease)
            return try rows.map { try decodeConsumer($0).registration }
        }
    }
    public func handoffToConsumers(lease: V2RealtimePartitionLease, throughControlSequence: Int64,
                                   heads: [V2RealtimeRoomHeadChange]) async throws {
        try validate(partitionID: lease.partitionID, after: throughControlSequence, limit: 1)
        guard heads.count<=128, Set(heads.map(\.roomID)).count==heads.count,
              heads.allSatisfy({ $0.partitionID==lease.partitionID && $0.revision>0 && $0.roomSequence>=0
                && $0.ownerEpoch>=0 && $0.roomControlVersion>=0 }) else { throw V2RealtimeJournalError.invalidInput }
        let json = String(decoding: try JSONEncoder().encode(heads), as: UTF8.self)
        try await transaction { db in
            let sql = try sqlDatabase(db); try await fence(sql, lease: lease)
            let allowed = try await sql.raw("SELECT partition_id FROM \(unsafeRaw: schema).realtime_journal_partitions WHERE partition_id=\(bind: lease.partitionID) AND published_through>=\(bind: throughControlSequence)").all()
            guard allowed.count==1 else { throw V2RealtimeJournalError.invalidInput }
            // Expired-but-not-retired consumers still retain responsibility. This
            // keeps a renewed exact generation replayable and blocks unsafe trim.
            try await sql.raw("""
                UPDATE \(unsafeRaw: schema).realtime_journal_consumers SET offered_through=greatest(offered_through,\(bind: throughControlSequence))
                WHERE partition_id=\(bind: lease.partitionID)
                """).run()
            try await sql.raw("""
                INSERT INTO \(unsafeRaw: schema).realtime_journal_consumer_heads
                  (partition_id,gateway_incarnation,room_id,room_sequence,owner_epoch,room_control_version,revision)
                SELECT c.partition_id,c.gateway_incarnation,h."roomID",h."roomSequence",h."ownerEpoch",h."roomControlVersion",h.revision
                FROM \(unsafeRaw: schema).realtime_journal_consumers c
                CROSS JOIN jsonb_to_recordset(\(bind: json)::jsonb) h("roomID" uuid,"roomSequence" bigint,"ownerEpoch" bigint,"roomControlVersion" bigint,revision bigint)
                WHERE c.partition_id=\(bind: lease.partitionID) AND h."roomID"=ANY(c.room_ids)
                ON CONFLICT(partition_id,gateway_incarnation,room_id) DO UPDATE
                  SET room_sequence=greatest(\(unsafeRaw: schema).realtime_journal_consumer_heads.room_sequence,EXCLUDED.room_sequence),
                      owner_epoch=EXCLUDED.owner_epoch,room_control_version=EXCLUDED.room_control_version,revision=EXCLUDED.revision
                  WHERE \(unsafeRaw: schema).realtime_journal_consumer_heads.revision<EXCLUDED.revision
                """).run()
            try await sql.raw("""
                UPDATE \(unsafeRaw: schema).realtime_dirty_room_heads h SET pending=false
                FROM jsonb_to_recordset(\(bind: json)::jsonb) ack("roomID" uuid,"roomSequence" bigint,"ownerEpoch" bigint,"roomControlVersion" bigint,revision bigint)
                WHERE h.partition_id=\(bind: lease.partitionID) AND h.room_id=ack."roomID"
                  AND h.revision=ack.revision AND h.room_sequence=ack."roomSequence"
                  AND h.owner_epoch=ack."ownerEpoch" AND h.room_control_version=ack."roomControlVersion"
                """).run()
            try await fence(sql, lease: lease)
        }
    }
    public func consumerBatch(lease: V2RealtimePartitionLease, consumer: V2RealtimeJournalConsumerKey,
                              limit: Int) async throws -> V2RealtimeJournalConsumerBatch {
        guard (1...128).contains(limit) else { throw V2RealtimeJournalError.invalidInput }
        return try await transaction { db in
            let sql = try sqlDatabase(db); try await fence(sql, lease: lease)
            guard let record = try await consumerRecord(sql, partitionID: lease.partitionID, key: consumer) else {
                throw V2RealtimeJournalError.authorityLost
            }
            let replay = try await read(sql, partitionID: lease.partitionID, after: record.controlCursor, limit: limit)
            let offered = min(record.offeredThrough,replay.publishedThrough)
            let journal = V2RealtimeJournalBatch(partitionID: lease.partitionID, publishedThrough: offered,
                trimmedThrough: replay.trimmedThrough, requiresSnapshot: replay.requiresSnapshot,
                entries: replay.entries.filter { $0.sequence<=offered })
            guard let payload = try await sql.raw("""
                SELECT coalesce(jsonb_agg(jsonb_build_object('partitionID',h.partition_id,'roomID',h.room_id,
                    'roomSequence',h.room_sequence,'ownerEpoch',h.owner_epoch,'roomControlVersion',h.room_control_version,
                    'revision',h.revision) ORDER BY h.room_id),'[]'::jsonb)::text AS payload
                FROM (SELECT * FROM \(unsafeRaw: schema).realtime_journal_consumer_heads
                    WHERE partition_id=\(bind: lease.partitionID) AND gateway_incarnation=\(bind: consumer.gateway.incarnationID)
                    ORDER BY room_id LIMIT \(bind: limit)) h
                """).first(decoding: Payload.self) else { throw V2RealtimeJournalError.corruptPersistenceState }
            let heads = try JSONDecoder().decode([V2RealtimeRoomHeadChange].self, from: Data(payload.payload.utf8))
            try await fence(sql, lease: lease)
            return .init(registration: record.registration, controlCursor: record.controlCursor,
                offeredThrough: offered, journal: journal, heads: heads)
        }
    }
    public func acknowledgeConsumer(lease: V2RealtimePartitionLease, consumer: V2RealtimeJournalConsumerKey,
                                    expectedControlCursor: Int64, appliedThrough: Int64,
                                    heads: [V2RealtimeRoomHeadChange]) async throws -> Bool {
        guard expectedControlCursor>=0, appliedThrough>=expectedControlCursor, heads.count<=128,
              Set(heads.map(\.roomID)).count==heads.count,
              heads.allSatisfy({ $0.partitionID==lease.partitionID && $0.revision>0 }) else { throw V2RealtimeJournalError.invalidInput }
        let json = String(decoding: try JSONEncoder().encode(heads), as: UTF8.self)
        return try await transaction { db in
            let sql = try sqlDatabase(db); try await fence(sql, lease: lease)
            guard let record = try await consumerRecord(sql, partitionID: lease.partitionID, key: consumer),
                  record.controlCursor==expectedControlCursor else { return false }
            let updated = try await sql.raw("""
                UPDATE \(unsafeRaw: schema).realtime_journal_consumers c
                SET control_cursor=\(bind: appliedThrough),offered_through=greatest(c.offered_through,\(bind: appliedThrough))
                FROM \(unsafeRaw: schema).realtime_journal_partitions p
                WHERE c.partition_id=\(bind: lease.partitionID) AND c.gateway_incarnation=\(bind: consumer.gateway.incarnationID)
                  AND c.control_cursor=\(bind: expectedControlCursor) AND p.partition_id=c.partition_id
                  AND p.published_through>=\(bind: appliedThrough)
                RETURNING c.gateway_incarnation
                """).all()
            guard updated.count==1 else { throw V2RealtimeJournalError.invalidInput }
            try await sql.raw("""
                DELETE FROM \(unsafeRaw: schema).realtime_journal_consumer_heads h
                USING jsonb_to_recordset(\(bind: json)::jsonb) ack("roomID" uuid,"roomSequence" bigint,"ownerEpoch" bigint,"roomControlVersion" bigint,revision bigint)
                WHERE h.partition_id=\(bind: lease.partitionID) AND h.gateway_incarnation=\(bind: consumer.gateway.incarnationID)
                  AND h.room_id=ack."roomID" AND h.revision=ack.revision AND h.room_sequence=ack."roomSequence"
                  AND h.owner_epoch=ack."ownerEpoch" AND h.room_control_version=ack."roomControlVersion"
                """).run()
            try await fence(sql, lease: lease)
            return true
        }
    }
    public func retireExpiredConsumer(lease: V2RealtimePartitionLease, consumer: V2RealtimeJournalConsumerKey,
                                     expectedRoutingEpoch: Int64, expectedRoutingToken: UUID,
                                     expectedCoverageExpiresAt: Date) async throws -> Bool {
        guard expectedRoutingEpoch>0, v2PostgresTimestampCanEncode(expectedCoverageExpiresAt) else {
            throw V2RealtimeJournalError.invalidInput
        }
        return try await transaction { db in
            let sql = try sqlDatabase(db); try await fence(sql, lease: lease)
            guard let record = try await consumerRecord(sql, partitionID: lease.partitionID, key: consumer, activeOnly: false),
                  record.registration.routingEpoch==expectedRoutingEpoch,
                  record.registration.routingToken==expectedRoutingToken,
                  abs(record.registration.coverageExpiresAt.timeIntervalSince(expectedCoverageExpiresAt))<0.000_001 else { return false }
            let deleted = try await sql.raw("""
                DELETE FROM \(unsafeRaw: schema).realtime_journal_consumers
                WHERE partition_id=\(bind: lease.partitionID) AND gateway_incarnation=\(bind: consumer.gateway.incarnationID)
                  AND coverage_expires_at<=clock_timestamp() RETURNING gateway_incarnation
                """).all()
            try await fence(sql, lease: lease)
            return deleted.count==1
        }
    }

    private var publisherLeases: PostgresV2JournalPublisherLeaseStore {
        get throws { try PostgresV2JournalPublisherLeaseStore(database: database, schema: schema) }
    }
    public func claim(partitionIDs: [Int], identity: V2GatewayRealtimeIdentity, token: UUID,
                      leaseDuration: TimeInterval) async throws -> [V2RealtimePartitionLease] {
        try await publisherLeases.claim(partitionIDs: partitionIDs, identity: identity, token: token, leaseDuration: leaseDuration)
    }
    public func renew(_ leases: [V2RealtimePartitionLease], leaseDuration: TimeInterval) async throws -> [V2RealtimePartitionLease] {
        try await publisherLeases.renew(leases, leaseDuration: leaseDuration)
    }
    public func confirm(_ leases: [V2RealtimePartitionLease]) async throws -> [V2RealtimePartitionLease] {
        try await publisherLeases.confirm(leases)
    }
    public func release(_ leases: [V2RealtimePartitionLease]) async throws {
        try await publisherLeases.release(leases)
    }

    public func pendingPartitions(partitionIDs: [Int], limit: Int) async throws -> [Int] {
        guard partitionIDs.count <= 256, partitionIDs.allSatisfy({ (0..<256).contains($0) }),
              (1...256).contains(limit) else { throw V2RealtimeJournalError.invalidInput }
        guard !partitionIDs.isEmpty else { return [] }
        let ids = String(decoding: try JSONEncoder().encode(Array(Set(partitionIDs)).sorted()), as: UTF8.self)
        struct Pending: Decodable { let partition_id: Int }
        return try await sqlDatabase(database).raw("""
            SELECT DISTINCT partition_id FROM \(unsafeRaw: schema).realtime_change_outbox
            WHERE partition_id IN (SELECT value::integer FROM jsonb_array_elements_text(\(bind: ids)::jsonb))
            ORDER BY partition_id LIMIT \(bind: limit)
            """).all(decoding: Pending.self).map(\.partition_id)
    }

    public func pendingRoomHeadPartitions(partitionIDs: [Int], limit: Int) async throws -> [Int] {
        guard partitionIDs.count <= 256, partitionIDs.allSatisfy({ (0..<256).contains($0) }),
              (1...256).contains(limit) else { throw V2RealtimeJournalError.invalidInput }
        guard !partitionIDs.isEmpty else { return [] }
        let ids = String(decoding: try JSONEncoder().encode(Array(Set(partitionIDs)).sorted()), as: UTF8.self)
        struct Pending: Decodable { let partition_id: Int }
        return try await sqlDatabase(database).raw("""
            SELECT DISTINCT partition_id FROM \(unsafeRaw: schema).realtime_dirty_room_heads
            WHERE pending AND partition_id IN(SELECT value::integer FROM jsonb_array_elements_text(\(bind: ids)::jsonb))
            ORDER BY partition_id LIMIT \(bind: limit)
            """).all(decoding: Pending.self).map(\.partition_id)
    }

    public func pendingRoomHeads(lease: V2RealtimePartitionLease, limit: Int) async throws -> [V2RealtimeRoomHeadChange] {
        guard (1...128).contains(limit) else { throw V2RealtimeJournalError.invalidInput }
        try validate(partitionID: lease.partitionID, after: 0, limit: limit)
        return try await transaction { db in
            let sql = try sqlDatabase(db)
            try await fence(sql, lease: lease)
            guard let row = try await sql.raw("""
                SELECT coalesce(jsonb_agg(jsonb_build_object(
                    'partitionID',h.partition_id,'roomID',h.room_id,'roomSequence',h.room_sequence,
                    'ownerEpoch',h.owner_epoch,'roomControlVersion',h.room_control_version,'revision',h.revision)
                    ORDER BY h.room_id),'[]'::jsonb)::text AS payload
                FROM (SELECT * FROM \(unsafeRaw: schema).realtime_dirty_room_heads
                    WHERE partition_id=\(bind: lease.partitionID) AND pending ORDER BY room_id LIMIT \(bind: limit)) h
                """).first(decoding: Payload.self) else { throw V2RealtimeJournalError.corruptPersistenceState }
            let heads = try JSONDecoder().decode([V2RealtimeRoomHeadChange].self, from: Data(row.payload.utf8))
            try await fence(sql, lease: lease)
            return heads
        }
    }

    public func acknowledgeRoomHeads(lease: V2RealtimePartitionLease, heads: [V2RealtimeRoomHeadChange]) async throws {
        guard heads.count <= 128, Set(heads.map(\.roomID)).count == heads.count,
              heads.allSatisfy({ $0.partitionID == lease.partitionID && $0.revision > 0
                && $0.roomSequence >= 0 && $0.ownerEpoch >= 0 && $0.roomControlVersion >= 0 }) else {
            throw V2RealtimeJournalError.invalidInput
        }
        try validate(partitionID: lease.partitionID, after: 0, limit: 1)
        guard !heads.isEmpty else { return }
        let json = String(decoding: try JSONEncoder().encode(heads), as: UTF8.self)
        try await transaction { db in
            let sql = try sqlDatabase(db)
            try await fence(sql, lease: lease)
            try await sql.raw("""
                UPDATE \(unsafeRaw: schema).realtime_dirty_room_heads h SET pending=false
                FROM jsonb_to_recordset(\(bind: json)::jsonb) AS ack(
                    "roomID" uuid,"partitionID" integer,"roomSequence" bigint,"ownerEpoch" bigint,
                    "roomControlVersion" bigint,revision bigint)
                WHERE h.room_id=ack."roomID" AND h.partition_id=\(bind: lease.partitionID)
                  AND h.revision=ack.revision AND h.room_sequence=ack."roomSequence"
                  AND h.owner_epoch=ack."ownerEpoch" AND h.room_control_version=ack."roomControlVersion"
                """).run()
            try await fence(sql, lease: lease)
        }
    }

    public func publishPending(lease: V2RealtimePartitionLease, limit: Int) async throws -> V2RealtimeJournalBatch {
        try validate(partitionID: lease.partitionID, after: 0, limit: limit)
        return try await transaction { db in
            let sql = try sqlDatabase(db)
            try await fence(sql, lease: lease)
            // Serialize allocators without blocking the KEY SHARE locks held
            // by uncommitted source inserts' partition foreign keys. UPDATE
            // would wait on those invisible sources and defeat committed replay.
            _ = try await sql.raw("""
                SELECT partition_id FROM \(unsafeRaw: schema).realtime_journal_partitions
                WHERE partition_id=\(bind: lease.partitionID) FOR NO KEY UPDATE
                """).all()
            let invalid = try await sql.raw("""
                SELECT source_event_id FROM \(unsafeRaw: schema).realtime_change_outbox
                WHERE partition_id=\(bind: lease.partitionID) AND
                    (CASE WHEN topic_kind='roomEvents' THEN room_control_version
                          WHEN topic_kind='userSync' THEN user_control_version END IS NULL OR
                     CASE WHEN topic_kind='roomEvents' THEN room_control_version
                          WHEN topic_kind='userSync' THEN user_control_version END <= 0)
                LIMIT 1
                """).all()
            guard invalid.isEmpty else { throw V2RealtimeJournalError.corruptPersistenceState }
            try await sql.raw("""
                DELETE FROM \(unsafeRaw: schema).realtime_change_outbox o
                WHERE o.source_event_id IN (
                    SELECT duplicate.source_event_id FROM \(unsafeRaw: schema).realtime_change_outbox duplicate
                    JOIN \(unsafeRaw: schema).realtime_control_publication_floors f
                      ON f.topic_kind=duplicate.topic_kind AND f.topic_id=duplicate.topic_id
                    WHERE duplicate.partition_id=\(bind: lease.partitionID)
                      AND CASE WHEN duplicate.topic_kind='roomEvents' THEN duplicate.room_control_version
                               ELSE duplicate.user_control_version END <= f.published_version
                    ORDER BY duplicate.created_at,duplicate.source_event_id LIMIT \(bind: limit))
                """).run()
            let selected = try await sql.raw("""
                WITH picked AS (
                    SELECT o.*,(SELECT min(age.created_at) FROM \(unsafeRaw: schema).realtime_change_outbox age
                                   WHERE age.topic_kind=o.topic_kind AND age.topic_id=o.topic_id) AS topic_created_at,
                           CASE WHEN o.topic_kind='roomEvents'  THEN o.room_control_version
                                    ELSE o.user_control_version END AS control_version
                    FROM \(unsafeRaw: schema).realtime_change_outbox o
                    LEFT JOIN \(unsafeRaw: schema).realtime_control_publication_floors f
                      ON f.topic_kind=o.topic_kind AND f.topic_id=o.topic_id
                    WHERE o.partition_id=\(bind: lease.partitionID)
                      AND CASE WHEN o.topic_kind='roomEvents' THEN o.room_control_version ELSE o.user_control_version END>coalesce(f.published_version,0)
                    ORDER BY topic_created_at,topic_kind,topic_id,control_version LIMIT \(bind: limit)
                )
                SELECT p.topic_kind FROM picked p
                LEFT JOIN \(unsafeRaw: schema).realtime_control_publication_floors f
                  ON f.topic_kind=p.topic_kind AND f.topic_id=p.topic_id
                GROUP BY p.topic_kind,p.topic_id,f.published_version
                HAVING min(p.control_version)<>coalesce(f.published_version,0)+1
                    OR max(p.control_version)-min(p.control_version)+1<>count(*)
                    OR count(DISTINCT p.control_version)<>count(*)
                """).all()
            guard selected.isEmpty else { throw V2RealtimeJournalError.corruptPersistenceState }
            let previous = try await read(sql, partitionID: lease.partitionID, after: 0, limit: 1)
            try await sql.raw("""
                WITH picked AS MATERIALIZED (
                    SELECT o.*,(SELECT min(age.created_at) FROM \(unsafeRaw: schema).realtime_change_outbox age
                                   WHERE age.topic_kind=o.topic_kind AND age.topic_id=o.topic_id) AS topic_created_at
                    FROM \(unsafeRaw: schema).realtime_change_outbox o
                    WHERE partition_id=\(bind: lease.partitionID) AND
                        CASE WHEN o.topic_kind='roomEvents' THEN o.room_control_version ELSE o.user_control_version END > coalesce((
                            SELECT published_version FROM \(unsafeRaw: schema).realtime_control_publication_floors f
                            WHERE f.topic_kind=o.topic_kind AND f.topic_id=o.topic_id),0)
                    ORDER BY topic_created_at,topic_kind,topic_id,
                        CASE WHEN o.topic_kind='roomEvents' THEN o.room_control_version ELSE o.user_control_version END
                    LIMIT \(bind: limit) FOR UPDATE
                ), numbered AS (
                    SELECT *,row_number() OVER(ORDER BY topic_created_at,topic_kind,topic_id,
                        CASE WHEN topic_kind='roomEvents' THEN room_control_version ELSE user_control_version END) AS journal_ordinal FROM picked
                ), appended AS (
                    INSERT INTO \(unsafeRaw: schema).realtime_change_journal
                    (partition_id,sequence,source_event_id,topic_kind,topic_id,change_kind,room_sequence,room_control_version,user_control_version,device_id,owner_epoch,membership_room_id)
                    SELECT partition_id,\(bind: previous.publishedThrough)+journal_ordinal,source_event_id,
                           topic_kind,topic_id,change_kind,room_sequence,room_control_version,user_control_version,device_id,owner_epoch,membership_room_id
                    FROM numbered RETURNING source_event_id,partition_id,sequence
                ), floors AS (
                    INSERT INTO \(unsafeRaw: schema).realtime_control_publication_floors(topic_kind,topic_id,published_version)
                    SELECT topic_kind,topic_id,max(CASE WHEN topic_kind='roomEvents' THEN room_control_version ELSE user_control_version END)
                    FROM picked WHERE source_event_id IN(SELECT source_event_id FROM appended) GROUP BY topic_kind,topic_id
                    ON CONFLICT(topic_kind,topic_id) DO UPDATE SET published_version=EXCLUDED.published_version
                    RETURNING topic_kind,topic_id
                ), marked AS (
                    DELETE FROM \(unsafeRaw: schema).realtime_change_outbox
                    WHERE source_event_id IN(SELECT source_event_id FROM appended)
                      AND EXISTS(SELECT 1 FROM floors) RETURNING source_event_id
                )
                UPDATE \(unsafeRaw: schema).realtime_journal_partitions
                SET published_through=published_through+(SELECT count(*) FROM marked)
                WHERE partition_id=\(bind: lease.partitionID)
                """).run()
            let result = try await read(sql, partitionID: lease.partitionID, after: previous.publishedThrough, limit: limit)
            try await fence(sql, lease: lease)
            return result
        }
    }

    public func replay(partitionID: Int, after: Int64, limit: Int) async throws -> V2RealtimeJournalBatch {
        try validate(partitionID: partitionID, after: after, limit: limit)
        return try await read(sqlDatabase(database), partitionID: partitionID, after: after, limit: limit)
    }

    public func trim(lease: V2RealtimePartitionLease, through: Int64) async throws {
        try validate(partitionID: lease.partitionID, after: through, limit: 1)
        try await transaction { db in
            let sql = try sqlDatabase(db)
            try await fence(sql, lease: lease)
            let rows = try await sql.raw("""
                UPDATE \(unsafeRaw: schema).realtime_journal_partitions
                SET trimmed_through=greatest(trimmed_through,\(bind: through))
                WHERE partition_id=\(bind: lease.partitionID) AND published_through>=\(bind: through)
                  AND NOT EXISTS(SELECT 1 FROM \(unsafeRaw: schema).realtime_journal_consumers
                    WHERE partition_id=\(bind: lease.partitionID) AND control_cursor<\(bind: through))
                RETURNING partition_id
                """).all()
            guard rows.count == 1 else { throw V2RealtimeJournalError.invalidInput }
            try await sql.raw("""
                DELETE FROM \(unsafeRaw: schema).realtime_change_journal
                WHERE partition_id=\(bind: lease.partitionID) AND sequence<=\(bind: through)
                """).run()
            try await fence(sql, lease: lease)
        }
    }

    private func fence(_ sql: any SQLDatabase, lease: V2RealtimePartitionLease) async throws {
        // Lock first, then sample the database clock: a queued old publisher
        // cannot append after a successor has claimed the partition.
        _ = try await sql.raw("""
            SELECT partition_id FROM \(unsafeRaw: schema).realtime_journal_publisher_leases
            WHERE partition_id=\(bind: lease.partitionID) FOR UPDATE
            """).all()
        let rows = try await sql.raw("""
            SELECT partition_id FROM \(unsafeRaw: schema).realtime_journal_publisher_leases
            WHERE partition_id=\(bind: lease.partitionID) AND lease_epoch=\(bind: lease.epoch)
              AND lease_token=\(bind: lease.token) AND host_id=\(bind: lease.identity.nodeID)
              AND service_id=\(bind: lease.identity.serviceID)
              AND process_incarnation=\(bind: lease.identity.incarnationID) AND expires_at>clock_timestamp()
            """).all()
        guard rows.count == 1 else { throw V2RealtimeJournalError.authorityLost }
    }

    private func read(_ sql: any SQLDatabase, partitionID: Int, after: Int64, limit: Int) async throws -> V2RealtimeJournalBatch {
        guard let row = try await sql.raw("""
            SELECT jsonb_build_object(
                'partitionID',p.partition_id,'publishedThrough',p.published_through,
                'trimmedThrough',p.trimmed_through,
                'requiresSnapshot',\(bind: after)<p.trimmed_through OR \(bind: after)>p.published_through,
                'entries',coalesce((SELECT jsonb_agg(e.body ORDER BY e.sequence) FROM (
                    SELECT j.sequence,jsonb_build_object(
                        'partitionID',j.partition_id,'sequence',j.sequence,'sourceEventID',j.source_event_id,
                        'topicKind',j.topic_kind,'topicID',j.topic_id,'changeKind',j.change_kind,
                        'ownerEpoch',j.owner_epoch,'roomSequence',j.room_sequence,'roomControlVersion',j.room_control_version,
                        'userControlVersion',j.user_control_version,'deviceID',j.device_id,'membershipRoomID',j.membership_room_id) AS body
                    FROM \(unsafeRaw: schema).realtime_change_journal j
                    WHERE j.partition_id=p.partition_id AND j.sequence>\(bind: after)
                        AND \(bind: after)>=p.trimmed_through AND \(bind: after)<=p.published_through
                    ORDER BY j.sequence LIMIT \(bind: limit)
                ) e),'[]'::jsonb))::text AS payload
            FROM \(unsafeRaw: schema).realtime_journal_partitions p WHERE partition_id=\(bind: partitionID)
            """).first(decoding: Payload.self) else { throw V2RealtimeJournalError.corruptPersistenceState }
        return try JSONDecoder().decode(V2RealtimeJournalBatch.self, from: Data(row.payload.utf8))
    }

    private struct Payload: Decodable { let payload: String }
    private func sqlDatabase(_ db: any Database) throws -> any SQLDatabase {
        guard let sql = db as? any SQLDatabase else { throw V2RealtimeJournalError.corruptPersistenceState }
        return sql
    }
    private func validate(partitionID: Int, after: Int64, limit: Int) throws {
        guard (0..<256).contains(partitionID),after>=0,(1...4096).contains(limit) else { throw V2RealtimeJournalError.invalidInput }
    }
    private func transaction<T: Sendable>(_ body: @escaping @Sendable (any Database) async throws -> T) async throws -> T {
        let deadline = min(V2RoomSQLDeadline.current ?? (ContinuousClock.now + .seconds(5)), ContinuousClock.now + .seconds(5))
        return try await V2RoomSQLDeadline.$current.withValue(deadline) {
            try await v2WithPostgresTransactionRetry(database: database, maximumRetryCount: 0,
                classifyCommitFailure: true, useRoomDeadline: true, body)
        }
    }
}

/// Fixed-size control-plane fencing; never used to resolve a publication.
/// Locks are acquired in ascending partition order. Every decision uses a
/// database clock sampled after those locks, and results escape only on COMMIT.
private struct PostgresV2JournalPublisherLeaseStore: V2RealtimePartitionLeaseStore {
    private let database: any Database
    private let schema: String
    private let operationTimeout: Duration
    private static let partitionCount = 256

    public init(database: any Database, schema: String = "im_v2", operationTimeout: Duration = .seconds(5)) throws {
        guard schema.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else {
            throw V2RealtimePartitionStoreError.invalidInput
        }
        guard operationTimeout > .zero, operationTimeout <= .seconds(10) else { throw V2RealtimePartitionStoreError.invalidInput }
        self.operationTimeout = operationTimeout
        self.database = database
        self.schema = schema
    }

    public func claim(partitionIDs: [Int], identity: V2GatewayRealtimeIdentity,
                      token: UUID, leaseDuration: TimeInterval) async throws -> [V2RealtimePartitionLease] {
        try validate(partitionIDs)
        try validate(identity)
        try validate(leaseDuration)
        guard !partitionIDs.isEmpty else { return [] }
        return try await transaction { db in
            let sql = try sql(db)
            let rows = try await lockedRows(sql, ids: partitionIDs)
            let now = try await clock(sql)
            let expiry = now.addingTimeInterval(leaseDuration)
            guard v2PostgresTimestampCanEncode(expiry) else {
                throw V2RealtimePartitionStoreError.invalidInput
            }
            var confirmed: [V2RealtimePartitionLease] = []
            var changes: [Mutation] = []
            for row in rows {
                try row.validate()
                if row.expiresAt > now {
                    // A retry of an uncertain claim confirms exactly its token;
                    // it does not extend time or replace an active incarnation.
                    if row.identity == identity, row.token == token {
                        confirmed.append(try row.lease(at: now))
                    }
                    continue
                }
                guard row.epoch < Int64.max else {
                    throw V2RealtimePartitionStoreError.corruptPersistenceState
                }
                changes.append(.init(partitionID: row.partitionID, identity: identity,
                                     epoch: row.epoch + 1, token: token, expiry: expiry))
            }
            confirmed += try await update(sql, changes: changes, now: now)
            return confirmed.sorted { $0.partitionID < $1.partitionID }
        }
    }

    public func renew(_ leases: [V2RealtimePartitionLease],
                      leaseDuration: TimeInterval) async throws -> [V2RealtimePartitionLease] {
        try validate(leases)
        try validate(leaseDuration)
        guard !leases.isEmpty else { return [] }
        let expected = Dictionary(uniqueKeysWithValues: leases.map { ($0.partitionID, $0) })
        return try await transaction { db in
            let sql = try sql(db)
            let rows = try await lockedRows(sql, ids: leases.map(\.partitionID))
            let now = try await clock(sql)
            let expiry = now.addingTimeInterval(leaseDuration)
            guard v2PostgresTimestampCanEncode(expiry) else {
                throw V2RealtimePartitionStoreError.invalidInput
            }
            var changes: [Mutation] = []
            for row in rows {
                try row.validate()
                guard let lease = expected[row.partitionID], row.matches(lease), row.expiresAt > now else { continue }
                changes.append(.init(partitionID: row.partitionID, identity: lease.identity,
                                     epoch: lease.epoch, token: lease.token,
                                     expiry: max(row.expiresAt, expiry)))
            }
            return try await update(sql, changes: changes, now: now)
        }
    }

    public func confirm(_ leases: [V2RealtimePartitionLease]) async throws -> [V2RealtimePartitionLease] {
        try validate(leases)
        guard !leases.isEmpty else { return [] }
        let expected = Dictionary(uniqueKeysWithValues: leases.map { ($0.partitionID, $0) })
        return try await transaction { db in
            let sql = try sql(db)
            let rows = try await lockedRows(sql, ids: leases.map(\.partitionID))
            let now = try await clock(sql)
            var result: [V2RealtimePartitionLease] = []
            for row in rows {
                try row.validate()
                guard let lease = expected[row.partitionID], row.matches(lease), row.expiresAt > now else { continue }
                result.append(try row.lease(at: now))
            }
            return result
        }
    }

    public func release(_ leases: [V2RealtimePartitionLease]) async throws {
        try validate(leases)
        guard !leases.isEmpty else { return }
        let expected = Dictionary(uniqueKeysWithValues: leases.map { ($0.partitionID, $0) })
        try await transaction { db in
            let sql = try sql(db)
            let rows = try await lockedRows(sql, ids: leases.map(\.partitionID))
            let now = try await clock(sql)
            var changes: [Mutation] = []
            for row in rows {
                try row.validate()
                guard let lease = expected[row.partitionID], row.matches(lease) else { continue }
                // Retain the epoch forever. An old release cannot retire a
                // successor, and the next claim must allocate a higher epoch.
                changes.append(.init(partitionID: row.partitionID, identity: lease.identity,
                                     epoch: lease.epoch, token: lease.token,
                                     expiry: min(row.expiresAt, now)))
            }
            _ = try await update(sql, changes: changes, now: now, returningActive: false)
        }
    }

    private func transaction<Value: Sendable>(
        _ body: @escaping @Sendable (any Database) async throws -> Value
    ) async throws -> Value {
        let limit = ContinuousClock.now + operationTimeout
        let deadline = min(V2RoomSQLDeadline.current ?? limit, limit)
        return try await V2RoomSQLDeadline.$current.withValue(deadline) {
            try await v2WithPostgresTransactionRetry(database: database, maximumRetryCount: 0,
                classifyCommitFailure: true, useRoomDeadline: true, body)
        }
    }

    private func lockedRows(_ sql: any SQLDatabase, ids: [Int]) async throws -> [Row] {
        let json = try encode(ids.sorted())
        let rows = try await sql.raw("""
            SELECT partition_id, host_id, service_id, process_incarnation,
                   lease_epoch, lease_token, expires_at
            FROM \(unsafeRaw: schema).realtime_journal_publisher_leases
            WHERE partition_id IN (SELECT value::integer
                FROM jsonb_array_elements_text(\(bind: json)::jsonb))
            ORDER BY partition_id FOR UPDATE
            """).all(decoding: Row.self)
        guard rows.map(\.partitionID) == ids.sorted() else {
            throw V2RealtimePartitionStoreError.corruptPersistenceState
        }
        return rows
    }

    private func update(_ sql: any SQLDatabase, changes: [Mutation], now: Date,
                        returningActive: Bool = true) async throws -> [V2RealtimePartitionLease] {
        guard !changes.isEmpty else { return [] }
        let json = try encode(changes.sorted { $0.partitionID < $1.partitionID })
        let rows = try await sql.raw("""
            UPDATE \(unsafeRaw: schema).realtime_journal_publisher_leases AS lease
            SET host_id = change.host_id, service_id = change.service_id,
                process_incarnation = change.process_incarnation,
                lease_epoch = change.lease_epoch, lease_token = change.lease_token,
                expires_at = to_timestamp(change.expires_at), updated_at = \(bind: now)
            FROM jsonb_to_recordset(\(bind: json)::jsonb) AS change
                (partition_id integer, host_id text, service_id text,
                 process_incarnation uuid, lease_epoch bigint, lease_token uuid,
                 expires_at double precision)
            WHERE lease.partition_id = change.partition_id
            RETURNING lease.partition_id, lease.host_id, lease.service_id,
                      lease.process_incarnation, lease.lease_epoch, lease.lease_token, lease.expires_at
            """).all(decoding: Row.self)
        let expected = Dictionary(uniqueKeysWithValues: changes.map { ($0.partitionID, $0) })
        guard rows.count == changes.count, Set(rows.map(\.partitionID)).count == changes.count else {
            throw V2RealtimePartitionStoreError.corruptPersistenceState
        }
        for row in rows {
            try row.validate()
            guard let change = expected[row.partitionID], row.identity == change.identity,
                  row.epoch == change.epoch, row.token == change.token,
                  abs(row.expiresAt.timeIntervalSince1970 - change.expirySeconds) < 0.000_01 else {
                throw V2RealtimePartitionStoreError.corruptPersistenceState
            }
        }
        guard returningActive else { return [] }
        return try rows.sorted { $0.partitionID < $1.partitionID }.map { try $0.lease(at: now) }
    }

    private func clock(_ sql: any SQLDatabase) async throws -> Date {
        guard let row = try await sql.raw("SELECT clock_timestamp() AS now").first(decoding: ClockRow.self),
              v2PostgresTimestampCanEncode(row.now) else {
            throw V2RealtimePartitionStoreError.corruptPersistenceState
        }
        return row.now
    }
    private func sql(_ db: any Database) throws -> any SQLDatabase {
        guard let sql = db as? any SQLDatabase else { throw V2RealtimePartitionStoreError.corruptPersistenceState }
        return sql
    }
    private func encode<T: Encodable>(_ value: T) throws -> String {
        guard let string = String(data: try JSONEncoder().encode(value), encoding: .utf8) else {
            throw V2RealtimePartitionStoreError.corruptPersistenceState
        }
        return string
    }
    private func validate(_ ids: [Int]) throws {
        guard ids.count <= Self.partitionCount, Set(ids).count == ids.count,
              ids.allSatisfy({ (0..<Self.partitionCount).contains($0) }) else {
            throw V2RealtimePartitionStoreError.invalidInput
        }
    }
    private func validate(_ identity: V2GatewayRealtimeIdentity) throws {
        guard !identity.nodeID.isEmpty, identity.nodeID.utf8.count <= 128,
              !identity.serviceID.isEmpty, identity.serviceID.utf8.count <= 128 else {
            throw V2RealtimePartitionStoreError.invalidInput
        }
    }
    private func validate(_ duration: TimeInterval) throws {
        guard duration.isFinite, duration > 0, duration <= 300 else {
            throw V2RealtimePartitionStoreError.invalidInput
        }
    }
    private func validate(_ leases: [V2RealtimePartitionLease]) throws {
        try validate(leases.map(\.partitionID))
        for lease in leases {
            try validate(lease.identity)
            guard lease.epoch > 0, lease.remainingLeaseSeconds.isFinite else {
                throw V2RealtimePartitionStoreError.invalidInput
            }
        }
    }

    private struct ClockRow: Decodable { let now: Date }
    private struct Row: Decodable {
        let partitionID: Int
        let hostID: String?
        let serviceID: String?
        let incarnation: UUID?
        let epoch: Int64
        let token: UUID?
        let expiresAt: Date
        enum CodingKeys: String, CodingKey {
            case partitionID = "partition_id", hostID = "host_id", serviceID = "service_id"
            case incarnation = "process_incarnation", epoch = "lease_epoch"
            case token = "lease_token", expiresAt = "expires_at"
        }
        var identity: V2GatewayRealtimeIdentity? {
            guard let hostID, let serviceID, let incarnation else { return nil }
            return .init(nodeID: hostID, serviceID: serviceID, incarnationID: incarnation)
        }
        func validate() throws {
            let initial = epoch == 0 && hostID == nil && serviceID == nil && incarnation == nil && token == nil
            let assigned = epoch > 0 && identity != nil && token != nil
            guard (initial || assigned), (0..<256).contains(partitionID),
                  v2PostgresTimestampCanEncode(expiresAt) else {
                throw V2RealtimePartitionStoreError.corruptPersistenceState
            }
        }
        func matches(_ lease: V2RealtimePartitionLease) -> Bool {
            identity == lease.identity && epoch == lease.epoch && token == lease.token
        }
        func lease(at now: Date) throws -> V2RealtimePartitionLease {
            guard let identity, let token, epoch > 0, expiresAt > now else {
                throw V2RealtimePartitionStoreError.corruptPersistenceState
            }
            return .init(partitionID: partitionID, identity: identity, epoch: epoch,
                         token: token, remainingLeaseSeconds: expiresAt.timeIntervalSince(now))
        }
    }
    private struct Mutation: Encodable {
        let partitionID: Int
        let identity: V2GatewayRealtimeIdentity
        let epoch: Int64
        let token: UUID
        let expirySeconds: TimeInterval
        var hostID: String { identity.nodeID }
        var serviceID: String { identity.serviceID }
        var incarnation: UUID { identity.incarnationID }
        enum CodingKeys: String, CodingKey {
            case partitionID = "partition_id", hostID = "host_id", serviceID = "service_id"
            case incarnation = "process_incarnation", epoch = "lease_epoch", token = "lease_token"
            case expirySeconds = "expires_at"
        }
        init(partitionID: Int, identity: V2GatewayRealtimeIdentity, epoch: Int64, token: UUID, expiry: Date) {
            self.partitionID = partitionID; self.identity = identity
            self.epoch = epoch; self.token = token; self.expirySeconds = expiry.timeIntervalSince1970
        }
        func encode(to encoder: any Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(partitionID, forKey: .partitionID)
            try values.encode(hostID, forKey: .hostID)
            try values.encode(serviceID, forKey: .serviceID)
            try values.encode(incarnation, forKey: .incarnation)
            try values.encode(epoch, forKey: .epoch)
            try values.encode(token, forKey: .token)
            try values.encode(expirySeconds, forKey: .expirySeconds)
        }
    }
}
