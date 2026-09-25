import Foundation
import IMV2ActorContracts
import IMV2Core

public enum V2ActorServiceIDTag: V2IdentifierTag {}
public typealias V2ActorServiceID = V2Identifier<V2ActorServiceIDTag>

/// 权限来自本地信任映射；请求不能自行声明角色。
public enum V2ActorServicePermission: String, Codable, Hashable, Sendable {
    case roomMaintenance
    case userRoomCalls
    case trustedSafety
    case specialAccountAudit
    case roomCoordination
}

public enum V2ActorCallPrincipal: Codable, Equatable, Sendable {
    case user(UserID)
    case service
}

/// 加密字节是下方封闭类型消息体的编码，而非按字符串分发的业务载荷。
/// 接收方先限制字节长度并验证原始签名，再解码为预期的消息体类型；
/// 验证其他平台发来的签名时，不会重新编码 JSON。
public struct V2ActorSignedPacket: Codable, Equatable, Sendable {
    public let signerID: V2ActorServiceID
    public let body: Data
    public let signature: Data

    public init(signerID: V2ActorServiceID, body: Data, signature: Data) {
        self.signerID = signerID
        self.body = body
        self.signature = signature
    }
}

public struct V2ActorSessionHello: Codable, Equatable, Sendable {
    public static let protocolVersion = 1
    public let version: Int
    public let serviceID: V2ActorServiceID
    public let callerIncarnation: UUID
    public let recipient: V2ActorHostIdentity
    public let handshakeID: UUID

    public init(version: Int = Self.protocolVersion, serviceID: V2ActorServiceID,
                callerIncarnation: UUID, recipient: V2ActorHostIdentity, handshakeID: UUID) {
        self.version = version
        self.serviceID = serviceID
        self.callerIncarnation = callerIncarnation
        self.recipient = recipient
        self.handshakeID = handshakeID
    }
}

public struct V2ActorSessionGrant: Codable, Equatable, Sendable {
    public let version: Int
    public let host: V2ActorHostIdentity
    public let serviceID: V2ActorServiceID
    public let callerIncarnation: UUID
    public let handshakeID: UUID
    public let sessionID: UUID
    public let remainingLifetime: V2ActorMilliseconds
}

public enum V2ActorRPCRequest: Codable, Equatable, Sendable {
    case activate(roomID: RoomID, owner: V2RoomDataOwner)
    case lookup(V2RoomActivationToken)
    case invoke(token: V2RoomActivationToken, request: V2RoomRequest)
    case reserve(token: V2RoomActivationToken, requestID: UUID)
    case markDispatched(V2RoomReservation)
    case abortReservation(V2RoomReservation)
    case finishReservation(V2RoomReservation, V2RoomReservationCompletion)
}

public enum V2ActorRPCResponse: Codable, Equatable, Sendable {
    /// 物理引用只保留在 Cluster 内；Runtime 的 RoomRef 只接触令牌。
    case ready(token: V2RoomActivationToken, physicalReference: Data)
    case occupied(V2RoomActivationLease)
    case result(V2RoomResponse)
    case reserved(V2RoomReservation)
    case completed(Bool)
    case acknowledged
    case failure(V2RoomCallFailure)
}

public struct V2ActorAuthenticatedCall: Codable, Equatable, Sendable {
    public let version: Int
    public let serviceID: V2ActorServiceID
    public let callerIncarnation: UUID
    public let recipient: V2ActorHostIdentity
    public let sessionID: UUID
    public let sequence: UInt64
    public let attemptID: UUID
    public let traceID: UUID
    public let remainingBudget: V2ActorMilliseconds
    public let principal: V2ActorCallPrincipal
    public let request: V2ActorRPCRequest

    public init(version: Int = V2ActorSessionHello.protocolVersion,
                serviceID: V2ActorServiceID, callerIncarnation: UUID, recipient: V2ActorHostIdentity,
                sessionID: UUID, sequence: UInt64, attemptID: UUID, traceID: UUID,
                remainingBudget: V2ActorMilliseconds, principal: V2ActorCallPrincipal,
                request: V2ActorRPCRequest) {
        self.version = version
        self.serviceID = serviceID
        self.callerIncarnation = callerIncarnation
        self.recipient = recipient
        self.sessionID = sessionID
        self.sequence = sequence
        self.attemptID = attemptID
        self.traceID = traceID
        self.remainingBudget = remainingBudget
        self.principal = principal
        self.request = request
    }
}

public struct V2ActorAuthenticatedReply: Codable, Equatable, Sendable {
    public let version: Int
    public let host: V2ActorHostIdentity
    public let sessionID: UUID
    public let sequence: UInt64
    public let attemptID: UUID
    public let response: V2ActorRPCResponse

    public init(call: V2ActorAuthenticatedCall, response: V2ActorRPCResponse) {
        self.version = V2ActorSessionHello.protocolVersion
        self.host = call.recipient
        self.sessionID = call.sessionID
        self.sequence = call.sequence
        self.attemptID = call.attemptID
        self.response = response
    }
}

public enum V2ActorAuthenticationError: Error, Equatable, Codable, Sendable {
    case invalidConfiguration
    case oversized
    case invalidSignature
    case unknownService
    case invalidRequest
    case unsupportedVersion
    case wrongRecipient
    case forbidden
    case sessionExpired
    case replay
    case overloaded
}
