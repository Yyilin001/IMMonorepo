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
        apiBaseURL: URL(string: "http://120.25.106.200:8080")!,
        imTCPHost: "120.25.106.200",
        imTCPPort: 9000,
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
