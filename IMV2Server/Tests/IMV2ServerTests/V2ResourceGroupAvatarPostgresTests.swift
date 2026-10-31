@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import FluentKit
import FluentPostgresDriver
import Foundation
import HTTPTypes
import IMV2ActorContracts
import IMV2ActorRuntime
import IMV2Core
import IMV2ServerHTTP
import PostgresNIO
import SQLKit
import Testing
import Vapor
import VaporTesting
@testable import IMV2Server
@testable import IMV2ServerInfrastructure

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"] != nil))
struct V2ResourceGroupAvatarPostgresTests {
    @Test("upload admission and owner transaction both require the structural group owner",
          arguments: ["valid", "disabled", "owner-before", "role-before", "owner-after", "role-after"])
    func uploadAuthority(scenario: String) async throws {
        try await withFixture { f in
            let device = try await f.account(on: f.database)
            let change: @Sendable () async throws -> Void = {
                if scenario.hasPrefix("owner-") {
                    // Deliberately leave the role and revisions untouched: the
                    // structural authority must be checked independently.
                    try await f.sql.raw("UPDATE im_v2.group_rooms SET owner_user_id=\(bind:f.member.uuidValue!) WHERE room_id=\(bind:f.room.uuidValue!)").run()
                } else if scenario.hasPrefix("role-") {
                    try await f.sql.raw("UPDATE im_v2.room_memberships SET role='member' WHERE room_id=\(bind:f.room.uuidValue!) AND user_id=\(bind:f.owner.uuidValue!)").run()
                }
            }
            if scenario.hasSuffix("before") { try await change() }
            let executor = try V2RoomMediaAuthorizationDomainExecutor(database: f.database, token: f.token, lifetime: f.lifetime)
            let route = try V2RoomShardRoute(shardID: f.token.owner.shardID, epoch: f.token.owner.epoch)
            let router = V2ResourceHomeRouter(controlDatabase: f.database, rooms: AvatarTestRouter(value: route),
                ownerDatabases: [route.shardID: f.database], authorization: .init(query: { query, _ in
                    let proof = try await executor.execute(query)
                    if scenario.hasSuffix("after") { try await change() }
                    return proof
                }))
            let request = try V2ResourceUploadRequest(operationID: .init(uuid: UUID()), mediaID: .init(uuid: UUID()),
                usage: .groupAvatar(f.room), contentType: "image/png", byteCount: 8,
                checksum: .init(value: String(repeating: "a", count: 64)))
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("avatar-upload-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let binding = try V2StorageBinding(id: "avatar-upload", configurationRevision: 1)
            let storage = try V2LocalResourceStorage(root: root.appendingPathComponent("objects"), binding: binding)
            let provider = try V2LocalFilesystemMediaProvider(rootDirectory: root.appendingPathComponent("staging"),
                targetBaseURL: #require(URL(string: "https://avatar-upload.test")), signingKey: Data(repeating: 1, count: 32))
            try await provider.prepare()
            let service = try V2ResourceService(resolve: { home, usage, actor, device in
                try await router.resolve(home: home, usage: usage, actorUserID: actor, deviceID: device)
            }, registry: .init(storages: [storage], defaultBinding: binding),
                transports: [V2LocalResourceUploadTransport(binding: binding, provider: provider)],
                maximumBytes: 1_000_000, supportsAvatars: scenario != "disabled",
                allocate: { _ in try storage.allocate() })
            #expect(try service.capabilities().allowedUsages.contains(.groupAvatar) == (scenario != "disabled"))
            let create: @Sendable () async throws -> V2ResourceUploadSession = {
                try await service.create(request, actor: f.owner, device: device)
            }
            if scenario == "valid" { #expect(try await create().mediaID == request.mediaID) }
            else if scenario == "disabled" {
                await #expect(throws: V2ResourceProviderError.unsupportedCapability) { _ = try await create() }
            }
            else { await #expect(throws: V2MediaStoreError.uploadNotAuthorized) { _ = try await create() } }
            #expect(try await f.sql.raw("SELECT count(*) AS value FROM im_v2.resource_upload_sessions WHERE media_id=\(bind:request.mediaID.uuidValue!)")
                .first(decoding: AvatarCountRow.self)?.value == (scenario == "valid" ? 1 : 0))
        }
    }

    @Test("query is not closure; closing an absent operation fences all future retries without room membership")
    func permanentClosure() async throws {
        try await withFixture { f in
            let command = try f.command(media: .init(uuid: UUID()))
            let store = try PostgresV2GroupCapabilitiesStore(database: f.database, activationScope: .init(tokens: [f.token]))
            #expect(try await store.recoverAvatar(actorUserID: f.owner, request: .init(command: command, action: .query)) == .unresolved)
            try await f.sql.raw("UPDATE im_v2.room_memberships SET left_revision=0 WHERE room_id=\(bind:f.room.uuidValue!) AND user_id=\(bind:f.owner.uuidValue!)").run()
            #expect(try await store.recoverAvatar(actorUserID: f.owner, request: .init(command: command, action: .closeIfAbsent)) == .closed)
            #expect(try await store.recoverAvatar(actorUserID: f.owner, request: .init(command: command, action: .query)) == .closed)
            await #expect(throws: V2GroupCapabilitiesStoreError.operationClosed) { _ = try await f.apply(command) }
            let changed = try V2GroupAvatarCommand(operationID: command.operationID, roomID: f.room, expectedRevision: 0, mutation: .remove)
            #expect(try await store.recoverAvatar(actorUserID: f.owner, request: .init(command: changed, action: .query)) == .idempotencyConflict)
            #expect(try await f.apply(changed) == .idempotencyConflict)
            #expect(try await store.recoverAvatar(actorUserID: f.member, request: .init(command: command, action: .query)) == .unresolved)
            #expect(try await f.sql.raw("SELECT count(*) AS value FROM im_v2.room_events WHERE room_id=\(bind:f.room.uuidValue!)").first(decoding: AvatarCountRow.self)?.value == 0)
            await #expect(throws: (any Error).self) {
                try await f.sql.raw("DELETE FROM im_v2.resource_group_avatar_closures WHERE actor_user_id=\(bind:f.owner.uuidValue!) AND operation_id=\(bind:command.operationID.uuidValue!)").run()
            }
            await #expect(throws: (any Error).self) {
                try await f.sql.raw("UPDATE im_v2.resource_group_avatar_closures SET expected_revision=99 WHERE actor_user_id=\(bind:f.owner.uuidValue!) AND operation_id=\(bind:command.operationID.uuidValue!)").run()
            }
        }
    }

    @Test("concurrent submission and closure have exactly one durable terminal outcome")
    func closureRace() async throws {
        try await withFixture { f in
            let command = try f.command(media: nil)
            let store = try PostgresV2GroupCapabilitiesStore(database: f.database, activationScope: .init(tokens: [f.token]))
            let values = try await withThrowingTaskGroup(of: V2GroupAvatarRecoveryResult.self) { tasks in
                for index in 0..<10 {
                    tasks.addTask {
                        if index.isMultiple(of: 2) {
                            return try await store.recoverAvatar(actorUserID: f.owner, request: .init(command: command, action: .closeIfAbsent))
                        }
                        do {
                            switch try await f.apply(command) {
                            case .applied(let value), .idempotent(let value): return .committed(value)
                            default: throw V2GroupCapabilitiesStoreError.corruptPersistenceState
                            }
                        } catch V2GroupCapabilitiesStoreError.operationClosed { return .closed }
                    }
                }
                var result: [V2GroupAvatarRecoveryResult] = []
                for try await value in tasks { result.append(value) }; return result
            }
            let first = try #require(values.first)
            #expect(values.allSatisfy { $0 == first })
            let count = try await f.sql.raw("""
                SELECT (SELECT count(*) FROM im_v2.resource_group_avatar_operations WHERE actor_user_id=\(bind:f.owner.uuidValue!) AND operation_id=\(bind:command.operationID.uuidValue!))
                     + (SELECT count(*) FROM im_v2.resource_group_avatar_closures WHERE actor_user_id=\(bind:f.owner.uuidValue!) AND operation_id=\(bind:command.operationID.uuidValue!)) AS value
                """).first(decoding: AvatarCountRow.self)?.value
            #expect(count == 1)
        }
    }

    @Test("both terminal insert fences observe a fresh snapshot after a real PostgreSQL lock wait", arguments: [false, true])
    func terminalSnapshotFence(closeFirst: Bool) async throws {
        try await withFixture { f in
            let command = try f.command(media: nil), gate = AvatarTerminalGate()
            let winner = Task {
                try await f.database.transaction { transaction in
                    let sql = try #require(transaction as? any SQLDatabase)
                    let pid = try #require(try await sql.raw("SELECT pg_backend_pid() AS pid").first(decoding: AvatarPIDRow.self)).pid
                    try await f.insertTerminal(close: closeFirst, command: command, sql: sql)
                    await gate.held(pid)
                    await gate.waitForRelease()
                }
            }
            let pid = await gate.waitUntilHeld()
            let loser = Task { try await f.insertTerminal(close: !closeFirst, command: command, sql: f.sql) }
            do {
                let deadline = ContinuousClock.now + .seconds(5)
                var blocked = false
                while ContinuousClock.now < deadline {
                    blocked = try await f.sql.raw("SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE \(bind:pid)=ANY(pg_blocking_pids(pid))) AS value")
                        .first(decoding: AvatarBoolRow.self)?.value == true
                    if blocked { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                #expect(blocked)
                await gate.release()
                try await winner.value
                do { try await loser.value; Issue.record("conflicting terminal row was inserted") }
                catch let error as PSQLError {
                    #expect(error.serverInfo?[.sqlState] == "23514")
                    #expect(error.serverInfo?[.constraintName] == (closeFirst ? "group_avatar_operation_permanently_closed" : "group_avatar_operation_already_committed"))
                }
            } catch {
                await gate.release(); _ = await winner.result; _ = await loser.result; throw error
            }
        }
    }
    @Test("concurrent retries commit once and replay the original immutable receipt after replacement")
    func durableReceipt() async throws {
        try await withFixture { fixture in
            let media = try await fixture.media()
            let command = try fixture.command(media: media)
            let results = try await withThrowingTaskGroup(of: V2GroupCapabilitiesOutcome<V2GroupAvatarChange>.self) { tasks in
                for _ in 0..<8 { tasks.addTask { try await fixture.apply(command) } }
                var results: [V2GroupCapabilitiesOutcome<V2GroupAvatarChange>] = []
                for try await value in tasks { results.append(value) }
                return results
            }
            #expect(results.filter { if case .applied = $0 { true } else { false } }.count == 1)
            #expect(results.filter { if case .idempotent = $0 { true } else { false } }.count == 7)
            let first = try #require(results.compactMap { if case .applied(let value) = $0 { value } else { nil } }.first)
            #expect(first.state.mediaID == media && first.state.revision == 1 && first.roomSequence == 1)
            let second = try await fixture.media()
            guard case .applied(let changed) = try await fixture.apply(fixture.command(media: second, revision: 1)) else {
                Issue.record("replacement failed"); return
            }
            #expect(changed.state.revision == 2 && changed.roomSequence == 2)
            #expect(try await fixture.apply(command) == .idempotent(first))
            #expect(try await fixture.apply(.init(operationID: command.operationID, roomID: fixture.room,
                expectedRevision: 0, mutation: .set(second))) == .idempotencyConflict)
            #expect(try await fixture.apply(fixture.command(media: second)) == .revisionConflict)
            let events = try await fixture.sql.raw("SELECT payload::text AS value FROM im_v2.room_events WHERE room_id=\(bind:fixture.room.uuidValue!) ORDER BY room_sequence").all(decoding: AvatarStringRow.self)
            #expect(events.count == 2)
            let page = try await PostgresV2GroupEventLogStore(database: fixture.database).pull(roomID: fixture.room,
                actorUserID: fixture.member, afterRoomSequence: 0, pageSize: 10)
            #expect(page.events.count == 2 && page.nextRoomSequence == 2)
            #expect(page.events.allSatisfy { $0.projectionKind == "group_capability" })
            for event in events {
                let payload = try #require(JSONSerialization.jsonObject(with: Data(event.value.utf8)) as? [String: Any])
                #expect(Set(payload.keys) == ["event_type", "room_id", "revision", "room_sequence", "server_created_at_ms"])
            }
            await #expect(throws: (any Error).self) {
                try await fixture.sql.raw("UPDATE im_v2.resource_group_avatar_operations SET resulting_revision=99 WHERE operation_id=\(bind:command.operationID.uuidValue!)").run()
            }
            await #expect(throws: (any Error).self) {
                try await fixture.sql.raw("DELETE FROM im_v2.resource_group_avatar_operations WHERE operation_id=\(bind:command.operationID.uuidValue!)").run()
            }
            #expect(try await fixture.apply(command) == .idempotent(first))
            try await fixture.sql.raw("UPDATE im_v2.rooms SET owner_epoch=1 WHERE room_id=\(bind: fixture.room.uuidValue!)").run()
            await #expect(throws: V2RoomActorStateError.ownerChanged) { _ = try await fixture.apply(command) }
        }
    }

    @Test("only the current structural owner can bind an eligible room avatar",
          arguments: ["member", "former-member", "structural-owner", "frozen", "foreign-home", "wrong-usage", "wrong-uploader", "expired", "missing-variant", "generation", "deleted", "retired-placement"])
    func authorization(scenario: String) async throws {
        try await withFixture { f in
            let media = try await f.media()
            var actor = f.owner
            var error = V2GroupCapabilitiesStoreError.resourceUnavailable
            switch scenario {
            case "member": actor = f.member; error = .actorNotAuthorized
            case "former-member":
                actor = f.member; error = .actorNotMember
                try await f.sql.raw("UPDATE im_v2.room_memberships SET left_revision=0 WHERE room_id=\(bind:f.room.uuidValue!) AND user_id=\(bind:f.member.uuidValue!)").run()
            case "structural-owner":
                error = .actorNotAuthorized
                try await f.sql.raw("UPDATE im_v2.group_rooms SET owner_user_id=\(bind:f.member.uuidValue!) WHERE room_id=\(bind:f.room.uuidValue!)").run()
            case "frozen":
                error = .actorNotAuthorized
                try await f.sql.raw("UPDATE im_v2.rooms SET frozen_at=\(bind:f.now),frozen_by_user_id=\(bind:f.owner.uuidValue!) WHERE room_id=\(bind:f.room.uuidValue!)").run()
            case "foreign-home": try await f.sql.raw("UPDATE im_v2.resource_catalog SET home_id=\(bind:UUID()) WHERE media_id=\(bind:media.uuidValue!)").run()
            case "wrong-usage": try await f.sql.raw("UPDATE im_v2.resource_catalog SET usage_kind='message_attachment' WHERE media_id=\(bind:media.uuidValue!)").run()
            case "wrong-uploader": try await f.sql.raw("UPDATE im_v2.media_objects SET owner_user_id=\(bind:f.member.uuidValue!) WHERE media_id=\(bind:media.uuidValue!)").run()
            case "expired": try await f.sql.raw("UPDATE im_v2.media_objects SET expires_at=\(bind:f.now) WHERE media_id=\(bind:media.uuidValue!)").run()
            case "missing-variant": try await f.sql.raw("DELETE FROM im_v2.resource_variants WHERE media_id=\(bind:media.uuidValue!) AND size=256").run()
            case "generation": try await f.sql.raw("UPDATE im_v2.resource_catalog SET generation=2 WHERE media_id=\(bind:media.uuidValue!)").run()
            case "deleted": try await f.sql.raw("UPDATE im_v2.media_objects SET state='expired' WHERE media_id=\(bind:media.uuidValue!)").run()
            default: try await f.sql.raw("UPDATE im_v2.resource_blob_placements SET state='retiring' WHERE media_id=\(bind:media.uuidValue!)").run()
            }
            let finalActor = actor, finalError = error
            await #expect(throws: finalError) { _ = try await f.apply(f.command(media: media), actor: finalActor) }
            #expect(try await f.sql.raw("SELECT count(*) AS value FROM im_v2.room_events WHERE room_id=\(bind:f.room.uuidValue!)").first(decoding: AvatarCountRow.self)?.value == 0)
        }
    }

    @Test("bound resources survive GC; removal retains outstanding byte capability grace")
    func retention() async throws {
        try await withFixture { f in
            let media = try await f.media()
            _ = try await f.apply(f.command(media: media))
            try await f.sql.raw("UPDATE im_v2.media_objects SET expires_at=\(bind:f.now.addingTimeInterval(-1)) WHERE media_id=\(bind:media.uuidValue!)").run()
            let retention = PostgresV2MediaRetentionStore(database: f.database)
            _ = try await retention.expireEligibleMedia(now: f.now, withdrawnRetention: 60, limit: 100_000)
            #expect(try await f.state(media) == "available")
            // Re-setting the currently bound avatar is valid after the upload bind deadline.
            _ = try await f.apply(f.command(media: media, revision: 1))
            let removal = try f.command(media: nil, revision: 2)
            guard case .applied(let removed) = try await f.apply(removal) else { Issue.record("remove failed"); return }
            #expect(removed.state.mediaID == nil && removed.state.revision == 3)
            _ = try await retention.expireEligibleMedia(now: f.now.addingTimeInterval(119), withdrawnRetention: 60, limit: 100_000)
            #expect(try await f.state(media) == "available")
            _ = try await retention.expireEligibleMedia(now: f.now.addingTimeInterval(121), withdrawnRetention: 60, limit: 100_000)
            #expect(try await f.state(media) == "expired")
            await #expect(throws: V2GroupCapabilitiesStoreError.resourceUnavailable) {
                _ = try await f.apply(f.command(media: media, revision: 3))
            }
        }
    }

    @Test("room-authoritative proof rechecks membership, resource generation, replacement and activation")
    func visibility() async throws {
        try await withFixture { f in
            let executor = try V2RoomMediaAuthorizationDomainExecutor(database: f.database, token: f.token, lifetime: f.lifetime)
            let port = V2ActorRoomMediaAuthorizationPort(query: { query, _ in try await executor.execute(query) })
            let deadline = ContinuousClock().now.advanced(by: .seconds(30))
            let request = V2ActorGroupAvatarVisibilityWire(roomID: f.room, actorUserID: f.member)
            let empty = try #require(try await port.captureGroupAvatar(request, deadline: deadline))
            #expect(empty.state.revision == 0 && empty.state.mediaID == nil && !empty.canManage)
            #expect(try await port.captureGroupAvatar(.init(roomID: f.room, actorUserID: .init(uuid: UUID())), deadline: deadline) == nil)
            let media = try await f.media()
            _ = try await f.apply(f.command(media: media))
            #expect(try await !port.recheckGroupAvatar(empty, deadline: deadline))
            let bound = try #require(try await port.captureGroupAvatar(request, deadline: deadline))
            #expect(bound.state.mediaID == media && bound.resourceGeneration == 1)
            #expect(try await port.recheckGroupAvatar(bound, deadline: deadline))
            #expect(try await port.captureGroupAvatar(.init(roomID: f.room, actorUserID: f.owner), deadline: deadline)?.canManage == true)
            try await f.sql.raw("UPDATE im_v2.resource_catalog SET generation=2 WHERE media_id=\(bind:media.uuidValue!)").run()
            #expect(try await !port.recheckGroupAvatar(bound, deadline: deadline))
            try await f.sql.raw("UPDATE im_v2.resource_catalog SET generation=1 WHERE media_id=\(bind:media.uuidValue!)").run()
            try await f.sql.raw("UPDATE im_v2.room_memberships SET left_revision=0 WHERE room_id=\(bind:f.room.uuidValue!) AND user_id=\(bind:f.member.uuidValue!)").run()
            #expect(try await !port.recheckGroupAvatar(bound, deadline: deadline))
            try await f.sql.raw("UPDATE im_v2.rooms SET owner_epoch=1 WHERE room_id=\(bind: f.room.uuidValue!)").run()
            await #expect(throws: V2RoomActorStateError.ownerChanged) {
                _ = try await port.captureGroupAvatar(request, deadline: deadline)
            }
        }
    }

    func withFixture(_ body: @escaping @Sendable (AvatarFixture) async throws -> Void) async throws {
        try await withAvatarDatabase { seed in
            try await seed.withActivation(body)
        }
    }

    @Test("HTTP reads authenticate the device, return no-store logical state and reject departed members",
          arguments: ProcessInfo.processInfo.environment["IMV2_RESOURCE_FORWARD_TARGET_DATABASE_URL"] == nil ? [false] : [false, true])
    func httpRead(separateControl: Bool) async throws {
        try await withFixture { f in
            let app = try await Application(.testing)
            let controlResources = makeV2DatabaseTestResources()
            do {
                let control: any Database
                if separateControl {
                    controlResources.databases.use(try .postgres(url: #require(ProcessInfo.processInfo.environment["IMV2_RESOURCE_FORWARD_TARGET_DATABASE_URL"])), as: .psql, isDefault: true)
                    control = controlResources.database(.psql)
                } else { control = f.database }
                let controlSQL = try #require(control as? any SQLDatabase)
                let device = DeviceID(uuid: UUID())
                let handle = "ga" + f.member.rawValue.replacingOccurrences(of: "-", with: "").prefix(24).lowercased()
                try await controlSQL.raw("INSERT INTO im_v2.public_user_profiles(user_id,public_handle,display_name,created_at,updated_at) VALUES(\(bind:f.member.uuidValue!),\(bind:handle),'Viewer',clock_timestamp(),clock_timestamp())").run()
                try await controlSQL.raw("INSERT INTO im_v2.auth_devices(user_id,device_id,created_at,last_active_at) VALUES(\(bind:f.member.uuidValue!),\(bind:device.uuidValue!),clock_timestamp(),clock_timestamp())").run()
                if separateControl {
                    #expect(try await f.sql.raw("SELECT count(*) AS value FROM im_v2.public_user_profiles WHERE user_id=\(bind:f.member.uuidValue!)").first(decoding: AvatarCountRow.self)?.value == 0)
                }
                let executor = try V2RoomMediaAuthorizationDomainExecutor(database: f.database, token: f.token, lifetime: f.lifetime)
                let route = try V2RoomShardRoute(shardID: f.token.owner.shardID, epoch: f.token.owner.epoch)
                let service = V2ResourceGroupAvatarPresentationService(controlDatabase: control,
                    rooms: AvatarTestRouter(value: route), ownerDatabases: [route.shardID: f.database],
                    authorization: .init(query: { query, _ in try await executor.execute(query) }), avatars: .init(delivery: AvatarTestDelivery {}))
                V2VaporGroupAvatarPresentationRoutes(authenticator: AvatarHTTPAuthentication(user: f.member), service: service).register(on: app)
                let path = URI(string: "v2/rooms/\(f.room.rawValue)/avatar")
                let headers: HTTPFields = [.authorization: "Bearer test", HTTPField.Name("X-IM-Device-ID")!: device.rawValue]
                try await app.testing { client in
                    let unauthenticated = try await client.send(.get, to: path)
                    #expect(unauthenticated.status == .unauthorized)
                    let invalid = try await client.send(.get, headers: headers, to: "v2/rooms/invalid/avatar")
                    #expect(invalid.status == .badRequest)
                    let empty = try await client.send(.get, headers: headers, to: path)
                    #expect(empty.status == .ok && empty.headers[.cacheControl] == "no-store")
                    let emptyValue = try await empty.content.decode(V2GroupAvatarPresentation.self)
                    #expect(emptyValue.state.revision == 0 && emptyValue.avatar == nil)
                    let media = try await f.media()
                    _ = try await f.apply(f.command(media: media))
                    let bound = try await client.send(.get, headers: headers, to: path)
                    #expect(bound.status == .ok && bound.headers[.cacheControl] == "no-store")
                    #expect(try await bound.content.decode(V2GroupAvatarPresentation.self).avatar?.mediaID == media)
                    try await f.sql.raw("UPDATE im_v2.room_memberships SET left_revision=0 WHERE room_id=\(bind:f.room.uuidValue!) AND user_id=\(bind:f.member.uuidValue!)").run()
                    let departed = try await client.send(.get, headers: headers, to: path)
                    #expect(departed.status == .forbidden)
                }
                try await app.shutdown()
                try await controlResources.shutdown()
            } catch { try? await app.shutdown(); try? await controlResources.shutdown(); throw error }
        }
    }

    @Test("injected delivery is followed by fresh control, membership, generation and routing checks",
          arguments: ["unchanged", "device", "membership", "replacement", "generation", "route"])
    func presentation(scenario: String) async throws {
        try await withFixture { f in
            let media = try await f.media(), device = DeviceID(uuid: UUID())
            _ = try await f.apply(f.command(media: media))
            let handle = "ga" + f.member.rawValue.replacingOccurrences(of: "-", with: "").prefix(24).lowercased()
            try await f.sql.raw("INSERT INTO im_v2.public_user_profiles(user_id,public_handle,display_name,created_at,updated_at) VALUES(\(bind:f.member.uuidValue!),\(bind:handle),'Viewer',clock_timestamp(),clock_timestamp())").run()
            try await f.sql.raw("INSERT INTO im_v2.auth_devices(user_id,device_id,created_at,last_active_at) VALUES(\(bind:f.member.uuidValue!),\(bind:device.uuidValue!),clock_timestamp(),clock_timestamp())").run()
            let executor = try V2RoomMediaAuthorizationDomainExecutor(database: f.database, token: f.token, lifetime: f.lifetime)
            let route = try V2RoomShardRoute(shardID: f.token.owner.shardID, epoch: f.token.owner.epoch)
            let router = AvatarTestRouter(value: route)
            let delivery = AvatarTestDelivery {
                switch scenario {
                case "device": try await f.sql.raw("UPDATE im_v2.auth_devices SET revoked_at=clock_timestamp() WHERE device_id=\(bind:device.uuidValue!)").run()
                case "membership": try await f.sql.raw("UPDATE im_v2.room_memberships SET left_revision=0 WHERE room_id=\(bind:f.room.uuidValue!) AND user_id=\(bind:f.member.uuidValue!)").run()
                case "replacement": _ = try await f.apply(f.command(media: nil, revision: 1))
                case "generation": try await f.sql.raw("UPDATE im_v2.resource_catalog SET generation=2 WHERE media_id=\(bind:media.uuidValue!)").run()
                case "route": await router.change(try .init(shardID: route.shardID, epoch: route.epoch + 1))
                default: break
                }
            }
            let service = V2ResourceGroupAvatarPresentationService(controlDatabase: f.database,
                rooms: router, ownerDatabases: [route.shardID: f.database],
                authorization: .init(query: { query, _ in try await executor.execute(query) }), avatars: .init(delivery: delivery))
            if scenario == "unchanged" {
                let value = try await service.read(roomID: f.room, actorUserID: f.member, deviceID: device)
                #expect(value.state.mediaID == media && value.avatar?.mediaID == media)
                #expect(value.resourceGeneration == 1 && !value.canManage && value.deviceID == device)
                #expect(value.validUntilUnixMilliseconds - value.observedAtUnixMilliseconds <= 300_000)
                #expect(try #require(value.avatar?.plan).expiresAtUnixMilliseconds <= value.validUntilUnixMilliseconds)
            } else {
                await #expect(throws: V2MediaStoreError.downloadNotAuthorized) {
                    _ = try await service.read(roomID: f.room, actorUserID: f.member, deviceID: device)
                }
            }
        }
    }

    @Test("HTTP commands recover lost replies through the Actor and preserve original receipts across later changes",
          arguments: ProcessInfo.processInfo.environment["IMV2_RESOURCE_FORWARD_TARGET_DATABASE_URL"] == nil ? [false] : [false, true])
    func httpCommand(separateControl: Bool) async throws {
        try await withFixture { f in
            let app = try await Application(.testing), controlResources = makeV2DatabaseTestResources()
            do {
                let control: any Database
                if separateControl {
                    controlResources.databases.use(try .postgres(url: #require(ProcessInfo.processInfo.environment["IMV2_RESOURCE_FORWARD_TARGET_DATABASE_URL"])), as: .psql, isDefault: true)
                    control = controlResources.database(.psql)
                } else { control = f.database }
                let controlSQL = try #require(control as? any SQLDatabase)
                let device = try await f.account(on: control)
                let executor = try V2RoomAdministrationDomainExecutor(database: f.database, invitationSecretIssuer: try .init(rawKey: Data(repeating: 0x73, count: 32)), invitationIdentities: PostgresV2GroupInvitationIdentityReader(database: f.database), token: f.token,
                    capacityProfile: f.profile, membershipIdentities: AvatarUnusedIdentityReader())
                let loss = AvatarCommandLostReply()
                let administration = V2RoomRefAdministrationClient(caller: .init(timeout: .seconds(30)) { request, actor, deadline in
                    #expect(actor == f.owner && deadline > .now && deadline <= .now + .seconds(10))
                    guard case .administration(let command) = request else { throw V2RoomCallFailure.outcomeUnknown }
                    let response = try await executor.executeUser(command)
                    if await loss.loseFirst() { throw V2RoomCallFailure.outcomeUnknown }
                    return .administration(response)
                })
                let service = V2ResourceGroupAvatarCommandService(controlDatabase: control, administration: administration)
                V2VaporGroupAvatarCommandRoutes(authenticator: AvatarHTTPAuthentication(user: f.owner), service: service).register(on: app)
                V2VaporGroupAvatarRecoveryRoutes(authenticator: AvatarHTTPAuthentication(user: f.owner), service: service).register(on: app)
                let path = URI(string: "v2/rooms/\(f.room.rawValue)/avatar")
                let headers: HTTPFields = [.authorization: "Bearer test", HTTPField.Name("X-IM-Device-ID")!: device.rawValue]
                let media = try await f.media(), command = try f.command(media: media)
                try await app.testing { client in
                    #expect(try await client.send(.post, to: path).status == .unauthorized)
                    let invalidPath = try await client.send(.post, headers: headers, to: URI(string: "v2/rooms/\(UUID().uuidString)/avatar"),
                        beforeSend: { try $0.content.encode(command, using: JSONEncoder()) })
                    #expect(invalidPath.status == .badRequest)
                    let oversized = try await client.send(.post, headers: headers, to: path,
                        beforeSend: { try $0.content.encode(String(repeating: "x", count: 9 * 1_024), using: JSONEncoder()) })
                    #expect(oversized.status == .contentTooLarge)
                    let lost = try await client.send(.post, headers: headers, to: path,
                        beforeSend: { try $0.content.encode(command, using: JSONEncoder()) })
                    #expect(lost.status == .serviceUnavailable && lost.headers[.cacheControl] == "no-store")
                    let recovered = try await client.send(.post, headers: headers, to: path,
                        beforeSend: { try $0.content.encode(command, using: JSONEncoder()) })
                    #expect(recovered.status == .ok && recovered.headers[.cacheControl] == "no-store")
                    let receipt = try await recovered.content.decode(V2GroupAvatarCommandResponse.self)
                    #expect(receipt.actorUserID == f.owner && receipt.deviceID == device && receipt.command == command)
                    guard case .committed(let first) = receipt.outcome else { Issue.record("missing commit receipt"); return }
                    #expect(first.state.revision == 1 && first.state.mediaID == media)

                    let stale = try f.command(media: media)
                    let conflict = try await client.send(.post, headers: headers, to: path,
                        beforeSend: { try $0.content.encode(stale, using: JSONEncoder()) })
                    #expect(conflict.status == .conflict)
                    #expect(try await conflict.content.decode(V2GroupAvatarCommandResponse.self).outcome == .revisionConflict)
                    let mutated = try V2GroupAvatarCommand(operationID: command.operationID, roomID: f.room, expectedRevision: 0, mutation: .remove)
                    let mismatch = try await client.send(.post, headers: headers, to: path,
                        beforeSend: { try $0.content.encode(mutated, using: JSONEncoder()) })
                    #expect(try await mismatch.content.decode(V2GroupAvatarCommandResponse.self).outcome == .idempotencyConflict)

                    let remove = try f.command(media: nil, revision: 1)
                    let removed = try await client.send(.post, headers: headers, to: path,
                        beforeSend: { try $0.content.encode(remove, using: JSONEncoder()) })
                    let removedValue = try await removed.content.decode(V2GroupAvatarCommandResponse.self)
                    guard case .committed(let second) = removedValue.outcome else { Issue.record("remove failed"); return }
                    #expect(second.state.revision == 2 && second.state.mediaID == nil)
                    let missing = try f.command(media: .init(uuid: UUID()), revision: 2)
                    let unavailable = try await client.send(.post, headers: headers, to: path,
                        beforeSend: { try $0.content.encode(missing, using: JSONEncoder()) })
                    #expect(unavailable.status == .unprocessableContent)
                    #expect(try await unavailable.content.decode(V2GroupAvatarCommandResponse.self).outcome == .resourceUnavailable)

                    try await f.sql.raw("UPDATE im_v2.room_memberships SET left_revision=0 WHERE room_id=\(bind:f.room.uuidValue!) AND user_id=\(bind:f.owner.uuidValue!)").run()
                    let denied = try await client.send(.post, headers: headers, to: path,
                        beforeSend: { try $0.content.encode(missing, using: JSONEncoder()) })
                    #expect(denied.status == .forbidden)
                    #expect(try await denied.content.decode(V2GroupAvatarCommandResponse.self).outcome == .forbidden)
                    let replay = try await client.send(.post, headers: headers, to: path,
                        beforeSend: { try $0.content.encode(command, using: JSONEncoder()) })
                    #expect(try await replay.content.decode(V2GroupAvatarCommandResponse.self) == receipt)
                    let recoveryPath = URI(string: "v2/rooms/\(f.room.rawValue)/avatar/recovery")
                    let recoverFirst = V2GroupAvatarRecoveryRequest(command: command, action: .closeIfAbsent)
                    let prior = try await client.send(.post, headers: headers, to: recoveryPath,
                        beforeSend: { try $0.content.encode(recoverFirst, using: JSONEncoder()) })
                    #expect(prior.status == .ok && prior.headers[.cacheControl] == "no-store")
                    #expect(try await prior.content.decode(V2GroupAvatarRecoveryResponse.self).result == .committed(first))
                    let close = V2GroupAvatarRecoveryRequest(command: missing, action: .closeIfAbsent)
                    let closed = try await client.send(.post, headers: headers, to: recoveryPath,
                        beforeSend: { try $0.content.encode(close, using: JSONEncoder()) })
                    let proof = try await closed.content.decode(V2GroupAvatarRecoveryResponse.self)
                    #expect(proof.request == close && proof.actorUserID == f.owner && proof.deviceID == device && proof.result == .closed)
                    let late = try await client.send(.post, headers: headers, to: path,
                        beforeSend: { try $0.content.encode(missing, using: JSONEncoder()) })
                    #expect(late.status == .gone)
                    try await controlSQL.raw("UPDATE im_v2.auth_devices SET revoked_at=clock_timestamp() WHERE device_id=\(bind:device.uuidValue!)").run()
                    let revoked = try await client.send(.post, headers: headers, to: path,
                        beforeSend: { try $0.content.encode(command, using: JSONEncoder()) })
                    #expect(revoked.status == .forbidden)
                    #expect(try await f.sql.raw("SELECT count(*) AS value FROM im_v2.resource_group_avatar_operations WHERE room_id=\(bind:f.room.uuidValue!)").first(decoding: AvatarCountRow.self)?.value == 2)
                }
                if separateControl {
                    #expect(try await f.sql.raw("SELECT count(*) AS value FROM im_v2.auth_devices WHERE user_id=\(bind:f.owner.uuidValue!)").first(decoding: AvatarCountRow.self)?.value == 0)
                }
                try await app.shutdown(); try await controlResources.shutdown()
            } catch { try? await app.shutdown(); try? await controlResources.shutdown(); throw error }
        }
    }

    @Test("command admission bounds concurrent work and releases a device slot after failure")
    func commandAdmission() async throws {
        try await withFixture { f in
            let device = try await f.account(on: f.database), command = try f.command(media: nil)
            let gate = AvatarCommandGate()
            let service = V2ResourceGroupAvatarCommandService(controlDatabase: f.database) { _, _, _ in
                await gate.arriveAndWait()
                throw V2RoomCallFailure.outcomeUnknown
            }
            let first = Task { try await service.execute(command, actorUserID: f.owner, deviceID: device) }
            await gate.waitUntilArrived()
            await #expect(throws: V2ResourceProviderError.throttled(retryAfter: 1)) {
                _ = try await service.execute(command, actorUserID: f.owner, deviceID: device)
            }
            await gate.release()
            await #expect(throws: V2RoomCallFailure.outcomeUnknown) { _ = try await first.value }
            await #expect(throws: V2RoomCallFailure.outcomeUnknown) {
                _ = try await service.execute(command, actorUserID: f.owner, deviceID: device)
            }
        }
    }
}

