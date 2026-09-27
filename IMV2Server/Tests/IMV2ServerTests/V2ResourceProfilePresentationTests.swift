import FluentKit
import FluentPostgresDriver
import Foundation
import IMV2ActorContracts
import IMV2Core
@testable import IMV2Server
import SQLKit
import Testing

@Suite(.serialized)
struct V2ResourceProfilePresentationTests {
    @Test("join-review visibility follows invitation permissions and pending requests without granting member access",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"] != nil),
          arguments: ["owner", "admin-default", "member-default", "admin-empty", "admin-unrelated", "member-grant", "admin-grant"])
    func joinReviewContexts(_ scenario: String) async throws {
        let resources = makeV2DatabaseTestResources()
        var service: V2ResourceProfilePresentationService?
        do {
            resources.databases.use(try .postgres(url: #require(ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"])), as: .psql, isDefault: true)
            let database = resources.database(.psql), sql = try #require(database as? any SQLDatabase)
            let actor = UserID(uuid: UUID()), applicant = UserID(uuid: UUID()), member = UserID(uuid: UUID())
            let device = DeviceID(uuid: UUID()), room = RoomID(uuid: UUID()), invite = UUID(), application = UUID()
            let tokenDigest = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
            let role = scenario.split(separator: "-").first.map(String.init)!
            for user in [actor, applicant, member] { try await seedProfile(user, sql: sql) }
            try await sql.raw("INSERT INTO im_v2.auth_devices(user_id,device_id,created_at,last_active_at) VALUES(\(bind: actor.uuidValue!),\(bind: device.uuidValue!),clock_timestamp(),clock_timestamp())").run()
            try await sql.raw("INSERT INTO im_v2.rooms(room_id,room_kind,room_shard_id,capacity_profile_id,membership_revision) VALUES(\(bind: room.uuidValue!),'group','profile-test','standard',3)").run()
            try await sql.raw("INSERT INTO im_v2.room_memberships(room_id,user_id,joined_revision,role) VALUES(\(bind: room.uuidValue!),\(bind: actor.uuidValue!),0,\(bind: role)),(\(bind: room.uuidValue!),\(bind: member.uuidValue!),0,\(bind: role == "owner" ? "member" : "owner"))").run()
            try await sql.raw("INSERT INTO im_v2.group_rooms(room_id,owner_user_id,title,created_at) VALUES(\(bind: room.uuidValue!),\(bind: role == "owner" ? actor.uuidValue! : member.uuidValue!),'Review fixture',clock_timestamp())").run()
            try await sql.raw("INSERT INTO im_v2.group_invite_links(invite_id,room_id,created_by_user_id,creation_operation_id,token_digest,requested_lifetime_seconds,expires_at,maximum_approved_uses,created_at) VALUES(\(bind: invite),\(bind: room.uuidValue!),\(bind: actor.uuidValue!),\(bind: UUID()),\(bind: tokenDigest),3600,clock_timestamp()+interval '1 hour',100,clock_timestamp())").run()
            try await sql.raw("INSERT INTO im_v2.group_join_requests(request_id,invite_id,room_id,applicant_user_id,submission_operation_id,created_at,updated_at) VALUES(\(bind: application),\(bind: invite),\(bind: room.uuidValue!),\(bind: applicant.uuidValue!),\(bind: UUID()),clock_timestamp(),clock_timestamp())").run()
            if scenario == "admin-empty" {
                try await sql.raw("INSERT INTO im_v2.group_role_policies(room_id,role) VALUES(\(bind: room.uuidValue!),'admin')").run()
            }
            if scenario.hasSuffix("grant") || scenario == "admin-unrelated" {
                try await sql.raw("INSERT INTO im_v2.group_role_permissions(room_id,role,permission) VALUES(\(bind: room.uuidValue!),\(bind: role),\(bind: scenario == "admin-unrelated" ? "send_messages" : "invite_members"))").run()
            }
            let tokens = PostgresV2RoomActivationStore(database: database), identity = try testToken(room)
            guard case .acquired(let lease) = try await tokens.acquire(roomID: room, owner: identity.owner,
                host: identity.host, duration: .init(30_000)) else { throw V2RoomActivationLeaseError.activationChanged }
            let executor = try V2RoomMediaAuthorizationDomainExecutor(database: database, token: lease.token)
            let port = V2ActorRoomMediaAuthorizationPort(query: { request, _ in try await executor.execute(request) })
            let reader = V2ResourceProfilePresentationService(controlDatabase: database, authorization: port,
                avatars: .init(delivery: NoProfileAvatarDelivery()))
            service = reader
            let reviewKey = V2ProfileViewLookupKey(userID: applicant, context: .groupJoinReview(room))
            let applicantMemberKey = V2ProfileViewLookupKey(userID: applicant, context: .room(room))
            let memberKey = V2ProfileViewLookupKey(userID: member, context: .room(room))
            let memberReviewKey = V2ProfileViewLookupKey(userID: member, context: .groupJoinReview(room))
            let allowed = scenario == "owner" || scenario == "admin-default" || scenario.hasSuffix("grant")
            let page = try await reader.read(.init(keys: [reviewKey, applicantMemberKey, memberKey, memberReviewKey]), actorUserID: actor, deviceID: device)
            if allowed {
                guard case .presentation(let value, let avatar) = page.results[0] else { throw V2MediaStoreError.downloadNotAuthorized }
                #expect(value.lease.key == reviewKey && value.groupMember == nil && avatar == nil)
            } else { #expect(page.results[0] == .unavailable(reviewKey)) }
            #expect(page.results[1] == .unavailable(applicantMemberKey))
            guard case .presentation = page.results[2] else { throw V2MediaStoreError.downloadNotAuthorized }
            #expect(page.results[3] == .unavailable(memberReviewKey))
            if scenario == "owner" {
                let request = V2ActorProfileVisibilityBatchWire(roomID: room, actorUserID: actor, roomKind: .groupJoinReview, targetUserIDs: [applicant])
                let deadline = ContinuousClock.now + .seconds(5)
                let proof = try #require(try await port.captureProfiles(request, deadline: deadline))
                try await sql.raw("UPDATE im_v2.rooms SET group_permission_revision=group_permission_revision+1 WHERE room_id=\(bind: room.uuidValue!)").run()
                #expect(try await !port.recheckProfiles(proof, deadline: deadline))
                for (blocker, blocked) in [(actor, applicant), (applicant, actor)] {
                    try await sql.raw("INSERT INTO im_v2.user_blocks(blocker_user_id,blocked_user_id,created_at) VALUES(\(bind: blocker.uuidValue!),\(bind: blocked.uuidValue!),clock_timestamp())").run()
                    let page = try await reader.read(.init(keys: [reviewKey]), actorUserID: actor, deviceID: device)
                    #expect(page.results == [.unavailable(reviewKey)])
                    try await sql.raw("DELETE FROM im_v2.user_blocks WHERE blocker_user_id=\(bind: blocker.uuidValue!) AND blocked_user_id=\(bind: blocked.uuidValue!)").run()
                }
                try await sql.raw("UPDATE im_v2.group_join_requests SET state='cancelled',decided_by_user_id=applicant_user_id,decided_at=clock_timestamp(),updated_at=clock_timestamp() WHERE request_id=\(bind: application)").run()
                let cancelled = try await reader.read(.init(keys: [reviewKey]), actorUserID: actor, deviceID: device)
                #expect(cancelled.results == [.unavailable(reviewKey)])
                try await sql.raw("UPDATE im_v2.auth_devices SET revoked_at=clock_timestamp() WHERE device_id=\(bind: device.uuidValue!)").run()
                await #expect(throws: V2MediaStoreError.downloadNotAuthorized) {
                    _ = try await reader.read(.init(keys: [reviewKey]), actorUserID: actor, deviceID: device)
                }
            }
            await reader.close(); try await resources.shutdown()
        } catch { await service?.close(); try? await resources.shutdown(); throw error }
    }

    @Test("direct chat author lookups distinguish the peer, self, wrong room kind and blocked access",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"] != nil))
    func directChatAuthorContexts() async throws {
        let resources = makeV2DatabaseTestResources()
        var service: V2ResourceProfilePresentationService?
        do {
            resources.databases.use(try .postgres(url: #require(ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"])), as: .psql, isDefault: true)
            let database = resources.database(.psql), sql = try #require(database as? any SQLDatabase)
            let actor = UserID(uuid: UUID()), peer = UserID(uuid: UUID()), stranger = UserID(uuid: UUID())
            let device = DeviceID(uuid: UUID()), room = RoomID(uuid: UUID())
            for user in [actor, peer, stranger] { try await seedProfile(user, sql: sql) }
            try await sql.raw("INSERT INTO im_v2.auth_devices(user_id,device_id,created_at,last_active_at) VALUES(\(bind: actor.uuidValue!),\(bind: device.uuidValue!),clock_timestamp(),clock_timestamp())").run()
            try await sql.raw("INSERT INTO im_v2.rooms(room_id,room_kind,room_shard_id,capacity_profile_id,membership_revision) VALUES(\(bind: room.uuidValue!),'direct','profile-test','standard',3)").run()
            for user in [actor, peer] {
                try await sql.raw("INSERT INTO im_v2.room_memberships(room_id,user_id,joined_revision) VALUES(\(bind: room.uuidValue!),\(bind: user.uuidValue!),0)").run()
            }
            try await sql.raw("""
                INSERT INTO im_v2.direct_room_owner_routes
                    (lower_user_id,higher_user_id,room_id,room_shard_id,created_at,updated_at)
                VALUES(LEAST(\(bind: actor.uuidValue!),\(bind: peer.uuidValue!)),
                       GREATEST(\(bind: actor.uuidValue!),\(bind: peer.uuidValue!)),
                       \(bind: room.uuidValue!),'profile-test',clock_timestamp(),clock_timestamp())
                """).run()
            let tokens = PostgresV2RoomActivationStore(database: database), identity = try testToken(room)
            guard case .acquired(let lease) = try await tokens.acquire(roomID: room, owner: identity.owner,
                host: identity.host, duration: .init(30_000)) else { throw V2RoomActivationLeaseError.activationChanged }
            let executor = try V2RoomMediaAuthorizationDomainExecutor(database: database, token: lease.token)
            let reader = V2ResourceProfilePresentationService(controlDatabase: database,
                authorization: .init(query: { request, _ in try await executor.execute(request) }),
                avatars: .init(delivery: NoProfileAvatarDelivery()))
            service = reader
            let ownKey = V2ProfileViewLookupKey(userID: actor, context: .relationship)
            let peerKey = V2ProfileViewLookupKey(userID: peer, context: .directConversation)
            let strangerKey = V2ProfileViewLookupKey(userID: stranger, context: .directConversation)
            let wrongSelfKey = V2ProfileViewLookupKey(userID: actor, context: .directConversation)
            let page = try await reader.read(.init(keys: [ownKey, peerKey, strangerKey, wrongSelfKey]), actorUserID: actor, deviceID: device)
            for (index, key) in [ownKey, peerKey].enumerated() {
                guard case .presentation(let value, let avatar) = page.results[index] else { throw V2MediaStoreError.downloadNotAuthorized }
                #expect(value.lease.key == key && value.lease.actorUserID == actor && value.lease.deviceID == device)
                #expect(value.view.userID == key.userID && value.groupMember == nil && avatar == nil)
            }
            #expect(page.results[2] == .unavailable(strangerKey))
            #expect(page.results[3] == .unavailable(wrongSelfKey))
            let roomKeys = [actor, peer, stranger].map { V2ProfileViewLookupKey(userID: $0, context: .room(room)) }
            let roomPage = try await reader.read(.init(keys: roomKeys), actorUserID: actor, deviceID: device)
            for index in 0..<2 {
                guard case .presentation(let value, let avatar) = roomPage.results[index] else { throw V2MediaStoreError.downloadNotAuthorized }
                #expect(value.lease.key == roomKeys[index] && value.lease.contextRevision == 3)
                #expect(value.groupMember == nil && avatar == nil)
            }
            #expect(roomPage.results[2] == .unavailable(roomKeys[2]))
            // Generic membership does not relax commands which require a group.
            #expect(try await executor.execute(.profileVisibilityBatch(.init(roomID: room, actorUserID: actor,
                roomKind: .group, targetUserIDs: [peer]))) == .notVisible)
            try await sql.raw("INSERT INTO im_v2.user_blocks(blocker_user_id,blocked_user_id,created_at) VALUES(\(bind: peer.uuidValue!),\(bind: actor.uuidValue!),clock_timestamp())").run()
            let blocked = try await reader.read(.init(keys: [ownKey, peerKey]), actorUserID: actor, deviceID: device)
            guard case .presentation = blocked.results.first else { throw V2MediaStoreError.downloadNotAuthorized }
            #expect(blocked.results.last == .unavailable(peerKey))
            let blockedRoom = try await reader.read(.init(keys: roomKeys), actorUserID: actor, deviceID: device)
            #expect(blockedRoom.results[1] == .unavailable(roomKeys[1]))
            try await sql.raw("DELETE FROM im_v2.user_blocks WHERE blocker_user_id=\(bind: peer.uuidValue!) AND blocked_user_id=\(bind: actor.uuidValue!)").run()
            try await sql.raw("UPDATE im_v2.room_memberships SET left_revision=3 WHERE room_id=\(bind: room.uuidValue!) AND user_id=\(bind: peer.uuidValue!)").run()
            let departed = try await reader.read(.init(keys: [roomKeys[1]]), actorUserID: actor, deviceID: device)
            #expect(departed.results == [.unavailable(roomKeys[1])])
            try await sql.raw("UPDATE im_v2.room_memberships SET left_revision=3 WHERE room_id=\(bind: room.uuidValue!) AND user_id=\(bind: actor.uuidValue!)").run()
            let removedViewer = try await reader.read(.init(keys: [roomKeys[0]]), actorUserID: actor, deviceID: device)
            #expect(removedViewer.results == [.unavailable(roomKeys[0])])
            try await sql.raw("UPDATE im_v2.auth_devices SET revoked_at=clock_timestamp() WHERE device_id=\(bind: device.uuidValue!)").run()
            await #expect(throws: V2MediaStoreError.downloadNotAuthorized) {
                _ = try await reader.read(.init(keys: [ownKey, peerKey]), actorUserID: actor, deviceID: device)
            }
            await reader.close()
            try await resources.shutdown()
        } catch { await service?.close(); try? await resources.shutdown(); throw error }
    }

