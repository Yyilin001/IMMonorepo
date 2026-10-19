import Foundation
import SwiftUI
import Observation
import IMV2ClientKit
import IMV2Core

@MainActor @Observable
final class V2AvatarPipeline {
    private(set) var generation: UInt64 = 0
    private(set) var isSuspending = false
    private var isClosed = false
    struct Snapshot: Sendable {
        let key: V2ProfileViewLookupKey
        let name: String
        let identity: V2PublicIdentity?
        let image: V2SendableImage?
        let deadline: ContinuousClock.Instant
    }
    let profiles: V2ProfilePresentationRepository
    let groups: V2GroupAvatarPresentationRepository
    let authors: V2AuthorPresentationPageCoordinator?
    private let files: V2ForegroundConversationMediaDownloader
    private let thumbnails: V2LocalMediaThumbnailCache
    init(profiles: V2ProfilePresentationRepository, groups: V2GroupAvatarPresentationRepository,
         files: V2ForegroundConversationMediaDownloader, thumbnails: V2LocalMediaThumbnailCache,
         authors: V2AuthorPresentationPageCoordinator? = nil) {
        self.profiles = profiles; self.groups = groups; self.files = files; self.thumbnails = thumbnails
        self.authors = authors
    }
    func snapshot(key: V2ProfileViewLookupKey, activation: V2ProfilePageActivation, pixels: Int?) async throws -> Snapshot? {
        guard !isClosed, !isSuspending else { throw V2ProfilePresentationError.inactive }
        let startedGeneration = generation
        guard let presentation = try await profiles.presentation(for: key, activation: activation),
              let initial = await profiles.cachedSnapshot(for: key, activation: activation),
              initial.presentation == presentation else { return nil }
        var image: V2SendableImage?
        if let access = initial.avatar, let pixels {
            do {
                let file = try await files.avatar(access)
                image = await thumbnails.thumbnail(fileURL: file.fileURL, maximumPixelSize: pixels)
                await files.releaseFile(file.fileURL)
            } catch is CancellationError { throw CancellationError() }
            catch { /* A failed byte capability does not revoke the independent name lease. */ }
        }
        try Task.checkCancellation()
        guard !isClosed, !isSuspending, generation == startedGeneration,
              let current = await profiles.cachedSnapshot(for: key, activation: activation),
              current.presentation.view == initial.presentation.view,
              current.presentation.groupMember == initial.presentation.groupMember,
              current.presentation.contactAlias == initial.presentation.contactAlias,
              current.presentation.lease.contextRevision == initial.presentation.lease.contextRevision,
              initial.deadline > .now else { return nil }
        // Compare immutable content identity, not a rotating signed URL. A
        // concurrent lease extension cannot extend this older decode's deadline.
        if current.avatar?.mediaID != initial.avatar?.mediaID || current.avatar?.variantID != initial.avatar?.variantID
            || current.avatar?.version != initial.avatar?.version || current.avatar?.checksum != initial.avatar?.checksum { image = nil }
        return .init(key: key, name: current.presentation.contactAlias?.remarkName ?? current.presentation.groupMember?.groupNickname ?? current.presentation.view.publicIdentity?.displayName ?? "用户",
                     identity: current.presentation.view.publicIdentity, image: image, deadline: min(initial.deadline, current.deadline))
    }
    struct GroupSnapshot: Sendable {
        let image: V2SendableImage?
        let deadline: ContinuousClock.Instant
    }
    func groupSnapshot(activation: V2GroupAvatarActivation, pixels: Int) async throws -> GroupSnapshot {
        guard !isClosed, !isSuspending else { throw V2GroupAvatarPresentationError.inactive }
        let presentation = try await groups.presentation(for: activation)
        var image: V2SendableImage?
        if let access = presentation.avatar {
            do {
                let file = try await files.avatar(access)
                image = await thumbnails.thumbnail(fileURL: file.fileURL, maximumPixelSize: pixels)
                await files.releaseFile(file.fileURL)
                guard image != nil else { throw V2ClientMediaTransferError.invalidResponse }
            } catch V2ClientMediaTransferError.targetExpired {
                await groups.invalidate(roomID: activation.roomID)
                throw V2ClientMediaTransferError.targetExpired
            }
        }
        try Task.checkCancellation()
        guard !isClosed, let current = try await groups.cachedPresentation(for: activation),
              current.state == presentation.state, current.resourceGeneration == presentation.resourceGeneration,
              current.membershipRevision == presentation.membershipRevision,
              let deadline = try await groups.authorizationDeadline(for: activation) else {
            throw V2GroupAvatarPresentationError.inactive
        }
        return .init(image: image, deadline: deadline)
    }
    func suspend() async {
        guard !isClosed, !isSuspending else { return }
        isSuspending = true
        generation &+= 1
        await authors?.suspend()
        await profiles.endAllActivations()
        await groups.endAllActivations()
        guard !isClosed else { return }
        isSuspending = false
        generation &+= 1
    }
    func close() async {
        isClosed = true
        isSuspending = true
        generation &+= 1
        await authors?.close()
        await profiles.close()
        await groups.close()
    }
}

