import Foundation
import AsyncHTTPClient
import NIOSSL
import Synchronization
import IMV2Core

/// Bounded operator-tool HTTP calls using the same local CA as the gateway.
/// Tokens stay in headers; redirects are disabled and errors contain no payloads.
public struct V2ToolOperationHTTP:Sendable {
    public enum Failure:Error { case invalidConfiguration,invalidResponse,incomplete,status(Int) }
    private let baseURL:URL
    private let client:HTTPClient
    public init(baseURL:URL,caPath:String) throws {
        guard baseURL.scheme=="https",baseURL.host != nil,baseURL.user==nil,baseURL.password==nil,baseURL.query==nil,baseURL.fragment==nil else { throw Failure.invalidConfiguration }
        var tls=TLSConfiguration.makeClientConfiguration()
        tls.trustRoots = .certificates(try NIOSSLCertificate.fromPEMFile(caPath))
        self.baseURL=baseURL
        self.client=HTTPClient(eventLoopGroupProvider:.singleton,configuration:.init(tlsConfiguration:tls,redirectConfiguration:.disallow))
    }
    public func shutdown() async throws { try await client.shutdown() }
    public func request<Response:Decodable & Sendable>(path:String,token:String,deviceID:String,body:Data?=nil,maximumBodyBytes:Int=8192,as:Response.Type) async throws -> Response {
        try Task.checkCancellation()
        guard !token.isEmpty,!token.unicodeScalars.contains(where:{$0.value<32 || $0.value==127}),
              !deviceID.unicodeScalars.contains(where:{$0.value<32 || $0.value==127}),(1...1_048_576).contains(maximumBodyBytes),body.map({$0.count<=maximumBodyBytes}) ?? true else { throw Failure.invalidConfiguration }
        var request=HTTPClientRequest(url:baseURL.appending(path:path).absoluteString)
        request.method=body==nil ? .GET:.POST
        request.headers.add(name:"Authorization",value:"Bearer \(token)")
        request.headers.add(name:"X-IM-Device-ID",value:deviceID)
        request.headers.add(name:"Accept",value:"application/json")
        request.headers.add(name:"Cache-Control",value:"no-store")
        if let body { request.headers.add(name:"Content-Type",value:"application/json");request.body = .bytes(body) }
        let response=try await client.execute(request,timeout:.seconds(15))
        guard response.status.code==200 else { throw Failure.status(Int(response.status.code)) }
        guard response.headers.first(name:"Content-Type")?.lowercased().split(separator:";",maxSplits:1).first=="application/json" else { throw Failure.invalidResponse }
        let bytes=try await response.body.collect(upTo:65_536)
        return try JSONDecoder().decode(Response.self,from:Data(bytes.readableBytesView))
    }
    public func openDirectRoom(command:V2DirectRoomOperationCommand,token:String,deviceID:String) async throws -> RoomID {
        let recovery=try V2DirectRoomOperationRecoveryRequest(identity:command.identity,fingerprint:command.fingerprint,action:.query)
        var recovering=false
        for _ in 0..<5 {
            let body=try recovering ? JSONEncoder().encode(recovery):JSONEncoder().encode(command)
            let result=try await request(path:recovering ? "v2/direct-room-operations/operations/recover":"v2/direct-room-operations/submit",token:token,deviceID:deviceID,body:body,as:V2DirectRoomOperationResult.self)
            switch result {
            case .receipt(let receipt):
                guard receipt.validates(command:command),case .opened(let roomID,_)=receipt.outcome else { throw Failure.invalidResponse }
                return roomID
            case .processing(let proof):
                guard proof.validates(command:command) else { throw Failure.invalidResponse }
                recovering=true
            case .unresolved:recovering=true
            case .deferred,.fingerprintConflict:throw Failure.incomplete
            }
            try await Task.sleep(for:.seconds(1))
        }
        throw Failure.incomplete
    }
    /// One immutable command per tool operation; unresolved responses are queried
    /// under that identity. A transport failure is reported, never resubmitted
    /// with a replacement identity by this helper.
    public func sendMessage(_ command: V2MessageSendOperationCommand, token: String, deviceID: String) async throws -> V2MessageSendOperationTerminalOutcome {
        let identity = try command.identity, fingerprint = try command.fingerprint
        let recovery = try V2MessageSendOperationRecoveryRequest(identity: identity, fingerprint: fingerprint,
            domainFingerprint: command.command.fingerprint, action: .query)
        let prefix = "v2/rooms/\(command.command.roomID.rawValue)/message-operations/"
        for attempt in 0..<5 {
            let body = try attempt == 0 ? JSONEncoder().encode(command) : JSONEncoder().encode(recovery)
            let result = try await request(path: prefix + (attempt == 0 ? "send" : "recover"),
                token: token, deviceID: deviceID, body: body, maximumBodyBytes: 1_048_576, as: V2MessageSendOperationRecoveryResult.self)
            switch result {
            case .receipt(let receipt):
                guard receipt.validates(identity: identity, fingerprint: fingerprint) else { throw Failure.invalidResponse }
                return receipt.outcome
            case .unresolved: break
            case .deferred, .fingerprintConflict: throw Failure.incomplete
            }
            if attempt < 4 { try await Task.sleep(for: .seconds(1)) }
        }
        throw Failure.incomplete
    }