    @Test("nickname scans share profile admission and shutdown drains noncooperative scans",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"] != nil))
    func nicknameScanAdmission() async throws {
        let resources = makeV2DatabaseTestResources()
        resources.databases.use(try .postgres(url: #require(ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"])), as: .psql, isDefault: true)
        let service = V2ResourceProfilePresentationService(controlDatabase: resources.database(.psql),
            authorization: .init(query: { _, _ in .notVisible }), avatars: .init(delivery: NoProfileAvatarDelivery()))
        let actor = UserID(uuid: UUID()), device = DeviceID(uuid: UUID()), room = RoomID(uuid: UUID())
        let gate = NicknameCandidateGate(), closed = ProfileBatchCallCounter()
        let first = Task { try await service.readGroupNicknames(roomID: room, afterUserID: nil, limit: 1,
            actorUserID: actor, deviceID: device) { await gate.hold(); return .init(values: [], nextCursor: nil) } }
        let second = Task { try await service.readGroupNicknames(roomID: room, afterUserID: nil, limit: 1,
            actorUserID: actor, deviceID: device) { await gate.hold(); return .init(values: [], nextCursor: nil) } }
        var closing: Task<Void, Never>?
        do {
            try await gate.waitForArrivals(2)
            first.cancel()
            // Cancellation alone cannot release a slot while its callback owns I/O.
            await #expect(throws: V2ResourceProviderError.throttled(retryAfter: 1)) {
                _ = try await service.read(.init(keys: [.init(userID: actor, context: .room(room))]), actorUserID: actor, deviceID: device)
            }
            closing = Task { await service.close(); await closed.increment() }
            let deadline = ContinuousClock.now + .seconds(3)
            var stopped = false
            while ContinuousClock.now < deadline && !stopped {
                do {
                    _ = try await service.readGroupNicknames(roomID: room, afterUserID: nil, limit: 1,
                        actorUserID: actor, deviceID: device) {
                        Issue.record("A third scan must not enter"); return .init(values: [], nextCursor: nil)
                    }
                } catch V2ProfileControlBatchError.closed { stopped = true
                } catch V2ResourceProviderError.throttled { try await Task.sleep(for: .milliseconds(1)) }
            }
            try #require(stopped)
            #expect(await closed.count == 0)
            await gate.release()
            await #expect(throws: (any Error).self) { _ = try await first.value }
            await #expect(throws: V2ProfileControlBatchError.closed) { _ = try await second.value }
            await closing?.value
            #expect(await closed.count == 1)
            try await resources.shutdown()
        } catch {
            await gate.release(); _ = await first.result; _ = await second.result
            await service.close(); await closing?.value
            try? await resources.shutdown(); throw error
        }
    }

    @Test("nickname pagination independently authorizes candidates and never returns stale scan content",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"] != nil))
    func authorizedNicknamePagination() async throws {
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: #require(ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"])), as: .psql, isDefault: true)
            let database = resources.database(.psql), sql = try #require(database as? any SQLDatabase)
            let actor = UserID(uuid: UUID()), device = DeviceID(uuid: UUID()), room = RoomID(uuid: UUID())
            let targets = (0..<3).map { _ in UserID(uuid: UUID()) }.sorted { $0.rawValue < $1.rawValue }
            for user in [actor] + targets { try await seedProfile(user, sql: sql) }
            try await sql.raw("INSERT INTO im_v2.auth_devices(user_id,device_id,created_at,last_active_at) VALUES(\(bind: actor.uuidValue!),\(bind: device.uuidValue!),clock_timestamp(),clock_timestamp())").run()
            try await sql.raw("INSERT INTO im_v2.rooms(room_id,room_shard_id,capacity_profile_id,membership_revision) VALUES(\(bind: room.uuidValue!),'profile-test','standard',3)").run()
            for user in [actor] + targets {
                try await sql.raw("INSERT INTO im_v2.room_memberships(room_id,user_id,joined_revision) VALUES(\(bind: room.uuidValue!),\(bind: user.uuidValue!),0)").run()
            }
            try await sql.raw("INSERT INTO im_v2.room_member_nicknames(room_id,user_id,nickname,revision,updated_at) VALUES(\(bind: room.uuidValue!),\(bind: targets[1].uuidValue!),'Current authorized name',2,clock_timestamp())").run()
            try await sql.raw("INSERT INTO im_v2.user_blocks(blocker_user_id,blocked_user_id,created_at) VALUES(\(bind: targets[0].uuidValue!),\(bind: actor.uuidValue!),clock_timestamp())").run()
            try await sql.raw("UPDATE im_v2.room_memberships SET left_revision=3 WHERE room_id=\(bind: room.uuidValue!) AND user_id=\(bind: targets[2].uuidValue!)").run()
            let tokens = PostgresV2RoomActivationStore(database: database), identity = try testToken(room)
            guard case .acquired(let lease) = try await tokens.acquire(roomID: room, owner: identity.owner,
                host: identity.host, duration: .init(30_000)) else { throw V2RoomActivationLeaseError.activationChanged }
            let executor = try V2RoomMediaAuthorizationDomainExecutor(database: database, token: lease.token)
            let service = V2ResourceProfilePresentationService(controlDatabase: database,
                authorization: .init(query: { request, _ in try await executor.execute(request) }),
                avatars: .init(delivery: NoProfileAvatarDelivery()))
            let scanned = V2GroupNicknamePage(values: try targets.map {
                try .init(roomID: room, userID: $0, groupNickname: "Stale scan text must not escape", revision: #require(.init(rawValue: 1)))
            }, nextCursor: targets.last)
            let page = try await service.readGroupNicknames(roomID: room, afterUserID: nil, limit: 3,
                actorUserID: actor, deviceID: device, candidates: { scanned })
            #expect(page.nextCursor == targets.last && page.batch.results.count == 3)
            #expect(page.batch.results[0] == .unavailable(.init(userID: targets[0], context: .room(room))))
            #expect(page.batch.results[2] == .unavailable(.init(userID: targets[2], context: .room(room))))
            guard case .presentation(let value, let avatar) = page.batch.results[1] else { throw V2MediaStoreError.downloadNotAuthorized }
            #expect(value.groupMember?.groupNickname == "Current authorized name" && value.groupMember?.revision.rawValue == 2)
            #expect(value.lease.actorUserID == actor && value.lease.deviceID == device && avatar == nil)
            #expect(!String(decoding: try JSONEncoder().encode(page), as: UTF8.self).contains("Stale scan text"))
            await #expect(throws: V2ProfilePresentationError.corruptPersistenceState) {
                _ = try await service.readGroupNicknames(roomID: room, afterUserID: targets[1], limit: 3,
                    actorUserID: actor, deviceID: device, candidates: { scanned })
            }
            let empty = try await service.readGroupNicknames(roomID: room, afterUserID: targets.last, limit: 3,
                actorUserID: actor, deviceID: device, candidates: { .init(values: [], nextCursor: nil) })
            #expect(empty.batch.results.isEmpty && empty.nextCursor == nil)
            try await sql.raw("UPDATE im_v2.auth_devices SET revoked_at=clock_timestamp() WHERE device_id=\(bind: device.uuidValue!)").run()
            await #expect(throws: V2MediaStoreError.downloadNotAuthorized) {
                _ = try await service.readGroupNicknames(roomID: room, afterUserID: nil, limit: 3,
                    actorUserID: actor, deviceID: device, candidates: { .init(values: [], nextCursor: nil) })
            }
            await service.close()
            try await resources.shutdown()
        } catch { try? await resources.shutdown(); throw error }
    }

    @Test("nickname proofs reject cross-context content and independently recheck their versions")
    func nicknameProofFences() async throws {
        let room = RoomID(uuid: UUID()), actor = UserID(uuid: UUID()), target = UserID(uuid: UUID())
        let request = V2ActorProfileVisibilityBatchWire(roomID: room, actorUserID: actor, roomKind: .group, targetUserIDs: [target])
        let token = try testToken(room), now = Date(), revision = try #require(V2ProfileRevision(rawValue: 1))
        let member = V2ActorGroupMemberPresentationWire(roomID: room, userID: target, groupNickname: "Name", revision: revision)
        func proof(_ members: [V2ActorGroupMemberPresentationWire], request: V2ActorProfileVisibilityBatchWire) -> V2ActorProfileVisibilityBatchSnapshotWire {
            .init(request: request, activation: token, membershipRevision: 3, visibleTargetUserIDs: [target],
                  observedAt: now, activationExpiresAt: now.addingTimeInterval(60), groupMembers: members)
        }
        let snapshot = proof([member], request: request), state = ProfileBatchProofState(.profilesVisible(proof([member], request: request)))
        let port = V2ActorRoomMediaAuthorizationPort { _, _ in await state.value() }
        let deadline = ContinuousClock.now + .seconds(5)
        #expect(try await port.captureProfiles(request, deadline: deadline) == snapshot)
        #expect(try await !port.recheckProfiles(proof([member, member], request: request), deadline: deadline))
        await state.update(.profilesVisible(proof([.init(roomID: room, userID: target, groupNickname: nil,
            revision: try #require(.init(rawValue: 2)))], request: request)))
        #expect(try await !port.recheckProfiles(snapshot, deadline: deadline))
        for members in [[member, member],
            [.init(roomID: .init(uuid: UUID()), userID: target, groupNickname: "Name", revision: revision)],
            [.init(roomID: room, userID: .init(uuid: UUID()), groupNickname: "Name", revision: revision)],
            [.init(roomID: room, userID: target, groupNickname: "  Name  ", revision: revision)]] {
            await state.update(.profilesVisible(proof(members, request: request)))
            await #expect(throws: V2RoomCallFailure.notAccepted(.invalidRequest)) {
                _ = try await port.captureProfiles(request, deadline: deadline)
            }
        }
        let direct = V2ActorProfileVisibilityBatchWire(roomID: room, actorUserID: actor, roomKind: .direct, targetUserIDs: [target])
        await state.update(.profilesVisible(proof([member], request: direct)))
        await #expect(throws: V2RoomCallFailure.notAccepted(.invalidRequest)) { _ = try await port.captureProfiles(direct, deadline: deadline) }
    }

    @Test("profile port rejects unrelated targets and a changed membership fence")
    func profilePortFences() async throws {
        let room = RoomID(uuid: UUID()), actor = UserID(uuid: UUID()), target = UserID(uuid: UUID())
        let request = V2ActorProfileVisibilityBatchWire(roomID: room, actorUserID: actor, roomKind: .group, targetUserIDs: [target])
        let token = try testToken(room)
        let now = Date()
        let snapshot = V2ActorProfileVisibilityBatchSnapshotWire(request: request, activation: token,
            membershipRevision: 3, visibleTargetUserIDs: [target], observedAt: now, activationExpiresAt: now.addingTimeInterval(60))
        let state = ProfileBatchProofState(.profilesVisible(snapshot))
        let port = V2ActorRoomMediaAuthorizationPort { _, _ in await state.value() }
        let deadline = ContinuousClock.now + .seconds(5)
        #expect(try await port.captureProfiles(request, deadline: deadline) == snapshot)
        await state.update(.profilesVisible(.init(request: request, activation: token, membershipRevision: 4,
            visibleTargetUserIDs: [target], observedAt: now, activationExpiresAt: now.addingTimeInterval(60))))
        #expect(try await !port.recheckProfiles(snapshot, deadline: deadline))
        await state.update(.profilesVisible(.init(request: request, activation: token, membershipRevision: 3,
            visibleTargetUserIDs: [UserID(uuid: UUID())], observedAt: now, activationExpiresAt: now.addingTimeInterval(60))))
        await #expect(throws: (any Error).self) { _ = try await port.captureProfiles(request, deadline: deadline) }
    }

    @Test("100 room keys share two Actor calls; context, block and device revocation remain isolated",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"] != nil))
    func batchedAuthorityAndControlFences() async throws {
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: #require(ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"])), as: .psql, isDefault: true)
            let database = resources.database(.psql)
            let sql = try #require(database as? any SQLDatabase)
            let actor = UserID(uuid: UUID()), device = DeviceID(uuid: UUID()), room = RoomID(uuid: UUID())
            let targets = (0..<100).map { _ in UserID(uuid: UUID()) }
            for user in [actor] + targets { try await seedProfile(user, sql: sql) }
            try await sql.raw("""
                INSERT INTO im_v2.auth_devices(user_id, device_id, created_at, last_active_at)
                VALUES (\(bind: actor.uuidValue!), \(bind: device.uuidValue!), clock_timestamp(), clock_timestamp())
                """).run()
            let token = try testToken(room), state = ProfileBatchCallCounter()
            let authorization = V2ActorRoomMediaAuthorizationPort { query, _ in
                guard case .profileVisibilityBatch(let request) = query else { return .notVisible }
                await state.increment()
                let now = Date()
                return .profilesVisible(.init(request: request, activation: token, membershipRevision: 3,
                    visibleTargetUserIDs: request.targetUserIDs, observedAt: now, activationExpiresAt: now.addingTimeInterval(60)))
            }
            let service = V2ResourceProfilePresentationService(controlDatabase: database, authorization: authorization,
                avatars: .init(delivery: NoProfileAvatarDelivery()))
            let request = try V2ProfilePresentationBatchRequest(keys: targets.map { .init(userID: $0, context: .room(room)) })
            let result = try await service.read(request, actorUserID: actor, deviceID: device)
            #expect(await state.count == 2)
            #expect(result.results.count == 100)
            for entry in result.results {
                guard case .presentation(let value, let avatar) = entry else { Issue.record("Expected authorized room presentation"); continue }
                #expect(value.lease.actorUserID == actor && value.lease.deviceID == device)
                #expect(value.lease.contextRevision == 3 && avatar == nil)
            }
            let target = try #require(targets.first)
            let relationship = V2ProfileViewLookupKey(userID: target, context: .relationship)
            let roomKey = V2ProfileViewLookupKey(userID: target, context: .room(room))
            let scoped = try await service.read(.init(keys: [relationship, roomKey]), actorUserID: actor, deviceID: device)
            #expect(scoped.results.first == .unavailable(relationship))
            guard case .presentation = scoped.results.last else { throw V2MediaStoreError.downloadNotAuthorized }
            try await sql.raw("""
                INSERT INTO im_v2.user_blocks(blocker_user_id, blocked_user_id, created_at)
                VALUES (\(bind: target.uuidValue!), \(bind: actor.uuidValue!), clock_timestamp())
                """).run()
            let blocked = try await service.read(.init(keys: [roomKey]), actorUserID: actor, deviceID: device)
            #expect(blocked.results == [.unavailable(roomKey)])
            try await sql.raw("UPDATE im_v2.auth_devices SET revoked_at = clock_timestamp() WHERE device_id = \(bind: device.uuidValue!)").run()
            await #expect(throws: V2MediaStoreError.downloadNotAuthorized) {
                _ = try await service.read(request, actorUserID: actor, deviceID: device)
            }
            try await resources.shutdown()
        } catch { try? await resources.shutdown(); throw error }
    }

    @Test("room executor returns current members only and rejects a released activation",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"] != nil))
    func authoritativeRoomVisibility() async throws {
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: #require(ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"])), as: .psql, isDefault: true)
            let database = resources.database(.psql), sql = try #require(database as? any SQLDatabase)
            let room = RoomID(uuid: UUID()), actor = UserID(uuid: UUID()), target = UserID(uuid: UUID()), departed = UserID(uuid: UUID())
            try await sql.raw("INSERT INTO im_v2.rooms(room_id, room_shard_id, capacity_profile_id, membership_revision) VALUES (\(bind: room.uuidValue!), 'profile-test', 'standard', 3)").run()
            for user in [actor, target] {
                try await sql.raw("INSERT INTO im_v2.room_memberships(room_id,user_id,joined_revision) VALUES (\(bind: room.uuidValue!),\(bind: user.uuidValue!),0)").run()
            }
            try await sql.raw("INSERT INTO im_v2.room_memberships(room_id,user_id,joined_revision,left_revision) VALUES (\(bind: room.uuidValue!),\(bind: departed.uuidValue!),0,3)").run()
            let leases = PostgresV2RoomActivationStore(database: database)
            let token = try testToken(room)
            guard case .acquired(let grant) = try await leases.acquire(roomID: room, owner: token.owner, host: token.host, duration: .init(30_000))
            else { throw V2RoomActivationLeaseError.activationChanged }
            let executor = try V2RoomMediaAuthorizationDomainExecutor(database: database, token: grant.token)
            let request = V2ActorProfileVisibilityBatchWire(roomID: room, actorUserID: actor, roomKind: .group, targetUserIDs: [target, departed])
            guard case .profilesVisible(let snapshot) = try await executor.execute(.profileVisibilityBatch(request))
            else { throw V2MediaStoreError.downloadNotAuthorized }
            #expect(snapshot.visibleTargetUserIDs == [target])
            #expect(snapshot.membershipRevision == 3)
            #expect(try await leases.release(token: grant.token))
            await #expect(throws: V2RoomActivationLeaseError.activationChanged) { _ = try await executor.execute(.profileVisibilityBatch(request)) }
            try await resources.shutdown()
        } catch { try? await resources.shutdown(); throw error }
    }

    private func testToken(_ room: RoomID) throws -> V2RoomActivationToken {
        try .init(roomID: room, owner: .init(shardID: "profile-test", epoch: 0), activationEpoch: .init(1),
                  host: .init(hostID: .init("profile-host"), incarnationID: UUID()))
    }

    @Test("provider signing cannot hide a concurrent device, block, profile or membership change",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"] != nil),
          arguments: ["unchanged", "device", "block", "profile", "membership", "nickname", "nicknameCleared", "nicknameInserted"])
    func authorityChangesDuringSigning(scenario: String) async throws {
        let resources = makeV2DatabaseTestResources()
        do {
            resources.databases.use(try .postgres(url: #require(ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"])), as: .psql, isDefault: true)
            let database = resources.database(.psql), sql = try #require(database as? any SQLDatabase)
            let actor = UserID(uuid: UUID()), target = UserID(uuid: UUID()), device = DeviceID(uuid: UUID())
            let room = RoomID(uuid: UUID()), media = MediaID(uuid: UUID()), now = Date()
            for user in [actor, target] { try await seedProfile(user, sql: sql) }
            try await sql.raw("INSERT INTO im_v2.auth_devices(user_id,device_id,created_at,last_active_at) VALUES(\(bind:actor.uuidValue!),\(bind:device.uuidValue!),clock_timestamp(),clock_timestamp())").run()
            try await sql.raw("INSERT INTO im_v2.media_objects(media_id,owner_user_id,content_type,byte_count,state,upload_session_id,expires_at,state_updated_at,created_at) VALUES(\(bind:media.uuidValue!),\(bind:target.uuidValue!),'image/png',8,'available',\(bind:UUID()),\(bind:now.addingTimeInterval(600)),\(bind:now),\(bind:now))").run()
            try await sql.raw("INSERT INTO im_v2.resource_catalog(media_id,home_kind,home_id,usage_kind,created_at) VALUES(\(bind:media.uuidValue!),'account',\(bind:target.uuidValue!),'user_avatar',\(bind:now))").run()
            try await sql.raw("UPDATE im_v2.public_user_profiles SET avatar_media_id=\(bind:media.uuidValue!) WHERE user_id=\(bind:target.uuidValue!)").run()
            let reference = try V2StoredObjectReference(placementID: UUID(), binding: .init(id: "external-adapter", configurationRevision: 3), handle: Data([1]))
            let json = String(decoding: try JSONEncoder().encode(reference), as: UTF8.self)
            try await sql.raw("INSERT INTO im_v2.resource_variants(media_id,generation,recipe,recipe_version,size,reference_json,byte_count,sha256,state,created_at) VALUES(\(bind:media.uuidValue!),1,'avatar',1,128,\(bind:json)::jsonb,8,\(bind:Data(repeating: 1, count: 32)),'ready',\(bind:now))").run()
            let token = try testToken(room)
            let query = V2ActorProfileVisibilityBatchWire(roomID: room, actorUserID: actor, roomKind: .memberRoom, targetUserIDs: [target])
            let member = V2ActorGroupMemberPresentationWire(roomID: room, userID: target, groupNickname: "Before",
                revision: try #require(.init(rawValue: 1)))
            let proof = ProfileBatchProofState(.profilesVisible(.init(request: query, activation: token,
                membershipRevision: 1, visibleTargetUserIDs: [target], observedAt: now, activationExpiresAt: now.addingTimeInterval(60),
                groupMembers: scenario == "nicknameInserted" ? [] : [member])))
            let service = V2ResourceProfilePresentationService(controlDatabase: database,
                authorization: .init(query: { _, _ in await proof.value() }),
                avatars: .init(delivery: ChangingProfileAvatarDelivery {
                    switch scenario {
                    case "device": try await sql.raw("UPDATE im_v2.auth_devices SET revoked_at=clock_timestamp() WHERE device_id=\(bind:device.uuidValue!)").run()
                    case "block": try await sql.raw("INSERT INTO im_v2.user_blocks(blocker_user_id,blocked_user_id,created_at) VALUES(\(bind:target.uuidValue!),\(bind:actor.uuidValue!),clock_timestamp())").run()
                    case "profile": try await sql.raw("UPDATE im_v2.public_user_profiles SET revision=revision+1 WHERE user_id=\(bind:target.uuidValue!)").run()
                    case "membership": await proof.update(.notVisible)
                    case "nickname", "nicknameCleared", "nicknameInserted":
                        let changed = V2ActorGroupMemberPresentationWire(roomID: room, userID: target,
                            groupNickname: scenario == "nicknameCleared" ? nil : "After", revision: try #require(.init(rawValue: 2)))
                        await proof.update(.profilesVisible(.init(request: query, activation: token, membershipRevision: 1,
                            visibleTargetUserIDs: [target], observedAt: now, activationExpiresAt: now.addingTimeInterval(60), groupMembers: [changed])))
                    default: break
                    }
                }))
            let key = V2ProfileViewLookupKey(userID: target, context: .room(room))
            let request = try V2ProfilePresentationBatchRequest(keys: [key])
            if scenario == "device" {
                await #expect(throws: V2MediaStoreError.downloadNotAuthorized) {
                    _ = try await service.read(request, actorUserID: actor, deviceID: device)
                }
            } else {
                let result = try await service.read(request, actorUserID: actor, deviceID: device)
                if scenario == "unchanged" {
                    guard case .presentation(let value, let access) = result.results.first else { throw V2MediaStoreError.downloadNotAuthorized }
                    #expect(access?.mediaID == media)
                    #expect(value.groupMember?.groupNickname == "Before")
                } else { #expect(result.results == [.retryable(key)]) }
            }
            try await resources.shutdown()
        } catch { try? await resources.shutdown(); throw error }
    }
    @Test("runtime delivers SQL-backed profile proofs and rechecks a later block despite its compression hint",
          .enabled(if: ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"] != nil))
    func runtimeUsesAuthoritativeReader() async throws {
        let resources = makeV2DatabaseTestResources()
        var runtime: V2AuthorPresentationRuntime?
        do {
            resources.databases.use(try .postgres(url: #require(ProcessInfo.processInfo.environment["IMV2_RESOURCE_TEST_DATABASE_URL"])), as: .psql, isDefault: true)
            let database = resources.database(.psql), sql = try #require(database as? any SQLDatabase)
            let actor = UserID(uuid: UUID()), target = UserID(uuid: UUID()), device = DeviceID(uuid: UUID()), room = RoomID(uuid: UUID())
            for user in [actor, target] { try await seedProfile(user, sql: sql) }
            try await sql.raw("INSERT INTO im_v2.auth_devices(user_id,device_id,created_at,last_active_at) VALUES(\(bind:actor.uuidValue!),\(bind:device.uuidValue!),clock_timestamp(),clock_timestamp())").run()
            let token = try testToken(room)
            let service = V2ResourceProfilePresentationService(controlDatabase: database,
                authorization: .init { query, _ in
                    guard case .profileVisibilityBatch(let request) = query else { return .notVisible }
                    let now = Date()
                    return .profilesVisible(.init(request: request, activation: token, membershipRevision: 3,
                        visibleTargetUserIDs: request.targetUserIDs, observedAt: now, activationExpiresAt: now.addingTimeInterval(60)))
                }, avatars: .init(delivery: NoProfileAvatarDelivery()))
            let owner = V2AuthorPresentationRuntime(configuration: try .init(mergeDelay: .zero), ingressConfiguration: try .init(),
                read: { request, identity in try await service.read(request, actorUserID: identity.userID, deviceID: identity.deviceID) },
                closeReader: { await service.close() })
            runtime = owner
            let output = RuntimeProfileOutput(), connection = UUID(), stream = UUID(), view = UUID()
            _ = try await owner.dispatcher.register(connectionID: connection,
                identity: .init(userID: actor, deviceID: device, capabilityProfile: "base"), streamID: stream,
                send: { bytes, _ in await output.append(bytes); return true })
            #expect(await owner.dispatcher.activateView(connectionID: connection, roomID: room, viewID: view))
            #expect(owner.ingress.submit(connectionID: connection, roomID: room, viewID: view, authors: [target]))
            let first = try V2AuthorPresentationDelta.decode(await output.waitFor(1))
            #expect(first.actorUserID == actor && first.deviceID == device && first.streamID == stream && first.viewID == view)
            guard case .presentation(let presentation, _) = first.batch.results.first else { throw V2MediaStoreError.downloadNotAuthorized }
            #expect(presentation.view.userID == target && presentation.lease.contextRevision == 3)
            let writeDeadline = ContinuousClock.now + .seconds(5)
            while await owner.dispatcher.statistics().writing != 0 {
                guard .now < writeDeadline else { throw CancellationError() }
                try await Task.sleep(for: .milliseconds(1))
            }
            try await sql.raw("INSERT INTO im_v2.user_blocks(blocker_user_id,blocked_user_id,created_at) VALUES(\(bind:target.uuidValue!),\(bind:actor.uuidValue!),clock_timestamp())").run()
            #expect(owner.ingress.submit(connectionID: connection, roomID: room, viewID: view, authors: [target]))
            let second = try V2AuthorPresentationDelta.decode(await output.waitFor(2))
            #expect(second.sequence > first.sequence)
            #expect(second.batch.results == [.unavailable(.init(userID: target, context: .room(room)))])
            await owner.close()
            try await resources.shutdown()
        } catch {
            await runtime?.close(); try? await resources.shutdown(); throw error
        }
    }

    private func seedProfile(_ user: UserID, sql: any SQLDatabase) async throws {
        let handle = "t_" + user.rawValue.replacingOccurrences(of: "-", with: "").prefix(24).lowercased()
        try await sql.raw("""
            INSERT INTO im_v2.public_user_profiles(user_id, public_handle, display_name, created_at, updated_at)
            VALUES (\(bind: user.uuidValue!), \(bind: handle), 'Test name', clock_timestamp(), clock_timestamp())
            """).run()
    }
}

private actor RuntimeProfileOutput {
    var frames: [Data] = []
    func append(_ frame: Data) { frames.append(frame) }
    func waitFor(_ count: Int) async throws -> Data {
        let deadline = ContinuousClock.now + .seconds(5)
        while frames.count < count {
            guard .now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(1))
        }
        return frames[count - 1]
    }
}

private struct NoProfileAvatarDelivery: V2ResourceDelivery {
    func issue(_ request: V2AuthorizedResourceDelivery) async throws -> V2ResourceTransferPlan {
        Issue.record("No media exists in this fixture; delivery must not be invoked")
        throw V2ResourceProviderError.notFound
    }
}
private struct ChangingProfileAvatarDelivery: V2ResourceDelivery {
    let change: @Sendable () async throws -> Void
    func issue(_ request: V2AuthorizedResourceDelivery) async throws -> V2ResourceTransferPlan {
        try await change()
        return try .init(mode: .httpGet, url: #require(URL(string: "https://cdn.invalid/object")),
            expiresAt: request.expiresAt, expectedByteCount: request.facts.byteCount,
            checksum: .init(value: request.facts.sha256.map { String(format: "%02x", $0) }.joined()))
    }
}
private actor ProfileBatchProofState {
    private var result: V2RoomMediaAuthorizationResult
    init(_ result: V2RoomMediaAuthorizationResult) { self.result = result }
    func value() -> V2RoomMediaAuthorizationResult { result }
    func update(_ result: V2RoomMediaAuthorizationResult) { self.result = result }
}
private actor ProfileBatchCallCounter {
    var count = 0
    func increment() { count += 1 }
}

private actor NicknameCandidateGate {
    private var arrivals = 0
    private var opened = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func hold() async {
        arrivals += 1
        if !opened { await withCheckedContinuation { waiting.append($0) } }
    }
    func waitForArrivals(_ count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while arrivals < count {
            guard ContinuousClock.now < deadline else { throw V2ProfileControlBatchError.deadlineExceeded }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    func release() { opened = true; for item in waiting { item.resume() }; waiting.removeAll() }
}
