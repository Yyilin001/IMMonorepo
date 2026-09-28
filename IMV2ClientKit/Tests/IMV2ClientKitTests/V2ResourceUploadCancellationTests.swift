import Foundation
import IMV2Core
import Testing
@testable import IMV2ClientKit

struct V2ResourceUploadCancellationTests {
    @Test("resource upload cancellation stops each business stage and retains the recoverable journal", arguments: [-1, 0, 1, 2, 3, 4])
    func cancellationBoundary(stage: Int) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try GRDBV2LocalSyncStore(databaseURL: directory.appendingPathComponent("db.sqlite"), installationBinding: .init(value: UUID()), userID: .init(uuid:UUID()))
        let id = UUID(), room = RoomID(uuid: UUID())
        let file = directory.appendingPathComponent(id.uuidString)
        try Data("abc".utf8).write(to: file)
        let input = try V2ResourceUploadRequest(operationID: .init(uuid: UUID()), mediaID: .init(uuid: UUID()),
            usage: .messageAttachment(room), contentType: "text/plain", byteCount: 3,
            checksum: .init(value: V2ResourceFileDigest.sha256(fileURL: file, expectedByteCount: 3)))
        let control = try CancellingResourceUpload(stage: stage, input: input, room: room)
        let engine = V2ResourceTransferEngine(store: store, control: control, executor: control, directory: directory)
        do {
            _ = try await engine.prepare(id: id, request: input)
            let work = Task {
                if stage == -1 { withUnsafeCurrentTask { $0?.cancel() } }
                for _ in 0..<5 {
                    let job = try await engine.resume(id: id)
                    if job.retryAt > Date() { try await Task.sleep(for: .seconds(job.retryAt.timeIntervalSinceNow)) }
                }
                return try await engine.resume(id: id)
            }
            await #expect(throws: CancellationError.self) { try await work.value }
            #expect(await control.calls == Array(["create", "target", "transfer", "finalize", "status"].prefix(stage + 1)))
            let saved = try #require(try await store.resourceTransfer(id: id))
            #expect(saved.request == input && saved.stage != .ready)
            #expect(!saved.cancellationRequested)
            #expect(try Data(contentsOf: file) == Data("abc".utf8))
            #expect(try await store.resourceSendPayloads().isEmpty)
            await engine.close()
            try await store.close()
        } catch { await engine.close(); try? await store.close(); throw error }
    }
}

private actor CancellingResourceUpload: V2ResourceUploadControlling, V2ResourcePlanExecuting {
    let stage: Int
    let input: V2ResourceUploadRequest
    let created: V2ResourceUploadSession
    private(set) var calls: [String] = []

    init(stage: Int, input: V2ResourceUploadRequest, room: RoomID) throws {
        self.stage = stage; self.input = input
        created = try .init(locator: .init(home: .room(room), sessionID: .init(uuid: UUID())),
            mediaID: input.mediaID, generation: 1, state: .created, resourceState: .pending,
            expiresAt: Date().addingTimeInterval(600))
    }

    private func record(_ name: String) {
        let index = calls.count
        calls.append(name)
        if index == stage { withUnsafeCurrentTask { $0?.cancel() } }
    }

    func create(_ request: V2ResourceUploadRequest) -> V2ResourceUploadSession {
        #expect(request == input)
        record("create")
        return created
    }

    func target(_ session: V2ResourceUploadSession) throws -> V2ResourceTransferPlan? {
        #expect(session == created)
        record("target")
        return try V2ResourceTransferPlan(mode: .httpPut, url: #require(URL(string: "https://resource.invalid/upload")),
            expiresAt: created.expiresAt, expectedByteCount: input.byteCount, checksum: input.checksum)
    }

    func upload(fileURL: URL, plan: V2ResourceTransferPlan) throws {
        #expect(try Data(contentsOf: fileURL) == Data("abc".utf8))
        #expect(plan.checksum == input.checksum)
        record("transfer")
    }

    func finalize(_ session: V2ResourceUploadSession) throws -> V2ResourceUploadSession {
        #expect(session == created)
        record("finalize")
        return try .init(locator: created.locator, mediaID: input.mediaID, generation: 1,
            state: .completed, resourceState: .scanning, expiresAt: created.expiresAt)
    }

    func status(_ locator: V2ResourceUploadLocator) throws -> V2ResourceUploadSession {
        #expect(locator == created.locator)
        record("status")
        return try .init(locator: locator, mediaID: input.mediaID, generation: 1,
            state: .completed, resourceState: .ready, expiresAt: created.expiresAt,
            bindableUntil: created.expiresAt)
    }

    func cancel(_ session: V2ResourceUploadSession) throws -> V2ResourceUploadSession {
        Issue.record("local task cancellation must not fabricate a remote cancellation request")
        throw V2ResourceJournalError.conflict
    }
}
