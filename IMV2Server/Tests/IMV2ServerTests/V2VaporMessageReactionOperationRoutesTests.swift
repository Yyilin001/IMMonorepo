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

struct V2VaporMessageReactionOperationRoutesTests {
    @Test(arguments: ["denied", "corrupt", "unknown", "validation"])
    func baselineFailureClassification(kind: String) async throws {
        let app = try await Application(.testing)
        let actor = UserID(uuid: UUID()), room = RoomID(uuid: UUID()), message = MessageID(uuid: UUID())
        let client = V2RoomRefMessagingClient(callTimeout: try .init(1000)) { _, _, _ in
            switch kind {
            case "denied": return .messaging(.failure(.reactionStore(.actorNotMember)))
            case "corrupt": return .messaging(.failure(.reactionStore(.corruptPersistenceState)))
            case "validation": return .messaging(.failure(.reactionValidation(.invalidReaction)))
            default: throw V2RoomCallFailure.outcomeUnknown
            }
        }
        do {
            V2VaporMessageReactionOperationRoutes(authenticator: ReactionRouteAuth(actor: actor), messages: client).register(on: app)
            try await app.testing { http in
                let result = try await http.send(.get, to: URI(string: "v2/rooms/\(room.rawValue)/message-reactions/\(message.rawValue)?reaction=x"), beforeSend: { request in
                    request.headers.bearerAuthorization = .init(token: "token")
                    request.headers[HTTPField.Name("X-IM-Device-ID")!] = UUID().uuidString
                })
                let expected: HTTPResponse.Status = kind == "denied" ? .forbidden : kind == "validation" ? .badRequest : .serviceUnavailable
                #expect(result.status == expected)
                #expect(result.headers[.cacheControl] == "no-store")
            }
            try await app.shutdown()
        } catch { try? await app.shutdown(); throw error }
    }

    @Test func baselineAndBoundOperations() async throws {
        let app=try await Application(.testing),actor=UserID(uuid:UUID()),room=RoomID(uuid:UUID()),message=MessageID(uuid:UUID())
        let command=try V2MessageReactionOperationCommand(command:.init(roomID:room,actorUserID:actor,operationID:.init(uuid:UUID()),messageID:message,reaction:"👍",action:.add),expectedReactionRevision:0,firstSubmissionDeadlineMilliseconds:1000)
        let receipt=try V2MessageReactionReceipt(identity:command.identity,fingerprint:command.fingerprint,outcome:.closed,resolvedAtMilliseconds:1000)
        let snapshot=try V2MessageReactionSnapshot(roomID:room,actorUserID:actor,messageID:message,reaction:"👍",targetState:.absent,revision:0)
        let client=V2RoomRefMessagingClient(callTimeout:try .init(1000),invoke:{ wire,user,_ in
            guard user==actor,case .messaging(let input)=wire else { throw V2RoomCallFailure.outcomeUnknown }
            switch input {
            case .reactionOperation(let value) where value==command: return .messaging(.reactionOperation(.receipt(receipt)))
            case .recoverReaction: return .messaging(.reactionOperation(.receipt(receipt)))
            case .reactionSnapshot(let value) where value.roomID==room && value.messageID==message && value.reaction=="👍": return .messaging(.reactionSnapshot(snapshot))
            default: throw V2RoomCallFailure.outcomeUnknown
            }
        })
        do {
            V2VaporMessageReactionOperationRoutes(authenticator:ReactionRouteAuth(actor:actor),messages:client).register(on:app)
            try await app.testing { http in
                let baseline=try await http.send(.get,to:URI(string:"v2/rooms/\(room.rawValue)/message-reactions/\(message.rawValue)?reaction=%F0%9F%91%8D"),beforeSend:{ request in
                    request.headers.bearerAuthorization = .init(token:"token");request.headers[HTTPField.Name("X-IM-Device-ID")!]=UUID().uuidString
                })
                #expect(baseline.status == .ok && baseline.headers[.cacheControl]=="no-store")
                #expect(try await baseline.content.decode(V2MessageReactionSnapshot.self)==snapshot)
                for (scope,status) in [(room.rawValue,HTTPResponse.Status.ok),(UUID().uuidString,.forbidden)] {
                    let result=try await http.send(.post,to:URI(string:"v2/rooms/\(scope)/message-reactions/change"),beforeSend:{ request in
                        request.headers.bearerAuthorization = .init(token:"token");request.headers[HTTPField.Name("X-IM-Device-ID")!]=UUID().uuidString
                        try request.content.encode(command,using:JSONEncoder())
                    })
                    #expect(result.status==status && result.headers[.cacheControl]=="no-store")
                    if status == .ok { #expect(try await result.content.decode(V2MessageReactionRecoveryResult.self) == .receipt(receipt)) }
                }
            }
            try await app.shutdown()
        } catch { try? await app.shutdown();throw error }
    }
}
private struct ReactionRouteAuth:V2GatewayAuthenticator {
    let actor:UserID
    func authenticateSession(accessToken:String,deviceID:DeviceID) async throws -> V2GatewayAuthentication { .init(userID:actor,expiresAt:nil) }
}
