import IMV2ServerApplication
import IMV2ServerContracts
import FluentKit
import Logging
import NIOCore
import SQLKit
import Synchronization

/// 事件循环均衡数据库错误。
public enum V2EventLoopBalancedDatabaseError: Error, Equatable, Sendable {
    /// 未提供任何数据库句柄。
    case emptyDatabaseSet
    /// 提供的句柄不支持 SQL。
    case databaseDoesNotSupportSQL
    /// 各句柄的配置类型不一致。
    case inconsistentConfiguration
    /// 各句柄的 SQL 方言类型不一致。
    case inconsistentDialect
}

/// 把相互独立的数据库操作分发到每个应用事件循环各一个 Fluent 数据库句柄上。
///
/// FluentKit 会把 `Databases.database(..., on:)` 返回的数据库绑定到指定的事件循环，
/// 因此长期存活的 Store 若只持有其中一个句柄，无论配置了多少事件循环，
/// 都只会用到 `EventLoopGroupConnectionPool` 中的一个成员。该适配器恢复预期的连接池拓扑，
/// 同时让事务与单会话工作严格固定在同一个底层句柄上。
///
/// 包装器对外报告的事件循环刻意保持稳定，以满足 `Database` 与 `SQLDatabase` 的要求。
/// 无返回值的 Future 会回跳到该循环；泛型事务结果保留所选循环，避免把非 Sendable
/// 结果跨循环传递。异步调用方则可在所选操作完成后恢复。
public final class V2EventLoopBalancedDatabase: Database, SQLDatabase, Sendable, V2RoomSQLSessionDefaults {
    private struct Entry: Sendable {
        let database: any Database
        let sql: any SQLDatabase
        let gate: V2PhysicalDatabaseLoanGate?
    }

    private struct SelectedEntry: Sendable {
        let database: any Database
        let sql: any SQLDatabase
        let request: V2PhysicalDatabaseLoanRequest?
    }

    let roomSQLSessionTimeouts: V2RoomActivationSQLTimeouts?
    private let poolBorrower: V2PhysicalDatabasePoolBorrower?
    private let entries: [Entry]
    private final class Selection: Sendable { let cursor = Mutex<Int>(0) }
    private let selection: Selection
    private let loanClass: V2PhysicalDatabaseLoanClass
    private let observationSource: V2DatabaseLoanSource?

    public let context: DatabaseContext
    public let logger: Logger
    public let eventLoop: any EventLoop
    public let dialect: any SQLDialect
    public let queryLogLevel: Logger.Level?

    public var version: (any SQLDatabaseReportedVersion)? { nil }
    public var inTransaction: Bool { false }
    /// 已配置的句柄数量。
    public var configuredEventLoopCount: Int { entries.count }
    /// Available ordinary slots, including all member pools, excluding renewal reserves.
    package var ordinaryConnectionCapacity: Int? {
        guard entries.allSatisfy({ $0.gate != nil }) else { return nil }
        return entries.reduce(0) { $0 + $1.gate!.ordinaryConnectionCapacity }
    }


    /// 校验并保存各事件循环的数据库句柄。
    ///
    /// 要求所有句柄都支持 SQL、配置类型一致且方言类型一致，
    /// 以免在同一个包装器下混用语义不同的连接。
    ///
    /// - Parameter databases: 各事件循环对应的数据库句柄。
    /// - Throws: 列表为空时抛出 ``V2EventLoopBalancedDatabaseError/emptyDatabaseSet``；
    ///   句柄不支持 SQL 时抛出 ``V2EventLoopBalancedDatabaseError/databaseDoesNotSupportSQL``；
    ///   配置类型不一致时抛出 ``V2EventLoopBalancedDatabaseError/inconsistentConfiguration``；
    ///   方言不一致时抛出 ``V2EventLoopBalancedDatabaseError/inconsistentDialect``。
    public init(databases: [any Database], loanPolicy: V2PhysicalDatabaseLoanPolicy? = nil,
                sessionTimeouts: V2RoomActivationSQLTimeouts? = nil) throws {
        guard let firstDatabase = databases.first else {
            throw V2EventLoopBalancedDatabaseError.emptyDatabaseSet
        }
        let entries = try databases.map { database -> Entry in
            guard let sql = database as? any SQLDatabase else {
                throw V2EventLoopBalancedDatabaseError.databaseDoesNotSupportSQL
            }
            guard ObjectIdentifier(type(of: database.context.configuration)) ==
                    ObjectIdentifier(type(of: firstDatabase.context.configuration))
            else {
                throw V2EventLoopBalancedDatabaseError.inconsistentConfiguration
            }
            return .init(database: database, sql: sql,
                gate: loanPolicy.map { V2PhysicalDatabaseLoanGate(eventLoop: database.eventLoop, policy: $0) })
        }
        guard let firstSQL = entries.first?.sql else {
            throw V2EventLoopBalancedDatabaseError.databaseDoesNotSupportSQL
        }
        let expectedDialect = String(reflecting: type(of: firstSQL.dialect))
        guard entries.allSatisfy({
            String(reflecting: type(of: $0.sql.dialect)) == expectedDialect
        }) else {
            throw V2EventLoopBalancedDatabaseError.inconsistentDialect
        }
        self.roomSQLSessionTimeouts = sessionTimeouts
        self.entries = entries
        poolBorrower = loanPolicy == nil ? nil : V2PhysicalDatabasePoolBorrower(
            gates: entries.compactMap(\.gate), eventLoop: firstDatabase.eventLoop)
        self.selection = Selection()
        self.loanClass = .ordinary
        self.observationSource = nil
        context = firstDatabase.context
        logger = firstSQL.logger
        eventLoop = firstSQL.eventLoop
        dialect = firstSQL.dialect
        queryLogLevel = firstSQL.queryLogLevel
    }

