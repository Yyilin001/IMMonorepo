import Foundation
import IMV2ServerApplication
import IMV2ServerContracts
import NIOCore
import SQLKit
import Synchronization

/// Observes only explicitly instrumented room/lease queries in one actual
/// transaction. It neither owns SQL nor changes cancellation or error semantics.
package final class V2RoomSQLContinuationTrace: Sendable {
    private enum Phase: Sendable { case waiting, settled(ContinuousClock.Instant), resumed(ContinuousClock.Instant) }
    private struct Pending: Sendable { let sequence: UInt64; let source: V2RoomSQLContinuationSource; var phase: Phase }
    private struct State: Sendable { var sequence: UInt64 = 0; var pending: Pending? }
    private let state = Mutex(State())
    private let metrics: V2SendOperationBatchMetrics

    package init(metrics: V2SendOperationBatchMetrics) { self.metrics = metrics }

    /// Must run immediately before the next actual SQL/COMMIT/ROLLBACK API.
    package func willDispatch() {
        state.withLock { state in
            guard let pending = state.pending, case .resumed(let at) = pending.phase else { return }
            metrics.recordSQLNextDispatch(source: pending.source, duration: at.duration(to: .now))
            state.pending = nil
        }
    }

    /// Ends a sequence without another observed dispatch. A later uninstrumented
    /// SQL may still run; this invents no interval or SQL-outcome claim.
    package func finishWithoutDispatch() {
        state.withLock { state in
            guard let pending = state.pending, case .resumed = pending.phase else { return }
            metrics.recordSQLNoNextDispatch(source: pending.source)
            state.pending = nil
        }
    }

    /// Registration and completion are separate from Swift resumption so a
    /// controlled future can prove that the first timestamp belongs to the EL.
    package func track<Value: Sendable>(_ future: EventLoopFuture<Value>, source: V2RoomSQLContinuationSource) -> Tracked<Value> {
        let sequence = state.withLock { state -> UInt64 in
            precondition(state.pending == nil, "continuation trace requires sequential transaction SQL")
            state.sequence &+= 1
            state.pending = .init(sequence: state.sequence, source: source, phase: .waiting)
            return state.sequence
        }
        let observed: EventLoopFuture<Value> = future.map { [self] value -> Value in
            settled(sequence)
            return value
        }.flatMapErrorThrowing { [self] error -> Value in
            settled(sequence)
            throw error
        }
        return .init(future: observed, trace: self, sequence: sequence)
    }

    private func settled(_ sequence: UInt64) {
        state.withLock { state in
            guard var pending = state.pending, pending.sequence == sequence, case .waiting = pending.phase else { return }
            pending.phase = .settled(.now)
            metrics.recordSQLResultSettled(source: pending.source)
            state.pending = pending
        }
    }

    private func resumed(_ sequence: UInt64) {
        state.withLock { state in
            guard var pending = state.pending, pending.sequence == sequence, case .settled(let at) = pending.phase else { return }
            let now = ContinuousClock.now
            pending.phase = .resumed(now)
            metrics.recordSQLTaskResumed(source: pending.source, duration: at.duration(to: now))
            state.pending = pending
        }
    }

    package struct Tracked<Value: Sendable>: Sendable {
        let future: EventLoopFuture<Value>
        let trace: V2RoomSQLContinuationTrace
        let sequence: UInt64
        package func get() async throws -> Value {
            let value: Value
            do { value = try await future.get() }
            catch { trace.resumed(sequence); throw error }
            trace.resumed(sequence)
            return value
        }
    }
}

package enum V2RoomSQLContinuationObservation {
    @TaskLocal package static var current: V2RoomSQLContinuationTrace?
    /// Composition can supply a physical-owner recorder; the actual borrowed
    /// transaction creates a fresh trace, never sharing pending state across SQL.
    @TaskLocal package static var metrics: V2SendOperationBatchMetrics?
}

func v2RoomSQLObservedAll<Row: Decodable>(_ query: any SQLQueryFetcher, decoding: Row.Type,
    source: V2RoomSQLContinuationSource) async throws -> [Row] {
    let trace = V2RoomSQLContinuationObservation.current
    trace?.willDispatch()
    let future: EventLoopFuture<[any SQLRow]> = query.all()
    do {
        let rows: [any SQLRow]
        if let trace { rows = try await trace.track(future, source: source).get() }
        else { rows = try await future.get() }
        return try rows.map { try $0.decode(model: Row.self) }
    } catch {
        // Catchers may issue uninstrumented SAVEPOINT/domain SQL. End only
        // this observed sequence rather than spanning those later statements.
        trace?.finishWithoutDispatch()
        throw error
    }
}

func v2RoomSQLObservedFirst<Row: Decodable>(_ query: any SQLQueryFetcher, decoding: Row.Type,
    source: V2RoomSQLContinuationSource) async throws -> Row? {
    let trace = V2RoomSQLContinuationObservation.current
    trace?.willDispatch()
    let future: EventLoopFuture<(any SQLRow)?> = query.first()
    do {
        let row: (any SQLRow)?
        if let trace { row = try await trace.track(future, source: source).get() }
        else { row = try await future.get() }
        return try row?.decode(model: Row.self)
    } catch {
        trace?.finishWithoutDispatch()
        throw error
    }
}
