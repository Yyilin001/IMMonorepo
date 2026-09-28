import Foundation
import HTTPTypes
import IMV2ActorContracts
import IMV2Core
import IMV2ServerHTTP
import Testing
import Vapor
import VaporTesting
@testable import IMV2Server

struct V2VaporReadReceiptRecoveryRoutesTests {
    @Test("read recovery binds the room/actor and keeps current unavailability distinct from original rejection")
    func scopedRecovery() async throws {
        let app = try await Application(.testing),actor = UserID(uuid:UUID()),room = RoomID(uuid:UUID())
        let command = try V2RecordReadReceiptCommand(roomID:room,actorUserID:actor,operationID:.init(uuid:UUID()),readThroughRoomSequence:3)
        let request = V2ReadReceiptRecoveryRequest(command:command)
        let client = V2RoomRefQueryClient(caller:.init(timeout:.seconds(1),invoke:{ wire,user,_ in
            guard user == actor,case .receiptQuery(.recover(let input)) = wire,input == request else { throw V2RoomCallFailure.outcomeUnknown }
            return .receipt(.recovery(.currentUnavailable(.permissionDenied)))
        }))
        do {
            V2VaporReadReceiptRecoveryRoutes(authenticator:ReadRecoveryAuthenticator(actor:actor),queries:client).register(on:app)
            try await app.testing { http in
                for (scope,status) in [(room.rawValue,HTTPResponse.Status.ok),(UUID().uuidString,.forbidden)] {
                    let response = try await http.send(.post,to:URI(string:"v2/rooms/\(scope)/read-receipts/operations/recover"),beforeSend:{ body in
                        body.headers.bearerAuthorization = .init(token:"token")
                        body.headers[HTTPField.Name("X-IM-Device-ID")!] = UUID().uuidString
                        try body.content.encode(request,using:JSONEncoder())
                    })
                    #expect(response.status == status && response.headers[.cacheControl] == "no-store")
                    if status == .ok { #expect(try await response.content.decode(V2ReadReceiptRecoveryResult.self) == .currentUnavailable(.permissionDenied)) }
                }
            }
            try await app.shutdown()
        } catch { try? await app.shutdown();throw error }
    }
}
private struct ReadRecoveryAuthenticator:V2GatewayAuthenticator {
    let actor:UserID
    func authenticateSession(accessToken:String,deviceID:DeviceID) async throws -> V2GatewayAuthentication { .init(userID:actor,expiresAt:nil) }
}
