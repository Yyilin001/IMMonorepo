import IMV2ServerContracts
import Foundation
import IMV2Core

/// Durable recovery candidate loaded after expired sessions have been sealed.
package struct V2ResourceRecoveryItem: Sendable {
    package let sessionID: UUID
    package let generation: Int64
    package let actorUserID: UUID
    package let deviceID: UUID
    package let request: Result<V2ResourceUploadRequest, any Error>

    package init(sessionID: UUID, generation: Int64, actorUserID: UUID, deviceID: UUID,
                 request: Result<V2ResourceUploadRequest, any Error>) {
        self.sessionID = sessionID
        self.generation = generation
        self.actorUserID = actorUserID
        self.deviceID = deviceID
        self.request = request
    }
}

package protocol V2ResourceRecoveryPersistence: Sendable {
    /// Seal expired sessions in one transaction, then read abandoned finalize attempts.
    func prepare(limit: Int) async throws -> [V2ResourceRecoveryItem]
}

/// Replays durable finalize attempts after a process crash.
public struct V2ResourceRecoveryWorker: Sendable {
    private let persistence: any V2ResourceRecoveryPersistence
    private let service: V2ResourceService

    package init(persistence: any V2ResourceRecoveryPersistence, service: V2ResourceService) {
        self.persistence = persistence
        self.service = service
    }

    public func runOnce(limit: Int = 16) async throws {
        guard (1...100).contains(limit) else { throw V2ResourceProviderError.configurationInvalid }
        let rows = try await persistence.prepare(limit: limit)
        for row in rows {
            try Task.checkCancellation()
            let request = try row.request.get()
            let actor = UserID(uuid: row.actorUserID)
            let locator = V2ResourceUploadLocator(home: request.usage.home(actorUserID: actor), sessionID: .init(uuid: row.sessionID))
            // Transient/authorization failures stay durable; expiry seals abandoned operations.
            do {
                let current = try await service.status(locator, actor: actor, device: .init(uuid: row.deviceID))
                _ = try await service.finalize(.init(locator: locator, generation: row.generation, parts: current.confirmedParts), actor: actor, device: .init(uuid: row.deviceID))
            } catch { /* Durable expiry/recovery owns the next bounded pass. */ }
        }
    }
}
