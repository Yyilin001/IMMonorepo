import CryptoKit
import Foundation
import IMV2ClientKit
import IMV2Core
import Testing
import UIKit
import SwiftUI
import Observation
@testable import IMApp

@MainActor
@Suite("Profile avatar pixels and display authority", .timeLimit(.minutes(1)))
struct V2ProfileAvatarPipelineTests {
    @Test("opening own profile does not revoke the account page's unchanged avatar grant")
    func openingProfileRetainsAccountAvatarGrant() async throws {
        let f = try await ProfilePipelineFixture(relationship: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let thumbnails = V2LocalMediaThumbnailCache(directories: [f.root]), pipeline = f.pipeline(thumbnails)
        let activation = await pipeline.profiles.activate()
        _ = try await pipeline.snapshot(key: f.key, activation: activation, pixels: 64)
        let before = try #require(await pipeline.profiles.cachedSnapshot(for: f.key, activation: activation))
        let profile = await f.reader.value.view
        let service = try ProfileIntentServiceFixture(confirmedProfile: profile)
        let store = V2PublicIdentitySettingsStore(service: service, attachmentStager: nil)
        await store.load()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let appeared = AsyncStream<Void>.makeStream()
        window.rootViewController = UIHostingController(rootView: NavigationStack {
            V2PublicIdentitySettingsView(store: store).onAppear { appeared.continuation.yield(()) }
        }.environment(\.v2AvatarPipeline, pipeline))
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil; store.stopObserving() }
        var iterator = appeared.stream.makeAsyncIterator(); _ = await iterator.next()
        try await Task.sleep(for: .milliseconds(200))
        let after = try #require(await pipeline.profiles.cachedSnapshot(for: f.key, activation: activation))
        #expect(after.deadline == before.deadline)
        #expect(after.presentation.view == before.presentation.view)
        #expect(after.avatar?.mediaID == before.avatar?.mediaID)
        appeared.continuation.finish()
        await pipeline.close(); await thumbnails.close(); try await f.files.close()
    }

    @Test("local display reaches the first UI identity callback during offline page reentry")
    func localFirstPaintAndReentry() async throws {
        let f = try await ProfilePipelineFixture(direct: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let thumbnails = V2LocalMediaThumbnailCache(directories: [f.root]), pipeline = f.pipeline(thumbnails)
        try await pipeline.prepareLocalDisplay()
        let page = await pipeline.profiles.activate()
        _ = try await pipeline.snapshot(key: f.key, activation: page, pixels: nil)
        try await waitForProfilePage { pipeline.localDisplay?.value(for: f.key)?.name == "Original" }
        await pipeline.profiles.deactivate(page)
        await pipeline.profiles.invalidate([f.key])
        await f.reader.setOffline()
        let probe = LocalProfileFirstPaintProbe()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: LocalProfileFirstPaintHost(probe: probe, key: f.key)
            .environment(\.v2AvatarPipeline, pipeline))
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        try await waitForProfilePage { !probe.identities.isEmpty }
        #expect((probe.identities.first ?? nil) == "Original")
        probe.visible = false
        try await Task.sleep(for: .milliseconds(50))
        probe.visible = true
        try await waitForProfilePage { probe.identities.count >= 2 }
        #expect(probe.identities.allSatisfy { $0 == "Original" })
        await pipeline.suspend()
        #expect(pipeline.localDisplay?.value(for: f.key)?.name == "Original")
        await pipeline.close(); await thumbnails.close(); try await f.files.close()
    }

    @Test("renaming updates live identity without an intermediate nil callback")
    func localRenameReplacesContentWithoutBlanking() async throws {
        let f = try await ProfilePipelineFixture(direct: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let thumbnails = V2LocalMediaThumbnailCache(directories: [f.root]), pipeline = f.pipeline(thumbnails)
        try await pipeline.prepareLocalDisplay()
        let page = await pipeline.profiles.activate()
        _ = try await pipeline.snapshot(key: f.key, activation: page, pixels: nil)
        try await waitForProfilePage { pipeline.localDisplay?.value(for: f.key)?.name == "Original" }
        let probe = LocalProfileFirstPaintProbe()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: LocalProfileFirstPaintHost(probe: probe, key: f.key)
            .environment(\.v2AvatarPipeline, pipeline))
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        try await waitForProfilePage { !probe.identities.isEmpty }
        try await f.reader.replaceName()
        await pipeline.profiles.invalidate([f.key])
        let next = await pipeline.profiles.activate()
        _ = try await pipeline.profiles.presentation(for: f.key, activation: next)
        try await waitForProfilePage { (probe.identities.last ?? nil) == "Updated" }
        #expect((probe.identities.first ?? nil) == "Original")
        #expect(probe.identities.allSatisfy { $0 != nil })
        await pipeline.close(); await thumbnails.close(); try await f.files.close()
    }

