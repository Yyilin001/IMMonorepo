import Foundation
import IMClientKit

struct AppNetworkConfiguration: Equatable {
    let apiBaseURL: URL
    let imTCPHost: String
    let imTCPPort: UInt16
    let timelineCatchUpConfiguration: ConversationRuntimeController.TimelineCatchUpConfiguration

    static let local = AppNetworkConfiguration(
        apiBaseURL: URL(string: "http://127.0.0.1:8080")!,
        imTCPHost: "127.0.0.1",
        imTCPPort: 9000,
        timelineCatchUpConfiguration: AppRuntimeTuningConfiguration.timelineCatchUpConfiguration()
    )

    static let publicGateway = AppNetworkConfiguration(
        apiBaseURL: productionAPIBaseURL(),
        imTCPHost: productionTCPHost(),
        imTCPPort: productionTCPPort(),
        timelineCatchUpConfiguration: AppRuntimeTuningConfiguration.timelineCatchUpConfiguration()
    )

    static let preview = local

    func makeNetworkEnvironment() -> NetworkEnvironment {
        NetworkEnvironment(baseURL: apiBaseURL)
    }

    func makeIMTCPConfiguration() -> IMTCPClientConfiguration {
        IMTCPClientConfiguration(
            host: imTCPHost,
            port: imTCPPort,
            deviceID: try? KeychainDeviceIdentityStore().currentDeviceID()
        )
    }

    private static func productionAPIBaseURL(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let rawValue = requiredConfigurationValue(
            environmentKey: "IM_API_BASE_URL",
            infoDictionaryKey: "IMAPIBaseURL",
            bundle: bundle,
            environment: environment,
            developmentDefault: "http://127.0.0.1:8080"
        )
        guard let url = URL(string: rawValue), url.scheme != nil, url.host != nil else {
            preconditionFailure("Invalid IM API base URL: \(rawValue)")
        }
        validateProductionAPIBaseURL(url)
        return url
    }

    private static func productionTCPHost(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let configured = configurationValue(
            environmentKey: "IM_TCP_HOST",
            infoDictionaryKey: "IMTCPHost",
            bundle: bundle,
            environment: environment
        ), !configured.isEmpty {
            validateProductionTCPHost(configured)
            return configured
        }
        guard let host = productionAPIBaseURL(bundle: bundle, environment: environment).host else {
            preconditionFailure("Missing IM TCP host")
        }
        validateProductionTCPHost(host)
        return host
    }

