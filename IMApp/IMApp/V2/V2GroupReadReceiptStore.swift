import Foundation
import IMV2ClientKit
import IMV2Core
import Observation

/// Owns one detail page's reader window and the transport being cancelled/drained.
/// Views observe this owner directly; timeline refreshes cannot replace its demand.
@MainActor
@Observable
final class V2GroupReadReceiptStore {
    private let roomID: String
    private let isGroupConversation: Bool
    private let reader: (any V2GroupReadReceiptReading)?
    private(set) var page: V2ReadReceiptReadersPage?
    private(set) var hasEarlierReaders = false
    private(set) var isLoading = false
    private(set) var feedback: String?
    @ObservationIgnored private var messageID: String?
    @ObservationIgnored private var demandID = UUID()
    @ObservationIgnored private var flight: (id: UUID, task: Task<V2ReadReceiptReadersPage, Error>)?

    init(roomID: String, kind: V2ConversationKind, reader: (any V2GroupReadReceiptReading)?) {
        self.roomID = roomID
        self.isGroupConversation = kind.isGroup
        self.reader = reader
    }

    deinit { flight?.task.cancel() }

    func presentationKey(for target: UserID) -> V2ProfileViewLookupKey? {
        guard isGroupConversation, let room = try? RoomID(roomID) else { return nil }
        return .init(userID: target, context: .room(room))
    }

    func loadReaders(for message: V2ConversationMessageItem, reset: Bool = false) async {
        guard isGroupConversation, message.isOutgoing, !message.isWithdrawn,
              let reader, !Task.isCancelled
        else { return }
        let isNewMessage = messageID != message.id
        if !reset, !isNewMessage, page?.nextCursor == nil { return }
        if !reset, !isNewMessage, isLoading { return }
        let demand = UUID()
        demandID = demand
        if reset || isNewMessage {
            messageID = message.id
            page = nil
            feedback = nil
            hasEarlierReaders = false
        }
        // A superseding message/reset owns the next read only after the old
        // transport actually returns. Multiple resets retain only the latest.
        if let previous = flight {
            previous.task.cancel()
            _ = await previous.task.result
            guard !Task.isCancelled, demand == demandID else { return }
        }
        let cursor = reset || isNewMessage ? nil : page?.nextCursor
        let roomID = self.roomID
        let task = Task {
            try Task.checkCancellation()
            return try await reader.readers(roomID: roomID, messageID: message.id, cursor: cursor)
        }
        flight = (demand, task)
        isLoading = true
        defer {
            if flight?.id == demand {
                flight = nil
                isLoading = false
            }
        }
        do {
            let received = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard demand == demandID else { return }
            guard received.roomID.rawValue == roomID, received.messageID.rawValue == message.id,
                  received.readers.count <= 100, received.nextCursor == nil || received.nextCursor != cursor else {
                feedback = "已读详情返回异常，请稍后重试。"
                return
            }
            if reset || isNewMessage {
                messageID = message.id
                page = received
            } else if let existing = page {
                let known = Set(existing.readers.map(\.userID))
                let incoming = Set(received.readers.map(\.userID))
                guard known.isDisjoint(with: incoming) else {
                    feedback = "已读详情返回重复数据，请刷新后重试。"
                    return
                }
                let readers = existing.readers + received.readers
                if readers.count > 1_000 { hasEarlierReaders = true }
                page = try .init(
                    roomID: received.roomID,
                    messageID: received.messageID,
                    readers: Array(readers.suffix(1_000)),
                    nextCursor: received.nextCursor
                )
            }
            feedback = nil
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, demand == demandID else { return }
            feedback = "无法读取已读详情，请检查网络后重试。"
        }
    }

}
