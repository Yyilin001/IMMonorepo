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
    @Test("typed HTTP message edits bind actor room and original receipt")
    func scopedOperations() async throws {
        let app=try await Application(.testing),actor=UserID(uuid:UUID()),room=RoomID(uuid:UUID()),message=MessageID(uuid:UUID())
        let edit=try V2MessageEditOperationCommand(command:.init(roomID:room,actorUserID:actor,operationID:.init(uuid:UUID()),messageID:message,expectedMessageRevision:1,text:"Edited",maximumUTF8Bytes:64),firstSubmissionDeadlineMilliseconds:1000)
        let editReceipt=try V2MessageMutationReceipt(identity:edit.identity,fingerprint:edit.fingerprint,outcome:.closed,resolvedAtMilliseconds:1000)
        let client=V2RoomRefMessagingClient(callTimeout:try .init(1000),invoke:{ wire,user,_ in
            guard user==actor,case .messaging(let command)=wire else { throw V2RoomCallFailure.outcomeUnknown }
            switch command {
            case .editOperation(let value) where value==edit: return .messaging(.mutation(.receipt(editReceipt)))
            default: throw V2RoomCallFailure.outcomeUnknown
            }
        })
        do {
            V2VaporMessageMutationOperationRoutes(authenticator:OperationRouteAuth(actor:actor),messages:client).register(on:app)
            try await app.testing { http in
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
