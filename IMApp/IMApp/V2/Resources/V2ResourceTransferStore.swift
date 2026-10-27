import Foundation
import IMV2ClientKit
import Observation

@MainActor @Observable
final class V2ResourceTransferStore {
    struct Query: Equatable { let group: V2ResourceTransferGroup; let before: V2ResourceTransferCursor? }
    struct ObservationID: Equatable { let query: Query; let revision: UInt64 }
    enum Content {
        case initial, available(V2ResourceTransferPage), unavailable
        var page: V2ResourceTransferPage? { if case .available(let page) = self { page } else { nil } }
    }
    struct Command: Equatable {
        let id = UUID()
        let transfer: V2ManagedResourceTransferID
        let action: V2ManagedResourceTransferAction
        let preparation: V2ResourcePreparationCancellationPlan?
        let unbound: V2ResourceUnboundCancellationPlan?
        init(transfer: V2ManagedResourceTransferID, action: V2ManagedResourceTransferAction, preparation: V2ResourcePreparationCancellationPlan? = nil, unbound: V2ResourceUnboundCancellationPlan? = nil) {
            self.transfer = transfer; self.action = action; self.preparation = preparation; self.unbound = unbound
        }
    }
    struct BatchCommand: Equatable {
        let id = UUID()
        let action: V2ResourceTransferBatchAction
        let transfers: [V2ManagedResourceTransferID]
    }
    private(set) var batchSelection: [V2ManagedResourceTransferID]?
    private(set) var batchCommand: BatchCommand?
    private enum Activity { case idle, singlePending(Command), singleRunning(Command), batchPending(BatchCommand), batchRunning(BatchCommand) }
    private var activity: Activity = .idle
    private(set) var batchFailures: [String] = []
    @ObservationIgnored private var resetBatchAfterCommand = false
    var isBatchBusy: Bool {
        switch activity { case .batchPending, .batchRunning: true; default: false }
    }
    var isPerforming: Bool { if case .idle = activity { false } else { true } }
    var performing: V2ManagedResourceTransferID? { if case .singleRunning(let request) = activity { request.transfer } else { nil } }
    let service: V2ResourceManagementService
    var group: V2ResourceTransferGroup = .active {
        didSet { if group != oldValue { previousCursors.removeAll(); before = nil; pageNumber = 1; resetBatchForQueryChange() } }
    }
    private(set) var content: Content = .initial
    private var loadedQuery: Query?
    private var loadedRevision: UInt64?
    private var observationRevision: UInt64 = 0
    private(set) var readFailure: String?
    var observationID: ObservationID { .init(query: query, revision: observationRevision) }
    var hasCurrentPage: Bool { loadedQuery == query && loadedRevision == observationRevision && readFailure == nil && content.page != nil }
    var canBeginBatchSelection: Bool { group == .attention && hasCurrentPage && content.page?.entries.isEmpty == false }
    private(set) var before: V2ResourceTransferCursor?
    private(set) var pageNumber = 1
    @ObservationIgnored private var previousCursors: [V2ResourceTransferCursor?] = []
    private(set) var command: Command?
    private(set) var feedback: String?
    private(set) var cancellationPlan: V2ResourcePreparationCancellationPlan?
    private(set) var unboundCancellationPlan: V2ResourceUnboundCancellationPlan?
    var query: Query { .init(group: group, before: before) }
    var canGoNextPage: Bool { hasCurrentPage && content.page?.nextCursor != nil }
    init(service: V2ResourceManagementService) { self.service = service }

