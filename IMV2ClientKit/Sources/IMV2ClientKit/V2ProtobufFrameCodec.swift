import Foundation
import IMV2Compression
import IMV2Core
import SwiftProtobuf

/// 客户端帧与 protobuf 适配层的格式、资源预算和压缩错误。
public enum V2ProtobufFrameCodecError: Error, Equatable, Sendable {
    /// protobuf 反序列化失败，包括超过配置的消息深度。
    case payloadDecodeFailed
    /// envelope 没有可映射为帧命令的消息体。
    case missingEnvelopeBody
    /// 帧头命令与 protobuf 消息体类型不一致。
    case headerCommandMismatch
    /// 帧头与载荷请求号不一致，或帧头绑定模式下载荷请求号不为零。
    case requestIDMismatch
    /// 帧版本与载荷版本不一致，或零版本帧不是客户端握手。
    case protocolVersionMismatch
    /// 包含未知标志、编码调用直接指定标志，或请求号绑定用于不支持的版本或命令。
    case unsupportedFrameFlags
    /// 收到压缩帧但当前连接没有协商压缩。
    case unsupportedCompression
    /// 未压缩载荷超过预算。
    case uncompressedPayloadTooLarge
    /// 压缩失败，或编码使用的大小、阈值及扩展比配置无效。
    case compressionFailed
    /// 解压失败，包括解压预算、扩展比或压缩内容不满足要求。
    case decompressionFailed
    /// 解码深度上限不是正数。
    case invalidMessageDepthLimit
}

/// 客户端的纯帧与 protobuf 适配器。
///
/// 负责载荷编解码、帧头一致性、解压预算及协商标志，不执行 TLS 读写、连接认证或业务授权。
/// 完整字节流的帧长度与缓冲管理由外层帧解码器负责。
public enum V2ProtobufFrameCodec {
    /// 默认 protobuf 嵌套深度 32，独立于字节预算；传输层可传入更严格的显式限制。
    public static let defaultMaximumMessageDepth = 32
    /// 默认未压缩载荷预算 65536 字节。
    public static let defaultMaximumUncompressedPayloadBytes = 65_536
    /// 默认达到 1024 字节才尝试压缩。
    public static let defaultCompressionThresholdBytes = 1_024

