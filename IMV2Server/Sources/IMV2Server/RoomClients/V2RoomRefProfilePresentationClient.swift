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

    public func contactAliasSnapshot(ownerUserID:UserID,targetUserID:UserID) async throws -> V2ContactAliasSnapshot {
        try await aliases.contactAliasSnapshot(ownerUserID:ownerUserID,targetUserID:targetUserID)
    }
    public func updateContactAlias(_ command:V2ContactAliasUpdateCommand) async throws -> V2ContactAliasUpdateReceipt {
        try await aliases.updateContactAlias(command)
    }
    public func recoverContactAlias(_ request:V2ContactAliasRecoveryRequest) async throws -> V2ContactAliasRecoveryResult {
        try await aliases.recoverContactAlias(request)
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

    public func ownGroupNicknameSnapshot(actorUserID:UserID,roomID:RoomID) async throws -> V2GroupNicknameSnapshot {
        let result=try await invoke(.administrationQuery(.ownGroupNickname(.init(roomID:roomID,actorUserID:actorUserID))),actor:actorUserID)
        guard case .ownGroupNickname(let value)=result,value.actorUserID==actorUserID,value.roomID==roomID else { throw V2RoomCallFailure.outcomeUnknown };return value
    }
    public func updateOwnGroupNickname(_ command:V2GroupNicknameUpdateCommand) async throws -> V2GroupNicknameUpdateReceipt {
        let result=try await invoke(.administration(.groupNickname(.init(command:command))),actor:command.actorUserID)
        guard case .groupNickname(let receipt)=result,receipt.validates(command) else { throw V2RoomCallFailure.outcomeUnknown };return receipt
    }
    public func recoverGroupNickname(_ request:V2GroupNicknameRecoveryRequest) async throws -> V2GroupNicknameRecoveryResult {
        let result=try await invoke(.administration(.groupNicknameRecovery(request)),actor:request.actorUserID)
        guard case .groupNicknameRecovery(let recovery)=result else { throw V2RoomCallFailure.outcomeUnknown }
        if case .receipt(let receipt)=recovery { guard receipt.identity==request.identity,receipt.fingerprint==request.fingerprint else { throw V2RoomCallFailure.outcomeUnknown } }
        guard request.action != .closeIfAbsent || recovery != .unresolved else { throw V2RoomCallFailure.outcomeUnknown };return recovery
    }
    private func invoke(_ request:V2RoomRequest,actor:UserID) async throws -> V2RoomAdministrationResult {
        guard case .administration(let result)=try await caller.call(request,actor:actor) else { throw V2RoomCallFailure.outcomeUnknown }
        if case .failure(let failure)=result { throw try failure.domainError() };return result
    }
}
