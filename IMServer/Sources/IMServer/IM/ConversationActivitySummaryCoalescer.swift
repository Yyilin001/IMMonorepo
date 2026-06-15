import Fluent
import Foundation
import Vapor

actor ConversationActivitySummaryCoalescer {
    private struct PendingWriteKey: Hashable {
        let conversationID: UUID
        let readModelKey: String
    }

    private struct PendingWrite {
        let key: PendingWriteKey
        let readModelDB: any Database
        let messageServerSequence: Int
        let messagePreview: IMMessagePreviewResponse
        let messageCreatedAt: Date?
        let updatedAt: Date
        let requestCount: Int
    }

    private let app: Application
    private var pendingWrites: [PendingWriteKey: PendingWrite] = [:]
    private var scheduledKeys = Set<PendingWriteKey>()

    init(app: Application) {
        self.app = app
    }

    func enqueue(
        conversationID: UUID,
        messageServerSequence: Int,
        messagePreview: IMMessagePreviewResponse,
        messageCreatedAt: Date?,
        updatedAt: Date,
        readModelDB: any Database,
        readModelKey: String,
        windowMilliseconds: Int
    ) async {
        guard windowMilliseconds > 0 else {
            do {
                try await IMConversationSummaryProjectionService(
                    sourceDB: readModelDB,
                    readModelDB: readModelDB
                ).upsertConversationActivity(
                    conversationID: conversationID,
                    messageServerSequence: messageServerSequence,
                    messagePreview: messagePreview,
                    messageCreatedAt: messageCreatedAt,
                    updatedAt: updatedAt,
                    on: readModelDB
                )
            } catch {
                app.logger.error("Conversation activity summary immediate write failed.", metadata: [
                    "conversation_id": .string(conversationID.uuidString),
                    "message_server_sequence": .stringConvertible(messageServerSequence),
                    "error": .string(String(describing: error))
                ])
            }
            return
        }

        let key = PendingWriteKey(conversationID: conversationID, readModelKey: readModelKey)
        let hadPending = pendingWrites[key] != nil
        if let current = pendingWrites[key],
           current.messageServerSequence > messageServerSequence {
            return
        }

        pendingWrites[key] = PendingWrite(
            key: key,
            readModelDB: readModelDB,
            messageServerSequence: messageServerSequence,
            messagePreview: messagePreview,
            messageCreatedAt: messageCreatedAt,
            updatedAt: updatedAt,
            requestCount: (pendingWrites[key]?.requestCount ?? 0) + 1
        )
        if hadPending {
            await app.conversationDomainEventMetrics.recordSummaryActivityCoalescedReplacement()
        }

        guard scheduledKeys.insert(key).inserted else {
            return
        }

        Task {
            try? await Task.sleep(nanoseconds: UInt64(windowMilliseconds) * 1_000_000)
            await self.flush(key: key)
        }
    }

    private func flush(key: PendingWriteKey) async {
        scheduledKeys.remove(key)
        guard let pending = pendingWrites.removeValue(forKey: key) else {
            return
        }
        let startedAt = Date()
        do {
            try await IMConversationSummaryProjectionService(
                sourceDB: pending.readModelDB,
                readModelDB: pending.readModelDB
            ).upsertConversationActivity(
                conversationID: pending.key.conversationID,
                messageServerSequence: pending.messageServerSequence,
                messagePreview: pending.messagePreview,
                messageCreatedAt: pending.messageCreatedAt,
                updatedAt: pending.updatedAt,
                on: pending.readModelDB
            )
            await app.conversationDomainEventMetrics.recordSummaryActivityCoalescedFlush(
                requestCount: pending.requestCount,
                elapsedMilliseconds: IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: startedAt)
            )
        } catch {
            await app.conversationDomainEventMetrics.recordSummaryActivityCoalescedFlushFailure(
                requestCount: pending.requestCount,
                elapsedMilliseconds: IMRealtimeDeliveryDiagnostics.elapsedMilliseconds(since: startedAt)
            )
            app.logger.error("Conversation activity summary coalesced write failed.", metadata: [
                "conversation_id": .string(pending.key.conversationID.uuidString),
                "read_model_key": .string(pending.key.readModelKey),
                "message_server_sequence": .stringConvertible(pending.messageServerSequence),
                "request_count": .stringConvertible(pending.requestCount),
                "error": .string(String(describing: error))
            ])
        }
    }
}

private struct ConversationActivitySummaryCoalescerStorageKey: StorageKey {
    typealias Value = ConversationActivitySummaryCoalescer
}

extension Application {
    var conversationActivitySummaryCoalescer: ConversationActivitySummaryCoalescer {
        if let coalescer = storage[ConversationActivitySummaryCoalescerStorageKey.self] {
            return coalescer
        }

        let coalescer = ConversationActivitySummaryCoalescer(app: self)
        storage[ConversationActivitySummaryCoalescerStorageKey.self] = coalescer
        return coalescer
    }
}
