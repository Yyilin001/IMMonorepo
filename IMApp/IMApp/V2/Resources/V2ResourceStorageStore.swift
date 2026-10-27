import Foundation
import IMV2ClientKit
import IMV2Core
import Observation

@MainActor @Observable
final class V2ResourceStorageStore {
    // Observation can suppress repeated publications of identical storage
    // facts, including a failed read that preserves the same prior snapshot.
    enum Content: Equatable {
        case initial
        case available(V2ResourceStorageSnapshot)
        case failed(previous: V2ResourceStorageSnapshot?, message: String)
        var snapshot: V2ResourceStorageSnapshot? {
            switch self { case .initial: nil; case .available(let value): value; case .failed(let value, _): value }
        }
    }
    enum Cleanup {
        case idle, planning
        case preview(V2ResourceCleanupPlan), committing(V2ResourceCleanupPlan)
        case finished(V2ResourceCleanupResult), failed(String)
        var plan: V2ResourceCleanupPlan? {
            switch self { case .preview(let value), .committing(let value): value; default: nil }
        }
        var isCommitting: Bool { if case .committing = self { true } else { false } }
    }
    struct Command: Equatable {
        enum Action: Equatable { case plan, commit(V2ResourceCleanupPlan), policy(Int64), network(V2ResourceDownloadNetworkPreferences), planRetention, releaseRetention(V2ResourceUnavailableRetentionPlan) }
        let id = UUID()
        let action: Action
    }
    let service: V2ResourceManagementService
    private(set) var content: Content = .initial
    private(set) var cleanup: Cleanup = .idle
    private(set) var command: Command?
    private enum CommandState: Equatable {
        case idle, pending(UUID), running(UUID)
    }
    private var commandState: CommandState = .idle
    var isBusy: Bool { commandState != .idle }
    var isUpdatingPolicy: Bool {
        guard isBusy else { return false }
        if case .policy? = command?.action { return true }
        return false
    }
    private(set) var policyMessage: String?
    private(set) var downloadNetworkPreferences: V2ResourceDownloadNetworkPreferences?
    var isUpdatingNetwork: Bool {
        guard isBusy else { return false }
        if case .network? = command?.action { return true }
        return false
    }
    private(set) var networkMessage: String?
    private(set) var retentionPlan: V2ResourceUnavailableRetentionPlan?
    var isManagingRetention: Bool {
        guard isBusy else { return false }
        switch command?.action {
        case .planRetention?, .releaseRetention?: return true
        default: return false
        }
    }
    private(set) var retentionMessage: String?
    init(service: V2ResourceManagementService) { self.service = service }

