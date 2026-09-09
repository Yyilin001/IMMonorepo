import Observation
import SwiftUI

/// Row geometry is transient and bounded by the published window. Only the
/// top visible identity and an explicit restoration request are observed.
@MainActor
@Observable
final class V2ListViewport {
    struct Restoration: Equatable {
        let id = UUID()
        let itemID: String
    }
    struct RowPosition: Equatable {
        let minY: CGFloat
        let maxY: CGFloat
    }
    enum ReadResolution {
        case ready(anchorID: String?)
        case reread
    }
    private(set) var anchorID: String?
    private(set) var restoration: Restoration?
    @ObservationIgnored private var rows: [String: RowPosition] = [:]
    @ObservationIgnored private var rowOwners: [String: UUID] = [:]
    @ObservationIgnored private var allowedIDs = Set<String>()
    @ObservationIgnored private var height: CGFloat = 0

    func reconcile(ids: [String]) {
        allowedIDs = Set(ids)
        rows = rows.filter { allowedIDs.contains($0.key) }
        rowOwners = rowOwners.filter { allowedIDs.contains($0.key) }
        if let anchorID, !allowedIDs.contains(anchorID) { self.anchorID = nil }
        if let restoration, !allowedIDs.contains(restoration.itemID) { self.restoration = nil }
    }

    func resize(height: CGFloat) {
        self.height = height
        updateAnchor()
    }

    func record(id: String, position: RowPosition, ownerID: UUID? = nil) {
        guard allowedIDs.contains(id) else { return }
        rows[id] = position
        rowOwners[id] = ownerID
        updateAnchor()
    }

    func remove(id: String, ownerID: UUID? = nil) {
        guard ownerID == nil || rowOwners[id] == ownerID else { return }
        rows[id] = nil; rowOwners[id] = nil; updateAnchor()
    }

    func containsVisibleRow(_ id: String) -> Bool {
        guard height > 0, let row = rows[id] else { return false }
        return row.maxY > 0 && row.minY < height
    }

    /// Resolve immediately before publishing, with no suspension before the
    /// caller commits. A reader must never restore an obsolete scroll position.
    func resolveRead(capturedAnchorID: String?, returnedIDs: [String], fallback: String?) -> ReadResolution {
        guard anchorID != capturedAnchorID else { return .ready(anchorID: fallback) }
        guard let anchorID else { return .ready(anchorID: nil) }
        return returnedIDs.contains(anchorID) ? .ready(anchorID: anchorID) : .reread
    }

    #if DEBUG
    func layoutDescription(for id: String) -> String {
        "height=\(height), row=\(String(describing: rows[id])), cachedRows=\(rows.count)"
    }
    #endif

    func restore(to id: String?) {
        guard let id, allowedIDs.contains(id), restoration?.itemID != id else { return }
        anchorID = id
        restoration = .init(itemID: id)
    }

    func userDidBeginScrolling() {
        restoration = nil
        updateAnchor()
    }

    /// List can clamp the first scroll against estimated row heights. Allow a
    /// few layout passes, then release ownership even if the view disappears.
    /// The page task owns cancellation; no timer survives its lifetime.
    func performRestoration(_ request: Restoration, scrollTo: (String) -> Void) async {
        await Task.yield()
        for _ in 0..<8 {
            guard !Task.isCancelled, restoration?.id == request.id else { return }
            scrollTo(request.itemID)
            do { try await Task.sleep(for: .milliseconds(20)) }
            catch { return }
            guard !Task.isCancelled, restoration?.id == request.id else { return }
            if containsVisibleRow(request.itemID) { break }
        }
        didRequestRestoration(request)
    }

    func didRequestRestoration(_ request: Restoration) {
        if restoration?.id == request.id { restoration = nil }
    }

    func reset() { rows.removeAll(); rowOwners.removeAll(); allowedIDs.removeAll(); anchorID = nil; restoration = nil }

    private func updateAnchor() {
        guard restoration == nil, height > 0 else { return }
        let top = rows.filter { $0.value.maxY > 0 && $0.value.minY < height }
            .min { lhs, rhs in lhs.value.minY == rhs.value.minY ? lhs.key < rhs.key : lhs.value.minY < rhs.value.minY }
        if let top { anchorID = top.key }
    }
}

struct V2ListViewportRow: ViewModifier {
    @State private var ownerID = UUID()
    let viewport: V2ListViewport
    let itemID: String
    let coordinateSpace: String

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: V2ListViewport.RowPosition.self) { proxy in
                let frame = proxy.frame(in: .named(coordinateSpace))
                return .init(minY: frame.minY, maxY: frame.maxY)
            } action: { viewport.record(id: itemID, position: $0, ownerID: ownerID) }
            .background {
                GeometryReader { proxy in
                    Color.clear.onAppear {
                        // A reused List row may reappear at the same geometry,
                        // so onGeometryChange alone need not emit again.
                        let frame = proxy.frame(in: .named(coordinateSpace))
                        viewport.record(id: itemID, position: .init(minY: frame.minY, maxY: frame.maxY), ownerID: ownerID)
                    }
                }
            }
            .onDisappear { viewport.remove(id: itemID, ownerID: ownerID) }
    }
}

struct V2ListViewportContainer: ViewModifier {
    let viewport: V2ListViewport
    let coordinateSpace: String

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content
                .coordinateSpace(name: coordinateSpace)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewport.resize(height: $0) }
                .onScrollPhaseChange { _, phase in
                    if phase == .tracking || phase == .interacting { viewport.userDidBeginScrolling() }
                }
                .task(id: viewport.restoration?.id) {
                    guard let request = viewport.restoration else { return }
                    await viewport.performRestoration(request) { proxy.scrollTo($0, anchor: .top) }
                }
        }
    }
}