    @Test("names publish before a suspended avatar decode, then explicit denial removes them")
    func localNamesDoNotWaitForAvatarPixels() async throws {
        let f = try await ProfilePipelineFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let entered = AsyncStream<Void>.makeStream(), gate = ProfileDecodeGate()
        let thumbnails = V2LocalMediaThumbnailCache(directories: [f.root]) { _, _ in
            await gate.wait(entered.continuation); return V2SendableImage(image: UIImage())
        }
        let pipeline = f.pipeline(thumbnails)
        try await pipeline.prepareLocalDisplay()
        let page = await pipeline.profiles.activate()
        let image = Task { try await pipeline.snapshot(key: f.key, activation: page, pixels: 16) }
        var iterator = entered.stream.makeAsyncIterator(); _ = await iterator.next()
        #expect(pipeline.localDisplay?.value(for: f.key)?.name == "Original")
        await gate.release(); _ = try await image.value
        await pipeline.profiles.invalidate([f.key])
        #expect(pipeline.localDisplay?.value(for: f.key)?.name == "Original")
        await f.reader.deny()
        let next = await pipeline.profiles.activate()
        _ = try await pipeline.profiles.presentation(for: f.key, activation: next)
        try await waitForProfilePage { pipeline.localDisplay?.value(for: f.key) == nil }
        await pipeline.close(); await thumbnails.close(); try await f.files.close(); entered.continuation.finish()
    }

    @Test("nested list pages reuse signed-in authority and render cached names on reentry")
    func nestedListReentry() async throws {
        let f = try await ProfilePipelineFixture(direct: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let thumbnails = V2LocalMediaThumbnailCache(directories: [f.root]), pipeline = f.pipeline(thumbnails)
        let probe = ProfileListLifecycleProbe()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView:
            ProfileListLifecycleHost(probe: probe, key: f.key, pipeline: pipeline)
                .environment(\.v2AvatarPipeline, pipeline))
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        try await waitForProfilePage { probe.loadedPages.contains(0) }
        let original = try #require(probe.scopes[0])
        probe.page = 1
        try await waitForProfilePage { probe.loadedPages.contains(1) }
        #expect(probe.scopes[1] === original)
        #expect(probe.initialNames[1] == "Original")
        #expect(await f.reader.calls == 1)
        probe.page = 2
        try await waitForProfilePage { probe.loadedPages.contains(2) }
        #expect(probe.scopes[2] === original)
        #expect(probe.initialNames[2] == "Original")
        let activation = original.activation
        let deadline = try #require(original.cachedSnapshot(key: f.key, pixels: nil, pipeline: pipeline)?.deadline)
        try await waitForProfilePage { probe.displayedIdentityName == "Original" }
        probe.phase = .inactive
        try await waitForProfilePage { probe.observedPhase == .inactive }
        #expect(probe.displayedIdentityName == "Original")
        probe.phase = .background
        try await waitForProfilePage { probe.observedPhase == .background }
        #expect(probe.displayedIdentityName == "Original")
        #expect(original.activation == activation)
        #expect(original.cachedSnapshot(key: f.key, pixels: nil, pipeline: pipeline)?.deadline == deadline)
        #expect(await f.reader.calls == 1)
        probe.phase = .active
        try await waitForProfilePage { probe.observedPhase == .active }
        #expect(probe.displayedIdentityName == "Original")
        #expect(original.activation == activation)
        #expect(original.cachedSnapshot(key: f.key, pixels: nil, pipeline: pipeline)?.name == "Original")
        #expect(original.cachedSnapshot(key: f.key, pixels: nil, pipeline: pipeline)?.deadline == deadline)
        // Sharing must not turn a revoked value into a stale-while-revalidate name.
        await pipeline.profiles.invalidate([f.key])
        try await waitForProfilePage { original.cachedSnapshot(key: f.key, pixels: nil, pipeline: pipeline) == nil }
        await pipeline.suspend()
        #expect(original.cachedSnapshot(key: f.key, pixels: nil, pipeline: pipeline) == nil)
        await pipeline.close(); await thumbnails.close(); try await f.files.close()
    }
    @Test("recipient authorized alias takes precedence over nickname and clears to nickname")
    func aliasDisplay() async throws {
        let f = try await ProfilePipelineFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let thumbnails = V2LocalMediaThumbnailCache(directories: [f.root]), pipeline = f.pipeline(thumbnails)
        try await f.reader.replaceNickname("Room name")
        try await f.reader.replaceAlias("My private name")
        let first = await pipeline.profiles.activate()
        #expect(try await pipeline.snapshot(key: f.key, activation: first, pixels: nil)?.name == "My private name")
        await pipeline.profiles.deactivate(first)
        try await f.reader.replaceAlias(nil)
        let second = await pipeline.profiles.activate()
        #expect(try await pipeline.snapshot(key: f.key, activation: second, pixels: nil)?.name == "Room name")
        await pipeline.close(); await thumbnails.close(); try await f.files.close()
    }