struct AvatarFixture: Sendable {
    let database: any Database; let sql: any SQLDatabase
    let room: RoomID; let owner: UserID; let member: UserID; let now: Date
    let token: V2RoomActivationToken; let lifetime: V2RoomActivationLifetime; let profile: V2CapacityProfile

    static func seed(database: any Database) async throws -> AvatarSeededRoom {
        let sql = try #require(database as? any SQLDatabase)
        let room = RoomID(uuid: UUID()), owner = UserID(uuid: UUID()), member = UserID(uuid: UUID())
        let now = Date(), shard = "avatar-" + UUID().uuidString, lease = UUID()
        // Owner databases need not contain control-domain profiles or auth devices.
        try await sql.raw("INSERT INTO im_v2.rooms(room_id,room_shard_id,capacity_profile_id,capacity_class) VALUES(\(bind:room.uuidValue!),\(bind:shard),'standard','large')").run()
        try await sql.raw("INSERT INTO im_v2.group_rooms(room_id,owner_user_id,title,created_at) VALUES(\(bind:room.uuidValue!),\(bind:owner.uuidValue!),'Avatar test',\(bind:now))").run()
        try await sql.raw("INSERT INTO im_v2.shard_admission_pools(room_shard_id,capacity_profile_id,lease_id,generation,valid_until,command_window_limit) VALUES(\(bind:shard),'standard',\(bind:lease),1,\(bind:now.addingTimeInterval(3_600)),100)").run()
        try await sql.raw("INSERT INTO im_v2.room_admission(room_id,eligible_member_count,command_window_limit,shard_lease_id,shard_lease_generation) VALUES(\(bind:room.uuidValue!),2,100,\(bind:lease),1)").run()
        for (user, role) in [(owner, "owner"), (member, "member")] {
            try await sql.raw("INSERT INTO im_v2.room_memberships(room_id,user_id,role,joined_revision) VALUES(\(bind:room.uuidValue!),\(bind:user.uuidValue!),\(bind:role),0)").run()
        }
        return try .init(database: database, sql: sql, room: room, owner: owner, member: member, now: now,
            dataOwner: .init(shardID: shard, epoch: 0),
            profile: .init(id: "standard", limits: .init(maxEligibleMembers: 100, maxCommandsPerWindow: 100, retryAfterSeconds: 1)))
    }

