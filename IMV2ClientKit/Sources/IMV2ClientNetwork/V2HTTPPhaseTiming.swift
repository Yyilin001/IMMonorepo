import Foundation
/// Missing URLSession phases remain nil (for example, a reused connection).
public struct V2HTTPPhaseTiming: Sendable {
    public let dns: TimeInterval?
    public let connect: TimeInterval?
    public let tls: TimeInterval?
    public let request: TimeInterval?
    public let response: TimeInterval?
    public let networkProtocol: String?
    public init(dns: TimeInterval?, connect: TimeInterval?, tls: TimeInterval?, request: TimeInterval?,
                response: TimeInterval?, networkProtocol: String?) {
        self.dns = dns; self.connect = connect; self.tls = tls; self.request = request
        self.response = response; self.networkProtocol = networkProtocol
    }
    package static func duration(_ start: Date?, _ end: Date?) -> TimeInterval? {
        guard let start, let end else { return nil }
        let value = end.timeIntervalSince(start)
        return value.isFinite && value >= 0 ? value : nil
    }
}