    @Test("an alias replacement during image decode withdraws the old combined result")
    func aliasReplacementDuringDecode() async throws {
        let f = try await ProfilePipelineFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let starts = AsyncStream<Void>.makeStream(), gate = ProfileDecodeGate()
        let thumbnails = V2LocalMediaThumbnailCache(directories: [f.root]) { _, _ in await gate.wait(starts.continuation); return V2SendableImage(image: UIImage()) }
        let pipeline = f.pipeline(thumbnails), first = await pipeline.profiles.activate()
        let decode = Task { try await pipeline.snapshot(key: f.key, activation: first, pixels: 16) }
        var entered = starts.stream.makeAsyncIterator(); _ = await entered.next()
        try await f.reader.replaceAlias("New alias")
        let second = await pipeline.profiles.activate()
        _ = try await pipeline.profiles.presentation(for: f.key, activation: second)
        await gate.release()
        #expect(try await decode.value == nil)
        await pipeline.close(); await thumbnails.close(); try await f.files.close(); starts.continuation.finish()
    }

    @Test("name-only selector rows share authorization, skip byte work and reauthorize after reentry")
    func nameOnlySelector() async throws {
        let f = try await ProfilePipelineFixture(direct: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        // Any accidental download now fails through NoProfileByteIO.
        try FileManager.default.removeItem(at: f.cachedFile)
        let thumbnails = V2LocalMediaThumbnailCache(directories: [f.root]) { _, _ in
            Issue.record("A name-only label must not decode an image")
            return nil
        }
        let pipeline = f.pipeline(thumbnails), scope = V2AuthorPresentationPageScope(context: .list(UUID()))
        let running = Task { await scope.run(pipeline: pipeline) }
        try await waitForProfilePage { scope.activation != nil }
        let a = try await scope.retain(f.key, pipeline: pipeline), b = try await scope.retain(f.key, pipeline: pipeline)
        let first = Task { try await scope.snapshot(key: f.key, activation: a.0, pipeline: pipeline, pixels: nil) }
        let second = Task { try await scope.snapshot(key: f.key, activation: b.0, pipeline: pipeline, pixels: nil) }
        let x = try #require(await first.value), y = try #require(await second.value)
        #expect(x.key == f.key && y.key == f.key)
        #expect(x.name == "Original" && y.name == "Original" && x.image == nil && y.image == nil)
        #expect(await f.reader.calls == 1)
        // A reconstructed row can render immediately without publishing a fake name.
        #expect(scope.cachedSnapshot(key: f.key, pixels: nil, pipeline: pipeline)?.name == "Original")
        #expect(scope.cachedSnapshot(key: f.key, pixels: 64, pipeline: pipeline) == nil)
        // Tab rows disappear, but the parent page retains bounded cache interests.
        for row in [a, b] { await pipeline.profiles.releaseVisibleInterest(row.1) }
        #expect(scope.cachedSnapshot(key: f.key, pixels: nil, pipeline: pipeline)?.name == "Original")
        let returningRow = try await scope.retain(f.key, pipeline: pipeline)
        #expect(scope.cachedSnapshot(key: f.key, pixels: nil, pipeline: pipeline)?.name == "Original")
        await pipeline.profiles.releaseVisibleInterest(returningRow.1)
        // Hidden-tab changes must still revoke the cached presentation.
        await pipeline.profiles.invalidate([f.key])
        try await waitForProfilePage { scope.cachedSnapshot(key: f.key, pixels: nil, pipeline: pipeline) == nil }
        scope.hide()
        #expect(scope.cachedSnapshot(key: f.key, pixels: nil, pipeline: pipeline) == nil)
        running.cancel(); await running.value
        await f.reader.deny()
        let reentered = Task { await scope.run(pipeline: pipeline) }
        try await waitForProfilePage { scope.activation != nil }
        let c = try await scope.retain(f.key, pipeline: pipeline)
        #expect(try await scope.snapshot(key: f.key, activation: c.0, pipeline: pipeline, pixels: nil) == nil)
        #expect(await f.reader.calls == 2)
        await pipeline.profiles.releaseVisibleInterest(c.1)
        scope.hide(); reentered.cancel(); await reentered.value
        await pipeline.close(); await thumbnails.close(); try await f.files.close()
    }

    @Test("a verified cached PNG still requires fresh page authorization")
    func cachedBytesNeedFreshAccess() async throws {
        let f = try await ProfilePipelineFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let thumbnails = V2LocalMediaThumbnailCache(directories: [f.root]), pipeline = f.pipeline(thumbnails)
        let first = await pipeline.profiles.activate()
        let value = try #require(await pipeline.snapshot(key: f.key, activation: first, pixels: 16))
        #expect(value.name == "Original" && value.image?.image.cgImage?.width == 16)
        await pipeline.profiles.deactivate(first)
        await f.reader.deny()
        let second = await pipeline.profiles.activate()
        #expect(try await pipeline.snapshot(key: f.key, activation: second, pixels: 16) == nil)
        #expect(FileManager.default.fileExists(atPath: f.cachedFile.path))
        await pipeline.close(); await thumbnails.close(); try await f.files.close()
    }

    @Test("a delayed image decode cannot cross profile invalidation, suspension or close", arguments: ["invalidate", "suspend", "close"])
    func lateDecode(boundary: String) async throws {
        let f = try await ProfilePipelineFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let starts = AsyncStream<Void>.makeStream(), gate = ProfileDecodeGate()
        let image = V2SendableImage(image: UIImage())
        let thumbnails = V2LocalMediaThumbnailCache(directories: [f.root]) { _, _ in
            await gate.wait(starts.continuation); return image
        }
        let pipeline = f.pipeline(thumbnails), activation = await pipeline.profiles.activate()
        let task = Task { try await pipeline.snapshot(key: f.key, activation: activation, pixels: 16) }
        var entered = starts.stream.makeAsyncIterator(); _ = await entered.next()
        switch boundary {
        case "invalidate": await pipeline.profiles.invalidate([f.key])
        case "suspend": await pipeline.suspend()
        default: await pipeline.close()
        }
        await gate.release()
        #expect(try await task.value == nil)
        await pipeline.close(); await thumbnails.close(); try await f.files.close(); starts.continuation.finish()
    }

    @Test("newer profile or nickname data during decoding cannot be combined with the old name and image", arguments: [false, true])
    func replacementDuringDecode(nicknameOnly: Bool) async throws {
        let f = try await ProfilePipelineFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let starts = AsyncStream<Void>.makeStream(), gate = ProfileDecodeGate()
        let image = V2SendableImage(image: UIImage())
        let thumbnails = V2LocalMediaThumbnailCache(directories: [f.root]) { _, _ in
            await gate.wait(starts.continuation); return image
        }
        let pipeline = f.pipeline(thumbnails), first = await pipeline.profiles.activate()
        let task = Task { try await pipeline.snapshot(key: f.key, activation: first, pixels: 16) }
        var entered = starts.stream.makeAsyncIterator(); _ = await entered.next()
        if nicknameOnly { try await f.reader.replaceNickname("Room name") }
        else { try await f.reader.replaceName() }
        let second = await pipeline.profiles.activate()
        let replacement = try await pipeline.profiles.presentation(for: f.key, activation: second)
        if nicknameOnly { #expect(replacement?.groupMember?.groupNickname == "Room name") }
        else { #expect(replacement?.view.publicIdentity?.displayName == "Updated") }
        await gate.release()
        #expect(try await task.value == nil)
        await pipeline.close(); await thumbnails.close(); try await f.files.close(); starts.continuation.finish()
    }

    @Test("authorized group nickname takes precedence and clearing it restores the public name")
    func nicknameDisplay() async throws {
        let f = try await ProfilePipelineFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let thumbnails = V2LocalMediaThumbnailCache(directories: [f.root]), pipeline = f.pipeline(thumbnails)
        try await f.reader.replaceNickname("Room name")
        let first = await pipeline.profiles.activate()
        #expect(try await pipeline.snapshot(key: f.key, activation: first, pixels: 16)?.name == "Room name")
        try await f.reader.replaceNickname(nil)
        let second = await pipeline.profiles.activate()
        #expect(try await pipeline.snapshot(key: f.key, activation: second, pixels: 16)?.name == "Original")
        #expect(await pipeline.profiles.cachedPresentation(for: f.key, activation: second)?.groupMember?.revision.rawValue == 2)
        await pipeline.close(); await thumbnails.close(); try await f.files.close()
    }

    @Test("visible group and direct rows share page authority and page reentry reauthorizes cached pixels", arguments: [false, true])
    func sharedVisiblePage(direct: Bool) async throws {
        let f = try await ProfilePipelineFixture(direct: direct)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let thumbnails = V2LocalMediaThumbnailCache(directories: [f.root]), pipeline = f.pipeline(thumbnails)
        let scope = V2AuthorPresentationPageScope(context: f.pageContext)
        #expect(f.pageContext.authorRoomID == f.key.context.authorizationRoomID)
        let running = Task { await scope.run(pipeline: pipeline) }
        try await waitForProfilePage { scope.activation != nil }
        let a = try await scope.retain(f.key, pipeline: pipeline), b = try await scope.retain(f.key, pipeline: pipeline)
        #expect(a.0 == b.0)
        let first = Task { try await scope.snapshot(key: f.key, activation: a.0, pipeline: pipeline, pixels: 16) }
        let second = Task { try await scope.snapshot(key: f.key, activation: b.0, pipeline: pipeline, pixels: 16) }
        #expect(try await first.value?.image != nil)
        #expect(try await second.value?.image != nil)
        #expect(await f.reader.calls == 1)
        await pipeline.profiles.releaseVisibleInterest(a.1)
        #expect(await pipeline.profiles.cachedPresentation(for: f.key, activation: b.0) != nil)
        await pipeline.profiles.releaseVisibleInterest(b.1)
        scope.hide(); running.cancel(); await running.value
        #expect(await pipeline.profiles.diagnostics().activations == 0)
        await f.reader.deny()
        let resumed = Task { await scope.run(pipeline: pipeline) }
        try await waitForProfilePage { scope.activation != nil }
        let c = try await scope.retain(f.key, pipeline: pipeline)
        #expect(c.0 != a.0)
        #expect(try await scope.snapshot(key: f.key, activation: c.0, pipeline: pipeline, pixels: 16) == nil)
        #expect(await f.reader.calls == 2)
        await pipeline.profiles.releaseVisibleInterest(c.1)
        scope.hide(); resumed.cancel(); await resumed.value
        await pipeline.close(); await thumbnails.close(); try await f.files.close()
    }

    @Test("group and direct page hiding reject late decode while a row still holds interest", arguments: [false, true])
    func pageHideFencesDecode(direct: Bool) async throws {
        let f = try await ProfilePipelineFixture(direct: direct)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let starts = AsyncStream<Void>.makeStream(), gate = ProfileDecodeGate()
        let thumbnails = V2LocalMediaThumbnailCache(directories: [f.root]) { _, _ in
            await gate.wait(starts.continuation); return V2SendableImage(image: UIImage())
        }
        let pipeline = f.pipeline(thumbnails)
        let scope = V2AuthorPresentationPageScope(context: f.pageContext), running = Task { await scope.run(pipeline: pipeline) }
        try await waitForProfilePage { scope.activation != nil }
        let row = try await scope.retain(f.key, pipeline: pipeline)
        let decode = Task { try await scope.snapshot(key: f.key, activation: row.0, pipeline: pipeline, pixels: 16) }
        var entered = starts.stream.makeAsyncIterator(); _ = await entered.next()
        scope.hide()
        await gate.release()
        #expect(try await decode.value == nil)
        await pipeline.profiles.releaseVisibleInterest(row.1)
        running.cancel(); await running.value
        await pipeline.close(); await thumbnails.close(); try await f.files.close(); starts.continuation.finish()
    }

    @Test("the page observes a complete key revision snapshot without refreshing unaffected rows")
    func pageKeyInvalidations() async throws {
        let f = try await ProfilePipelineFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let thumbnails = V2LocalMediaThumbnailCache(directories: [f.root]), pipeline = f.pipeline(thumbnails)
        let scope = V2AuthorPresentationPageScope(context: f.pageContext), running = Task { await scope.run(pipeline: pipeline) }
        try await waitForProfilePage { scope.activation != nil }
        let other = V2ProfileViewLookupKey(userID: .init(uuid: UUID()), context: f.key.context)
        let stable = V2ProfileViewLookupKey(userID: .init(uuid: UUID()), context: f.key.context)
        let a = try await scope.retain(f.key, pipeline: pipeline), b = try await scope.retain(other, pipeline: pipeline)
        let c = try await scope.retain(stable, pipeline: pipeline)
        await pipeline.profiles.invalidate([f.key]); await pipeline.profiles.invalidate([other])
        try await waitForProfilePage { scope.revision(for: f.key) != nil && scope.revision(for: other) != nil }
        #expect(scope.revision(for: stable) == nil)
        for row in [a, b, c] { await pipeline.profiles.releaseVisibleInterest(row.1) }
        scope.hide(); running.cancel(); await running.value
        await pipeline.close(); await thumbnails.close(); try await f.files.close()
    }

    @Test("a direct page rejects another peer and wrong lookup contexts before issuing requests")
    func directPageContextIsolation() async throws {
        let f = try await ProfilePipelineFixture(direct: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let thumbnails = V2LocalMediaThumbnailCache(directories: [f.root]), pipeline = f.pipeline(thumbnails)
        let scope = V2AuthorPresentationPageScope(context: f.pageContext)
        let running = Task { await scope.run(pipeline: pipeline) }
        try await waitForProfilePage { scope.activation != nil }
        let activation = try #require(scope.activation)
        let wrongKeys: [V2ProfileViewLookupKey] = [
            .init(userID: .init(uuid: UUID()), context: .directConversation),
            .init(userID: .init(uuid: UUID()), context: f.key.context),
            .init(userID: f.key.userID, context: .directConversation),
            .init(userID: f.key.userID, context: .relationship),
            .init(userID: f.key.userID, context: .room(.init(uuid: UUID()))),
            .init(userID: f.actor, context: .directConversation),
            .init(userID: f.actor, context: .relationship)
        ]
        for key in wrongKeys {
            await #expect(throws: V2ProfilePresentationError.inactive) { try await scope.retain(key, pipeline: pipeline) }
            await #expect(throws: V2ProfilePresentationError.inactive) {
                try await scope.snapshot(key: key, activation: activation, pipeline: pipeline, pixels: 16)
            }
        }
        #expect(await f.reader.calls == 0)
        let ownKey = V2ProfileViewLookupKey(userID: f.actor, context: f.key.context)
        let own = try await scope.retain(ownKey, pipeline: pipeline)
        let peer = try await scope.retain(f.key, pipeline: pipeline)
        #expect(own.0 == peer.0)
        #expect(try await scope.snapshot(key: f.key, activation: peer.0, pipeline: pipeline, pixels: 16)?.name == "Original")
        await pipeline.profiles.invalidate([f.key])
        try await waitForProfilePage { scope.revision(for: f.key) != nil }
        #expect(scope.revision(for: ownKey) == nil)
        for row in [own, peer] { await pipeline.profiles.releaseVisibleInterest(row.1) }
        scope.hide(); running.cancel(); await running.value
        await pipeline.close(); await thumbnails.close(); try await f.files.close()
    }
}

@MainActor
@Observable
private final class ProfileListLifecycleProbe {
    var page = 0
    var phase = ScenePhase.active
    var observedPhase = ScenePhase.active
    var displayedIdentityName: String?
    let rootID = UUID()
    var scopes: [Int: V2AuthorPresentationPageScope] = [:]
    var initialNames: [Int: String] = [:]
    var loadedPages: Set<Int> = []
}

private struct ProfileListLifecycleHost: View {
    let probe: ProfileListLifecycleProbe
    let key: V2ProfileViewLookupKey
    let pipeline: V2AvatarPipeline
    var body: some View {
        ProfileListLifecycleChild(probe: probe, key: key, pipeline: pipeline, page: probe.page)
            .authorPresentationPage(context: .list(UUID()))
            .id(probe.page)
            .authorPresentationPage(context: .list(probe.rootID))
            .environment(\.scenePhase, probe.phase)
    }
}

private struct ProfileListLifecycleChild: View {
    let probe: ProfileListLifecycleProbe
    let key: V2ProfileViewLookupKey
    let pipeline: V2AvatarPipeline
    let page: Int
    @Environment(\.v2AuthorPresentationPageScope) private var scope
    @Environment(\.scenePhase) private var phase
    var body: some View {
        VStack {
            Text("Profile lifecycle probe")
            V2AuthorizedProfileNameView(key: key)
            V2AuthorizedPublicHandleView(key: key) { identity in
                guard probe.page == page else { return }
                probe.displayedIdentityName = identity?.displayName
            }
        }
            .onChange(of: phase, initial: true) { _, value in probe.observedPhase = value }
            .onAppear {
                if let name = scope?.cachedSnapshot(key: key, pixels: nil, pipeline: pipeline)?.name {
                    probe.initialNames[page] = name
                }
            }
            .task(id: scope?.activation) {
                guard let scope, scope.activation != nil,
                      let retained = try? await scope.retain(key, pipeline: pipeline) else { return }
                defer { Task { await pipeline.profiles.releaseVisibleInterest(retained.1) } }
                guard let value = try? await scope.snapshot(key: key, activation: retained.0, pipeline: pipeline, pixels: nil),
                      value.name == "Original", !Task.isCancelled else { return }
                probe.scopes[page] = scope
                probe.loadedPages.insert(page)
            }
    }
}

@MainActor
private func waitForProfilePage(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !predicate() { guard .now < deadline else { throw CancellationError() }; try await Task.sleep(for: .milliseconds(1)) }
}

@MainActor
private struct ProfilePipelineFixture {
    let root: URL, cachedFile: URL, key: V2ProfileViewLookupKey
    let pageContext: V2AuthorPresentationPageScope.Context
    let actor = UserID(uuid: UUID()), device = DeviceID(uuid: UUID())
    let reader: ProfilePipelineReader, files: V2ResourceMediaTestOwner
    init(direct: Bool = false, relationship: Bool = false) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("profile-pipeline-\(UUID())")
        let png = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).pngData { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        let media = MediaID(uuid: UUID()), variant = ResourceVariantID(uuid: UUID())
        let checksum = try V2ResourceChecksum(value: SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined())
        let room = RoomID(uuid: UUID())
        key = .init(userID: .init(uuid: UUID()), context: relationship ? .relationship : .room(room))
        pageContext = direct ? .direct(roomID: room, actorUserID: actor, peerUserID: key.userID) : .group(room)
        let now = Date(), rev = try #require(V2ProfileRevision(rawValue: 1))
        let view = try V2ProfileView(userID: key.userID,
            publicIdentity: .init(userID: key.userID, handle: .init("profile"), displayName: "Original", accountKind: .regular),
            avatar: .init(mediaID: media), state: .active, revision: rev, visibilityRevision: rev)
        let lease = try V2PresentationAccessLease(actorUserID: actor, deviceID: device, key: key,
            profileRevision: rev, visibilityRevision: rev, contextRevision: 1, observedAt: now, validUntil: now.addingTimeInterval(300))
        let avatar = try V2ResourceAvatarAccess(mediaID: media, variantID: variant, version: 1, checksum: checksum,
            plan: .init(mode: .httpGet, url: #require(URL(string: "https://delivery.invalid/avatar")),
                expiresAt: now.addingTimeInterval(120), expectedByteCount: Int64(png.count), checksum: checksum))
        reader = .init(value: try .init(view: view, lease: lease), avatar: avatar)
        files = try await makeResourceMediaTestDownloader(downloader: .init(targetResolver: NoProfileByteIO(), byteTransfer: ResourceMediaSeedBytes(png)), directory: root)
        let seeded = try await files.avatar(avatar, home: .account(key.userID))
        cachedFile = seeded.fileURL
        await seeded.release()
    }
    func pipeline(_ thumbnails: V2LocalMediaThumbnailCache) -> V2AvatarPipeline {
        .init(profiles: .init(actorUserID: actor, deviceID: device, reader: reader),
            groups: .init(actorUserID: actor, deviceID: device, reader: NoProfileByteIO(), minimumRevision: { _ in 0 }),
            files: files.downloader, thumbnails: thumbnails)
    }
}
private actor ProfilePipelineReader: V2ProfilePresentationReading {
    var value: V2AuthorizedProfilePresentation
    let avatar: V2ResourceAvatarAccess
    var denied = false
    var offline = false
    func setOffline() { offline = true }
    var calls = 0
    init(value: V2AuthorizedProfilePresentation, avatar: V2ResourceAvatarAccess) { self.value = value; self.avatar = avatar }
    func deny() { denied = true }
    func replaceAlias(_ name: String?) throws {
        let alias = try V2ContactAlias(ownerUserID: value.lease.actorUserID, targetUserID: value.view.userID,
            remarkName: name, revision: #require(.init(rawValue: (value.contactAlias?.revision.rawValue ?? 0) + 1)))
        value = try .init(view: value.view, lease: value.lease, groupMember: value.groupMember, contactAlias: alias)
    }
    func replaceNickname(_ name: String?) throws {
        guard case .room(let room) = value.lease.key.context else { throw CancellationError() }
        let member = try V2GroupMemberPresentation(roomID: room, userID: value.view.userID,
            groupNickname: name, revision: #require(.init(rawValue: (value.groupMember?.revision.rawValue ?? 0) + 1)))
        value = try .init(view: value.view, lease: value.lease, groupMember: member, contactAlias: value.contactAlias)
    }
    func replaceName() throws {
        let rev = try #require(V2ProfileRevision(rawValue: 2)), previous = value
        let view = try V2ProfileView(userID: previous.view.userID,
            publicIdentity: .init(userID: previous.view.userID, handle: .init("profile"), displayName: "Updated", accountKind: .regular),
            avatar: previous.view.avatar, state: .active, revision: rev, visibilityRevision: rev)
        let lease = try V2PresentationAccessLease(actorUserID: previous.lease.actorUserID, deviceID: previous.lease.deviceID,
            key: previous.lease.key, profileRevision: rev, visibilityRevision: rev, contextRevision: 2,
            observedAt: Date(), validUntil: Date().addingTimeInterval(299))
        value = try .init(view: view, lease: lease, groupMember: previous.groupMember, contactAlias: previous.contactAlias)
    }
    func readPresentations(_ keys: [V2ProfileViewLookupKey]) throws -> V2ProfilePresentationBatch {
        calls += 1
        if offline { throw URLError(.notConnectedToInternet) }
        let key = value.lease.key
        return .init(presentations: denied ? [:] : [key: value], unavailable: denied ? Set(keys) : [],
                     serverNow: Date(), avatars: denied ? [:] : [key: avatar])
    }
}
private actor ProfileDecodeGate {
    var continuation: CheckedContinuation<Void, Never>?
    func wait(_ starts: AsyncStream<Void>.Continuation) async {
        await withCheckedContinuation { continuation = $0; starts.yield(()) }
    }
    func release() { continuation?.resume(); continuation = nil }
}
private struct NoProfileByteIO: V2ClientMediaDownloadTargetResolver, V2ClientMediaByteTransfer, V2GroupAvatarPresentationReading {
    func resolveDownloadTarget(mediaID: MediaID, message: V2MediaMessageLocation?) throws -> V2ClientMediaTransferTarget { throw CancellationError() }
    func upload(fileURL: URL, target: V2ClientMediaTransferTarget) throws { throw CancellationError() }
    func download(target: V2ClientMediaTransferTarget, destinationURL: URL) throws { throw CancellationError() }
    func readGroupAvatar(roomID: RoomID) throws -> V2GroupAvatarPresentation { throw V2GroupAvatarReadError.forbidden }
}

@MainActor @Observable private final class LocalProfileFirstPaintProbe {
    var visible = true
    var identities: [String?] = []
}
private struct LocalProfileFirstPaintHost: View {
    @Bindable var probe: LocalProfileFirstPaintProbe
    let key: V2ProfileViewLookupKey
    var body: some View {
        if probe.visible {
            V2AuthorizedPublicHandleView(key: key) { identity in probe.identities.append(identity?.displayName) }
        } else { Text("Other page") }
    }
}