    func observe(reconcile: Bool = true) async {
        let changes = await service.changes()
        await reload(reconcile: reconcile)
        for await change in changes {
            guard !Task.isCancelled else { return }
            if change.scopes.contains(.resources) { await reload() }
        }
    }
    func reload(reconcile: Bool = false) async {
        do {
            let value = try await service.center.storageSnapshot(reconcile: reconcile)
            let network = try await service.center.downloadNetworkPreferences()
            guard !Task.isCancelled else { return }
            content = .available(value)
            downloadNetworkPreferences = network
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled else { return }
            content = .failed(previous: content.snapshot, message: V2ResourceFailure.message(error))
        }
    }
    func previewCleanup() {
        guard !isBusy else { return }
        enqueue(.plan)
    }
    func commitCleanup() {
        guard !isBusy, case .preview(let plan) = cleanup else { return }
        enqueue(.commit(plan))
    }
    func dismissCleanup() {
        // SwiftUI also writes nil after a completed sheet is removed. That
        // acknowledgement must not erase the actual result shown underneath.
        if case .preview = cleanup { cleanup = .idle }
    }
    func changeCacheLimit(_ bytes: Int64) {
        guard !isBusy else { return }
        enqueue(.policy(bytes))
    }
    func changeDownloadNetwork(_ value: V2ResourceDownloadNetworkPreferences) {
        guard !isBusy else { return }
        networkMessage = nil
        enqueue(.network(value))
    }
    func changeAutomaticCategory(_ category: V2ResourceCategory, enabled: Bool) {
        guard var value = downloadNetworkPreferences else { return }
        var categories = value.automaticDownloads.categories
        if enabled { categories.insert(category) } else { categories.remove(category) }
        guard let policy = try? V2ResourceAutomaticDownloadPolicy(categories: categories, maximumByteCount: value.automaticDownloads.maximumByteCount) else { return }
        value.automaticDownloads = policy
        changeDownloadNetwork(value)
    }
    func changeAutomaticLimit(_ bytes: Int64) {
        guard var value = downloadNetworkPreferences,
              let policy = try? V2ResourceAutomaticDownloadPolicy(categories: value.automaticDownloads.categories, maximumByteCount: bytes) else { return }
        value.automaticDownloads = policy
        changeDownloadNetwork(value)
    }
    func execute(_ request: Command) async {
        guard commandState == .pending(request.id), request == command else { return }
        commandState = .running(request.id)
        defer { commandState = .idle }
        do {
            switch request.action {
            case .planRetention:
                let plan = try await service.center.planUnavailableRetentionRelease()
                try Task.checkCancellation()
                guard request == command else { return }
                if plan.count == 0 { retentionMessage = "没有需要解除保留的失效资源。" }
                else { retentionPlan = plan }
            case .releaseRetention(let plan):
                let result = try await service.center.releaseUnavailableRetention(plan)
                try Task.checkCancellation()
                guard request == command else { return }
                retentionMessage = "已解除 \(result.releasedCount) 项保留，跳过 \(result.skippedCount) 项。可继续预览并清理缓存。"
            case .network(let value):
                try await service.center.setDownloadNetworkPreferences(value)
                try Task.checkCancellation()
                guard request == command else { return }
                networkMessage = "下载网络设置已更新。"
            case .plan:
                cleanup = .planning
                let plan = try await service.center.planCleanup()
                try Task.checkCancellation()
                guard request == command else { return }
                cleanup = .preview(plan)
            case .commit(let plan):
                cleanup = .committing(plan)
                let result = try await service.center.commitCleanup(plan)
                try Task.checkCancellation()
                guard request == command else { return }
                cleanup = .finished(result)
            case .policy(let bytes):
                guard let snapshot = content.snapshot else { return }
                policyMessage = nil
                let old = snapshot.quota.policy
                let policy = try V2ResourceStoragePolicy(maximumCacheBytes: bytes, maximumOriginalBytes: old.maximumOriginalBytes,
                    maximumTemporaryBytes: old.maximumTemporaryBytes, maximumManagedBytes: old.maximumManagedBytes,
                    minimumFreeBytes: old.minimumFreeBytes, retainedWarningBytes: old.retainedWarningBytes)
                _ = try await service.center.setStoragePolicy(policy)
                try Task.checkCancellation()
                guard request == command else { return }
                policyMessage = "缓存额度已更新。"
            }
            await reload()
        } catch is CancellationError {
            switch request.action {
            case .plan, .commit: cleanup = .failed("操作已中断，请重新预览可清理内容。")
            default: break
            }
        }
        catch {
            guard !Task.isCancelled, request == command else { return }
            if case .planRetention = request.action { retentionMessage = V2ResourceFailure.message(error) }
            else if case .releaseRetention = request.action { retentionMessage = V2ResourceFailure.message(error) }
            else if case .network = request.action { networkMessage = V2ResourceFailure.message(error) }
            else if case .policy = request.action { policyMessage = V2ResourceFailure.message(error) }
            else { cleanup = .failed(V2ResourceFailure.message(error)) }
        }
    }

    private func enqueue(_ action: Command.Action) {
        let next = Command(action: action)
        command = next
        commandState = .pending(next.id)
    }

    func previewUnavailableRetention() {
        guard !isBusy, retentionPlan == nil else { return }
        retentionMessage = nil
        enqueue(.planRetention)
    }

    func dismissUnavailableRetention() { retentionPlan = nil }

    func releaseUnavailableRetention() {
        guard !isBusy, let plan = retentionPlan else { return }
        retentionPlan = nil
        enqueue(.releaseRetention(plan))
    }
}