private struct V2AvatarPipelineKey: EnvironmentKey {
    static let defaultValue: V2AvatarPipeline? = nil
}
extension EnvironmentValues {
    var v2AvatarPipeline: V2AvatarPipeline? {
        get { self[V2AvatarPipelineKey.self] }
        set { self[V2AvatarPipelineKey.self] = newValue }
    }
}

/// Chat rows borrow their page activation; other rows own one. Leaving or
/// backgrounding hides protected pixels before asynchronous cleanup completes.
struct V2AuthorizedAvatarView: View {
    let key: V2ProfileViewLookupKey
    var showsName = false
    var size: CGFloat = 36
    var body: some View { V2AuthorizedProfileView(key: key, appearance: .avatar(size: size, showsName: showsName)) }
}

struct V2AuthorizedProfileNameView: View {
    let key: V2ProfileViewLookupKey
    var placeholder = "用户"
    var body: some View { V2AuthorizedProfileView(key: key, appearance: .name, placeholder: placeholder) }
}

struct V2AuthorizedPublicHandleView: View {
    let key: V2ProfileViewLookupKey
    var onIdentity: ((V2PublicIdentity?) -> Void)? = nil
    var body: some View { V2AuthorizedProfileView(key: key, appearance: .handle, placeholder: "公开 ID 暂不可用", onIdentity: onIdentity) }
}

private enum V2ProfileAppearance: Equatable {
    case avatar(size: CGFloat, showsName: Bool)
    case name
    case handle
}

private struct V2AuthorizedProfileView: View {
    let key: V2ProfileViewLookupKey
    let appearance: V2ProfileAppearance
    var placeholder = "用户"
    var onIdentity: ((V2PublicIdentity?) -> Void)? = nil
    #if DEBUG
    @Environment(\.v2MockProfileNames) private var mockProfileNames
    #endif
    @Environment(\.v2AvatarPipeline) private var pipeline
    @Environment(\.scenePhase) private var phase
    @Environment(\.displayScale) private var scale
    @Environment(\.v2AuthorPresentationPageScope) private var pageScope
    @State private var snapshotGeneration: UInt64 = 0
    @State private var isVisible = false
    @State private var snapshot: V2AvatarPipeline.Snapshot?
    @State private var refresh: UInt64 = 0
    @State private var snapshotRefresh: UInt64 = 0
    @State private var subscription: InvalidationSubscription?
    @State private var snapshotActivation: V2ProfilePageActivation?
    @State private var snapshotPageRevision: UUID?

    private var sharedPage: V2AuthorPresentationPageScope? {
        guard let pageScope, pageScope.accepts(key) else { return nil }
        return pageScope
    }
    private var requestedPixels: Int? {
        if case .avatar(let size, _) = appearance { min(512, max(1, Int(size * scale))) }
        else { nil }
    }
    private var displaySnapshot: V2AvatarPipeline.Snapshot? {
        guard phase == .active, let pipeline, !pipeline.isSuspending else { return nil }
        if let sharedPage {
            if let cached = sharedPage.cachedSnapshot(key: key, pixels: requestedPixels, pipeline: pipeline) { return cached }
            guard sharedPage.activation != nil, snapshotActivation == sharedPage.activation,
                  snapshotPageRevision == sharedPage.revision(for: key) else { return nil }
        }
        guard isVisible, snapshotGeneration == pipeline.generation, snapshotRefresh == refresh,
              let snapshot, snapshot.key == key, snapshot.deadline > .now else { return nil }
        return snapshot
    }
    private var canDisplay: Bool { displaySnapshot != nil }

