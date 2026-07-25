import Fluent
import Foundation
import NIOConcurrencyHelpers
import SQLKit
import Vapor

struct CrossCellRealtimeDispatchOutboxConfiguration: Sendable {
    let batchSize: Int
    let pollIntervalNanoseconds: UInt64
    let claimTimeout: TimeInterval
    let retryBaseDelay: TimeInterval
    let retryMaximumDelay: TimeInterval
    let deliveryTimeoutSeconds: Int64
    let maxConcurrentDeliveries: Int
    let metricsSnapshotInterval: TimeInterval

    static func load(from environment: Environment) -> CrossCellRealtimeDispatchOutboxConfiguration {
        let pollIntervalMilliseconds = max(
            50,
            Environment.get("IM_CROSS_CELL_REALTIME_OUTBOX_POLL_INTERVAL_MS").flatMap(Int.init(_:)) ?? 100
        )
        return CrossCellRealtimeDispatchOutboxConfiguration(
            batchSize: max(
                1,
                Environment.get("IM_CROSS_CELL_REALTIME_OUTBOX_BATCH_SIZE").flatMap(Int.init(_:)) ?? 100
            ),
            pollIntervalNanoseconds: UInt64(pollIntervalMilliseconds) * 1_000_000,
            claimTimeout: TimeInterval(max(
                5,
                Environment.get("IM_CROSS_CELL_REALTIME_OUTBOX_CLAIM_TIMEOUT_SECONDS").flatMap(Int.init(_:)) ?? 60
            )),
            retryBaseDelay: TimeInterval(max(
                100,
                Environment.get("IM_CROSS_CELL_REALTIME_OUTBOX_RETRY_BASE_MS").flatMap(Int.init(_:)) ?? 500
            )) / 1_000,
            retryMaximumDelay: TimeInterval(max(
                1_000,
                Environment.get("IM_CROSS_CELL_REALTIME_OUTBOX_RETRY_MAX_MS").flatMap(Int.init(_:)) ?? 30_000
            )) / 1_000,
            deliveryTimeoutSeconds: Int64(min(
                60,
                max(
                    1,
                    Environment.get("IM_CROSS_CELL_REALTIME_OUTBOX_DELIVERY_TIMEOUT_SECONDS").flatMap(Int.init(_:)) ?? 5
                )
            )),
            maxConcurrentDeliveries: max(
                1,
                Environment.get("IM_CROSS_CELL_REALTIME_OUTBOX_MAX_IN_FLIGHT").flatMap(Int.init(_:)) ?? 8
            ),
            metricsSnapshotInterval: TimeInterval(max(
                1,
                Environment.get("IM_CROSS_CELL_REALTIME_OUTBOX_METRICS_INTERVAL_SECONDS").flatMap(Int.init(_:)) ?? 5
            ))
        )
    }
}

/// Persists inter-Cell realtime dispatches before attempting HTTP delivery.
/// Rows are completed only after the target Cell accepts the packet. This is an
/// at-least-once transport; remote consumers must remain idempotent by event ID.
struct CrossCellRealtimeDispatchOutbox {
    let db: any Database

