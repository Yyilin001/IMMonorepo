import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core

public protocol V2MembershipOperationClient:Sendable {
    func admit(_ intent:V2MembershipIntent) async throws -> V2MembershipAdmissionResult
    func submit(_ command:V2MembershipOperationCommand) async throws -> V2MembershipRecoveryResult
    func recover(_ command:V2MembershipOperationCommand,action:V2OperationRecoveryRequest.Action) async throws -> V2MembershipRecoveryResult
}
public struct V2HTTPMembershipOperationClient:V2MembershipOperationClient {
    private let baseURL:URL
    private let credentials:any V2ClientMediaEdgeCredentialProvider
    private let transport:any V2ClientMediaEdgeHTTPTransport
    public init(baseURL:URL,credentials:any V2ClientMediaEdgeCredentialProvider,transport:any V2ClientMediaEdgeHTTPTransport) throws {
        guard baseURL.scheme=="https",baseURL.host != nil,baseURL.user==nil,baseURL.password==nil,baseURL.query==nil,baseURL.fragment==nil else { throw V2HTTPFailure(kind:.invalidEndpoint,service:"accountAPI") }
        self.baseURL=baseURL;self.credentials=credentials;self.transport=transport
    }
    public func admit(_ intent:V2MembershipIntent) async throws -> V2MembershipAdmissionResult {
        let(data,response)=try await data(body:JSONEncoder().encode(intent),room:intent.roomID,action:"admissions")
        guard response.statusCode==200 else { throw V2HTTPFailure.status(response,service:"accountAPI") }
        try validateJSON(data,response)
        let result=try JSONDecoder().decode(V2MembershipAdmissionResult.self,from:data)
        if case .admitted(let admission)=result,!admission.validates(intent:intent) { throw V2MembershipOperationValidationError.invalidAdmission }
        return result
    }
    public func submit(_ command:V2MembershipOperationCommand) async throws -> V2MembershipRecoveryResult {
        try await send(command:command,body:JSONEncoder().encode(command),action:"submit")
    }
    public func recover(_ command:V2MembershipOperationCommand,action:V2OperationRecoveryRequest.Action) async throws -> V2MembershipRecoveryResult {
        let request=try V2MembershipRecoveryRequest(identity:command.identity,fingerprint:command.fingerprint,action:action)
        return try await send(command:command,body:JSONEncoder().encode(request),action:"operations/recover")
    }
    private func send(command:V2MembershipOperationCommand,body:Data,action:String) async throws -> V2MembershipRecoveryResult {
        let(data,response)=try await data(body:body,room:command.intent.roomID,action:action)
        let identity=try command.identity,fingerprint=try command.fingerprint
        if response.statusCode==429 || response.statusCode==503 {
            guard V2HTTPContract.isJSON(response),data.count<=65_536,
                let decoded=try? JSONDecoder().decode(V2MembershipRecoveryResult.self,from:data),case .deferred(let hint)=decoded else { throw V2HTTPFailure.status(response,service:"accountAPI") }
            guard hint.validates(identity:identity,fingerprint:fingerprint) else { throw V2OperationWorkError.identityConflict }
            let now=Date()
            let header=V2RetryAfter.date(from:response.value(forHTTPHeaderField:"Retry-After"),now:now).map { max(0,ceil($0.timeIntervalSince(now)*1_000)) } ?? 0
            guard header<=86_400_000 else { throw V2HTTPFailure.status(response,service:"accountAPI",now:now) }
            let delay=max(hint.retryAfterMilliseconds ?? 0,UInt64(header))
            return .deferred(try .init(identity:identity,fingerprint:fingerprint,reason:hint.reason,retryAfterMilliseconds:delay>0 ? delay : nil))
        }
        guard response.statusCode==200 else { throw V2HTTPFailure.status(response,service:"accountAPI") }
        try validateJSON(data,response)
        let result=try JSONDecoder().decode(V2MembershipRecoveryResult.self,from:data)
        if case .receipt(let receipt)=result,!receipt.validates(command:command) { throw V2MembershipOperationValidationError.invalidReceipt }
        if case .deferred(let hint)=result,!hint.validates(identity:identity,fingerprint:fingerprint) { throw V2OperationWorkError.identityConflict }
        return result
    }
    private func validateJSON(_ data:Data,_ response:HTTPURLResponse) throws {
        guard V2HTTPContract.isJSON(response),data.count<=65_536 else { throw V2HTTPFailure(kind:.invalidResponse,service:"accountAPI",statusCode:response.statusCode) }
    }
    private func data(body:Data,room:RoomID,action:String) async throws -> (Data,HTTPURLResponse) {
        try Task.checkCancellation()
        guard body.count<=4_096 else { throw V2OperationWorkError.invalidRecord }
        let credential=try await credentials.mediaEdgeCredentials()
        guard !credential.accessToken.isEmpty,!credential.accessToken.unicodeScalars.contains(where:{$0.value<32 || $0.value==127}) else { throw V2ClientMediaTransferError.authorizationUnavailable }
        var request=URLRequest(url:baseURL.appending(path:"v2/rooms/\(room.rawValue)/membership/\(action)"),cachePolicy:.reloadIgnoringLocalAndRemoteCacheData,timeoutInterval:15)
        request.httpMethod="POST";request.httpBody=body
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
