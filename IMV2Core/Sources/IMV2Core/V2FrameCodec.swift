import Foundation

/// protobuf 包体之外的稳定二进制命令码。
///
/// 使用结构体保留未知值，使协议边缘可报告升级或不支持错误，而不让帧解码失去同步。
/// 构造命令码不表示服务端支持该业务；可用性、权限和请求／响应方向由上层验证。
public struct V2FrameCommand: RawRepresentable, Equatable, Hashable, Sendable {
    /// 命令在固定帧头中的 16 位无符号编码。
    public let rawValue: UInt16

    /// 保留给定命令码，包括当前实现尚未定义的值。
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let messageSendOperation = Self(rawValue: 127)
    public static let messageSendOperationRecover = Self(rawValue: 128)
    public static let messageSendOperationResult = Self(rawValue: 129)
    public static let realtimeCoverage = Self(rawValue: 130)
    public static let deviceRoomProgressReport = Self(rawValue: 131)
    public static let deviceRoomProgressRecorded = Self(rawValue: 132)

    public var isMessageSendOperation: Bool {
        self == .messageSendOperation || self == .messageSendOperationRecover || self == .messageSendOperationResult
    }

    public static let presencePublicationControl = Self(rawValue:125)
    public static let presencePublicationControlled = Self(rawValue:126)
    /// 客户端声明可用版本与能力的启动请求。
    public static let clientHello = Self(rawValue: 1)
    /// 服务端版本与能力协商响应。
    public static let serverHello = Self(rawValue: 2)
    /// 客户端认证请求。
    public static let authenticate = Self(rawValue: 3)
    /// 认证成功响应。
    public static let authenticated = Self(rawValue: 4)
    /// 连接心跳请求。
    public static let heartbeat = Self(rawValue: 5)
    /// 心跳确认。
    public static let heartbeatAck = Self(rawValue: 6)
    /// 消息发送请求。
    /// 消息接受响应。
    public static let messageAccepted = Self(rawValue: 21)
    /// 成员资格变更请求。
    /// 成员资格变更结果。
    public static let membershipChanged = Self(rawValue: 23)
    /// 消息撤回请求。
    /// 消息撤回结果。
    public static let messageWithdrawn = Self(rawValue: 25)
    /// 消息回应变更请求。
    /// 消息回应变更结果。
    public static let messageReactionChanged = Self(rawValue: 27)
    /// 消息编辑请求。
    /// 消息编辑结果。
    public static let messageEdited = Self(rawValue: 29)
    /// 已读水位记录请求。
    public static let recordReadReceipt = Self(rawValue: 41)
    /// 已读水位记录结果。
    public static let readReceiptRecorded = Self(rawValue: 42)
    /// 打开私聊请求。
    /// 私聊打开结果。
    /// 陌生人消息接收策略设置。
    /// 陌生人消息接收策略设置结果。
    public static let strangerMessagePermissionSet = Self(rawValue: 46)
    /// 联系人关系变更请求。
    /// 联系人关系变更结果。
    public static let relationshipChanged = Self(rawValue: 48)
    /// 用户屏蔽变更请求。
    /// 用户屏蔽变更结果。
    public static let userBlockChanged = Self(rawValue: 50)
    /// 消息治理请求。
    /// 消息治理后的内容移除结果。
    /// 成员禁言请求。
    /// 成员禁言结果。
    public static let memberMuted = Self(rawValue: 54)
    /// 治理角色移除成员请求。
    /// 治理移除成员结果。
    public static let memberRemovedByModerator = Self(rawValue: 56)
    /// 群房间创建完成结果。
    /// 成员目录分页请求。
    public static let listRoomMembers = Self(rawValue: 59)
    /// 成员目录分页响应。
    public static let roomMembersPage = Self(rawValue: 60)
    /// 房间事件增量拉取。
    public static let groupEventPull = Self(rawValue: 61)
    /// 房间事件分页响应。
    public static let groupEventPage = Self(rawValue: 62)
    /// 订阅房间事件可用提示。
    public static let groupEventSubscribe = Self(rawValue: 63)
    /// 房间事件订阅确认。
    public static let groupEventSubscribed = Self(rawValue: 64)
    /// 取消房间事件提示订阅。
    public static let groupEventUnsubscribe = Self(rawValue: 65)
    /// 房间新事件可用提示，不作为可靠投递确认。
    public static let groupEventAvailable = Self(rawValue: 66)
    /// 开始分阶段群创建。
    /// 群创建准备结果。
    /// 追加群创建初始成员批次。
    /// 初始成员批次追加结果。
    /// 提交群创建最终确认。
    /// 取消尚可取消的群创建。
    /// 群创建取消结果。
    /// 设置允许被添加的策略。
    /// 被添加策略设置结果。
    public static let userAddPermissionSet = Self(rawValue: 75)
    /// 设置已读回执偏好。
    /// 已读回执偏好设置结果。
    public static let readReceiptPreferencesSet = Self(rawValue: 77)
    /// 查询已读者分页。
    public static let listReadReceiptReaders = Self(rawValue: 78)
    /// 已读者分页响应。
    public static let readReceiptReadersPage = Self(rawValue: 79)
    /// 设置实时活动偏好。
    /// 实时活动偏好设置结果。
    public static let liveActivityPreferencesSet = Self(rawValue: 81)
    /// 订阅在线状态。
    public static let subscribePresence = Self(rawValue: 82)
    /// 在线状态订阅确认。
    public static let presenceSubscribed = Self(rawValue: 83)
    /// 取消在线状态订阅。
    public static let unsubscribePresence = Self(rawValue: 84)
    /// 订阅输入状态。
    public static let subscribeTyping = Self(rawValue: 85)
    /// 取消输入状态订阅。
    public static let unsubscribeTyping = Self(rawValue: 86)
    /// 更新本端输入状态。
    public static let setTypingState = Self(rawValue: 87)
    /// 输入状态变化通知。
    public static let typingStateChanged = Self(rawValue: 88)
    /// 在线状态变化通知。
    public static let presenceChanged = Self(rawValue: 89)
    /// 个人可靠同步增量拉取。
    public static let syncPull = Self(rawValue: 30)
    /// 个人同步批次响应。
    public static let syncBatch = Self(rawValue: 31)
    /// 确认已持久化的增量范围。
    public static let syncAck = Self(rawValue: 32)
    /// 要求进入快照恢复。
    public static let resetRequired = Self(rawValue: 33)
    /// 确认快照导入协议阶段。
    public static let snapshotAck = Self(rawValue: 34)
    /// 通用确认响应。
    public static let acknowledged = Self(rawValue: 35)
    /// 请求同步快照。
    public static let syncSnapshot = Self(rawValue: 36)
    /// 快照 manifest 响应。
    public static let snapshotManifest = Self(rawValue: 37)
    /// 请求快照页。
    public static let snapshotPagePull = Self(rawValue: 38)
    /// 快照页响应。
    public static let snapshotPage = Self(rawValue: 39)
    /// 个人同步可用提示，不替代持久游标。
    public static let syncAvailable = Self(rawValue: 40)
    /// 结构化错误响应。
    public static let error = Self(rawValue: 90)
    /// 查询实时活动偏好。
    public static let getLiveActivityPreferences = Self(rawValue: 91)
    /// 实时活动偏好查询结果。
    public static let liveActivityPreferences = Self(rawValue: 92)
    /// 设置会话本地同步偏好。
    public static let setConversationState = Self(rawValue: 93)
    /// 会话偏好设置结果。
    public static let personalPreferenceReceipt = Self(rawValue: 124)
    public static let conversationStateSet = Self(rawValue: 94)
    /// 设置消息收藏状态。
    public static let setMessageFavorite = Self(rawValue: 95)
    /// 消息收藏变更结果。
    public static let messageFavoriteChanged = Self(rawValue: 96)
    /// 设置群消息置顶状态。
    /// 群消息置顶变更结果。
    public static let pinnedMessageChanged = Self(rawValue: 98)
    /// 设置群公告。
    /// 群公告变更结果。
    public static let groupAnnouncementChanged = Self(rawValue: 100)
    /// 设置群角色权限策略。
    /// 群角色权限策略变更结果。
    public static let groupRolePermissionsChanged = Self(rawValue: 102)
    /// 变更群成员角色。
    /// 群成员角色变更结果。
    public static let groupMemberRoleChanged = Self(rawValue: 104)
    /// 分块转发消息请求。
    /// 分块转发结果。
    /// 请求群角色权限基线。
    public static let getGroupRolePolicyBaseline = Self(rawValue: 107)
    /// 群角色权限基线响应。
    public static let groupRolePolicyBaseline = Self(rawValue: 108)
    public static let userRoomDirectoryList = Self(rawValue: 111)
    public static let userRoomDirectoryPage = Self(rawValue: 112)
    public static let roomSyncStateBatch = Self(rawValue: 113)
    public static let roomSyncStateBatchResult = Self(rawValue: 114)
    public static let accountRoomChangesStart = Self(rawValue: 115)
    public static let accountRoomChangesReady = Self(rawValue: 116)
    public static let accountRoomResyncRequired = Self(rawValue: 118)
    public static let roomLatestVisibleBatch = Self(rawValue: 119)
    public static let roomLatestVisibleBatchResult = Self(rawValue: 120)
    /// Recipient-specific, negotiated, ephemeral author supplement.
    public static let authorPresentationDelta = Self(rawValue: 121)
    /// 按精确 stream、room、view 停止可选补充，不取消房间订阅。
    public static let authorPresentationEnd = Self(rawValue: 122)
    public static let authorPresentationEnded = Self(rawValue: 123)

}

