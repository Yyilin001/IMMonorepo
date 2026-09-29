@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing
@testable import IMV2ServerGateway

struct V2PreparedGroupEventPageCacheTests {
    @Test("early page-key hits never invoke the envelope producer")
    func earlyKeySkipsMaterializationOnHit() throws {
        let cache = V2PreparedGroupEventPageCache(configuration: .init(
            maximumEntries: 8,
            maximumBytes: 1_048_576,
            shardCount: 4
        ))
        let key = V2PreparedGroupEventPageKey(
            protocolVersion: 21,
            roomID: "group-early-key",
            firstEventID: "event-1",
            lastEventID: "event-2",
            firstRoomSequence: 1,
            lastRoomSequence: 2,
            eventCount: 2,
            nextRoomSequence: 2,
            hasMore: true
        )
        var producerCalls = 0
        func frame(requestID: UInt64) throws -> V2Frame {
            try cache.frame(
                for: key,
                requestID: requestID,
                compression: nil,
                maximumUncompressedPayloadBytes: 65_536,
                compressionThresholdBytes: 1_024,
                maximumExpansionRatio: 64
            ) {
                producerCalls += 1
                return pageEnvelope(requestID: requestID, lastSequence: 2)
            }
        }

        let first = try frame(requestID: 101)
        let second = try frame(requestID: 202)

        #expect(producerCalls == 1)
        #expect(first.payload == second.payload)
        #expect(first.requestID == 101)
        #expect(second.requestID == 202)
        #expect(try V2ServerProtobufFrameCodec.decode(first).requestID == 101)
        #expect(try V2ServerProtobufFrameCodec.decode(second).requestID == 202)
        #expect(cache.snapshot().hits == 1)
        #expect(cache.snapshot().misses == 1)
    }

    @Test("a cold group page has one shard-local producer under concurrent fan-out")
    func singleFlightsColdPage() async throws {
        let cache = V2PreparedGroupEventPageCache(configuration: .init(
            maximumEntries: 64,
            maximumBytes: 8_388_608,
            shardCount: 16
        ))
        try await withThrowingTaskGroup(of: V2Frame?.self) { group in
            for requestID in 1 ... 128 {
                group.addTask {
                    try cache.frame(
                        for: pageEnvelope(requestID: UInt64(requestID), lastSequence: 16),
                        frameVersion: 21,
                        compression: nil,
                        maximumUncompressedPayloadBytes: 65_536,
                        compressionThresholdBytes: 1_024,
                        maximumExpansionRatio: 64
                    )
                }
            }
            for try await frame in group {
                #expect(frame?.flags == [.headerBoundRequestID])
            }
        }
        let snapshot = cache.snapshot()
        #expect(snapshot.misses == 1)
        #expect(snapshot.hits == 127)
        #expect(snapshot.entries == 1)
    }

