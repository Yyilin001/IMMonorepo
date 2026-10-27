import Foundation
import IMV2ClientKit
import IMV2Core
import Observation

@MainActor
final class V2ResourcePresentation: Identifiable {
    enum Purpose: Equatable { case preview, share }
    let id = UUID()
    let purpose: Purpose
    let descriptor: V2ResourceDescriptor
    let lease: V2ConversationMediaFileLease
    init(purpose: Purpose, descriptor: V2ResourceDescriptor, lease: V2ConversationMediaFileLease) {
        self.purpose = purpose; self.descriptor = descriptor; self.lease = lease
    }
}

@MainActor @Observable
final class V2ResourceDetailStore {
    enum Content {
        case initial, available(V2ResourceDetailSnapshot), unavailable(String)
        var snapshot: V2ResourceDetailSnapshot? { if case .available(let value) = self { value } else { nil } }
    }
    struct Command: Equatable {
        enum Action: Equatable { case reload, retained(Bool), download, present(V2ResourcePresentation.Purpose) }
        let id = UUID()
        let action: Action
    }
    let key: V2ResourceKey
    let service: V2ResourceManagementService
    private(set) var content: Content = .initial
    private(set) var sourceCursor: V2ResourceSourceCursor?
    private var loadedSourceCursor: V2ResourceSourceCursor?
    private(set) var readFailure: String?
    var hasCurrentDetails: Bool { content.snapshot != nil && readFailure == nil && loadedSourceCursor == sourceCursor }
    var canGoNextSources: Bool {
        hasCurrentDetails && content.snapshot?.nextSourceCursor != nil
    }
    private(set) var command: Command?
    private enum CommandState: Equatable { case idle, pending(UUID), running(UUID) }
    private var commandState: CommandState = .idle
    var isWorking: Bool { commandState != .idle }
    private(set) var feedback: String?
    var presentation: V2ResourcePresentation?
    private(set) var queuedTransfer: V2ManagedResourceTransferID?
    var original: V2ResourceVariantSnapshot? { content.snapshot?.variants.first { $0.descriptor.key.rendition == .original } }
    init(key: V2ResourceKey, service: V2ResourceManagementService) { self.key = key; self.service = service }

    func observe() async {
        let changes = await service.changes()
        await reload()
        for await change in changes {
            guard !Task.isCancelled else { return }
            if change.scopes.contains(.resources) { await reload() }
        }
    }
    func reload() async {
        let expectedCursor = sourceCursor
        do {
            let value = try await service.center.details(for: key, beforeSources: expectedCursor)
            guard !Task.isCancelled, expectedCursor == sourceCursor else { return }
            readFailure = nil
            if let value { content = .available(value); loadedSourceCursor = expectedCursor }
            else { content = .unavailable("资源或原消息当前不可访问。"); presentation = nil }
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled, expectedCursor == sourceCursor else { return }
            let message = V2ResourceFailure.message(error)
            readFailure = message; feedback = nil; presentation = nil
            switch error {
            case V2ResourceStorageError.closed, V2ResourceStorageError.unavailable,
                 V2ClientResourceDirectoryError.notVisible, V2ClientMediaTransferError.authorizationDenied,
                 V2MediaFileAccessError.unavailable:
                content = .unavailable(message)
            default:
                // Previously read metadata is useful offline, but is never a
                // new access grant. Actions stay disabled until a fresh read.
                if content.snapshot == nil { content = .unavailable(message) }
            }
        }
    }
    func retryRead() {
        guard !isWorking else { return }
        enqueue(.reload)
    }
    func nextSources() {
        guard canGoNextSources, let next = content.snapshot?.nextSourceCursor else { return }
        sourceCursor = next
    }
    func firstSources() { sourceCursor = nil }
    func setRetained(_ value: Bool) {
        guard !isWorking, hasCurrentDetails, original != nil else { return }
        enqueue(.retained(value))
    }
    func present(_ purpose: V2ResourcePresentation.Purpose) {
        guard !isWorking, hasCurrentDetails, presentation == nil, content.snapshot?.sources.isEmpty == false else { return }
        enqueue(.present(purpose))
    }
    func download() {
        guard !isWorking, hasCurrentDetails, original != nil, content.snapshot?.sources.isEmpty == false else { return }
        enqueue(.download)
    }
    private func enqueue(_ action: Command.Action) {
        let next = Command(action: action)
        feedback = nil
        command = next
        commandState = .pending(next.id)
    }
    func execute(_ request: Command) async {
        guard commandState == .pending(request.id), request == command else { return }
        commandState = .running(request.id)
        defer { commandState = .idle }
        do {
            switch request.action {
            case .reload: break
            case .download:
                guard let source = content.snapshot?.sources.first else { throw V2ResourceStorageError.unavailable }
                let transfer = try await service.center.enqueueDownload(key, source: source)
                guard !Task.isCancelled, request == command else { return }
                queuedTransfer = transfer
                feedback = "已保存下载请求，可在传输任务中查看状态或继续处理。"
            case .retained(let retained):
                try await service.center.setRetained(retained, variant: .init(resource: key))
                guard !Task.isCancelled, request == command else { return }
                feedback = retained ? "已保留本机；未下载的文件仍需联网获取。" : "已解除保留，文件可按缓存策略回收。"
            case .present(let purpose):
                guard let snapshot = content.snapshot, let source = snapshot.sources.first else { throw V2ResourceStorageError.unavailable }
                let original = try await service.borrow(key, source: source, contentType: snapshot.descriptor.contentType)
                let lease: V2ConversationMediaFileLease
                if purpose == .share {
                    lease = try await V2LocalMediaShareSheet.prepareLease(original, kind: snapshot.descriptor.kind,
                        contentType: snapshot.descriptor.contentType, displayName: snapshot.descriptor.displayName)
                } else { lease = original }
                guard !Task.isCancelled, request == command else { await lease.release(); return }
                presentation = .init(purpose: purpose, descriptor: snapshot.descriptor, lease: lease)
            }
            await reload()
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled, request == command else { return }
            feedback = V2ResourceFailure.message(error)
        }
    }
}