/// 帧头标志集合；构造保留位值，上层负责验证协商与适用命令。
public struct V2FrameFlags: OptionSet, Equatable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// 包体已压缩的标记，仅在版本和压缩协商成功后适用。
    ///
    /// 本帧 codec 不解压；调用者必须独立限制解压后的字节数。
    public static let compressed = Self(rawValue: 1 << 0)

    /// 房间事件页的请求关联仅绑定已认证帧头，包体 request_id 为零。
    ///
    /// 此表示自协议 v21 引入，使同一不可变包体可被不同授权连接复用；并非任意命令均可使用。
    public static let headerBoundRequestID = Self(rawValue: 1 << 1)
}

/// 完整协议帧的值表示，包含固定帧头字段和 opaque 包体。
///
/// 构造器不执行协商、大小或 payload 业务验证；编码器与会话边缘各自承担对应检查。
public struct V2Frame: Equatable, Sendable {
    /// 帧魔数 0x494D，对应网络字节序的 IM。
    public static let magic: UInt16 = 0x494D // "IM" in network byte order.
    /// 固定头长 18 字节：魔数 2、版本 1、标志 1、命令 2、请求 ID 8、包体长度 4。
    public static let headerLength = 18

    /// 该帧使用的协议版本；bootstrap Hello 使用零，后续使用协商结果。
    public let version: UInt8
    /// 压缩与请求关联等编码标记，不包含认证结论。
    public let flags: V2FrameFlags
    /// 帧类型；与 protobuf 内容一致性由协议边缘验证。
    public let command: V2FrameCommand
    /// 请求／响应关联 ID；非零及占用约束由连接状态或相应通知合同检查。
    public let requestID: UInt64
    /// 未在此层解释的包体字节，可能为按标志编码的 protobuf 数据。
    public let payload: Data

