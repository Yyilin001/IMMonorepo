import IMV2Core

/// Exact discovery only; deliberately not a general profile-by-ID reader.
public protocol V2PublicIdentityPresentationResolving: Sendable {
    func resolveForPresentation(handle: String) async throws -> V2PublicIdentityLookupSnapshot
}

/// Monotonic, memory-only permission. Page exit/account replacement must clear it
/// even when this deadline has not elapsed. It cannot enter a profile repository.
public struct V2PublicIdentityLookupSnapshot: Equatable, Sendable {
    public let resolution: V2PublicIdentityResolution
    public let deadline: ContinuousClock.Instant
    public var identity: V2PublicIdentity { resolution.identity }

    public init(resolution: V2PublicIdentityResolution, requestStartedAt: ContinuousClock.Instant,
                responseReceivedAt: ContinuousClock.Instant) throws {
        let remaining = resolution.validUntilUnixMilliseconds - resolution.serverNowUnixMilliseconds
        let elapsed = requestStartedAt.duration(to: responseReceivedAt)
        guard elapsed >= .zero, elapsed < .milliseconds(remaining) else {
            throw V2PublicIdentityDirectoryClientError.invalidResponse
        }
        self.resolution = resolution
        // Subtract the complete round trip, including credential acquisition.
        deadline = responseReceivedAt.advanced(by: .milliseconds(remaining) - elapsed)
    }

    public func isValid(at now: ContinuousClock.Instant = .now) -> Bool { now < deadline }
}
