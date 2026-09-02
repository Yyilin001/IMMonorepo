import Foundation
import IMV2Compression
import Testing

@Suite("V2 zlib frame compression")
struct V2ZlibFrameCompressionTests {
    @Test("v20 zlib member matches the cross-platform golden vector")
    func goldenVector() throws {
        let input = Data("IMV2 frame compression golden vector v20".utf8)
        let expected = Data([
            0x78, 0x01, 0xf3, 0xf4, 0x0d, 0x33, 0x52, 0x48,
            0x2b, 0x4a, 0xcc, 0x4d, 0x55, 0x48, 0xce, 0xcf,
            0x2d, 0x28, 0x4a, 0x2d, 0x2e, 0xce, 0xcc, 0xcf,
            0x53, 0x48, 0xcf, 0xcf, 0x49, 0x49, 0xcd, 0x53,
            0x28, 0x4b, 0x4d, 0x2e, 0xc9, 0x2f, 0x52, 0x28,
            0x33, 0x32, 0x00, 0x00, 0x24, 0xbb, 0x0e, 0x60,
        ])
        #expect(try V2ZlibFrameCompression.compress(
            input,
            maximumInputBytes: 65_536,
            level: 1
        ) == expected)
        #expect(try V2ZlibFrameCompression.decompress(
            expected,
            maximumOutputBytes: 65_536
        ) == input)
    }

    @Test("round trips an independent frame member")
    func roundTrip() throws {
        let input = Data(String(repeating: "message.accepted|room|sequence|", count: 2_000).utf8)
        let compressed = try V2ZlibFrameCompression.compress(
            input,
            maximumInputBytes: 128 * 1_024
        )
        #expect(compressed.count < input.count / 10)
        #expect(try V2ZlibFrameCompression.decompress(
            compressed,
            maximumOutputBytes: 128 * 1_024,
            maximumExpansionRatio: 1_024
        ) == input)
    }

    @Test("rejects output beyond the fixed decoded-byte budget")
    func rejectsOutputLimit() throws {
        let input = Data(repeating: 0x41, count: 8_192)
        let compressed = try V2ZlibFrameCompression.compress(
            input,
            maximumInputBytes: input.count
        )
        #expect(throws: V2FrameCompressionError.outputLimitExceeded) {
            try V2ZlibFrameCompression.decompress(
                compressed,
                maximumOutputBytes: input.count - 1
            )
        }
    }

    @Test("rejects a payload whose expansion ratio exceeds policy")
    func rejectsExpansionRatio() throws {
        let input = Data(repeating: 0x41, count: 8_192)
        let compressed = try V2ZlibFrameCompression.compress(
            input,
            maximumInputBytes: input.count
        )
        #expect(throws: V2FrameCompressionError.expansionRatioExceeded) {
            try V2ZlibFrameCompression.decompress(
                compressed,
                maximumOutputBytes: input.count,
                maximumExpansionRatio: 2
            )
        }
    }

    @Test("rejects corrupt compressed input")
    func rejectsCorruptInput() {
        #expect(throws: V2FrameCompressionError.self) {
            try V2ZlibFrameCompression.decompress(
                Data([0x01, 0x02, 0x03]),
                maximumOutputBytes: 65_536
            )
        }
    }
}
