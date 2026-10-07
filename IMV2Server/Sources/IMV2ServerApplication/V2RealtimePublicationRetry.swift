import Foundation
import IMV2ServerContracts

/// Only explicit capacity proof receives short retries. Network, routing and
/// persistence failures retain their existing exponential backoff.
func v2RealtimePublicationRetryDelay(error: any Error, identity: String,
                                    attempt: Int, maximumDelay: TimeInterval) -> TimeInterval {
    precondition(attempt > 0 && maximumDelay > 0)
    guard error is V2RealtimePublicationBackpressure else {
        return min(maximumDelay, pow(2, Double(min(attempt - 1, 5))))
    }
    let base = min(min(2, maximumDelay), 0.5 * pow(2, Double(min(attempt - 1, 2))))
    // Version-stable FNV-1a over canonical identity and attempt distributes
    // durable retries without process-local randomness or Swift Hasher.
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in (identity.lowercased() + ":" + String(attempt)).utf8 {
        hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
    }
    let fraction = Double(hash >> 11) / 9_007_199_254_740_992
    let floor = max(base / 2, Double.leastNonzeroMagnitude)
    return min(base, max(floor, base * (0.5 + 0.5 * fraction)))
}
