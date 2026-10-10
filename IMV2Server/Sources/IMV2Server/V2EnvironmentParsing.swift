import Foundation
import IMV2ServerContracts

/// 所有服务共享必需变量的空白处理与错误语义；各服务自行声明配置和范围限制。
func v2RequiredEnvironmentValue(_ key: String, environment: any V2RuntimeEnvironment) throws -> String {
    guard let value = environment.value(for: key)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
        throw V2GatewayRuntimeConfigurationError.missing(key)
    }
    return value
}

func v2RequiredEnvironmentInteger(_ key: String, environment: any V2RuntimeEnvironment) throws -> Int {
    let value = try v2RequiredEnvironmentValue(key, environment: environment)
    guard let result = Int(value) else { throw V2GatewayRuntimeConfigurationError.invalid(key) }
    return result
}
