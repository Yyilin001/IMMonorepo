import IMV2ServerContracts
import Foundation
import IMV2Core

/// 把已认证发送输入转换为领域命令，并交给准入或存储完成接受。
///
/// 本层执行命令构造校验，为一次调用固定时间与标识；房间权限、幂等竞争和原子提交由存储边界负责。
/// 配置批处理器时走其准入路径，否则直接调用单命令存储。
public struct V2SendMessageService: Sendable {
    /// 直接接受单命令的持久化实现。
    private let store: any V2RoomWriteStore
    /// 可选的有序准入实现。
    private let batcher: (any V2SendMessageAdmission)?
    /// 本服务采用的房间容量配置。
    private let capacityProfile: V2CapacityProfile
    /// 领域命令构造时使用的内容限制。
    private let limits: V2MessageCommandLimits
    /// 为接受请求生成稳定标识的工厂。
    private let idFactory: V2AcceptanceIDFactory
    /// 每次发送读取一次的可注入时间来源。
    private let now: @Sendable () -> Date

    /// 报告批处理器是否管理数据库工作所需的前台写入许可。
    ///
    /// 启用后 Gateway 不应为每个排队消息重复保留许可，避免尚未开始的批次耗尽前台通道。
    var managesForegroundWriteAdmission: Bool {
        batcher?.managesForegroundWriteAdmission ?? false
    }

    /// 配置发送服务及其可注入依赖。
    ///
    /// - Parameters:
    ///   - store: 单命令持久化边界。
    ///   - capacityProfile: 与房间持久化配置核对的容量策略。
    ///   - limits: 消息命令校验限制。
    ///   - idFactory: 接受标识生成器，默认使用进程共享生产生成器。
    ///   - batcher: 可选的有序准入实现；存在时发送通过它执行。
    ///   - now: 接受时间来源，每次发送读取一次。
    public init(
        store: any V2RoomWriteStore,
        capacityProfile: V2CapacityProfile,
        limits: V2MessageCommandLimits,
        idFactory: V2AcceptanceIDFactory = .init(),
        batcher: (any V2SendMessageAdmission)? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.batcher = batcher
        self.capacityProfile = capacityProfile
        self.limits = limits
        self.idFactory = idFactory
        self.now = now
    }

    /// 校验发送内容，准备不可变写入请求并等待接受结果。
    ///
    /// - Parameter request: 已由传输边缘绑定可信用户身份的发送输入；本方法不验证认证凭证。
    /// - Returns: 新接受、原回执重放、冲突、限流、不可用或私聊策略拒绝结果。
    /// - Throws: 命令校验、标识生成、准入或持久化执行的错误。
    ///
    /// 时间仅读取一次，生成的标识随请求交给批处理器；同一批次内部重试不得重新生成。
    public func send(_ request: V2AuthenticatedSendMessage) async throws -> V2SendMessageOutcome {
        let command = try V2SendMessageCommand(
            roomID: request.roomID,
            senderUserID: request.actorUserID,
            clientMessageID: request.clientMessageID,
            text: request.text,
            media: request.media,
            mentions: request.mentions,
            entities: request.entities,
            replyTo: request.replyTo,
            limits: limits
        )
        let acceptedAt = now()
        let prepared = V2RoomWriteRequest(
            command: command,
            capacityProfile: capacityProfile,
            identifiers: try idFactory.make(at: acceptedAt),
            now: acceptedAt
        )
        if let batcher {
            return try await batcher.accept(prepared)
        }
        return try await store.accept(
            command: prepared.command,
            capacityProfile: prepared.capacityProfile,
            identifiers: prepared.identifiers,
            now: prepared.now
        )
    }
}
