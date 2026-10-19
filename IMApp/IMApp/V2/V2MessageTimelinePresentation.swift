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
    private(set) var dataSource = ListDataSource<V2MessageTimelineRow>()
    private(set) var hasInvalidSnapshot = false

    @discardableResult
    func apply(_ items: [V2ConversationTimelineItem], pending: [V2DurableConversationSendService.Pending] = []) -> Bool {
        do {
            try dataSource.applyValidated(items.map(V2MessageTimelineRow.committed) + pending.map(V2MessageTimelineRow.pending))
            hasInvalidSnapshot = false
            return true
        } catch {
            // Keep the last coherent list instead of partially publishing bad IDs.
            hasInvalidSnapshot = true
            return false
        }
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
