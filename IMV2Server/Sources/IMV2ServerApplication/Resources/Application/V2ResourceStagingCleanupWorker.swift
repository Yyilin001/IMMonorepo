import Foundation
import IMV2Core

package struct V2ResourceStagingCleanupClaim: Sendable {
    package let sessionID: UUID
    package let token: UUID
    package let source: Result<(request: V2ResourceUploadRequest, binding: V2StorageBinding), any Error>
    package init(sessionID: UUID, token: UUID,
                 source: Result<(request: V2ResourceUploadRequest, binding: V2StorageBinding), any Error>) {
        self.sessionID = sessionID; self.token = token; self.source = source
    }
}

package protocol V2ResourceStagingCleanupPersistence: Sendable {
    func claim(limit: Int) async throws -> [V2ResourceStagingCleanupClaim]
    func complete(_ claim: V2ResourceStagingCleanupClaim) async throws
    func retry(_ claim: V2ResourceStagingCleanupClaim) async throws
}

/// Independent of the user's session and of the scan/recovery queues. A successful
/// publication owns this cleanup until every issued upload key is durably fenced.
public struct V2ResourceStagingCleanupWorker: Sendable {
    private let persistence: any V2ResourceStagingCleanupPersistence
    private let service: V2ResourceService
    private let timeout: Duration

    package init(persistence: any V2ResourceStagingCleanupPersistence, service: V2ResourceService,
                 timeout: Duration = .seconds(120)) {
        self.persistence = persistence; self.service = service; self.timeout = timeout
    }

    public func runOnce(limit: Int = 16) async throws {
        guard (1...100).contains(limit), timeout > .zero, timeout <= .seconds(120) else { throw V2ResourceProviderError.configurationInvalid }
        // Claim one item at a time so later leases cannot expire while earlier I/O runs.
        for _ in 0..<limit {
            try Task.checkCancellation()
            guard let claim = try await persistence.claim(limit: 1).first else { break }
            do {
                let source = try claim.source.get()
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { try await service.cleanupStaging(request: source.request, binding: source.binding) }
                    group.addTask {
                        try await Task.sleep(for: timeout)
                        throw V2ResourceProviderError.temporarilyUnavailable
                    }
                    defer { group.cancelAll() }
                    _ = try await group.next()
                }
                try Task.checkCancellation()
                try await persistence.complete(claim)
            } catch is CancellationError {
                // The owned work has drained. The durable five-minute lease allows
                // a new process to recover even if cancellation also stops database I/O.
                throw CancellationError()
            } catch {
                try await persistence.retry(claim)
            }
        }
    }
}
