import Foundation
import Testing
#if canImport(Network)
import Network
import Synchronization
#endif
@testable import IMV2ClientKit

@Suite("Bounded per-attempt resource transfer observations", .timeLimit(.minutes(1)))
struct V2ResourceTransferProgressTests {
    @Test func uploadAndDownloadWithSameUUIDStaySeparateAndOldResponseCannotEndNextRange() throws {
        let hub = V2ResourceTransferProgressHub(), id = UUID()
        let upload = try hub.begin(transfer: .upload(id), expectedBytes: 10)
        let context = V2ResourceDownloadProgressContext(job: id, hub: hub)
        let first = V2ResourceDownloadProgressRequest(context: context)
        try first.begin(expectedBytes: 4); try first.consume(byteCount: 2)
        upload.report(transferredBytes: 8)
        #expect(hub.snapshot()[.upload(id)]?.transferredBytes == 8)
        #expect(hub.snapshot()[.download(id)]?.transferredBytes == 2)
        first.end()
        let second = V2ResourceDownloadProgressRequest(context: context)
        try second.begin(expectedBytes: 6); try second.consume(byteCount: 3)
        try first.consume(byteCount: 2); first.end()
        #expect(hub.snapshot()[.download(id)]?.transferredBytes == 3)
        #expect(throws: V2ClientMediaTransferError.byteCountMismatch) { try second.consume(byteCount: 4) }
        #expect(hub.snapshot()[.download(id)]?.transferredBytes == 3)
        #expect(throws: V2ResourceStorageError.invalidRecord) { try hub.begin(transfer: .serverImport(id), expectedBytes: 10) }
        second.end(); upload.end(); hub.close()
    }

    @Test func countersAreMonotonicBoundedAndCannotOutliveTheirAttempt() throws {
        let hub = V2ResourceTransferProgressHub(), job = UUID()
        let first = try hub.begin(transfer: .upload(job), expectedBytes: 100)
        first.report(transferredBytes: -1); first.report(transferredBytes: 101)
        #expect(hub.snapshot()[.upload(job)]?.transferredBytes == 0)
        first.report(transferredBytes: 80); first.report(transferredBytes: 50)
        #expect(hub.snapshot()[.upload(job)]?.transferredBytes == 80)
        #expect(throws: V2ResourceStorageError.conflict) { try hub.begin(transfer: .upload(job), expectedBytes: 100) }
        first.end()
        let second = try hub.begin(transfer: .upload(job), expectedBytes: 100)
        first.report(transferredBytes: 100); first.end()
        #expect(hub.snapshot()[.upload(job)]?.attemptID == second.attempt && hub.snapshot()[.upload(job)]?.transferredBytes == 0)
        second.report(transferredBytes: 20)
        #expect(hub.snapshot()[.upload(job)]?.transferredBytes == 20)
        hub.close(); second.report(transferredBytes: 100)
        #expect(hub.snapshot().isEmpty)
        #expect(throws: V2ResourceStorageError.closed) { try hub.begin(transfer: .upload(UUID()), expectedBytes: 1) }
    }

    @Test func callbacksCoalesceWithoutSpawningUnboundedWorkOrRetainingHistory() async throws {
        let hub = V2ResourceTransferProgressHub()
        let reporters = try (0..<4).map { _ in try hub.begin(transfer: .upload(UUID()), expectedBytes: 10_000) }
        #expect(throws: V2ResourceStorageError.capacityExceeded) { try hub.begin(transfer: .upload(UUID()), expectedBytes: 1) }
        for count in 1...10_000 { reporters[0].report(transferredBytes: Int64(count)) }
        #expect(hub.snapshot().count == 4 && hub.snapshot()[reporters[0].transfer]?.transferredBytes == 10_000)
        // Completion leaves at most the single newest pulse. No 10,000-event replay.
        hub.close()
        var iterator = hub.updates.makeAsyncIterator()
        #expect(await iterator.next() != nil)
        #expect(await iterator.next() == nil)
    }

    @Test func accountHubsCannotShareOrRestoreAnotherAccountsAttempt() throws {
        let first = V2ResourceTransferProgressHub(), second = V2ResourceTransferProgressHub(), id = UUID()
        let a = try first.begin(transfer: .upload(id), expectedBytes: 10)
        let b = try second.begin(transfer: .upload(id), expectedBytes: 10)
        a.report(transferredBytes: 9)
        #expect(first.snapshot()[.upload(id)]?.transferredBytes == 9 && second.snapshot()[.upload(id)]?.transferredBytes == 0)
        first.close(); a.end(); b.report(transferredBytes: 4)
        #expect(second.snapshot()[.upload(id)]?.transferredBytes == 4)
        second.close()
    }
}