    public static func scoped<Value:Sendable>(baseURL:URL,caPath:String,operation:@Sendable (Self) async throws -> Value) async throws -> Value {
        let client=try Self(baseURL:baseURL,caPath:caPath)
        let result:Value
        do { result=try await operation(client) }
        catch { try? await client.shutdown();throw error }
        // Shutdown failures propagate without attempting to shut down a second time.
        try await client.shutdown()
        return result
    }
    public func changeRelationship(actor:UserID,target:UserID,action:V2RelationshipAction,token:String,deviceID:String) async throws {
        let baseline=try await request(path:"v2/social/targets/\(target.rawValue)/baseline",token:token,deviceID:deviceID,as:V2SocialOperationSnapshot.self)
        guard baseline.actorUserID==actor,baseline.targetUserID==target else { throw Failure.invalidResponse }
        let command=try V2SocialOperationCommand(identity:.init(accountID:actor,scope:.userPair(actor,target),operation:.relationship(.init(UUID().uuidString))),action:.relationship(action),expectedRevision:baseline.relationshipRevision,firstSubmissionDeadlineMilliseconds:UInt64(Date().timeIntervalSince1970*1000)+600_000)
        let recovery=try V2SocialOperationRecoveryRequest(identity:command.identity,fingerprint:command.fingerprint,action:.query)
        var recovering=false
        for _ in 0..<5 {
            let body=try recovering ? JSONEncoder().encode(recovery):JSONEncoder().encode(command)
            let result=try await request(path:"v2/social/operations/"+(recovering ? "recover":"submit"),token:token,deviceID:deviceID,body:body,as:V2SocialOperationRecoveryResult.self)
            switch result {
            case .receipt(let receipt):
                guard receipt.validates(command:command),case .applied=receipt.outcome else { throw Failure.invalidResponse }
                return
            case .unresolved:recovering.toggle()
            case .deferred,.fingerprintConflict:throw Failure.incomplete
            }
            try await Task.sleep(for:.seconds(1))
        }
        throw Failure.incomplete
    }

}

/// Owns only tool HTTP sends, including their event-loop completion callbacks.
public final class V2ToolHTTPSendTaskOwner: Sendable {
    private struct State { var closing = false; var tasks: [UUID: Task<Void, Never>] = [:] }
    private let state = Mutex(State())
    public init() {}
    @discardableResult public func start(id: UUID, operation: @escaping @Sendable () async -> Void) -> Bool {
        state.withLock { value in
            guard !value.closing, value.tasks[id] == nil else { return false }
            value.tasks[id] = Task {
                await operation()
                self.state.withLock { _ = $0.tasks.removeValue(forKey: id) }
            }
            return true
        }
    }
    public func cancel(id: UUID) { state.withLock { $0.tasks[id]?.cancel() } }
    public func closeAndDrain() async {
        let tasks = state.withLock { value in
            value.closing = true
            let tasks = Array(value.tasks.values)
            for task in tasks { task.cancel() }
            return tasks
        }
        for task in tasks { await task.value }
    }
}
