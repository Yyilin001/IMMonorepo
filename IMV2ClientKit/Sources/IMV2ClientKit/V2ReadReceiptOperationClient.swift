import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core

/// TCP submission and independently available HTTP monotonic recovery share one frozen command.
public struct V2ReadReceiptOperationAdapter: V2ReadReceiptOperationClient {
    private let realtime: any V2ClientReadReceiptTransport
    private let credentials: any V2ClientMediaEdgeCredentialProvider
    private let transport: any V2ClientMediaEdgeHTTPTransport
    private let baseURL: URL
    public init(realtime: any V2ClientReadReceiptTransport, baseURL: URL,
                credentials: any V2ClientMediaEdgeCredentialProvider, transport: any V2ClientMediaEdgeHTTPTransport) throws {
        guard baseURL.scheme == "https", baseURL.host != nil, baseURL.user == nil, baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil else { throw V2HTTPFailure(kind:.invalidEndpoint,service:"accountAPI") }
        self.realtime=realtime;self.baseURL=baseURL;self.credentials=credentials;self.transport=transport
    }
    public func submit(_ command: V2RecordReadReceiptCommand) async throws -> V2ReadReceiptOperationReceipt {
        let value=try await realtime.recordReadReceipt(roomID:command.roomID,operationID:command.operationID,readThroughRoomSequence:command.readThroughRoomSequence)
        return try .init(command:command,receipt:.init(roomID:value.roomID,userID:value.userID,readThroughRoomSequence:value.readThroughRoomSequence,recordedAt:value.recordedAt))
    }
    public func recover(_ request: V2ReadReceiptRecoveryRequest) async throws -> V2ReadReceiptRecoveryResult {
        try Task.checkCancellation()
        let credential=try await credentials.mediaEdgeCredentials()
        guard !credential.accessToken.isEmpty,
            !credential.accessToken.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw V2ClientMediaTransferError.authorizationUnavailable }
        let command=request.command
        var urlRequest=URLRequest(url:baseURL.appending(path:"v2/rooms/\(command.roomID.rawValue)/read-receipts/operations/recover"),cachePolicy:.reloadIgnoringLocalAndRemoteCacheData,timeoutInterval:15)
        urlRequest.httpMethod="POST";urlRequest.httpBody=try JSONEncoder().encode(request)
        urlRequest.setValue("Bearer \(credential.accessToken)",forHTTPHeaderField:"Authorization")
        urlRequest.setValue(credential.deviceID.rawValue,forHTTPHeaderField:"X-IM-Device-ID")
        urlRequest.setValue("application/json",forHTTPHeaderField:"Content-Type")
        urlRequest.setValue("application/json",forHTTPHeaderField:"Accept")
        urlRequest.setValue("no-store",forHTTPHeaderField:"Cache-Control")
        V2HTTPRequestDeadline.attach(credential.requestDeadline,to:&urlRequest)
        let (data,response)=try await transport.data(for:urlRequest)
        try Task.checkCancellation()
        guard response.statusCode == 200 else { throw V2HTTPFailure.status(response,service:"accountAPI") }
        guard V2HTTPContract.isJSON(response),data.count <= 65_536 else { throw V2HTTPFailure(kind:.invalidResponse,service:"accountAPI",statusCode:response.statusCode) }
        let result=try JSONDecoder().decode(V2ReadReceiptRecoveryResult.self,from:data)
        switch result {
        case .originalReceipt(let value): guard value.validates(command) else { throw V2ReadReceiptRecoveryValidationError.invalidProof }
        case .watermarkProof(let value): guard value.validates(command) else { throw V2ReadReceiptRecoveryValidationError.invalidProof }
        default: break
        }
        return result
    }
}
