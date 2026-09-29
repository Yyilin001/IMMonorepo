@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import SwiftProtobuf
import Testing
@testable import IMV2ServerGateway

struct V2ProtobufFrameCodecTests {
    @Test("recipient-specific author TCP payload retains private alias and its original revision")
    func authorContactAliasRoundTrip() throws {
        let actor = UserID(uuid:UUID()),target = UserID(uuid:UUID()),device = DeviceID(uuid:UUID()),room = RoomID(uuid:UUID()),now = Date()
        let revision = try #require(V2ProfileRevision(rawValue:1))
        let view = try V2ProfileView(userID:target,publicIdentity:.init(userID:target,handle:.init("aliaswire"),displayName:"Public",accountKind:.regular),avatar:nil,state:.active,revision:revision,visibilityRevision:revision)
        let lease = try V2PresentationAccessLease(actorUserID:actor,deviceID:device,key:.init(userID:target,context:.room(room)),profileRevision:revision,visibilityRevision:revision,contextRevision:1,observedAt:now,validUntil:now.addingTimeInterval(120))
        let alias = try V2ContactAlias(ownerUserID:actor,targetUserID:target,remarkName:"Private name",revision:#require(.init(rawValue:9)))
        let presentation = try V2AuthorizedProfilePresentation(view:view,lease:lease,contactAlias:alias)
        let batch = try V2ProfilePresentationBatchResponse(serverNowUnixMilliseconds:lease.observedAtUnixMilliseconds,results:[.presentation(presentation,avatar:nil)])
        let delta = try V2AuthorPresentationDelta(streamID:UUID(),viewID:UUID(),sequence:1,actorUserID:actor,deviceID:device,roomID:room,batch:batch)
        var envelope = IMV2Envelope();envelope.protocolVersion = IMV2ProtocolVersion.current
        envelope.authorPresentationDelta = .init();envelope.authorPresentationDelta.payload = try delta.encoded()
        let decoded = try V2ServerProtobufFrameCodec.decode(V2ServerProtobufFrameCodec.encode(envelope,frameVersion:UInt8(IMV2ProtocolVersion.current)))
        #expect(try V2AuthorPresentationDelta.decode(decoded.authorPresentationDelta.payload) == delta)
    }

    @Test("sync record byte budgeting matches the protobuf repeated field")
    func sizesSyncBatchRecordExactly() throws {
        let record = try V2SyncRecord(
            sequence: 16_384,
            sourceEventID: try .init("00000000-0000-0000-0000-000000000123"),
            projectionKind: "message",
            payloadJSON: String(repeating: "x", count: 700)
        )
        var protobuf = IMV2SyncRecord()
        protobuf.userSyncSequence = record.sequence
        protobuf.sourceEventID = record.sourceEventID.rawValue
        protobuf.projectionKind = record.projectionKind
        protobuf.payload = Data(record.payloadJSON.utf8)
        let encodedRecordBytes = try protobuf.serializedData().count
        let repeatedFieldBytes = 1 + protobufVarintBytes(encodedRecordBytes) + encodedRecordBytes

        #expect(v2EncodedSyncBatchRecordFieldBytes(record) == repeatedFieldBytes)
    }

    @Test("server protobuf codec rejects a mismatched command header")
    func rejectsMismatch() throws {
        var envelope = IMV2Envelope()
        envelope.requestID = 11
        envelope.protocolVersion = 1
        envelope.syncAck = .init()
        let frame = try V2ServerProtobufFrameCodec.encode(envelope, frameVersion: 1)
        let mismatch = V2Frame(version: 1, command: .syncPull, requestID: 11, payload: frame.payload)
        #expect(throws: V2ServerProtobufFrameCodecError.headerCommandMismatch) { _ = try V2ServerProtobufFrameCodec.decode(mismatch) }
    }

    @Test("server codec rejects unnegotiated frame flags before protobuf decoding")
    func rejectsFrameFlags() throws {
        var envelope = IMV2Envelope()
        envelope.requestID = 12
        envelope.protocolVersion = 1
        envelope.syncPull = .init()
        let plain = try V2ServerProtobufFrameCodec.encode(envelope, frameVersion: 1)
        let compressed = V2Frame(
            version: plain.version,
            flags: [.compressed],
            command: plain.command,
            requestID: plain.requestID,
            payload: plain.payload
        )
        #expect(throws: V2ServerProtobufFrameCodecError.unsupportedCompression) {
            _ = try V2ServerProtobufFrameCodec.decode(compressed)
        }
        #expect(throws: V2ServerProtobufFrameCodecError.unsupportedFrameFlags) {
            _ = try V2ServerProtobufFrameCodec.encode(envelope, frameVersion: 1, flags: [.compressed])
        }
    }

    @Test("server codec compresses only after negotiation and preserves envelope validation")
    func negotiatedCompressionRoundTrip() throws {
        var envelope = IMV2Envelope()
        envelope.requestID = 14
        envelope.protocolVersion = IMV2ProtocolVersion.current
        envelope.groupEventPage = .init()
        envelope.groupEventPage.roomID = "group-compression-test"
        var event = IMV2GroupEvent()
        event.sourceEventID = "00000000-0000-0000-0000-000000000014"
        event.roomSequence = 1
        event.projectionKind = "message"
        event.payload = Data(repeating: 0x61, count: 8_192)
        envelope.groupEventPage.events = [event]

        let frame = try V2ServerProtobufFrameCodec.encode(
            envelope,
            frameVersion: UInt8(IMV2ProtocolVersion.current),
            compression: .zlib,
            compressionThresholdBytes: 1,
            maximumExpansionRatio: 1_024
        )
        #expect(frame.flags == [.compressed])
        #expect(frame.payload.count < 512)
        #expect(try V2ServerProtobufFrameCodec.decode(
            frame,
            compression: .zlib,
            maximumExpansionRatio: 1_024
        ) == envelope)
        #expect(throws: V2ServerProtobufFrameCodecError.unsupportedCompression) {
            _ = try V2ServerProtobufFrameCodec.decode(frame)
        }
    }

    @Test("v21 group pages may bind request correlation to the frame header")
    func headerBoundRequestIDRoundTrip() throws {
        var envelope = IMV2Envelope()
        envelope.requestID = 77
        envelope.protocolVersion = 21
        envelope.groupEventPage = .init()
        envelope.groupEventPage.roomID = "group-header-bound-test"

        let frame = try V2ServerProtobufFrameCodec.encode(
            envelope,
            frameVersion: 21,
            bindRequestIDToHeader: true
        )
        #expect(frame.flags == [.headerBoundRequestID])
        #expect(frame.requestID == 77)
        #expect(try IMV2Envelope(serializedBytes: frame.payload).requestID == 0)
        #expect(try V2ServerProtobufFrameCodec.decode(frame) == envelope)
    }

    @Test("header-bound correlation is restricted to v21 group-event pages")
    func rejectsInvalidHeaderBoundRequestIDUse() throws {
        var ordinary = IMV2Envelope()
        ordinary.requestID = 78
        ordinary.protocolVersion = 21
        ordinary.syncAck = .init()
        #expect(throws: V2ServerProtobufFrameCodecError.unsupportedFrameFlags) {
            _ = try V2ServerProtobufFrameCodec.encode(
                ordinary,
                frameVersion: 21,
                bindRequestIDToHeader: true
            )
        }

        var page = IMV2Envelope()
        page.requestID = 79
        page.protocolVersion = 20
        page.groupEventPage = .init()
        #expect(throws: V2ServerProtobufFrameCodecError.unsupportedFrameFlags) {
            _ = try V2ServerProtobufFrameCodec.encode(
                page,
                frameVersion: 20,
                bindRequestIDToHeader: true
            )
        }
    }

    @Test("server codec applies the explicit protobuf nesting limit")
    func rejectsExcessiveMessageNesting() throws {
        let frame = try nestedSyncBatchFrame()
        #expect(throws: V2ServerProtobufFrameCodecError.payloadDecodeFailed) {
            _ = try V2ServerProtobufFrameCodec.decode(frame, maximumMessageDepth: 1)
        }
        #expect(throws: V2ServerProtobufFrameCodecError.invalidMessageDepthLimit) {
            _ = try V2ServerProtobufFrameCodec.decode(frame, maximumMessageDepth: 0)
        }
        #expect(try V2ServerProtobufFrameCodec.decode(frame, maximumMessageDepth: 8).syncBatch.records.count == 1)
    }

    private func nestedSyncBatchFrame() throws -> V2Frame {
        var envelope = IMV2Envelope()
        envelope.requestID = 13
        envelope.protocolVersion = 1
        envelope.syncBatch = .init()
        envelope.syncBatch.records = [.init()]
        return try V2ServerProtobufFrameCodec.encode(envelope, frameVersion: 1)
    }
}

private func protobufVarintBytes(_ value: Int) -> Int {
    var remaining = value
    var count = 1
    while remaining >= 0x80 {
        remaining >>= 7
        count += 1
    }
    return count
}
