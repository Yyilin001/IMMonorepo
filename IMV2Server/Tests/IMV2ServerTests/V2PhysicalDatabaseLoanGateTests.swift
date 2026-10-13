import FluentKit
import FluentPostgresDriver
import Foundation
import IMV2ServerInfrastructure
import NIOCore
import SQLKit
import Synchronization
import Testing

@Suite("Physical database loan ownership")
struct V2PhysicalDatabaseLoanGateTests {
    @Test("idle renewal capacity serves ordinary work and queued renewal takes the next returned slot")
    func elasticRenewalCapacity() async throws {
        let resources = makeV2DatabaseTestResources()
        let gate = V2PhysicalDatabaseLoanGate(eventLoop: resources.eventLoopGroup.next(), policy: try .init(
            maximumConnections: 4, reservedRenewalConnections: 2,
            maximumQueued: 4, maximumWait: .seconds(5), lendsIdleRenewalConnections: true))
        var held: [V2PhysicalDatabaseLoanLease] = []
        for _ in 0..<4 { held.append(try await gate.acquire(loanClass: .ordinary).get()) }
        let ordinary = gate.request(loanClass: .ordinary)
        let renewal = gate.request(loanClass: .renewal)
        #expect(gate.snapshot().classes[.ordinary]?.inFlight == 4)
        held.removeLast().release()
        let renewed = try await renewal.future.get()
        #expect(gate.snapshot().classes[.ordinary]?.queued == 1)
        #expect(gate.snapshot().classes[.renewal]?.inFlight == 1)
        renewed.release()
        let next = try await ordinary.future.get()
        #expect(gate.snapshot().classes[.ordinary]?.inFlight == 4)
        next.release()
        for lease in held { lease.release() }
        await gate.shutdown()
        try await resources.shutdown()
    }
    @Test("queued Sendable room borrowing follows a peer capacity return while the original pool remains held",
          arguments: V2PhysicalDatabaseLoanClass.allCases, [false, true])
    func queuedRoomBorrowFollowsPeer(loanClass: V2PhysicalDatabaseLoanClass, releaseBoth: Bool) async throws {
        let resources = makeV2DatabaseTestResources(eventLoopThreads: 2)
        resources.databases.use(try .postgres(url: "postgres://imv2:unused@127.0.0.1:1/imv2"), as: .psql, isDefault: true)
        let loops = Array(resources.eventLoopGroup.makeIterator())
        #expect(loops.count == 2 && loops[0] !== loops[1])
        let bases = try loops.map {
            try #require(resources.databases.database(.psql, logger: resources.logger, on: $0))
        }
        let base = bases[0]
        let dialect = try #require((base as? any SQLDatabase)?.dialect)
        let probes = [ControlledLoanProbe(), ControlledLoanProbe()]
        let pools = bases.indices.map { ControlledLoanDatabase(context: bases[$0].context,
            dialect: dialect, probe: probes[$0]) }
        let database = try V2EventLoopBalancedDatabase(databases: pools, loanPolicy: .init(
            maximumConnections: 2, reservedRenewalConnections: 1,
            maximumQueued: 1, maximumWait: .seconds(5))).usingLoanClass(loanClass)
        let held = loops.map { ControlledLoanWork(loop: $0) }
        let futures = held.indices.map { index in
            database.withConnection { borrowed in held[index].begin().hop(to: borrowed.eventLoop) }
        }
        let next = ControlledLoanWork(loop: base.eventLoop)
        let dispatchCount = Mutex(0)
        var nextFuture: EventLoopFuture<Void>?
        do {
            for work in held { try await work.entered.futureResult.get() }
            let future = database.withScheduledConnection(deadline: .now + .seconds(3)) { borrowed in
                dispatchCount.withLock { $0 += 1 }
                return next.begin().hop(to: borrowed.eventLoop)
            }
            #expect(future.eventLoop === database.eventLoop)
            nextFuture = future
            future.whenFailure { next.failBeforeEntry($0) }
            #expect(database.loanMetricsSnapshot().classes[loanClass]?.queued == 1)
            // The shared borrower's initial ticket waits at pool 0. Returning
            // only pool 1 must dispatch it, with no release from held[0].
            if releaseBoth {
                await withTaskGroup(of: Void.self) { group in
                    for work in held { group.addTask { work.finish() } }
                }
                for future in futures { try await future.get() }
            } else {
                held[1].finish()
                try await futures[1].get()
            }
            try await next.entered.futureResult.get()
            #expect(dispatchCount.withLock { $0 } == 1)
            if releaseBoth {
                #expect(probes.reduce(0) { $0 + $1.snapshot().borrowed } == 3)
                #expect(probes.reduce(0) { $0 + $1.snapshot().inFlight } == 1)
            } else {
                #expect(probes[0].snapshot().inFlight == 1)
                #expect(probes[0].snapshot().borrowed == 1)
                #expect(probes[1].snapshot().borrowed == 2)
                #expect(probes[1].snapshot().inFlight == 1)
            }
            #expect(database.loanMetricsSnapshot().classes[loanClass]?.queued == 0)
            #expect(database.loanMetricsSnapshot().classes[loanClass]?.rejected == 0)
            #expect(probes.allSatisfy { $0.snapshot().peak == 1 })
            held[0].finish(); next.finish()
            try await futures[0].get(); try await future.get()
            await database.shutdownLoans()
            #expect(database.loanMetricsSnapshot().classes[loanClass]?.inFlight == 0)
            #expect(dispatchCount.withLock { $0 } == 1)
            try await resources.shutdown()
        } catch {
            for work in held { work.finish() }
            next.finish()
            for future in futures { _ = try? await future.get() }
            if let nextFuture { _ = try? await nextFuture.get() }
            await database.shutdownLoans()
            try await resources.shutdown()
            throw error
        }
    }

