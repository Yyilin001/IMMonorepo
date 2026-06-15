import Foundation

enum IMGatewayRelayBinaryCodec {
    private static let magic = Array("IMRP1".utf8)
    private static let batchMagic = Array("IMRB1".utf8)
    private static let uuidByteCount = 16

    struct DomainEventPacket: Sendable {
        let requestID: UUID?
        let payloadData: Data
        let recipientUserIDs: [UUID]
    }

    struct DomainEventPacketBatch: Sendable {
        let requestID: UUID?
        let entries: [DomainEventPacketBatchEntry]
    }

    struct DomainEventPacketBatchEntry: Sendable {
        let payloadData: Data
        let recipientUserIDs: [UUID]
        let fanoutIntent: IMGatewayDomainEventFanoutIntent
    }

    static func encodeDomainEventPacket(
        payloadData: Data,
        recipientUserIDs: [UUID],
        requestID: UUID?
    ) throws -> Data {
        guard !recipientUserIDs.isEmpty else {
            throw BinaryRelayCodecError.emptyRecipients
        }
        guard payloadData.count <= Int(UInt32.max),
              recipientUserIDs.count <= Int(UInt32.max)
        else {
            throw BinaryRelayCodecError.valueTooLarge
        }

        var data = Data()
        data.reserveCapacity(Self.magic.count + 1 + Self.uuidByteCount + 4 + payloadData.count + 4 + recipientUserIDs.count * Self.uuidByteCount)
        data.append(contentsOf: Self.magic)
        if let requestID {
            data.append(1)
            appendUUID(requestID, to: &data)
        } else {
            data.append(0)
        }
        appendUInt32(UInt32(payloadData.count), to: &data)
        data.append(payloadData)
        appendUInt32(UInt32(recipientUserIDs.count), to: &data)
        for userID in recipientUserIDs {
            appendUUID(userID, to: &data)
        }
        return data
    }

    static func encodedDomainEventPacketByteCount(
        payloadByteCount: Int,
        recipientCount: Int,
        includesRequestID: Bool
    ) -> Int {
        magic.count
            + 1
            + (includesRequestID ? uuidByteCount : 0)
            + 4
            + max(0, payloadByteCount)
            + 4
            + max(0, recipientCount) * uuidByteCount
    }

    static func encodeDomainEventPacketBatch(
        entries: [DomainEventPacketBatchEntry],
        requestID: UUID?
    ) throws -> Data {
        guard !entries.isEmpty else {
            throw BinaryRelayCodecError.emptyBatch
        }
        guard entries.count <= Int(UInt32.max) else {
            throw BinaryRelayCodecError.valueTooLarge
        }
        for entry in entries {
            guard !entry.recipientUserIDs.isEmpty else {
                throw BinaryRelayCodecError.emptyRecipients
            }
            guard entry.payloadData.count <= Int(UInt32.max),
                  entry.recipientUserIDs.count <= Int(UInt32.max)
            else {
                throw BinaryRelayCodecError.valueTooLarge
            }
        }

        var data = Data()
        data.reserveCapacity(encodedDomainEventPacketBatchByteCount(
            entries: entries.map {
                (payloadByteCount: $0.payloadData.count, recipientCount: $0.recipientUserIDs.count)
            },
            includesRequestID: requestID != nil
        ))
        data.append(contentsOf: Self.batchMagic)
        if let requestID {
            data.append(1)
            appendUUID(requestID, to: &data)
        } else {
            data.append(0)
        }
        appendUInt32(UInt32(entries.count), to: &data)
        for entry in entries {
            data.append(fanoutIntentCode(entry.fanoutIntent))
            appendUInt32(UInt32(entry.payloadData.count), to: &data)
            data.append(entry.payloadData)
            appendUInt32(UInt32(entry.recipientUserIDs.count), to: &data)
            for userID in entry.recipientUserIDs {
                appendUUID(userID, to: &data)
            }
        }
        return data
    }

