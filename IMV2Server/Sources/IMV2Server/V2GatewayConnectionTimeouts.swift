import NIOCore

/// Validated once before constructing NIO timers. Millisecond configuration
/// must retain its exact value when represented as signed nanoseconds.
struct V2GatewayConnectionTimeouts: Sendable {
    static let maximumMilliseconds = Int(Int64.max / 1_000_000)
    let authentication: TimeAmount
    let idle: TimeAmount

    init(authenticationMilliseconds: Int, idleMilliseconds: Int) throws {
        let supported = 1...Self.maximumMilliseconds
        guard supported.contains(authenticationMilliseconds), supported.contains(idleMilliseconds) else {
            throw V2TLSGatewayServerError.invalidConfiguration
        }
        authentication = .milliseconds(Int64(authenticationMilliseconds))
        idle = .milliseconds(Int64(idleMilliseconds))
    }
}
