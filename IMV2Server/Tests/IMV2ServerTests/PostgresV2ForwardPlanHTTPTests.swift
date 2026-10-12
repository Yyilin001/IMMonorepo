@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import HTTPTypes
import IMV2ActorContracts
import IMV2Core
import Synchronization
import IMV2ServerHTTP
import SQLKit
import Testing
import Vapor
import VaporTesting
@testable import IMV2Server
@testable import IMV2ServerInfrastructure

extension PostgresV2RoomWriteStoreIntegrationTests {
    @Test("account forward HTTP recovers original target proof across worker restart and closes only unexported pairs")
    func forwardPlanHTTPAndOwnerRecovery() async throws {
        try await withForwardOwnerDatabases(mode:.standard) { sourceDB,targetDB,sourceSQL,targetSQL,targetRoom in
            let now=Date(),profile=try forwardImportTestProfile(),limits=try V2MessageCommandLimits(maxUTF8Bytes:64)
            for sql in [sourceSQL,targetSQL] {
                try await sql.raw("UPDATE im_v2.shard_admission_pools SET valid_until=\(bind: now.addingTimeInterval(600))").run()
            }
            guard case .accepted(let sourceMessage)=try await V2SendMessageService(store:V2PolicyAuthorizedTestWriteStore(database:sourceDB,controlDatabase:sourceDB,
                store:PostgresV2RoomWriteStore(database:sourceDB),shardID:"room-a",epoch:0),capacityProfile:profile,limits:limits,now:{now}).send(.init(roomID:roomID,actorUserID:senderID,clientMessageID:.init(uuid:UUID()),text:"forward durable source")) else { throw CancellationError() }
            try await withRoomActivations(database: sourceDB, owners: [
                roomID: .init(shardID: "room-a", epoch: 0), targetRoom: .init(shardID: "room-b", epoch: 0)
            ]) { tokens in
                let sourceToken = try #require(tokens.first { $0.roomID == roomID })
                let targetToken = try #require(tokens.first { $0.roomID == targetRoom })
                let sourceExecutor=try V2RoomForwardDomainExecutor(database:sourceDB,token:sourceToken,write:.init(database:sourceDB),capacityProfile:profile,limits:limits,now:{now})
                try await withFixturePolicyOwners(database: sourceDB, projectionDelivery: SuccessfulProjectionDelivery()) { owners in
                    let policies = V2RoomPolicyAuthorizationService(roomDatabase: targetDB,
                        policyOwners: owners, endpoint: "forward-plan-target", maximumRooms: 1)
                    do {
                let targetExecutor=try V2RoomForwardDomainExecutor(database:targetDB,token:targetToken,write:PostgresV2RoomWriteStore(database:targetDB).usingControlDatabase(sourceDB).usingPolicyAuthorizations(policies),capacityProfile:profile,limits:limits,now:{now})
                let loseFirstTargetACK=Mutex(true)
                let port=V2OwnerAwareForwardPlanPort(router:ForwardPlanTestRouter(target:targetRoom),execute:{ command,_ in
                    if command.roomID==roomID { return try await sourceExecutor.execute(command) }
                    guard command.roomID==targetRoom else { throw V2RoomCallFailure.notAccepted(.invalidRequest) }
                    let result=try await targetExecutor.execute(command)
                    if loseFirstTargetACK.withLock({ value in let old=value;value=false;return old }) { throw V2RoomCallFailure.outcomeUnknown }
                    return result
                })
                let store=PostgresV2ForwardPlanStore(database:sourceDB,clock:{now})
                let service=V2ForwardPlanService(store:store,port:port,clock:{now})
                func frozen(revision:UInt64=1) throws -> V2ForwardPlanOperationCommand {
                    try .init(actorUserID:senderID,command:.init(operationID:.init(uuid:UUID()),sources:[.init(roomID:roomID,messageID:sourceMessage.messageID,revision:.init(revision))],targetRoomIDs:[targetRoom]),firstSubmissionDeadlineMilliseconds:UInt64(now.timeIntervalSince1970*1000)+60_000)
                }
                let command=try frozen(),app=try await Application(.testing)
                do {
                    V2VaporForwardPlanRoutes(authenticator:ForwardPlanRouteAuth(actor:senderID),service:service).register(on:app)
                    try await app.testing { http in
                        let submit=try await http.send(.post,to:"v2/forward-plans/submit",beforeSend:{ request in
                            request.headers.bearerAuthorization = .init(token:"token");request.headers[HTTPField.Name("X-IM-Device-ID")!]=UUID().uuidString
                            try request.content.encode(command,using:JSONEncoder())
                        })
                        #expect(submit.status == .ok && submit.headers[.cacheControl]=="no-store")
                        guard case .processing(let progress)=try await submit.content.decode(V2ForwardPlanRecoveryResult.self) else { throw CancellationError() }
                        #expect(progress.executionState == .waitingToStart)
                    }
                    try await service.runOnce()
                    // A new process reconciles immutable receipts; it does not recreate child IDs.
                    let restarted=V2ForwardPlanService(store:.init(database:sourceDB,clock:{now}),port:port,clock:{now})
                    try await restarted.advance(command)
                    guard case .receipt(let original)=try await restarted.recover(.init(command:command,action:.query)) else { throw CancellationError() }
                    #expect(original.validates(command:command))
                    try await app.testing { http in
                        let reply=try await http.send(.post,to:"v2/forward-plans/operations/recover",beforeSend:{request in
                            request.headers.bearerAuthorization = .init(token:"token");request.headers[HTTPField.Name("X-IM-Device-ID")!]=UUID().uuidString
                            try request.content.encode(V2ForwardPlanRecoveryRequest(command:command,action:.query),using:JSONEncoder())
                        })
                        #expect(reply.status == .ok && reply.headers[.cacheControl]=="no-store")
                        #expect(try await reply.content.decode(V2ForwardPlanRecoveryResult.self) == .receipt(original))
                        let other=try V2ForwardPlanOperationCommand(actorUserID:.init(uuid:UUID()),command:command.command,firstSubmissionDeadlineMilliseconds:command.firstSubmissionDeadlineMilliseconds)
                        let rejected=try await http.send(.post,to:"v2/forward-plans/submit",beforeSend:{request in
                            request.headers.bearerAuthorization = .init(token:"token");request.headers[HTTPField.Name("X-IM-Device-ID")!]=UUID().uuidString
                            try request.content.encode(other,using:JSONEncoder())
                        })
                        #expect(rejected.status == .forbidden && rejected.headers[.cacheControl]=="no-store")
                    }
                    let targetCount=try await targetSQL.raw("SELECT count(*)::bigint AS count FROM im_v2.messages").first(decoding:ForwardPlanRowCount.self)
                    #expect(targetCount?.count==1)
                    try await sourceSQL.raw("UPDATE im_v2.room_memberships SET left_revision=2 WHERE room_id=\(bind:roomUUID) AND user_id=\(bind:senderUUID)").run()
                    try await sourceSQL.raw("UPDATE im_v2.rooms SET membership_revision=2 WHERE room_id=\(bind:roomUUID)").run()
                    #expect(try await restarted.recover(.init(command:command,action:.query)) == .receipt(original))
                    let absent=try frozen()
                    _=try await service.submit(absent);_=try await store.claimNext(absent)
                    _=try await service.recover(.init(command:absent,action:.cancelRemaining))
                    try await restarted.advance(absent)
                    guard case .receipt(let cancelled)=try await service.recover(.init(command:absent,action:.query)),case .resolved(let child)=cancelled.progress.children[0].state,case .completed(let pairs)=child.outcome else { throw CancellationError() }
                    #expect(pairs[0].outcome == .rejected(.closedBeforeExecution))
                    #expect(try await targetSQL.raw("SELECT count(*)::bigint AS count FROM im_v2.messages").first(decoding:ForwardPlanRowCount.self)?.count==1)
                    let bad=try frozen(revision:2)
                    _=try await service.submit(bad);try await restarted.advance(bad)
                    guard case .receipt(let rejection)=try await service.recover(.init(command:bad,action:.query)) else { throw CancellationError() }
                    #expect(rejection.validates(command:bad))
                    // owner-fencing still applies even when original source proof exists.
                    try await sourceSQL.raw("UPDATE im_v2.rooms SET owner_epoch=owner_epoch+1 WHERE room_id=\(bind:roomUUID)").run()
                    await #expect(throws:(any Error).self) { _=try await sourceExecutor.execute(.recoverExport(.init(actorUserID:senderID,operationID:command.childCommand(index:0).operationID,source:command.command.sources[0],targetRoomID:targetRoom),action:.query)) }
                    try await app.shutdown()
                } catch { try? await app.shutdown();throw error }
                        await policies.shutdown()
                    } catch {
                        await policies.shutdown()
                        throw error
                    }
                }
            }
        }
    }
}
private struct ForwardPlanTestRouter:V2RoomShardRouting {
    let target:RoomID
    func route(for roomID:RoomID) async throws -> V2RoomShardRoute { try .init(shardID:roomID==target ? "room-b":"room-a",epoch:0) }
}
private struct ForwardPlanRouteAuth:V2GatewayAuthenticator {
    let actor:UserID
    func authenticateSession(accessToken:String,deviceID:DeviceID) async throws -> V2GatewayAuthentication { .init(userID:actor,expiresAt:nil) }
}
private struct ForwardPlanRowCount:Decodable { let count:Int64 }
