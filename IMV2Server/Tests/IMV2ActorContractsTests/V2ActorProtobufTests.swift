import Foundation
import Testing
@testable import IMV2ActorContracts

@Suite("Typed Protobuf boundary")
struct V2ActorProtobufTests {
    struct Scalars: Codable, Equatable {
        let signed: Int64; let unsigned: UInt64; let binary: Data
        let uuid: UUID; let date: Date; let text: String
        let optional: String?; let values: [Bool]; let dictionary: [String: Int]
    }
    @Test func preservesScalarsWithoutJSONOrBase64() throws {
        let value = Scalars(signed: .min, unsigned: .max, binary: Data(0...255), uuid: UUID(),
            date: Date(timeIntervalSinceReferenceDate: -123.125), text: "中文\u{0}\"\\", optional: nil,
            values: [true, false], dictionary: ["a": -3, "b": 7])
        let bytes = try V2ActorProtobuf.encode(value)
        #expect(try referenceMatches(value))
        #expect(try V2ActorProtobuf.decode(Scalars.self, from: bytes) == value)
        #expect(bytes.range(of: value.binary) != nil)
        #expect(bytes.range(of: Data(value.binary.base64EncodedString().utf8)) == nil)
        #expect(try V2ActorProtobuf.encode(value) == bytes)
    }
    @Test func rejectsMalformedDuplicateAndOutOfRangeValues() throws {
        #expect(throws: (any Error).self) { try V2ActorProtobuf.decode(Int.self, from: Data()) }
        var number = Im_Actor_V1_Value(); number.signedValue = 256
        #expect(throws: (any Error).self) { try V2ActorProtobuf.decode(Int8.self, from: number.serializedData()) }
        number.doubleValue = .infinity
        #expect(throws: (any Error).self) { try V2ActorProtobuf.decode(Double.self, from: number.serializedData()) }
        var field = Im_Actor_V1_Field(); field.name = "a"; field.value.boolValue = true
        var duplicate = Im_Actor_V1_Value(); duplicate.objectValue.fields = [field, field]
        #expect(throws: (any Error).self) { try V2ActorProtobuf.decode([String: Bool].self, from: duplicate.serializedData()) }
        var nested = Im_Actor_V1_Value(); nested.boolValue = true
        for _ in 0..<65 { var parent = Im_Actor_V1_Value(); parent.arrayValue.values = [nested]; nested = parent }
        #expect(throws: (any Error).self) { try V2ActorProtobuf.decode([Bool].self, from: nested.serializedData()) }
    }
    @Test func linearWriterMatchesGeneratedEncoder() throws {
        for number: Int64 in [.min, -129, -128, -1, 0, 1, 127, 128, 16384, .max] {
            #expect(try referenceMatches(number))
        }
        for number: UInt64 in [0, 127, 128, 16384, .max] {
            #expect(try referenceMatches(number))
        }
        for object: [String: [Data?]] in [[:], ["": [nil, Data(), Data(0...255)]], ["中文": []]] {
            #expect(try referenceMatches(object))
            #expect(try V2ActorProtobuf.decode([String: [Data?]].self, from: V2ActorProtobuf.encode(object)) == object)
        }
        for value in [false, true] { #expect(try referenceMatches(value)) }
    }

    private func referenceMatches<T: Encodable>(_ value: T) throws -> Bool {
        let actual = try V2ActorProtobuf.encode(value)
        let reference = try V2ActorProtobuf.message(value).serializedData()
        return actual == reference
    }
    struct EncodingProbe: Encodable {
        func encode(to encoder: any Encoder) throws { throw ProbeError.unexpectedEncoding }
    }
    enum ProbeError: Error { case unexpectedEncoding }
    @Test func localAccountingDoesNotCallEncoder() {
        #expect(V2ActorPayloadBudget.retainedBytes(of: EncodingProbe()) > 0)
    }
}