    /// 把业务 envelope 编码为完整帧模型，并按收益与扩展比决定是否压缩。
    ///
    /// - Parameters:
    ///   - envelope: 待发送消息，必须包含可映射的消息体和符合帧版本的协议版本。
    ///   - frameVersion: 帧版本；零版本仅允许客户端握手。
    ///   - flags: 必须为空，实际压缩与请求号绑定标志由编码器生成。
    ///   - compression: 已协商的压缩能力，为空时不压缩。
    ///   - maximumUncompressedPayloadBytes: 必须为正的原始载荷预算。
    ///   - compressionThresholdBytes: 非负压缩阈值。
    ///   - maximumExpansionRatio: 必须为正的解压扩展比上限。
    ///   - bindRequestIDToHeader: 仅对版本至少为 21 的群事件页面有效，将载荷请求号清零，关联号只放在帧头。
    /// - Returns: 未压缩或 zlib 压缩的帧；压缩无收益或扩展比超限时回退未压缩载荷。
    /// - Throws: 版本、消息体、标志、预算或压缩错误，也可能传播 protobuf 序列化错误。
    ///
    /// 请求号绑定便于复用页面载荷，但不会改变传入的 envelope。此方法生成帧模型，不负责将帧写入 socket。
    public static func encode(
        _ envelope: IMV2Envelope,
        frameVersion: UInt8,
        flags: V2FrameFlags = [],
        compression: V2NegotiatedFrameCompression? = nil,
        maximumUncompressedPayloadBytes: Int = defaultMaximumUncompressedPayloadBytes,
        maximumMessageSendUncompressedPayloadBytes: Int = V2MessageSendWireLimits.maximumPayloadBytes,
        compressionThresholdBytes: Int = defaultCompressionThresholdBytes,
        maximumExpansionRatio: Int = V2ZlibFrameCompression.defaultMaximumExpansionRatio,
        bindRequestIDToHeader: Bool = false
    ) throws -> V2Frame {
        guard flags.isEmpty else { throw V2ProtobufFrameCodecError.unsupportedFrameFlags }
        guard maximumUncompressedPayloadBytes > 0,
              maximumMessageSendUncompressedPayloadBytes > 0,
              maximumMessageSendUncompressedPayloadBytes <= V2MessageSendWireLimits.maximumPayloadBytes,
              compressionThresholdBytes >= 0,
              maximumExpansionRatio > 0
        else {
            throw V2ProtobufFrameCodecError.compressionFailed
        }
        let command = try command(for: envelope)
        try validate(envelope: envelope, frameVersion: frameVersion)
        let payloadLimit = command.isMessageSendOperation ? maximumMessageSendUncompressedPayloadBytes : maximumUncompressedPayloadBytes
        if bindRequestIDToHeader {
            guard frameVersion >= 21, command == .groupEventPage else {
                throw V2ProtobufFrameCodecError.unsupportedFrameFlags
            }
        }
        var wireEnvelope = envelope
        var outputFlags: V2FrameFlags = []
        if bindRequestIDToHeader {
            wireEnvelope.requestID = 0
            outputFlags.insert(.headerBoundRequestID)
        }
        let uncompressed = try wireEnvelope.serializedData()
        guard uncompressed.count <= payloadLimit else {
            throw V2ProtobufFrameCodecError.uncompressedPayloadTooLarge
        }
        guard compression != nil, uncompressed.count >= compressionThresholdBytes else {
            return .init(version: frameVersion, flags: outputFlags, command: command, requestID: envelope.requestID, payload: uncompressed)
        }
        let compressed: Data
        do {
            compressed = try V2ZlibFrameCompression.compress(
                uncompressed,
                maximumInputBytes: payloadLimit
            )
        } catch {
            throw V2ProtobufFrameCodecError.compressionFailed
        }
        guard compressed.count < uncompressed.count,
              compressed.count <= Int.max / maximumExpansionRatio,
              uncompressed.count <= compressed.count * maximumExpansionRatio
        else {
            return .init(version: frameVersion, flags: outputFlags, command: command, requestID: envelope.requestID, payload: uncompressed)
        }
        outputFlags.insert(.compressed)
        return .init(
            version: frameVersion,
            flags: outputFlags,
            command: command,
            requestID: envelope.requestID,
            payload: compressed
        )
    }

    /// 按当前连接编码合同还原 envelope，并核对帧头与载荷的一致性。
    ///
    /// - Parameters:
    ///   - frame: 已从字节流中提取的完整帧。
    ///   - maximumMessageDepth: 正的 protobuf 嵌套深度上限。
    ///   - compression: 当前已协商的压缩能力；压缩帧要求非空。
    ///   - maximumUncompressedPayloadBytes: 解压后或原始载荷的大小预算。
    ///   - maximumExpansionRatio: 解压路径使用的扩展比上限。
    /// - Returns: 已核对命令、版本与请求号的 envelope；绑定模式从帧头恢复请求号。
    /// - Throws: 未知或不适用标志、未协商压缩、资源预算、protobuf 格式或帧头一致性错误。
    ///
    /// 绑定请求号只允许版本至少为 21 的群事件页面，且载荷中请求号必须为零。解码成功不代表命令已获授权。
    public static func decode(
        _ frame: V2Frame,
        maximumMessageDepth: Int = defaultMaximumMessageDepth,
        compression: V2NegotiatedFrameCompression? = nil,
        maximumUncompressedPayloadBytes: Int = defaultMaximumUncompressedPayloadBytes,
        maximumMessageSendUncompressedPayloadBytes: Int = V2MessageSendWireLimits.maximumPayloadBytes,
        maximumExpansionRatio: Int = V2ZlibFrameCompression.defaultMaximumExpansionRatio
    ) throws -> IMV2Envelope {
        let knownFlags: V2FrameFlags = [.compressed, .headerBoundRequestID]
        guard frame.flags.subtracting(knownFlags).isEmpty else {
            throw V2ProtobufFrameCodecError.unsupportedFrameFlags
        }
        if frame.flags.contains(.headerBoundRequestID) {
            guard frame.version >= 21, frame.command == .groupEventPage else {
                throw V2ProtobufFrameCodecError.unsupportedFrameFlags
            }
        }
        guard maximumMessageDepth > 0 else { throw V2ProtobufFrameCodecError.invalidMessageDepthLimit }
        guard maximumUncompressedPayloadBytes > 0, maximumMessageSendUncompressedPayloadBytes > 0,
              maximumMessageSendUncompressedPayloadBytes <= V2MessageSendWireLimits.maximumPayloadBytes else {
            throw V2ProtobufFrameCodecError.uncompressedPayloadTooLarge
        }
        let payloadLimit = frame.command.isMessageSendOperation ? maximumMessageSendUncompressedPayloadBytes : maximumUncompressedPayloadBytes
        let payload: Data
        if frame.flags.contains(.compressed) {
            guard compression != nil else { throw V2ProtobufFrameCodecError.unsupportedCompression }
            do {
                payload = try V2ZlibFrameCompression.decompress(
                    frame.payload,
                    maximumOutputBytes: payloadLimit,
                    maximumExpansionRatio: maximumExpansionRatio
                )
            } catch {
                throw V2ProtobufFrameCodecError.decompressionFailed
            }
        } else {
            guard frame.payload.count <= payloadLimit else {
                throw V2ProtobufFrameCodecError.uncompressedPayloadTooLarge
            }
            payload = frame.payload
        }
        var envelope: IMV2Envelope
        do {
            var options = BinaryDecodingOptions()
            options.messageDepthLimit = maximumMessageDepth
            envelope = try .init(serializedBytes: payload, options: options)
        }
        catch { throw V2ProtobufFrameCodecError.payloadDecodeFailed }
        if frame.flags.contains(.headerBoundRequestID) {
            guard envelope.requestID == 0 else {
                throw V2ProtobufFrameCodecError.requestIDMismatch
            }
            envelope.requestID = frame.requestID
        } else {
            guard envelope.requestID == frame.requestID else {
                throw V2ProtobufFrameCodecError.requestIDMismatch
            }
        }
        try validate(envelope: envelope, frameVersion: frame.version)
        guard try command(for: envelope) == frame.command else { throw V2ProtobufFrameCodecError.headerCommandMismatch }
        return envelope
    }