    /// 保存帧字段，不执行业务验证或网络 I/O。
    ///
    /// - Parameters:
    ///   - version: 待编码的协议版本。
    ///   - flags: 包体表示与关联标志，默认无标记。
    ///   - command: 16 位命令码。
    ///   - requestID: 传输关联身份，通知的零值语义由上层决定。
    ///   - payload: 完整包体，不含固定帧头。
    public init(version: UInt8, flags: V2FrameFlags = [], command: V2FrameCommand, requestID: UInt64, payload: Data) {
        self.version = version
        self.flags = flags
        self.command = command
        self.requestID = requestID
        self.payload = payload
    }
}

/// 帧解码与编码的版本／包体预算，以及单次解码调度上限。
public struct V2FrameLimits: Equatable, Sendable {
    /// 允许的包体字节上限，不包含 18 字节帧头；构造时限定为线格式 UInt32 可表达范围。
    public let maximumPayloadBytes: Int
    /// v45 send operation frame ceiling; ordinary commands retain maximumPayloadBytes.
    public let maximumMessageSendPayloadBytes: Int
    /// 一次 append 最多返回的完整帧数，范围为 1...4096。
    ///
    /// TCP 合并读中的超额完整帧留在缓冲区，后续以空 Data 继续 drain，而不是将有效数据误判为非法。
    public let maximumFramesPerAppend: Int
    /// codec 接受的非空版本集合；不替代连接状态机的版本协商。
    public let acceptedVersions: Set<UInt8>

