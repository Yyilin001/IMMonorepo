import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core

/// HTTP submission remains independently available while realtime is disconnected.
public struct V2HTTPMessageReactionOperationClient: V2MessageReactionOperationClient {
    private let baseURL:URL
    private let credentials:any V2ClientMediaEdgeCredentialProvider
    private let transport:any V2ClientMediaEdgeHTTPTransport
    public init(baseURL:URL,credentials:any V2ClientMediaEdgeCredentialProvider,transport:any V2ClientMediaEdgeHTTPTransport) throws {
        guard baseURL.scheme=="https",baseURL.host != nil,baseURL.user==nil,baseURL.password==nil,baseURL.query==nil,baseURL.fragment==nil else {
            throw V2HTTPFailure(kind:.invalidEndpoint,service:"accountAPI")
        }
        self.baseURL=baseURL;self.credentials=credentials;self.transport=transport
    }
    public func snapshot(roomID:RoomID,messageID:MessageID,reaction:String) async throws -> V2MessageReactionSnapshot {
        let credential=try await credentials.mediaEdgeCredentials()
        guard !credential.accessToken.isEmpty,!credential.accessToken.unicodeScalars.contains(where:{$0.value<32 || $0.value==127}) else { throw V2ClientMediaTransferError.authorizationUnavailable }
        var components=URLComponents(url:baseURL.appending(path:"v2/rooms/\(roomID.rawValue)/message-reactions/\(messageID.rawValue)"),resolvingAgainstBaseURL:false)!
        components.queryItems=[.init(name:"reaction",value:reaction)]
        guard let url=components.url else { throw V2HTTPFailure(kind:.invalidEndpoint,service:"accountAPI") }
        var request=URLRequest(url:url,cachePolicy:.reloadIgnoringLocalAndRemoteCacheData,timeoutInterval:15)
        request.setValue("Bearer \(credential.accessToken)",forHTTPHeaderField:"Authorization")
        request.setValue(credential.deviceID.rawValue,forHTTPHeaderField:"X-IM-Device-ID")
        request.setValue("application/json",forHTTPHeaderField:"Accept")
        request.setValue("no-store",forHTTPHeaderField:"Cache-Control")
        V2HTTPRequestDeadline.attach(credential.requestDeadline,to:&request)
        let(data,response)=try await transport.data(for:request)
        try Task.checkCancellation()
        guard response.statusCode==200 else { throw V2HTTPFailure.status(response,service:"accountAPI") }
        guard V2HTTPContract.isJSON(response),data.count<=65_536 else { throw V2HTTPFailure(kind:.invalidResponse,service:"accountAPI") }
        let snapshot=try JSONDecoder().decode(V2MessageReactionSnapshot.self,from:data)
        guard snapshot.roomID==roomID,snapshot.messageID==messageID,snapshot.reaction==reaction else { throw V2OperationWorkError.identityConflict }
        return snapshot
    }
    public func submit(_ command:V2MessageReactionOperationCommand) async throws -> V2MessageReactionRecoveryResult {
        let encoder=JSONEncoder();encoder.outputFormatting = [.sortedKeys]
        return try await send(identity:command.identity,fingerprint:command.fingerprint,body:encoder.encode(command),action:"change")
    }
    public func recover(_ request:V2MessageReactionRecoveryRequest) async throws -> V2MessageReactionRecoveryResult {
        try await send(identity:request.identity,fingerprint:request.fingerprint,body:JSONEncoder().encode(request),action:"operations/recover")
    }
    private func send(identity:V2OperationIdentity,fingerprint:V2OperationFingerprint,body:Data,action:String) async throws -> V2MessageReactionRecoveryResult {
        try Task.checkCancellation()
        guard case .message(let room,_)=identity.scope else { throw V2OperationWorkError.identityConflict }
        let credential=try await credentials.mediaEdgeCredentials()
        guard !credential.accessToken.isEmpty,!credential.accessToken.unicodeScalars.contains(where:{$0.value<32 || $0.value==127}) else {
            throw V2ClientMediaTransferError.authorizationUnavailable
        }
        var request=URLRequest(url:baseURL.appending(path:"v2/rooms/\(room.rawValue)/message-reactions/\(action)"),cachePolicy:.reloadIgnoringLocalAndRemoteCacheData,timeoutInterval:15)
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
            guard V2HTTPContract.isJSON(response), data.count<=65_536,
                let result=try? JSONDecoder().decode(V2MessageReactionRecoveryResult.self,from:data),
                case .deferred(let hint)=result else { throw V2HTTPFailure.status(response,service:"accountAPI") }
            guard hint.validates(identity:identity,fingerprint:fingerprint) else { throw V2OperationWorkError.identityConflict }
            let now=Date()
            let headerDelay=V2RetryAfter.date(from:response.value(forHTTPHeaderField:"Retry-After"),now:now).map { max(0,ceil($0.timeIntervalSince(now)*1_000)) } ?? 0
            guard headerDelay<=86_400_000 else { throw V2HTTPFailure.status(response,service:"accountAPI",now:now) }
            let delay=max(hint.retryAfterMilliseconds ?? 0,UInt64(headerDelay))
            return .deferred(try .init(identity:hint.identity,fingerprint:hint.fingerprint,reason:hint.reason,retryAfterMilliseconds:delay>0 ? delay : nil))
        }
        guard response.statusCode==200 else { throw V2HTTPFailure.status(response,service:"accountAPI") }
        guard V2HTTPContract.isJSON(response),data.count<=65_536 else { throw V2HTTPFailure(kind:.invalidResponse,service:"accountAPI",statusCode:response.statusCode) }
        let result=try JSONDecoder().decode(V2MessageReactionRecoveryResult.self,from:data)
        if case .receipt(let receipt)=result, !receipt.validates(identity:identity,fingerprint:fingerprint) {
            throw V2OperationWorkError.identityConflict
        }
        if case .deferred(let hint)=result, !hint.validates(identity:identity,fingerprint:fingerprint) {
            throw V2OperationWorkError.identityConflict
        }
        return result
    }
}