    /// 检查载荷与帧版本合同。
    ///
    /// 零版本只要求消息体是客户端握手，不在此要求其载荷版本为零；其他版本必须与 envelope 完全一致。
    /// 支持版本集合由会话协商层另外检查。
    private static func validate(envelope: IMV2Envelope, frameVersion: UInt8) throws {
        if frameVersion == 0 {
            guard case .clientHello? = envelope.body else { throw V2ProtobufFrameCodecError.protocolVersionMismatch }
        } else if envelope.protocolVersion != UInt32(frameVersion) {
            throw V2ProtobufFrameCodecError.protocolVersionMismatch
        }
        if frameVersion < 47, let body = envelope.body {
            switch body {
            case .deviceRoomProgressReport, .deviceRoomProgressRecorded:
                throw V2ProtobufFrameCodecError.protocolVersionMismatch
            default: break
            }
        }
        if frameVersion < 46, case .realtimeCoverage? = envelope.body {
            throw V2ProtobufFrameCodecError.protocolVersionMismatch
        }
        if frameVersion < 45, let body = envelope.body {
            switch body {
            case .messageSendOperation, .messageSendOperationRecover, .messageSendOperationResult:
                throw V2ProtobufFrameCodecError.protocolVersionMismatch
            default: break
            }
        }
    }

