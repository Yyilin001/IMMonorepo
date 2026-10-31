import Foundation
import Observation
import SwiftUI
import IMV2ClientKit
import IMV2Core

/// Each page owns authority; visible rows only borrow interests. A complete
/// per-key revision snapshot survives coalesced repository notifications.
@MainActor @Observable
final class V2AuthorPresentationPageScope {
    enum Context: Hashable {
        case group(RoomID)
        case direct(roomID: RoomID, actorUserID: UserID, peerUserID: UserID)
        /// A selector contributes complete keys without a room-message subscription.
        case list(UUID)

        func key(for userID: UserID) -> V2ProfileViewLookupKey? {
            switch self {
            case .group(let roomID):
                return .init(userID: userID, context: .room(roomID))
            case .direct(let roomID, let actorUserID, let peerUserID):
                guard userID == actorUserID || userID == peerUserID else { return nil }
                return .init(userID: userID, context: .room(roomID))
            case .list: return nil
            }
        }

        func accepts(_ key: V2ProfileViewLookupKey) -> Bool {
            if case .list = self { return true }
            return self.key(for: key.userID) == key
        }

        var authorRoomID: RoomID? {
            switch self {
            case .group(let roomID), .direct(let roomID, _, _): roomID
            case .list: nil
            }
        }
    }

    let context: Context
    private(set) var activation: V2ProfilePageActivation?
    private var revisions: [V2ProfileViewLookupKey: UUID] = [:]
    private var runID: UUID?
    private struct SnapshotKey: Hashable {
        let profile: V2ProfileViewLookupKey
        let pixels: Int?
    }
    private struct CachedSnapshot {
        let value: V2AvatarPipeline.Snapshot
        let generation: UInt64
        let revision: UUID?
        let interest: V2ProfileVisibleInterest
    }
    private var snapshots: [SnapshotKey: CachedSnapshot] = [:]

    init(context: Context) { self.context = context }
    func accepts(_ key: V2ProfileViewLookupKey) -> Bool { context.accepts(key) }
    func revision(for key: V2ProfileViewLookupKey) -> UUID? { revisions[key] }
    func hide() { activation = nil; revisions = [:]; snapshots = [:] }

    /// Synchronous reuse is restricted to this active page and the original
    /// authorization deadline. It never persists a private name or extends a lease.
    func cachedSnapshot(key: V2ProfileViewLookupKey, pixels: Int?, pipeline: V2AvatarPipeline) -> V2AvatarPipeline.Snapshot? {
        guard activation != nil, accepts(key), !pipeline.isSuspending,
              let cached = snapshots[SnapshotKey(profile: key, pixels: pixels)],
              cached.generation == pipeline.generation, cached.revision == revisions[key],
              cached.value.deadline > .now else { return nil }
        return cached.value
    }

    func run(pipeline: V2AvatarPipeline) async {
        let id = UUID(); runID = id
        let active = await pipeline.profiles.activateVisiblePage(delivery: pipeline.authors == nil ? .http : .authorStream)
        do {
            try Task.checkCancellation()
            let updates = try await pipeline.profiles.invalidations(for: active)
            guard runID == id, !Task.isCancelled else { throw CancellationError() }
            activation = active; revisions = [:]; snapshots = [:]
            await withTaskGroup(of: Void.self) { group in
                if let authors = pipeline.authors {
                    let roomID = context.authorRoomID
                    group.addTask { try? await authors.run(messageRoomID: roomID, activation: active) }
                }
                for await _ in updates {
                    if Task.isCancelled || runID != id { break }
                    guard let next = try? await pipeline.profiles.invalidationRevisions(for: active),
                          !Task.isCancelled, runID == id, activation == active else { break }
                    // Retained snapshots observe revocations while admitted.
                    // Their bounded cache interests yield to actual visible rows.
                    revisions = next
                }
                group.cancelAll()
            }
        } catch { }
        if runID == id { hide(); runID = nil }
        await pipeline.profiles.deactivate(active)
    }

    func retain(_ key: V2ProfileViewLookupKey, pipeline: V2AvatarPipeline) async throws -> (V2ProfilePageActivation, V2ProfileVisibleInterest) {
        try Task.checkCancellation()
        guard accepts(key), let activation, let runID else { throw V2ProfilePresentationError.inactive }
        let interest = try await pipeline.profiles.retainVisibleInterest(for: key, activation: activation)
        guard self.activation == activation, self.runID == runID, !Task.isCancelled else {
            await pipeline.profiles.releaseVisibleInterest(interest)
            throw V2ProfilePresentationError.inactive
        }
        return (activation, interest)
    }