#if canImport(Network)
extension V2ResourceTransferProgressTests {
    @Test func realURLSessionUploadReportsBytesBeforeHTTPCompletion() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "upload-progress-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "body")
        let size = 128 * 1_024
        try Data(repeating: 0x61, count: size).write(to: file)
        let server = try ProgressHTTPServer(expectedBytes: size)
        let port = try await server.start()
        let session = URLSession(configuration: .ephemeral)
        let hub = V2ResourceTransferProgressHub(), job = UUID()
        let reporter = try hub.begin(transfer: .upload(job), expectedBytes: Int64(size))
        var request = URLRequest(url: try #require(URL(string: "http://127.0.0.1:\(port)/upload")))
        request.httpMethod = "PUT"
        request.setValue(String(size), forHTTPHeaderField: "Content-Length")
        let input = request
        let upload = Task {
            try await V2ResourceTransferProgressScope.$reporter.withValue(reporter) {
                try await V2BoundedFileUpload(session: session).send(input, file: file, deadline: .now.advanced(by: .seconds(10)))
            }
        }
        do {
            let deadline = ContinuousClock.now + .seconds(5)
            while !(await server.receivedBody) || hub.snapshot()[.upload(job)]?.transferredBytes != Int64(size) {
                try #require(ContinuousClock.now < deadline, "Real body counters did not arrive before the server response")
                try await Task.sleep(for: .milliseconds(10))
            }
            // The peer has deliberately not sent any HTTP response yet.
            #expect(hub.snapshot()[.upload(job)]?.transferredBytes == Int64(size))
            try await server.respond()
            #expect(try await upload.value.statusCode == 200)
            reporter.end(); hub.close(); session.invalidateAndCancel()
            await server.stop()
        } catch {
            upload.cancel(); await server.stop(); _ = await upload.result
            reporter.end(); hub.close(); session.invalidateAndCancel()
            throw error
        }
    }
}

private actor ProgressHTTPServer {
    enum Failure: Error { case listener, request, disconnected }
    private let listener: NWListener
    private let expectedBytes: Int
    private var connection: NWConnection?
    private var reader: Task<Void, Never>?
    private(set) var receivedBody = false
    init(expectedBytes: Int) throws {
        listener = try NWListener(using: .tcp, on: .any)
        self.expectedBytes = expectedBytes
    }
    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        return try await withCheckedThrowingContinuation { continuation in
            let pending = Mutex<CheckedContinuation<UInt16, any Error>?>(continuation)
            listener.stateUpdateHandler = { [listener] state in
                let result: Result<UInt16, any Error>
                switch state {
                case .ready: result = listener.port.map { .success($0.rawValue) } ?? .failure(Failure.listener)
                case .failed, .cancelled: result = .failure(Failure.listener)
                default: return
                }
                let waiter = pending.withLock { let old = $0; $0 = nil; return old }
                waiter?.resume(with: result)
            }
            listener.start(queue: .global())
        }
    }
    private func accept(_ candidate: NWConnection) {
        guard connection == nil else { candidate.cancel(); return }
        connection = candidate
        candidate.start(queue: .global())
        reader = Task { await readBody(candidate) }
    }
    private func readBody(_ connection: NWConnection) async {
        do {
            var headers = Data(), bodyBytes = 0, foundHeaders = false
            while bodyBytes < expectedBytes {
                let bytes: Data = try await withCheckedThrowingContinuation { continuation in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, error in
                        if let error { continuation.resume(throwing: error) }
                        else if let data, !data.isEmpty { continuation.resume(returning: data) }
                        else { continuation.resume(throwing: Failure.disconnected) }
                    }
                }
                if foundHeaders { bodyBytes += bytes.count }
                else {
                    headers.append(bytes)
                    if let range = headers.range(of: Data("\r\n\r\n".utf8)) {
                        bodyBytes = headers.count - range.upperBound
                        foundHeaders = true; headers.removeAll()
                    } else if headers.count > 16_384 { throw Failure.request }
                }
            }
            receivedBody = bodyBytes == expectedBytes
        } catch { connection.cancel() }
    }
    func respond() async throws {
        guard receivedBody, let connection else { throw Failure.request }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
                contentContext: .finalMessage, isComplete: true, completion: .contentProcessed {
                    if let error = $0 { continuation.resume(throwing: error) } else { continuation.resume() }
                })
        }
    }
    func stop() async {
        listener.cancel(); connection?.cancel()
        await reader?.value; reader = nil; connection = nil
        listener.stateUpdateHandler = nil; listener.newConnectionHandler = nil
    }
}
#endif
