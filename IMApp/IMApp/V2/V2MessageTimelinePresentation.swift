import MessagingUI
import Observation
import SwiftUI

enum V2MessageTimelineRow: Hashable, Identifiable {
    case committed(V2ConversationTimelineItem)
    case pending(V2DurableConversationSendService.Pending)
    var id: String {
        switch self {
        case .committed(let item): item.id
        case .pending(let item): "pending-" + item.id.uuidString
        }
    }
}

/// Adapts committed timeline snapshots without replacing the renderer's identity.
/// MessagingUI computes inserts, removals and edits, preserving the visible anchor.
@MainActor @Observable
final class V2MessageTimelinePresentation {
    struct Snapshot: Equatable {
        let timeline: [V2ConversationTimelineItem]
        let pending: [V2DurableConversationSendService.Pending]
    }

    private(set) var dataSource = ListDataSource<V2MessageTimelineRow>()
    private(set) var hasInvalidSnapshot = false

    @discardableResult
    func apply(_ items: [V2ConversationTimelineItem], pending: [V2DurableConversationSendService.Pending] = []) -> Bool {
        do {
            let rows = Self.merge(items, pending: pending)
            // Validate before mutating the live renderer, including duplicate IDs.
            guard Set(rows.map(\.id)).count == rows.count else {
                hasInvalidSnapshot = true
                return false
            }
            let old = Array(dataSource.items)
            let difference = rows.map(\.id).difference(from: old.map(\.id))
            var removed: [String] = []
            var inserted: [Int] = []
            for change in difference {
                switch change {
                case .remove(_, let id, _): removed.append(id)
                case .insert(let offset, _, _): inserted.append(offset)
                }
            }
            inserted.sort()
            // A send acknowledgement removes the pending row and inserts the
            // committed row. Publish that handoff in ONE collection transaction:
            // a separate remove can otherwise discard the visible bottom anchor.
            if !removed.isEmpty, let first = inserted.first,
               inserted == Array(first..<(first + inserted.count)) {
                let oldByID = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
                let removedIDs = Set(removed)
                dataSource.applyTransaction(
                    removeIDs: removed,
                    insertAt: first,
                    insertedItems: inserted.map { rows[$0] },
                    updatedItems: rows.filter { row in
                        !removedIDs.contains(row.id) && oldByID[row.id].map { $0 != row } == true
                    }
                )
            } else {
                try dataSource.applyValidated(rows)
            }
            hasInvalidSnapshot = false
            return true
        } catch {
            // Keep the last coherent list instead of partially publishing bad IDs.
            hasInvalidSnapshot = true
            return false
        }
    }

    private static func merge(_ items: [V2ConversationTimelineItem], pending: [V2DurableConversationSendService.Pending]) -> [V2MessageTimelineRow] {
        let pending = pending.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        var result: [V2MessageTimelineRow] = []
        result.reserveCapacity(items.count + pending.count)
        var next = 0
        // Server timeline order remains authoritative even across clock changes.
        // Local sends are inserted by their frozen creation time, independent of
        // failure status or the journal's active/terminal pagination priority.
        for item in items {
            let timestamp: Date = switch item {
            case .message(let message, _): message.createdAt
            case .activity(let activity): activity.createdAt
            }
            while next < pending.count && pending[next].createdAt <= timestamp {
                result.append(.pending(pending[next]))
                next += 1
            }
            result.append(.committed(item))
        }
        result.append(contentsOf: pending[next...].map(V2MessageTimelineRow.pending))
        return result
    }

}

/// UICollectionView hosting cells start a new SwiftUI root. Carry the page's
/// profile authority, scene phase and interaction context across that boundary.
struct V2MessageTimelineEnvironment<Content: View>: View {
    @Environment(\.self) private var environment
    @ViewBuilder let content: (EnvironmentValues) -> Content

    var body: some View { content(environment) }
}

struct V2PendingMessageRow: View {
    let pending: V2DurableConversationSendService.Pending
    let retry: () -> Void
    let cancel: () -> Void

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 6) {
                Text(pending.text.isEmpty ? "附件" : pending.text)
                    .padding(14)
                    .foregroundStyle(.white)
                    .background(V2VisualStyle.outgoing, in: RoundedRectangle(cornerRadius: 20))
                Text(pending.status).font(.caption).foregroundStyle(.secondary)
                if pending.total > 0 {
                    ProgressView(value: Double(pending.completed), total: Double(pending.total))
                        .accessibilityLabel("附件已准备 \(pending.completed)/\(pending.total)")
                }
                if pending.canRetry || pending.canCancel {
                    HStack {
                        if pending.canRetry { Button(pending.retryTitle, action: retry) }
                        if pending.canCancel { Button("取消", action: cancel) }
                    }.font(.caption).buttonStyle(.bordered)
                }
            }
        }
        .accessibilityIdentifier("v2.message.pending.\(pending.id.uuidString)")
    }
}