    @discardableResult
    func enqueueAndAttempt(
        targetCellID: String,
        envelope: NodeMessageDispatchEnvelope,
        app: Application
    ) async throws -> CrossCellRealtimeDispatch {
        let now = Date()
        let record = try CrossCellRealtimeDispatch(
            originCellID: app.imRealtimeCellID,
            targetCellID: targetCellID,
            envelope: envelope,
            now: now
        )
        if let existing = try await CrossCellRealtimeDispatch.query(on: db)
            .filter(\.$dedupeKey == record.dedupeKey)
            .first()
        {
            await app.routingMetrics.recordCrossCellDispatchOutboxDeduplicated()
            return existing
        }
        // Claim the row before saving so another worker cannot race the
        // synchronous first delivery attempt. A crashed process is recovered by
        // the lease timeout in `claimPendingBatch`.
        record.statusEnum = .processing
        record.processingStartedAt = now
        do {
            try await record.save(on: db)
        } catch {
            // The unique index is the concurrency boundary. A concurrent
            // replay may win after the preflight lookup; return its durable
            // handoff rather than generating a second realtime delivery.
            if let existing = try? await CrossCellRealtimeDispatch.query(on: db)
                .filter(\.$dedupeKey == record.dedupeKey)
                .first()
            {
                await app.routingMetrics.recordCrossCellDispatchOutboxDeduplicated()
                return existing
            }
            throw error
        }
        await app.routingMetrics.recordCrossCellDispatchOutboxEnqueued()

        do {
            try await deliver(record, app: app)
            return record
        } catch {
            // Once retry state is persisted, the caller has a durable handoff
            // and must not retry the source event just because the target Cell
            // is temporarily unavailable. Conversely, a failure to persist this
            // state is fatal: there is no durable recovery record yet.
            try await scheduleRetry(record, error: error, app: app)
            return record
        }
    }

    @discardableResult
    func processPendingBatch(
        app: Application,
        configuration: CrossCellRealtimeDispatchOutboxConfiguration? = nil
    ) async throws -> Int {
        let configuration = configuration ?? app.crossCellRealtimeDispatchOutboxConfiguration
        let records = try await claimPendingBatch(configuration: configuration)
        guard !records.isEmpty else {
            return 0
        }

        var nextIndex = records.startIndex
        var deliveredCount = 0
        await withTaskGroup(of: Bool.self) { group in
            var inFlight = 0
            func submit(_ record: CrossCellRealtimeDispatch) {
                group.addTask {
                    do {
                        try await deliver(record, app: app)
                        return true
                    } catch {
                        do {
                            try await scheduleRetry(record, error: error, app: app)
                        } catch let persistenceError {
                            app.logger.error(
                                "Cross-Cell realtime dispatch retry state update failed",
                                metadata: [
                                    "dispatch_id": .string(record.id?.uuidString ?? ""),
                                    "target_cell_id": .string(record.targetCellID),
                                    "delivery_error": .string(String(describing: error)),
                                    "persistence_error": .string(String(describing: persistenceError))
                                ]
                            )
                        }
                        return false
                    }
                }
            }

            while nextIndex < records.endIndex && inFlight < configuration.maxConcurrentDeliveries {
                submit(records[nextIndex])
                nextIndex = records.index(after: nextIndex)
                inFlight += 1
            }
            while let delivered = await group.next() {
                inFlight -= 1
                if delivered {
                    deliveredCount += 1
                }
                guard nextIndex < records.endIndex else { continue }
                submit(records[nextIndex])
                nextIndex = records.index(after: nextIndex)
                inFlight += 1
            }
        }
        return deliveredCount
    }

