import Foundation
import Observation
import SwiftUI
import IMV2ClientKit
import IMV2Core

/// The chat page owns authority; visible rows only borrow interests. A complete
/// per-key revision snapshot survives coalesced repository notifications.
@MainActor @Observable
final class V2AuthorPresentationPageScope {
    enum Context: Hashable {
        case group(RoomID)
        case direct(roomID: RoomID, actorUserID: UserID, peerUserID: UserID)
        /// A selector has independently scoped keys and never opens author push.
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

    init(context: Context) { self.context = context }
    func accepts(_ key: V2ProfileViewLookupKey) -> Bool { context.accepts(key) }
    func revision(for key: V2ProfileViewLookupKey) -> UUID? { revisions[key] }
    func hide() { activation = nil; revisions = [:] }

    func run(pipeline: V2AvatarPipeline) async {
        let id = UUID(); runID = id
        let active = await pipeline.profiles.activateVisiblePage()
        do {
            try Task.checkCancellation()
            let updates = try await pipeline.profiles.invalidations(for: active)
            guard runID == id, !Task.isCancelled else { throw CancellationError() }
            activation = active; revisions = [:]
            await withTaskGroup(of: Void.self) { group in
                if let roomID = context.authorRoomID, let authors = pipeline.authors {
                    group.addTask { try? await authors.run(roomID: roomID, activation: active) }
                }
                for await _ in updates {
                    if Task.isCancelled || runID != id { break }
                    guard let next = try? await pipeline.profiles.invalidationRevisions(for: active),
                          !Task.isCancelled, runID == id, activation == active else { break }
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
    @Environment(\.scenePhase) private var phase
    @State private var scope: V2AuthorPresentationPageScope
    init(context: V2AuthorPresentationPageScope.Context) { _scope = State(initialValue: .init(context: context)) }
    func body(content: Content) -> some View {
        content
            .environment(\.v2AuthorPresentationPageScope, scope)
            .task(id: TaskKey(phase: phase, generation: pipeline?.generation ?? 0)) {
                scope.hide()
                guard phase == .active, let pipeline, !pipeline.isSuspending else { return }
                await scope.run(pipeline: pipeline)
            }
            .onChange(of: phase) { _, value in if value != .active { scope.hide() } }
            .onDisappear { scope.hide() }
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
