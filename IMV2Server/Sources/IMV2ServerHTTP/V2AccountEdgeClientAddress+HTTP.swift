import IMV2ServerContracts
import NIOCore

// Parse the authenticated HTTP edge address before deriving its opaque key.
extension V2AccountEdgeClientAddress {
    public init(_ value: String) throws {
        guard (1 ... 45).contains(value.utf8.count),
              (try? SocketAddress(ipAddress: value, port: 0)) != nil
        else { throw V2AccountEdgeClientRateLimitError.invalidAddress }
        self.init(validatedAddress: value)
    }
}
