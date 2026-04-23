import NIOCore
import Vapor

struct AuthClientIPResolver: Sendable {
    let trustedProxyIPs: Set<String>

    static func load(from environment: Environment) -> AuthClientIPResolver {
        let trustedProxyIPs = Set(
            (Environment.get("TRUSTED_PROXY_IPS") ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )

        return AuthClientIPResolver(trustedProxyIPs: trustedProxyIPs)
    }

    func resolveClientIPAddress(for req: Request) -> String? {
        resolveClientIPAddress(remoteIPAddress: req.remoteAddress?.ipAddress, headers: req.headers)
    }

    func resolveClientIPAddress(remoteIPAddress: String?, headers: HTTPHeaders) -> String? {
        let normalizedRemote = normalize(ip: remoteIPAddress)

        guard let normalizedRemote else {
            return nil
        }

        guard trustedProxyIPs.contains(normalizedRemote) else {
            return normalizedRemote
        }

        if let forwardedIP = headers.forwarded.compactMap({ normalizeForwarded(ip: $0.for) }).first {
            return forwardedIP
        }

        if let xRealIP = normalize(ip: headers.first(name: "X-Real-IP")) {
            return xRealIP
        }

        if let xForwardedFor = headers.first(name: .xForwardedFor)?
            .split(separator: ",")
            .compactMap({ normalize(ip: String($0)) })
            .first
        {
            return xForwardedFor
        }

        return normalizedRemote
    }

    private func normalizeForwarded(ip: String?) -> String? {
        guard var value = ip?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.lowercased() != "unknown"
        else {
            return nil
        }

        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }

        if value.hasPrefix("["),
           let closingBracket = value.firstIndex(of: "]")
        {
            return normalize(ip: String(value[value.index(after: value.startIndex)..<closingBracket]))
        }

        if let colonIndex = value.lastIndex(of: ":"),
           value[..<colonIndex].contains(".")
        {
            return normalize(ip: String(value[..<colonIndex]))
        }

        return normalize(ip: value)
    }

    private func normalize(ip: String?) -> String? {
        guard let rawValue = ip?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty
        else {
            return nil
        }

        return rawValue
    }
}

private struct AuthClientIPResolverStorageKey: StorageKey {
    typealias Value = AuthClientIPResolver
}

extension Application {
    var authClientIPResolver: AuthClientIPResolver {
        get {
            if let resolver = self.storage[AuthClientIPResolverStorageKey.self] {
                return resolver
            }

            let resolver = AuthClientIPResolver(trustedProxyIPs: [])
            self.storage[AuthClientIPResolverStorageKey.self] = resolver
            return resolver
        }
        set {
            self.storage[AuthClientIPResolverStorageKey.self] = newValue
        }
    }
}
