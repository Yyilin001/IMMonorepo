import Foundation
import Crypto
import IMV2Core
import Testing
import Synchronization
@testable import IMV2ClientKit

struct V2RangeDownloadTests {
    @Test func responseProgressMeasuresEachAcceptedRangeAndFullResponseRebuildSeparately() async throws {
        let destination = try destination()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        let hub = V2ResourceTransferProgressHub(), id = UUID()
        let capture = RangeProgressCapture(hub: hub, id: id)
        let transport = CapturedRangeTransport(base: RangeFixture(body: body), capture: capture)
        try await V2ResourceDownloadProgressScope.$context.withValue(.init(job: id, hub: hub)) {
            try await V2URLSessionMediaByteTransfer(transport: transport, chunkBytes: 4).download(target: target(body), destinationURL: destination)
        }
        #expect(capture.headers.compactMap { $0?.expectedBytes } == [4,4,2])
        #expect(capture.bodies.compactMap { $0?.transferredBytes } == [4,4,2])
        #expect(Set(capture.headers.compactMap { $0?.attemptID }).count == 3)
        #expect(hub.snapshot().isEmpty)
        #expect(try Data(contentsOf: destination) == body)
        hub.close()
    }

    @Test func interruptedResponseEndsItsProgressAnd200RebuildDoesNotAddOldPrefix() async throws {
        let destination = try destination()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        let hub = V2ResourceTransferProgressHub(), id = UUID()
        let initial = RangeProgressCapture(hub: hub, id: id)
        await #expect(throws: URLError.self) {
            try await V2ResourceDownloadProgressScope.$context.withValue(.init(job: id, hub: hub)) {
                try await V2URLSessionMediaByteTransfer(transport: CapturedRangeTransport(base: RangeFixture(body: body, failAfterBytes: 2), capture: initial), chunkBytes: 4)
                    .download(target: target(body), destinationURL: destination)
            }
        }
        #expect(initial.bodies.compactMap { $0?.transferredBytes } == [2])
        #expect(hub.snapshot().isEmpty)
        let resumed = RangeProgressCapture(hub: hub, id: id)
        try await V2ResourceDownloadProgressScope.$context.withValue(.init(job: id, hub: hub)) {
            try await V2URLSessionMediaByteTransfer(transport: CapturedRangeTransport(base: RangeFixture(body: body, fullResponse: true), capture: resumed), chunkBytes: 4)
                .download(target: target(body), destinationURL: destination)
        }
        #expect(resumed.headers.compactMap { $0?.expectedBytes } == [10])
        #expect(resumed.bodies.compactMap { $0?.transferredBytes } == [10])
        #expect(initial.headers.compactMap { $0 }.first?.attemptID != resumed.headers.compactMap { $0 }.first?.attemptID)
        #expect(hub.snapshot().isEmpty)
        hub.close()
    }

    @Test func rejectedVersionNeverStartsAResponseProgressAttempt() async throws {
        let destination = try destination()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        await #expect(throws: URLError.self) {
            try await V2URLSessionMediaByteTransfer(transport: RangeFixture(body: body, failAfterBytes: 2), chunkBytes: 4).download(target: target(body), destinationURL: destination)
        }
        let hub = V2ResourceTransferProgressHub(), id = UUID()
        let capture = RangeProgressCapture(hub: hub, id: id)
        await #expect(throws: V2RangeDownloadError.versionChanged) {
            try await V2ResourceDownloadProgressScope.$context.withValue(.init(job: id, hub: hub)) {
                try await V2URLSessionMediaByteTransfer(transport: CapturedRangeTransport(base: RangeFixture(body: body, etag: "\"other-version\""), capture: capture), chunkBytes: 4)
                    .download(target: target(body), destinationURL: destination)
            }
        }
        #expect(capture.headers.isEmpty && capture.bodies.isEmpty && hub.snapshot().isEmpty)
        hub.close()
    }
    @Test func everyRangeRequestRetainsNetworkRestrictionsAndCannotRelaxAnExistingRestriction() async throws {
        let destination = try destination()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        let expected = V2ResourceDownloadNetworkConstraints(allowsCellular: false, allowsExpensive: false, allowsConstrained: false)
        let restricted = try target(body).restrictingNetwork(to: expected).restrictingNetwork(to: .unrestricted)
        let transport = RangeFixture(body: body)
        try await V2URLSessionMediaByteTransfer(transport: transport, chunkBytes: 4).download(target: restricted, destinationURL: destination)
        let requests = await transport.recorded
        #expect(requests.count == 3)
        for request in requests {
            #expect(!request.allowsCellularAccess)
            #expect(!request.allowsExpensiveNetworkAccess)
            #expect(!request.allowsConstrainedNetworkAccess)
        }
        #expect(try Data(contentsOf: destination) == body)
    }
    @Test(arguments: ["rebuild", "rebuild-corrupt", "rebuild-changed"])
    func verifiedPrefixRequiresSameEntityAndFinalChecksum(path: String) async throws {
        let body = Data("abcdefghij".utf8), root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("download")
        let plan = try V2ClientMediaTransferTarget(downloadPlan: .init(mode: .httpGet,
            url: URL(string: "https://provider.invalid/" + path)!, expiresAt: .now.addingTimeInterval(60),
            expectedByteCount: 10, checksum: .init(value: SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined())))
        await #expect(throws: URLError.self) {
            try await V2URLSessionMediaByteTransfer(transport: RangeFixture(body: body, failAfterBytes: 2), chunkBytes: 4)
                .download(target: plan, destinationURL: destination)
        }
        let diagnostics = V2NetworkDiagnostics()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NativeRangeProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let downloader = V2URLSessionMediaByteTransfer(session: session, diagnostics: diagnostics)
        if path == "rebuild-corrupt" {
            await #expect(throws: V2ClientMediaTransferError.checksumMismatch) { try await downloader.download(target: plan, destinationURL: destination) }
        } else { try await downloader.download(target: plan, destinationURL: destination) }
        let metrics = diagnostics.snapshot().resources
        #expect(metrics.count == 1)
        let metric = try #require(metrics.first)
        #expect(metric.bodyBytesReceived == 10)
        #expect(metric.verifiedRangeRebuildPrefixBytes == (path == "rebuild" ? 2 : nil))
        #expect(FileManager.default.fileExists(atPath: destination.path) == (path != "rebuild-corrupt"))
    }


    private let body = Data("abcdefghij".utf8)
    private func target(_ bytes: Data) throws -> V2ClientMediaTransferTarget {
        try .init(downloadPlan: .init(mode: .httpGet,url: URL(string:"https://provider.invalid/object?signature=secret")!,expiresAt: Date().addingTimeInterval(60),expectedByteCount: Int64(bytes.count),checksum: .init(value: SHA256.hash(data: bytes).map { String(format:"%02x",$0) }.joined())))
    }
    private func destination() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "range-\(UUID())")
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        return root.appending(path:"download")
    }
    @Test func interruptedRangeResumesSameVersionAndNeverPersistsSignature() async throws {
        let destination = try destination()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        let first = RangeFixture(body: body,failAfterBytes: 2)
        let target = try target(body)
        await #expect(throws: URLError.self) { try await V2URLSessionMediaByteTransfer(transport:first,chunkBytes:4).download(target:target,destinationURL:destination) }
        let journal = try String(contentsOf:destination.appendingPathExtension("range-journal"),encoding:.utf8)
        #expect(!journal.contains("signature") && !journal.contains("secret") && !journal.contains("https"))
        let resumed = RangeFixture(body:body)
        try await V2URLSessionMediaByteTransfer(transport:resumed,chunkBytes:4).download(target:target,destinationURL:destination)
        #expect(try Data(contentsOf:destination) == body)
        #expect(await resumed.ranges().first == "bytes=2-5")
        #expect(await resumed.ifRanges().first == "\"version-1\"")
        #expect(!FileManager.default.fileExists(atPath:destination.appendingPathExtension("range-journal").path))
    }
    @Test func provider200RestartsRatherThanAppending() async throws {
        let destination = try destination()
        defer { try? FileManager.default.removeItem(at:destination.deletingLastPathComponent()) }
        let target = try target(body)
        await #expect(throws: URLError.self) { try await V2URLSessionMediaByteTransfer(transport:RangeFixture(body:body,failAfterBytes:2),chunkBytes:4).download(target:target,destinationURL:destination) }
        let fallback = RangeFixture(body:body,fullResponse:true)
        try await V2URLSessionMediaByteTransfer(transport:fallback,chunkBytes:4).download(target:target,destinationURL:destination)
        #expect(try Data(contentsOf:destination) == body)
        #expect(await fallback.ranges().first == "bytes=2-5")
    }
    @Test func changedETagCannotMixVersions() async throws {
        let destination = try destination()
        defer { try? FileManager.default.removeItem(at:destination.deletingLastPathComponent()) }
        let target = try target(body)
        await #expect(throws: URLError.self) { try await V2URLSessionMediaByteTransfer(transport:RangeFixture(body:body,failAfterBytes:2),chunkBytes:4).download(target:target,destinationURL:destination) }
        await #expect(throws: V2RangeDownloadError.versionChanged) {
            try await V2URLSessionMediaByteTransfer(transport:RangeFixture(body:body,etag:"\"version-2\""),chunkBytes:4).download(target:target,destinationURL:destination)
        }
        #expect(!FileManager.default.fileExists(atPath:destination.path))
        let bytes = try Data(contentsOf:destination.appendingPathExtension("range-journal"))
        #expect(try JSONDecoder().decode(V2RangeDownloadJournal.self,from:bytes).offset == 0)
    }
    @Test(arguments: [false,true]) func uncommittedTailAndTamperedPrefixAreNotResumeInputs(tampered: Bool) async throws {
        let destination = try destination()
        defer { try? FileManager.default.removeItem(at:destination.deletingLastPathComponent()) }
        let target = try target(body)
        await #expect(throws: URLError.self) { try await V2URLSessionMediaByteTransfer(transport:RangeFixture(body:body,failAfterBytes:2),chunkBytes:4).download(target:target,destinationURL:destination) }
        let partial = destination.appendingPathExtension("range-part")
        try Data((tampered ? "XYUNCOMMITTED" : "abUNCOMMITTED").utf8).write(to:partial)
        let resumed = RangeFixture(body:body)
        try await V2URLSessionMediaByteTransfer(transport:resumed,chunkBytes:4).download(target:target,destinationURL:destination)
        #expect(await resumed.ranges().first == (tampered ? "bytes=0-3" : "bytes=2-5"))
        #expect(try Data(contentsOf:destination) == body)
    }
    @Test func recoveredCompleteCheckpointAccepts416BodyOnlyAfterVerification() async throws {
        let destination = try destination()
        defer { try? FileManager.default.removeItem(at:destination.deletingLastPathComponent()) }
        let target = try target(body)
        do {
            let file = try V2RangeDownloadFile(destination:destination,target:target)
            let response = HTTPURLResponse(url:target.url,statusCode:200,httpVersion:nil,headerFields:["ETag":"\"version-1\""])!
            try file.accept(response,requestedStart:0,requestedEnd:9)
            try file.append(body); try file.finishResponse()
        }
        let transport = RangeFixture(body:body)
        try await V2URLSessionMediaByteTransfer(transport:transport,chunkBytes:4).download(target:target,destinationURL:destination)
        #expect(await transport.ranges().first == "bytes=10-13")
        #expect(try Data(contentsOf:destination) == body)
    }
    @Test func range416RequiresExactLocalSizeAndThenDigest() throws {
        let destination = try destination()
        defer { try? FileManager.default.removeItem(at:destination.deletingLastPathComponent()) }
        let target = try target(body)
        let file = try V2RangeDownloadFile(destination:destination,target:target)
        let complete = HTTPURLResponse(url:target.url,statusCode:416,httpVersion:nil,headerFields:["Content-Range":"bytes */10"])!
        #expect(throws: V2RangeDownloadError.invalidRange) { try file.accept(complete,requestedStart:0,requestedEnd:3) }
        let response = HTTPURLResponse(url:target.url,statusCode:200,httpVersion:nil,headerFields:[:])!
        try file.accept(response,requestedStart:0,requestedEnd:3); try file.append(body); try file.finishResponse()
        try file.accept(complete,requestedStart:10,requestedEnd:13); try file.finishResponse(); try file.publish(to:destination)
        #expect(try Data(contentsOf:destination) == body)
    }
}
private final class RangeProgressCapture: Sendable {
    private struct State: Sendable { var headers: [V2ResourceTransferAttemptProgress?] = []; var bodies: [V2ResourceTransferAttemptProgress?] = [] }
    private let state = Mutex(State())
    let hub: V2ResourceTransferProgressHub
    let id: UUID
    init(hub: V2ResourceTransferProgressHub, id: UUID) { self.hub = hub; self.id = id }
    var headers: [V2ResourceTransferAttemptProgress?] { state.withLock { $0.headers } }
    var bodies: [V2ResourceTransferAttemptProgress?] { state.withLock { $0.bodies } }
    func header() { let sample = hub.snapshot()[.download(id)]; state.withLock { $0.headers.append(sample) } }
    func body() { let sample = hub.snapshot()[.download(id)]; state.withLock { $0.bodies.append(sample) } }
}
private struct CapturedRangeTransport: V2RangeDownloadTransport {
    let base: RangeFixture
    let capture: RangeProgressCapture
    func stream(_ request: URLRequest, maximumBytes: Int64, receiveResponse: @escaping @Sendable (HTTPURLResponse) throws -> Void,
                consume: @escaping @Sendable (Data) throws -> Void) async throws -> V2RangeDownloadResponse {
        try await base.stream(request, maximumBytes: maximumBytes, receiveResponse: {
            try receiveResponse($0); capture.header()
        }, consume: { try consume($0); capture.body() })
    }
}

