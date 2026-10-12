@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import HTTPTypes
import IMV2ServerHTTP
import Vapor
import VaporTesting
import IMV2ActorContracts
import IMV2Core
import SQLKit
import Synchronization
import Testing
@testable import IMV2Server
@testable import IMV2ServerInfrastructure

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("member administration authenticated HTTP uses fenced room authority")
    func memberAdministrationHTTP() async throws {
        try await withForwardOwnerDatabases(mode:.standard) { database,_,sql,_,_ in
            let now=Date(timeIntervalSince1970:1_750_000_000),ms:UInt64=1_750_000_000_000
            try await sql.raw("UPDATE im_v2.rooms SET membership_revision=1 WHERE room_id=\(bind:roomUUID)").run()
            try await sql.raw("UPDATE im_v2.room_memberships SET role='owner' WHERE room_id=\(bind:roomUUID) AND user_id=\(bind:senderUUID)").run()
            try await withRoomActivation(database:database,roomID:roomID,shardID:"room-a",epoch:0) { token in
                let executor=try V2RoomAdministrationDomainExecutor(database:database, invitationSecretIssuer: try .init(rawKey: Data(repeating: 0x73, count: 32)), invitationIdentities: PostgresV2GroupInvitationIdentityReader(database: database),token:token,capacityProfile:forwardImportTestProfile(),membershipIdentities:V2PostgresMembershipIdentitySnapshotValidator(database:database),now:{now})
                let client=V2RoomRefAdministrationClient(caller:.init(timeout:.seconds(10),invoke:{ wire,user,_ in
                    guard user==senderID,case .administration(let command)=wire else { throw V2RoomCallFailure.outcomeUnknown }
                    return .administration(try await executor.executeUser(command))
                }))
                let app=try await Application(.testing)
                do {
                    V2VaporMemberAdministrationRoutes(authenticator:MemberAdministrationHTTPAuth(actor:senderID),rooms:client).register(on:app)
                    let intent=try V2MemberAdministrationIntent(roomID:roomID,actorUserID:senderID,operationID:.init(uuid:UUID()),targetUserID:.init(uuid:memberTwoUUID),action:.remove,reasonCode:.init("abuse_spam"),expectedMembershipRevision:1,confirmedUntilMilliseconds:ms+120_000)
                    try await app.testing { http in
                        let admissionResponse=try await http.send(.post,to:URI(string:"v2/rooms/\(roomID.rawValue)/member-administration/admissions"),beforeSend:{ request in
                            request.headers.bearerAuthorization = .init(token:"token");request.headers[HTTPField.Name("X-IM-Device-ID")!]=UUID().uuidString
                            try request.content.encode(intent,using:JSONEncoder())
                        })
                        #expect(admissionResponse.status == .ok && admissionResponse.headers[.cacheControl]=="no-store")
                        guard case .admitted(let context)=try await admissionResponse.content.decode(V2MemberAdministrationAdmissionResult.self) else { throw CancellationError() }
                        let command=try V2MemberAdministrationCommand(intent:intent,admission:context)
                        let response=try await http.send(.post,to:URI(string:"v2/rooms/\(roomID.rawValue)/member-administration/submit"),beforeSend:{ request in
                            request.headers.bearerAuthorization = .init(token:"token");request.headers[HTTPField.Name("X-IM-Device-ID")!]=UUID().uuidString
                            try request.content.encode(command,using:JSONEncoder())
                        })
                        #expect(response.status == .ok && response.headers[.cacheControl]=="no-store")
                        guard case .receipt(let receipt)=try await response.content.decode(V2MemberAdministrationRecoveryResult.self) else { throw CancellationError() }
                        #expect(receipt.validates(command:command))
                        let recovery=try V2MemberAdministrationRecoveryRequest(identity:command.identity,fingerprint:command.fingerprint,action:.query)
                        for (path,status) in [(roomID.rawValue,HTTPResponse.Status.ok),(UUID().uuidString,.forbidden)] {
                            let query=try await http.send(.post,to:URI(string:"v2/rooms/\(path)/member-administration/operations/recover"),beforeSend:{ request in
                                request.headers.bearerAuthorization = .init(token:"token");request.headers[HTTPField.Name("X-IM-Device-ID")!]=UUID().uuidString
                                try request.content.encode(recovery,using:JSONEncoder())
                            })
                            #expect(query.status==status && query.headers[.cacheControl]=="no-store")
                            if status == .ok { #expect(try await query.content.decode(V2MemberAdministrationRecoveryResult.self) == .receipt(receipt)) }
                        }
                    }
                    try await app.shutdown()
                } catch { try? await app.shutdown();throw error }
            }
        }
    }

    @Test("member administration preserves original proof and fixed online admission")
    func memberAdministrationOriginalProof() async throws {
        try await withForwardOwnerDatabases(mode:.standard) { database,_,sql,_,_ in
            let base=Date(timeIntervalSince1970:1_750_000_000)
            let milliseconds=UInt64(base.timeIntervalSince1970*1000)
            let clock=Mutex(base)
            try await sql.raw("UPDATE im_v2.rooms SET membership_revision=1 WHERE room_id=\(bind:roomUUID)").run()
            try await sql.raw("UPDATE im_v2.room_memberships SET role='owner' WHERE room_id=\(bind:roomUUID) AND user_id=\(bind:senderUUID)").run()
            try await withRoomActivation(database:database,roomID:roomID,shardID:"room-a",epoch:0) { token in
                let store=PostgresV2MemberAdministrationStore(database:database,clock:{clock.withLock{$0}})
                func intent(deadline:UInt64=120_000,revision:UInt64=1,action:V2MemberAdministrationAction = .mute(untilMilliseconds:milliseconds+300_000)) throws -> V2MemberAdministrationIntent {
                    try .init(roomID:roomID,actorUserID:senderID,operationID:.init(uuid:UUID()),targetUserID:.init(uuid:memberTwoUUID),action:action,reasonCode:.init("abuse_spam"),expectedMembershipRevision:revision,confirmedUntilMilliseconds:milliseconds+deadline)
                }
                #expect(try await store.admit(intent(deadline:120_001),token:token) == .currentUnavailable(.invalidConfirmationDeadline))
                let frozen=try intent()
                guard case .admitted(let context)=try await store.admit(frozen,token:token) else { throw CancellationError() }
                #expect(context.targetJoinedRevision == 0)
                clock.withLock{$0=base.addingTimeInterval(121)}
                #expect(try await store.admit(frozen,token:token) == .admitted(context))
                let expired=try V2MemberAdministrationCommand(intent:frozen,admission:context)
                guard case .receipt(let rejection)=try await store.submit(expired,token:token,capacityProfile:forwardImportTestProfile(),eventID:.init(uuid:UUID())) else { throw CancellationError() }
                #expect(rejection.outcome == .rejected(.admissionExpired))
                clock.withLock{$0=base}
                let original=try intent()
                guard case .admitted(let admitted)=try await store.admit(original,token:token) else { throw CancellationError() }
                let command=try V2MemberAdministrationCommand(intent:original,admission:admitted)
                guard case .receipt(let receipt)=try await store.submit(command,token:token,capacityProfile:forwardImportTestProfile(),eventID:.init(uuid:UUID())) else { throw CancellationError() }
                guard case .applied(.muted)=receipt.outcome else { throw CancellationError() }
                #expect(receipt.validates(command:command))
                #expect(try await count("im_v2.moderation_operations",on:sql) == 0)
                let noop=try intent()
                guard case .admitted(let noopContext)=try await store.admit(noop,token:token) else { throw CancellationError() }
                let noopCommand=try V2MemberAdministrationCommand(intent:noop,admission:noopContext)
                guard case .receipt(let noopReceipt)=try await store.submit(noopCommand,token:token,capacityProfile:forwardImportTestProfile(),eventID:.init(uuid:UUID())) else { throw CancellationError() }
                #expect(noopReceipt.outcome == .alreadySatisfied(muteUntilMilliseconds:milliseconds+300_000,membershipRevision:1))
                #expect(try await count("im_v2.room_events",on:sql) == 1)
                try await sql.raw("UPDATE im_v2.room_memberships SET left_revision=2 WHERE room_id=\(bind:roomUUID) AND user_id=\(bind:senderUUID)").run()
                try await sql.raw("UPDATE im_v2.rooms SET membership_revision=2 WHERE room_id=\(bind:roomUUID)").run()
                let query=try V2MemberAdministrationRecoveryRequest(identity:command.identity,fingerprint:command.fingerprint,action:.query)
                #expect(try await store.recover(query,token:token) == .receipt(receipt))
                #expect(try await store.submit(command,token:token,capacityProfile:forwardImportTestProfile(),eventID:.init(uuid:UUID())) == .receipt(receipt))
                let fingerprint=try V2OperationFingerprint(version:1,digest:Data(repeating:9,count:32))
                #expect(try await store.recover(.init(identity:command.identity,fingerprint:fingerprint,action:.query),token:token) == .fingerprintConflict)
                await #expect(throws:(any Error).self) { try await sql.raw("DELETE FROM im_v2.member_administration_receipts").run() }
            }
        }
    }

    @Test("member administration outer receipt failure rolls back every domain effect",arguments:[false,true])
    func memberAdministrationAtomicRollback(removal:Bool) async throws {
        try await withForwardOwnerDatabases(mode:.standard) { database,_,sql,_,_ in
            let now=Date(timeIntervalSince1970:1_750_000_000),ms:UInt64=1_750_000_000_000
            try await sql.raw("UPDATE im_v2.rooms SET membership_revision=1 WHERE room_id=\(bind:roomUUID)").run()
            try await sql.raw("UPDATE im_v2.room_memberships SET role='owner' WHERE room_id=\(bind:roomUUID) AND user_id=\(bind:senderUUID)").run()
            try await withRoomActivation(database:database,roomID:roomID,shardID:"room-a",epoch:0) { token in
                let store=PostgresV2MemberAdministrationStore(database:database,clock:{now})
                let intent=try V2MemberAdministrationIntent(roomID:roomID,actorUserID:senderID,operationID:.init(uuid:UUID()),targetUserID:.init(uuid:memberTwoUUID),action:removal ? .remove : .mute(untilMilliseconds:ms+300_000),reasonCode:.init("abuse_spam"),expectedMembershipRevision:1,confirmedUntilMilliseconds:ms+120_000)
                guard case .admitted(let admission)=try await store.admit(intent,token:token) else { throw CancellationError() }
                let command=try V2MemberAdministrationCommand(intent:intent,admission:admission)
                let before=try await sql.raw("SELECT to_jsonb(r)::text AS value FROM im_v2.rooms r WHERE room_id=\(bind:roomUUID)").first(decoding:StringValueRow.self)?.value
                try await sql.raw("CREATE FUNCTION im_v2.fail_member_receipt() RETURNS trigger LANGUAGE plpgsql AS 'BEGIN RAISE EXCEPTION ''forced original receipt failure''; END'").run()
                try await sql.raw("CREATE TRIGGER fail_member_receipt BEFORE INSERT ON im_v2.member_administration_receipts FOR EACH ROW EXECUTE FUNCTION im_v2.fail_member_receipt()").run()
                await #expect(throws:(any Error).self) { _=try await store.submit(command,token:token,capacityProfile:forwardImportTestProfile(),eventID:.init(uuid:UUID())) }
                #expect(try await sql.raw("SELECT to_jsonb(r)::text AS value FROM im_v2.rooms r WHERE room_id=\(bind:roomUUID)").first(decoding:StringValueRow.self)?.value == before)
                for table in ["room_events","moderation_audit_entries","room_member_mutes","member_administration_receipts"] { #expect(try await count("im_v2."+table,on:sql) == 0) }
                #expect(try await sql.raw("SELECT count(*) AS value FROM im_v2.room_memberships WHERE room_id=\(bind:roomUUID) AND left_revision IS NOT NULL").first(decoding:CountRow.self)?.value == 0)
                try await sql.raw("DROP TRIGGER fail_member_receipt ON im_v2.member_administration_receipts").run()
                guard case .receipt(let receipt)=try await store.submit(command,token:token,capacityProfile:forwardImportTestProfile(),eventID:.init(uuid:UUID())) else { throw CancellationError() }
                #expect(receipt.validates(command:command))
                #expect(try await count("im_v2.room_events",on:sql) == 1)
                #expect(try await count("im_v2.moderation_audit_entries",on:sql) == 1)
            }
        }
    }

    @Test("member administration current permission, close races and owner fence")
    func memberAdministrationPermissionAndRace() async throws {
        try await withForwardOwnerDatabases(mode:.standard) { database,_,sql,_,_ in
            let now=Date(timeIntervalSince1970:1_750_000_000),ms:UInt64=1_750_000_000_000
            try await sql.raw("UPDATE im_v2.rooms SET membership_revision=1 WHERE room_id=\(bind:roomUUID)").run()
            try await sql.raw("UPDATE im_v2.room_memberships SET role='owner' WHERE room_id=\(bind:roomUUID) AND user_id=\(bind:senderUUID)").run()
            try await withRoomActivation(database:database,roomID:roomID,shardID:"room-a",epoch:0) { token in
                let store=PostgresV2MemberAdministrationStore(database:database,clock:{now})
                func command() async throws -> V2MemberAdministrationCommand {
                    let intent=try V2MemberAdministrationIntent(roomID:roomID,actorUserID:senderID,operationID:.init(uuid:UUID()),targetUserID:.init(uuid:memberTwoUUID),action:.mute(untilMilliseconds:ms+300_000),reasonCode:.init("abuse_spam"),expectedMembershipRevision:1,confirmedUntilMilliseconds:ms+120_000)
                    guard case .admitted(let admission)=try await store.admit(intent,token:token) else { throw CancellationError() }
                    return try .init(intent:intent,admission:admission)
                }
                let denied=try await command()
                try await sql.raw("UPDATE im_v2.room_memberships SET role='member' WHERE room_id=\(bind:roomUUID) AND user_id=\(bind:senderUUID)").run()
                guard case .receipt(let original)=try await store.submit(denied,token:token,capacityProfile:forwardImportTestProfile(),eventID:.init(uuid:UUID())) else { throw CancellationError() }
                #expect(original.outcome == .rejected(.permissionDenied))
                try await sql.raw("UPDATE im_v2.room_memberships SET role='owner' WHERE room_id=\(bind:roomUUID) AND user_id=\(bind:senderUUID)").run()
                #expect(try await store.submit(denied,token:token,capacityProfile:forwardImportTestProfile(),eventID:.init(uuid:UUID())) == .receipt(original))
                let racing=try await command(),query=try V2MemberAdministrationRecoveryRequest(identity:racing.identity,fingerprint:racing.fingerprint,action:.closeIfAbsent)
                async let submission=store.submit(racing,token:token,capacityProfile:forwardImportTestProfile(),eventID:.init(uuid:UUID()))
                async let closure=store.recover(query,token:token)
                let (submitted,closed)=try await (submission,closure)
                #expect(submitted==closed)
                guard case .receipt(let winner)=submitted else { throw CancellationError() }
                let count=try await count("im_v2.room_events",on:sql)
                if winner.outcome == .closed { #expect(count==0) } else { #expect(count==1 && winner.validates(command:racing)) }
                try await sql.raw("UPDATE im_v2.rooms SET owner_epoch=owner_epoch+1 WHERE room_id=\(bind:roomUUID)").run()
                await #expect(throws: V2RoomActorStateError.ownerChanged) { _=try await store.recover(query,token:token) }
            }
        }
    }

    @Test("member administration close and membership incarnation remain authoritative")
    func memberAdministrationCloseAndIncarnation() async throws {
        try await withForwardOwnerDatabases(mode:.standard) { database,_,sql,_,_ in
            let now=Date(timeIntervalSince1970:1_750_000_000),ms:UInt64=1_750_000_000_000
            try await sql.raw("UPDATE im_v2.rooms SET membership_revision=1 WHERE room_id=\(bind:roomUUID)").run()
            try await sql.raw("UPDATE im_v2.room_memberships SET role='owner' WHERE room_id=\(bind:roomUUID) AND user_id=\(bind:senderUUID)").run()
            try await withRoomActivation(database:database,roomID:roomID,shardID:"room-a",epoch:0) { token in
                let store=PostgresV2MemberAdministrationStore(database:database,clock:{now})
                func command() async throws -> V2MemberAdministrationCommand {
                    let intent=try V2MemberAdministrationIntent(roomID:roomID,actorUserID:senderID,operationID:.init(uuid:UUID()),targetUserID:.init(uuid:memberTwoUUID),action:.remove,reasonCode:.init("abuse_spam"),expectedMembershipRevision:1,confirmedUntilMilliseconds:ms+120_000)
                    guard case .admitted(let admission)=try await store.admit(intent,token:token) else { throw CancellationError() }
                    return try .init(intent:intent,admission:admission)
                }
                let closed=try await command(),stale=try await command()
                let request=try V2MemberAdministrationRecoveryRequest(identity:closed.identity,fingerprint:closed.fingerprint,action:.closeIfAbsent)
                guard case .receipt(let receipt)=try await store.recover(request,token:token) else { throw CancellationError() }
                #expect(receipt.outcome == .closed)
                #expect(try await store.submit(closed,token:token,capacityProfile:forwardImportTestProfile(),eventID:.init(uuid:UUID())) == .receipt(receipt))
                try await sql.raw("UPDATE im_v2.room_memberships SET left_revision=2 WHERE room_id=\(bind:roomUUID) AND user_id=\(bind:memberTwoUUID)").run()
                try await sql.raw("INSERT INTO im_v2.room_memberships(room_id,user_id,joined_revision) VALUES(\(bind:roomUUID),\(bind:memberTwoUUID),3)").run()
                try await sql.raw("UPDATE im_v2.rooms SET membership_revision=3 WHERE room_id=\(bind:roomUUID)").run()
                guard case .receipt(let rejected)=try await store.submit(stale,token:token,capacityProfile:forwardImportTestProfile(),eventID:.init(uuid:UUID())) else { throw CancellationError() }
                #expect(rejected.outcome == .rejected(.membershipChanged(currentRevision:3)))
                #expect(try await count("im_v2.room_events",on:sql) == 0)
            }
        }
    }
}

private struct MemberAdministrationHTTPAuth:V2GatewayAuthenticator {
    let actor:UserID
    func authenticateSession(accessToken:String,deviceID:DeviceID) async throws -> V2GatewayAuthentication { .init(userID:actor,expiresAt:nil) }
}
