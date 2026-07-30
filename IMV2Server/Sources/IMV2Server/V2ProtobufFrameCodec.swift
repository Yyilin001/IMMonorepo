import Foundation
import IMV2Core
import SwiftProtobuf

public enum V2ServerProtobufFrameCodecError: Error, Equatable, Sendable {
    case payloadDecodeFailed
    case missingEnvelopeBody
    case headerCommandMismatch
    case requestIDMismatch
    case protocolVersionMismatch
    case unsupportedFrameFlags
    case invalidMessageDepthLimit
}

/// Server-side counterpart to the client adapter. It is intentionally a pure
/// codec: TLS I/O and command authorization remain outside this boundary.
public enum V2ServerProtobufFrameCodec {
    /// This is a wire-safety limit, independent of the frame byte limit. The
    /// production gateway always supplies its explicit runtime value.
    public static let defaultMaximumMessageDepth = 32

    public static func encode(_ envelope: IMV2Envelope, frameVersion: UInt8, flags: V2FrameFlags = []) throws -> V2Frame {
        guard flags.isEmpty else { throw V2ServerProtobufFrameCodecError.unsupportedFrameFlags }
        let command = try command(for: envelope)
        try validate(envelope: envelope, frameVersion: frameVersion)
        return .init(version: frameVersion, flags: flags, command: command, requestID: envelope.requestID, payload: try envelope.serializedData())
    }

    public static func decode(
        _ frame: V2Frame,
        maximumMessageDepth: Int = defaultMaximumMessageDepth
    ) throws -> IMV2Envelope {
        guard frame.flags.isEmpty else { throw V2ServerProtobufFrameCodecError.unsupportedFrameFlags }
        guard maximumMessageDepth > 0 else { throw V2ServerProtobufFrameCodecError.invalidMessageDepthLimit }
        let envelope: IMV2Envelope
        do {
            var options = BinaryDecodingOptions()
            options.messageDepthLimit = maximumMessageDepth
            envelope = try .init(serializedBytes: frame.payload, options: options)
        }
        catch { throw V2ServerProtobufFrameCodecError.payloadDecodeFailed }
        guard envelope.requestID == frame.requestID else { throw V2ServerProtobufFrameCodecError.requestIDMismatch }
        try validate(envelope: envelope, frameVersion: frame.version)
        guard try command(for: envelope) == frame.command else { throw V2ServerProtobufFrameCodecError.headerCommandMismatch }
        return envelope
    }

    private static func validate(envelope: IMV2Envelope, frameVersion: UInt8) throws {
        if frameVersion == 0 {
            guard case .clientHello? = envelope.body else { throw V2ServerProtobufFrameCodecError.protocolVersionMismatch }
        } else if envelope.protocolVersion != UInt32(frameVersion) {
            throw V2ServerProtobufFrameCodecError.protocolVersionMismatch
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
        case .createGroupRoom?: return .createGroupRoom
        case .groupRoomCreated?: return .groupRoomCreated
        case .listRoomMembers?: return .listRoomMembers
        case .roomMembersPage?: return .roomMembersPage
        case .groupEventPull?: return .groupEventPull
        case .groupEventPage?: return .groupEventPage
        case .groupEventSubscribe?: return .groupEventSubscribe
        case .groupEventSubscribed?: return .groupEventSubscribed
        case .groupEventUnsubscribe?: return .groupEventUnsubscribe
        case .groupEventAvailable?: return .groupEventAvailable
        case .setStrangerMessagePermission?: return .setStrangerMessagePermission
        case .strangerMessagePermissionSet?: return .strangerMessagePermissionSet
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
        case nil: throw V2ServerProtobufFrameCodecError.missingEnvelopeBody
        }
    }
}
