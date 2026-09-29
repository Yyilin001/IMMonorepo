import IMV2ServerContracts
import Foundation
import IMV2ActorContracts
import IMV2Core

public enum V2ActorAdministrationWireError: Error, Equatable, Sendable {
    case invalidPermissionList
    case invalidDate
    case invalidPageLimit
    case invalidRetryAfter
    case trustedActionOnUserLane
    case unsupportedAuthenticatedRevision
}

private func v2ActorPermissions(_ values: [V2GroupPermission]) throws -> Set<V2GroupPermission> {
    let set = Set(values)
    guard set.count == values.count, values.count <= V2GroupPermission.allCases.count else {
        throw V2ActorAdministrationWireError.invalidPermissionList
    }
    return set
}

func v2ActorSortedPermissions(_ values: Set<V2GroupPermission>) -> [V2GroupPermission] {
    values.sorted { $0.rawValue < $1.rawValue }
}

func v2ActorValidateDate(_ value: Date) throws {
    guard value.timeIntervalSince1970.isFinite else {
        throw V2ActorAdministrationWireError.invalidDate
    }
}

extension V2ActorTrustedSafetyWire {
    public init(_ request: V2TrustedSafetyRoomControl) {
        self.init(roomID: request.roomID, operationID: request.operationID,
                  action: request.action, messageID: nil, expectedMessageRevision: nil,
                  reasonCode: request.reasonCode.rawValue)
    }

    public init(_ request: V2TrustedSafetyModeration) {
        self.init(roomID: request.roomID, operationID: request.operationID,
                  action: request.action, messageID: request.messageID,
                  expectedMessageRevision: request.expectedMessageRevision,
                  reasonCode: request.reasonCode.rawValue)
    }

    public func trustedModeration() throws -> V2TrustedSafetyModeration {
        if let revision = expectedMessageRevision {
            guard revision > 0, revision <= UInt64(Int64.max) else {
                throw V2RevisionValidationError.outOfRange
            }
        }
        return try .init(roomID: roomID, operationID: operationID, action: action,
                         messageID: messageID, expectedMessageRevision: expectedMessageRevision,
                         reasonCode: V2ModerationReasonCode(reasonCode))
    }

    public func trustedRoomControl() throws -> V2TrustedSafetyRoomControl {
        guard messageID == nil, expectedMessageRevision == nil else {
            throw V2ModerationValidationError.invalidActionShape
        }
        return try .init(roomID: roomID, operationID: operationID, action: action,
                         reasonCode: V2ModerationReasonCode(reasonCode))
    }
}

extension V2ActorGroupNicknameUpdateWire {
    /// 在把既有的参数式 API 调用传给远程执行器前，先校验输入。
    public func validateForDomain() throws {
        guard let initialRevision = V2ProfileRevision(rawValue: 1) else {
            throw V2RevisionValidationError.outOfRange
        }
        _ = try V2GroupMemberPresentation(roomID: roomID, userID: actorUserID,
                                           groupNickname: nickname, revision: initialRevision)
    }
}

extension V2ActorGroupNicknamesQueryWire {
    public func validateForDomain() throws {
        guard (1...500).contains(limit) else { throw V2ActorAdministrationWireError.invalidPageLimit }
    }
}