    private func claimPendingBatch(
        configuration: CrossCellRealtimeDispatchOutboxConfiguration
    ) async throws -> [CrossCellRealtimeDispatch] {
        let now = Date()
        let leaseExpiry = now.addingTimeInterval(-configuration.claimTimeout)
        if let sql = db as? any SQLDatabase,
           sql.dialect.name == "postgresql"
        {
            struct ClaimedRow: Decodable { let id: UUID }
            let claimed = try await sql.raw("""
                WITH \(ident: "claimed") AS (
                    SELECT \(ident: "id")
                    FROM \(ident: CrossCellRealtimeDispatch.schema)
                    WHERE (
                        (\(ident: "status") = \(bind: CrossCellRealtimeDispatchStatus.pending.rawValue)
                         AND \(ident: "next_attempt_at") <= \(bind: now))
                        OR
                        (\(ident: "status") = \(bind: CrossCellRealtimeDispatchStatus.processing.rawValue)
                         AND \(ident: "processing_started_at") <= \(bind: leaseExpiry))
                    )
                    ORDER BY \(ident: "next_attempt_at") ASC, \(ident: "created_at") ASC
                    LIMIT \(bind: configuration.batchSize)
                    FOR UPDATE SKIP LOCKED
                )
                UPDATE \(ident: CrossCellRealtimeDispatch.schema)
                SET
                    \(ident: "status") = \(bind: CrossCellRealtimeDispatchStatus.processing.rawValue),
                    \(ident: "processing_started_at") = \(bind: now),
                    \(ident: "error_message") = NULL
                WHERE \(ident: "id") IN (SELECT \(ident: "id") FROM \(ident: "claimed"))
                RETURNING \(ident: "id")
                """).all(decoding: ClaimedRow.self)
            let ids = claimed.map(\.id)
            guard !ids.isEmpty else { return [] }
            let records = try await CrossCellRealtimeDispatch.query(on: db)
                .filter(\.$id ~~ ids)
                .all()
            return records.sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
        }

        let candidates = try await CrossCellRealtimeDispatch.query(on: db)
            .group(.or) { group in
                group.group(.and) { and in
                    and.filter(\.$status == CrossCellRealtimeDispatchStatus.pending.rawValue)
                    and.filter(\.$nextAttemptAt <= now)
                }
                group.group(.and) { and in
                    and.filter(\.$status == CrossCellRealtimeDispatchStatus.processing.rawValue)
                    and.filter(\.$processingStartedAt <= leaseExpiry)
                }
            }
            .sort(\.$nextAttemptAt, .ascending)
            .sort(\.$createdAt, .ascending)
            .limit(configuration.batchSize)
            .all()
        for record in candidates {
            record.statusEnum = .processing
            record.processingStartedAt = now
            record.errorMessage = nil
            try await record.save(on: db)
        }
        return candidates
    }

    private func deliver(_ record: CrossCellRealtimeDispatch, app: Application) async throws {
        let envelope = try record.decodedEnvelope()
        guard let baseURL = try await app.cellIngressEndpointResolver.endpoint(
            for: record.targetCellID,
            purpose: .realtime
        ) else {
            throw Abort(.serviceUnavailable, reason: "No realtime ingress endpoint configured for Cell \(record.targetCellID).")
        }
        guard let sharedSecret = app.cellIngressConfiguration.sharedSecret?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sharedSecret.isEmpty
        else {
            throw Abort(.serviceUnavailable, reason: "Remote Cell realtime dispatch requires a Cell ingress secret.")
        }

        let request = IMCellRealtimeDispatchRequest(
            originCellID: record.originCellID,
            targetCellID: record.targetCellID,
            hop: 1,
            expiresAtEpochSeconds: Int(Date().timeIntervalSince1970) + 15,
            envelope: envelope
        )
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: "Content-Type", value: "application/json")
        headers.replaceOrAdd(name: "X-IM-Internal-Secret", value: sharedSecret)
        var httpRequest = ClientRequest(
            method: .POST,
            url: URI(string: "\(baseURL)/internal/im/realtime/dispatch"),
            headers: headers,
            byteBufferAllocator: app.client.byteBufferAllocator
        )
        httpRequest.timeout = .seconds(app.crossCellRealtimeDispatchOutboxConfiguration.deliveryTimeoutSeconds)
        try httpRequest.content.encode(request)
        let response = try await app.client.send(httpRequest)
        guard response.status == .noContent else {
            throw Abort(
                .badGateway,
                reason: "Remote Cell \(record.targetCellID) rejected realtime dispatch with HTTP \(response.status.code)."
            )
        }