    static func encodedDomainEventPacketBatchByteCount(
        entries: [(payloadByteCount: Int, recipientCount: Int)],
        includesRequestID: Bool
    ) -> Int {
        batchMagic.count
            + 1
            + (includesRequestID ? uuidByteCount : 0)
            + 4
            + entries.reduce(0) { partial, entry in
                partial
                    + 1
                    + 4
                    + max(0, entry.payloadByteCount)
                    + 4
                    + max(0, entry.recipientCount) * uuidByteCount
            }
    }

    static func decodeDomainEventPacket(_ data: Data) throws -> DomainEventPacket {
        var cursor = 0
        guard data.count >= Self.magic.count + 1 + 4 + 4,
              Array(data.prefix(Self.magic.count)) == Self.magic
        else {
            throw BinaryRelayCodecError.invalidMagic
        }
        cursor += Self.magic.count

        let hasRequestID = try readByte(from: data, cursor: &cursor)
        let requestID: UUID?
        switch hasRequestID {
        case 0:
            requestID = nil
        case 1:
            requestID = try readUUID(from: data, cursor: &cursor)
        default:
            throw BinaryRelayCodecError.invalidRequestIDFlag
        }

        let payloadLength = Int(try readUInt32(from: data, cursor: &cursor))
        guard payloadLength >= 0,
              data.count - cursor >= payloadLength
        else {
            throw BinaryRelayCodecError.truncatedPayload
        }
        let payloadData = data[cursor..<(cursor + payloadLength)]
        cursor += payloadLength

        let recipientCount = Int(try readUInt32(from: data, cursor: &cursor))
        guard recipientCount > 0 else {
            throw BinaryRelayCodecError.emptyRecipients
        }
        guard data.count - cursor == recipientCount * Self.uuidByteCount else {
            throw BinaryRelayCodecError.invalidRecipientBytes
        }

        var recipientUserIDs: [UUID] = []
        recipientUserIDs.reserveCapacity(recipientCount)
        for _ in 0..<recipientCount {
            recipientUserIDs.append(try readUUID(from: data, cursor: &cursor))
        }

        return DomainEventPacket(
            requestID: requestID,
            payloadData: Data(payloadData),
            recipientUserIDs: recipientUserIDs
        )
    }

