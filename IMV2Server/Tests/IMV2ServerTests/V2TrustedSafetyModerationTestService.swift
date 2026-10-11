import Foundation
import IMV2Core
import IMV2ServerApplication
import IMV2ServerContracts
import IMV2ServerInfrastructure

/// 审核命令的事件标识生成器。
public struct V2ModerationIDFactory: Sendable {
    private let makeUUID: @Sendable () -> UUID
    /// 注入 UUID 来源。
    ///
    /// - Parameter makeUUID: 产生原始 UUID 的闭包。
    public init(makeUUID: @escaping @Sendable () -> UUID = UUID.init) { self.makeUUID = makeUUID }

    /// 生成一个事件标识。
    ///
    /// - Returns: 本次命令使用的标识组合。
    /// - Throws: 标识类型拒绝生成值时抛出。
    public func make() throws -> EventID {
        try .init(makeUUID().uuidString)
    }
}

/// 面向普通审核者的审核服务。
public struct V2TrustedSafetyModerationService: Sendable {
    private let store: any V2TrustedSafetyModerationStore
    private let safetyActorUserID: UserID
    private let capacityProfile: V2CapacityProfile
    private let identifiers: V2ModerationIDFactory
    private let now: @Sendable () -> Date

    /// 组合审核存储与固定的安全主体。
    ///
    /// - Parameters:
    ///   - store: 执行特权审核的存储实现。
    ///   - safetyActorUserID: 服务配置的受信审计主体。
    ///   - capacityProfile: 固定的容量档位。
    ///   - identifiers: 事件标识生成器。
    ///   - now: 可注入的当前时刻读取函数。
    public init(store: any V2TrustedSafetyModerationStore, safetyActorUserID: UserID, capacityProfile: V2CapacityProfile, identifiers: V2ModerationIDFactory = .init(), now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.safetyActorUserID = safetyActorUserID
        self.capacityProfile = capacityProfile
        self.identifiers = identifiers
        self.now = now
    }

    /// 应用一次房间冻结或解冻控制。
    ///
    /// - Parameter request: 已认证的房间控制命令。
    /// - Returns: 审核结果。
    /// - Throws: 命令构造失败或存储判定失败时抛出。
    public func apply(_ request: V2TrustedSafetyRoomControl) async throws -> V2ModerationOutcome {
        try await apply(V2TrustedSafetyModeration(
            roomID: request.roomID,
            operationID: request.operationID,
            action: request.action,
            reasonCode: request.reasonCode
        ))
    }

    /// 应用一次特权安全审核命令。
    ///
    /// 命令中的发起者固定为部署时配置的安全主体，不接受调用方传入。
    ///
    /// - Parameter request: 特权安全审核命令。
    /// - Returns: 审核结果。
    /// - Throws: 命令构造失败、标识生成失败或存储判定失败时抛出。
    public func apply(_ request: V2TrustedSafetyModeration) async throws -> V2ModerationOutcome {
        let eventID = try identifiers.make()
        let command = try V2ModerationCommand(
            roomID: request.roomID,
            actorUserID: safetyActorUserID,
            operationID: request.operationID,
            action: request.action,
            messageID: request.messageID,
            expectedMessageRevision: request.expectedMessageRevision,
            reasonCode: request.reasonCode
        )
        return try await store.applyTrustedSafety(command: command, capacityProfile: capacityProfile, eventID: eventID, now: now())
    }
}

extension V2TrustedSafetyModerationService: V2ContentReviewSafetyApplying {}
