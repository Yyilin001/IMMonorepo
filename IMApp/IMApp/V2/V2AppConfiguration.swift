import Foundation
import IMV2ClientKit

struct V2AppConfiguration: Sendable {
    let accountBaseURL: URL
    let realtimeEndpoint: V2RealtimeEndpoint
    let keychainService: String
    let pushEndpointEnvironment: V2ClientPushEndpointEnvironment

    init(bundle: Bundle = .main) throws {
        try self.init(bundle: bundle, realtimeEndpointOverride: nil)
    }

    #if DEBUG
    /// Confines the deterministic offline UI fixture to Debug builds. The
    /// account HTTPS origin remains real so an established local session can
    /// still open its SQLite projection; only the realtime transport is made
    /// unavailable.
    init(localE2ETestForcesUnavailableRealtime: Bool, bundle: Bundle = .main) throws {
        let realtimeEndpointOverride = localE2ETestForcesUnavailableRealtime
            ? try V2RealtimeEndpoint(host: "127.0.0.1", port: 1)
            : nil
        try self.init(bundle: bundle, realtimeEndpointOverride: realtimeEndpointOverride)
    }
    #endif

    private init(bundle: Bundle, realtimeEndpointOverride: V2RealtimeEndpoint?) throws {
        guard let rawBaseURL = bundle.object(forInfoDictionaryKey: "IMV2AccountBaseURL") as? String,
              let accountBaseURL = URL(string: rawBaseURL),
              accountBaseURL.scheme?.lowercased() == "https", accountBaseURL.host != nil
        else { throw V2AppConfigurationError.invalidAccountBaseURL }
        guard let gatewayHost = bundle.object(forInfoDictionaryKey: "IMV2GatewayHost") as? String,
              let rawGatewayPort = bundle.object(forInfoDictionaryKey: "IMV2GatewayPort"),
              let gatewayPort = UInt16(String(describing: rawGatewayPort))
        else { throw V2AppConfigurationError.invalidRealtimeEndpoint }
        self.accountBaseURL = accountBaseURL
        if let realtimeEndpointOverride {
            realtimeEndpoint = realtimeEndpointOverride
        } else {
            realtimeEndpoint = try V2RealtimeEndpoint(host: gatewayHost, port: gatewayPort)
        }
        guard let rawPushEnvironment = bundle.object(forInfoDictionaryKey: "IMV2PushEnvironment") as? String,
              let pushEndpointEnvironment = V2ClientPushEndpointEnvironment(rawValue: rawPushEnvironment)
        else { throw V2AppConfigurationError.invalidPushEnvironment }
        self.pushEndpointEnvironment = pushEndpointEnvironment
        keychainService = (bundle.bundleIdentifier ?? "com.stskcxfz.imapp") + ".v2"
    }

    func endpoint(_ path: String) -> URL {
        accountBaseURL.appending(path: path)
    }

    /// The media edge shares the account-service HTTPS origin in local V2
    /// composition, while retaining a distinct `/v2/media` authorization
    /// boundary and deployment listener in production.
    var mediaEdgeEndpoint: URL {
        endpoint("v2/media")
    }

    var pushEndpoint: URL {
        endpoint("v2/push-endpoint")
    }
}

enum V2AppConfigurationError: Error, Equatable {
    case invalidAccountBaseURL
    case invalidRealtimeEndpoint
    case invalidPushEnvironment
}
