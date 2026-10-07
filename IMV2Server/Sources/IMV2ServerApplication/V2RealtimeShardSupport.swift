import Crypto
import Foundation
import IMV2ActorContracts
import IMV2ServerContracts
import Synchronization

/// Canonical control identity is independent of transport signatures. The
/// fingerprint identifies a retry; the transport still authenticates authority.
public enum V2RealtimeShardFingerprint {
    private struct Material: Codable {
        let token: V2RealtimeShardToken
        let session: V2RealtimeShardSession
        let baseRevision: Int64
        let nextRevision: Int64
        let mutation: V2RealtimeShardMutation
    }
    public static func control(token: V2RealtimeShardToken, session: V2RealtimeShardSession,
        baseRevision: Int64, nextRevision: Int64, mutation: V2RealtimeShardMutation) throws -> Data {
        try hash(Material(token: token, session: session, baseRevision: baseRevision,
                          nextRevision: nextRevision, mutation: mutation))
    }
    public static func snapshot(_ interests: [V2RealtimeShardInterest]) throws -> Data {
        try hash(interests.sorted { key($0.key) < key($1.key) })
    }
    private static func hash<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return Data(SHA256.hash(data: try encoder.encode(value)))
    }
    static func key(_ key: V2RealtimeTopicKey) -> String { key.kind.rawValue + "\u{0}" + key.id }
}

/// Shared across every local partition. Staging counts against the same budget
/// as installed subscriptions, so a replacement cannot double memory unbounded.
final class V2RealtimeIndexBudget: Sendable {
    private struct State: Sendable { var items = 0; var bytes = 0 }
    private let state = Mutex(State())
    private let maximumItems: Int
    private let maximumBytes: Int
    init(maximumItems: Int, maximumBytes: Int) {
        self.maximumItems = maximumItems; self.maximumBytes = maximumBytes
    }
    func reserve(items: Int, bytes: Int) -> Bool {
        state.withLock { value in
            guard items >= 0, bytes >= 0, items <= maximumItems - value.items,
                  bytes <= maximumBytes - value.bytes else { return false }
            value.items += items; value.bytes += bytes; return true
        }
    }
    func release(items: Int, bytes: Int) {
        state.withLock { value in
            precondition(items <= value.items && bytes <= value.bytes)
            value.items -= items; value.bytes -= bytes
        }
    }
    static func bytes(_ interest: V2RealtimeShardInterest) -> Int { interest.key.id.utf8.count + 192 }
}