    private static func productionTCPPort(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> UInt16 {
        let rawValue = requiredConfigurationValue(
            environmentKey: "IM_TCP_PORT",
            infoDictionaryKey: "IMTCPPort",
            bundle: bundle,
            environment: environment,
            developmentDefault: "9000"
        )
        guard let port = UInt16(rawValue) else {
            preconditionFailure("Invalid IM TCP port: \(rawValue)")
        }
        validateProductionTCPPort(port)
        return port
    }

    private static func configurationValue(
        environmentKey: String,
        infoDictionaryKey: String,
        bundle: Bundle,
        environment: [String: String]
    ) -> String? {
        if let value = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        return (bundle.object(forInfoDictionaryKey: infoDictionaryKey) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func requiredConfigurationValue(
        environmentKey: String,
        infoDictionaryKey: String,
        bundle: Bundle,
        environment: [String: String],
        developmentDefault: String
    ) -> String {
        if let value = configurationValue(
            environmentKey: environmentKey,
            infoDictionaryKey: infoDictionaryKey,
            bundle: bundle,
            environment: environment
        ), !value.isEmpty {
            guard !value.contains("$("), !value.contains(")") else {
                preconditionFailure("Unresolved network configuration: \(infoDictionaryKey)=\(value)")
            }
            return value
        }

        #if DEBUG
        return developmentDefault
        #else
        preconditionFailure("Missing required production network configuration: \(infoDictionaryKey)")
        #endif
    }

    private static func validateProductionAPIBaseURL(_ url: URL) {
        #if !DEBUG
        guard url.scheme == "https" else {
            preconditionFailure("Production API base URL must use HTTPS: \(url.absoluteString)")
        }
        guard url.port == nil || url.port == 443 else {
            preconditionFailure("Production API base URL must use default HTTPS port 443: \(url.absoluteString)")
        }
        if let host = url.host {
            validateProductionTCPHost(host)
        }
        #endif
    }

    private static func validateProductionTCPHost(_ host: String) {
        #if !DEBUG
        let normalizedHost = host.lowercased()
        let placeholderHosts: Set<String> = ["im.example.com", "example.com", "example.net", "example.org"]
        let placeholderSuffixes = [".example.com", ".example.net", ".example.org", ".test", ".invalid", ".localhost"]
        let localHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]
        let stalePublicIPs: Set<String> = ["47.106.103.10", "120.25.106.200"]
        guard normalizedHost.contains(".") else {
            preconditionFailure("Production network host must be a real DNS name: \(host)")
        }
        guard !isIPLiteral(normalizedHost) else {
            preconditionFailure("Production network host must not be a raw IP address: \(host)")
        }
        guard !placeholderHosts.contains(normalizedHost),
              !placeholderSuffixes.contains(where: { normalizedHost.hasSuffix($0) }) else {
            preconditionFailure("Production network host must not be a placeholder: \(host)")
        }
        guard !localHosts.contains(normalizedHost) else {
            preconditionFailure("Production network host must not be local: \(host)")
        }
        guard !stalePublicIPs.contains(normalizedHost) else {
            preconditionFailure("Production network host points to a stale temporary server: \(host)")
        }
        #endif
    }

    private static func validateProductionTCPPort(_ port: UInt16) {
        #if !DEBUG
        guard port == 9000 else {
            preconditionFailure("Production IM TCP port must be 9000 to match the public gateway and cloud security group policy: \(port)")
        }
        #endif
    }

    private static func isIPLiteral(_ host: String) -> Bool {
        isIPv4Literal(host) || host.contains(":")
    }

    private static func isIPv4Literal(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else {
            return false
        }
        return parts.allSatisfy { part in
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let value = Int(part) else {
                return false
            }
            return value >= 0 && value <= 255
        }
    }
}

enum AppRuntimeTuningConfiguration {
    static let selectedHintInitialJitterMillisecondsKey = "IM_SELECTED_HINT_CATCH_UP_INITIAL_JITTER_MS"
    static let selectedHintMinimumIntervalMillisecondsKey = "IM_SELECTED_HINT_CATCH_UP_MIN_INTERVAL_MS"
    static let selectedHintMicroBatchMillisecondsKey = "IM_SELECTED_HINT_CATCH_UP_MICRO_BATCH_MS"

    static func timelineCatchUpConfiguration(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ConversationRuntimeController.TimelineCatchUpConfiguration {
        let production = ConversationRuntimeController.TimelineCatchUpConfiguration.production
        return ConversationRuntimeController.TimelineCatchUpConfiguration(
            selectedHintInitialJitterNanoseconds: nanoseconds(
                for: selectedHintInitialJitterMillisecondsKey,
                defaultValue: production.selectedHintInitialJitterNanoseconds,
                defaults: defaults,
                environment: environment
            ),
            selectedHintMinimumIntervalNanoseconds: nanoseconds(
                for: selectedHintMinimumIntervalMillisecondsKey,
                defaultValue: production.selectedHintMinimumIntervalNanoseconds,
                defaults: defaults,
                environment: environment
            ),
            selectedHintMicroBatchNanoseconds: nanoseconds(
                for: selectedHintMicroBatchMillisecondsKey,
                defaultValue: production.selectedHintMicroBatchNanoseconds,
                defaults: defaults,
                environment: environment
            )
        )
    }

    private static func nanoseconds(
        for key: String,
        defaultValue: UInt64,
        defaults: UserDefaults,
        environment: [String: String]
    ) -> UInt64 {
        if let rawValue = environment[key],
           let milliseconds = Double(rawValue),
           milliseconds >= 0 {
            return UInt64((milliseconds * 1_000_000).rounded())
        }
        if defaults.object(forKey: key) != nil {
            let defaultsValue = defaults.double(forKey: key)
            guard defaultsValue >= 0 else {
                return defaultValue
            }
            return UInt64((defaultsValue * 1_000_000).rounded())
        }
        return defaultValue
    }
}
