import Foundation
import Testing
@testable import IMV2ClientKit

@Suite("System byte observations require an exact adopted mapping")
struct V2ResourceNativeProgressTests {
    @Test func directionsKeepSameUUIDSeparateAndDoNotTreatBytesAsCompletion() {
        let job = UUID(), a = UUID(), b = UUID(), now = Date()
        let bindings: [V2ResourceNativeProgressBinding] = [
            .init(transfer: .upload(job), mapping: a, identifier: 1, expectedBytes: 10, expiresAt: now.addingTimeInterval(60)),
            .init(transfer: .download(job), mapping: b, identifier: 2, expectedBytes: 20, expiresAt: now.addingTimeInterval(60))]
        let values = V2ResourceNativeProgress.snapshot(bindings: bindings,
            tasks: [.init(identifier: 1, mappingID: a, sentBytes: 10, receivedBytes: 100), .init(identifier: 2, mappingID: b, sentBytes: 200, receivedBytes: 7)], now: now)
        #expect(values[.upload(job)]?.transferredBytes == 10 && values[.upload(job)]?.attemptID == a)
        #expect(values[.download(job)]?.transferredBytes == 7 && values[.download(job)]?.expectedBytes == 20)
    }

    @Test func unmatchedUnknownInvalidExpiredAndDuplicateObservationsAreOmitted() {
        let now = Date(), job = UUID(), mapping = UUID()
        let binding = V2ResourceNativeProgressBinding(transfer: .download(job), mapping: mapping, identifier: 1, expectedBytes: 10, expiresAt: now.addingTimeInterval(60))
        let invalid: [V2BackgroundSystemTask] = [
            .init(identifier: 2, mappingID: mapping, receivedBytes: 4),
            .init(identifier: 1, mappingID: UUID(), receivedBytes: 4),
            .init(identifier: 1, mappingID: nil, receivedBytes: 4),
            .init(identifier: 1, mappingID: mapping),
            .init(identifier: 1, mappingID: mapping, receivedBytes: -1),
            .init(identifier: 1, mappingID: mapping, receivedBytes: 11)]
        for task in invalid { #expect(V2ResourceNativeProgress.snapshot(bindings: [binding], tasks: [task], now: now).isEmpty) }
        let valid = V2BackgroundSystemTask(identifier: 1, mappingID: mapping, receivedBytes: 5)
        #expect(V2ResourceNativeProgress.snapshot(bindings: [binding], tasks: [valid, valid], now: now).isEmpty)
        #expect(V2ResourceNativeProgress.snapshot(bindings: [binding, binding], tasks: [valid], now: now).isEmpty)
        #expect(V2ResourceNativeProgress.snapshot(bindings: [binding], tasks: [valid], now: now.addingTimeInterval(60)).isEmpty)
        #expect(V2ResourceNativeProgress.snapshot(bindings: [], tasks: [valid], now: now).isEmpty)
        #expect(V2ResourceNativeProgress.snapshot(bindings: [binding], tasks: Array(repeating: valid, count: 65), now: now).isEmpty)
    }
}
