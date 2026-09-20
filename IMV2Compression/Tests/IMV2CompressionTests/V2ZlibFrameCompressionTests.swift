import Foundation
import IMV2Compression
import Testing

@Suite("V2 zlib frame compression")
struct V2ZlibFrameCompressionTests {
    @Test("invalid budgets are rejected before allocating an output buffer", arguments: [Int.min, -1, 0])
    func invalidBudgets(value: Int) throws {
        let input = Data([0x41])
        #expect(throws: V2FrameCompressionError.invalidConfiguration) {
            try V2ZlibFrameCompression.compress(input, maximumInputBytes: value)
        }
        #expect(throws: V2FrameCompressionError.invalidConfiguration) {
            try V2ZlibFrameCompression.decompress(input, maximumOutputBytes: value)
        }
        #expect(throws: V2FrameCompressionError.invalidConfiguration) {
            try V2ZlibFrameCompression.decompress(
                input, maximumOutputBytes: 1, maximumExpansionRatio: value
            )
        }
    }

    @Test("expansion bound is checked at its largest representable product")
    func expansionProductBounds() throws {
        let input = Data(repeating: 0x41, count: 128)
        let compressed = try V2ZlibFrameCompression.compress(input, maximumInputBytes: input.count)
        #expect(compressed.count > 1)
        let largestRatio = Int.max / compressed.count
        #expect(try V2ZlibFrameCompression.decompress(
            compressed, maximumOutputBytes: input.count,
            maximumExpansionRatio: largestRatio
        ) == input)
        for ratio in [largestRatio + 1, Int.max] {
            #expect(throws: V2FrameCompressionError.expansionRatioExceeded) {
                try V2ZlibFrameCompression.decompress(
                    compressed, maximumOutputBytes: input.count,
                    maximumExpansionRatio: ratio
                )
            }
        }
    }

    @Test("exact byte budgets allow a frame and reject one byte less")
    func exactByteBudgets() throws {
        let input = Data([0x41, 0x42, 0x43])
        let compressed = try V2ZlibFrameCompression.compress(input, maximumInputBytes: input.count)
        #expect(throws: V2FrameCompressionError.inputTooLarge) {
            try V2ZlibFrameCompression.compress(input, maximumInputBytes: input.count - 1)
        }
        #expect(try V2ZlibFrameCompression.decompress(
            compressed, maximumOutputBytes: input.count, maximumExpansionRatio: 1
        ) == input)
        #expect(throws: V2FrameCompressionError.outputLimitExceeded) {
            try V2ZlibFrameCompression.decompress(
                compressed, maximumOutputBytes: input.count - 1, maximumExpansionRatio: 1
            )
        }
    }

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
