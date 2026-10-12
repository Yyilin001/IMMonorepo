import Foundation
import NIOCore
import NIOEmbedded
import Synchronization
import Testing
@testable import PostgresNIO

@Suite("Independent PostgreSQL Sync cycles")
struct V2IndependentQueryPipelineTests {
    private func context(_ loop: EmbeddedEventLoop, sql: String = "INSERT INTO test VALUES (1)") -> IndependentQueryContext {
        .init(query: .init(unsafeSQL: sql), promise: loop.makePromise())
    }
    private func complete(_ pipeline: IndependentQueryPipeline, parses: Bool = true, describes: Bool = true) {
        if parses { #expect(pipeline.receive(.parseComplete) == .consumed) }
        if describes { #expect(pipeline.receive(.noData) == .consumed) }
        #expect(pipeline.receive(.bindComplete) == .consumed)
        #expect(pipeline.receive(.commandComplete("INSERT 0 1")) == .consumed)
    }
    @Test("two packets are emitted before any reply, and completion requires each own idle Ready")
    func independentCommitBoundaries() throws {
        let loop = EmbeddedEventLoop(), pipeline = IndependentQueryPipeline()
        let a = context(loop), b = context(loop)
        let settled = Mutex([Bool]())
        a.promise.futureResult.whenSuccess { _ in settled.withLock { $0.append(true) } }
        b.promise.futureResult.whenSuccess { _ in settled.withLock { $0.append(false) } }
        #expect(pipeline.enqueue(a) != nil)
        #expect(pipeline.enqueue(b) != nil)
        complete(pipeline)
        loop.run()
        #expect(settled.withLock { $0.isEmpty })
        #expect(pipeline.receive(.readyForQuery(.idle)) == .consumed)
        loop.run()
        #expect(settled.withLock { $0 } == [true])
        #expect(pipeline.hasPending)
        complete(pipeline, parses: false)
        #expect(pipeline.receive(.readyForQuery(.idle)) == .consumed)
        loop.run()
        #expect(settled.withLock { $0 } == [true, false])
        #expect(!pipeline.hasPending)
    }
    @Test("one SQL failure is isolated by Sync and the next cycle still succeeds")
    func failureIsolation() {
        let loop = EmbeddedEventLoop(), pipeline = IndependentQueryPipeline()
        let a = context(loop, sql: "bad sql"), b = context(loop)
        let settled = Mutex([String]())
        a.promise.futureResult.whenFailure { error in settled.withLock { $0.append(error is PSQLError ? "sql" : "unknown") } }
        b.promise.futureResult.whenSuccess { _ in settled.withLock { $0.append("ok") } }
        #expect(pipeline.enqueue(a) != nil)
        #expect(pipeline.enqueue(b) != nil)
        #expect(pipeline.receive(.error(.init(fields: [.severity: "ERROR", .sqlState: "42601"]))) == .consumed)
        loop.run(); #expect(settled.withLock { $0.isEmpty })
        #expect(pipeline.receive(.readyForQuery(.idle)) == .consumed)
        complete(pipeline)
        #expect(pipeline.receive(.readyForQuery(.idle)) == .consumed)
        loop.run(); #expect(settled.withLock { $0 } == ["sql", "ok"])
    }
    @Test("capacity rejects a third cycle, close only makes unconfirmed work unknown")
    func boundsAndClose() {
        let loop = EmbeddedEventLoop(), pipeline = IndependentQueryPipeline()
        let a = context(loop), b = context(loop), third = context(loop)
        let settled = Mutex([String]())
        a.promise.futureResult.whenSuccess { _ in settled.withLock { $0.append("a") } }
        b.promise.futureResult.whenFailure { error in
            if case PostgresIndependentQueryError.outcomeUnknown = error { settled.withLock { $0.append("unknown") } }
        }
        #expect(pipeline.enqueue(a) != nil)
        #expect(pipeline.enqueue(b) != nil)
        #expect(pipeline.enqueue(third) == nil)
        third.promise.fail(PostgresIndependentQueryError.notSubmitted)
        complete(pipeline)
        #expect(pipeline.receive(.readyForQuery(.idle)) == .consumed)
        pipeline.failUnconfirmed()
        loop.run(); #expect(settled.withLock { $0 } == ["a", "unknown"])
        let rejected = context(loop)
        #expect(pipeline.enqueue(rejected) == nil)
        rejected.promise.fail(PostgresIndependentQueryError.notSubmitted)
    }
    @Test("nonidle response cannot confirm an atomic commit")
    func transactionResponseRejected() {
        let loop = EmbeddedEventLoop(), pipeline = IndependentQueryPipeline()
        let a = context(loop)
        #expect(pipeline.enqueue(a) != nil)
        complete(pipeline)
        #expect(pipeline.receive(.readyForQuery(.inTransaction)) == .close)
        pipeline.failUnconfirmed(); loop.run()
    }
    @Test("bounded result rejects a 65th row and cannot publish success")
    func boundedResponse() {
        let loop = EmbeddedEventLoop(), pipeline = IndependentQueryPipeline(), a = context(loop, sql: "SELECT NULL")
        #expect(pipeline.enqueue(a) != nil)
        #expect(pipeline.receive(.parseComplete) == .consumed)
        #expect(pipeline.receive(.rowDescription(.init(columns: [
            .init(name: "v", tableOID: 0, columnAttributeNumber: 0, dataType: .int4, dataTypeSize: 4, dataTypeModifier: -1, format: .text)
        ]))) == .consumed)
        #expect(pipeline.receive(.bindComplete) == .consumed)
        var bytes = ByteBuffer(); bytes.writeInteger(Int32(-1))
        let row = DataRow(columnCount: 1, bytes: bytes)
        for _ in 0..<64 { #expect(pipeline.receive(.dataRow(row)) == .consumed) }
        #expect(pipeline.receive(.dataRow(row)) == .close)
        pipeline.failUnconfirmed(); loop.run()
    }
}
