import Crypto
import Foundation
import IMV2ActorContracts

/// A signed ephemeral key exchange establishes separate request/reply keys.
/// Neither the shared secret nor derived keys are serialized or logged.
struct V2ActorSessionMAC: Sendable {
    let sessionID: UUID
    let client: V2ActorServiceID
    let server: V2ActorServiceID
    private let requestKey: SymmetricKey
    private let replyKey: SymmetricKey

    init(privateKey: Curve25519.KeyAgreement.PrivateKey, peerKey: Data,
         transcript: Data, sessionID: UUID, client: V2ActorServiceID, server: V2ActorServiceID) throws {
        guard peerKey.count == 32 else { throw V2ActorAuthenticationError.invalidRequest }
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: peerKey))
        var binding = Data("imv2-session-mac-v1".utf8)
        binding.append(transcript); binding.append(Self.uuidBytes(sessionID))
        binding.append(Data(client.rawValue.utf8)); binding.append(0); binding.append(Data(server.rawValue.utf8))
        let salt = Data(SHA256.hash(data: binding))
        self.sessionID = sessionID; self.client = client; self.server = server
        requestKey = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
            sharedInfo: Data("request".utf8), outputByteCount: 32)
        replyKey = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
            sharedInfo: Data("reply".utf8), outputByteCount: 32)
    }

    func seal<Body: Encodable>(_ body: Body, reply: Bool, maximumBytes: Int) throws -> V2ActorSignedPacket {
        let encoded = try V2ActorProtobuf.encode(body)
        guard maximumBytes > 0, !encoded.isEmpty, encoded.count <= maximumBytes - 16 else {
            throw V2ActorAuthenticationError.oversized
        }
        var bytes = Self.uuidBytes(sessionID); bytes.append(encoded)
        var mac = HMAC<SHA256>(key: reply ? replyKey : requestKey)
        mac.update(data: Data(String(reflecting: Body.self).utf8)); mac.update(data: bytes)
        return .init(signerID: reply ? server : client, body: bytes, signature: Data(mac.finalize()))
    }

    func open<Body: Decodable>(_ packet: V2ActorSignedPacket, as: Body.Type, reply: Bool,
                              maximumBytes: Int) throws -> Body {
        guard maximumBytes > 0, packet.body.count <= maximumBytes,
              packet.signerID == (reply ? server : client),
              try Self.packetSessionID(packet) == sessionID else {
            throw V2ActorAuthenticationError.wrongRecipient
        }
        // Use the library's constant-time authentication comparison.
        guard HMAC<SHA256>.isValidAuthenticationCode(packet.signature, authenticating:
            V2MACAuthenticatedBytes(domain: Data(String(reflecting: Body.self).utf8), body: packet.body), using: reply ? replyKey : requestKey) else {
            throw V2ActorAuthenticationError.invalidSignature
        }
        do { return try V2ActorProtobuf.decode(Body.self, from: Data(packet.body.dropFirst(16))) }
        catch { throw V2ActorAuthenticationError.invalidRequest }
    }

    static func packetSessionID(_ packet: V2ActorSignedPacket) throws -> UUID {
        guard packet.signature.count == 32, packet.body.count > 16 else { throw V2ActorAuthenticationError.invalidSignature }
        var value: uuid_t = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
        withUnsafeMutableBytes(of: &value) { $0.copyBytes(from: packet.body.prefix(16)) }
        return UUID(uuid: value)
    }
    private static func uuidBytes(_ id: UUID) -> Data {
        var value = id.uuid
        return withUnsafeBytes(of: &value) { Data($0) }
    }
}

/// HMAC consumes the two existing regions without joining/copying the packet.
private struct V2MACAuthenticatedBytes: DataProtocol {
    typealias Index = Int
    typealias SubSequence = Data
    let domain: Data
    let body: Data
    var startIndex: Int { 0 }
    var endIndex: Int { domain.count + body.count }
    var regions: [Data] { [domain, body] }
    subscript(index: Int) -> UInt8 {
        precondition(index >= startIndex && index < endIndex)
        return index < domain.count ? domain[domain.startIndex + index] : body[body.startIndex + index - domain.count]
    }
    subscript(bounds: Range<Int>) -> Data { Data(bounds.map { self[$0] }) }
    func index(after i: Int) -> Int { i + 1 }
    func index(before i: Int) -> Int { i - 1 }
}

protocol V2ActorSessionBoundCall { var sessionID: UUID { get } }
extension RoomSubscriptionBatchCall: V2ActorSessionBoundCall {}
extension RoomSubscriptionCall: V2ActorSessionBoundCall {}
extension JournalProjectionCall: V2ActorSessionBoundCall {}
extension RealtimeCall: V2ActorSessionBoundCall {}
extension ShardCall: V2ActorSessionBoundCall {}