    private init(sharing original: V2EventLoopBalancedDatabase, loanClass: V2PhysicalDatabaseLoanClass,
                 observationSource: V2DatabaseLoanSource? = nil) {
        roomSQLSessionTimeouts = original.roomSQLSessionTimeouts
        poolBorrower = original.poolBorrower
        entries = original.entries; selection = original.selection; self.loanClass = loanClass
        self.observationSource = observationSource ?? original.observationSource
        context = original.context; logger = original.logger; eventLoop = original.eventLoop
        dialect = original.dialect; queryLogLevel = original.queryLogLevel
    }

    /// The facade shares the exact physical gates and selection cursor.
    public func usingLoanClass(_ loanClass: V2PhysicalDatabaseLoanClass) -> V2EventLoopBalancedDatabase {
        .init(sharing: self, loanClass: loanClass)
    }

    /// A fixed fallback for work launched by detached collectors. Explicit
    /// caller scopes take priority; the physical gate and pool stay shared.
    public func usingObservationSource(_ source: V2DatabaseLoanSource) -> V2EventLoopBalancedDatabase {
        .init(sharing: self, loanClass: loanClass, observationSource: source)
    }

    private func loanRequest(_ gate: V2PhysicalDatabaseLoanGate, onlyIfAvailable: Bool = false) -> V2PhysicalDatabaseLoanRequest? {
        let caller = V2DatabaseLoanObservationContext.source
        let source: V2DatabaseLoanSource = caller != .other ? caller :
            observationSource ?? (loanClass == .activation ? .lifecycle : loanClass == .renewal ? .renewal : .other)
        // Capture scheduling authority on the Swift caller before any EL hop.
        // Diagnostic observation sources never grant scheduling priority.
        let selectedClass: V2PhysicalDatabaseLoanClass = loanClass == .ordinary &&
            V2PhysicalDatabaseLoanScope.purpose == .sync ? .sync : loanClass
        return V2DatabaseLoanObservationContext.$source.withValue(source) {
            if onlyIfAvailable {
                gate.requestIfAvailable(loanClass: selectedClass, deadline: V2RoomSQLDeadline.current)
            } else { gate.request(loanClass: selectedClass, deadline: V2RoomSQLDeadline.current) }
        }
    }

    public func loanMetricsSnapshot() -> V2PhysicalDatabaseLoanMetricsSnapshot {
        var result = V2PhysicalDatabaseLoanMetricsSnapshot()
        for entry in entries {
            guard let snapshot = entry.gate?.snapshot() else { continue }
            for (source, item) in snapshot.observations {
                result.observations[source, default: .init()].merge(item)
            }
            for kind in V2PhysicalDatabaseLoanClass.allCases {
                let item = snapshot.classes[kind, default: .init()]
                var combined = result.classes[kind, default: .init()]
                combined.inFlight += item.inFlight; combined.queued += item.queued
                let granted = combined.granted.addingReportingOverflow(item.granted)
                let rejected = combined.rejected.addingReportingOverflow(item.rejected)
                combined.granted = granted.overflow ? .max : granted.partialValue
                combined.rejected = rejected.overflow ? .max : rejected.partialValue
                result.classes[kind] = combined
            }
        }
        return result
    }

