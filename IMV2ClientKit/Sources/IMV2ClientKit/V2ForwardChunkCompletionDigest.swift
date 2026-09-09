import Crypto
import Foundation
import IMV2Core

/// Only immutable result metadata is retained. Result order on the wire is
/// irrelevant: encode in the persisted command's source order instead.
enum V2ForwardChunkCompletionDigest {
    static func acknowledged(command: V2ForwardMessagesCommand, results: [V2ForwardMessageResult]) throws -> String {
        try acknowledged(sourceMessageIDs: command.sourceMessageIDs, targetRoomIDs: command.targetRoomIDs, results: results)
    }

    static func acknowledged(sourceMessageIDs: [MessageID], targetRoomIDs: [RoomID], results: [V2ForwardMessageResult]) throws -> String {
        guard targetRoomIDs.count == 1,
              results.count == sourceMessageIDs.count,
              Set(results.map(\.sourceMessageID)) == Set(sourceMessageIDs),
              results.allSatisfy({ $0.targetRoomID == targetRoomIDs[0] })
        else { throw V2ClientCommandError.commandConflict }
        let bySource = Dictionary(uniqueKeysWithValues: results.map { ($0.sourceMessageID, $0) })
        var encoder = Encoder(kind: 0)
        for source in sourceMessageIDs {
            guard let result = bySource[source] else { throw V2ClientCommandError.commandConflict }
            encoder.string(source.rawValue)
            encoder.string(result.targetRoomID.rawValue)
            if let messageID = result.messageID, let sequence = result.roomSequence, result.errorCode == nil {
                guard sequence > 0, sequence <= UInt64(Int64.max) else { throw V2ClientCommandError.commandConflict }
                encoder.data.append(0)
                encoder.string(messageID.rawValue)
                encoder.integer(sequence)
            } else if let code = result.errorCode, result.messageID == nil, result.roomSequence == nil {
                guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw V2ClientCommandError.commandConflict }
                encoder.data.append(1)
                encoder.string(code)
            } else {
                throw V2ClientCommandError.commandConflict
            }
        }
        return encoder.digest
    }

    static func rejected(code: String) -> String {
        var encoder = Encoder(kind: 1)
        encoder.string(code)
        return encoder.digest
    }

    private struct Encoder {
        var data = Data("im-v2-forward-chunk-completion-v1".utf8)
        init(kind: UInt8) { data.append(kind) }
        mutating func integer(_ value: UInt64) {
            withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
        }
        mutating func string(_ value: String) {
            let bytes = Data(value.utf8)
            integer(UInt64(bytes.count))
            data.append(bytes)
        }
        var digest: String { "v1:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    }
}
