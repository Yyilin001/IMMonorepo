import Foundation
import IMV2ActorContracts
import IMV2Core

/// 封闭的启动例外：尚未创建的房间还没有激活租约。
/// 调用方通过固定分片标识选定现有所有者，绝不通过解析未知房间来选择。
public struct V2RoomBootstrapDomainExecutor: Sendable {
    private let shardID: String
    private let direct: any V2DirectMessagingStore
    private let group: any V2ControlValidatedStagedGroupMessagingStore
    private let capacityProfile: V2CapacityProfile
    private let now: @Sendable () -> Date

    public init(shardID: String, direct: any V2DirectMessagingStore,
                group: any V2ControlValidatedStagedGroupMessagingStore,
                capacityProfile: V2CapacityProfile,
                now: @escaping @Sendable () -> Date = Date.init) throws {
        guard !shardID.isEmpty, shardID == shardID.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw V2GroupMessagingPolicyError.invalidRoomShard
        }
        self.shardID = shardID
        self.direct = direct
        self.group = group
        self.capacityProfile = capacityProfile
        self.now = now
    }

    public func execute(_ input: V2ActorRoomBootstrapCommand) async throws -> V2ActorRoomCreationResult {
        switch input {
        case .direct(let value):
            guard value.roomShardID == shardID else { throw V2GroupMessagingPolicyError.invalidRoomShard }
            let result = try await direct.open(command: value.validatedCommand(),
                capacityProfile: capacityProfile, roomShardID: shardID,
                roomID: value.roomID, now: now())
            return .direct(.init(domain: result))
        case .group(let value):
            let command = try value.validatedCommand()
            let intent = try value.intent.toDomain()
            guard intent.roomShardID == shardID, intent.roomID == input.roomID,
                  intent.routeEpoch == 0,
                  intent.requestFingerprint == (try groupCreationFingerprint(command)) else {
                throw V2GroupRoomCreationIntentStoreError.invalidIntent
            }
            let result = try await group.createControlValidated(command: command,
                validatedMemberUserIDs: value.validatedMemberUserIDs,
                capacityProfile: capacityProfile, roomShardID: shardID,
                roomID: intent.roomID, eventID: intent.eventID, now: now())
            return .group(.init(domain: result))
        case .stagedGroup(let value):
            let command = try value.validatedCommand()
            let intent = try value.intent.toDomain()
            guard intent.roomShardID == shardID, intent.roomID == input.roomID,
                  intent.routeEpoch == 0,
                  intent.requestFingerprint == (try stagedGroupCreationFingerprint(command)) else {
                throw V2GroupRoomCreationIntentStoreError.invalidIntent
            }
            let result = try await group.createControlValidatedStaged(command: command,
                intent: intent, capacityProfile: capacityProfile, now: now())
            return .group(.init(domain: result))
        }
    }

    public func stage(intent wireIntent: V2ActorGroupCreationIntentWire,
                      page wirePage: V2ActorGroupCreationManifestPageWire) async throws {
        let intent = try wireIntent.toDomain()
        guard intent.roomShardID == shardID, intent.routeEpoch == 0 else {
            throw V2GroupRoomCreationIntentStoreError.invalidIntent
        }
        try await group.stageControlValidatedAudience(intent: intent,
            page: wirePage.toDomain(), now: now())
    }
}