    @Test("pool selection skips an occupied pool while another has capacity without increasing loans",
          arguments: V2PhysicalDatabaseLoanClass.allCases)
    func availablePoolSelection(loanClass: V2PhysicalDatabaseLoanClass) async throws {
        let resources = makeV2DatabaseTestResources()
        resources.databases.use(try .postgres(url: "postgres://imv2:unused@127.0.0.1:1/imv2"), as: .psql, isDefault: true)
        let base = resources.database(.psql)
        let dialect = try #require((base as? any SQLDatabase)?.dialect)
        let probes = [ControlledLoanProbe(), ControlledLoanProbe()]
        let pools = probes.map { ControlledLoanDatabase(context: base.context, dialect: dialect, probe: $0) }
        let database = try V2EventLoopBalancedDatabase(databases: pools, loanPolicy: .init(
            maximumConnections: 2, reservedRenewalConnections: 1,
            maximumQueued: 0, maximumWait: .seconds(5))).usingLoanClass(loanClass)
        let first = ControlledLoanWork(loop: base.eventLoop)
        let third = ControlledLoanWork(loop: base.eventLoop)
        let firstFuture = database.withConnection { _ in first.begin() }
        firstFuture.whenFailure { first.failBeforeEntry($0) }
        var thirdFuture: EventLoopFuture<Void>?
        do {
            try await first.entered.futureResult.get()
            // Advance the shared rotation through pool 1, then return its loan.
            try await database.withConnection { $0.eventLoop.makeSucceededVoidFuture() }.get()
            #expect(probes[0].snapshot().inFlight == 1)
            #expect(probes[1].snapshot().inFlight == 0)
            let future = database.withConnection { _ in third.begin() }
            thirdFuture = future
            future.whenFailure { third.failBeforeEntry($0) }
            try await third.entered.futureResult.get()
            #expect(probes[0].snapshot().borrowed == 1)
            #expect(probes[1].snapshot().borrowed == 2)
            #expect(database.loanMetricsSnapshot().classes[loanClass]?.inFlight == 2)
            // Both pools are now full for this class: no third permit appears.
            do {
                try await database.withConnection { $0.eventLoop.makeSucceededVoidFuture() }.get()
                Issue.record("all occupied pools must retain the original capacity limit")
            } catch { #expect(error as? V2PhysicalDatabaseLoanFailure == .queueFull) }
            #expect(probes.allSatisfy { $0.snapshot().peak == 1 })
            first.finish(); third.finish()
            try await firstFuture.get(); try await future.get()
            await database.shutdownLoans()
            #expect(database.loanMetricsSnapshot().classes[loanClass]?.inFlight == 0)
            try await resources.shutdown()
        } catch {
            first.finish(); third.finish()
            _ = try? await firstFuture.get()
            if let thirdFuture { _ = try? await thirdFuture.get() }
            await database.shutdownLoans()
            try await resources.shutdown()
            throw error
        }
    }

    @Test("fixed loan source follows queued cancellation, concurrent SQL and actual late return")
    func loanObservationFollowsActualFuture() async throws {
        let resources = makeV2DatabaseTestResources()
        let loop = resources.eventLoopGroup.next()
        let gate = V2PhysicalDatabaseLoanGate(eventLoop: loop, policy: try .init(
            maximumConnections: 1, reservedRenewalConnections: 0,
            maximumQueued: 2, maximumWait: .seconds(5)))
        let request = V2DatabaseLoanObservationContext.$source.withValue(.durableOwner) {
            gate.request(loanClass: .ordinary)
        }
        let lease = try await request.future.get()
        let queued = V2DatabaseLoanObservationContext.$source.withValue(.presence) {
            gate.request(loanClass: .ordinary)
        }
        let steps = (0..<4).map { _ in loop.makePromise(of: Void.self) }
        let completedSteps = Mutex<Set<Int>>([])
        @Sendable func releaseStep(_ index: Int) {
            if completedSteps.withLock({ $0.insert(index).inserted }) { steps[index].succeed(()) }
        }
        let entered = loop.makePromise(of: Void.self)
        let firstSQLFinished = loop.makePromise(of: Void.self)
        let returned = loop.makePromise(of: Void.self)
        let actual = steps[0].futureResult.flatMap { () -> EventLoopFuture<Void> in
            lease.observation.driverEntered()
            lease.observation.setSQLPhase(.fence)
            let fenceSQL = lease.observation.startSQL()
            lease.observation.setSQLPhase(.other)
            let bodySQL = lease.observation.startSQL(phase: .readBody)
            lease.observation.setSQLPhase(.transactionControl) // Does not relabel existing tokens.
            steps[1].futureResult.whenComplete { _ in
                lease.observation.finishSQL(fenceSQL)
                lease.observation.finishSQL(fenceSQL) // Same actual callback may be observed twice.
                firstSQLFinished.succeed(())
            }
            steps[2].futureResult.whenComplete { _ in
                lease.observation.finishSQL(bodySQL)
                lease.observation.finishSQL(bodySQL)
            }
            entered.succeed(())
            return steps[1].futureResult.and(steps[2].futureResult).flatMap { _ in steps[3].futureResult }
        }
        actual.whenComplete { _ in lease.release(); returned.succeed(()) }
        let caller = Task { try await actual.get() }
        do {
            #expect(lease.observation.source == .durableOwner)
            #expect(gate.snapshot().observations[.durableOwner]?.stages[.awaitingDriver]?.active == 1)
            #expect(gate.snapshot().observations[.presence]?.stages[.gateQueued]?.active == 1)
            queued.cancel()
            do { _ = try await queued.future.get(); Issue.record("queued cancellation must fail") }
            catch { #expect(error as? V2PhysicalDatabaseLoanFailure == .cancelled) }
            #expect(gate.snapshot().observations[.presence]?.actualHeldCount == 0)
            #expect(gate.snapshot().observations[.presence]?.stages[.gateQueued]?.count == 1)
            #expect(gate.snapshot().observations[.presence]?.stages.values.reduce(0) { $0 + $1.active } == 0)
            // Changing the caller source cannot relabel the captured lease.
            V2DatabaseLoanObservationContext.$source.withValue(.maintenance) { releaseStep(0) }
            try await entered.futureResult.get()
            #expect(gate.snapshot().observations[.durableOwner]?.stages[.sql]?.active == 1)
            #expect(gate.snapshot().observations[.durableOwner]?.stages[.awaitingDriver]?.count == 1)
            releaseStep(1)
            try await firstSQLFinished.futureResult.get()
            #expect(gate.snapshot().observations[.durableOwner]?.stages[.sql]?.active == 1)
            #expect(gate.snapshot().observations[.durableOwner]?.stages[.sql]?.count == 0)
            #expect(gate.snapshot().observations[.durableOwner]?.sqlPhases[.fence]?.count == 1)
            #expect(gate.snapshot().observations[.durableOwner]?.sqlPhases[.readBody]?.count == 0)
            releaseStep(2)
            // FIFO EL barrier observes both SQL callbacks before sampling.
            try await loop.submit { () }.get()
            #expect(gate.snapshot().observations[.durableOwner]?.stages[.betweenSQL]?.active == 1)
            #expect(gate.snapshot().observations[.durableOwner]?.stages[.sql]?.count == 1)
            caller.cancel()
            request.cancel() // An actual granted loan remains owned.
            #expect(gate.snapshot().classes[.ordinary]?.inFlight == 1)
            #expect(gate.snapshot().observations[.durableOwner]?.actualHeldCount == 0)
            releaseStep(3)
            try await caller.value
            try await returned.futureResult.get()
            lease.release() // Idempotent terminal accounting.
            let final = try #require(gate.snapshot().observations[.durableOwner])
            #expect(final.actualHeldCount == 1)
            #expect(final.sqlPhases[.fence]?.count == 1)
            #expect(final.sqlPhases[.readBody]?.count == 1)
            #expect(final.sqlPhases[.other]?.count == 0)
            #expect(final.sqlPhases[.transactionControl]?.count == 0)
            for phase in [V2DatabaseLoanSQLPhase.fence, .readBody] {
                let timing = try #require(final.sqlPhases[phase])
                #expect(timing.totalMilliseconds >= 0)
                #expect(timing.maxMilliseconds == timing.totalMilliseconds)
            }
            #expect(final.actualHeldTotalMilliseconds >= final.stages[.sql, default: .init()].totalMilliseconds)
            #expect(final.stages.values.allSatisfy { $0.active == 0 })
            #expect(final.stages[.settled]?.active == 0)
            #expect(gate.snapshot().observations[.maintenance]?.actualHeldCount == 0)
            #expect(gate.snapshot().classes[.ordinary]?.inFlight == 0)
            await gate.shutdown()
            try await resources.shutdown()
        } catch {
            queued.cancel()
            for index in steps.indices { releaseStep(index) }
            _ = try? await caller.value
            _ = try? await returned.futureResult.get()
            lease.release()
            await gate.shutdown()
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("nine ordinary borrows leave two real renewal slots and ordinary waiters keep FIFO")
    func physicalBorrowsPreserveRenewalCapacityAndFIFO() async throws {
        let resources = makeV2DatabaseTestResources()
        resources.databases.use(try .postgres(url: "postgres://imv2:unused@127.0.0.1:1/imv2"), as: .psql, isDefault: true)
        let base = resources.database(.psql)
        let probe = ControlledLoanProbe()
        let controlled = ControlledLoanDatabase(context: base.context,
            dialect: try #require((base as? any SQLDatabase)?.dialect), probe: probe)
        let database = try V2EventLoopBalancedDatabase(databases: [controlled], loanPolicy: .init(
            maximumConnections: 11, reservedRenewalConnections: 2,
            maximumQueued: 16, maximumWait: .seconds(5)))
        let renewal = database.usingLoanClass(.renewal)
        let work = (0..<13).map { _ in ControlledLoanWork(loop: base.eventLoop) }
        let starts = Mutex<[Int]>([])
        var futures: [EventLoopFuture<Void>] = []
        for index in 0..<11 {
            futures.append(database.withConnection { _ in
                starts.withLock { $0.append(index) }
                return work[index].begin()
            })
        }
        for index in 11..<13 {
            futures.append(renewal.withConnection { _ in work[index].begin() })
        }
        for (index, future) in futures.enumerated() {
            future.whenFailure { work[index].failBeforeEntry($0) }
        }
        do {
            for index in Array(0..<9) + Array(11..<13) { try await work[index].entered.futureResult.get() }
            #expect(probe.snapshot().inFlight == 11)
            #expect(probe.snapshot().peak == 11)
            #expect(database.loanMetricsSnapshot().classes[.ordinary]?.inFlight == 9)
            #expect(database.loanMetricsSnapshot().classes[.ordinary]?.queued == 2)
            #expect(database.loanMetricsSnapshot().classes[.renewal]?.inFlight == 2)
            work[0].finish()
            try await work[9].entered.futureResult.get()
            #expect(!work[10].hasEntered)
            #expect(database.loanMetricsSnapshot().classes[.ordinary]?.queued == 1)
            work[1].finish()
            try await work[10].entered.futureResult.get()
            #expect(starts.withLock { $0.filter { $0 >= 9 } } == [9, 10])
            for item in work { item.finish() }
            for future in futures { try await future.get() }
            await database.shutdownLoans()
            #expect(probe.snapshot().inFlight == 0)
            #expect(probe.snapshot().borrowed == 13)
            #expect(probe.snapshot().peak == 11)
            try await resources.shutdown()
        } catch {
            for item in work { item.finish() }
            for future in futures { _ = try? await future.get() }
            await database.shutdownLoans()
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("real shared borrows alternate Sync and general FIFO without new capacity")
    func syncBorrowsShareCapacityAndAlternateFIFO() async throws {
        let resources = makeV2DatabaseTestResources()
        resources.databases.use(try .postgres(url: "postgres://imv2:unused@127.0.0.1:1/imv2"), as: .psql, isDefault: true)
        let base = resources.database(.psql)
        let probe = ControlledLoanProbe()
        let controlled = ControlledLoanDatabase(context: base.context,
            dialect: try #require((base as? any SQLDatabase)?.dialect), probe: probe)
        let database = try V2EventLoopBalancedDatabase(databases: [controlled], loanPolicy: .init(
            maximumConnections: 11, reservedRenewalConnections: 2,
            maximumQueued: 16, maximumWait: .seconds(5)))
        let work = (0..<15).map { _ in ControlledLoanWork(loop: base.eventLoop) }
        let starts = Mutex<[Int]>([])
        var futures: [EventLoopFuture<Void>] = []
        // A late ordinary arrival (10) cannot bypass already queued Sync (11).
        for index in Array(0..<10) + [11, 10, 12, 13, 14] {
            let submit = { @Sendable () -> EventLoopFuture<Void> in
                let facade = index >= 13 ? database.usingLoanClass(.renewal) : database
                return facade.withConnection { _ in
                    starts.withLock { $0.append(index) }
                    return work[index].begin()
                }
            }
            // Purpose must be captured now, not when the eventual EL closure runs.
            let future = index == 11 || index == 12
                ? V2PhysicalDatabaseLoanScope.$purpose.withValue(.sync, operation: submit) : submit()
            future.whenFailure { work[index].failBeforeEntry($0) }
            futures.append(future)
        }
        do {
            for index in Array(0..<9) + [13, 14] { try await work[index].entered.futureResult.get() }
            #expect(probe.snapshot().inFlight == 11)
            #expect(database.loanMetricsSnapshot().classes[.ordinary]?.queued == 2)
            #expect(database.loanMetricsSnapshot().classes[.sync]?.queued == 2)
            for (held, next) in [(0, 11), (1, 9), (2, 12), (3, 10)] {
                work[held].finish()
                try await work[next].entered.futureResult.get()
                let snapshot = database.loanMetricsSnapshot()
                #expect(snapshot.classes.values.reduce(0) { $0 + $1.inFlight } == 11)
            }
            #expect(starts.withLock { $0.filter { (9...12).contains($0) } } == [11, 9, 12, 10])
            for item in work { item.finish() }
            for future in futures { try await future.get() }
            await database.shutdownLoans()
            #expect(probe.snapshot().inFlight == 0 && probe.snapshot().peak == 11)
            try await resources.shutdown()
        } catch {
            for item in work { item.finish() }
            for future in futures { _ = try? await future.get() }
            await database.shutdownLoans()
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("two cold borrows leave seven hot and two renewal slots while cold waiters keep FIFO")
    func activationBorrowsPreserveHotCapacityAndFIFO() async throws {
        let resources = makeV2DatabaseTestResources()
        resources.databases.use(try .postgres(url: "postgres://imv2:unused@127.0.0.1:1/imv2"), as: .psql, isDefault: true)
        let base = resources.database(.psql)
        let probe = ControlledLoanProbe()
        let controlled = ControlledLoanDatabase(context: base.context,
            dialect: try #require((base as? any SQLDatabase)?.dialect), probe: probe)
        let database = try V2EventLoopBalancedDatabase(databases: [controlled], loanPolicy: .init(
            maximumConnections: 11, reservedRenewalConnections: 2,
            maximumQueued: 16, maximumWait: .seconds(5)))
        let renewal = database.usingLoanClass(.renewal)
        let activation = database.usingLoanClass(.activation)
        let work = (0..<13).map { _ in ControlledLoanWork(loop: base.eventLoop) }
        let starts = Mutex<[Int]>([])
        var futures: [EventLoopFuture<Void>] = []
        for index in 0..<11 {
            futures.append((index < 4 ? activation : database).withConnection { _ in
                starts.withLock { $0.append(index) }
                return work[index].begin()
            })
        }
        for index in 11..<13 {
            futures.append(renewal.withConnection { _ in work[index].begin() })
        }
        for (index, future) in futures.enumerated() {
            future.whenFailure { work[index].failBeforeEntry($0) }
        }
        do {
            for index in [0, 1] + Array(4..<13) { try await work[index].entered.futureResult.get() }
            #expect(probe.snapshot().inFlight == 11)
            #expect(probe.snapshot().peak == 11)
            #expect(database.loanMetricsSnapshot().classes[.ordinary]?.inFlight == 7)
            #expect(database.loanMetricsSnapshot().classes[.activation]?.queued == 2)
            #expect(database.loanMetricsSnapshot().classes[.renewal]?.inFlight == 2)
            #expect(database.loanMetricsSnapshot().classes[.activation]?.inFlight == 2)
            work[0].finish()
            try await work[2].entered.futureResult.get()
            #expect(!work[3].hasEntered)
            #expect(database.loanMetricsSnapshot().classes[.activation]?.queued == 1)
            work[1].finish()
            try await work[3].entered.futureResult.get()
            #expect(starts.withLock { $0.filter { $0 < 4 } } == [0, 1, 2, 3])
            for item in work { item.finish() }
            for future in futures { try await future.get() }
            await database.shutdownLoans()
            #expect(probe.snapshot().inFlight == 0)
            #expect(probe.snapshot().borrowed == 13)
            #expect(probe.snapshot().peak == 11)
            try await resources.shutdown()
        } catch {
            for item in work { item.finish() }
            for future in futures { _ = try? await future.get() }
            await database.shutdownLoans()
            try? await resources.shutdown()
            throw error
        }
    }

    @Test("borrowed nested work keeps one physical slot until actual completion and every shutdown drains",
          arguments: [V2PhysicalDatabaseLoanClass.ordinary, .activation, .sync])
    func nestedBorrowAndSubmittedCancellationKeepActualOwnership(loanClass: V2PhysicalDatabaseLoanClass) async throws {
        let resources = makeV2DatabaseTestResources()
        resources.databases.use(try .postgres(url: "postgres://imv2:unused@127.0.0.1:1/imv2"), as: .psql, isDefault: true)
        let base = resources.database(.psql)
        let probe = ControlledLoanProbe()
        let controlled = ControlledLoanDatabase(context: base.context,
            dialect: try #require((base as? any SQLDatabase)?.dialect), probe: probe)
        let database = try V2EventLoopBalancedDatabase(databases: [controlled], loanPolicy: .init(
            maximumConnections: 2, reservedRenewalConnections: 1,
            maximumQueued: 4, maximumWait: .seconds(5)))
        let work = ControlledLoanWork(loop: base.eventLoop)
        let future: EventLoopFuture<Void> = database.usingLoanClass(loanClass).withConnection { borrowed -> EventLoopFuture<Void> in
            borrowed.transaction { transaction -> EventLoopFuture<Void> in
                transaction.withConnection { nested -> EventLoopFuture<Void> in
                    guard let sql = nested as? any SQLDatabase else {
                        return nested.eventLoop.makeFailedFuture(ControlledLoanFailure.unsupported)
                    }
                    return sql.execute(sql: SQLRaw("SELECT 1"), { _ in }).flatMap {
                        return work.begin()
                    }
                }
            }
        }
        future.whenFailure { work.failBeforeEntry($0) }
        let caller = Task { try await future.get() }
        try await work.entered.futureResult.get()
        caller.cancel()
        #expect(probe.snapshot().borrowed == 1)
        #expect(probe.snapshot().inFlight == 1)
        #expect(database.loanMetricsSnapshot().classes[loanClass]?.inFlight == 1)
        let shutdownEntered = [base.eventLoop.makePromise(of: Void.self), base.eventLoop.makePromise(of: Void.self)]
        let completed = Mutex(0)
        let shutdowns = shutdownEntered.map { signal in
            Task {
                signal.succeed(())
                await database.shutdownLoans()
                completed.withLock { $0 += 1 }
            }
        }
        for signal in shutdownEntered { try await signal.futureResult.get() }
        #expect(completed.withLock { $0 } == 0)
        #expect(probe.snapshot().inFlight == 1)
        work.finish()
        try await future.get()
        _ = await caller.result
        for task in shutdowns { await task.value }
        #expect(completed.withLock { $0 } == 2)
        #expect(probe.snapshot().inFlight == 0)
        #expect(database.loanMetricsSnapshot().classes[loanClass]?.inFlight == 0)
        try await resources.shutdown()
    }

    @Test("activation policy validates its ordinary sublimit and zero renewal reservation remains usable")
    func activationPolicyAndUnreservedRenewal() async throws {
        for limit in [0, 10] {
            do {
                _ = try V2PhysicalDatabaseLoanPolicy(maximumConnections: 11,
                    reservedRenewalConnections: 2, maximumQueued: 4, maximumWait: .seconds(5),
                    maximumActivationConnections: limit)
                Issue.record("activation capacity must fit inside ordinary capacity")
            } catch { #expect(error as? V2PhysicalDatabaseLoanFailure == .invalidPolicy) }
        }
        let resources = makeV2DatabaseTestResources()
        let gate = V2PhysicalDatabaseLoanGate(eventLoop: resources.eventLoopGroup.next(), policy: try .init(
            maximumConnections: 1, reservedRenewalConnections: 0,
            maximumQueued: 4, maximumWait: .seconds(5)))
        let cold = try await gate.acquire(loanClass: .activation).get()
        let renewal = gate.request(loanClass: .renewal)
        #expect(gate.snapshot().classes[.renewal]?.queued == 1)
        cold.release()
        let renewalLease = try await renewal.future.get()
        #expect(gate.snapshot().classes[.renewal]?.inFlight == 1)
        let queued = gate.request(loanClass: .activation)
        let shutdown = Task { await gate.shutdown() }
        do {
            _ = try await queued.future.get()
            Issue.record("shutdown must reject queued cold work")
        } catch { #expect(error as? V2PhysicalDatabaseLoanFailure == .closed) }
        #expect(gate.snapshot().classes[.renewal]?.inFlight == 1)
        renewalLease.release()
        await shutdown.value
        try await resources.shutdown()
    }

    @Test("session borrow failure never enters the body and settles every ownership promise")
    func failedSessionBorrowSettlesOwnership() async throws {
        let resources = makeV2DatabaseTestResources()
        resources.databases.use(try .postgres(url: "postgres://imv2:unused@127.0.0.1:1/imv2"), as: .psql, isDefault: true)
        let base = resources.database(.psql)
        let probe = ControlledLoanProbe()
        let controlled = ControlledLoanDatabase(context: base.context,
            dialect: try #require((base as? any SQLDatabase)?.dialect), probe: probe, failBorrow: true)
        let database = try V2EventLoopBalancedDatabase(databases: [controlled], loanPolicy: .init(
            maximumConnections: 2, reservedRenewalConnections: 1,
            maximumQueued: 4, maximumWait: .seconds(5)))
        let entered = Mutex(false)
        do {
            let _: Void = try await database.withSession { _ in
                entered.withLock { $0 = true }
            }
            Issue.record("failed driver borrow must fail the session")
        } catch { #expect(error as? ControlledLoanFailure == .borrowFailed) }
        #expect(!entered.withLock { $0 })
        #expect(probe.snapshot().borrowed == 0)
        #expect(probe.snapshot().inFlight == 0)
        #expect(database.loanMetricsSnapshot().classes[.ordinary]?.inFlight == 0)
        // Both calls must return: no orphaned session completion promise may hold the loan.
        await database.shutdownLoans()
        await database.shutdownLoans()
        try await resources.shutdown()
    }

    @Test("queued loan cancellation removes only its waiter and granted ownership drains every shutdown",
          arguments: [V2PhysicalDatabaseLoanClass.ordinary, .activation, .sync])
    func queuedCancellationAndActualOwnership(loanClass: V2PhysicalDatabaseLoanClass) async throws {
        let resources = makeV2DatabaseTestResources()
        let loop = resources.eventLoopGroup.next()
        let gate = V2PhysicalDatabaseLoanGate(eventLoop: loop, policy: try .init(
            maximumConnections: 2, reservedRenewalConnections: 1,
            maximumQueued: 4, maximumWait: .seconds(5)))
        let first = gate.request(loanClass: loanClass)
        let lease = try await first.future.get()
        let queued = gate.request(loanClass: loanClass)
        #expect(gate.snapshot().classes[loanClass]?.queued == 1)
        queued.cancel()
        do {
            _ = try await queued.future.get()
            Issue.record("cancelled queued loan must fail")
        } catch { #expect(error as? V2PhysicalDatabaseLoanFailure == .cancelled) }
        #expect(gate.snapshot().classes[loanClass]?.queued == 0)
        let expired = gate.request(loanClass: loanClass, deadline: .now + .milliseconds(20))
        do {
            _ = try await expired.future.get()
            Issue.record("queued deadline must fail without reclaiming the held loan")
        } catch { #expect(error as? V2PhysicalDatabaseLoanFailure == .timedOut) }
        #expect(gate.snapshot().classes[loanClass]?.inFlight == 1)
        #expect(gate.snapshot().classes[loanClass]?.queued == 0)
        // Cancelling an already granted request cannot reclaim its ownership.
        first.cancel()
        #expect(gate.snapshot().classes[loanClass]?.inFlight == 1)
        let firstShutdownEntered = loop.makePromise(of: Void.self)
        let secondShutdownEntered = loop.makePromise(of: Void.self)
        let completions = Mutex(0)
        let shutdown0 = Task {
            firstShutdownEntered.succeed(())
            await gate.shutdown()
            completions.withLock { $0 += 1 }
        }
        let shutdown1 = Task {
            secondShutdownEntered.succeed(())
            await gate.shutdown()
            completions.withLock { $0 += 1 }
        }
        try await firstShutdownEntered.futureResult.get()
        try await secondShutdownEntered.futureResult.get()
        #expect(completions.withLock { $0 } == 0)
        #expect(gate.snapshot().classes[loanClass]?.inFlight == 1)
        lease.release()
        lease.release()
        await shutdown0.value
        await shutdown1.value
        #expect(completions.withLock { $0 } == 2)
        #expect(gate.snapshot().classes[loanClass]?.inFlight == 0)
        do {
            _ = try await gate.acquire(loanClass: loanClass).get()
            Issue.record("closed physical gate must reject new requests")
        } catch { #expect(error as? V2PhysicalDatabaseLoanFailure == .closed) }
        try await resources.shutdown()
    }
}

/// Holds the protocol operation's real EventLoopFuture, rather than teaching
/// a fake admission controller when it should release its counter.
private final class ControlledLoanWork: Sendable {
    let entered: EventLoopPromise<Void>
    let completion: EventLoopPromise<Void>
    private let state = Mutex((entered: false, completed: false))
    init(loop: any EventLoop) {
        entered = loop.makePromise(of: Void.self)
        completion = loop.makePromise(of: Void.self)
    }
    var hasEntered: Bool { state.withLock { $0.entered } }
    func failBeforeEntry(_ error: any Error) {
        let first = state.withLock { value in
            guard !value.entered else { return false }
            value.entered = true; return true
        }
        if first { entered.fail(error) }
    }
    func begin() -> EventLoopFuture<Void> {
        let first = state.withLock { value in
            guard !value.entered else { return false }
            value.entered = true; return true
        }
        if first { entered.succeed(()) }
        return completion.futureResult
    }
    func finish() {
        let first = state.withLock { value in
            guard !value.completed else { return false }
            value.completed = true; return true
        }
        if first { completion.succeed(()) }
    }
}

private final class ControlledLoanProbe: Sendable {
    struct State: Sendable { var inFlight = 0; var peak = 0; var borrowed = 0 }
    private let state = Mutex(State())
    func begin() { state.withLock { $0.inFlight += 1; $0.borrowed += 1; $0.peak = max($0.peak, $0.inFlight) } }
    func end() { state.withLock { $0.inFlight -= 1 } }
    func snapshot() -> State { state.withLock { $0 } }
}

private final class ControlledLoanDatabase: Database, SQLDatabase, Sendable {
    let context: DatabaseContext
    let dialect: any SQLDialect
    let probe: ControlledLoanProbe
    let inTransaction: Bool
    let failBorrow: Bool
    init(context: DatabaseContext, dialect: any SQLDialect, probe: ControlledLoanProbe, borrowed: Bool = false, failBorrow: Bool = false) {
        self.context = context; self.dialect = dialect; self.probe = probe; inTransaction = borrowed
        self.failBorrow = failBorrow
    }
    func withConnection<T>(_ closure: @escaping @Sendable (any Database) -> EventLoopFuture<T>) -> EventLoopFuture<T> {
        guard !inTransaction else { return closure(self) }
        guard !failBorrow else { return eventLoop.makeFailedFuture(ControlledLoanFailure.borrowFailed) }
        probe.begin()
        let borrowed = ControlledLoanDatabase(context: context, dialect: dialect, probe: probe, borrowed: true)
        return closure(borrowed).always { _ in self.probe.end() }
    }
    func transaction<T>(_ closure: @escaping @Sendable (any Database) -> EventLoopFuture<T>) -> EventLoopFuture<T> {
        withConnection(closure)
    }
    func execute(sql query: any SQLExpression, _ onRow: @escaping @Sendable (any SQLRow) -> Void) -> EventLoopFuture<Void> {
        guard !inTransaction else { return eventLoop.makeSucceededVoidFuture() }
        return withConnection { _ in self.eventLoop.makeSucceededVoidFuture() }
    }
    func withSession<R>(_ closure: @escaping @Sendable (any SQLDatabase) async throws -> R) async throws -> R {
        guard !inTransaction else { return try await closure(self) }
        probe.begin()
        defer { probe.end() }
        let borrowed = ControlledLoanDatabase(context: context, dialect: dialect, probe: probe, borrowed: true)
        return try await closure(borrowed)
    }
    func execute(query: DatabaseQuery, onOutput: @escaping @Sendable (any DatabaseOutput) -> Void) -> EventLoopFuture<Void> {
        eventLoop.makeFailedFuture(ControlledLoanFailure.unsupported)
    }
    func execute(schema: DatabaseSchema) -> EventLoopFuture<Void> { eventLoop.makeFailedFuture(ControlledLoanFailure.unsupported) }
    func execute(enum databaseEnum: DatabaseEnum) -> EventLoopFuture<Void> { eventLoop.makeFailedFuture(ControlledLoanFailure.unsupported) }
}
private enum ControlledLoanFailure: Error, Equatable { case unsupported, borrowFailed }