private actor RangeFixture: V2RangeDownloadTransport {
    let body: Data
    let failAfterBytes: Int?
    let fullResponse: Bool
    let etag: String
    var recorded: [URLRequest] = []
    init(body:Data,failAfterBytes:Int? = nil,fullResponse:Bool = false,etag:String = "\"version-1\"") {
        self.body = body; self.failAfterBytes = failAfterBytes; self.fullResponse = fullResponse; self.etag = etag
    }
    func ranges() -> [String] { recorded.compactMap { $0.value(forHTTPHeaderField:"Range") } }
    func ifRanges() -> [String] { recorded.compactMap { $0.value(forHTTPHeaderField:"If-Range") } }
    func stream(_ request:URLRequest,maximumBytes:Int64,receiveResponse:@escaping @Sendable (HTTPURLResponse)throws -> Void,consume:@escaping @Sendable (Data)throws -> Void) async throws -> V2RangeDownloadResponse {
        recorded.append(request)
        let range = request.value(forHTTPHeaderField:"Range")!.dropFirst(6).split(separator:"-").map { Int($0)! }
        if range[0] == body.count {
            let response = HTTPURLResponse(url:request.url!,statusCode:416,httpVersion:nil,headerFields:["Content-Range":"bytes */\(body.count)"])!
            try receiveResponse(response); try consume(Data("error body".utf8)); return .init(response: response)
        }
        let start = fullResponse ? 0 : range[0]
        let end = fullResponse ? body.count - 1 : min(body.count - 1,range[1])
        let headers = fullResponse ? ["ETag":etag] : ["ETag":etag,"Content-Range":"bytes \(start)-\(end)/\(body.count)"]
        let response = HTTPURLResponse(url:request.url!,statusCode:fullResponse ? 200 : 206,httpVersion:nil,headerFields:headers)!
        try receiveResponse(response)
        if let failAfterBytes { try consume(body.subdata(in:start..<min(end+1,start+failAfterBytes))); throw URLError(.networkConnectionLost) }
        try consume(body.subdata(in:start..<end+1)); return .init(response: response)
    }
}

