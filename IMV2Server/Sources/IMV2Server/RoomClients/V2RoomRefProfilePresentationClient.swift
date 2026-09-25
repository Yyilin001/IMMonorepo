import Foundation
import IMV2ActorContracts
import IMV2ActorRuntime
import IMV2Core

/// 联系人别名仍保存在用户存储中；只有房间范围内的昵称操作
/// 会通过已认证的房间能力。
public struct V2RoomRefProfilePresentationClient: V2ProfilePresentationManaging {
    private let aliases: any V2ProfilePresentationManaging
    private let caller: V2RoomRefUserCaller

    public init(aliases: any V2ProfilePresentationManaging, directory: V2RoomDirectory,
                callTimeout: Duration = .seconds(10)) {
        self.aliases = aliases
        self.caller = .init(directory: directory, timeout: callTimeout)
    }

    init(aliases: any V2ProfilePresentationManaging, caller: V2RoomRefUserCaller) {
        self.aliases = aliases
        self.caller = caller
    }

    public func contactAliases(ownerUserID: UserID, afterTargetUserID: UserID?, limit: Int) async throws -> V2ContactAliasPage {
        try await aliases.contactAliases(ownerUserID: ownerUserID,
            afterTargetUserID: afterTargetUserID, limit: limit)
    }

    public func updateContactAlias(ownerUserID: UserID, targetUserID: UserID,
                                   operationID: ContactAliasOperationID,
                                   expectedRevision: V2ProfileRevision?,
                                   remarkName: String?) async throws -> V2ContactAlias {
        try await aliases.updateContactAlias(ownerUserID: ownerUserID, targetUserID: targetUserID,
            operationID: operationID, expectedRevision: expectedRevision, remarkName: remarkName)
    }

    public func groupNicknames(actorUserID: UserID, roomID: RoomID,
                               afterUserID: UserID?, limit: Int) async throws -> V2GroupNicknamePage {
        let query = V2ActorGroupNicknamesQueryWire(roomID: roomID,
            actorUserID: actorUserID, afterUserID: afterUserID, limit: limit)
        try query.validateForDomain()
        guard case .administration(let result) = try await caller.call(
            .administrationQuery(.groupNicknames(query)), actor: actorUserID) else {
            throw V2ProfilePresentationError.corruptPersistenceState
        }
        switch result {
        case .groupNicknames(let value):
            let page = try value.domain()
            guard page.values.allSatisfy({ $0.roomID == roomID }) else {
                throw V2ProfilePresentationError.corruptPersistenceState
            }
            return page
        case .failure(let failure): throw try failure.domainError()
        default: throw V2ProfilePresentationError.corruptPersistenceState
        }
    }

    public func updateOwnGroupNickname(actorUserID: UserID, roomID: RoomID,
                                       operationID: GroupNicknameOperationID,
                                       expectedRevision: V2ProfileRevision?,
                                       nickname: String?) async throws -> V2GroupMemberPresentation {
        let command = V2ActorGroupNicknameUpdateWire(roomID: roomID, actorUserID: actorUserID,
            operationID: operationID, expectedRevision: expectedRevision, nickname: nickname)
        try command.validateForDomain()
        guard case .administration(let result) = try await caller.call(
            .administration(.groupNickname(command)), actor: actorUserID) else {
            throw V2RoomCallFailure.outcomeUnknown
        }
        switch result {
        case .groupNickname(let value):
            let presentation = try value.domain()
            guard presentation.roomID == roomID, presentation.userID == actorUserID else {
                throw V2ProfilePresentationError.corruptPersistenceState
            }
            return presentation
        case .failure(let failure): throw try failure.domainError()
        default: throw V2RoomCallFailure.outcomeUnknown
        }
    }
}
