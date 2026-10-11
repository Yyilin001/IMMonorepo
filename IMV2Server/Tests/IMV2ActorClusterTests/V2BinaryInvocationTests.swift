import IMV2ActorContracts
import Foundation
import NIO
import Testing
@testable import DistributedCluster

@Suite("Binary invocation preserves argument bytes and rejects malformed frames")
struct V2BinaryInvocationTests {
    @Test func actorIDPathIsEncodedOnceAndMetadataSurvives() async throws {
        var settings = ClusterSystemSettings(name: "actor-metadata-codec", host: "127.0.0.1", port: Int.random(in: 30_000...44_999))
        settings.threadPoolSize = 1; settings.downingStrategy = .none; settings.onDownAction = .none
        let system = await ClusterSystem("actor-metadata-codec", settings: settings)
        do {
            let path = try ActorPath([ActorPathSegment("user"), ActorPathSegment("room")])
            let id = ActorID(remote: settings.bindNode, path: path, incarnation: ActorIncarnation(42))
            id.metadata.type = .init(mangledName: "RoomType")
            id.metadata.wellKnown = "rooms"
            let wire = try id.toProto(context: system.serialization.context)
            #expect(wire.path.segments == ["user", "room"])
            #expect(wire.metadata[ActorMetadataKeys.__instance.path.id] == nil)
            let decoded = try ActorID(fromProto: wire, context: system.serialization.context)
            #expect(decoded.path == id.path && decoded.node == id.node && decoded.incarnation == id.incarnation)
            #expect(decoded.metadata.type?.mangledName == "RoomType")
            #expect(decoded.metadata.wellKnown == "rooms")
            // Older senders' duplicate metadata remains harmless on decode.
            var oldWire = wire
            oldWire.metadata[ActorMetadataKeys.__instance.path.id] = Data("ignored old path".utf8)
            let old = try ActorID(fromProto: oldWire, context: system.serialization.context)
            #expect(old.path == id.path && old.metadata.wellKnown == "rooms")
        } catch {
            try await system.shutdown().wait(); throw error
        }
        try await system.shutdown().wait()
    }
    @Test func binaryReplyRoundTripAndMalformedFrames() throws {
        let codec = BinaryRemoteCallReplySerializer(.init())
        let original = BinaryRemoteCallReply(callID: UUID(), value: Data(repeating: 42, count: 16_384))
        let encoded = try codec.serialize(original).readData()
        let decoded = try codec.deserialize(from: .data(encoded))
        #expect(decoded.callID == original.callID && decoded.value == original.value)
        #expect(encoded.count == 24 + original.value!.count)
        for end in [0, 3, 4, 19, 20, 23, 24, encoded.count - 1] {
            #expect(throws: (any Error).self) { try codec.deserialize(from: .data(encoded.prefix(end))) }
        }
        #expect(throws: (any Error).self) { try codec.deserialize(from: .data(encoded + Data([0]))) }
        var changed = encoded; changed[0] ^= 1
        #expect(throws: (any Error).self) { try codec.deserialize(from: .data(changed)) }
        changed = encoded; changed.replaceSubrange(20..<24, with: [255,255,255,255])
        #expect(throws: (any Error).self) { try codec.deserialize(from: .data(changed)) }
    }

    @Test func roundTripAndSize() throws {
        let codec = BinaryInvocationSerializer(.init())
        let original = InvocationMessage(callID: UUID(), targetIdentifier: "调用/target",
            genericSubstitutions: ["Swift.Int", "模块.类型"],
            arguments: [Data(), Data(0...255), Data(repeating: 42, count: 16_384)])
        let encoded = try codec.serialize(original)
        let result = try codec.deserialize(from: encoded)
        #expect(result.callID == original.callID)
        #expect(result.targetIdentifier == original.targetIdentifier)
        #expect(result.genericSubstitutions == original.genericSubstitutions)
        #expect(result.arguments == original.arguments)
        let legacy = try V2ActorProtobuf.encode(original)
        #expect(encoded.count < legacy.count)
    }

    @Test func emptyInvocation() throws {
        let codec = BinaryInvocationSerializer(.init())
        let original = InvocationMessage(callID: UUID(), targetIdentifier: "target",
            genericSubstitutions: [], arguments: [])
        let result = try codec.deserialize(from: codec.serialize(original))
        #expect(result.callID == original.callID)
        #expect(result.arguments.isEmpty && result.genericSubstitutions.isEmpty)
    }

    @Test func truncationAndTrailingBytes() throws {
        let codec = BinaryInvocationSerializer(.init())
        let original = InvocationMessage(callID: UUID(), targetIdentifier: "target",
            genericSubstitutions: ["Swift.Int"], arguments: [Data("signed bytes".utf8)])
        let bytes = try codec.serialize(original).readData()
        for end in 0..<bytes.count {
            #expect(throws: (any Error).self) { try codec.deserialize(from: .data(bytes.prefix(end))) }
        }
        #expect(throws: (any Error).self) { try codec.deserialize(from: .data(bytes + Data([0]))) }
    }

    @Test func forgedLengthsVersionAndUTF8() throws {
        let codec = BinaryInvocationSerializer(.init())
        let original = InvocationMessage(callID: UUID(), targetIdentifier: "t",
            genericSubstitutions: [], arguments: [])
        let bytes = try codec.serialize(original).readData()
        for offset in [0, 20, 25, 29] {
            var changed = bytes
            changed.replaceSubrange(offset..<(offset + 4), with: [255, 255, 255, 255])
            #expect(throws: (any Error).self) { try codec.deserialize(from: .data(changed)) }
        }
        var invalidUTF8 = bytes; invalidUTF8[24] = 255
        #expect(throws: (any Error).self) { try codec.deserialize(from: .data(invalidUTF8)) }
    }
}