    func media() async throws -> MediaID {
        let media = MediaID(uuid: UUID()), reference = try V2StoredObjectReference(placementID: UUID(),
            binding: .init(id: "opaque-test-provider", configurationRevision: 7), handle: Data("provider-only-identity".utf8))
        let json = String(decoding: try JSONEncoder().encode(reference), as: UTF8.self), digest = Data(repeating: 7, count: 32)
        try await sql.raw("INSERT INTO im_v2.media_objects(media_id,owner_user_id,content_type,byte_count,state,upload_session_id,expires_at,state_updated_at,created_at) VALUES(\(bind:media.uuidValue!),\(bind:owner.uuidValue!),'image/png',8,'available',\(bind:UUID()),\(bind:now.addingTimeInterval(600)),\(bind:now),\(bind:now))").run()
        try await sql.raw("INSERT INTO im_v2.resource_catalog(media_id,home_kind,home_id,usage_kind,created_at) VALUES(\(bind:media.uuidValue!),'room',\(bind:room.uuidValue!),'group_avatar',\(bind:now))").run()
        try await sql.raw("INSERT INTO im_v2.resource_blob_placements(placement_id,media_id,generation,reference_json,byte_count,sha256,state,verified_at) VALUES(\(bind:reference.placementID),\(bind:media.uuidValue!),1,\(bind:json)::jsonb,8,\(bind:digest),'active',\(bind:now))").run()
        for size in [128, 256] {
            try await sql.raw("INSERT INTO im_v2.resource_variants(media_id,generation,recipe,recipe_version,size,reference_json,byte_count,sha256,state,created_at) VALUES(\(bind:media.uuidValue!),1,'avatar',1,\(bind:size),\(bind:json)::jsonb,8,\(bind:digest),'ready',\(bind:now))").run()
        }
        return media
    }
    func command(media: MediaID?, revision: UInt64 = 0) throws -> V2GroupAvatarCommand {
        try .init(operationID: .init(uuid: UUID()), roomID: room, expectedRevision: revision, mutation: media.map { .set($0) } ?? .remove)
    }
    func apply(_ command: V2GroupAvatarCommand, actor: UserID? = nil) async throws -> V2GroupCapabilitiesOutcome<V2GroupAvatarChange> {
        try await PostgresV2GroupCapabilitiesStore(database: database, activationScope: .init(tokens: [token]))
            .setAvatar(actorUserID: actor ?? owner, command: command, capacityProfile: profile, eventID: .init(uuid: UUID()), now: now)
    }
    func state(_ media: MediaID) async throws -> String? {
        try await sql.raw("SELECT state AS value FROM im_v2.media_objects WHERE media_id=\(bind:media.uuidValue!)").first(decoding: AvatarStringRow.self)?.value
    }
    func account(on control: any Database) async throws -> DeviceID {
        let sql = try #require(control as? any SQLDatabase), device = DeviceID(uuid: UUID())
        let handle = "ga" + owner.rawValue.replacingOccurrences(of: "-", with: "").prefix(24).lowercased()
        try await sql.raw("INSERT INTO im_v2.public_user_profiles(user_id,public_handle,display_name,created_at,updated_at) VALUES(\(bind:owner.uuidValue!),\(bind:handle),'Owner',clock_timestamp(),clock_timestamp())").run()
        try await sql.raw("INSERT INTO im_v2.auth_devices(user_id,device_id,created_at,last_active_at) VALUES(\(bind:owner.uuidValue!),\(bind:device.uuidValue!),clock_timestamp(),clock_timestamp())").run()
        return device
    }
    func insertTerminal(close: Bool, command: V2GroupAvatarCommand, sql: any SQLDatabase) async throws {
        if close {
            try await sql.raw("""
                INSERT INTO im_v2.resource_group_avatar_closures(actor_user_id,operation_id,room_id,requested_media_id,expected_revision,closed_at)
                VALUES(\(bind:owner.uuidValue!),\(bind:command.operationID.uuidValue!),\(bind:room.uuidValue!),NULL,0,clock_timestamp())
                """).run()
        } else {
            try await sql.raw("""
                INSERT INTO im_v2.resource_group_avatar_operations(actor_user_id,operation_id,room_id,requested_media_id,expected_revision,resulting_revision,room_sequence,event_id,created_at)
                VALUES(\(bind:owner.uuidValue!),\(bind:command.operationID.uuidValue!),\(bind:room.uuidValue!),NULL,0,1,1,\(bind:UUID()),clock_timestamp())
                """).run()
        }
    }
}

