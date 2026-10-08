import Foundation

/// 与 SignedPacket 使用相同的 JSON 字节上限；
/// 对同进程的有类型调用只测量一次，字节数不能由调用方提供。
struct V2ActorLocalPayload<Body: Encodable & Sendable>: Sendable {
    let body: Body
    let byteCount: Int

    init(_ body: Body) throws {
        let encoder = JSONEncoder()
        let bytes = try encoder.encode(body)
        self.body = body
        self.byteCount = bytes.count
    }
}
