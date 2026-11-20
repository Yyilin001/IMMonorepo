import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import IMV2ClientKit
@testable import IMV2ClientRuntime
@testable import IMV2ClientNetwork
@testable import IMV2ClientApple

@Suite("Foundation connectivity callbacks remain observational", .timeLimit(.minutes(1)))
struct V2ResourceConnectivityTests {
    @Test(arguments: Kind.allCases)
    func delegateClearsWaitOnActualActivityAndIgnoresLateWait(kind: Kind) {
        exercise(kind: kind, cancel: false)
    }
    @Test(arguments: Kind.allCases)
    func cancellationClearsWaitWithoutResurrection(kind: Kind) {
        exercise(kind: kind, cancel: true)
    }
    @Test func callbackCannotRecreateClosedAccountObservation() {
        let hub = V2ResourceTransferProgressHub(), id = V2ManagedResourceTransferID.download(UUID())
        let observation = V2ResourceConnectivityObservation(context: .init(transfer: id, hub: hub))
        hub.close(); observation.waiting()
        #expect(hub.waitingSnapshot().isEmpty)
        observation.finish()
    }
    #if canImport(Darwin)
    @Test func onlyMediaPoolWaitsAndCallerCanChooseExplicitly() {
        #expect(!V2SecureURLSession.account.configuration.waitsForConnectivity)
        #expect(V2SecureURLSession.mediaProvider.configuration.waitsForConnectivity)
        let custom = V2SecureURLSession.make(waitForConnectivity: true)
        defer { custom.invalidateAndCancel() }
        #expect(custom.configuration.waitsForConnectivity)
    }
    #endif
    enum Kind: CaseIterable, Sendable {
        case upload, range
        #if canImport(Darwin)
        case request
        #endif
    }
    private func exercise(kind: Kind, cancel: Bool) {
        let hub = V2ResourceTransferProgressHub(), id = V2ManagedResourceTransferID.download(UUID())
        let session = V2SecureURLSession.make(), url = URL(string: "https://example.invalid/resource")!
        defer { hub.close(); session.invalidateAndCancel() }
        // Never resume a physical task or access a network. Deliver Foundation's
        // callback boundary to the actual production delegate with captured scope.
        let task = session.dataTask(with: url)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let callbacks: (wait: () -> Void, active: () -> Void, cancel: () -> Void) = V2ResourceTransferWaitScope.$context.withValue(.init(transfer: id, hub: hub)) {
            switch kind {
            case .upload:
                let delegate = V2FileUploadDelegate(diagnostics: nil, mode: .upload, retry: false, progress: nil)
                return ({ delegate.urlSession(session, taskIsWaitingForConnectivity: task) },
                        { delegate.urlSession(session, task: task, didSendBodyData: 1, totalBytesSent: 1, totalBytesExpectedToSend: 2) },
                        { delegate.cancel() })
            case .range:
                let delegate = V2RangeTaskDelegate(diagnostics: nil, mode: .rangeDownload, retry: false, maximumBytes: 2, receiveResponse: { _ in }, consume: { _ in })
                return ({ delegate.urlSession(session, taskIsWaitingForConnectivity: task) },
                        { delegate.urlSession(session, dataTask: task, didReceive: response, completionHandler: { _ in }) },
                        { delegate.cancel() })
            #if canImport(Darwin)
            case .request:
                let observation = V2ResourceConnectivityObservation()
                let delegate = V2HTTPExecutionDelegate(events: .init(waiting: { observation.waiting() }, active: { observation.finish() }))
                return ({ delegate.urlSession(session, taskIsWaitingForConnectivity: task) },
                        { delegate.record(response: 200, bytes: 0) },
                        { delegate.cancel() })
            #endif
            }
        }
        #expect(hub.waitingSnapshot().isEmpty)
        callbacks.wait(); callbacks.wait()
        #expect(hub.waitingSnapshot()[id] == .network)
        // A distinct consumer's admission wait must survive this task finishing.
        let other = hub.beginWait(transfer: id, reason: .requestSlot)
        if cancel { callbacks.cancel() } else { callbacks.active() }
        #expect(hub.waitingSnapshot()[id] == .requestSlot)
        callbacks.wait()
        #expect(hub.waitingSnapshot()[id] == .requestSlot)
        other?.end()
        #expect(hub.waitingSnapshot().isEmpty)
        callbacks.cancel(); callbacks.active(); callbacks.wait()
        #expect(hub.waitingSnapshot().isEmpty)
    }
}
