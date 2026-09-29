@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import HTTPTypes
import IMV2ActorContracts
import IMV2Core
import IMV2ServerHTTP
import Testing
import Vapor
import VaporTesting
@testable import IMV2Server
@testable import IMV2ServerInfrastructure

struct V2VaporMessageOperationRoutesTests {
    @Test("typed message HTTP operations bind actor room and original receipt")
    func scopedOperations() async throws {
        let app=try await Application(.testing),actor=UserID(uuid:UUID()),room=RoomID(uuid:UUID()),message=MessageID(uuid:UUID())
        let send=try V2MessageSendOperationCommand(command:.init(roomID:room,senderUserID:actor,clientMessageID:.init(uuid:UUID()),text:"Original",limits:.init(maxUTF8Bytes:64)),firstSubmissionDeadlineMilliseconds:1000)
        let limited=try V2MessageSendOperationCommand(command:.init(roomID:room,senderUserID:actor,clientMessageID:.init(uuid:UUID()),text:"Rate",limits:.init(maxUTF8Bytes:64)),firstSubmissionDeadlineMilliseconds:1000)
        let rateHint=try V2MessageOperationRetryHint(identity:limited.identity,fingerprint:limited.fingerprint,reason:.rateLimited,retryAfterMilliseconds:1200)
        let edit=try V2MessageEditOperationCommand(command:.init(roomID:room,actorUserID:actor,operationID:.init(uuid:UUID()),messageID:message,expectedMessageRevision:1,text:"Edited",maximumUTF8Bytes:64),firstSubmissionDeadlineMilliseconds:1000)
        let sendReceipt=try V2MessageSendOperationReceipt(identity:send.identity,fingerprint:send.fingerprint,outcome:.accepted(.init(messageID:message,roomSequence:1)),resolvedAtMilliseconds:1000)
        let editReceipt=try V2MessageMutationReceipt(identity:edit.identity,fingerprint:edit.fingerprint,outcome:.closed,resolvedAtMilliseconds:1000)
        let client=V2RoomRefMessagingClient(callTimeout:try .init(1000),invoke:{ wire,user,_ in
            guard user==actor,case .messaging(let command)=wire else { throw V2RoomCallFailure.outcomeUnknown }
            switch command {
            case .sendOperation(let value) where value==limited: return .messaging(.sendOperation(.deferred(rateHint)))
            case .sendOperation(let value) where value==send: return .messaging(.sendOperation(.receipt(sendReceipt)))
            case .editOperation(let value) where value==edit: return .messaging(.mutation(.receipt(editReceipt)))
            default: throw V2RoomCallFailure.outcomeUnknown
            }
        })
        do {
            V2VaporMessageSendOperationRoutes(authenticator:OperationRouteAuth(actor:actor),messages:client).register(on:app)
            V2VaporMessageMutationOperationRoutes(authenticator:OperationRouteAuth(actor:actor),messages:client).register(on:app)
            try await app.testing { http in
                let sent=try await http.send(.post,to:URI(string:"v2/rooms/\(room.rawValue)/message-operations/send"),beforeSend:{ request in
                    request.headers.bearerAuthorization = .init(token:"token");request.headers[HTTPField.Name("X-IM-Device-ID")!] = UUID().uuidString
                    try request.content.encode(send,using:JSONEncoder())
                })
                #expect(sent.status == .ok && sent.headers[.cacheControl]=="no-store")
                #expect(try await sent.content.decode(V2MessageSendOperationRecoveryResult.self) == .receipt(sendReceipt))
                let rateResponse=try await http.send(.post,to:URI(string:"v2/rooms/\(room.rawValue)/message-operations/send"),beforeSend:{ request in
                    request.headers.bearerAuthorization = .init(token:"token");request.headers[HTTPField.Name("X-IM-Device-ID")!] = UUID().uuidString
                    try request.content.encode(limited,using:JSONEncoder())
                })
                #expect(rateResponse.status == .tooManyRequests && rateResponse.headers[.retryAfter]=="2" && rateResponse.headers[.cacheControl]=="no-store")
                #expect(try await rateResponse.content.decode(V2MessageSendOperationRecoveryResult.self) == .deferred(rateHint))
                for (scope,status) in [(room.rawValue,HTTPResponse.Status.ok),(UUID().uuidString,.forbidden)] {
                    let edited=try await http.send(.post,to:URI(string:"v2/rooms/\(scope)/message-mutations/edit"),beforeSend:{ request in
                        request.headers.bearerAuthorization = .init(token:"token");request.headers[HTTPField.Name("X-IM-Device-ID")!] = UUID().uuidString
                        try request.content.encode(edit,using:JSONEncoder())
                    })
                    #expect(edited.status==status && edited.headers[.cacheControl]=="no-store")
                    if status == .ok { #expect(try await edited.content.decode(V2MessageMutationRecoveryResult.self) == .receipt(editReceipt)) }
                }
            }
            try await app.shutdown()
        } catch { try? await app.shutdown();throw error }
    }
}
private struct OperationRouteAuth:V2GatewayAuthenticator {
    let actor:UserID
    func authenticateSession(accessToken:String,deviceID:DeviceID) async throws -> V2GatewayAuthentication { .init(userID:actor,expiresAt:nil) }
}
