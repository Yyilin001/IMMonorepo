import Foundation

/// Stable binary command code carried outside the protobuf envelope. Unknown
/// values remain representable so a newer peer can return a structured upgrade
/// error instead of the frame parser losing synchronization.
public struct V2FrameCommand: RawRepresentable, Equatable, Hashable, Sendable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let clientHello = Self(rawValue: 1)
    public static let serverHello = Self(rawValue: 2)
    public static let authenticate = Self(rawValue: 3)
    public static let authenticated = Self(rawValue: 4)
    public static let heartbeat = Self(rawValue: 5)
    public static let heartbeatAck = Self(rawValue: 6)
    public static let sendMessage = Self(rawValue: 20)
    public static let messageAccepted = Self(rawValue: 21)
    public static let changeRoomMembership = Self(rawValue: 22)
    public static let membershipChanged = Self(rawValue: 23)
    public static let withdrawMessage = Self(rawValue: 24)
    public static let messageWithdrawn = Self(rawValue: 25)
    public static let changeMessageReaction = Self(rawValue: 26)
    public static let messageReactionChanged = Self(rawValue: 27)
    public static let editMessage = Self(rawValue: 28)
    public static let messageEdited = Self(rawValue: 29)
    public static let recordReadReceipt = Self(rawValue: 41)
    public static let readReceiptRecorded = Self(rawValue: 42)
    public static let openDirectRoom = Self(rawValue: 43)
    public static let directRoomOpened = Self(rawValue: 44)
    public static let setStrangerMessagePermission = Self(rawValue: 45)
    public static let strangerMessagePermissionSet = Self(rawValue: 46)
    public static let changeRelationship = Self(rawValue: 47)
    public static let relationshipChanged = Self(rawValue: 48)
    public static let changeUserBlock = Self(rawValue: 49)
    public static let userBlockChanged = Self(rawValue: 50)
    public static let moderateMessage = Self(rawValue: 51)
    public static let messageRedacted = Self(rawValue: 52)
    public static let muteMember = Self(rawValue: 53)
    public static let memberMuted = Self(rawValue: 54)
    public static let moderateMemberRemoval = Self(rawValue: 55)
    public static let memberRemovedByModerator = Self(rawValue: 56)
    public static let createGroupRoom = Self(rawValue: 57)
    public static let groupRoomCreated = Self(rawValue: 58)
    public static let listRoomMembers = Self(rawValue: 59)
    public static let roomMembersPage = Self(rawValue: 60)
    public static let groupEventPull = Self(rawValue: 61)
    public static let groupEventPage = Self(rawValue: 62)
    public static let groupEventSubscribe = Self(rawValue: 63)
    public static let groupEventSubscribed = Self(rawValue: 64)
    public static let groupEventUnsubscribe = Self(rawValue: 65)
    public static let groupEventAvailable = Self(rawValue: 66)
    public static let beginGroupRoomCreation = Self(rawValue: 67)
    public static let groupRoomCreationPrepared = Self(rawValue: 68)
    public static let appendGroupRoomCreationMembers = Self(rawValue: 69)
    public static let groupRoomCreationMembersAppended = Self(rawValue: 70)
    public static let finalizeGroupRoomCreation = Self(rawValue: 71)
    public static let cancelGroupRoomCreation = Self(rawValue: 72)
    public static let groupRoomCreationCancelled = Self(rawValue: 73)
    public static let setUserAddPermission = Self(rawValue: 74)
    public static let userAddPermissionSet = Self(rawValue: 75)
    public static let setReadReceiptPreferences = Self(rawValue: 76)
    public static let readReceiptPreferencesSet = Self(rawValue: 77)
    public static let listReadReceiptReaders = Self(rawValue: 78)
    public static let readReceiptReadersPage = Self(rawValue: 79)
    public static let setLiveActivityPreferences = Self(rawValue: 80)
    public static let liveActivityPreferencesSet = Self(rawValue: 81)
    public static let subscribePresence = Self(rawValue: 82)
    public static let presenceSubscribed = Self(rawValue: 83)
    public static let unsubscribePresence = Self(rawValue: 84)
    public static let subscribeTyping = Self(rawValue: 85)
    public static let unsubscribeTyping = Self(rawValue: 86)
    public static let setTypingState = Self(rawValue: 87)
    public static let typingStateChanged = Self(rawValue: 88)
    public static let presenceChanged = Self(rawValue: 89)
    public static let syncPull = Self(rawValue: 30)
    public static let syncBatch = Self(rawValue: 31)
    public static let syncAck = Self(rawValue: 32)
    public static let resetRequired = Self(rawValue: 33)
    public static let snapshotAck = Self(rawValue: 34)
    public static let acknowledged = Self(rawValue: 35)
    public static let syncSnapshot = Self(rawValue: 36)
    public static let snapshotManifest = Self(rawValue: 37)
    public static let snapshotPagePull = Self(rawValue: 38)
    public static let snapshotPage = Self(rawValue: 39)
    public static let syncAvailable = Self(rawValue: 40)
    public static let error = Self(rawValue: 90)
    public static let getLiveActivityPreferences = Self(rawValue: 91)
    public static let liveActivityPreferences = Self(rawValue: 92)
    public static let setConversationState = Self(rawValue: 93)
    public static let conversationStateSet = Self(rawValue: 94)
    public static let setMessageFavorite = Self(rawValue: 95)
    public static let messageFavoriteChanged = Self(rawValue: 96)
    public static let setPinnedMessage = Self(rawValue: 97)
    public static let pinnedMessageChanged = Self(rawValue: 98)
    public static let setGroupAnnouncement = Self(rawValue: 99)
    public static let groupAnnouncementChanged = Self(rawValue: 100)
    public static let setGroupRolePermissions = Self(rawValue: 101)
    public static let groupRolePermissionsChanged = Self(rawValue: 102)
    public static let changeGroupMemberRole = Self(rawValue: 103)
    public static let groupMemberRoleChanged = Self(rawValue: 104)
    public static let forwardMessages = Self(rawValue: 105)
    public static let messagesForwarded = Self(rawValue: 106)
}

