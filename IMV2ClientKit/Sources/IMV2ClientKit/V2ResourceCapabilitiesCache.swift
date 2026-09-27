import Foundation
import IMV2Core

public protocol V2ResourceCapabilityReading: Sendable {
    func capabilities() async throws -> V2ResourceCapabilities
}

public enum V2ResourceCapabilityError: Error, Equatable, Sendable {
    case usageUnavailable, fileTooLarge(maximumBytes: Int64), uploadModeUnavailable
}

/// Account-owned advisory admission. Unknown/offline capabilities never prevent a
/// durable draft from being saved. The owner API remains the allocation authority.
public actor V2ResourceCapabilitiesCache {
    private let reader: any V2ResourceCapabilityReading
    private var value: V2ResourceCapabilities?
    private var validUntil: ContinuousClock.Instant?
    private var retryAfter: ContinuousClock.Instant?
    private var refreshing = false
    private var closed = false

    public init(reader: any V2ResourceCapabilityReading) { self.reader = reader }

    public func refreshIfNeeded() async throws {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        let now = ContinuousClock.now
        guard !refreshing, retryAfter.map({ $0 <= now }) ?? true,
              validUntil.map({ $0 <= now }) ?? true else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let current = try await reader.capabilities()
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            value = current; validUntil = ContinuousClock.now.advanced(by: .seconds(60)); retryAfter = nil
        } catch is CancellationError { throw CancellationError() }
        catch { retryAfter = ContinuousClock.now.advanced(by: .seconds(30)) }
    }

    public func validateNewUpload(_ request: V2ResourceUploadRequest) throws {
        guard !closed else { throw CancellationError() }
        guard let value, let validUntil, validUntil > ContinuousClock.now else { return }
        let usage: V2ResourceCapabilityUsage
        switch request.usage {
        case .messageAttachment: usage = .messageAttachment
        case .userAvatar: usage = .userAvatar
        case .groupAvatar: usage = .groupAvatar
        }
        guard value.allowedUsages.contains(usage) else { throw V2ResourceCapabilityError.usageUnavailable }
        guard request.byteCount <= value.maximumBytes else { throw V2ResourceCapabilityError.fileTooLarge(maximumBytes: value.maximumBytes) }
        guard value.uploadModes.contains(where: request.clientModes.contains) else { throw V2ResourceCapabilityError.uploadModeUnavailable }
    }

    public func close() { closed = true; value = nil; validUntil = nil }
}
