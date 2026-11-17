import Foundation

import IMV2Core
import IMV2ClientRuntime

struct SharedAttachment: Encodable, Sendable {
    let id: String; let name: String; let contentType: String; let bytes: Int64; let kind: String
    init(_ value: V2MediaPresentation) { id = value.mediaID.rawValue; name = value.resourceDescriptor?.displayName.value ?? "附件"; contentType = value.contentType; bytes = value.byteCount; kind = value.kind.rawValue }
    init(_ value: V2LocalResourceAsset) { id = value.id.value.uuidString; name = value.displayName.value; contentType = value.contentType.value; bytes = value.byteCount; kind = V2MediaPresentation.kind(forContentType: contentType).rawValue }
}
struct SharedTransfer: Encodable, Sendable {
    let id: String; let kind: String; let name: String; let phase: String; let bytes: Int64?; let confirmed: Int64?; let actions: [String]
}
struct SharedResourceView: Encodable, Sendable {
    let draft: SharedAttachment?; let importID: String?; let selected: SharedAttachment?; let roomID: String?; let messageID: String?
    let image: String?; let remainingMilliseconds: Int64; let readID: String?; let chunk: String?
    let transfers: [SharedTransfer]; let failure: String?
}
/// One resource owner for the Android binding. All durable send/download state
/// remains in existing Swift services; staging and display state are ephemeral.
actor SharedMedia {
    private let messages: V2MessageService
    private let createStagingFile: @Sendable (URL) throws -> FileHandle
    private let account: UserID; private let store: GRDBV2LocalSyncStore
    private let resources: V2ResourceCenter; private let uploads: V2ResourceTransferEngine
    private let cache: V2ResourceDownloadCache; private let resolver: SharedMediaResolver
    private let stagingRoot: URL
    private var tasks: [Task<Void,Never>] = []
    private var failure: SharedFailure?
    private var transfers: [V2ManagedResourceTransfer] = []
    private var draft: V2LocalResourceAsset?
    private struct Importing { let id: UUID; let room: RoomID; let name: V2ResourceDisplayName; let type: V2ResourceContentType; let dimensions: V2LocalResourceImageDimensions?; let url: URL; let file: FileHandle; var bytes: Int64 }
    private var importing: Importing?
    private var selected: (V2MediaMessageLocation, V2MediaPresentation)?
    private var preview: (V2ResourceCachedFile, Data, ContinuousClock.Instant)?
    private var reading: (UUID, V2ResourceCachedFile, Int64)?
    init(account: UserID, store: GRDBV2LocalSyncStore, resources: V2ResourceCenter, uploads: V2ResourceTransferEngine, base: URL, http: V2SessionHTTPAuthorization, rangeTransport: any V2RangeDownloadTransport, createStagingFile: @escaping @Sendable (URL) throws -> FileHandle, messages: V2MessageService) async throws {
        self.messages = messages
        self.createStagingFile = createStagingFile
        self.account = account; self.store = store; self.resources = resources; self.uploads = uploads
        let resolver = try SharedMediaResolver(base: base, http: http); self.resolver = resolver
        cache = try await resources.downloadCache(using: .init(targetResolver: resolver, byteTransfer: V2URLSessionMediaByteTransfer(transport: rangeTransport)))
        stagingRoot = await resources.scope.resourceFilesDirectory.resolvingSymlinksInPath().appendingPathComponent("shared-imports", isDirectory: true)
        if !FileManager.default.fileExists(atPath: stagingRoot.path) { try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        let facts = try stagingRoot.resourceValues(forKeys: [.isSymbolicLinkKey,.isDirectoryKey])
        guard facts.isDirectory == true, facts.isSymbolicLink == false, stagingRoot.resolvingSymlinksInPath() == stagingRoot else { throw SharedFailure.storageUnavailable }
        for file in try FileManager.default.contentsOfDirectory(at: stagingRoot, includingPropertiesForKeys: nil) {
            let facts = try file.resourceValues(forKeys: [.isRegularFileKey,.isSymbolicLinkKey])
            guard UUID(uuidString: file.lastPathComponent) != nil, facts.isRegularFile == true, facts.isSymbolicLink == false else { throw SharedFailure.storageUnavailable }
            if let id = UUID(uuidString: file.lastPathComponent), let asset = try await resources.localAsset(.init(id)) {
                guard case .messageDraft = asset.purpose else { throw SharedFailure.storageUnavailable }
                try await resources.discardLocalSelection(asset.id)
            }
            try FileManager.default.removeItem(at: file)
        }
    }
    func start() {
        tasks = [Task { do { try await cache.runRecovery() } catch is CancellationError {} catch { failure = sharedFailure(error) } },
            Task { do { try await store.runResourcePreparation { try await self.handoff() } } catch is CancellationError {} catch { failure = sharedFailure(error) } },
            Task { do { for await value in try await resources.transferSnapshots(for: .init(limit: 50)) {
                switch value { case .available(let page): transfers = page.entries; case .unavailable: failure = .storageUnavailable }
            } } catch is CancellationError {} catch { failure = sharedFailure(error) } }]
    }
    private func handoff() async throws {
        for intent in try await store.duePreparedSendIntents() {
            do { _ = try await store.handOffSendIntent(intent.id) }
            catch is CancellationError { throw CancellationError() }
            catch V2ServerTimeAnchor.Failure.unavailable { try await store.deferPreparedSendIntent(intent.id, consumeAttempt: false) }
            catch { try await store.deferPreparedSendIntent(intent.id) }
        }
        try await uploads.releaseFinishedSources()
    }
    func close() async {
        tasks.forEach { $0.cancel() }; await clear()
        await cache.close()
        for task in tasks { await task.value }; tasks = []
    }
    func clear() async {
        selected = nil; preview = nil; reading = nil
        if let importing { try? importing.file.close(); try? FileManager.default.removeItem(at: importing.url) }; importing = nil
        if let draft { try? await discardSelection(draft) }; draft = nil
    }
    func begin(_ request: SharedRequest, room: RoomID) async throws {
        guard try await store.roomAllowsLocalRead(roomID: room), let name = request.displayName, let type = request.contentType else { throw SharedFailure.invalidInput }
        await clear()
        let id = UUID(); let url = stagingRoot.appendingPathComponent(id.uuidString)
        let display = try V2ResourceDisplayName(name); let content = try V2ResourceContentType(type)
        let dimensions: V2LocalResourceImageDimensions?
        if let width = request.width, let height = request.height { dimensions = try .init(width: width, height: height) } else { dimensions = nil }
        guard stagingRoot.resolvingSymlinksInPath() == stagingRoot else { throw SharedFailure.storageUnavailable }
        let file = try createStagingFile(url)
        importing = .init(id: id, room: room, name: display, type: content, dimensions: dimensions, url: url, file: file, bytes: 0)
    }
    func append(_ request: SharedRequest) throws {
        guard var value = importing, value.id.uuidString == request.intentID, request.offset == value.bytes,
              let encoded = request.data, let data = Data(base64Encoded: encoded), (1...65_536).contains(data.count), value.bytes + Int64(data.count) <= 33_554_432 else { throw SharedFailure.invalidInput }
        try value.file.write(contentsOf: data); value.bytes += Int64(data.count); importing = value
    }
    func finish(_ request: SharedRequest) async throws {
        guard let value = importing, value.id.uuidString == request.intentID, value.bytes > 0, request.offset == value.bytes else { throw SharedFailure.invalidInput }
        try value.file.synchronize(); try value.file.close()
        defer { if draft?.id.value != value.id { try? FileManager.default.removeItem(at: value.url) }; importing = nil }
        draft = try await resources.importLocal(at: value.url, displayName: value.name, contentType: value.type, purpose: .messageDraft(value.room), imageDimensions: value.dimensions, id: .init(value.id), maximumBytes: 33_554_432, maximumSelections: 4)
        // Keep only an empty selection marker until send/discard. On process
        // restart it releases an unsubmitted UI selection, never an upload owner.
        let marker = try FileHandle(forWritingTo: value.url); defer { try? marker.close() }
        try marker.truncate(atOffset: 0); try marker.synchronize()
    }
    private func discardSelection(_ asset: V2LocalResourceAsset) async throws {
        try await resources.discardLocalSelection(asset.id)
        let marker = stagingRoot.appendingPathComponent(asset.id.value.uuidString)
        if FileManager.default.fileExists(atPath: marker.path) { try FileManager.default.removeItem(at: marker) }
    }
    func send(_ request: SharedRequest, room: RoomID) async throws {
        guard let draft, request.intentID == draft.id.value.uuidString, draft.purpose == .messageDraft(room), try await store.roomAllowsLocalRead(roomID: room) else { throw SharedFailure.invalidInput }
        let job = UUID()
        let upload = try V2ResourceUploadRequest(operationID: .init(uuid: job), mediaID: .init(uuid: job), usage: .messageAttachment(room), contentType: draft.contentType.value, byteCount: draft.byteCount, checksum: draft.checksum, clientModes: [.httpPartPut,.httpPut], displayName: draft.displayName, clientImageDimensions: draft.imageDimensions)
        let intent = try V2SendIntent(id: UUID(), roomID: room, clientMessageID: .init(uuid: UUID()), text: request.text ?? "", attachmentJobIDs: [job])
        try await messages.sendPreparedAttachments(intent, resources: [.init(id: job, request: upload, localAssetID: draft.id)], using: uploads)
        try? await discardSelection(draft); self.draft = nil
    }
    private func presentation(_ location: V2MediaMessageLocation, id: MediaID) async throws -> V2MediaPresentation {
        guard try await store.roomAllowsLocalRead(roomID: location.roomID),
              case .found(let window) = try await store.conversationTimelineWindow(in: location.roomID, for: account, around: location.messageID, before: 0, after: 0),
              let message = window.page.messages.first(where: { $0.messageID == location.messageID && !$0.isWithdrawn }),
              let value = message.mediaPresentations.first(where: { $0.mediaID == id }) else { throw SharedFailure.invalidInput }
        return value
    }
    func open(_ request: SharedRequest, room: RoomID) async throws {
        selected = nil; preview = nil; reading = nil
        let location = try V2MediaMessageLocation(roomID: room, messageID: MessageID(request.messageID ?? ""))
        let value = try await presentation(location, id: MediaID(request.mediaID ?? ""))
        selected = (location, value)
    }
    func download() async throws {
        guard let (location,value) = selected, value.byteCount <= 33_554_432 else { throw SharedFailure.invalidInput }
        _ = try await presentation(location, id: value.mediaID)
        _ = try await resources.prepareMessageDownload(mediaID: value.mediaID, message: location)
    }
    func imagePreview() async throws {
        guard let (location,value) = selected, value.kind == .image || value.kind == .animatedImage else { throw SharedFailure.invalidInput }
        let file = try await cache.imagePreview(.init(mediaID: value.mediaID), message: location)
        let lease = try await file.borrowFile()
        do {
            let size = try FileManager.default.attributesOfItem(atPath: lease.fileURL.path)[.size] as? NSNumber
            guard let size, size.intValue <= 2_097_152, let deadline = await resolver.previewDeadlines[value.mediaID], deadline > .now else { throw SharedFailure.invalidInput }
            let data = try Data(contentsOf: lease.fileURL)
            guard selected?.0 == location, selected?.1.mediaID == value.mediaID else { throw CancellationError() }
            _ = try await presentation(location, id: value.mediaID)
            preview = (file, data, deadline); await lease.release()
        } catch { await lease.release(); throw error }
    }
    func beginRead() async throws {
        guard let (location,value) = selected, value.byteCount <= 33_554_432 else { throw SharedFailure.invalidInput }
        _ = try await presentation(location, id: value.mediaID)
        guard let file = try await cache.cachedFile(.init(mediaID: value.mediaID), message: location) else { throw SharedFailure.invalidInput }
        reading = (UUID(), file, 0)
    }
    func read(_ request: SharedRequest) async throws -> String {
        guard let (id,file,offset) = reading, request.intentID == id.uuidString, request.offset == offset, let selected else { throw SharedFailure.invalidInput }
        _ = try await presentation(selected.0, id: selected.1.mediaID)
        let lease = try await file.borrowFile()
        do {
            let input = try FileHandle(forReadingFrom: lease.fileURL); defer { try? input.close() }
            try input.seek(toOffset: UInt64(offset)); let data = try input.read(upToCount: 262_144) ?? Data()
            guard reading?.0 == id, self.selected?.0 == selected.0 else { throw CancellationError() }
            reading = (id,file,offset + Int64(data.count)); await lease.release(); return data.base64EncodedString()
        } catch { await lease.release(); throw error }
    }
    func endRead() { reading = nil }
    func action(_ request: SharedRequest) async throws {
        guard let raw = request.intentID, let value = transfers.first(where: { Self.identity($0.id).1 == raw }), let action = request.action,
              value.actions.contains(where: { $0.rawValue == action }) else { throw SharedFailure.invalidInput }
        switch action {
        case "pause": try await resources.pauseTransfer(value.id)
        case "resume": try await resources.resumeTransfer(value.id)
        case "retry": try await resources.retryTransfer(value.id)
        case "cancel": try await resources.cancelTransfer(value.id)
        case "retryCancellation": try await resources.retryCancellation(value.id)
        default: throw SharedFailure.invalidInput
        }
    }
    func cancelSend(_ id: UUID) async throws {
        guard let intent = try await store.preparingSendIntent(id: id) else { throw SharedFailure.invalidInput }
        try await store.cancelSendIntent(id)
        for job in intent.attachmentJobIDs { try await uploads.cancel(id: job) }
        try await uploads.releaseFinishedSources()
    }
    static func identity(_ id: V2ManagedResourceTransferID) -> (String,String) { switch id { case .upload(let id): ("upload",id.uuidString); case .download(let id): ("download",id.uuidString); case .serverImport(let id): ("import",id.uuidString) } }
    func snapshot(chunk: String? = nil) async -> SharedResourceView {
        if let selected, (try? await presentation(selected.0,id:selected.1.mediaID)) == nil { self.selected = nil; preview = nil; reading = nil }
        var image: String?; var milliseconds: Int64 = 0
        if let preview, preview.2 > .now, let lease = try? await preview.0.borrowFile() {
            await lease.release(); image = preview.1.base64EncodedString()
            let duration = ContinuousClock.now.duration(to: preview.2); milliseconds = max(0,duration.components.seconds*1000 + duration.components.attoseconds/1_000_000_000_000_000)
        } else { preview = nil }
        return .init(draft: draft.map(SharedAttachment.init), importID: importing?.id.uuidString, selected: selected.map { SharedAttachment($0.1) }, roomID: selected?.0.roomID.rawValue, messageID: selected?.0.messageID.rawValue,
            image: image, remainingMilliseconds: milliseconds, readID: reading?.0.uuidString, chunk: chunk, transfers: transfers.map { value in
                let (kind,id) = Self.identity(value.id)
                let phase: String
                switch value.phase { case .waitingRetry: phase = "waitingRetry"; case .requiresAttention: phase = "requiresAttention"; case .failed: phase = "failed"; default: phase = String(describing:value.phase) }
                return .init(id:id,kind:kind,name:value.displayName?.value ?? "资源",phase:phase,bytes:value.totalBytes,confirmed:value.confirmedBytes,actions:value.actions.map(\.rawValue).filter { $0 != "cancelUnbound" })
            }, failure:failure?.rawValue)
    }
}
