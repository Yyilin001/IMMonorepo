import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core

public protocol V2AccountPreferenceClient:Sendable {
    func baseline(kind:V2OperationKind) async throws -> V2AccountPreferenceSnapshot
    func submit(_ command:V2AccountPreferenceCommand) async throws -> V2AccountPreferenceRecoveryResult
    func recover(_ command:V2AccountPreferenceCommand,action:V2OperationRecoveryRequest.Action) async throws -> V2AccountPreferenceRecoveryResult
}
public struct V2HTTPAccountPreferenceOperationClient:V2AccountPreferenceClient {
    private let baseURL:URL
    private let credentials:any V2ClientMediaEdgeCredentialProvider
    private let transport:any V2ClientMediaEdgeHTTPTransport
    public init(baseURL:URL,credentials:any V2ClientMediaEdgeCredentialProvider,transport:any V2ClientMediaEdgeHTTPTransport) throws {
        guard baseURL.scheme=="https",baseURL.host != nil,baseURL.user==nil,baseURL.password==nil,baseURL.query==nil,baseURL.fragment==nil else { throw V2HTTPFailure(kind:.invalidEndpoint,service:"accountAPI") }
        self.baseURL=baseURL;self.credentials=credentials;self.transport=transport
    }
    public func baseline(kind:V2OperationKind) async throws -> V2AccountPreferenceSnapshot {
        let(data,response)=try await data(body:nil,kind:kind,action:"baseline")
        guard response.statusCode==200 else { throw V2HTTPFailure.status(response,service:"accountAPI") }
        try validateJSON(data,response)
        let snapshot=try JSONDecoder().decode(V2AccountPreferenceSnapshot.self,from:data)
        guard snapshot.value.kind==kind else { throw V2AccountPreferenceValidationError.invalidSnapshot }
        return snapshot
    }
    public func submit(_ command:V2AccountPreferenceCommand) async throws -> V2AccountPreferenceRecoveryResult {
        try await send(command:command,body:JSONEncoder().encode(command),action:"submit")
    }
    public func recover(_ command:V2AccountPreferenceCommand,action:V2OperationRecoveryRequest.Action) async throws -> V2AccountPreferenceRecoveryResult {
        let request=try V2AccountPreferenceRecoveryRequest(identity:command.identity,fingerprint:command.fingerprint,action:action)
        return try await send(command:command,body:JSONEncoder().encode(request),action:"recover")
    }
    private func send(command:V2AccountPreferenceCommand,body:Data,action:String) async throws -> V2AccountPreferenceRecoveryResult {
        let(data,response)=try await data(body:body,kind:nil,action:action)
        let identity=try command.identity,fingerprint=try command.fingerprint
        if response.statusCode==429 || response.statusCode==503 {
            guard V2HTTPContract.isJSON(response),data.count<=65_536,
                let decoded=try? JSONDecoder().decode(V2AccountPreferenceRecoveryResult.self,from:data),case .deferred(let hint)=decoded else { throw V2HTTPFailure.status(response,service:"accountAPI") }
            guard hint.validates(identity:identity,fingerprint:fingerprint) else { throw V2OperationWorkError.identityConflict }
            let now=Date()
            let header=V2RetryAfter.date(from:response.value(forHTTPHeaderField:"Retry-After"),now:now).map { max(0,ceil($0.timeIntervalSince(now)*1_000)) } ?? 0
            guard header<=86_400_000 else { throw V2HTTPFailure.status(response,service:"accountAPI",now:now) }
            let delay=max(hint.retryAfterMilliseconds ?? 0,UInt64(header))
            return .deferred(try .init(identity:identity,fingerprint:fingerprint,reason:hint.reason,retryAfterMilliseconds:delay>0 ? delay : nil))
        }
        guard response.statusCode==200 else { throw V2HTTPFailure.status(response,service:"accountAPI") }
        try validateJSON(data,response)
        let result=try JSONDecoder().decode(V2AccountPreferenceRecoveryResult.self,from:data)
        if case .receipt(let receipt)=result,!receipt.validates(command:command) { throw V2AccountPreferenceValidationError.invalidReceipt }
        if case .deferred(let hint)=result,!hint.validates(identity:identity,fingerprint:fingerprint) { throw V2OperationWorkError.identityConflict }
        return result
    }
    private func validateJSON(_ data:Data,_ response:HTTPURLResponse) throws {
        guard V2HTTPContract.isJSON(response),data.count<=65_536 else { throw V2HTTPFailure(kind:.invalidResponse,service:"accountAPI",statusCode:response.statusCode) }
    }
    private func data(body:Data?,kind:V2OperationKind?,action:String) async throws -> (Data,HTTPURLResponse) {
        try Task.checkCancellation()
        guard (body?.count ?? 0)<=4_096 else { throw V2OperationWorkError.invalidRecord }
        let credential=try await credentials.mediaEdgeCredentials()
        guard !credential.accessToken.isEmpty,!credential.accessToken.unicodeScalars.contains(where:{$0.value<32 || $0.value==127}) else { throw V2ClientMediaTransferError.authorizationUnavailable }
        let path=kind.map { "v2/account-preferences/\($0.rawValue)/baseline" } ?? "v2/account-preferences/operations/\(action)"
        var request=URLRequest(url:baseURL.appending(path:path),cachePolicy:.reloadIgnoringLocalAndRemoteCacheData,timeoutInterval:15)
        request.httpMethod=kind == nil ? "POST" : "GET";request.httpBody=body
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