private struct AvatarStringRow: Decodable { let value: String }
private struct AvatarCountRow: Decodable { let value: Int64 }
private struct AvatarBoolRow: Decodable { let value: Bool }
private struct AvatarPIDRow: Decodable { let pid: Int32 }
private actor AvatarTerminalGate {
    private var pid: Int32?, released = false
    private var heldWaiter: CheckedContinuation<Int32, Never>?, releaseWaiter: CheckedContinuation<Void, Never>?
    func held(_ pid: Int32) { self.pid = pid; heldWaiter?.resume(returning: pid); heldWaiter = nil }
    func waitUntilHeld() async -> Int32 { if let pid { return pid }; return await withCheckedContinuation { heldWaiter = $0 } }
    func waitForRelease() async { if !released { await withCheckedContinuation { releaseWaiter = $0 } } }
    func release() { released = true; releaseWaiter?.resume(); releaseWaiter = nil }
}
private actor AvatarTestRouter: V2RoomShardRouting {
    private var value: V2RoomShardRoute
    init(value: V2RoomShardRoute) { self.value = value }
    func route(for roomID: RoomID) async throws -> V2RoomShardRoute { value }
    func change(_ value: V2RoomShardRoute) { self.value = value }
}
private struct AvatarTestDelivery: V2ResourceDelivery {
    let change: @Sendable () async throws -> Void
    func issue(_ request: V2AuthorizedResourceDelivery) async throws -> V2ResourceTransferPlan {
        try await change()
        return try .init(mode: .httpGet, url: #require(URL(string: "https://independent-cdn.invalid/avatar")),
            expiresAt: request.expiresAt, expectedByteCount: request.facts.byteCount,
            checksum: .init(value: request.facts.sha256.map { String(format: "%02x", $0) }.joined()))
    }
}
private struct AvatarHTTPAuthentication: V2GatewayAuthenticator {
    let user: UserID
    func authenticateSession(accessToken: String, deviceID: DeviceID) async throws -> V2GatewayAuthentication {
        .init(userID: user, expiresAt: nil)
    }
}
private struct AvatarUnusedIdentityReader: V2MembershipIdentitySnapshotValidating {
    func snapshot(actorUserID: UserID, targetUserID: UserID) async throws -> V2MembershipIdentitySnapshot {
        Issue.record("group avatar mutation must not read membership identity snapshots")
        throw V2RoomCallFailure.outcomeUnknown
    }
}
private actor AvatarCommandLostReply {
    private var first = true
    func loseFirst() -> Bool { defer { first = false }; return first }
}
private actor AvatarCommandGate {
    private var arrived = false, released = false
    private var arrival: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func arriveAndWait() async {
        arrived = true; arrival?.resume(); arrival = nil
        if !released { await withCheckedContinuation { releaseWaiter = $0 } }
    }
    func waitUntilArrived() async { if !arrived { await withCheckedContinuation { arrival = $0 } } }
    func release() { released = true; releaseWaiter?.resume(); releaseWaiter = nil }
}

