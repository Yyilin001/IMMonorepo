import Fluent
import SQLKit
import Vapor

extension IMRealtimeMessageService {
    func preallocateServerSequencesIfNeeded(
        count: Int,
        conversationID: UUID,
        updatedAt: Date,
        on database: any Database
    ) async throws -> [Int]? {
        guard let app, app.sequenceAllocationConfiguration.mode == .block else {
            return nil
        }

        return try await app.sequenceBlockAllocator.nextSequences(
            count: count,
            conversationID: conversationID,
            blockSize: app.sequenceAllocationConfiguration.blockSize,
            updatedAt: updatedAt,
            on: database,
            app: app
        )
    }

    func allocateNextServerSequence(
        conversationID: UUID,
        updatedAt: Date,
        on database: any Database
    ) async throws -> Int {
        let startedAt = Date()
        defer {
            if let app {
                Task {
                    await app.databaseMetrics.record(
                        operation: "conversation_sequence_allocate",
                        durationMillis: max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
                    )
                }
            }
        }
        do {
            return try await ConversationSequenceAllocator(db: database).allocateNextServerSequence(
                conversationID: conversationID,
                updatedAt: updatedAt
            )
        } catch {
            if error is any AbortError {
                throw IMRealtimeMessageError.conversationUnavailable
            }
            throw error
        }
    }
}
