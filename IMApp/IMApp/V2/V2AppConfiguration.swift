import Foundation
import IMV2ClientKit

struct V2AppConfiguration: Sendable {
    let accountBaseURL: URL
    let realtimeEndpoint: V2RealtimeEndpoint
    let passkeyRelyingPartyID: String
    let keychainService: String
    let pushEndpointEnvironment: V2ClientPushEndpointEnvironment

    init(bundle: Bundle = .main) throws {
        guard let rawBaseURL = bundle.object(forInfoDictionaryKey: "IMV2AccountBaseURL") as? String,
              let accountBaseURL = URL(string: rawBaseURL),
              accountBaseURL.scheme?.lowercased() == "https", accountBaseURL.host != nil
        else { throw V2AppConfigurationError.invalidAccountBaseURL }
        guard let passkeyRelyingPartyID = bundle.object(forInfoDictionaryKey: "IMV2PasskeyRelyingPartyID") as? String,
              !passkeyRelyingPartyID.isEmpty, !passkeyRelyingPartyID.contains("/")
        else { throw V2AppConfigurationError.invalidPasskeyRelyingPartyID }
        guard let gatewayHost = bundle.object(forInfoDictionaryKey: "IMV2GatewayHost") as? String,
              let rawGatewayPort = bundle.object(forInfoDictionaryKey: "IMV2GatewayPort"),
              let gatewayPort = UInt16(String(describing: rawGatewayPort))
        else { throw V2AppConfigurationError.invalidRealtimeEndpoint }
        self.accountBaseURL = accountBaseURL
        realtimeEndpoint = try V2RealtimeEndpoint(host: gatewayHost, port: gatewayPort)
        self.passkeyRelyingPartyID = passkeyRelyingPartyID
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
    case invalidPasskeyRelyingPartyID
    case invalidRealtimeEndpoint
    case invalidPushEnvironment
}
