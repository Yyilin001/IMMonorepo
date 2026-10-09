import IMV2ClientKit
import IMV2Core
import SwiftUI

/// Pixels are visible only within the current scene, row activation and lease.
/// Content may remain on disk; that cache never authorizes a later page entry.
struct V2AuthorizedGroupAvatarView: View {
    let roomID: RoomID
    var size: CGFloat = 36
    var fallbackTitle: String? = nil
    @Environment(\.v2AvatarPipeline) private var pipeline
    @Environment(\.scenePhase) private var phase
    @Environment(\.displayScale) private var scale
    @State private var visible = false
    @State private var snapshotGeneration: UInt64 = 0
    @State private var snapshotRefresh: UInt64 = 0
    @State private var snapshot: V2AvatarPipeline.GroupSnapshot?
    @State private var refresh: UInt64 = 0
    @State private var subscription: InvalidationSubscription?

    var body: some View {
        Group {
            if visible, phase == .active, snapshotGeneration == pipeline?.generation, snapshotRefresh == refresh, let image = snapshot?.image {
                Image(uiImage: image.image).resizable().scaledToFill()
            } else {
                V2AvatarPlaceholder(symbol: "person.2.fill", title: fallbackTitle, size: size)
            }
        }
        .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.32))
        .accessibilityLabel("群头像")
        .accessibilityIdentifier("v2.group.avatar.image")
        .task(id: LoadKey(room: roomID, visible: visible, phase: phase, generation: pipeline?.generation ?? 0, refresh: refresh)) {
            snapshot = nil
            guard visible, phase == .active, let pipeline, !pipeline.isSuspending else { return }
            await load(pipeline)
        }
        .task(id: subscription?.activation) {
            guard let subscription else { return }
            for await _ in subscription.updates {
                guard !Task.isCancelled, self.subscription?.activation == subscription.activation else { return }
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
            if value != .active { snapshot = nil; if let pipeline { Task { await pipeline.suspend() } } }
        }
        .onAppear { visible = true }
        .onScrollVisibilityChange(threshold: 0.1) { visible = $0; if !$0 { snapshot = nil } }
        .onDisappear { visible = false; snapshot = nil }
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
        var failures = 0
        while !Task.isCancelled && failures < 5 {
            do {
                let value = try await pipeline.groupSnapshot(activation: activation, pixels: min(512, max(1, Int(size * scale))))
                try Task.checkCancellation()
                guard generation == pipeline.generation, activeRefresh == refresh else { break }
                snapshotGeneration = generation; snapshotRefresh = activeRefresh; snapshot = value; failures = 0
                try await ContinuousClock().sleep(until: value.deadline)
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
        let room: RoomID
        let visible: Bool
        let phase: ScenePhase
        let generation: UInt64
        let refresh: UInt64
    }
    private struct InvalidationSubscription {
        let activation: V2GroupAvatarActivation
        let updates: AsyncStream<Void>
    }
}