    static func decodeDomainEventPacketBatch(_ data: Data) throws -> DomainEventPacketBatch {
        var cursor = 0
        guard data.count >= Self.batchMagic.count + 1 + 4,
              Array(data.prefix(Self.batchMagic.count)) == Self.batchMagic
        else {
            throw BinaryRelayCodecError.invalidMagic
        }
        cursor += Self.batchMagic.count

        let hasRequestID = try readByte(from: data, cursor: &cursor)
        let requestID: UUID?
        switch hasRequestID {
        case 0:
            requestID = nil
        case 1:
            requestID = try readUUID(from: data, cursor: &cursor)
        default:
            throw BinaryRelayCodecError.invalidRequestIDFlag
        }

        let entryCount = Int(try readUInt32(from: data, cursor: &cursor))
        guard entryCount > 0 else {
            throw BinaryRelayCodecError.emptyBatch
        }

        var entries: [DomainEventPacketBatchEntry] = []
        entries.reserveCapacity(entryCount)
        for _ in 0..<entryCount {
            let fanoutIntent = try fanoutIntent(fromCode: try readByte(from: data, cursor: &cursor))
            let payloadLength = Int(try readUInt32(from: data, cursor: &cursor))
            guard payloadLength >= 0,
                  data.count - cursor >= payloadLength
            else {
                throw BinaryRelayCodecError.truncatedPayload
            }
            let payloadData = data[cursor..<(cursor + payloadLength)]
            cursor += payloadLength

            let recipientCount = Int(try readUInt32(from: data, cursor: &cursor))
            guard recipientCount > 0 else {
                throw BinaryRelayCodecError.emptyRecipients
            }
            guard data.count - cursor >= recipientCount * Self.uuidByteCount else {
                throw BinaryRelayCodecError.invalidRecipientBytes
            }

            var recipientUserIDs: [UUID] = []
            recipientUserIDs.reserveCapacity(recipientCount)
            for _ in 0..<recipientCount {
                recipientUserIDs.append(try readUUID(from: data, cursor: &cursor))
            }
            entries.append(DomainEventPacketBatchEntry(
                payloadData: Data(payloadData),
                recipientUserIDs: recipientUserIDs,
                fanoutIntent: fanoutIntent
            ))
        }
        guard cursor == data.count else {
            throw BinaryRelayCodecError.invalidRecipientBytes
        }

        return DomainEventPacketBatch(requestID: requestID, entries: entries)
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    private static func readUInt32(from data: Data, cursor: inout Int) throws -> UInt32 {
        guard data.count - cursor >= 4 else {
            throw BinaryRelayCodecError.truncatedPayload
        }
        let value = (UInt32(data[cursor]) << 24)
            | (UInt32(data[cursor + 1]) << 16)
            | (UInt32(data[cursor + 2]) << 8)
            | UInt32(data[cursor + 3])
        cursor += 4
        return value
    }

    private static func appendUUID(_ uuid: UUID, to data: inout Data) {
        let bytes = uuid.uuid
        data.append(bytes.0)
        data.append(bytes.1)
        data.append(bytes.2)
        data.append(bytes.3)
        data.append(bytes.4)
        data.append(bytes.5)
        data.append(bytes.6)
        data.append(bytes.7)
        data.append(bytes.8)
        data.append(bytes.9)
        data.append(bytes.10)
        data.append(bytes.11)
        data.append(bytes.12)
        data.append(bytes.13)
        data.append(bytes.14)
        data.append(bytes.15)
    }

    private static func readUUID(from data: Data, cursor: inout Int) throws -> UUID {
        guard data.count - cursor >= Self.uuidByteCount else {
            throw BinaryRelayCodecError.truncatedPayload
        }
        let uuid = uuid_t(
            data[cursor],
            data[cursor + 1],
            data[cursor + 2],
            data[cursor + 3],
            data[cursor + 4],
            data[cursor + 5],
            data[cursor + 6],
            data[cursor + 7],
            data[cursor + 8],
            data[cursor + 9],
            data[cursor + 10],
            data[cursor + 11],
            data[cursor + 12],
            data[cursor + 13],
            data[cursor + 14],
            data[cursor + 15]
        )
        cursor += Self.uuidByteCount
        return UUID(uuid: uuid)
    }

    private static func readByte(from data: Data, cursor: inout Int) throws -> UInt8 {
        guard data.count - cursor >= 1 else {
            throw BinaryRelayCodecError.truncatedPayload
        }
        defer { cursor += 1 }
        return data[cursor]
    }

    private static func fanoutIntentCode(_ intent: IMGatewayDomainEventFanoutIntent) -> UInt8 {
        switch intent {
        case .unspecified:
            return 0
        case .preSplitActiveFull:
            return 1
        case .preSplitActiveCompact:
            return 3
        case .preSplitInactiveHint:
            return 2
        }
    }

    private static func fanoutIntent(fromCode code: UInt8) throws -> IMGatewayDomainEventFanoutIntent {
        switch code {
        case 0:
            return .unspecified
        case 1:
            return .preSplitActiveFull
        case 2:
            return .preSplitInactiveHint
        case 3:
            return .preSplitActiveCompact
        default:
            throw BinaryRelayCodecError.invalidFanoutIntent
        }
    }
}

enum BinaryRelayCodecError: Error {
    case emptyBatch
    case emptyRecipients
    case invalidFanoutIntent
    case invalidMagic
    case invalidRecipientBytes
    case invalidRequestIDFlag
    case truncatedPayload
    case valueTooLarge
}
