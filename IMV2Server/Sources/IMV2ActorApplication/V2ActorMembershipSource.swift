import IMV2ActorCluster
import Logging

/// Owns one serial certified-read/apply loop. A transport never accepts a
/// discovery observation as a membership decision. Shutdown joins actual work.
package actor V2ActorMembershipSource {
    private let load: @Sendable () async throws -> V2ActorServiceMembershipRecord
    private let install: @Sendable (V2ActorServiceMembershipRecord) async throws -> Void
    private let suspend: @Sendable () async -> Void
    private var worker: Task<Void, Never>?
    private var loading = false
    private var closed = false
    private var failed = false
    private let logger = Logger(label: "IMV2ServiceMembership")
    package init(load: @escaping @Sendable () async throws -> V2ActorServiceMembershipRecord,
                 install: @escaping @Sendable (V2ActorServiceMembershipRecord) async throws -> Void,
                 suspend: @escaping @Sendable () async -> Void) {
        self.load = load; self.install = install; self.suspend = suspend
    }
    package func start() throws {
        guard !closed, worker == nil else { throw V2RoomActorApplicationError.invalidRole }
        worker = Task { await self.run() }
    }
    package func refresh() async throws {
        guard !closed, !loading else { throw V2RoomActorApplicationError.invalidRole }
        loading = true
        defer { loading = false }
        do {
            let committed = try await load()
            guard !closed else { throw CancellationError() }
            try await install(committed)
            if failed { logger.notice("Committed membership source recovered"); failed = false }
        } catch {
            if !closed, !failed {
                await suspend()
                failed = true
                logger.error("Committed membership unavailable; service qualification suspended")
            }
            throw error
        }
    }
    private func run() async {
        defer { worker = nil }
        while !closed, !Task.isCancelled {
            do { try await refresh() } catch {}
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
        }
    }
    package func stop(deadline: ContinuousClock.Instant) async -> Bool {
        closed = true; worker?.cancel()
        while (loading || worker != nil), ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(5)) } catch { return false }
        }
        return !loading && worker == nil
    }
}