    public init(
        maximumPayloadBytes: Int,
        maximumMessageSendPayloadBytes: Int = V2MessageSendWireLimits.maximumPayloadBytes,
        maximumFramesPerAppend: Int = 256,
        acceptedVersions: Set<UInt8>
    ) throws {
        guard maximumPayloadBytes >= 0,
              UInt32(exactly: maximumPayloadBytes) != nil,
              maximumMessageSendPayloadBytes >= 0,
              UInt32(exactly: maximumMessageSendPayloadBytes) != nil,
              maximumMessageSendPayloadBytes <= Int.max - V2Frame.headerLength,
              maximumPayloadBytes <= Int.max - V2Frame.headerLength,
              maximumFramesPerAppend > 0,
              maximumFramesPerAppend <= 4_096,
              !acceptedVersions.isEmpty
        else {
            throw V2FrameCodecError.invalidLimits
        }
        self.maximumPayloadBytes = maximumPayloadBytes
        self.maximumMessageSendPayloadBytes = maximumMessageSendPayloadBytes
        self.maximumFramesPerAppend = maximumFramesPerAppend
        self.acceptedVersions = acceptedVersions
    }

    public func maximumPayloadBytes(for command: V2FrameCommand, version: UInt8) -> Int {
        command.isMessageSendOperation && version >= 45 ? maximumMessageSendPayloadBytes : maximumPayloadBytes
    }
}

public enum V2MessageSendWireLimits {
    public static let maximumPayloadBytes = 1_052_672 // 1 MiB + 4 KiB
}

/// 帧配置、固定头、长度或单帧输入结构不符合要求时的错误。
public enum V2FrameCodecError: Error, Equatable, Sendable {
    case invalidLimits
    case invalidMagic
    case unsupportedVersion(UInt8)
    case declaredPayloadTooLarge(Int)
    case payloadTooLarge(Int)
    case tooManyFramesInBatch(Int)
    case trailingPartialFrame
    case expectedSingleFrame
}

/// 有状态的增量帧解码器，支持任意 TCP 拆包与粘包。
///
/// 切出包体前先验证头部及声明长度；单次最多产出调度预算内的帧。内部缓冲仍保存剩余字节，
/// 调用者负责限制传输读取与排空节奏。此值不负责解压、protobuf 解码或身份验证。
public struct V2FrameDecoder: Sendable {
    private let limits: V2FrameLimits
    private var allowsLargeMessageSendFrames: Bool
    private var buffered = Data()

    /// 创建空缓冲解码器；同一连接的后续字节应交给同一实例。
    public init(limits: V2FrameLimits, allowsLargeMessageSendFrames: Bool = false) {
        self.limits = limits
        self.allowsLargeMessageSendFrames = allowsLargeMessageSendFrames
    }

