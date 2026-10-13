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
    case placementVote
    case placementRead
    case placementWrite
    /// Dedicated deployment authority, separate from room Hosts and callers.
    case placementExclude
    case realtimePublish
    case realtimeReceive
    case policyMutation
    case policyRegistration
}

public enum V2ActorCallPrincipal: Codable, Equatable, Sendable {
    case user(UserID)
    case service
}

/// 加密字节是下方封闭类型消息体的编码，而非按字符串分发的业务载荷。
/// 握手与发现使用 Ed25519；已协商会话使用 32 字节 HMAC 和会话前缀。
/// 接收方限制长度并认证原始字节后才解码，不重新编码业务消息体。
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
    public let agreementKey: Data?

    public init(version: Int = Self.protocolVersion, serviceID: V2ActorServiceID,
                callerIncarnation: UUID, recipient: V2ActorHostIdentity, handshakeID: UUID, agreementKey: Data? = nil) {
        self.version = version
        self.serviceID = serviceID
        self.callerIncarnation = callerIncarnation
        self.recipient = recipient
        self.handshakeID = handshakeID
        self.agreementKey = agreementKey
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
    public var agreementKey: Data? = nil
}

public enum V2ActorRPCRequest: Codable, Equatable, Sendable {
    case placementWrite(V2PlacementRaftWire)
    case placementRead(V2PlacementRaftWire)
    case placementRaft(V2PlacementRaftWire)
    case drainPlacement(V2ActorPlacementDrainWire)
    case activate(roomID: RoomID, owner: V2RoomDataOwner)
    case lookup(V2RoomActivationToken)
    case mutatePolicy(V2PolicyMutationWire)
    case policySnapshots(V2PolicySnapshotRequestWire)
    case updatePolicySnapshot(V2PolicySnapshotUpdateWire)
    case releasePolicyInterests(V2PolicyInterestReleaseWire)
    case forwardPair(token: V2RoomActivationToken, pair: V2ActorForwardPairWire)
    case invoke(token: V2RoomActivationToken, request: V2RoomRequest)
    case recoveryBatch([V2RoomRecoveryBatchWireItem])
    case reserve(token: V2RoomActivationToken, requestID: UUID)
    case markDispatched(V2RoomReservation)
    case abortReservation(V2RoomReservation)
    case finishReservation(V2RoomReservation, V2RoomReservationCompletion)
}

public enum V2ActorRPCResponse: Codable, Equatable, Sendable {
    /// 物理引用只保留在 Cluster 内；Runtime 的 RoomRef 只接触令牌。
    case placementWrite(V2PlacementRaftWire)
    case placementRead(V2PlacementRaftWire)
    case placementRaft(V2PlacementRaftWire)
    case placementDrained(V2ActorPlacementDrainedWire)
    case ready(token: V2RoomActivationToken, physicalReference: Data)
    case result(V2RoomResponse)
    case recoveryBatch([V2RoomRecoveryBatchWireOutcome])
    case reserved(V2RoomReservation)
    case completed(Bool)
    case acknowledged
    case policyMutationIdentityConflict(V2PolicyMutationWire)
    case policyMutationCommitted(V2PolicyMutationReceiptWire)
    case policySnapshots(V2PolicySnapshotBatchWire)
    case forwardPair(V2ActorForwardMessageResultWire)
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

    init(version: Int, host: V2ActorHostIdentity, sessionID: UUID, sequence: UInt64,
         attemptID: UUID, response: V2ActorRPCResponse) {
        self.version = version
        self.host = host
        self.sessionID = sessionID
        self.sequence = sequence
        self.attemptID = attemptID
        self.response = response
    }

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