struct V2RangeNativeTransportTests {
    @Test func sharedPriorityPromotionReachesRealRangeTransportWithoutASecondTransfer() async throws {
        let session = session(); defer { session.invalidateAndCancel() }
        let root = FileManager.default.temporaryDirectory.appending(path: "promoted-native-range-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let scheduler = V2AccountWorkScheduler(), demand = V2ByteTransferDemand(priority: .background)
        let occupied = try await scheduler.acquire(.init(service: "mediaProvider", priority: .background, kind: .byteTransfer(.download)))
        let download = V2URLSessionMediaByteTransfer(session: session, scheduler: scheduler)
        let target = try target(), file = root.appending(path: "download")
        let queued = Task {
            try await V2NetworkWorkScope.$context.withValue(.init(service: "resources", priority: .background)) {
                try await V2ByteTransferWorkScope.$demand.withValue(demand) {
                    try await download.download(target: target, destinationURL: file)
                }
            }
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while await scheduler.snapshot().waitingByteTransfers != 1 {
            try #require(ContinuousClock.now < deadline); try await Task.sleep(for: .milliseconds(10))
        }
        demand.promote(to: .interactive)
        try await queued.value
        #expect(try Data(contentsOf: file) == Data("abcdefghij".utf8))
        #expect(demand.observerCount == 0)
        let state = await scheduler.snapshot()
        #expect(state.activeDownloads == 1 && state.waitingByteTransfers == 0)
        _ = await scheduler.release(occupied)
        await scheduler.closeAndDrain()
    }

    @Test func nativeForegroundUploadAndDownloadShareDirectionalAndTotalLimits() async throws {
        let session = session(); defer { session.invalidateAndCancel() }
        let root = FileManager.default.temporaryDirectory.appending(path: "mixed-native-bytes-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "upload-source")
        try Data("file".utf8).write(to: source)
        let scheduler = V2AccountWorkScheduler()
        let upload = V2URLSessionResourcePlanExecutor(session: session, scheduler: scheduler)
        let download = V2URLSessionMediaByteTransfer(session: session, scheduler: scheduler)
        let plan = try V2ResourceTransferPlan(mode: .httpPut, url: #require(URL(string: "https://provider.invalid/blackhole")), expiresAt: .now.addingTimeInterval(60), expectedByteCount: 4)
        let target = try target(path: "blackhole")
        var tasks: [Task<Void, any Error>] = []
        for index in 0..<3 {
            tasks.append(Task { try await upload.upload(fileURL: source, plan: plan) })
            tasks.append(Task { try await download.download(target: target, destinationURL: root.appending(path: "download-\(index)")) })
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while true {
            let state = await scheduler.snapshot()
            if state.activeUploads == 2 && state.activeDownloads == 2 && state.waitingByteTransfers == 2 { break }
            try #require(ContinuousClock.now < deadline); await Task.yield()
        }
        for task in tasks { task.cancel() }
        for task in tasks {
            await #expect(throws: CancellationError.self) { try await task.value }
        }
        let drained = await scheduler.snapshot()
        #expect(drained.active == 0 && drained.waiting == 0)
        await scheduler.closeAndDrain()
    }

    @Test func foregroundAutomaticDownloadKeepsItsScopePriorityAndUserReservation() async throws {
        let session = session(); defer { session.invalidateAndCancel() }
        let root = FileManager.default.temporaryDirectory.appending(path: "priority-native-bytes-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let scheduler = V2AccountWorkScheduler(), target = try target(path: "blackhole")
        let download = V2URLSessionMediaByteTransfer(session: session, scheduler: scheduler)
        let first = Task {
            try await V2NetworkWorkScope.$context.withValue(.init(service: "resources", priority: .background)) {
                try await download.download(target: target, destinationURL: root.appending(path: "automatic-1"))
            }
        }
        let second = Task {
            try await V2NetworkWorkScope.$context.withValue(.init(service: "resources", priority: .background)) {
                try await download.download(target: target, destinationURL: root.appending(path: "automatic-2"))
            }
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while await scheduler.snapshot().waitingByteTransfers != 1 {
            try #require(ContinuousClock.now < deadline); await Task.yield()
        }
        let user = Task { try await download.download(target: target, destinationURL: root.appending(path: "user")) }
        while await scheduler.snapshot().activeDownloads != 2 {
            try #require(ContinuousClock.now < deadline); await Task.yield()
        }
        let admitted = await scheduler.snapshot()
        #expect(admitted.activeBackgroundTransfers == 1 && admitted.waitingByteTransfers == 1)
        for task in [first, second, user] { task.cancel() }
        for task in [first, second, user] { await #expect(throws: CancellationError.self) { try await task.value } }
        #expect(await scheduler.snapshot().active == 0)
        await scheduler.closeAndDrain()
    }
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NativeRangeProtocol.self]
        return URLSession(configuration: configuration)
    }
    private func target(path:String = "range",expiry:Date = .now.addingTimeInterval(60)) throws -> V2ClientMediaTransferTarget {
        let bytes = Data("abcdefghij".utf8)
        return try .init(downloadPlan: .init(mode:.httpGet,url:URL(string:"https://provider.invalid/\(path)")!,expiresAt:expiry,expectedByteCount:10,checksum:.init(value:SHA256.hash(data:bytes).map { String(format:"%02x",$0) }.joined())))
    }
    @Test func native206StreamAndCancelledTaskReleasePhysicalBytePermit() async throws {
        let session = session(); defer { session.invalidateAndCancel() }
        let root = FileManager.default.temporaryDirectory.appending(path:"native-range-\(UUID())")
        defer { try? FileManager.default.removeItem(at:root) }
        let scheduler = V2AccountWorkScheduler()
        let diagnostics = V2NetworkDiagnostics()
        let transfer = V2URLSessionMediaByteTransfer(session:session,scheduler:scheduler, diagnostics:diagnostics)
        try await transfer.download(target:target(),destinationURL:root.appending(path:"verified"))
        #expect(try Data(contentsOf:root.appending(path:"verified")) == Data("abcdefghij".utf8))
        #expect(await scheduler.snapshot().active == 0)
        await #expect(throws: V2RangeDownloadError.invalidRange) {
            try await transfer.download(target: target(path: "invalid-range"), destinationURL: root.appending(path: "invalid"))
        }
        #expect(await scheduler.snapshot().active == 0)
        let blockedTarget = try target(path:"blackhole")
        let task = Task { try await transfer.download(target:blockedTarget,destinationURL:root.appending(path:"cancelled")) }
        try await Task.sleep(for:.milliseconds(20)); task.cancel()
        do { try await task.value; Issue.record("must cancel") } catch is CancellationError {}
        #expect(await scheduler.snapshot().active == 0)
        #expect(!FileManager.default.fileExists(atPath:root.appending(path:"cancelled").path))
        #expect(diagnostics.snapshot().resources.first?.response == .partialResponse)
        #expect(diagnostics.snapshot().resources.last?.cancelled == true)
        #expect(diagnostics.snapshot().resources.allSatisfy { $0.bodyBytesSent >= 0 && $0.bodyBytesReceived >= 0 })
    }
    @Test func uploadDropsBoundedResponseAndDrainsCancellation() async throws {
        let session = session(); defer { session.invalidateAndCancel() }
        let directory = FileManager.default.temporaryDirectory.appending(path:"native-upload-\(UUID())")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let file = directory.appending(path:"source")
        try Data("file".utf8).write(to:file); defer { try? FileManager.default.removeItem(at:directory) }
        let scheduler = V2AccountWorkScheduler()
        let diagnostics = V2NetworkDiagnostics()
        let executor = V2URLSessionResourcePlanExecutor(session:session,scheduler:scheduler,diagnostics:diagnostics)
        let success = try V2ResourceTransferPlan(mode:.httpPut,url:URL(string:"https://provider.invalid/upload")!,expiresAt:.now.addingTimeInterval(60),expectedByteCount:4)
        try await executor.upload(fileURL:file,plan:success)
        #expect(diagnostics.snapshot().resources.last?.mode == .upload)
        #expect(diagnostics.snapshot().resources.last?.response == .successStatus)
        let part = try V2ResourceTransferPlan(mode:.httpPartPut,url:success.url,expiresAt:success.expiresAt,
            expectedByteCount:2,byteRange:.init(lowerBound:1,upperBound:2),partNumber:1)
        await #expect(throws: V2ClientMediaTransferError.byteCountMismatch) { try await executor.upload(fileURL: file, plan: part) }
        let slice = directory.appending(path: "prepared-part")
        try Data("il".utf8).write(to: slice)
        try await V2NetworkWorkScope.$context.withValue(.init(service:"mediaProvider",isRetry:true)) {
            try await executor.upload(fileURL:slice,plan:part)
        }
        #expect(diagnostics.snapshot().resources.last?.mode == .multipartUpload)
        #expect(diagnostics.snapshot().resources.last?.retryAttempt == true)

        #expect(await scheduler.snapshot().active == 0)
        let tooLarge = try V2ResourceTransferPlan(mode:.httpPut,url:URL(string:"https://provider.invalid/large-upload-response")!,expiresAt:.now.addingTimeInterval(60),expectedByteCount:4)
        await #expect(throws:V2RangeDownloadError.responseTooLarge) { try await executor.upload(fileURL:file,plan:tooLarge) }
        #expect(await scheduler.snapshot().active == 0)
        let blocked = try V2ResourceTransferPlan(mode:.httpPut,url:URL(string:"https://provider.invalid/blackhole")!,expiresAt:.now.addingTimeInterval(60),expectedByteCount:4)
        let task = Task { try await executor.upload(fileURL:file,plan:blocked) }
        try await Task.sleep(for:.milliseconds(20)); task.cancel()
        do { try await task.value; Issue.record("must cancel") } catch is CancellationError {}
        #expect(await scheduler.snapshot().active == 0)
    }
    @Test func nativeRangeResponseStagesAndRetryScopeAreObservedAtCompletion() async throws {
        let session = session(); defer { session.invalidateAndCancel() }
        let diagnostics = V2NetworkDiagnostics()
        let transport = V2URLSessionRangeDownloadTransport(session:session, diagnostics:diagnostics)
        for (path,status) in [("full-response",200),("unsatisfied",416)] {
            var request = URLRequest(url:URL(string:"https://provider.invalid/\(path)?signature=secret")!)
            request.setValue("bytes=2-5",forHTTPHeaderField:"Range")
            let transfer = try await V2NetworkWorkScope.$context.withValue(.init(service:"mediaProvider",isRetry:true)) {
                try await transport.stream(request, maximumBytes:20, receiveResponse:{ response in
                    #expect(response.statusCode == status)
                }, consume:{ _ in })
            }
            transfer.record()
        }
        #expect(diagnostics.snapshot().resources.map(\.response) == [.fullResponseForRange,.rangeUnsatisfied])
        #expect(diagnostics.snapshot().resources.allSatisfy { $0.retryAttempt && !$0.failed })
    }
}
private final class NativeRangeProtocol: URLProtocol,@unchecked Sendable {
    override class func canInit(with request:URLRequest) -> Bool { true }
    override class func canonicalRequest(for request:URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url?.path != "/blackhole" else { return }
        let bytes:Data
        let response:HTTPURLResponse
        if request.httpMethod == "PUT" {
            bytes = request.url?.path == "/large-upload-response" ? Data(repeating:1,count:600 * 1024) : Data()
            response = HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:[:])!
        } else if request.url?.path.hasPrefix("/rebuild") == true {
            bytes = Data((request.url?.path == "/rebuild-corrupt" ? "abcdefghXX" : "abcdefghij").utf8)
            response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["ETag": request.url?.path == "/rebuild-changed" ? "\"version-2\"" : "\"version-1\""])!
        } else if request.url?.path == "/full-response" || request.url?.path == "/unsatisfied" {
            bytes = Data()
            response = HTTPURLResponse(url:request.url!,statusCode:request.url?.path == "/full-response" ? 200 : 416,httpVersion:nil,headerFields:[:])!
        } else {
            let body = Data("abcdefghij".utf8)
            let range = request.value(forHTTPHeaderField:"Range")!.dropFirst(6).split(separator:"-").map { Int($0)! }
            let start = range[0],end = min(9,range[1])
            bytes = body.subdata(in:start..<end+1)
            response = HTTPURLResponse(url:request.url!,statusCode:206,httpVersion:nil,headerFields:["Content-Range": request.url?.path == "/invalid-range" ? "bytes invalid" : "bytes \(start)-\(end)/10","ETag":"\"native-1\""])!
        }
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        if !bytes.isEmpty { client?.urlProtocol(self,didLoad:bytes) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