    public func shutdownLoans() async {
        poolBorrower?.close()
        await withTaskGroup(of: Void.self) { group in
            for entry in entries {
                if let gate = entry.gate { group.addTask { await gate.shutdown() } }
            }
            if let poolBorrower { group.addTask { await poolBorrower.waitUntilSettled() } }
        }
    }

    private func withLoan<T>(_ entry: SelectedEntry,
        _ operation: @escaping @Sendable (V2PhysicalDatabaseLoanLease?) -> EventLoopFuture<T>
    ) -> EventLoopFuture<T> {
        guard let request = entry.request else { return operation(nil) }
        // Fluent's generic result need not be Sendable. Keep its promise and
        // actual result on the selected pool's EventLoop rather than moving T
        // through flatMap's Sendable boundary or back to the facade's loop.
        let promise = entry.database.eventLoop.makePromise(of: T.self)
        request.future.whenComplete { result in
            switch result {
            case .failure(let error): promise.fail(error)
            case .success(let lease):
                let actual = operation(lease)
                precondition(actual.eventLoop === entry.database.eventLoop)
                actual.whenComplete { result in
                    // Only actual physical settlement returns the permit.
                    lease.release()
                    promise.assumeIsolated().completeWith(result)
                }
            }
        }
        return promise.futureResult
    }

    private static func requireLive(_ lease: V2PhysicalDatabaseLoanLease?) throws {
        if let lease, ContinuousClock.now >= lease.deadline { throw V2PhysicalDatabaseLoanFailure.timedOut }
    }

    /// Owner execution may defer pool selection because its result is Sendable.
    /// The original bounded waiter is retained until either its original pool
    /// or a peer supplies a real loan. Generic Fluent results keep their loop.
    package func withScheduledConnection<Value: Sendable>(deadline: ContinuousClock.Instant,
        acquisitionCancellation: V2ConnectionAcquisitionCancellation? = nil,
        _ closure: @escaping @Sendable (any Database) -> EventLoopFuture<Value>
    ) -> EventLoopFuture<Value> {
        guard let poolBorrower else { return withConnection(closure) }
        let timeline = V2OwnerConnectionTimeline.current
        let requestedAt = ContinuousClock.now
        timeline?.mark("pool_request_started", at: requestedAt)
        if let started = timeline?.marker("ticket_task_started") {
            timeline?.record(.ownerTaskToPoolRequest, from: started, to: requestedAt)
        }
        if let started = timeline?.marker("physical_borrow_entered") {
            timeline?.record(.ownerPhysicalToPoolRequest, from: started, to: requestedAt)
        }
        let caller = V2DatabaseLoanObservationContext.source
        let source = caller != .other ? caller : observationSource ??
            (loanClass == .activation ? .lifecycle : loanClass == .renewal ? .renewal : .other)
        let selectedClass: V2PhysicalDatabaseLoanClass = loanClass == .ordinary &&
            V2PhysicalDatabaseLoanScope.purpose == .sync ? .sync : loanClass
        let completion = eventLoop.makePromise(of: Value.self)
        let request = V2DatabaseLoanObservationContext.$source.withValue(source) {
            poolBorrower.request(loanClass: selectedClass, deadline: deadline, onAssignment: { [self] result in
                switch result {
                case .failure(let error): completion.fail(error)
                case .success(let assignment):
                    let callbackAt = ContinuousClock.now
                    timeline?.mark("pool_assignment_callback_entered", at: callbackAt)
                    if let assigned = timeline?.marker("pool_assignment_published") {
                        timeline?.record(.ownerPoolAssignmentCallbackWait, from: assigned, to: callbackAt)
                    }
                    let entry = entries[assignment.index], lease = assignment.lease
                    let actual: EventLoopFuture<Value> = entry.database.withConnection { borrowed in
                        let enteredAt = ContinuousClock.now
                        timeline?.mark("driver_entered", at: enteredAt)
                        timeline?.record(.ownerPoolToDriverWait, from: callbackAt, to: enteredAt)
                        lease.observation.driverEntered()
                        do { try Self.requireLive(lease) }
                        catch { return borrowed.eventLoop.makeFailedFuture(error) }
                        return closure(v2ObserveBorrowedDatabase(borrowed, observation: lease.observation,
                            sessionTimeouts: self.roomSQLSessionTimeouts))
                    }
                    actual.whenComplete { result in
                        lease.release()
                        timeline?.mark("pool_returned")
                        // Only the terminal Sendable result crosses the facade.
                        // Connection assignment and SQL never wait on that loop.
                        completion.completeWith(result)
                    }
                }
            })
        }
        acquisitionCancellation?.install(request.cancel)
        return completion.futureResult
    }