    func observe() async {
        let expected = observationID
        do {
            let stream = try await service.center.transferSnapshots(for: .init(group: expected.query.group, before: expected.query.before))
            for await snapshot in stream {
                guard !Task.isCancelled, expected == observationID else { return }
                switch snapshot {
                case .available(let page):
                    loadedQuery = expected.query; loadedRevision = expected.revision
                    content = .available(page); readFailure = nil
                case .unavailable:
                    failRead("本机传输记录暂不可用，请重新读取。", preserveRows: true)
                }
            }
            guard !Task.isCancelled, expected == observationID else { return }
            failRead("当前账号不可用，请重新连接账号。", preserveRows: false)
        } catch {
            guard !Task.isCancelled, expected == observationID else { return }
            failRead(V2ResourceFailure.message(error), preserveRows: (error as? V2ResourceStorageError) != .closed)
        }
    }
    private func failRead(_ message: String, preserveRows: Bool) {
        readFailure = message
        if !preserveRows || content.page == nil { content = .unavailable }
        if !preserveRows {
            cancellationPlan = nil; unboundCancellationPlan = nil
            resetBatchForQueryChange()
        }
    }
    func retryRead() {
        guard !isPerforming else { return }
        observationRevision &+= 1
    }
    func nextPage() {
        guard canGoNextPage, let cursor = content.page?.nextCursor else { return }
        previousCursors.append(before); before = cursor; pageNumber += 1; resetBatchForQueryChange()
    }
    func previousPage() {
        // Back uses saved history, so it may cancel a page that is still loading.
        guard !previousCursors.isEmpty else { return }
        before = previousCursors.removeLast(); pageNumber -= 1; resetBatchForQueryChange()
    }
    func toggleBatchMode() {
        guard !isPerforming, group == .attention, cancellationPlan == nil, unboundCancellationPlan == nil else { return }
        if batchSelection == nil { guard canBeginBatchSelection else { return }; batchSelection = [] }
        else { batchSelection = nil }
        feedback = nil; batchFailures = []
    }
    func toggleBatchSelection(_ id: V2ManagedResourceTransferID) {
        guard !isPerforming, hasCurrentPage, var values = batchSelection,
              content.page?.entries.contains(where: { $0.id == id }) == true else { return }
        if let index = values.firstIndex(of: id) { values.remove(at: index) }
        else if values.count < 100 { values.append(id) }
        batchSelection = values
    }
    func selectBatchPage() {
        guard !isPerforming, hasCurrentPage, batchSelection != nil else { return }
        batchSelection = Array((content.page?.entries.map(\.id) ?? []).prefix(100))
    }
    func batchEligibleCount(_ action: V2ResourceTransferBatchAction) -> Int {
        guard hasCurrentPage, let selected = batchSelection else { return 0 }
        return content.page?.entries.filter { selected.contains($0.id) && $0.actions.contains(action.capability) }.count ?? 0
    }
    func requestBatch(_ action: V2ResourceTransferBatchAction) {
        guard !isPerforming, hasCurrentPage, let selected = batchSelection, !selected.isEmpty else { return }
        feedback = nil; batchFailures = []
        let request = BatchCommand(action: action, transfers: selected)
        activity = .batchPending(request); batchCommand = request
    }
    func executeBatch(_ request: BatchCommand) async {
        guard case .batchPending(let pending) = activity, pending == request else { return }
        activity = .batchRunning(request)
        defer {
            if case .batchRunning(let running) = activity, running == request {
                activity = .idle
                if resetBatchAfterCommand { resetBatchForQueryChange() }
            }
        }
        do {
            let result = try await service.retryTransfers(request.transfers, action: request.action)
            try Task.checkCancellation()
            batchSelection = result.failedIDs
            feedback = "已请求 \(result.requestedCount.formatted()) 项，跳过 \(result.skippedCount.formatted()) 项，失败 \(result.failedIDs.count.formatted()) 项。"
            batchFailures = result.failures
            if result.skippedCount > 0 { batchFailures.insert("跳过的任务当前不支持此操作，暂停的任务不会自动恢复。", at: 0) }
        } catch is CancellationError { }
        catch { if !Task.isCancelled { feedback = V2ResourceFailure.message(error) } }
    }
    private func resetBatchForQueryChange() {
        if isBatchBusy { resetBatchAfterCommand = true; return }
        resetBatchAfterCommand = false
        batchSelection = nil; batchFailures = []; feedback = nil
    }