    func snapshot(key: V2ProfileViewLookupKey, activation: V2ProfilePageActivation,
                  pipeline: V2AvatarPipeline, pixels: Int?) async throws -> V2AvatarPipeline.Snapshot? {
        guard accepts(key), self.activation == activation, let runID else { throw V2ProfilePresentationError.inactive }
        let revision = revisions[key]
        let value = try await pipeline.snapshot(key: key, activation: activation, pixels: pixels)
        guard self.activation == activation, self.runID == runID, revisions[key] == revision else { return nil }
        let cacheKey = SnapshotKey(profile: key, pixels: pixels)
        if let value {
            let cachedInterest: V2ProfileVisibleInterest?
            do { cachedInterest = try await pipeline.profiles.retainCachedVisibleInterest(for: key, activation: activation) }
            catch V2ProfilePresentationError.overloaded { cachedInterest = nil }
            guard self.activation == activation, self.runID == runID, revisions[key] == revision,
                  !Task.isCancelled else {
                if let cachedInterest { await pipeline.profiles.releaseVisibleInterest(cachedInterest) }
                return nil
            }
            guard let interest = cachedInterest else { return value }
            var removed: [V2ProfileVisibleInterest] = []
            for (key, cached) in snapshots where cached.value.deadline <= .now {
                removed.append(cached.interest)
                snapshots.removeValue(forKey: key)
            }
            if let previous = snapshots.removeValue(forKey: cacheKey) { removed.append(previous.interest) }
            if snapshots.count >= 128,
               let oldest = snapshots.min(by: { $0.value.value.deadline < $1.value.value.deadline })?.key,
               let evicted = snapshots.removeValue(forKey: oldest) { removed.append(evicted.interest) }
            snapshots[cacheKey] = .init(value: value, generation: pipeline.generation, revision: revision, interest: interest)
            for token in removed { await pipeline.profiles.releaseVisibleInterest(token) }
        } else if let previous = snapshots.removeValue(forKey: cacheKey) {
            await pipeline.profiles.releaseVisibleInterest(previous.interest)
        }
        return value
    }
}

private struct V2AuthorPresentationPageScopeKey: EnvironmentKey {
    static let defaultValue: V2AuthorPresentationPageScope? = nil
}
extension EnvironmentValues {
    var v2AuthorPresentationPageScope: V2AuthorPresentationPageScope? {
        get { self[V2AuthorPresentationPageScopeKey.self] }
        set { self[V2AuthorPresentationPageScopeKey.self] = newValue }
    }
}

private struct V2AuthorPresentationPageModifier: ViewModifier {
    @Environment(\.v2AvatarPipeline) private var pipeline
    @Environment(\.v2AuthorPresentationPageScope) private var inheritedScope
    @Environment(\.scenePhase) private var phase
    @State private var scope: V2AuthorPresentationPageScope
    init(context: V2AuthorPresentationPageScope.Context) { _scope = State(initialValue: .init(context: context)) }
    @ViewBuilder
    func body(content: Content) -> some View {
        if case .list = scope.context, let inheritedScope, case .list = inheritedScope.context {
            // The signed-in navigation container owns list authority. A child
            // tab, selector or profile must not replace it with a short-lived
            // activation, otherwise every return starts with placeholders.
            // Complete lookup keys still separate relationship/direct contexts;
            // room author scopes deliberately keep their own lifecycle.
            content
        } else {
        content
            .environment(\.v2AuthorPresentationPageScope, scope)
            .task(id: TaskKey(phase: phase != .background ? .active : .background, generation: pipeline?.generation ?? 0)) {
                scope.hide()
                // All pages contribute to the account connection's foreground
                // view. Backgrounding retires their grants and subscriptions.
                guard phase != .background,
                      let pipeline, !pipeline.isSuspending else { return }
                await scope.run(pipeline: pipeline)
            }
            .onChange(of: phase) { _, value in
                if value == .background { scope.hide() }
            }
            .onDisappear { scope.hide() }
        }
    }
    private struct TaskKey: Equatable { let phase: ScenePhase; let generation: UInt64 }
}
extension View {
    @ViewBuilder
    func authorPresentationPage(context: V2AuthorPresentationPageScope.Context?) -> some View {
        if let context { modifier(V2AuthorPresentationPageModifier(context: context)).id(context) }
        else { self }
    }
}
