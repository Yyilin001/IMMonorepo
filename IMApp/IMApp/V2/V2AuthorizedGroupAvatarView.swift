import IMV2ClientKit
import IMV2Core
import SwiftUI
import OSLog

/// Rows may reuse a live page-owned grant across tab and sheet transitions.
/// Disk content alone never authorizes display after page exit or revocation.
struct V2AuthorizedGroupAvatarView: View {
    let roomID: RoomID
    var size: CGFloat = 36
    var fallbackTitle: String? = nil
    @Environment(\.v2AvatarPipeline) private var pipeline
    @Environment(\.v2AuthorPresentationPageScope) private var pageScope
    @Environment(\.scenePhase) private var phase
    @Environment(\.displayScale) private var scale
    #if DEBUG
    @Environment(\.v2GroupAvatarDisplayObservation) private var displayObservation
    #endif
    @State private var visible = false
    @State private var snapshotGeneration: UInt64 = 0
    @State private var snapshotRefresh: UInt64 = 0
    @State private var snapshot: V2AvatarPipeline.GroupSnapshot?
    @State private var refresh: UInt64 = 0
    @State private var subscription: InvalidationSubscription?

    private static let logger = Logger(subsystem: "com.stskcxfz.imapp", category: "GroupAvatarDisplay")

    private func trace(_ event: String) {
        #if DEBUG
        print("GroupAvatarDisplay event=\(event) size=\(size) visible=\(visible) pixels=\(snapshot?.image != nil) refresh=\(refresh)")
        #endif
        Self.logger.debug("event=\(event, privacy: .public) size=\(size) visible=\(visible) pixels=\(snapshot?.image != nil) refresh=\(refresh)")
    }

    private var pixels: Int { min(512, max(1, Int(size * scale))) }
    private var displayed: V2AvatarPipeline.GroupSnapshot? {
        guard let pipeline, !pipeline.isSuspending else { return nil }
        if visible, snapshotGeneration == pipeline.generation, snapshotRefresh == refresh,
           let snapshot, snapshot.image != nil, snapshot.deadline > .now { return snapshot }
        return pageScope?.cachedGroup(room: roomID, pixels: pixels, pipeline: pipeline)
    }

    var body: some View {
        Group {
            if let image = displayed?.image {
                Image(uiImage: image.image).resizable().scaledToFill()
            } else {
                V2AvatarPlaceholder(symbol: "person.2.fill", title: fallbackTitle, size: size)
            }
        }
        .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.32))
        #if DEBUG
        .onChange(of: displayed?.image != nil, initial: true) { _, hasImage in
            displayObservation?(size, hasImage)
        }
        #endif
        .accessibilityLabel("群头像")
        .accessibilityIdentifier("v2.group.avatar.image")
        .task(id: LoadKey(pipeline: pipeline.map(ObjectIdentifier.init), phase: phase, room: roomID, visible: visible, generation: pipeline?.generation ?? 0, refresh: refresh, page: pageScope?.activation)) {
            trace("load-task-start")
            if displayed == nil { snapshot = nil }
            guard visible, phase == .active, let pipeline, !pipeline.isSuspending else { return }
            pageScope?.prepareGroup(room: roomID, pixels: pixels, pipeline: pipeline)
            await load(pipeline)
        }
        .task(id: subscription?.activation) {
            guard let subscription else { return }
            for await _ in subscription.updates {
                guard !Task.isCancelled, self.subscription?.activation == subscription.activation else { return }
                trace("invalidation")
                snapshot = nil; refresh &+= 1
                return
            }
        }
        .task(id: snapshot?.deadline) {
            guard let deadline = snapshot?.deadline else { return }
            do {
                try await ContinuousClock().sleep(until: deadline)
                try Task.checkCancellation()
                if snapshot?.deadline == deadline { snapshot = nil }
            } catch { }
        }
        .onChange(of: phase) { _, value in
            if value == .active, snapshot.map({ $0.deadline <= .now }) ?? true { refresh &+= 1 }
        }
        .onAppear { trace("appear"); visible = true }
        .v2AvatarVisibility { trace($0 ? "scroll-visible" : "scroll-hidden"); visible = $0; if !$0 { snapshot = nil } }
        .onDisappear { trace("disappear"); visible = false; snapshot = nil }
    }

    private func load(_ pipeline: V2AvatarPipeline) async {
        let generation = pipeline.generation
        let activeRefresh = refresh
        let activation: V2GroupAvatarActivation
        do {
            activation = try await pipeline.groups.activate(roomID: roomID)
            subscription = try await .init(activation: activation, updates: pipeline.groups.invalidations(for: activation))
        }
        catch { return }
        var failures = 0, avatarRetries = V2AvatarRetrySchedule()
        while !Task.isCancelled && failures < 5 {
            guard phase == .active else { break }
            do {
                let value = try await pipeline.groupSnapshot(activation: activation, pixels: min(512, max(1, Int(size * scale))))
                try Task.checkCancellation()
                guard generation == pipeline.generation, activeRefresh == refresh else { break }
                snapshotGeneration = generation; snapshotRefresh = activeRefresh; snapshot = value; failures = 0
                trace("pixels-published")
                if let retry = avatarRetries.next(retryAt: value.avatarRetryAt, deadline: value.deadline), retry < value.deadline {
                    try await ContinuousClock().sleep(until: retry)
                    continue
                }
                try await ContinuousClock().sleep(until: value.deadline)
                avatarRetries = .init()
                snapshot = nil
            } catch is CancellationError { break }
            catch V2GroupAvatarPresentationError.inactive { snapshot = nil; break }
            catch {
                snapshot = nil; failures += 1
                do { try await Task.sleep(for: .seconds(min(30, 1 << failures))) }
                catch { break }
            }
        }
        await pipeline.groups.deactivate(activation)
        if subscription?.activation == activation { subscription = nil }
    }

    private struct LoadKey: Equatable {
        let pipeline: ObjectIdentifier?
        let phase: ScenePhase
        let room: RoomID
        let visible: Bool
        let generation: UInt64
        let refresh: UInt64
        let page: V2ProfilePageActivation?
    }
    private struct InvalidationSubscription {
        let activation: V2GroupAvatarActivation
        let updates: AsyncStream<Void>
    }
}

#if DEBUG
private struct V2GroupAvatarDisplayObservationKey: EnvironmentKey {
    static let defaultValue: (@Sendable (CGFloat, Bool) -> Void)? = nil
}
extension EnvironmentValues {
    /// Observes the actual image/placeholder branch for presentation regression tests.
    var v2GroupAvatarDisplayObservation: (@Sendable (CGFloat, Bool) -> Void)? {
        get { self[V2GroupAvatarDisplayObservationKey.self] }
        set { self[V2GroupAvatarDisplayObservationKey.self] = newValue }
    }
}
#endif
