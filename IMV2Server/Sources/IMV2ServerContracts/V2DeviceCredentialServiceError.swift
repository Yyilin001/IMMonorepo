public enum V2DeviceCredentialServiceError: Error, Equatable, Sendable {
    case invalidRefreshCredential
    case invalidMetadata
    case invalidConfiguration
    case malformedPersistence
    case unavailable
}
