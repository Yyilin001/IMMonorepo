import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Read receipt HTTP recovery",.serialized)
struct V2ReadReceiptOperationClientTests {
    @Test("HTTP recovery retains frozen command and local deadline without leaking budget to wire")
    func typedRecoveryBudget() async throws {
        let command=try V2RecordReadReceiptCommand(roomID:.init(uuid:UUID()),actorUserID:.init(uuid:UUID()),operationID:.init(uuid:UUID()),readThroughRoomSequence:9)
        let deadline=ContinuousClock.now + .seconds(15)
        let value=try V2ReadReceipt(roomID:command.roomID,userID:command.actorUserID,readThroughRoomSequence:12,recordedAt:Date())
        let result=V2ReadReceiptRecoveryResult.watermarkProof(try .init(command:command,watermark:value))
        let io=ReceiptHTTPIO(data:try JSONEncoder().encode(result))
        let adapter=try V2ReadReceiptOperationAdapter(realtime:UnusedReceiptTCP(),baseURL:#require(URL(string:"https://account.invalid")),credentials:ReceiptHTTPCredentials(deadline:deadline),transport:io)
        #expect(try await adapter.recover(.init(command:command)) == result)
        let request=try #require(await io.request)
        #expect(request.httpMethod == "POST" && request.url?.path == "/v2/rooms/\(command.roomID.rawValue)/read-receipts/operations/recover")
        #expect(try JSONDecoder().decode(V2ReadReceiptRecoveryRequest.self,from:#require(request.httpBody)).command == command)
        #expect(V2HTTPRequestDeadline.deadline(for:request) == deadline)
        #expect(!(request.allHTTPHeaderFields ?? [:]).keys.contains { $0.lowercased().contains("deadline") || $0.lowercased().contains("budget") })
    }
    @Test("another frozen operation's otherwise valid proof cannot complete this intent")
    func rejectsDifferentIdentity() async throws {
        let room=RoomID(uuid:UUID()), account=UserID(uuid:UUID())
        let requested=try V2RecordReadReceiptCommand(roomID:room,actorUserID:account,operationID:.init(uuid:UUID()),readThroughRoomSequence:2)
        let other=try V2RecordReadReceiptCommand(roomID:room,actorUserID:account,operationID:.init(uuid:UUID()),readThroughRoomSequence:2)
        let result=V2ReadReceiptRecoveryResult.watermarkProof(try .init(command:other,watermark:.init(roomID:room,userID:account,readThroughRoomSequence:2,recordedAt:Date())))
        let io=ReceiptHTTPIO(data:try JSONEncoder().encode(result))
        let adapter=try V2ReadReceiptOperationAdapter(realtime:UnusedReceiptTCP(),baseURL:#require(URL(string:"https://account.invalid")),credentials:ReceiptHTTPCredentials(deadline:nil),transport:io)
        await #expect(throws:V2ReadReceiptRecoveryValidationError.invalidProof) { _ = try await adapter.recover(.init(command:requested)) }
    }
    @Test(arguments:["http://account.invalid","https://account.invalid?a=1","https://account.invalid/#x"])
    func rejectsInvalidBase(value:String) throws {
        #expect(throws:V2HTTPFailure.self) { _ = try V2ReadReceiptOperationAdapter(realtime:UnusedReceiptTCP(),baseURL:#require(URL(string:value)),credentials:ReceiptHTTPCredentials(deadline:nil),transport:ReceiptHTTPIO(data:Data())) }
    }
}
private struct ReceiptHTTPCredentials:V2ClientMediaEdgeCredentialProvider {
    let deadline:ContinuousClock.Instant?
    func mediaEdgeCredentials() -> V2ClientMediaEdgeCredentials { .init(accessToken:"test-token",deviceID:.init(uuid:UUID()),requestDeadline:deadline) }
}
private actor ReceiptHTTPIO:V2ClientMediaEdgeHTTPTransport {
    let data:Data
    var request:URLRequest?
    init(data:Data) { self.data=data }
    func data(for request:URLRequest) -> (Data,HTTPURLResponse) {
        self.request=request
        return (data,HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!)
    }
}
private struct UnusedReceiptTCP:V2ClientReadReceiptTransport {
    func recordReadReceipt(roomID:RoomID,operationID:ReadReceiptOperationID,readThroughRoomSequence:UInt64) throws -> V2ClientReadReceipt { throw V2RealtimeTransportError.unexpectedResponse }

    func listReadReceiptReaders(roomID:RoomID,messageID:MessageID,cursor:String?,pageSize:Int) throws -> V2ReadReceiptReadersPage { throw V2RealtimeTransportError.unexpectedResponse }
}
