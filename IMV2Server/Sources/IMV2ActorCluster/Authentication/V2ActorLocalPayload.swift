import Foundation

/// The same sorted-key JSON byte ceiling as a SignedPacket, measured once for
/// a typed same-process call. The count cannot be supplied by a caller.
struct V2ActorLocalPayload<Body: Encodable & Sendable>: Sendable {
    let body: Body
    let byteCount: Int

    init(_ body: Body) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(body)
        self.body = body
        self.byteCount = bytes.count
    }
}