    public func execute(query: DatabaseQuery,
        onOutput: @escaping @Sendable (any DatabaseOutput) -> Void
    ) -> EventLoopFuture<Void> {
        let entry = nextEntry()
        return withLoan(entry) { lease in
            entry.database.withConnection { borrowed in
                lease?.observation.driverEntered()
                do { try Self.requireLive(lease) }
                catch { return borrowed.eventLoop.makeFailedFuture(error) }
                return v2ObserveBorrowedDatabase(borrowed, observation: lease?.observation, sessionTimeouts: self.roomSQLSessionTimeouts).execute(query: query, onOutput: onOutput)
            }
        }.hop(to: eventLoop)
    }

    public func execute(schema: DatabaseSchema) -> EventLoopFuture<Void> {
        let entry = nextEntry()
        return withLoan(entry) { lease in
            entry.database.withConnection { borrowed in
                lease?.observation.driverEntered()
                do { try Self.requireLive(lease) }
                catch { return borrowed.eventLoop.makeFailedFuture(error) }
                return v2ObserveBorrowedDatabase(borrowed, observation: lease?.observation, sessionTimeouts: self.roomSQLSessionTimeouts).execute(schema: schema)
            }
        }.hop(to: eventLoop)
    }

    public func execute(enum databaseEnum: DatabaseEnum) -> EventLoopFuture<Void> {
        let entry = nextEntry()
        return withLoan(entry) { lease in
            entry.database.withConnection { borrowed in
                lease?.observation.driverEntered()
                do { try Self.requireLive(lease) }
                catch { return borrowed.eventLoop.makeFailedFuture(error) }
                return v2ObserveBorrowedDatabase(borrowed, observation: lease?.observation, sessionTimeouts: self.roomSQLSessionTimeouts).execute(enum: databaseEnum)
            }
        }.hop(to: eventLoop)
    }

    public func transaction<T>(
        _ closure: @escaping @Sendable (any Database) -> EventLoopFuture<T>
    ) -> EventLoopFuture<T> {
        let entry = nextEntry()
        return withLoan(entry) { lease in
            entry.database.transaction { borrowed in
                lease?.observation.driverEntered()
                do { try Self.requireLive(lease) }
                catch { return borrowed.eventLoop.makeFailedFuture(error) }
                return closure(v2ObserveBorrowedDatabase(borrowed, observation: lease?.observation, sessionTimeouts: self.roomSQLSessionTimeouts))
            }
        }
    }

    public func withConnection<T>(
        _ closure: @escaping @Sendable (any Database) -> EventLoopFuture<T>
    ) -> EventLoopFuture<T> {
        let entry = nextEntry()
        return withLoan(entry) { lease in
            entry.database.withConnection { borrowed in
                lease?.observation.driverEntered()
                do { try Self.requireLive(lease) }
                catch { return borrowed.eventLoop.makeFailedFuture(error) }
                // Bottom-level borrowed handles never re-enter this facade.
                return closure(v2ObserveBorrowedDatabase(borrowed, observation: lease?.observation, sessionTimeouts: self.roomSQLSessionTimeouts))
            }
        }
    }

    public func execute(sql query: any SQLExpression,
        _ onRow: @escaping @Sendable (any SQLRow) -> Void
    ) -> EventLoopFuture<Void> {
        let entry = nextEntry()
        return withLoan(entry) { lease in
            entry.database.withConnection { borrowed in
                lease?.observation.driverEntered()
                do {
                    try Self.requireLive(lease)
                    guard let sql = v2ObserveBorrowedDatabase(borrowed, observation: lease?.observation, sessionTimeouts: self.roomSQLSessionTimeouts) as? any SQLDatabase else { throw V2EventLoopBalancedDatabaseError.databaseDoesNotSupportSQL }
                    return sql.execute(sql: query, onRow)
                } catch { return borrowed.eventLoop.makeFailedFuture(error) }
            }
        }.hop(to: eventLoop)
    }

