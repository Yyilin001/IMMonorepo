import MessagingUI
import Observation
import SwiftUI
import IMV2ClientKit
import UIKit

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

/// First-entry pin survives self-sizing and viewport/inset changes. It is
/// relinquished on real user scroll input or explicit history navigation;
/// programmatic geometry notifications cannot accidentally relinquish it.
struct V2MessageTimelineInitialBottomAnchor {
    struct Geometry: Equatable {
        let contentSize: CGSize
        let visibleSize: CGSize
        let bottomInset: CGFloat
        let pointsFromBottom: CGFloat
    }
    private(set) var isActive: Bool
    private var lastCorrection: Geometry?

    init(isActive: Bool = true) { self.isActive = isActive }

    mutating func release() { isActive = false; lastCorrection = nil }

    mutating func needsCorrection(_ geometry: Geometry, hasItems: Bool) -> Bool {
        guard isActive, hasItems, geometry.visibleSize.height > 0,
              geometry.contentSize.height.isFinite, geometry.visibleSize.height.isFinite,
              geometry.pointsFromBottom.isFinite else { return false }
        guard geometry.pointsFromBottom > 1 else { lastCorrection = nil; return false }
        guard lastCorrection != geometry else { return false }
        lastCorrection = geometry
        return true
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

/// Hosting cells own their SwiftUI accessibility and presentation roots.
/// Replacing the entire EnvironmentValues also replaces those private roots,
/// leaving visible message content absent from the accessibility tree.
/// Carry only the page dependencies and public display settings we need.
struct V2MessageTimelineInheritedEnvironment: ViewModifier {
    let source: EnvironmentValues

    @ViewBuilder func body(content: Content) -> some View {
        let inherited = content
            .environment(\.v2AvatarPipeline, source.v2AvatarPipeline)
            .environment(\.v2AuthorPresentationPageScope, source.v2AuthorPresentationPageScope)
            .environment(\.v2MediaThumbnailCache, source.v2MediaThumbnailCache)
            .environment(\.v2UserInteractionContext, source.v2UserInteractionContext)
            .environment(\.v2ResourceManagement, source.v2ResourceManagement)
            .environment(\.v2ResourceNavigation, source.v2ResourceNavigation)
            .environment(\.scenePhase, source.scenePhase)
            .environment(\.displayScale, source.displayScale)
            .environment(\.dynamicTypeSize, source.dynamicTypeSize)
            .environment(\.colorScheme, source.colorScheme)
            .environment(\.layoutDirection, source.layoutDirection)
            .environment(\.locale, source.locale)
            .environment(\.calendar, source.calendar)
            .environment(\.timeZone, source.timeZone)
        #if DEBUG
        inherited.environment(\.v2MockProfileNames, source.v2MockProfileNames)
        #else
        inherited
        #endif
    }
}

struct V2PendingMessageRow: View {
    let pending: V2DurableConversationSendService.Pending
    let retry: () -> Void
    let cancel: () -> Void
    var borrowImage: (@MainActor (UUID) async throws -> V2ResourceFileLease)? = nil

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 6) {
                VStack(alignment: .trailing, spacing: 6) {
                    if !pending.text.isEmpty || (pending.images.isEmpty && pending.total == 0) {
                        Text(pending.text.isEmpty ? "附件" : pending.text)
                    }
                    if !pending.images.isEmpty {
                        ForEach(pending.images, id: \.jobID) { image in
                            V2PendingImagePreview(image: image, borrow: borrowImage)
                        }
                    }
                    ForEach(0..<max(0, pending.total - pending.images.count), id: \.self) { _ in
                        V2ConversationMediaPlaceholder(systemImage: "paperclip")
                            .frame(width: 200, height: 88)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .accessibilityLabel("待发送附件")
                    }
                }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .foregroundStyle(.white)
                    .background(V2VisualStyle.outgoing, in: RoundedRectangle(cornerRadius: 20))
                Text(pending.status).font(.caption).foregroundStyle(.secondary)
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

private struct V2PendingImagePreview: View {
    let image: V2PendingResourceSendSnapshot.LocalImage
    let borrow: (@MainActor (UUID) async throws -> V2ResourceFileLease)?
    @Environment(\.v2MediaThumbnailCache) private var cache
    @State private var thumbnail: UIImage?

    var body: some View {
        VStack(spacing: 6) {
            V2ConversationImageLayout(dimensions: image.dimensions) {
                if let thumbnail {
                    V2ZoomableConversationImage(image: thumbnail)
                } else {
                    V2ConversationMediaPlaceholder()
                }
            }
            .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .accessibilityLabel("待发送图片")
        .task(id: image.jobID) {
            guard let borrow else { return }
            do {
                let lease = try await borrow(image.jobID)
                let result = await cache?.thumbnail(fileURL: lease.fileURL, maximumPixelSize: 2048)
                await lease.release()
                guard !Task.isCancelled else { return }
                thumbnail = result?.image
            } catch { }
        }
    }
}
