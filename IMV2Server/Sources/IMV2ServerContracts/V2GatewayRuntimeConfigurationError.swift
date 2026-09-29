import Foundation

public enum V2GatewayRuntimeConfigurationError: Error, Equatable, Sendable {
    case missing(String)
    case invalid(String)
}
