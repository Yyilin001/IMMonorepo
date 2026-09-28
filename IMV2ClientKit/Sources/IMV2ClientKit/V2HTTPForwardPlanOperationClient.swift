import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core

/// HTTP submission remains independently available while realtime is disconnected.
public struct V2HTTPForwardPlanOperationClient: V2ForwardPlanOperationClient {
    private let baseURL:URL
    private let credentials:any V2ClientMediaEdgeCredentialProvider
    private let transport:any V2ClientMediaEdgeHTTPTransport
    public init(baseURL:URL,credentials:any V2ClientMediaEdgeCredentialProvider,transport:any V2ClientMediaEdgeHTTPTransport) throws {
        guard baseURL.scheme=="https",baseURL.host != nil,baseURL.user==nil,baseURL.password==nil,baseURL.query==nil,baseURL.fragment==nil else {
            throw V2HTTPFailure(kind:.invalidEndpoint,service:"accountAPI")
        }
        self.baseURL=baseURL;self.credentials=credentials;self.transport=transport
    }
    public func submit(_ command:V2ForwardPlanOperationCommand) async throws -> V2ForwardPlanRecoveryResult {
        let encoder=JSONEncoder();encoder.outputFormatting = [.sortedKeys]
        return try await send(command:command,body:encoder.encode(command),action:"submit")
    }
    public func recover(_ command:V2ForwardPlanOperationCommand,action:V2ForwardPlanRecoveryAction) async throws -> V2ForwardPlanRecoveryResult {
        let request=try V2ForwardPlanRecoveryRequest(command:command,action:action)
        return try await send(command:command,body:JSONEncoder().encode(request),action:"operations/recover")
    }
    private func send(command:V2ForwardPlanOperationCommand,body:Data,action:String) async throws -> V2ForwardPlanRecoveryResult {
        let identity=try command.identity,fingerprint=try command.fingerprint
        guard body.count<=65_536 else { throw V2OperationWorkError.invalidRecord }
        try Task.checkCancellation()
        guard case .account = identity.scope else { throw V2OperationWorkError.identityConflict }
        let credential=try await credentials.mediaEdgeCredentials()
        guard !credential.accessToken.isEmpty,!credential.accessToken.unicodeScalars.contains(where:{$0.value<32 || $0.value==127}) else {
            throw V2ClientMediaTransferError.authorizationUnavailable
        }
        var request=URLRequest(url:baseURL.appending(path:"v2/forward-plans/\(action)"),cachePolicy:.reloadIgnoringLocalAndRemoteCacheData,timeoutInterval:15)
        request.httpMethod="POST";request.httpBody=body
        request.setValue("Bearer \(credential.accessToken)",forHTTPHeaderField:"Authorization")
        request.setValue(credential.deviceID.rawValue,forHTTPHeaderField:"X-IM-Device-ID")
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.setValue("application/json",forHTTPHeaderField:"Accept")
        request.setValue("no-store",forHTTPHeaderField:"Cache-Control")
        V2HTTPRequestDeadline.attach(credential.requestDeadline,to:&request)
        let(data,response)=try await transport.data(for:request)
        try Task.checkCancellation()
        if response.statusCode == 429 || response.statusCode == 503 {
            guard V2HTTPContract.isJSON(response), data.count<=1_048_576,
                let result=try? JSONDecoder().decode(V2ForwardPlanRecoveryResult.self,from:data),
                case .deferred(let hint)=result else { throw V2HTTPFailure.status(response,service:"accountAPI") }
            guard hint.validates(identity:identity,fingerprint:fingerprint) else { throw V2OperationWorkError.identityConflict }
            let now=Date()
            let headerDelay=V2RetryAfter.date(from:response.value(forHTTPHeaderField:"Retry-After"),now:now).map { max(0,ceil($0.timeIntervalSince(now)*1_000)) } ?? 0
            guard headerDelay<=86_400_000 else { throw V2HTTPFailure.status(response,service:"accountAPI",now:now) }
            let delay=max(hint.retryAfterMilliseconds ?? 0,UInt64(headerDelay))
            return .deferred(try .init(identity:hint.identity,fingerprint:hint.fingerprint,reason:hint.reason,retryAfterMilliseconds:delay>0 ? delay : nil))
        }
        guard response.statusCode==200 else { throw V2HTTPFailure.status(response,service:"accountAPI") }
        guard V2HTTPContract.isJSON(response),data.count<=1_048_576 else { throw V2HTTPFailure(kind:.invalidResponse,service:"accountAPI",statusCode:response.statusCode) }
        let result=try JSONDecoder().decode(V2ForwardPlanRecoveryResult.self,from:data)
        if case .receipt(let receipt)=result, !receipt.validates(command:command) {
            throw V2OperationWorkError.identityConflict
        }
        if case .processing(let progress)=result, !progress.validates(command:command) {
            throw V2OperationWorkError.identityConflict
        }
        if case .deferred(let hint)=result, !hint.validates(identity:identity,fingerprint:fingerprint) {
            throw V2OperationWorkError.identityConflict
        }
        return result
    }
}
