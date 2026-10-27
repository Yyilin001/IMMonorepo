import Foundation
import IMV2ClientKit
import IMV2Core
import Observation

nonisolated struct V2ResourceRetentionBatchResult: Sendable {
    enum Outcome: Sendable { case changed, unchanged, unavailable, failed(String) }
    let items: [(key: V2ResourceKey, outcome: Outcome)]
    var changedCount: Int { items.filter { if case .changed = $0.outcome { true } else { false } }.count }
    var failedKeys: [V2ResourceKey] { items.compactMap { if case .failed = $0.outcome { $0.key } else { nil } } }
    var skippedCount: Int { items.count - changedCount - failedKeys.count }
    var unavailableCount: Int { items.filter { if case .unavailable = $0.outcome { true } else { false } }.count }
    var unchangedCount: Int { skippedCount - unavailableCount }
    var failures: [String] { Array(Set(items.compactMap { if case .failed(let message) = $0.outcome { message } else { nil } })).sorted() }
}

extension V2ResourceManagementService {
    func setRetained(_ retained: Bool, resources: [V2ResourceKey]) async throws -> V2ResourceRetentionBatchResult {
        guard !resources.isEmpty, resources.count <= 100 else { throw V2ResourceStorageError.invalidRecord }
        var seen = Set<V2ResourceKey>(), items: [(V2ResourceKey, V2ResourceRetentionBatchResult.Outcome)] = []
        for key in resources where seen.insert(key).inserted {
            try Task.checkCancellation()
            do {
                guard let original = try await center.variants(for: key).first(where: { $0.descriptor.key.rendition == .original }) else {
                    items.append((key, .unavailable)); continue
                }
                if original.isRetained == retained { items.append((key, .unchanged)); continue }
                try await center.setRetained(retained, variant: original.descriptor.key)
                items.append((key, .changed))
            } catch is CancellationError { throw CancellationError() }
            catch V2ResourceStorageError.unavailable { items.append((key, .unavailable)) }
            catch V2ResourceStorageError.closed { throw V2ResourceStorageError.closed }
            catch { items.append((key, .failed(V2ResourceFailure.message(error)))) }
        }
        return .init(items: items)
    }
}

@MainActor @Observable
final class V2ResourceSelectionStore {
    struct Command: Equatable {
        enum Action: Equatable {
            case retain(Bool, [V2ResourceKey]), preview([V2ResourceKey]), cleanup(V2ResourceSelectionCleanupPlan)
        }
        let id = UUID()
        let action: Action
    }
    struct CleanupPreview: Identifiable {
        let value: V2ResourceSelectionCleanupPlan
        var id: UUID { value.plan.id }
    }
    let service: V2ResourceManagementService
    private(set) var selected: [V2ResourceKey]? = nil
    private(set) var command: Command?
    private enum CommandState: Equatable { case idle, pending(UUID), running(UUID) }
    private var commandState: CommandState = .idle
    var isBusy: Bool { commandState != .idle }
    private(set) var cleanup: CleanupPreview?
    private(set) var feedback: String?
    private(set) var failureDetails: [String] = []
    @ObservationIgnored private var resetAfterCommand = false
    var isSelecting: Bool { selected != nil }
    init(service: V2ResourceManagementService) { self.service = service }

    func toggleMode() {
        guard !isBusy, cleanup == nil else { return }
        selected = selected == nil ? [] : nil
        feedback = nil; failureDetails = []
    }
    func resetForQueryChange() {
        if isBusy { resetAfterCommand = true; return }
        resetAfterCommand = false
        selected = nil; cleanup = nil; feedback = nil; failureDetails = []
    }
    func toggle(_ key: V2ResourceKey) {
        guard !isBusy, cleanup == nil, var values = selected else { return }
        if let index = values.firstIndex(of: key) { values.remove(at: index) }
        else if values.count < 100 { values.append(key) }
        selected = values
    }
    func selectPage(_ keys: [V2ResourceKey]) {
        guard !isBusy, cleanup == nil, selected != nil else { return }
        var seen = Set<V2ResourceKey>()
        selected = Array(keys.filter { seen.insert($0).inserted }.prefix(100))
    }
    func retain(_ value: Bool) { request { .retain(value, $0) } }
    func previewCleanup() { request { .preview($0) } }
    private func request(_ action: ([V2ResourceKey]) -> Command.Action) {
        guard !isBusy, cleanup == nil, let selected, !selected.isEmpty else { return }
        feedback = nil; failureDetails = []
        let next = Command(action: action(selected))
        commandState = .pending(next.id); command = next
    }
    func dismissCleanup() { if !isBusy { cleanup = nil } }
    func commitCleanup() {
        guard !isBusy, let cleanup else { return }
        let next = Command(action: .cleanup(cleanup.value))
        commandState = .pending(next.id); command = next
    }
    func execute(_ request: Command) async {
        guard command == request, commandState == .pending(request.id) else { return }
        commandState = .running(request.id)
        defer {
            if command == request, commandState == .running(request.id) {
                commandState = .idle
                if resetAfterCommand { resetForQueryChange() }
            }
        }
        do {
            switch request.action {
            case .retain(let value, let resources):
                let result = try await service.setRetained(value, resources: resources)
                try Task.checkCancellation()
                selected = result.failedKeys
                feedback = "已完成 \(result.changedCount.formatted()) 项，跳过 \(result.skippedCount.formatted()) 项，失败 \(result.failedKeys.count.formatted()) 项。"
                failureDetails = result.skippedCount == 0 ? result.failures
                    : ["\(result.unchangedCount.formatted()) 项无需改变状态，\(result.unavailableCount.formatted()) 项当前不可访问。"] + result.failures
            case .preview(let resources):
                let plan = try await service.center.planCleanup(resources: resources)
                try Task.checkCancellation()
                cleanup = .init(value: plan)
            case .cleanup(let preview):
                let result = try await service.center.commitCleanup(preview.plan)
                try Task.checkCancellation()
                cleanup = nil; selected = []
                feedback = "已清理 \(result.deletedCount.formatted()) 个本机文件，释放 \(V2ResourceFormatting.bytes(result.releasedBytes))；跳过 \(result.skippedCount.formatted()) 项，失败 \(result.failedCount.formatted()) 项。"
            }
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled else { return }
            cleanup = nil; feedback = V2ResourceFailure.message(error)
        }
    }
}
