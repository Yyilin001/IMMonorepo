import Foundation
import IMV2ActorContracts
import IMV2Core

/// 封闭的启动例外：尚未创建的房间还没有激活租约。
/// 调用方通过固定分片标识选定现有所有者，绝不通过解析未知房间来选择。
public struct V2RoomBootstrapDomainExecutor: Sendable {
    private let shardID: String
    private let direct: PostgresV2DirectMessagingStore
    private let group: PostgresV2GroupMessagingStore
    private let capacityProfile: V2CapacityProfile
    private let now: @Sendable () -> Date

    public init(shardID: String, direct: PostgresV2DirectMessagingStore,
                group: PostgresV2GroupMessagingStore,
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
        case .provenDirect(let value):
            guard value.roomShardID == shardID, value.roomID.uuidValue != nil else { throw V2GroupMessagingPolicyError.invalidRoomShard }
            return .provenDirect(try await direct.submitDirectRoomOperation(value.command, roomID:value.roomID,
                roomShardID:shardID, capacityProfile:capacityProfile, now:now()))
        case .provenDirectRecovery(let value):
            guard value.roomShardID == shardID else { throw V2GroupMessagingPolicyError.invalidRoomShard }
            return .provenDirect(try await direct.recoverDirectRoomOperation(value.request, now:now()))
        case .provenGroup(let value):
            let placement=try value.placement.toDomain()
            guard placement.roomShardID==shardID,placement.routeEpoch==0,placement.roomID==input.roomID else { throw V2GroupRoomCreationIntentStoreError.invalidIntent }
            return .provenGroup(try await group.createProvenGroup(intent:value.intent,placement:placement,capacityProfile:capacityProfile,now:now()))

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