    /// Enable only after the authenticated connection negotiated v45 send support.
    /// Buffered bytes remain intact and are checked under the new bound when drained.
    public mutating func setAllowsLargeMessageSendFrames(_ allowed: Bool) {
        allowsLargeMessageSendFrames = allowed
    }

    /// 是否还保留尚未完成或尚未排空的字节。
    ///
    /// 为 true 不代表已有完整帧；append 空 Data 可排出下一批，遇到仅半帧时仍返回空数组。
    public var hasBufferedBytes: Bool { !buffered.isEmpty }

    /// 追加字节并最多解码一轮完整帧。
    ///
    /// 返回前一次性压缩已消费前缀，避免对密集粘包逐帧重建后缀。
    ///
    /// - Parameter bytes: 本次传输读取；可为空以继续排空上次剩余完整帧。
    /// - Returns: 零到 maximumFramesPerAppend 个完整帧；半帧保留等待下次读取。
    /// - Throws: 魔数、版本或声明长度错误。错误后不保证可跳过坏帧继续使用此缓冲，
    ///   连接所有者应按协议失败策略处理。
    public mutating func append(_ bytes: Data) throws -> [V2Frame] {
        buffered.append(bytes)
        var result: [V2Frame] = []
        var consumedBytes = 0
        while result.count < limits.maximumFramesPerAppend,
              buffered.count - consumedBytes >= V2Frame.headerLength {
            guard readUInt16(buffered, at: consumedBytes) == V2Frame.magic else {
                throw V2FrameCodecError.invalidMagic
            }
            let version = readUInt8(buffered, at: consumedBytes + 2)
            guard limits.acceptedVersions.contains(version) else {
                throw V2FrameCodecError.unsupportedVersion(version)
            }
            let command = V2FrameCommand(rawValue: readUInt16(buffered, at: consumedBytes + 4))
            if command.isMessageSendOperation && version < 45 {
                throw V2FrameCodecError.unsupportedVersion(version)
            }
            let declaredLength = Int(readUInt32(buffered, at: consumedBytes + 14))
            let maximumLength = allowsLargeMessageSendFrames
                ? limits.maximumPayloadBytes(for: command, version: version) : limits.maximumPayloadBytes
            guard declaredLength <= maximumLength else {
                throw V2FrameCodecError.declaredPayloadTooLarge(declaredLength)
            }
            let fullLength = V2Frame.headerLength + declaredLength
            guard buffered.count - consumedBytes >= fullLength else { break }
            let frameStart = consumedBytes
            let frame = V2Frame(
                version: version,
                flags: .init(rawValue: readUInt8(buffered, at: frameStart + 3)),
                command: command,
                requestID: readUInt64(buffered, at: frameStart + 6),
                payload: dataSlice(
                    buffered,
                    from: frameStart + V2Frame.headerLength,
                    to: frameStart + fullLength
                )
            )
            consumedBytes += fullLength
            result.append(frame)
        }
        // Compact once per transport read. Rebuilding the suffix for every
        // frame makes a dense coalesced read quadratic in total bytes.
        if consumedBytes > 0 {
            buffered = Data(buffered.dropFirst(consumedBytes))
        }
        return result
    }

    /// 在流结束且完整帧已全部排空后检查是否仍有残留字节。
    ///
    /// - Throws: 只要缓冲非空即抛出 trailingPartialFrame，包括尚未 drain 的完整帧。
    ///   因此不能在达到单轮预算后直接调用此方法代替继续排空。
    public mutating func finish() throws {
        guard buffered.isEmpty else { throw V2FrameCodecError.trailingPartialFrame }
    }
}