    var body: some View {
        VStack(spacing: 3) {
            switch appearance {
            case .avatar(let size, let showsName):
                Group {
                    if canDisplay, let image = displaySnapshot?.image { Image(uiImage: image.image).resizable().scaledToFill() }
                    else { V2AvatarPlaceholder(title: placeholderTitle, size: size) }
                }
                .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.32)).accessibilityHidden(true)
                if showsName { Text(displayName).font(.caption2).lineLimit(1) }
            case .handle:
                Text(canDisplay ? displaySnapshot?.identity?.handle.description ?? placeholder : placeholder)
                    .accessibilityIdentifier("v2.user.public-handle")
            case .name:
                Text(displayName).fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(appearance == .handle ? (canDisplay ? displaySnapshot?.identity?.handle.description ?? placeholder : placeholder) : displayName)
        .task(id: TaskKey(key: key, phase: phase, generation: pipeline?.generation ?? 0, visible: isVisible, refresh: refresh,
                          activation: sharedPage?.activation, pageRevision: sharedPage?.revision(for: key), appearance: appearance)) {
            // A restarted task may still own a valid presentation. Do not blank
            // it while the replacement read is in flight; canDisplay continues
            // to enforce expiry, generation and page-revision boundaries.
            if !canDisplay { snapshot = nil }
            guard phase == .active, isVisible, let pipeline, !pipeline.isSuspending else { return }
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
        .onChange(of: phase) { _, newPhase in
            if newPhase != .active { snapshot = nil; if let pipeline { Task { await pipeline.suspend() } } }
        }
        .onChange(of: canDisplay ? displaySnapshot?.identity : nil) { _, identity in onIdentity?(identity) }
        .onAppear { isVisible = true }
        .onScrollVisibilityChange(threshold: 0.1) { isVisible = $0; if !$0 { snapshot = nil } }
        .onDisappear { isVisible = false; snapshot = nil }
    }
    private var placeholderTitle: String? {
        #if DEBUG
        if let name = mockProfileNames[key.userID.rawValue] { return name }
        #endif
        return canDisplay ? displaySnapshot?.name : nil
    }
    private var displayName: String {
        #if DEBUG
        if let name = mockProfileNames[key.userID.rawValue] { return name }
        #endif
        return canDisplay ? displaySnapshot?.name ?? placeholder : placeholder
    }
    private func load(_ pipeline: V2AvatarPipeline) async {
        let activeGeneration = pipeline.generation, activeRefresh = refresh
        let page = sharedPage, pageRevision = page?.revision(for: key)
        let activation: V2ProfilePageActivation
        let interest: V2ProfileVisibleInterest?
        if let page {
            guard let borrowed = try? await page.retain(key, pipeline: pipeline) else { return }
            activation = borrowed.0; interest = borrowed.1
        } else {
            activation = await pipeline.profiles.activate(); interest = nil
            do {
                subscription = try await .init(activation: activation, updates: pipeline.profiles.invalidations(for: activation))
            } catch { await pipeline.profiles.deactivate(activation); return }
        }
        var failures = 0
        while !Task.isCancelled && failures < 5 {
            do {
                let pixels: Int? = if case .avatar(let size, _) = appearance { min(512, max(1, Int(size * scale))) } else { nil }
                let value: V2AvatarPipeline.Snapshot?
                if let page { value = try await page.snapshot(key: key, activation: activation, pipeline: pipeline, pixels: pixels) }
                else { value = try await pipeline.snapshot(key: key, activation: activation, pixels: pixels) }
                try Task.checkCancellation()
                guard activeGeneration == pipeline.generation, activeRefresh == refresh,
                      page == nil || (page?.activation == activation && page?.revision(for: key) == pageRevision) else { break }
                snapshotGeneration = activeGeneration; snapshotRefresh = activeRefresh
                snapshotActivation = page == nil ? nil : activation; snapshotPageRevision = pageRevision
                snapshot = value; failures = 0
                if let deadline = value?.deadline { try await ContinuousClock().sleep(until: deadline) }
                else { try await Task.sleep(for: .seconds(30)) }
                snapshot = nil
            } catch is CancellationError { break }
            catch V2ProfilePresentationError.inactive { snapshot = nil; break }
            catch V2ProfilePresentationError.throttled(let retryAfter) {
                snapshot = nil
                let delay = retryAfter.isFinite ? min(315_576_000, max(0.1, retryAfter)) : 1
                do { try await Task.sleep(for: .seconds(delay)) } catch { break }
            }
            catch {
                snapshot = nil; failures += 1
                do { try await Task.sleep(for: .seconds(min(30, 1 << failures))) } catch { break }
            }
        }
        if let interest { await pipeline.profiles.releaseVisibleInterest(interest) }
        else { await pipeline.profiles.deactivate(activation) }
        if subscription?.activation == activation { subscription = nil }
    }
    private struct TaskKey: Equatable {
        let key: V2ProfileViewLookupKey; let phase: ScenePhase; let generation: UInt64; let visible: Bool; let refresh: UInt64
        let activation: V2ProfilePageActivation?; let pageRevision: UUID?
        let appearance: V2ProfileAppearance
    }
    private struct InvalidationSubscription {
        let activation: V2ProfilePageActivation
        let updates: AsyncStream<Void>
    }
}
