import Foundation
import IMClientKit

@MainActor
extension ConversationRuntimeController {
    func markConversationReadIfSelectedUpToLatestLoadedSequence(for conversationID: String) async {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty,
              imConversationStore.selectedConversationID == trimmedConversationID
        else {
            return
        }

        await markConversationReadUpToLatestLoadedSequence(for: trimmedConversationID)
    }

    func markConversationReadInternal(
        conversationID: String,
        readSequence: UInt64,
        debounceNanoseconds: UInt64 = HistoryConfig.readReportDebounceNanoseconds
    ) async {
        guard let trimmedConversationID = enqueueConversationReadReport(
            for: conversationID,
            readSequence: readSequence,
            debounceNanoseconds: debounceNanoseconds
        ) else {
            return
        }

        guard debounceNanoseconds == 0 else {
            return
        }

        await flushConversationReadReport(for: trimmedConversationID)
    }

    func enqueueConversationReadReport(
        for conversationID: String,
        readSequence: UInt64,
        debounceNanoseconds: UInt64
    ) -> String? {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return nil
        }

        let currentServerReadSequence = imConversationStore.serverLastReadSequence(for: trimmedConversationID) ?? 0
        let nextReadSequence = max(
            readSequence,
            pendingIMConversationReadSequences[trimmedConversationID] ?? 0
        )
        guard nextReadSequence > currentServerReadSequence else {
            return nil
        }

        pendingIMConversationReadSequences[trimmedConversationID] = nextReadSequence
        imConversationReadReportTasks[trimmedConversationID]?.cancel()

        guard debounceNanoseconds > 0 else {
            imConversationReadReportTasks[trimmedConversationID] = nil
            return trimmedConversationID
        }

        imConversationReadReportTasks[trimmedConversationID] = Task { [weak self] in
            guard let self else {
                return
            }

            try? await Task.sleep(nanoseconds: debounceNanoseconds)

            guard !Task.isCancelled else {
                return
            }

            await self.flushConversationReadReport(for: trimmedConversationID)
        }

        return trimmedConversationID
    }

    func flushConversationReadReport(for conversationID: String) async {
        let trimmedConversationID = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedConversationID.isEmpty else {
            return
        }

        imConversationReadReportTasks[trimmedConversationID] = nil

        guard let readSequence = pendingIMConversationReadSequences.removeValue(forKey: trimmedConversationID) else {
            return
        }

        do {
            let response = try await sessionClient.markIMConversationRead(
                conversationID: trimmedConversationID,
                readSequence: readSequence
            )
            markServerOnline()
            imConversationStore.applyServerExplicitReadResponse(response)
            scheduleConversationCachePersist()
        } catch {
            await handleIMDataRequestError(error)
        }
    }
}