    @Test("prepared group pages share payload bytes while request correlation stays in the frame header")
    func sharesPayloadAcrossRequestIDs() throws {
        let cache = V2PreparedGroupEventPageCache(configuration: .init(
            maximumEntries: 8,
            maximumBytes: 1_048_576,
            shardCount: 4
        ))
        let first = try #require(try cache.frame(
            for: pageEnvelope(requestID: 101, lastSequence: 2),
            frameVersion: 21,
            compression: nil,
            maximumUncompressedPayloadBytes: 65_536,
            compressionThresholdBytes: 1_024,
            maximumExpansionRatio: 64
        ))
        let second = try #require(try cache.frame(
            for: pageEnvelope(requestID: 202, lastSequence: 2),
            frameVersion: 21,
            compression: nil,
            maximumUncompressedPayloadBytes: 65_536,
            compressionThresholdBytes: 1_024,
            maximumExpansionRatio: 64
        ))

        #expect(first.payload == second.payload)
        #expect(first.requestID == 101)
        #expect(second.requestID == 202)
        #expect(first.flags == [.headerBoundRequestID])
        #expect(try V2ServerProtobufFrameCodec.decode(first).requestID == 101)
        #expect(try V2ServerProtobufFrameCodec.decode(second).requestID == 202)
        #expect(cache.snapshot() == .init(entries: 1, bytes: first.payload.count, hits: 1, misses: 1, evictions: 0))
    }

    @Test("prepared cache keys immutable event-page identity and keeps compression representations separate")
    func separatesPagesAndRepresentations() throws {
        let cache = V2PreparedGroupEventPageCache(configuration: .init(
            maximumEntries: 8,
            maximumBytes: 1_048_576,
            shardCount: 4
        ))
        let plain = try #require(try cache.frame(
            for: pageEnvelope(requestID: 1, lastSequence: 2),
            frameVersion: 21,
            compression: nil,
            maximumUncompressedPayloadBytes: 65_536,
            compressionThresholdBytes: 1,
            maximumExpansionRatio: 1_024
        ))
        let compressed = try #require(try cache.frame(
            for: pageEnvelope(requestID: 2, lastSequence: 2),
            frameVersion: 21,
            compression: .zlib,
            maximumUncompressedPayloadBytes: 65_536,
            compressionThresholdBytes: 1,
            maximumExpansionRatio: 1_024
        ))
        let differentPage = try #require(try cache.frame(
            for: pageEnvelope(requestID: 3, lastSequence: 3),
            frameVersion: 21,
            compression: nil,
            maximumUncompressedPayloadBytes: 65_536,
            compressionThresholdBytes: 1,
            maximumExpansionRatio: 1_024
        ))

        #expect(plain.flags == [.headerBoundRequestID])
        #expect(compressed.flags == [.compressed, .headerBoundRequestID])
        #expect(compressed.payload != plain.payload)
        #expect(differentPage.payload != plain.payload)
        #expect(try V2ServerProtobufFrameCodec.decode(
            compressed,
            compression: .zlib,
            maximumExpansionRatio: 1_024
        ).requestID == 2)
        let snapshot = cache.snapshot()
        #expect(snapshot.entries == 2)
        #expect(snapshot.misses == 3)
    }

    @Test("prepared cache is bounded and ignores ordinary responses and older protocols")
    func enforcesBoundsAndScope() throws {
        let cache = V2PreparedGroupEventPageCache(configuration: .init(
            maximumEntries: 1,
            maximumBytes: 65_536,
            shardCount: 1
        ))
        _ = try cache.frame(
            for: pageEnvelope(requestID: 1, lastSequence: 2),
            frameVersion: 21,
            compression: nil,
            maximumUncompressedPayloadBytes: 65_536,
            compressionThresholdBytes: 1_024,
            maximumExpansionRatio: 64
        )
        _ = try cache.frame(
            for: pageEnvelope(requestID: 2, lastSequence: 3),
            frameVersion: 21,
            compression: nil,
            maximumUncompressedPayloadBytes: 65_536,
            compressionThresholdBytes: 1_024,
            maximumExpansionRatio: 64
        )
        var acknowledged = IMV2Envelope()
        acknowledged.requestID = 4
        acknowledged.protocolVersion = 21
        acknowledged.acknowledged = .init()

        #expect(cache.snapshot().entries == 1)
        #expect(cache.snapshot().evictions == 1)
        #expect(try cache.frame(
            for: acknowledged,
            frameVersion: 21,
            compression: nil,
            maximumUncompressedPayloadBytes: 65_536,
            compressionThresholdBytes: 1_024,
            maximumExpansionRatio: 64
        ) == nil)
        #expect(try cache.frame(
            for: pageEnvelope(requestID: 5, lastSequence: 2),
            frameVersion: 20,
            compression: nil,
            maximumUncompressedPayloadBytes: 65_536,
            compressionThresholdBytes: 1_024,
            maximumExpansionRatio: 64
        ) == nil)
    }

    private func pageEnvelope(requestID: UInt64, lastSequence: UInt64) -> IMV2Envelope {
        var envelope = IMV2Envelope()
        envelope.requestID = requestID
        envelope.protocolVersion = 21
        envelope.groupEventPage = .init()
        envelope.groupEventPage.roomID = "group-prepared-cache-test"
        envelope.groupEventPage.nextRoomSequence = lastSequence + 1
        envelope.groupEventPage.hasMore_p = true
        envelope.groupEventPage.events = (1 ... lastSequence).map { sequence in
            var event = IMV2GroupEvent()
            event.sourceEventID = "event-\(sequence)"
            event.roomSequence = sequence
            event.projectionKind = "message"
            event.payload = Data(repeating: UInt8(sequence), count: 512)
            return event
        }
        return envelope
    }
}