/// Database fixture initialization does not create an Actor or grant authority.
struct AvatarSeededRoom: Sendable {
    let database: any Database
    let sql: any SQLDatabase
    let room: RoomID
    let owner: UserID
    let member: UserID
    let now: Date
    let dataOwner: V2RoomDataOwner
    let profile: V2CapacityProfile

    func withActivation<Value: Sendable>(epoch: Int64 = 0,
        _ body: @escaping @Sendable (AvatarFixture) async throws -> Value) async throws -> Value {
        try await withRoomActivationLifetime(database: database, roomID: room,
                                             shardID: dataOwner.shardID, epoch: epoch) { token, lifetime in
            try await body(.init(database: database, sql: sql, room: room, owner: owner, member: member,
                                 now: now, token: token, lifetime: lifetime, profile: profile))
        }
    }
}

func withAvatarDatabase(_ body: @escaping @Sendable (AvatarSeededRoom) async throws -> Void) async throws {
    let resources = makeV2DatabaseTestResources()
    do {
        resources.databases.use(try .postgres(url: #require(ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"]),
            maxConnectionsPerEventLoop: 4), as: .psql, isDefault: true)
        let seed = try await AvatarFixture.seed(database: resources.database(.psql))
        try await body(seed)
        try await resources.shutdown()
    } catch { try? await resources.shutdown(); throw error }
}