    func retry(_ id: V2ManagedResourceTransferID) {
        request(.retry, for: id)
    }
    func retryCancellation(_ id: V2ManagedResourceTransferID) { request(.retryCancellation, for: id) }
    func cancel(_ id: V2ManagedResourceTransferID) {
        request(.cancel, for: id)
    }
    func cancelUnbound(_ id: V2ManagedResourceTransferID) { request(.cancelUnbound, for: id) }
    func dismissUnboundCancellation() { unboundCancellationPlan = nil }
    func confirmUnboundCancellation(_ plan: V2ResourceUnboundCancellationPlan) {
        guard !isPerforming, batchSelection == nil else { return }
        unboundCancellationPlan = nil
        let request = Command(transfer: plan.transfer, action: .cancelUnbound, unbound: plan)
        activity = .singlePending(request); command = request
    }
    func pause(_ id: V2ManagedResourceTransferID) { request(.pause, for: id) }
    func resume(_ id: V2ManagedResourceTransferID) { request(.resume, for: id) }
    func dismissCancellation() { cancellationPlan = nil }
    func confirmCancellation(_ plan: V2ResourcePreparationCancellationPlan) {
        guard !isPerforming, batchSelection == nil else { return }
        cancellationPlan = nil
        let request = Command(transfer: plan.transfer, action: .cancel, preparation: plan)
        activity = .singlePending(request); command = request
    }
    private func request(_ action: V2ManagedResourceTransferAction, for id: V2ManagedResourceTransferID) {
        guard !isPerforming, hasCurrentPage, batchSelection == nil, content.page?.entries.contains(where: { $0.id == id && $0.actions.contains(action) }) == true else { return }
        let request = Command(transfer: id, action: action)
        activity = .singlePending(request); command = request
    }
    func execute(_ request: Command) async {
        guard case .singlePending(let pending) = activity, pending == request, batchSelection == nil else { return }
        activity = .singleRunning(request); feedback = nil
        defer { if case .singleRunning(let running) = activity, running == request { activity = .idle } }
        do {
            switch request.action {
            case .retry: try await service.center.retryTransfer(request.transfer)
            case .retryCancellation: try await service.center.retryCancellation(request.transfer)
            case .cancelUnbound:
                if let plan = request.unbound { try await service.center.cancelUnbound(plan) }
                else {
                    let plan = try await service.center.planUnboundCancellation(request.transfer)
                    guard !Task.isCancelled, command == request else { return }
                    unboundCancellationPlan = plan
                    return
                }
            case .cancel:
                if let plan = request.preparation { try await service.center.cancelPreparation(plan) }
                else if case .download = request.transfer { try await service.center.cancelTransfer(request.transfer) }
                else {
                    let plan = try await service.center.planPreparationCancellation(request.transfer)
                    guard !Task.isCancelled, command == request else { return }
                    cancellationPlan = plan
                    return
                }
            case .pause: try await service.center.pauseTransfer(request.transfer)
            case .resume: try await service.center.resumeTransfer(request.transfer)
            }
            guard !Task.isCancelled, command == request else { return }
            switch request.action {
            case .retry: feedback = "已恢复原任务，将继续确认处理结果。"
            case .retryCancellation: feedback = "已请求继续确认取消，将遵守服务器的重试等待时间。"
            case .cancelUnbound: feedback = "已请求取消任务，正在确认原操作结果。"
            case .cancel: feedback = request.preparation == nil ? "已请求取消，传输停止后会清理断点暂存。" : "已取消待发送消息，正在停止附件准备。"
            case .pause:
                switch request.transfer {
                case .upload: feedback = "上传已请求暂停，原文件会保留。"
                case .serverImport: feedback = "已请求暂停本机跟进，服务器仍可能继续处理。"
                case .download: feedback = "已请求暂停，传输停止后保留断点。"
                }
            case .resume:
                switch request.transfer {
                case .upload: feedback = "已请求继续上传，将先确认原操作。"
                case .serverImport: feedback = "已请求继续跟进，将确认原导入操作。"
                case .download: feedback = "已请求继续下载，将重新确认访问权限。"
                }
            }
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled, command == request else { return }
            feedback = V2ResourceFailure.message(error)
        }
    }
}
