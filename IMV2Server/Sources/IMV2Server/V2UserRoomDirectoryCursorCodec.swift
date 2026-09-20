import Crypto
import Foundation
import IMV2Core

/// A cursor proves scan position, never membership. Authorization is evaluated on every page.
public struct V2UserRoomDirectoryCursorCodec: Sendable {
    private let key: SymmetricKey
    public static let maximumBytes = 2048

    public init(key: Data) throws {
        guard key.count >= 32 else { throw V2RoomRecoveryReadError.invalidRequest }
        self.key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(
            for: Data("im-v2-user-room-directory-v1".utf8), using: SymmetricKey(data: key))))
    }

    public func encode(userID: UserID, topologyGeneration: String, storeIndex: Int, after: RoomID?) throws -> String {
        guard userID.uuidValue != nil, !topologyGeneration.isEmpty, topologyGeneration.utf8.count <= 128,
              storeIndex >= 0, storeIndex <= Int(Int32.max), after == nil || after?.uuidValue != nil
        else { throw V2RoomRecoveryReadError.invalidCursor }
        let payload = try JSONEncoder().encode(Payload(version: 1, userID: userID.rawValue,
            topology: topologyGeneration, storeIndex: storeIndex, after: after?.rawValue))
        let signature = Data(HMAC<SHA256>.authenticationCode(for: payload, using: key))
        let result = payload.base64EncodedString() + "." + signature.base64EncodedString()
        guard result.utf8.count <= Self.maximumBytes else { throw V2RoomRecoveryReadError.invalidCursor }
        return result
    }

    public func decode(_ cursor: String, userID: UserID, topologyGeneration: String, storeCount: Int) throws -> Position {
        guard !cursor.isEmpty, cursor.utf8.count <= Self.maximumBytes else { throw V2RoomRecoveryReadError.invalidCursor }
        let components = cursor.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 2, let payload = Data(base64Encoded: String(components[0])),
              let signature = Data(base64Encoded: String(components[1])),
              HMAC<SHA256>.isValidAuthenticationCode(signature, authenticating: payload, using: key),
              let value = try? JSONDecoder().decode(Payload.self, from: payload), value.version == 1,
              let encodedUser = try? UserID(value.userID), encodedUser == userID
        else { throw V2RoomRecoveryReadError.invalidCursor }
        guard value.topology == topologyGeneration else { throw V2RoomRecoveryReadError.topologyChanged }
        guard value.storeIndex >= 0, value.storeIndex < storeCount else { throw V2RoomRecoveryReadError.invalidCursor }
        let after: RoomID?
        if let raw = value.after {
            guard let parsed = try? RoomID(raw), parsed.uuidValue != nil else { throw V2RoomRecoveryReadError.invalidCursor }
            after = parsed
        } else { after = nil }
        return .init(storeIndex: value.storeIndex, after: after)
    }

    public struct Position: Equatable, Sendable {
        public let storeIndex: Int
        public let after: RoomID?
    }

    private struct Payload: Codable {
        let version: Int
        let userID: String
        let topology: String
        let storeIndex: Int
        let after: String?
    }
}