    public func execute(sql query: any SQLExpression,
        _ onRow: @escaping @Sendable (any SQLRow) -> Void
    ) async throws {
        let entry = nextEntry()
        guard let request = entry.request else { return try await entry.sql.execute(sql: query, onRow) }
        try await withTaskCancellationHandler {
            let lease = try await request.future.get()
            if Task.isCancelled { lease.release(); throw V2PhysicalDatabaseLoanFailure.cancelled }
            let actual = entry.database.withConnection { borrowed in
                lease.observation.driverEntered()
                do {
                    try Self.requireLive(lease)
                    guard let sql = v2ObserveBorrowedDatabase(borrowed, observation: lease.observation, sessionTimeouts: self.roomSQLSessionTimeouts) as? any SQLDatabase else { throw V2EventLoopBalancedDatabaseError.databaseDoesNotSupportSQL }
                    return sql.execute(sql: query, onRow)
                } catch { return borrowed.eventLoop.makeFailedFuture(error) }
            }
            actual.whenComplete { _ in lease.release() }
            try await actual.get()
        } onCancel: { request.cancel() }
    }

    public func withSession<R>(
        _ closure: @escaping @Sendable (any SQLDatabase) async throws -> R
    ) async throws -> R {
        let entry = nextEntry()
        guard let request = entry.request else { return try await entry.sql.withSession(closure) }
        return try await withTaskCancellationHandler {
            let lease = try await request.future.get()
            if Task.isCancelled { lease.release(); throw V2PhysicalDatabaseLoanFailure.cancelled }
            // R is not constrained to Sendable by SQLKit's protocol. Run the
            // caller closure directly; only the borrowed SQL handle and Void
            // settlement futures cross the async/future handshake.
            let available = entry.database.eventLoop.makePromise(of: (any SQLDatabase).self)
            let finished = entry.database.eventLoop.makePromise(of: Void.self)
            let sessionFinished = Mutex(false)
            let finish: @Sendable (Result<Void, any Error>) -> Void = { result in
                let first = sessionFinished.withLock { flag in
                    guard !flag else { return false }; flag = true; return true
                }
                if first { finished.completeWith(result) }
            }
            let signalled = Mutex(false)
            let signal: @Sendable (Result<any SQLDatabase, any Error>) -> Void = { result in
                let first = signalled.withLock { flag in
                    guard !flag else { return false }; flag = true; return true
                }
                if first { available.completeWith(result) }
            }
            let actual = entry.database.withConnection { borrowed in
                lease.observation.driverEntered()
                do {
                    try Self.requireLive(lease)
                    guard let sql = v2ObserveBorrowedDatabase(borrowed, observation: lease.observation, sessionTimeouts: self.roomSQLSessionTimeouts) as? any SQLDatabase else { throw V2EventLoopBalancedDatabaseError.databaseDoesNotSupportSQL }
                    signal(.success(sql))
                    return finished.futureResult
                } catch {
                    finish(.failure(error))
                    signal(.failure(error))
                    return borrowed.eventLoop.makeFailedFuture(error)
                }
            }
            actual.whenComplete { result in
                // A physical acquisition may fail before its closure runs.
                // Complete both handshake promises, including the unused
                // finished promise, without racing the caller's completion.
                finish(result)
                if case .failure(let error) = result { signal(.failure(error)) }
                lease.release()
            }
            do {
                let sql = try await available.futureResult.get()
                try Task.checkCancellation()
                let value = try await closure(sql)
                finish(.success(()))
                try await actual.get()
                return value
            } catch {
                // Finish once: errors after successful session completion must
                // not fail the already completed physical borrow promise.
                finish(.failure(error))
                _ = try? await actual.get()
                throw error
            }
        } onCancel: { request.cancel() }
    }

    /// Prefer a pool whose existing gate can grant immediately, preserving
    /// round-robin choice among available pools. Selection and the capacity
    /// claim share this facade's cursor lock, including all class/source views.
    /// If every pool is busy, register once on the normal round-robin pool.
    private func nextEntry() -> SelectedEntry {
        selection.cursor.withLock { index in
            for offset in 0..<entries.count {
                let candidate = (index + offset) % entries.count
                let entry = entries[candidate]
                if let gate = entry.gate {
                    guard let request = loanRequest(gate, onlyIfAvailable: true) else { continue }
                    index = (candidate + 1) % entries.count
                    return .init(database: entry.database, sql: entry.sql, request: request)
                }
                index = (candidate + 1) % entries.count
                return .init(database: entry.database, sql: entry.sql, request: nil)
            }
            let entry = entries[index]
            index = (index + 1) % entries.count
            return .init(database: entry.database, sql: entry.sql,
                request: entry.gate.flatMap { loanRequest($0) })
        }
    }
}