public struct V2FrameFlags: OptionSet, Equatable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// Valid only after version/compression negotiation. The codec never
    /// decompresses data and callers must enforce a separate decoded limit.
    public static let compressed = Self(rawValue: 1 << 0)
}

public struct V2Frame: Equatable, Sendable {
    public static let magic: UInt16 = 0x494D // "IM" in network byte order.
    public static let headerLength = 18

    public let version: UInt8
    public let flags: V2FrameFlags
    public let command: V2FrameCommand
    public let requestID: UInt64
    public let payload: Data

    public init(version: UInt8, flags: V2FrameFlags = [], command: V2FrameCommand, requestID: UInt64, payload: Data) {
        self.version = version
        self.flags = flags
        self.command = command
        self.requestID = requestID
        self.payload = payload
    }
}

public struct V2FrameLimits: Equatable, Sendable {
    public let maximumPayloadBytes: Int
    public let acceptedVersions: Set<UInt8>

    public init(maximumPayloadBytes: Int, acceptedVersions: Set<UInt8>) throws {
        guard maximumPayloadBytes >= 0, !acceptedVersions.isEmpty else {
            throw V2FrameCodecError.invalidLimits
        }
        self.maximumPayloadBytes = maximumPayloadBytes
        self.acceptedVersions = acceptedVersions
    }
}

public enum V2FrameCodecError: Error, Equatable, Sendable {
    case invalidLimits
    case invalidMagic
    case unsupportedVersion(UInt8)
    case declaredPayloadTooLarge(Int)
    case payloadTooLarge(Int)
    case trailingPartialFrame
    case expectedSingleFrame
}

/// Incremental, bounded decoder. It validates the fixed header and declared
/// payload size before slicing/allocating a payload, making it suitable for a
/// TLS byte stream that may split or coalesce arbitrary frame boundaries.
public struct V2FrameDecoder: Sendable {
    private let limits: V2FrameLimits
    private var buffered = Data()

    public init(limits: V2FrameLimits) { self.limits = limits }

    public mutating func append(_ bytes: Data) throws -> [V2Frame] {
        buffered.append(bytes)
        var result: [V2Frame] = []
        while buffered.count >= V2Frame.headerLength {
            guard readUInt16(buffered, at: 0) == V2Frame.magic else {
                throw V2FrameCodecError.invalidMagic
            }
            let version = readUInt8(buffered, at: 2)
            guard limits.acceptedVersions.contains(version) else {
                throw V2FrameCodecError.unsupportedVersion(version)
            }
            let declaredLength = Int(readUInt32(buffered, at: 14))
            guard declaredLength <= limits.maximumPayloadBytes else {
                throw V2FrameCodecError.declaredPayloadTooLarge(declaredLength)
            }
            let fullLength = V2Frame.headerLength + declaredLength
            guard buffered.count >= fullLength else { break }
            let frame = V2Frame(
                version: version,
                flags: .init(rawValue: readUInt8(buffered, at: 3)),
                command: .init(rawValue: readUInt16(buffered, at: 4)),
                requestID: readUInt64(buffered, at: 6),
                payload: dataSlice(buffered, from: V2Frame.headerLength, to: fullLength)
            )
            // Data's integer subscript is based on `startIndex`, which is not
            // guaranteed to reset after removeFirst on every platform.
            // Rebuilding the remaining buffer keeps later header reads
            // independent of its internal index origin.
            buffered = Data(buffered.dropFirst(fullLength))
            result.append(frame)
        }
        return result
    }

    /// Call only when the underlying TLS stream closes.
    public mutating func finish() throws {
        guard buffered.isEmpty else { throw V2FrameCodecError.trailingPartialFrame }
    }
}

public enum V2FrameCodec {
    public static func encode(_ frame: V2Frame, limits: V2FrameLimits) throws -> Data {
        guard limits.acceptedVersions.contains(frame.version) else {
            throw V2FrameCodecError.unsupportedVersion(frame.version)
        }
        guard frame.payload.count <= limits.maximumPayloadBytes else {
            throw V2FrameCodecError.payloadTooLarge(frame.payload.count)
        }
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

    public static func decodeExactlyOne(_ bytes: Data, limits: V2FrameLimits) throws -> V2Frame {
        var decoder = V2FrameDecoder(limits: limits)
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