    /// 按 protobuf 消息体枚举映射唯一帧命令，缺少消息体时抛出错误。
    ///
    /// 此映射同时包含请求、响应和通知，不构成客户端可发送命令的白名单。
    private static func command(for envelope: IMV2Envelope) throws -> V2FrameCommand {
        switch envelope.body {
        case .deviceRoomProgressReport?: return .deviceRoomProgressReport
        case .deviceRoomProgressRecorded?: return .deviceRoomProgressRecorded
        case .messageSendOperation?: return .messageSendOperation
        case .messageSendOperationRecover?: return .messageSendOperationRecover
        case .messageSendOperationResult?: return .messageSendOperationResult
        case .clientHello?: return .clientHello
        case .serverHello?: return .serverHello
        case .authenticate?: return .authenticate
        case .authenticated?: return .authenticated
        case .heartbeat?: return .heartbeat
        case .heartbeatAck?: return .heartbeatAck
        case .messageAccepted?: return .messageAccepted
        case .membershipChanged?: return .membershipChanged
        case .messageWithdrawn?: return .messageWithdrawn
        case .messageReactionChanged?: return .messageReactionChanged
        case .messageEdited?: return .messageEdited
        case .syncPull?: return .syncPull
        case .syncBatch?: return .syncBatch
        case .syncAck?: return .syncAck
        case .resetRequired?: return .resetRequired
        case .snapshotAck?: return .snapshotAck
        case .acknowledged?: return .acknowledged
        case .syncSnapshot?: return .syncSnapshot
        case .snapshotManifest?: return .snapshotManifest
        case .snapshotPagePull?: return .snapshotPagePull
        case .snapshotPage?: return .snapshotPage
        case .realtimeCoverage?: return .realtimeCoverage
        case .syncAvailable?: return .syncAvailable
        case .recordReadReceipt?: return .recordReadReceipt
        case .readReceiptRecorded?: return .readReceiptRecorded
        case .listRoomMembers?: return .listRoomMembers
        case .roomMembersPage?: return .roomMembersPage
        case .userRoomDirectoryList?: return .userRoomDirectoryList
        case .userRoomDirectoryPage?: return .userRoomDirectoryPage
        case .roomSyncStateBatch?: return .roomSyncStateBatch
        case .roomSyncStateBatchResult?: return .roomSyncStateBatchResult
        case .accountRoomChangesStart?: return .accountRoomChangesStart
        case .accountRoomChangesReady?: return .accountRoomChangesReady
        case .accountRoomResyncRequired?: return .accountRoomResyncRequired
        case .roomLatestVisibleBatch?: return .roomLatestVisibleBatch
        case .roomLatestVisibleBatchResult?: return .roomLatestVisibleBatchResult
        case .authorPresentationDelta?: return .authorPresentationDelta
        case .authorPresentationEnd?: return .authorPresentationEnd
        case .authorPresentationEnded?: return .authorPresentationEnded
        case .personalPreferenceReceipt?: return .personalPreferenceReceipt

        case .groupEventPull?: return .groupEventPull
        case .groupEventPage?: return .groupEventPage
        case .groupEventSubscribe?: return .groupEventSubscribe
        case .groupEventSubscribed?: return .groupEventSubscribed
        case .groupEventUnsubscribe?: return .groupEventUnsubscribe
        case .groupEventAvailable?: return .groupEventAvailable
        case .strangerMessagePermissionSet?: return .strangerMessagePermissionSet
        case .userAddPermissionSet?: return .userAddPermissionSet
        case .readReceiptPreferencesSet?: return .readReceiptPreferencesSet
        case .listReadReceiptReaders?: return .listReadReceiptReaders
        case .readReceiptReadersPage?: return .readReceiptReadersPage
        case .liveActivityPreferencesSet?: return .liveActivityPreferencesSet
        case .subscribePresence?: return .subscribePresence
        case .presenceSubscribed?: return .presenceSubscribed
        case .unsubscribePresence?: return .unsubscribePresence
        case .subscribeTyping?: return .subscribeTyping
        case .unsubscribeTyping?: return .unsubscribeTyping
        case .setTypingState?: return .setTypingState
        case .typingStateChanged?: return .typingStateChanged
        case .presenceChanged?: return .presenceChanged
        case .presencePublicationControl?: return .presencePublicationControl
        case .presencePublicationControlled?: return .presencePublicationControlled
        case .getLiveActivityPreferences?: return .getLiveActivityPreferences
        case .liveActivityPreferences?: return .liveActivityPreferences
        case .setConversationState?: return .setConversationState
        case .conversationStateSet?: return .conversationStateSet
        case .setMessageFavorite?: return .setMessageFavorite
        case .messageFavoriteChanged?: return .messageFavoriteChanged
        case .pinnedMessageChanged?: return .pinnedMessageChanged
        case .groupAnnouncementChanged?: return .groupAnnouncementChanged
        case .groupRolePermissionsChanged?: return .groupRolePermissionsChanged
        case .groupMemberRoleChanged?: return .groupMemberRoleChanged
        case .getGroupRolePolicyBaseline?: return .getGroupRolePolicyBaseline
        case .groupRolePolicyBaseline?: return .groupRolePolicyBaseline
        case .relationshipChanged?: return .relationshipChanged
        case .userBlockChanged?: return .userBlockChanged
        case .memberMuted?: return .memberMuted
        case .memberRemovedByModerator?: return .memberRemovedByModerator
        case .error?: return .error
        case nil: throw V2ProtobufFrameCodecError.missingEnvelopeBody
        }
    }
}
