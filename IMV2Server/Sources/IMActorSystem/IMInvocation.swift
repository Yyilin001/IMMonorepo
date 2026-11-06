import Distributed
import Foundation
import NIOCore
import Synchronization
@_exported import IMActorTransport

public enum IMRemoteCall {
    @TaskLocal public static var deadline: ContinuousClock.Instant?
    public static func with<Value: Sendable>(timeout: Duration,
        operation: @Sendable () async throws -> Value) async throws -> Value {
        guard timeout > .zero else { throw IMActorError.deadlineExceeded }
        let end = min(deadline ?? .now + timeout, .now + timeout)
        try Task.checkCancellation()
        return try await $deadline.withValue(end) { try await operation() }
    }
}

public struct IMInvocationEncoder: DistributedTargetInvocationEncoder {
    public typealias SerializationRequirement = IMWireValue
    var bytes = ByteBuffer()
    var argumentTypes: [UInt32] = []
    var resultType: (any IMWireValue.Type)?
    let recording: Bool
    init(recording: Bool = false) { self.recording = recording }
    public mutating func recordGenericSubstitution<T>(_ type: T.Type) throws { throw IMActorError.unknownMethod }
    public mutating func recordArgument<Value: IMWireValue>(_ argument: RemoteCallArgument<Value>) throws {
        guard argumentTypes.count < 16 else { throw IMActorError.malformed }
        argumentTypes.append(Value.wireTypeID)
        if recording { return }
        bytes.writeInteger(Value.wireTypeID)
        let offset = bytes.writerIndex; bytes.writeInteger(UInt32(0))
        try argument.value.encodeWire(into: &bytes)
        let length = bytes.writerIndex - offset - 4
        guard length <= 16_777_216, bytes.readableBytes <= 33_554_432 else { throw IMActorError.overloaded }
        bytes.setInteger(UInt32(length), at: offset)
    }
    public mutating func recordReturnType<R: IMWireValue>(_ type: R.Type) throws { resultType = type }
    public mutating func recordErrorType<E: Error>(_ type: E.Type) throws {}
    public mutating func doneRecording() throws {}
}

public struct IMInvocationDecoder: DistributedTargetInvocationDecoder {
    public typealias SerializationRequirement = IMWireValue
    var bytes: ByteBuffer
    var resultType: (any IMWireValue.Type)?
    public mutating func decodeGenericSubstitutions() throws -> [Any.Type] { [] }
    public mutating func decodeNextArgument<Argument: IMWireValue>() throws -> Argument {
        guard try bytes.imRead(UInt32.self) == Argument.wireTypeID else { throw IMActorError.malformed }
        var argument = try bytes.imReadBytes(maximum: 16_777_216)
        let value = try Argument.decodeWire(from: &argument); try argument.imRequireEnd(); return value
    }
    public mutating func decodeErrorType() throws -> Any.Type? { (any Error).self }
    public mutating func decodeReturnType() throws -> Any.Type? { resultType }
}

final class IMResultBox: Sendable {
    let result = Mutex<IMTransportReply?>(nil)
    func store(_ reply: IMTransportReply) throws {
        try result.withLock { guard $0 == nil else { throw IMActorError.malformed }; $0 = reply }
    }
}
public struct IMInvocationResultHandler: DistributedTargetInvocationResultHandler {
    public typealias SerializationRequirement = IMWireValue
    let box: IMResultBox
    let allowedErrors: Set<UInt32>
    let reserveReply: @Sendable (Int) throws -> IMReplyReservation
    public func onReturn<Success: IMWireValue>(value: Success) async throws {
        let size = value.wireByteCount
        let reservation = try reserveReply(size)
        var body = ByteBuffer(); try value.encodeWire(into: &body)
        guard body.readableBytes == size else { throw IMActorError.malformed }
        try box.store(.init(body: body, reservation: reservation))
    }
    public func onReturnVoid() async throws { try box.store(.init(body: ByteBuffer())) }
    public func onThrow<Err: Error>(error: Err) async throws {
        if error is CancellationError { try box.store(.failure(.deadlineExceeded)); return }
        if let error = error as? IMActorError { try box.store(.failure(error)); return }
        if let value = error as? any IMWireValue, allowedErrors.contains(type(of: value).wireTypeID) {
            let size = value.wireByteCount + 4
            let reservation = try reserveReply(size)
            var body = ByteBuffer(); body.writeInteger(type(of: value).wireTypeID)
            try value.encodeWire(into: &body)
            guard body.readableBytes == size else { throw IMActorError.malformed }
            try box.store(.init(body: body, isFailure: true, reservation: reservation))
        } else { try box.store(.failure(.remoteFailure)) }
    }
}

public struct IMMethod: Sendable {
    public let id: UInt32
    public let traffic: IMTrafficClass
    let target: String
    let actorType: ObjectIdentifier
    let arguments: [UInt32]
    let result: (any IMWireValue.Type)?
    init(id: UInt32, traffic: IMTrafficClass, target: String, actorType: ObjectIdentifier,
         arguments: [UInt32], result: (any IMWireValue.Type)?) {
        self.id = id; self.traffic = traffic; self.target = target; self.actorType = actorType
        self.arguments = arguments; self.result = result
    }
}

public struct IMServiceKey<Act: DistributedActor>: Sendable where Act.ActorSystem == IMActorSystem {
    public let name: String
    public init(_ actor: Act.Type, id: String) { self.name = id }
}

public struct IMPeerSnapshot: Sendable {
    public let revision: UInt64
    public let available: [IMNode: Bool]
    /// Last loss revision survives a coalesced disconnect/reconnect snapshot.
    public let lossRevisions: [IMNode: UInt64]
}
