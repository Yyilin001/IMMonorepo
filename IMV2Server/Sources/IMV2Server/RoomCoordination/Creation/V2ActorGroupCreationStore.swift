import Foundation
import IMV2ActorContracts
import IMV2Core

/// 由组合根提供的类型化引导派发。它选择固定分片，
/// 不查找未知房间，也不调用普通的 RoomRef。
public struct V2ActorCreationBootstrapPort: Sendable {
    public let execute: @Sendable (V2ActorRoomBootstrapCommand, ContinuousClock.Instant) async throws -> V2ActorRoomCreationResult
    public let stage: @Sendable (V2ActorGroupCreationIntentWire, V2ActorGroupCreationManifestPageWire,
                                 ContinuousClock.Instant) async throws -> Void

    public init(execute: @escaping @Sendable (V2ActorRoomBootstrapCommand, ContinuousClock.Instant) async throws -> V2ActorRoomCreationResult,
                stage: @escaping @Sendable (V2ActorGroupCreationIntentWire, V2ActorGroupCreationManifestPageWire,
                                            ContinuousClock.Instant) async throws -> Void) {
        self.execute = execute
        self.stage = stage
    }
}
