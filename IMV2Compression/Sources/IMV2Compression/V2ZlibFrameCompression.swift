import CZlib
import Foundation

public enum V2FrameCompressionError: Error, Equatable, Sendable {
    case invalidConfiguration
    case inputTooLarge
    case compressionFailed(Int32)
    case invalidCompressedPayload(Int32)
    case outputLimitExceeded
    case expansionRatioExceeded
}

/// Transport-neutral result of the protobuf handshake. Generated protobuf
/// enum types remain at the client/server edges instead of leaking into this
/// shared compression primitive.
public enum V2NegotiatedFrameCompression: Equatable, Sendable {
    case zlib
}

/// One independent zlib member per gateway frame.
///
/// Independent members avoid cross-connection compression state, make a
/// dropped frame recoverable by the ordinary request/cursor protocol and let
/// an immutable compressed page be shared by multiple authorized recipients.
public enum V2ZlibFrameCompression {
    public static let defaultCompressionLevel: Int32 = 1
    public static let defaultMaximumExpansionRatio = 64

    public static func compress(
        _ input: Data,
        maximumInputBytes: Int,
        level: Int32 = defaultCompressionLevel
    ) throws -> Data {
        guard maximumInputBytes > 0,
              level >= Int32(Z_NO_COMPRESSION),
              level <= Int32(Z_BEST_COMPRESSION)
        else { throw V2FrameCompressionError.invalidConfiguration }
        guard input.count <= maximumInputBytes else {
            throw V2FrameCompressionError.inputTooLarge
        }

        let sourceCount = uLong(input.count)
        let bound = compressBound(sourceCount)
        guard bound <= uLong(Int.max) else {
            throw V2FrameCompressionError.inputTooLarge
        }
        var output = Data(count: max(1, Int(bound)))
        var outputCount = bound
        let status: Int32 = input.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                compress2(
                    destination.bindMemory(to: Bytef.self).baseAddress,
                    &outputCount,
                    source.bindMemory(to: Bytef.self).baseAddress,
                    sourceCount,
                    level
                )
            }
        }
        guard status == Z_OK else {
            throw V2FrameCompressionError.compressionFailed(status)
        }
        output.count = Int(outputCount)
        return output
    }

    public static func decompress(
        _ input: Data,
        maximumOutputBytes: Int,
        maximumExpansionRatio: Int = defaultMaximumExpansionRatio
    ) throws -> Data {
        guard maximumOutputBytes > 0, maximumExpansionRatio > 0 else {
            throw V2FrameCompressionError.invalidConfiguration
        }
        guard !input.isEmpty else {
            throw V2FrameCompressionError.invalidCompressedPayload(Int32(Z_DATA_ERROR))
        }

        var output = Data(count: maximumOutputBytes)
        var outputCount = uLong(maximumOutputBytes)
        let status: Int32 = input.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                uncompress(
                    destination.bindMemory(to: Bytef.self).baseAddress,
                    &outputCount,
                    source.bindMemory(to: Bytef.self).baseAddress,
                    uLong(input.count)
                )
            }
        }
        if status == Z_BUF_ERROR {
            throw V2FrameCompressionError.outputLimitExceeded
        }
        guard status == Z_OK else {
            throw V2FrameCompressionError.invalidCompressedPayload(status)
        }
        guard outputCount <= uLong(Int.max) else {
            throw V2FrameCompressionError.outputLimitExceeded
        }
        let decodedCount = Int(outputCount)
        guard input.count <= Int.max / maximumExpansionRatio,
              decodedCount <= input.count * maximumExpansionRatio
        else { throw V2FrameCompressionError.expansionRatioExceeded }
        output.count = decodedCount
        return output
    }
}
