import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2Compression
import IMV2Core

extension V2PreparedGroupEventPageEncodingContext {
    init(
        requestID: UInt64,
        frameVersion: UInt8,
        compression: V2NegotiatedFrameCompression?,
        maximumUncompressedPayloadBytes: Int,
        compressionThresholdBytes: Int,
        maximumExpansionRatio: Int,
        maximumGroupEventPagePayloadBytes: Int,
        cache: V2PreparedGroupEventPageCache,
        captureAuthorSample: Bool = false
    ) {
        self.init(
            requestID: requestID,
            frameVersion: frameVersion,
            maximumGroupEventPagePayloadBytes: maximumGroupEventPagePayloadBytes,
            encoder: V2GroupEventPageEncoder(
                requestID: requestID,
                compression: compression,
                maximumUncompressedPayloadBytes: maximumUncompressedPayloadBytes,
                compressionThresholdBytes: compressionThresholdBytes,
                maximumExpansionRatio: maximumExpansionRatio,
                cache: cache
            ),
            captureAuthorSample: captureAuthorSample
        )
    }
}

private struct V2GroupEventPageEncoder: V2GroupEventPageEncoding {
    let requestID: UInt64
    let compression: V2NegotiatedFrameCompression?
    let maximumUncompressedPayloadBytes: Int
    let compressionThresholdBytes: Int
    let maximumExpansionRatio: Int
    let cache: V2PreparedGroupEventPageCache

    func frame(for key: V2PreparedGroupEventPageKey, events: () -> [V2GroupEventLogEntry]) throws -> V2Frame {
        try cache.frame(
            for: key,
            requestID: requestID,
            compression: compression,
            maximumUncompressedPayloadBytes: maximumUncompressedPayloadBytes,
            compressionThresholdBytes: compressionThresholdBytes,
            maximumExpansionRatio: maximumExpansionRatio
        ) {
            var envelope = IMV2Envelope()
            envelope.requestID = requestID
            envelope.protocolVersion = UInt32(key.protocolVersion)
            envelope.groupEventPage = .init()
            envelope.groupEventPage.roomID = key.roomID
            envelope.groupEventPage.events = events().map { entry in
                var event = IMV2GroupEvent()
                event.sourceEventID = entry.sourceEventID.rawValue
                event.roomSequence = entry.roomSequence
                event.projectionKind = entry.projectionKind
                event.payload = entry.payload
                return event
            }
            envelope.groupEventPage.nextRoomSequence = key.nextRoomSequence
            envelope.groupEventPage.hasMore_p = key.hasMore
            return envelope
        }
    }

    func repeatedFieldBytes(_ entry: V2GroupEventLogEntry) -> Int {
        v2PreparedGroupEventRepeatedFieldBytes(entry)
    }

    func envelopeBytes(roomID: String, eventFieldBytes: Int, nextRoomSequence: UInt64, hasMore: Bool) -> Int {
        v2PreparedGroupEventPageEnvelopeBytes(roomID: roomID, eventFieldBytes: eventFieldBytes, nextRoomSequence: nextRoomSequence, hasMore: hasMore)
    }
}

private func v2PreparedGroupEventPageEnvelopeBytes(
    roomID: String,
    eventFieldBytes: Int,
    nextRoomSequence: UInt64,
    hasMore: Bool
) -> Int {
    let pageBytes =
        v2PreparedProtobufLengthDelimitedFieldBytes(
            fieldNumber: 1,
            payloadBytes: roomID.utf8.count
        )
        + eventFieldBytes
        + v2PreparedProtobufVarintFieldBytes(
            fieldNumber: 3,
            value: nextRoomSequence
        )
        + (hasMore
            ? v2PreparedProtobufVarintFieldBytes(fieldNumber: 4, value: 1)
            : 0)

    return v2PreparedProtobufVarintFieldBytes(fieldNumber: 1, value: .max)
        + v2PreparedProtobufVarintFieldBytes(
            fieldNumber: 2,
            value: UInt64(IMV2ProtocolVersion.current)
        )
        + v2PreparedProtobufLengthDelimitedFieldBytes(
            fieldNumber: 62,
            payloadBytes: pageBytes
        )
}

private func v2PreparedGroupEventRepeatedFieldBytes(
    _ entry: V2GroupEventLogEntry
) -> Int {
    let eventBytes =
        v2PreparedProtobufLengthDelimitedFieldBytes(
            fieldNumber: 1,
            payloadBytes: entry.sourceEventID.rawValue.utf8.count
        )
        + v2PreparedProtobufVarintFieldBytes(
            fieldNumber: 2,
            value: entry.roomSequence
        )
        + v2PreparedProtobufLengthDelimitedFieldBytes(
            fieldNumber: 3,
            payloadBytes: entry.projectionKind.utf8.count
        )
        + v2PreparedProtobufLengthDelimitedFieldBytes(
            fieldNumber: 4,
            payloadBytes: entry.payload.count
        )
    return v2PreparedProtobufLengthDelimitedFieldBytes(
        fieldNumber: 2,
        payloadBytes: eventBytes
    )
}

private func v2PreparedProtobufLengthDelimitedFieldBytes(
    fieldNumber: Int,
    payloadBytes: Int
) -> Int {
    v2PreparedProtobufTagBytes(fieldNumber: fieldNumber, wireType: 2)
        + v2PreparedProtobufVarintByteCount(UInt64(payloadBytes))
        + payloadBytes
}

private func v2PreparedProtobufVarintFieldBytes(
    fieldNumber: Int,
    value: UInt64
) -> Int {
    guard value != 0 else { return 0 }
    return v2PreparedProtobufTagBytes(fieldNumber: fieldNumber, wireType: 0)
        + v2PreparedProtobufVarintByteCount(value)
}

private func v2PreparedProtobufTagBytes(
    fieldNumber: Int,
    wireType: UInt64
) -> Int {
    v2PreparedProtobufVarintByteCount((UInt64(fieldNumber) << 3) | wireType)
}

private func v2PreparedProtobufVarintByteCount(_ value: UInt64) -> Int {
    var remaining = value
    var count = 1
    while remaining >= 0x80 {
        remaining >>= 7
        count += 1
    }
    return count
}
