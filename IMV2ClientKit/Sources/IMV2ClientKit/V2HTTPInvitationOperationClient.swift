import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core

public protocol V2InvitationOperationClient:Sendable {
    func admit(_ request:V2GroupInvitationAdmissionRequest) async throws -> V2GroupInvitationAdmissionResult
    func submit(_ submission:V2GroupInvitationSubmission) async throws -> V2GroupInvitationOperationRecoveryResult
    func baseline(roomID:RoomID) async throws -> V2GroupInvitationOperationBaseline
    func recover(_ intent:V2GroupInvitationOperationIntent,action:V2OperationRecoveryRequest.Action) async throws -> V2GroupInvitationOperationRecoveryResult
}
public struct V2HTTPInvitationOperationClient:V2InvitationOperationClient {
    private let baseURL:URL
    private let credentials:any V2ClientMediaEdgeCredentialProvider
    private let transport:any V2ClientMediaEdgeHTTPTransport
    public init(baseURL:URL,credentials:any V2ClientMediaEdgeCredentialProvider,transport:any V2ClientMediaEdgeHTTPTransport) throws {
        guard baseURL.scheme=="https",baseURL.host != nil,baseURL.user==nil,baseURL.password==nil,baseURL.query==nil,baseURL.fragment==nil else { throw V2HTTPFailure(kind:.invalidEndpoint,service:"accountAPI") }
        self.baseURL=baseURL;self.credentials=credentials;self.transport=transport
    }
    public func baseline(roomID:RoomID) async throws -> V2GroupInvitationOperationBaseline {
        let(data,response)=try await data(body:nil,room:roomID,action:"baseline")
        guard response.statusCode==200 else {throw V2HTTPFailure.status(response,service:"accountAPI")}
        try validateJSON(data,response)
        let baseline=try JSONDecoder().decode(V2GroupInvitationOperationBaseline.self,from:data)
        guard baseline.roomID==roomID else {throw V2GroupInvitationOperationValidationError.invalidIntent};return baseline
    }
    public func admit(_ request:V2GroupInvitationAdmissionRequest) async throws -> V2GroupInvitationAdmissionResult {
        let intent=request.intent
        let(data,response)=try await data(body:JSONEncoder().encode(request),room:intent.roomID,action:"admissions")
        guard response.statusCode==200 else {throw V2HTTPFailure.status(response,service:"accountAPI")}
        try validateJSON(data,response)
        let result=try JSONDecoder().decode(V2GroupInvitationAdmissionResult.self,from:data)
        switch result {
        case .admitted(let admission):guard admission.validates(intent:intent) else {throw V2GroupInvitationOperationValidationError.invalidAdmission}
        case .terminal(let receipt):guard receipt.validates(intent:intent) else {throw V2GroupInvitationOperationValidationError.invalidReceipt}
        default:break
        };return result
    }
    public func submit(_ submission:V2GroupInvitationSubmission) async throws -> V2GroupInvitationOperationRecoveryResult {
        try await send(intent:submission.command.intent,body:JSONEncoder().encode(submission),action:"submit")
    }
    public func recover(_ intent:V2GroupInvitationOperationIntent,action:V2OperationRecoveryRequest.Action) async throws -> V2GroupInvitationOperationRecoveryResult {
        try await send(intent:intent,body:JSONEncoder().encode(V2GroupInvitationRecoveryRequest(intent:intent,action:action)),action:"operations/recover")
    }
    private func send(intent:V2GroupInvitationOperationIntent,body:Data,action:String) async throws -> V2GroupInvitationOperationRecoveryResult {
        let(data,response)=try await data(body:body,room:intent.roomID,action:action)
        let identity=intent.identity,fingerprint=try intent.fingerprint
        if response.statusCode==429 || response.statusCode==503 {
            guard V2HTTPContract.isJSON(response),data.count<=65_536,
                let decoded=try? JSONDecoder().decode(V2GroupInvitationOperationRecoveryResult.self,from:data),case .deferred(let hint)=decoded else { throw V2HTTPFailure.status(response,service:"accountAPI") }
            guard hint.validates(identity:identity,fingerprint:fingerprint) else { throw V2OperationWorkError.identityConflict }
            let now=Date()
            let header=V2RetryAfter.date(from:response.value(forHTTPHeaderField:"Retry-After"),now:now).map { max(0,ceil($0.timeIntervalSince(now)*1_000)) } ?? 0
            guard header<=86_400_000 else { throw V2HTTPFailure.status(response,service:"accountAPI",now:now) }
            let delay=max(hint.retryAfterMilliseconds ?? 0,UInt64(header))
            return .deferred(try .init(identity:identity,fingerprint:fingerprint,reason:hint.reason,retryAfterMilliseconds:delay>0 ? delay : nil))
        }
        guard response.statusCode==200 else { throw V2HTTPFailure.status(response,service:"accountAPI") }
        try validateJSON(data,response)
        let result=try JSONDecoder().decode(V2GroupInvitationOperationRecoveryResult.self,from:data)
        if case .receipt(let receipt)=result,!receipt.validates(intent:intent) { throw V2GroupInvitationOperationValidationError.invalidReceipt }
        if case .deferred(let hint)=result,!hint.validates(identity:identity,fingerprint:fingerprint) { throw V2OperationWorkError.identityConflict }
        return result
    }
    private func validateJSON(_ data:Data,_ response:HTTPURLResponse) throws {
        guard V2HTTPContract.isJSON(response),data.count<=65_536 else { throw V2HTTPFailure(kind:.invalidResponse,service:"accountAPI",statusCode:response.statusCode) }
    }
    private func data(body:Data?,room:RoomID,action:String) async throws -> (Data,HTTPURLResponse) {
        try Task.checkCancellation()
        guard (body?.count ?? 0)<=8_192 else { throw V2OperationWorkError.invalidRecord }
        let credential=try await credentials.mediaEdgeCredentials()
        try Task.checkCancellation()
        guard !credential.accessToken.isEmpty,!credential.accessToken.unicodeScalars.contains(where:{$0.value<32 || $0.value==127}) else { throw V2ClientMediaTransferError.authorizationUnavailable }
        var request=URLRequest(url:baseURL.appending(path:"v2/rooms/\(room.rawValue)/invitation-operations/\(action)"),cachePolicy:.reloadIgnoringLocalAndRemoteCacheData,timeoutInterval:15)
        request.httpMethod=body == nil ? "GET" : "POST";request.httpBody=body
        request.setValue("Bearer \(credential.accessToken)",forHTTPHeaderField:"Authorization")
        request.setValue(credential.deviceID.rawValue,forHTTPHeaderField:"X-IM-Device-ID")
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.setValue("application/json",forHTTPHeaderField:"Accept")
        request.setValue("no-store",forHTTPHeaderField:"Cache-Control")
        V2HTTPRequestDeadline.attach(credential.requestDeadline,to:&request)
        let result=try await transport.data(for:request)
        try Task.checkCancellation();return result
    }
}