/// 无状态帧编码与严格单帧解码入口。
public enum V2FrameCodec {
    /// 检查版本集合和包体预算，供 Data 与传输原生编码器共用。
    ///
    /// 允许 NIO 编码器避免中间整帧 Data 拷贝，同时保留相同检查。
    /// 此函数不解析 payload，也不验证认证、标志或命令可用性。
    ///
    /// - Parameters:
    ///   - frame: 待写出的帧。
    ///   - limits: 当前编码边缘允许的版本及包体容量。
    /// - Throws: unsupportedVersion 或 payloadTooLarge。
    public static func validateForEncoding(_ frame: V2Frame, limits: V2FrameLimits) throws {
        guard limits.acceptedVersions.contains(frame.version) else {
            throw V2FrameCodecError.unsupportedVersion(frame.version)
        }
        if frame.command.isMessageSendOperation && frame.version < 45 {
            throw V2FrameCodecError.unsupportedVersion(frame.version)
        }
        guard frame.payload.count <= limits.maximumPayloadBytes(for: frame.command, version: frame.version) else {
            throw V2FrameCodecError.payloadTooLarge(frame.payload.count)
        }
    }

    /// 按网络字节序编码固定头，再附加原包体。
    ///
    /// - Parameters:
    ///   - frame: 待编码帧；payload 长度须能由线格式 UInt32 表达。
    ///   - limits: 当前版本与包体上限。
    /// - Returns: 可交给字节传输层的完整帧数据。
    /// - Throws: 编码前的版本或包体预算验证错误。
    public static func encode(_ frame: V2Frame, limits: V2FrameLimits) throws -> Data {
        try validateForEncoding(frame, limits: limits)
        var encoded = Data()
        encoded.reserveCapacity(V2Frame.headerLength + frame.payload.count)
        encoded.appendUInt16(V2Frame.magic)
        encoded.append(frame.version)
        encoded.append(frame.flags.rawValue)
        encoded.appendUInt16(frame.command.rawValue)
        encoded.appendUInt64(frame.requestID)
        encoded.appendUInt32(UInt32(frame.payload.count))
        encoded.append(frame.payload)
        return encoded
    }

    /// 要求输入恰好是一帧完整编码数据。
    ///
    /// 不接受多个帧或尾部半帧；处理连续连接字节流时应使用 V2FrameDecoder。
    ///
    /// - Parameters:
    ///   - bytes: 包含固定头和包体的单帧字节。
    ///   - limits: 解码版本、包体与单轮帧数预算。
    /// - Returns: 唯一解码帧。
    /// - Throws: 帧头／长度错误、trailingPartialFrame 或 expectedSingleFrame。
    public static func decodeExactlyOne(_ bytes: Data, limits: V2FrameLimits) throws -> V2Frame {
        var decoder = V2FrameDecoder(limits: limits, allowsLargeMessageSendFrames: true)
        let frames = try decoder.append(bytes)
        try decoder.finish()
        guard frames.count == 1 else { throw V2FrameCodecError.expectedSingleFrame }
        return frames[0]
    }
}

private func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
    (UInt16(readUInt8(data, at: offset)) << 8) | UInt16(readUInt8(data, at: offset + 1))
}

private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
    (UInt32(readUInt8(data, at: offset)) << 24) | (UInt32(readUInt8(data, at: offset + 1)) << 16) | (UInt32(readUInt8(data, at: offset + 2)) << 8) | UInt32(readUInt8(data, at: offset + 3))
}

private func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
    var value: UInt64 = 0
    for index in offset..<(offset + 8) { value = (value << 8) | UInt64(readUInt8(data, at: index)) }
    return value
}

private func readUInt8(_ data: Data, at offset: Int) -> UInt8 {
    data[data.index(data.startIndex, offsetBy: offset)]
}

private func dataSlice(_ data: Data, from offset: Int, to endOffset: Int) -> Data {
    let start = data.index(data.startIndex, offsetBy: offset)
    let end = data.index(data.startIndex, offsetBy: endOffset)
    return Data(data[start..<end])
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xFF)); append(UInt8(value & 0xFF))
    }
    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF)); append(UInt8((value >> 16) & 0xFF)); append(UInt8((value >> 8) & 0xFF)); append(UInt8(value & 0xFF))
    }
    mutating func appendUInt64(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) { append(UInt8((value >> UInt64(shift)) & 0xFF)) }
    }
}
