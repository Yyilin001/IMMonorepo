import Foundation
import IMV2Compression
import IMV2Core
import SwiftProtobuf

public enum V2ProtobufFrameCodecError: Error, Equatable, Sendable {
    case payloadDecodeFailed
    case missingEnvelopeBody
    case headerCommandMismatch
    case requestIDMismatch
    case protocolVersionMismatch
    case unsupportedFrameFlags
    case unsupportedCompression
    case uncompressedPayloadTooLarge
    case compressionFailed
    case decompressionFailed
    case invalidMessageDepthLimit
}

/// Bridges the transport-neutral Core frame to generated V2 protobuf messages.
/// Validation here prevents a frame header from being correlated with a
/// semantically different protobuf body.
public enum V2ProtobufFrameCodec {
    /// First-release protocol limit. The transport may provide a stricter
    /// deployment-specific value, but no decoder falls back to the library's
    /// mutable default.
    public static let defaultMaximumMessageDepth = 32
    public static let defaultMaximumUncompressedPayloadBytes = 65_536
    public static let defaultCompressionThresholdBytes = 1_024

    public static func encode(
        _ envelope: IMV2Envelope,
        frameVersion: UInt8,
        flags: V2FrameFlags = [],
        compression: V2NegotiatedFrameCompression? = nil,
        maximumUncompressedPayloadBytes: Int = defaultMaximumUncompressedPayloadBytes,
        compressionThresholdBytes: Int = defaultCompressionThresholdBytes,
        maximumExpansionRatio: Int = V2ZlibFrameCompression.defaultMaximumExpansionRatio,
        bindRequestIDToHeader: Bool = false
    ) throws -> V2Frame {
        guard flags.isEmpty else { throw V2ProtobufFrameCodecError.unsupportedFrameFlags }
        guard maximumUncompressedPayloadBytes > 0,
              compressionThresholdBytes >= 0,
              maximumExpansionRatio > 0
        else {
            throw V2ProtobufFrameCodecError.compressionFailed
        }
        let command = try command(for: envelope)
        try validate(envelope: envelope, frameVersion: frameVersion)
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
        guard uncompressed.count <= maximumUncompressedPayloadBytes else {
            throw V2ProtobufFrameCodecError.uncompressedPayloadTooLarge
        }
        guard compression != nil, uncompressed.count >= compressionThresholdBytes else {
            return .init(version: frameVersion, flags: outputFlags, command: command, requestID: envelope.requestID, payload: uncompressed)
        }
        let compressed: Data
        do {
            compressed = try V2ZlibFrameCompression.compress(
                uncompressed,
                maximumInputBytes: maximumUncompressedPayloadBytes
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

    public static func decode(
        _ frame: V2Frame,
        maximumMessageDepth: Int = defaultMaximumMessageDepth,
        compression: V2NegotiatedFrameCompression? = nil,
        maximumUncompressedPayloadBytes: Int = defaultMaximumUncompressedPayloadBytes,
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
        let payload: Data
        if frame.flags.contains(.compressed) {
            guard compression != nil else { throw V2ProtobufFrameCodecError.unsupportedCompression }
            do {
                payload = try V2ZlibFrameCompression.decompress(
                    frame.payload,
                    maximumOutputBytes: maximumUncompressedPayloadBytes,
                    maximumExpansionRatio: maximumExpansionRatio
                )
            } catch {
                throw V2ProtobufFrameCodecError.decompressionFailed
            }
        } else {
            guard frame.payload.count <= maximumUncompressedPayloadBytes else {
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

    private static func validate(envelope: IMV2Envelope, frameVersion: UInt8) throws {
        if frameVersion == 0 {
            guard case .clientHello? = envelope.body else { throw V2ProtobufFrameCodecError.protocolVersionMismatch }
        } else if envelope.protocolVersion != UInt32(frameVersion) {
            throw V2ProtobufFrameCodecError.protocolVersionMismatch
        }
    }

    private static func command(for envelope: IMV2Envelope) throws -> V2FrameCommand {
        switch envelope.body {
        case .clientHello?: return .clientHello
        case .serverHello?: return .serverHello
        case .authenticate?: return .authenticate
        case .authenticated?: return .authenticated
        case .heartbeat?: return .heartbeat
        case .heartbeatAck?: return .heartbeatAck
        case .sendMessage?: return .sendMessage
        case .messageAccepted?: return .messageAccepted
        case .changeRoomMembership?: return .changeRoomMembership
        case .membershipChanged?: return .membershipChanged
        case .withdrawMessage?: return .withdrawMessage
        case .messageWithdrawn?: return .messageWithdrawn
        case .changeMessageReaction?: return .changeMessageReaction
        case .messageReactionChanged?: return .messageReactionChanged
        case .editMessage?: return .editMessage
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
        case .syncAvailable?: return .syncAvailable
        case .recordReadReceipt?: return .recordReadReceipt
        case .readReceiptRecorded?: return .readReceiptRecorded
        case .openDirectRoom?: return .openDirectRoom
        case .directRoomOpened?: return .directRoomOpened
        case .groupRoomCreated?: return .groupRoomCreated
        case .listRoomMembers?: return .listRoomMembers
        case .roomMembersPage?: return .roomMembersPage
        case .groupEventPull?: return .groupEventPull
        case .groupEventPage?: return .groupEventPage
        case .groupEventSubscribe?: return .groupEventSubscribe
        case .groupEventSubscribed?: return .groupEventSubscribed
        case .groupEventUnsubscribe?: return .groupEventUnsubscribe
        case .groupEventAvailable?: return .groupEventAvailable
        case .beginGroupRoomCreation?: return .beginGroupRoomCreation
        case .groupRoomCreationPrepared?: return .groupRoomCreationPrepared
        case .appendGroupRoomCreationMembers?: return .appendGroupRoomCreationMembers
        case .groupRoomCreationMembersAppended?: return .groupRoomCreationMembersAppended
        case .finalizeGroupRoomCreation?: return .finalizeGroupRoomCreation
        case .cancelGroupRoomCreation?: return .cancelGroupRoomCreation
        case .groupRoomCreationCancelled?: return .groupRoomCreationCancelled
        case .setStrangerMessagePermission?: return .setStrangerMessagePermission
        case .strangerMessagePermissionSet?: return .strangerMessagePermissionSet
        case .setUserAddPermission?: return .setUserAddPermission
        case .userAddPermissionSet?: return .userAddPermissionSet
        case .setReadReceiptPreferences?: return .setReadReceiptPreferences
        case .readReceiptPreferencesSet?: return .readReceiptPreferencesSet
        case .listReadReceiptReaders?: return .listReadReceiptReaders
        case .readReceiptReadersPage?: return .readReceiptReadersPage
        case .setLiveActivityPreferences?: return .setLiveActivityPreferences
        case .liveActivityPreferencesSet?: return .liveActivityPreferencesSet
        case .subscribePresence?: return .subscribePresence
        case .presenceSubscribed?: return .presenceSubscribed
        case .unsubscribePresence?: return .unsubscribePresence
        case .subscribeTyping?: return .subscribeTyping
        case .unsubscribeTyping?: return .unsubscribeTyping
        case .setTypingState?: return .setTypingState
        case .typingStateChanged?: return .typingStateChanged
        case .presenceChanged?: return .presenceChanged
        case .getLiveActivityPreferences?: return .getLiveActivityPreferences
        case .liveActivityPreferences?: return .liveActivityPreferences
        case .setConversationState?: return .setConversationState
        case .conversationStateSet?: return .conversationStateSet
        case .setMessageFavorite?: return .setMessageFavorite
        case .messageFavoriteChanged?: return .messageFavoriteChanged
        case .setPinnedMessage?: return .setPinnedMessage
        case .pinnedMessageChanged?: return .pinnedMessageChanged
        case .setGroupAnnouncement?: return .setGroupAnnouncement
        case .groupAnnouncementChanged?: return .groupAnnouncementChanged
        case .setGroupRolePermissions?: return .setGroupRolePermissions
        case .groupRolePermissionsChanged?: return .groupRolePermissionsChanged
        case .changeGroupMemberRole?: return .changeGroupMemberRole
        case .groupMemberRoleChanged?: return .groupMemberRoleChanged
        case .forwardMessages?: return .forwardMessages
        case .messagesForwarded?: return .messagesForwarded
        case .changeRelationship?: return .changeRelationship
        case .relationshipChanged?: return .relationshipChanged
        case .changeUserBlock?: return .changeUserBlock
        case .userBlockChanged?: return .userBlockChanged
        case .moderateMessage?: return .moderateMessage
        case .messageRedacted?: return .messageRedacted
        case .muteMember?: return .muteMember
        case .memberMuted?: return .memberMuted
        case .moderateMemberRemoval?: return .moderateMemberRemoval
        case .memberRemovedByModerator?: return .memberRemovedByModerator
        case .error?: return .error
        case nil: throw V2ProtobufFrameCodecError.missingEnvelopeBody
        }
    }
}
