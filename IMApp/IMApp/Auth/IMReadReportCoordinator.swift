import Foundation
import IMClientKit

@MainActor
final class IMReadReportCoordinator {
    private weak var runtime: ConversationRuntimeController?
    private var reportTasks: [String: Task<Void, Never>] = [:]
    private var pendingReadSequences: [String: UInt64] = [:]

    init(runtime: ConversationRuntimeController) {
        self.runtime = runtime
    }

    func markIfSelectedUpToLatestLoadedSequence(for conversationID: String) async {
        guard let runtime else {
            return
        }

        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty,
              runtime.imConversationStore.selectedConversationID == trimmedConversationID
        else {
            return
        }

        await markUpToLatestLoadedSequence(for: trimmedConversationID)
    }

    func markUpToLatestLoadedSequence(for conversationID: String) async {
        guard let runtime,
              let readSequence = runtime.imConversationStore.latestLoadedServerSequence(for: conversationID)
        else {
            return
        }

        await mark(
            conversationID: conversationID,
            readSequence: readSequence,
            debounceNanoseconds: 0
        )
    }

    func mark(
        conversationID: String,
        readSequence: UInt64,
        debounceNanoseconds: UInt64 = ConversationRuntimeController.HistoryConfig.readReportDebounceNanoseconds
    ) async {
        guard let trimmedConversationID = enqueue(
            conversationID: conversationID,
            readSequence: readSequence,
            debounceNanoseconds: debounceNanoseconds
        ) else {
            return
        }

        guard debounceNanoseconds == 0 else {
            return
        }

        await flush(for: trimmedConversationID)
    }

    func cancelAll() {
        for task in reportTasks.values {
            task.cancel()
        }
        reportTasks = [:]
        pendingReadSequences = [:]
    }

    private func enqueue(
        conversationID: String,
        readSequence: UInt64,
        debounceNanoseconds: UInt64
    ) -> String? {
        guard let runtime else {
            return nil
        }

        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return nil
        }

        let currentServerReadSequence = runtime.imConversationStore.serverLastReadSequence(for: trimmedConversationID) ?? 0
        let nextReadSequence = max(
            readSequence,
            pendingReadSequences[trimmedConversationID] ?? 0
        )
        guard nextReadSequence > currentServerReadSequence else {
            return nil
        }

        pendingReadSequences[trimmedConversationID] = nextReadSequence
        reportTasks[trimmedConversationID]?.cancel()

        guard debounceNanoseconds > 0 else {
            reportTasks[trimmedConversationID] = nil
            return trimmedConversationID
        }

        reportTasks[trimmedConversationID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: debounceNanoseconds)

            guard !Task.isCancelled else {
                return
            }

            await self?.flush(for: trimmedConversationID)
        }

        return trimmedConversationID
    }

    private func flush(for conversationID: String) async {
        guard let runtime else {
            return
        }

        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return
        }

        reportTasks[trimmedConversationID] = nil

        guard let readSequence = pendingReadSequences.removeValue(forKey: trimmedConversationID) else {
            return
        }

        do {
            let response = try await runtime.sessionClient.markIMConversationRead(
                conversationID: trimmedConversationID,
                readSequence: readSequence
            )
            runtime.markServerOnline()
            runtime.imConversationStore.applyServerExplicitReadResponse(response)
            runtime.scheduleConversationCachePersist()
        } catch {
            await runtime.handleIMDataRequestError(error)
        }
    }
}

@MainActor
extension ConversationRuntimeController {
    func markConversationReadIfSelectedUpToLatestLoadedSequence(for conversationID: String) async {
        await readReportCoordinator.markIfSelectedUpToLatestLoadedSequence(for: conversationID)
    }

    func markConversationReadUpToLatestLoadedSequence(for conversationID: String) async {
        await readReportCoordinator.markUpToLatestLoadedSequence(for: conversationID)
    }

    func markConversationRead(
        conversationID: String,
        readSequence: UInt64,
        debounceNanoseconds: UInt64 = HistoryConfig.readReportDebounceNanoseconds
    ) async {
        await readReportCoordinator.mark(
            conversationID: conversationID,
            readSequence: readSequence,
            debounceNanoseconds: debounceNanoseconds
        )
    }

    func markConversationReadInternal(
        conversationID: String,
        readSequence: UInt64,
        debounceNanoseconds: UInt64 = HistoryConfig.readReportDebounceNanoseconds
    ) async {
        await readReportCoordinator.mark(
            conversationID: conversationID,
            readSequence: readSequence,
            debounceNanoseconds: debounceNanoseconds
        )
    }

    func cancelConversationReadReports() {
        readReportCoordinator.cancelAll()
    }
}