        record.statusEnum = .delivered
        record.deliveredAt = Date()
        record.processingStartedAt = nil
        record.errorMessage = nil
        try await record.save(on: db)
        await app.routingMetrics.recordCrossCellDispatchOutboxDelivered()
    }

    private func scheduleRetry(
        _ record: CrossCellRealtimeDispatch,
        error: any Error,
        app: Application
    ) async throws {
        let configuration = app.crossCellRealtimeDispatchOutboxConfiguration
        record.retryCount += 1
        let exponent = min(record.retryCount - 1, 16)
        let delay = min(
            configuration.retryMaximumDelay,
            configuration.retryBaseDelay * pow(2, Double(exponent))
        )
        record.statusEnum = .pending
        record.nextAttemptAt = Date().addingTimeInterval(delay)
        record.processingStartedAt = nil
        record.errorMessage = String(describing: error)
        try await record.save(on: db)
        await app.routingMetrics.recordCrossCellDispatchOutboxRetry()
    }

    func recordBacklogSnapshot(app: Application) async {
        do {
            let pending = try await CrossCellRealtimeDispatch.query(on: db)
                .filter(\.$status != CrossCellRealtimeDispatchStatus.delivered.rawValue)
                .count()
            let oldest = try await CrossCellRealtimeDispatch.query(on: db)
                .filter(\.$status != CrossCellRealtimeDispatchStatus.delivered.rawValue)
                .sort(\.$createdAt, .ascending)
                .first()
                .flatMap(\.createdAt)
            let oldestAgeMilliseconds = oldest.map {
                IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(from: $0, to: Date())
            } ?? 0
            await app.routingMetrics.recordCrossCellDispatchOutboxBacklog(
                pendingCount: pending,
                oldestPendingAgeMilliseconds: oldestAgeMilliseconds
            )
        } catch {
            app.logger.warning(
                "Cross-Cell realtime dispatch outbox backlog snapshot failed",
                metadata: ["error": .string(String(describing: error))]
            )
        }
    }
}

final class CrossCellRealtimeDispatchOutboxLifecycle: LifecycleHandler, @unchecked Sendable {
    private let taskLock = NIOLock()
    private var task: Task<Void, Never>?

    func didBootAsync(_ application: Application) async throws {
        // Tests exercise the processor directly. Avoid a polling task sharing
        // the in-memory database with test assertions and shutdown handling.
        guard application.environment != .testing else {
            return
        }
        let configuration = application.crossCellRealtimeDispatchOutboxConfiguration
        taskLock.withLock {
            task = Task {
                let outbox = CrossCellRealtimeDispatchOutbox(db: application.db)
                var nextMetricsSnapshotAt = Date.distantPast
                while !Task.isCancelled {
                    do {
                        let delivered = try await outbox.processPendingBatch(
                            app: application,
                            configuration: configuration
                        )
                        if Date() >= nextMetricsSnapshotAt {
                            await outbox.recordBacklogSnapshot(app: application)
                            nextMetricsSnapshotAt = Date().addingTimeInterval(configuration.metricsSnapshotInterval)
                        }
                        if delivered == 0 {
                            try await Task.sleep(nanoseconds: configuration.pollIntervalNanoseconds)
                        }
                    } catch {
                        application.logger.warning(
                            "Cross-Cell realtime dispatch outbox iteration failed",
                            metadata: [
                                "node_id": .string(application.imNodeID),
                                "error": .string(String(describing: error))
                            ]
                        )
                        try? await Task.sleep(nanoseconds: configuration.pollIntervalNanoseconds)
                    }
                }
            }
        }
    }

    func shutdownAsync(_ application: Application) async {
        let task = taskLock.withLock { () -> Task<Void, Never>? in
            defer { self.task = nil }
            return self.task
        }
        task?.cancel()
    }
}

private struct CrossCellRealtimeDispatchOutboxConfigurationStorageKey: StorageKey {
    typealias Value = CrossCellRealtimeDispatchOutboxConfiguration
}

extension Application {
    var crossCellRealtimeDispatchOutboxConfiguration: CrossCellRealtimeDispatchOutboxConfiguration {
        get {
            if let configuration = storage[CrossCellRealtimeDispatchOutboxConfigurationStorageKey.self] {
                return configuration
            }
            let configuration = CrossCellRealtimeDispatchOutboxConfiguration.load(from: environment)
            storage[CrossCellRealtimeDispatchOutboxConfigurationStorageKey.self] = configuration
            return configuration
        }
        set {
            storage[CrossCellRealtimeDispatchOutboxConfigurationStorageKey.self] = newValue
        }
    }
}
