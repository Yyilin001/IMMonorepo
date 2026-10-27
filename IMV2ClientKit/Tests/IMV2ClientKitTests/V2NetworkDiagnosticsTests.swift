import Foundation
@testable import IMV2ClientKit
import Testing

@Suite("Bounded production network diagnostics")
struct V2NetworkDiagnosticsTests {
    @Test func backgroundUnknownAndBoundedSamplesNeverSubstitutePayloadOrZero() {
        let diagnostics=V2NetworkDiagnostics()
        for _ in 0..<10_000 { diagnostics.record(V2BackgroundTransferMetric(result:nil)) }
        #expect(diagnostics.snapshot().backgrounds.count == 128)
        #expect(diagnostics.snapshot().backgroundRecorded == 10_000)
        #expect(diagnostics.snapshot().backgrounds.allSatisfy {
            !$0.completionObserved && $0.errorCode == nil && $0.bodyBytesSent == nil && $0.bodyBytesReceived == nil && $0.cancelled == nil
        })
        let result=V2BackgroundTransferResult(mappingID:UUID(),taskIdentifier:1,statusCode:nil,
            errorCode:URLError.cancelled.rawValue,sentBytes:3,receivedBytes:0)
        diagnostics.record(V2BackgroundTransferMetric(result:result))
        #expect(diagnostics.snapshot().backgrounds.last?.bodyBytesSent == 3)
        #expect(diagnostics.snapshot().backgrounds.last?.bodyBytesReceived == 0)
        #expect(diagnostics.snapshot().backgrounds.last?.cancelled == true)
        #expect(diagnostics.snapshot().backgrounds.last?.errorCode == URLError.cancelled.rawValue)
        diagnostics.close()
        diagnostics.record(V2BackgroundTransferMetric(result:result))
        #expect(diagnostics.snapshot().backgrounds.isEmpty)
        #expect(diagnostics.snapshot().backgroundRecorded == 10_001)
    }

    @Test func resourcePressureIsBoundedWithoutInventingWireOrDuplicateBytes() {
        let diagnostics = V2NetworkDiagnostics()
        for _ in 0..<10_000 {
            diagnostics.record(.init(mode:.multipartUpload,statusCode:200,bodyBytesSent:7,bodyBytesReceived:2,
                elapsed:0.1,retryAttempt:true,cancelled:false,failed:false))
        }
        #expect(diagnostics.snapshot().resourceRecorded == 10_000)
        #expect(diagnostics.snapshot().resources.count == 128)
        #expect(diagnostics.snapshot().resources.last?.bodyBytesSent == 7)
        diagnostics.record(.init(mode:.download,statusCode:nil,bodyBytesSent:-1,bodyBytesReceived:0,
            elapsed:0.1,retryAttempt:false,cancelled:false,failed:true))
        #expect(diagnostics.snapshot().resourceRecorded == 10_000)
        diagnostics.close()
        #expect(diagnostics.snapshot().resources.isEmpty)
    }

    @Test func pressureAndSensitiveLabels() async throws {
        let sink = V2NetworkDiagnostics()
        let stream = try sink.updates()
        for _ in 0..<10_000 { sink.record(sample(service: "https://host/path?token=private")) }
        #expect(sink.snapshot().recorded == 10_000)
        #expect(sink.snapshot().samples.count == 128)
        #expect(sink.snapshot().samples.allSatisfy { $0.service == "other" && $0.phases == nil })
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next()?.recorded == 10_000)
        sink.close()
        #expect(await iterator.next() == nil)
        sink.record(sample())
        #expect(sink.snapshot().samples.isEmpty)
    }
    @Test func boundedObserversAndInvalidClockValues() throws {
        let sink = V2NetworkDiagnostics()
        var streams: [AsyncStream<V2NetworkDiagnostics.Snapshot>] = []
        for _ in 0..<8 { streams.append(try sink.updates()) }
        #expect(throws: V2NetworkDiagnostics.ObservationError.overloaded) { try sink.updates() }
        sink.record(sample(elapsed: .nan)); sink.record(sample(elapsed: -1))
        #expect(sink.snapshot().recorded == 0)
        #expect(V2HTTPPhaseTiming.duration(nil, Date()) == nil)
        #expect(V2HTTPPhaseTiming.duration(Date(timeIntervalSince1970: 2), Date(timeIntervalSince1970: 1)) == nil)
        #expect(V2HTTPPhaseTiming.duration(Date(timeIntervalSince1970: 1), Date(timeIntervalSince1970: 3)) == 2)
        sink.close()
        #expect(streams.count == 8)
    }
    @Test func accountRuntimeActuallyConsumesExecutorEventsAndDrainsObservers() async throws {
        let runtime = V2AccountRuntime(configuration: .init(ordinaryLimit: 1, serviceLimit: 1))
        let held = try await runtime.scheduler.acquire(.init(service: "accountAPI"))
        // Fill ordinary admission so a queued attempt expires before any I/O.

        await #expect(throws: V2HTTPFailure.self) {
            _ = try await runtime.httpExecutor.execute(URLRequest(url: URL(string: "https://example.test/profile")!),
                budget: .init(timeout: 0.02), service: "accountAPI")
        }
        let value = try #require(runtime.networkDiagnostics.snapshot().samples.last)
        #expect(value.certainty == .notStarted && value.failure == .deadlineExceeded)
        #expect(value.queued > 0 && value.elapsed == 0 && value.phases == nil)
        _ = await runtime.scheduler.release(held)
        await runtime.close()
        #expect(runtime.networkDiagnostics.snapshot().samples.isEmpty)
    }
    @Test func operationPressureIsBoundedAndReturningDoesNotCreateProof() {
        let sink = V2NetworkDiagnostics()
        for _ in 0..<10_000 {
            sink.record(V2OperationStepMetric(kind: .profileUpdate, action: .submit, attempt: 1,
                priority: .interactive, candidateWait: 0.01, handlerElapsed: 0.02,
                completion: .returned, execution: .awaitingConfirmation, scheduling: .backingOff))
        }
        let snapshot = sink.snapshot()
        #expect(snapshot.operationRecorded == 10_000 && snapshot.operationSteps.count == 128)
        #expect(snapshot.httpRecorded == 0 && snapshot.samples.isEmpty)
        #expect(snapshot.operationSteps.allSatisfy { $0.certainty == .outcomeUnknown })
        sink.close()
        #expect(sink.snapshot().operationSteps.isEmpty)
    }
    private func sample(service: String = "accountAPI", elapsed: TimeInterval = 1) -> V2NetworkMetric {
        .init(service: service, elapsed: elapsed, receivedBytes: 3, statusCode: 200, failure: nil,
            cancelled: false, transactionCount: 0, reusedConnection: false)
    }
}
