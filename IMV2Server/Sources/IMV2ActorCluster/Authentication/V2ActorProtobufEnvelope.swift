import Foundation
import IMV2ActorContracts
import IMV2Core
import SwiftProtobuf

private func uuidBytes(_ value: UUID) -> Data {
    var tuple = value.uuid
    return withUnsafeBytes(of: &tuple) { Data($0) }
}
private func uuid(_ bytes: Data) throws -> UUID {
    guard bytes.count == 16 else { throw V2ActorAuthenticationError.invalidRequest }
    return bytes.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
}
private func hostWire(_ host: V2ActorHostIdentity) -> Im_Actor_V1_HostIdentity {
    var value = Im_Actor_V1_HostIdentity()
    value.hostID = host.hostID.rawValue; value.incarnationID = uuidBytes(host.incarnationID)
    return value
}
private func hostModel(_ value: Im_Actor_V1_HostIdentity) throws -> V2ActorHostIdentity {
    guard value.unknownFields.data.isEmpty else { throw V2ActorAuthenticationError.invalidRequest }
    return try .init(hostID: .init(value.hostID), incarnationID: uuid(value.incarnationID))
}

extension V2ActorAuthenticatedCall: V2ActorProtobufMessage {
    package func protobufBytes() throws -> Data {
        var value = Im_Actor_V1_AuthenticatedCall()
        value.version = Int64(version); value.serviceID = serviceID.rawValue
        value.callerIncarnation = uuidBytes(callerIncarnation); value.recipient = hostWire(recipient)
        value.sessionID = uuidBytes(sessionID); value.sequence = sequence
        value.attemptID = uuidBytes(attemptID); value.traceID = uuidBytes(traceID)
        value.remainingBudgetMs = UInt64(remainingBudget.rawValue)
        switch principal {
        case .user(let user): value.userID = user.rawValue
        case .service: value.service = true
        }
        value.requestBody = try V2ActorProtobuf.encode(request)
        return try value.serializedData()
    }
    package static func fromProtobufBytes(_ bytes: Data) throws -> Self {
        let value = try Im_Actor_V1_AuthenticatedCall(serializedBytes: bytes)
        guard value.unknownFields.data.isEmpty, value.hasRecipient, !value.requestBody.isEmpty,
              let version = Int(exactly: value.version), let budget = Int64(exactly: value.remainingBudgetMs)
        else { throw V2ActorAuthenticationError.invalidRequest }
        let principal: V2ActorCallPrincipal
        switch value.principal {
        case .userID(let user): principal = .user(try .init(user))
        case .service(true): principal = .service
        default: throw V2ActorAuthenticationError.invalidRequest
        }
        return try .init(version: version, serviceID: .init(value.serviceID),
            callerIncarnation: uuid(value.callerIncarnation), recipient: hostModel(value.recipient),
            sessionID: uuid(value.sessionID), sequence: value.sequence, attemptID: uuid(value.attemptID),
            traceID: uuid(value.traceID), remainingBudget: .init(budget), principal: principal,
            request: V2ActorProtobuf.decode(V2ActorRPCRequest.self, from: value.requestBody))
    }
}
extension V2ActorAuthenticatedReply: V2ActorProtobufMessage {
    package func protobufBytes() throws -> Data {
        var value = Im_Actor_V1_AuthenticatedReply()
        value.version = Int64(version); value.host = hostWire(host)
        value.sessionID = uuidBytes(sessionID); value.sequence = sequence; value.attemptID = uuidBytes(attemptID)
        value.responseBody = try V2ActorProtobuf.encode(response)
        return try value.serializedData()
    }
    package static func fromProtobufBytes(_ bytes: Data) throws -> Self {
        let value = try Im_Actor_V1_AuthenticatedReply(serializedBytes: bytes)
        guard value.unknownFields.data.isEmpty, value.hasHost, !value.responseBody.isEmpty,
              let version = Int(exactly: value.version) else { throw V2ActorAuthenticationError.invalidRequest }
        return try .init(version: version, host: hostModel(value.host), sessionID: uuid(value.sessionID),
            sequence: value.sequence, attemptID: uuid(value.attemptID),
            response: V2ActorProtobuf.decode(V2ActorRPCResponse.self, from: value.responseBody))
    }
}
