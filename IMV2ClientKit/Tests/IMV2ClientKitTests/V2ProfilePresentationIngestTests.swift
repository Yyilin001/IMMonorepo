import Foundation
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Profile HTTP and author delta ownership", .timeLimit(.minutes(1)))
struct V2ProfilePresentationIngestTests {
    @Test("avatar renewal shares bounded HTTP work without dropping valid display authority",
          arguments: ["success", "transport", "denied", "invalidate", "deactivate", "unauthorized", "close"])
    func avatarRenewal(scenario: String) async throws {
        let f = Fixture(), page = await f.repository.activate(), media = MediaID(uuid: UUID())
        let checksum = try V2ResourceChecksum(value: String(repeating: "a", count: 64))
        let avatar = try V2ResourceAvatarAccess(mediaID: media, variantID: .init(uuid: UUID()), version: 1,
            checksum: checksum, byteCount: 1,
            plan: .init(mode: .httpGet, url: #require(URL(string: "https://objects.invalid/renewed")),
                expiresAt: f.date.addingTimeInterval(60), expectedByteCount: 1, checksum: checksum))
        let value = try f.value(key: f.key, revision: 1, media: media)
        let first = Task { try await f.repository.presentation(for: f.key, activation: page) }
        try await f.reader.waitForCalls(1)
        await f.reader.release(0, with: .success(.init(presentations: [f.key: value], denials: [:], serverNow: f.date,
            avatars: [f.key: avatar.withoutDownloadPlan()])))
        _ = try await first.value
        let original = try #require(await f.repository.avatarReadGrant(for: f.key, activation: page))
        let a = Task { try await f.repository.refreshAvatarReadGrant(for: f.key, activation: page, replacing: original.avatar) }
        let b = Task { try await f.repository.refreshAvatarReadGrant(for: f.key, activation: page, replacing: original.avatar) }
        try await wait { await f.repository.diagnostics().waitingConsumers == 2 }
        try await f.reader.waitForCalls(2)
        #expect(await f.repository.cachedPresentation(for: f.key, activation: page) == value)
        try await original.requireValid()
        if scenario == "invalidate" { await f.repository.invalidate([f.key]) }
        if scenario == "deactivate" { await f.repository.deactivate(page) }
        var closing: Task<Void, Never>?
        if scenario == "close" {
            closing = Task { await f.repository.close() }
            try await wait { await f.repository.diagnostics().activations == 0 }
        }
        let response: Result<V2ProfilePresentationBatch, Error>
        switch scenario {
        case "transport": response = .failure(URLError(.notConnectedToInternet))
        case "unauthorized": response = .failure(V2ClientMediaTransferError.authorizationUnavailable)
        case "denied": response = .success(.init(presentations: [:], denials: [f.key: value.lease.authorityVersion], serverNow: f.date))
        default: response = .success(.init(presentations: [f.key: value], denials: [:], serverNow: f.date, avatars: [f.key: avatar]))
        }
        await f.reader.release(1, with: response)
        for task in [a, b] {
            switch await task.result {
            case .success(let renewed):
                if scenario == "success" { #expect(renewed?.avatar.plan != nil) }
                else { #expect(scenario == "denied" && renewed == nil) }
            case .failure: #expect(!["success", "denied"].contains(scenario))
            }
        }
        if scenario == "transport" {
            try await original.requireValid()
            #expect(await f.repository.cachedPresentation(for: f.key, activation: page) == value)
            await #expect(throws: (any Error).self) {
                _ = try await f.repository.refreshAvatarReadGrant(for: f.key, activation: page, replacing: original.avatar)
            }
        } else if scenario != "success" {
            await #expect(throws: (any Error).self) { try await original.requireValid() }
        } else {
            let reused = try await f.repository.refreshAvatarReadGrant(for: f.key, activation: page, replacing: original.avatar)
            #expect(reused?.avatar.plan != nil)
        }
        #expect(await f.reader.calls == 2)
        await closing?.value
        await f.repository.close()
    }

    @Test("only an installed visible denial receives an application receipt")
    func installedDenialReceipt() async throws {
        let f = Fixture(), page = await f.repository.activateVisiblePage()
        let view = try await f.receiver.beginView(streamID: UUID(), roomID: f.room)
        let binding = try await f.repository.bindAuthorView(view, activation: page)
        let staged = try await f.repository.ingest(.init(view: view, sequence: 1,
            entries: [.unavailable(f.key, until: .now + .seconds(30))]), binding: binding)
        #expect(staged == nil)
        _ = try await f.repository.retainVisibleInterest(for: f.key, activation: page)
        let installed = try await f.repository.ingest(.init(view: view, sequence: 2,
            entries: [.unavailable(f.key, until: .now + .seconds(30))]), binding: binding)
        #expect(installed?.sequence == 2 && installed?.userIDs == [f.author])
        let expired = try await f.repository.ingest(.init(view: view, sequence: 3,
            entries: [.unavailable(f.key, until: .now - .seconds(1))]), binding: binding)
        #expect(expired == nil)
        #expect(await f.reader.calls == 0)
        await f.repository.close()
    }

    @Test("receipts include only retained visible entries and exclude staged or obsolete data")
    func retainedEntriesOnly() async throws {
        let f = Fixture(), page = await f.repository.activateVisiblePage()
        let view = try await f.receiver.beginView(streamID: UUID(), roomID: f.room)
        let binding = try await f.repository.bindAuthorView(view, activation: page)
        let staged = try await f.repository.ingest(f.received(view: view, revision: 1), binding: binding)
        #expect(staged == nil)
        _ = try await f.repository.retainVisibleInterest(for: f.key, activation: page)
        let retained = try await f.repository.ingest(f.received(view: view, revision: 2, sequence: 2), binding: binding)
        #expect(retained?.sequence == 2 && retained?.userIDs == [f.author])
        #expect((1...120_000).contains(try #require(retained?.minimumRemainingMilliseconds)))
        let obsolete = try await f.repository.ingest(f.received(view: view, revision: 1, sequence: 3), binding: binding)
        #expect(obsolete == nil)
        #expect(await f.repository.cachedPresentation(for: f.key, activation: page)?.view.revision.rawValue == 2)
        await f.repository.close()
    }

    @Test("a maximum-duration fresh lease is accepted after the page's timing anchor")
    func maximumLeaseAfterViewStarted() async throws {
        let f = Fixture(), page = await f.repository.activateVisiblePage()
        let view = try await f.receiver.beginView(streamID: UUID(), roomID: f.room)
        let binding = try await f.repository.bindAuthorView(view, activation: page)
        _ = try await f.repository.retainVisibleInterest(for: f.key, activation: page)
        let original = try f.value(key: f.key, revision: 1)
        let lease = try V2PresentationAccessLease(actorUserID: f.actor, deviceID: f.device, key: f.key,
            profileRevision: original.view.revision, visibilityRevision: original.view.visibilityRevision,
            contextRevision: original.lease.contextRevision, authorityVersion: original.lease.authorityVersion,
            observedAt: f.date, validUntil: f.date.addingTimeInterval(300))
        let delta = try V2AuthorPresentationDelta(streamID: view.streamID, viewID: view.viewID, sequence: 1,
            actorUserID: f.actor, deviceID: f.device, roomID: f.room, serverViewAgeMilliseconds: 1,
            batch: .init(serverNowUnixMilliseconds: 2_000_000_000_000,
                results: [.presentation(.init(view: original.view, lease: lease), avatar: nil)]))
        try await Task.sleep(for: .milliseconds(5))
        let received = try #require(await f.receiver.receive(delta.encoded(), for: view))
        #expect(try await f.repository.ingest(received, binding: binding) != nil)
        #expect(await f.repository.cachedPresentation(for: f.key, activation: page) != nil)
        await f.repository.close()
    }

    @Test("alias durable floor fences cached and late HTTP without comparing public profile revision", arguments: [false, true])
    func durableAliasFloor(lazy: Bool) async throws {
        let floors = NicknameFloors(), f = Fixture(aliasRevisions: { await floors.read($0) })
        let page = await f.repository.activate()
        let initial = Task { try await f.repository.presentation(for: f.key, activation: page) }
        try await f.reader.waitForCalls(1)
        await f.reader.release(0, with: .success(try f.aliasBatch(1)))
        #expect(try await initial.value?.contactAlias?.revision.rawValue == 1)
        await floors.set(f.key, revision: 2)
        if !lazy { try await f.repository.refreshAliasInvalidations() }
        #expect(await f.repository.cachedSnapshot(for: f.key, activation: page) == nil)
        await floors.set(f.key, revision: 1)
        let old = Task { try await f.repository.presentation(for: f.key, activation: page) }
        try await f.reader.waitForCalls(2)
        await f.reader.release(1, with: .success(try f.aliasBatch(1)))
        await #expect(throws: V2ProfilePresentationError.staleResponse) { _ = try await old.value }
        let current = Task { try await f.repository.presentation(for: f.key, activation: page) }
        try await f.reader.waitForCalls(3)
        await f.reader.release(2, with: .success(try f.aliasBatch(2, name: nil)))
        #expect(try await current.value?.contactAlias?.revision.rawValue == 2)
        await f.repository.close()
    }

    @Test("alias floor blocks old early author candidates and allows same nonce to deliver a cleared revision")
    func aliasAuthorFloor() async throws {
        let floors = NicknameFloors(), f = Fixture(aliasRevisions: { await floors.read($0) })
        await floors.set(f.key, revision: 2)
        let page = await f.repository.activateVisiblePage()
        let view = try await f.receiver.beginView(streamID: UUID(), roomID: f.room)
        let binding = try await f.repository.bindAuthorView(view, activation: page)
        try await f.repository.ingest(f.received(view: view, revision: 1, contactAlias: f.alias(1)), binding: binding)
        #expect(await f.repository.diagnostics().bufferedAuthorEntries == 0)
        try await f.repository.ingest(f.received(view: view, revision: 1, sequence: 2, contactAlias: f.alias(2, name: nil)), binding: binding)
        _ = try await f.repository.retainVisibleInterest(for: f.key, activation: page)
        #expect(try await f.repository.presentation(for: f.key, activation: page)?.contactAlias?.revision.rawValue == 2)
        try await f.repository.ingest(f.received(view: view, revision: 1, sequence: 3, contactAlias: f.alias(2, name: "Conflicting same version")), binding: binding)
        #expect(await f.repository.cachedPresentation(for: f.key, activation: page)?.contactAlias?.remarkName == nil)
        #expect(await f.reader.calls == 0)
        await f.repository.close()
    }

    @Test("an alias floor received while HTTP is pending rejects the old response")
    func aliasFloorDuringHTTP() async throws {
        let floors = NicknameFloors(), f = Fixture(aliasRevisions: { await floors.read($0) })
        let page = await f.repository.activate()
        let pending = Task { try await f.repository.presentation(for: f.key, activation: page) }
        try await f.reader.waitForCalls(1)
        await floors.set(f.key, revision: 2)
        await f.reader.release(0, with: .success(try f.aliasBatch(1)))
        await #expect(throws: V2ProfilePresentationError.staleResponse) { _ = try await pending.value }
        await f.repository.close()
    }

    @Test("a content-only nickname invalidation accepts the current version from the same author view")
    func nicknameInvalidationKeepsAuthorView() async throws {
        let floors = NicknameFloors(), f = Fixture(nicknameRevisions: { await floors.read($0) })
        let page = await f.repository.activateVisiblePage()
        _ = try await f.repository.retainVisibleInterest(for: f.key, activation: page)
        let view = try await f.receiver.beginView(streamID: UUID(), roomID: f.room)
        let binding = try await f.repository.bindAuthorView(view, activation: page)
        let first = try #require(f.nicknameBatch(1).presentations[f.key]?.groupMember)
        let second = try #require(f.nicknameBatch(2).presentations[f.key]?.groupMember)
        try await f.repository.ingest(f.received(view: view, revision: 1, groupMember: first), binding: binding)
        #expect(await f.repository.cachedPresentation(for: f.key, activation: page)?.groupMember == first)
        await floors.set(f.key, revision: 2)
        try await f.repository.refreshNicknameInvalidations()
        #expect(await f.repository.cachedSnapshot(for: f.key, activation: page) == nil)
        try await f.repository.ingest(f.received(view: view, revision: 1, sequence: 2, groupMember: first), binding: binding)
        #expect(await f.repository.cachedSnapshot(for: f.key, activation: page) == nil)
        try await f.repository.ingest(f.received(view: view, revision: 1, sequence: 3, groupMember: second), binding: binding)
        #expect(await f.repository.cachedPresentation(for: f.key, activation: page)?.groupMember == second)
        // An actual access invalidation still blocks this old nonce.
        await f.repository.invalidate([f.key])
        try await f.repository.ingest(f.received(view: view, revision: 1, sequence: 4, groupMember: second), binding: binding)
        #expect(await f.repository.cachedSnapshot(for: f.key, activation: page) == nil)
        #expect(await f.reader.calls == 0)
        await f.repository.close()
    }

    @Test("a durable nickname floor invalidates only that author and context", arguments: [false, true])
    func durableNicknameFloor(lazyCheck: Bool) async throws {
        let floors = NicknameFloors(), f = Fixture(nicknameRevisions: { await floors.read($0) })
        let page = await f.repository.activate()
        let other = V2ProfileViewLookupKey(userID: f.author, context: .relationship)
        let initial = Task { try await f.repository.presentation(for: f.key, activation: page) }
        try await f.reader.waitForCalls(1)
        await f.reader.release(0, with: .success(try f.nicknameBatch(1)))
        #expect(try await initial.value?.groupMember?.revision.rawValue == 1)
        let otherRead = Task { try await f.repository.presentation(for: other, activation: page) }
        try await f.reader.waitForCalls(2)
        await f.reader.release(1, with: .success(try f.batch(revision: 1, keys: [other])))
        _ = try await otherRead.value
        _ = try await f.repository.invalidations(for: page)
        let before = try await f.repository.invalidationRevisions(for: page)
        await floors.set(f.key, revision: 2)
        if !lazyCheck { try await f.repository.refreshNicknameInvalidations() }
        #expect(await f.repository.cachedSnapshot(for: f.key, activation: page) == nil)
        #expect(await f.repository.cachedSnapshot(for: other, activation: page) != nil)
        let after = try await f.repository.invalidationRevisions(for: page)
        #expect(after[f.key] != before[f.key] && after[other] == before[other])
        // A lower persisted read cannot lower a floor already observed by this activation.
        await floors.set(f.key, revision: 1)
        let old = Task { try await f.repository.presentation(for: f.key, activation: page) }
        try await f.reader.waitForCalls(3)
        await f.reader.release(2, with: .success(try f.nicknameBatch(1)))
        await #expect(throws: V2ProfilePresentationError.staleResponse) { _ = try await old.value }
        let current = Task { try await f.repository.presentation(for: f.key, activation: page) }
        try await f.reader.waitForCalls(4)
        await f.reader.release(3, with: .success(try f.nicknameBatch(2)))
        #expect(try await current.value?.groupMember?.revision.rawValue == 2)
        #expect(await f.repository.cachedSnapshot(for: other, activation: page) != nil)
        await f.repository.close()
    }

    @Test("a nickname event arriving during HTTP blocks the old response without another notification")
    func nicknameEventDuringRead() async throws {
        let floors = NicknameFloors(), f = Fixture(nicknameRevisions: { await floors.read($0) })
        let page = await f.repository.activate()
        let old = Task { try await f.repository.presentation(for: f.key, activation: page) }
        try await f.reader.waitForCalls(1)
        await floors.set(f.key, revision: 2)
        await f.reader.release(0, with: .success(try f.nicknameBatch(1)))
        await #expect(throws: V2ProfilePresentationError.staleResponse) { _ = try await old.value }
        #expect(await f.repository.cachedSnapshot(for: f.key, activation: page) == nil)
        await f.repository.close()
    }

    @Test("early author supplements cannot bypass a durable nickname floor after restart")
    func nicknameFloorBeforeInterest() async throws {
        let floors = NicknameFloors(), f = Fixture(nicknameRevisions: { await floors.read($0) })
        await floors.set(f.key, revision: 2)
        let page = await f.repository.activateVisiblePage()
        let view = try await f.receiver.beginView(streamID: UUID(), roomID: f.room)
        let binding = try await f.repository.bindAuthorView(view, activation: page)
        let old = try #require(f.nicknameBatch(1).presentations[f.key]?.groupMember)
        try await f.repository.ingest(f.received(view: view, revision: 1, groupMember: old), binding: binding)
        #expect(await f.repository.diagnostics().bufferedAuthorEntries == 0)
        let current = try #require(f.nicknameBatch(2).presentations[f.key]?.groupMember)
        try await f.repository.ingest(f.received(view: view, revision: 1, sequence: 2, groupMember: current), binding: binding)
        #expect(await f.repository.diagnostics().bufferedAuthorEntries == 1)
        let interest = try await f.repository.retainVisibleInterest(for: f.key, activation: page)
        #expect(try await f.repository.presentation(for: f.key, activation: page)?.groupMember == current)
        #expect(await f.repository.diagnostics().inFlight == 0)
        await f.repository.releaseVisibleInterest(interest)
        await f.repository.close()
    }

    @Test("nickname versions reject rollback and conflicting values, and a clear notifies visible rows")
    func nicknameRevisionFloor() async throws {
        let f = Fixture(), activation = await f.repository.activate()
        let updates = try await f.repository.invalidations(for: activation)
        let view = try await f.receiver.beginView(streamID: UUID(), roomID: f.room)
        let binding = try await f.repository.bindAuthorView(view, activation: activation)
        let waiting = Task { try await f.repository.presentation(for: f.key, activation: activation) }
        try await f.reader.waitForCalls(1)
        let accepted = try V2GroupMemberPresentation(roomID: f.room, userID: f.author, groupNickname: "Current",
            revision: #require(.init(rawValue: 2)))
        try await f.repository.ingest(f.received(view: view, revision: 1, groupMember: accepted), binding: binding)
        #expect(try await waiting.value?.groupMember == accepted)
        await f.reader.release(0, with: .success(try f.batch(revision: 1)))
        try await wait { await f.repository.diagnostics().inFlight == 0 }
        let rejected: [V2GroupMemberPresentation?] = [nil,
            try .init(roomID: f.room, userID: f.author, groupNickname: "Old", revision: #require(.init(rawValue: 1))),
            try .init(roomID: f.room, userID: f.author, groupNickname: "Contradiction", revision: #require(.init(rawValue: 2)))]
        for (index, member) in rejected.enumerated() {
            try await f.repository.ingest(f.received(view: view, revision: 1, sequence: UInt64(index + 2), groupMember: member), binding: binding)
            #expect(await f.repository.cachedPresentation(for: f.key, activation: activation)?.groupMember == accepted)
        }
        let notification = Task { for await _ in updates { return true }; return false }
        let cleared = try V2GroupMemberPresentation(roomID: f.room, userID: f.author, groupNickname: nil,
            revision: #require(.init(rawValue: 3)))
        try await f.repository.ingest(f.received(view: view, revision: 1, sequence: 5, groupMember: cleared), binding: binding)
        #expect(await notification.value)
        #expect(await f.repository.cachedPresentation(for: f.key, activation: activation)?.groupMember == cleared)
        try await f.repository.ingest(f.received(view: view, revision: 2, sequence: 6, state: .hidden), binding: binding)
        #expect(await f.repository.cachedPresentation(for: f.key, activation: activation)?.view.state == .hidden)
        try await f.repository.ingest(f.received(view: view, revision: 2, sequence: 7, groupMember: accepted), binding: binding)
        #expect(await f.repository.cachedPresentation(for: f.key, activation: activation)?.view.state == .hidden)
        try await f.repository.ingest(f.received(view: view, revision: 2, sequence: 8, groupMember: cleared), binding: binding)
        #expect(await f.repository.cachedPresentation(for: f.key, activation: activation)?.view.state == .active)
        await f.repository.close()
    }

    @Test("a departed page's non-cooperative HTTP response cannot satisfy reentry")
    func reentry() async throws {
        let f = Fixture(), first = await f.repository.activate()
        let old = Task { try await f.repository.presentation(for: f.key, activation: first) }
        try await f.reader.waitForCalls(1)
        await f.repository.deactivate(first)
        await #expect(throws: CancellationError.self) { _ = try await old.value }
        let next = await f.repository.activate()
        let new = Task { try await f.repository.presentation(for: f.key, activation: next) }
        try await wait { await f.repository.diagnostics().waitingConsumers == 1 }
        await f.reader.release(0, with: .success(try f.batch(revision: 1)))
        try await f.reader.waitForCalls(2)
        #expect(await f.repository.cachedPresentation(for: f.key, activation: next) == nil)
        await f.reader.release(1, with: .success(try f.batch(revision: 2)))
        #expect(try await new.value?.view.revision.rawValue == 2)
        await f.repository.close()
    }

    @Test("an activation that joins after HTTP starts requires its own later authority read")
    func lateJoiningPage() async throws {
        let f = Fixture(), first = await f.repository.activate()
        let a = Task { try await f.repository.presentation(for: f.key, activation: first) }
        try await f.reader.waitForCalls(1)
        let second = await f.repository.activate()
        let b = Task { try await f.repository.presentation(for: f.key, activation: second) }
        try await wait { await f.repository.diagnostics().waitingConsumers == 2 }
        await f.reader.release(0, with: .success(try f.batch(revision: 1)))
        #expect(try await a.value?.view.revision.rawValue == 1)
        try await f.reader.waitForCalls(2)
        #expect(await f.repository.cachedPresentation(for: f.key, activation: second) == nil)
        await f.reader.release(1, with: .success(try f.batch(revision: 2)))
        #expect(try await b.value?.view.revision.rawValue == 2)
        await f.repository.close()
    }

    @Test("delta completes the visible demand while old HTTP keeps its slot and cannot overwrite")
    func pushedSuccessWins() async throws {
        let f = Fixture(), activation = await f.repository.activate()
        let view = try await f.receiver.beginView(streamID: UUID(), roomID: f.room)
        let binding = try await f.repository.bindAuthorView(view, activation: activation)
        let waiting = Task { try await f.repository.presentation(for: f.key, activation: activation) }
        try await f.reader.waitForCalls(1)
        let pushed = try await f.received(view: view, revision: 2)
        try await f.repository.ingest(pushed, binding: binding)
        #expect(try await waiting.value?.view.revision.rawValue == 2)
        #expect(await f.repository.diagnostics().inFlight == 1)
        await f.reader.release(0, with: .success(try f.batch(revision: 1)))
        try await wait { await f.repository.diagnostics().inFlight == 0 }
        #expect(await f.repository.cachedPresentation(for: f.key, activation: activation)?.view.revision.rawValue == 2)
        await f.repository.unbindAuthorView(binding)
        #expect(await f.repository.cachedPresentation(for: f.key, activation: activation) == nil)
        await f.repository.close()
    }

    @Test("a newer HTTP denial fences old author data and a newer grant restores the same page")
    func denialFencesVersion() async throws {
        let f = Fixture(), activation = await f.repository.activate()
        let view = try await f.receiver.beginView(streamID: UUID(), roomID: f.room)
        let binding = try await f.repository.bindAuthorView(view, activation: activation)
        let first = V2PresentationAuthorityVersion.fixture(f.key, contextRevision: 2, controlSequence: 1)
        let denied = V2PresentationAuthorityVersion.fixture(f.key, contextRevision: 2, controlSequence: 2)
        let restored = V2PresentationAuthorityVersion.fixture(f.key, contextRevision: 2, controlSequence: 3)
        let waiting = Task { try await f.repository.presentation(for: f.key, activation: activation) }
        try await f.reader.waitForCalls(1)
        try await f.repository.ingest(f.received(view: view, revision: 2, authority: first), binding: binding)
        _ = try await waiting.value
        await f.reader.release(0, with: .success(.init(presentations: [:], denials: [f.key: denied], serverNow: f.date)))
        try await wait { await f.repository.diagnostics().inFlight == 0 }
        #expect(await f.repository.cachedPresentation(for: f.key, activation: activation) == nil)
        try await f.repository.ingest(f.received(view: view, revision: 3, sequence: 2, authority: first), binding: binding)
        #expect(await f.repository.cachedPresentation(for: f.key, activation: activation) == nil)
        let receipt = try await f.repository.ingest(f.received(view: view, revision: 3, sequence: 3, authority: restored), binding: binding)
        #expect(receipt?.sequence == 3)
        #expect(await f.repository.cachedPresentation(for: f.key, activation: activation)?.view.revision.rawValue == 3)
        #expect(await f.reader.calls == 1)
        await f.repository.close()
    }

    @Test("an older overlapping HTTP denial cannot revoke a newer installed author grant")
    func staleHTTPDenial() async throws {
        let f = Fixture(), page = await f.repository.activate()
        let view = try await f.receiver.beginView(streamID: UUID(), roomID: f.room)
        let binding = try await f.repository.bindAuthorView(view, activation: page)
        let waiting = Task { try await f.repository.presentation(for: f.key, activation: page) }
        try await f.reader.waitForCalls(1)
        let version = V2PresentationAuthorityVersion.fixture(f.key, contextRevision: 2, controlSequence: 3)
        try await f.repository.ingest(f.received(view: view, revision: 2, authority: version), binding: binding)
        _ = try await waiting.value
        await f.reader.release(0, with: .success(.init(presentations: [:], denials: [f.key: .fixture(f.key, contextRevision: 1, controlSequence: 2)], serverNow: f.date)))
        try await wait { await f.repository.diagnostics().inFlight == 0 }
        #expect(await f.repository.cachedPresentation(for: f.key, activation: page)?.lease.authorityVersion == version)
        await f.repository.close()
    }

    @Test("a stale HTTP denial completes its own waiting page without borrowing another page's grant")
    func staleDenialCompletesDemand() async throws {
        let f = Fixture(), first = await f.repository.activate()
        let view = try await f.receiver.beginView(streamID: UUID(), roomID: f.room)
        let binding = try await f.repository.bindAuthorView(view, activation: first)
        let waiting = Task { try await f.repository.presentation(for: f.key, activation: first) }
        try await f.reader.waitForCalls(1)
        let version = V2PresentationAuthorityVersion.fixture(f.key, contextRevision: 2, controlSequence: 3)
        try await f.repository.ingest(f.received(view: view, revision: 2, authority: version), binding: binding)
        _ = try await waiting.value
        await f.reader.release(0, with: .failure(CancellationError()))
        try await wait { await f.repository.diagnostics().inFlight == 0 }
        let second = await f.repository.activate()
        let pending = Task { try await f.repository.presentation(for: f.key, activation: second) }
        try await f.reader.waitForCalls(2)
        await f.reader.release(1, with: .success(.init(presentations: [:], denials: [f.key: .fixture(f.key, contextRevision: 1, controlSequence: 2)], serverNow: f.date)))
        await #expect(throws: V2ProfilePresentationError.staleResponse) { _ = try await pending.value }
        #expect(await f.repository.cachedPresentation(for: f.key, activation: second) == nil)
        #expect(await f.repository.cachedPresentation(for: f.key, activation: first)?.lease.authorityVersion == version)
        #expect(await f.repository.diagnostics().waitingConsumers == 0)
        await f.repository.close()
    }

    @Test("an older staged value cannot hide another page's newer grant from a late denial")
    func candidateDoesNotHideGrantedFloor() async throws {
        let f = Fixture(), first = await f.repository.activateVisiblePage()
        let view = try await f.receiver.beginView(streamID: UUID(), roomID: f.room)
        let binding = try await f.repository.bindAuthorView(view, activation: first)
        try await f.repository.ingest(f.received(view: view, revision: 1,
            authority: .fixture(f.key, contextRevision: 1, controlSequence: 1)), binding: binding)
        #expect(await f.repository.diagnostics().bufferedAuthorEntries == 1)
        let second = await f.repository.activate()
        let pending = Task { try await f.repository.presentation(for: f.key, activation: second) }
        try await f.reader.waitForCalls(1)
        let version = V2PresentationAuthorityVersion.fixture(f.key, contextRevision: 1, controlSequence: 3)
        let value = try f.value(key: f.key, revision: 1, authority: version)
        await f.reader.release(0, with: .success(.init(presentations: [f.key: value], denials: [:], serverNow: f.date)))
        #expect(try await pending.value?.lease.authorityVersion == version)
        try await f.repository.ingest(f.denied(view: view, sequence: 2,
            version: .fixture(f.key, contextRevision: 1, controlSequence: 2)), binding: binding)
        #expect(await f.repository.cachedPresentation(for: f.key, activation: second)?.lease.authorityVersion == version)
        #expect(await f.repository.diagnostics().authorityDenials == 0)
        await f.repository.close()
    }

    @Test("concurrent control and room denials preserve both floors; content changes cannot bypass them")
    func incomparableDenials() async throws {
        let f = Fixture(), page = await f.repository.activateVisiblePage()
        let view = try await f.receiver.beginView(streamID: UUID(), roomID: f.room)
        let binding = try await f.repository.bindAuthorView(view, activation: page)
        _ = try await f.repository.retainVisibleInterest(for: f.key, activation: page)
        try await f.repository.ingest(f.received(view: view, revision: 1,
            authority: .fixture(f.key, contextRevision: 1, controlSequence: 1)), binding: binding)
        try await f.repository.ingest(f.denied(view: view, sequence: 2,
            version: .fixture(f.key, contextRevision: 1, controlSequence: 2)), binding: binding)
        try await f.repository.ingest(f.denied(view: view, sequence: 3,
            version: .fixture(f.key, contextRevision: 2, controlSequence: 1)), binding: binding)
        // Newer control with older room, or exactly the combined denial floor,
        // cannot revive display, even with a newer public profile revision.
        for (index, version) in [V2PresentationAuthorityVersion.fixture(f.key, contextRevision: 1, controlSequence: 3),
                                .fixture(f.key, contextRevision: 2, controlSequence: 2)].enumerated() {
            let receipt = try await f.repository.ingest(f.received(view: view, revision: 5, sequence: UInt64(index + 4), authority: version), binding: binding)
            #expect(receipt == nil)
            #expect(await f.repository.cachedPresentation(for: f.key, activation: page) == nil)
        }
        let version = V2PresentationAuthorityVersion.fixture(f.key, contextRevision: 3, controlSequence: 2)
        try await f.repository.ingest(f.received(view: view, revision: 1, sequence: 6, authority: version), binding: binding)
        #expect(await f.repository.cachedPresentation(for: f.key, activation: page)?.lease.authorityVersion == version)
        #expect(await f.reader.calls == 0)
        await f.repository.close()
    }

    @Test("a room permission-only revision restores a staged denial without changing public content or membership")
    func permissionOnlyRecovery() async throws {
        let f = Fixture(), page = await f.repository.activateVisiblePage()
        let view = try await f.receiver.beginView(streamID: UUID(), roomID: f.room)
        let binding = try await f.repository.bindAuthorView(view, activation: page)
        let denied = V2PresentationAuthorityVersion.fixture(f.key, contextRevision: 5, controlSequence: 10, permissionRevision: 2)
        try await f.repository.ingest(f.denied(view: view, sequence: 1, version: denied), binding: binding)
        let next = V2PresentationAuthorityVersion.fixture(f.key, contextRevision: 5, controlSequence: 10, permissionRevision: 3)
        try await f.repository.ingest(f.received(view: view, revision: 1, sequence: 2, authority: next), binding: binding)
        _ = try await f.repository.retainVisibleInterest(for: f.key, activation: page)
        #expect(try await f.repository.presentation(for: f.key, activation: page)?.lease.authorityVersion == next)
        #expect(await f.repository.cachedPresentation(for: f.key, activation: page)?.lease.authorityVersion == next)
        #expect(await f.reader.calls == 0)
        await f.repository.close()
    }

    @Test("key invalidation fences old work without failing an unrelated context in the same batch")
    func contextIsolation() async throws {
        let f = Fixture(), activation = await f.repository.activate()
        let other = V2ProfileViewLookupKey(userID: f.author, context: .relationship)
        let a = Task { try await f.repository.presentation(for: f.key, activation: activation) }
        let b = Task { try await f.repository.presentation(for: other, activation: activation) }
        try await f.reader.waitForCalls(1)
        #expect(await f.reader.keys(0).count == 2)
        await f.repository.invalidate([f.key])
        await #expect(throws: V2ProfilePresentationError.inactive) { _ = try await a.value }
        await f.reader.release(0, with: .success(try f.batch(revision: 2, keys: [f.key, other])))
        #expect(try await b.value?.lease.key == other)
        #expect(await f.repository.cachedPresentation(for: f.key, activation: activation) == nil)
        await f.repository.close()
    }

    @Test("invalidation also wakes a visible row still waiting for its first presentation")
    func invalidatingPendingRow() async throws {
        let f = Fixture(), activation = await f.repository.activate()
        let updates = try await f.repository.invalidations(for: activation)
        let notification = Task { for await _ in updates { return true }; return false }
        let pending = Task { try await f.repository.presentation(for: f.key, activation: activation) }
        try await f.reader.waitForCalls(1)
        await f.repository.invalidate([f.key])
        #expect(await notification.value)
        await #expect(throws: V2ProfilePresentationError.inactive) { _ = try await pending.value }
        await f.reader.release(0, with: .success(try f.batch(revision: 1)))
        await f.repository.close()
    }

    @Test("a malformed batch cannot partially install a valid first presentation")
    func atomicBatchValidation() async throws {
        let f = Fixture(), activation = await f.repository.activate()
        let other = V2ProfileViewLookupKey(userID: .init(uuid: UUID()), context: .room(f.room))
        let a = Task { try await f.repository.presentation(for: f.key, activation: activation) }
        let b = Task { try await f.repository.presentation(for: other, activation: activation) }
        try await f.reader.waitForCalls(1)
        let good = try f.value(key: f.key, revision: 1), bad = try f.value(key: other, revision: 1, actor: .init(uuid: UUID()))
        await f.reader.release(0, with: .success(.init(presentations: [f.key: good, other: bad], unavailable: [], serverNow: f.date)))
        await #expect(throws: V2ProfilePresentationError.invalidResponse) { _ = try await a.value }
        await #expect(throws: V2ProfilePresentationError.invalidResponse) { _ = try await b.value }
        #expect(await f.repository.cachedPresentation(for: f.key, activation: activation) == nil)
        await f.repository.close()
    }

    @Test("expired avatar capability does not extend or erase a still-valid name")
    func independentAvatarDeadline() async throws {
        let f = Fixture(), activation = await f.repository.activate(), media = MediaID(uuid: UUID())
        let checksum = try V2ResourceChecksum(value: String(repeating: "a", count: 64))
        let avatar = try V2ResourceAvatarAccess(mediaID: media, variantID: .init(uuid: UUID()), version: 1, checksum: checksum,
            plan: .init(mode: .httpGet, url: #require(URL(string: "https://objects.invalid/avatar")), expiresAt: f.date.addingTimeInterval(0.2), expectedByteCount: 1, checksum: checksum))
        let pending = Task { try await f.repository.presentation(for: f.key, activation: activation) }
        try await f.reader.waitForCalls(1)
        let value = try f.value(key: f.key, revision: 1, media: media)
        await f.reader.release(0, with: .success(.init(presentations: [f.key: value], unavailable: [], serverNow: f.date, avatars: [f.key: avatar])))
        _ = try await pending.value
        let grant = try #require(await f.repository.avatarReadGrant(for: f.key, activation: activation))
        try await Task.sleep(for: .milliseconds(230))
        #expect(await f.repository.avatarReadGrant(for: f.key, activation: activation)?.avatar.plan == nil)
        #expect(await f.repository.avatarReadGrant(for: f.key, activation: activation)?.avatar.mediaID == media)
        #expect(await f.repository.cachedPresentation(for: f.key, activation: activation) != nil)
        try await grant.requireValid()
        await f.repository.invalidate([f.key])
        await #expect(throws: V2ResourceStorageError.unavailable) { try await grant.requireValid() }
        await f.repository.close()
    }

    @Test("a shorter display lease notifies existing rows even when the visible profile is unchanged")
    func shorterLeaseInvalidatesSnapshot() async throws {
        let f = Fixture(), first = await f.repository.activate()
        let updates = try await f.repository.invalidations(for: first)
        let a = Task { try await f.repository.presentation(for: f.key, activation: first) }
        try await f.reader.waitForCalls(1)
        let original = try f.value(key: f.key, revision: 1)
        await f.reader.release(0, with: .success(try f.batch(revision: 1)))
        _ = try await a.value
        let oldDeadline = try #require(await f.repository.authorizationDeadline(for: f.key, activation: first))
        let observed = Task { for await _ in updates { return true }; return false }
        let second = await f.repository.activate()
        let b = Task { try await f.repository.presentation(for: f.key, activation: second) }
        try await f.reader.waitForCalls(2)
        let lease = try V2PresentationAccessLease(actorUserID: f.actor, deviceID: f.device, key: f.key,
            profileRevision: original.view.revision, visibilityRevision: original.view.visibilityRevision,
            contextRevision: 1, observedAt: f.date, validUntil: f.date.addingTimeInterval(30))
        let value = try V2AuthorizedProfilePresentation(view: original.view, lease: lease)
        await f.reader.release(1, with: .success(.init(presentations: [f.key: value], unavailable: [], serverNow: f.date)))
        _ = try await b.value
        #expect(await observed.value)
        let deadline = try #require(await f.repository.authorizationDeadline(for: f.key, activation: first))
        #expect(deadline < oldDeadline)
        await f.repository.close()
    }

    @Test("concurrent close waits for real HTTP completion and closed repositories never reactivate")
    func permanentClose() async throws {
        let f = Fixture(), activation = await f.repository.activate()
        let pending = Task { try await f.repository.presentation(for: f.key, activation: activation) }
        try await f.reader.waitForCalls(1)
        let a = Task { await f.repository.close() }, b = Task { await f.repository.close() }
        await #expect(throws: CancellationError.self) { _ = try await pending.value }
        #expect(await f.repository.diagnostics().inFlight == 1)
        let next = await f.repository.activate()
        await #expect(throws: V2ProfilePresentationError.inactive) { _ = try await f.repository.presentation(for: f.key, activation: next) }
        await f.reader.release(0, with: .success(try f.batch(revision: 1)))
        await a.value; await b.value
        #expect(await f.repository.diagnostics().inFlight == 0)
    }

    @Test("late account throttle completes replacement demand waiting behind the old flight")
    func lateThrottleOnReentry() async throws {
        let f = Fixture(), first = await f.repository.activate()
        let old = Task { try await f.repository.presentation(for: f.key, activation: first) }
        try await f.reader.waitForCalls(1)
        await f.repository.deactivate(first); _ = await old.result
        let second = await f.repository.activate()
        let fresh = Task { try await f.repository.presentation(for: f.key, activation: second) }
        try await wait { await f.repository.diagnostics().waitingConsumers == 1 }
        await f.reader.release(0, with: .failure(V2ProfilePresentationError.throttled(retryAfter: 1)))
        do { _ = try await fresh.value; Issue.record("Expected cooldown") }
        catch V2ProfilePresentationError.throttled(let duration) { #expect(duration > 0 && duration <= 2) }
        #expect(await f.repository.diagnostics().waitingConsumers == 0)
        await f.repository.close()
    }

    @Test("retryable delta creates bounded key backoff without caching a permission denial")
    func pushedRetryable() async throws {
        let f = Fixture(), activation = await f.repository.activate()
        let view = try await f.receiver.beginView(streamID: UUID(), roomID: f.room)
        let binding = try await f.repository.bindAuthorView(view, activation: activation)
        let pending = Task { try await f.repository.presentation(for: f.key, activation: activation) }
        try await f.reader.waitForCalls(1)
        let wire = try V2AuthorPresentationDelta(streamID: view.streamID, viewID: view.viewID, sequence: 1,
            actorUserID: f.actor, deviceID: f.device, roomID: f.room,
            batch: .init(serverNowUnixMilliseconds: 2_000_000_000_000, results: [.retryable(f.key)]), retryAfterMilliseconds: 2_000)
        let delta = try #require(await f.receiver.receive(wire.encoded(), for: view))
        try await f.repository.ingest(delta, binding: binding)
        do { _ = try await pending.value; Issue.record("Expected key backoff") }
        catch V2ProfilePresentationError.throttled(let duration) { #expect(duration > 0 && duration <= 2) }
        await f.reader.release(0, with: .failure(CancellationError()))
        try await wait { await f.repository.diagnostics().inFlight == 0 }
        #expect(await f.repository.cachedPresentation(for: f.key, activation: activation) == nil)
        let other = V2ProfileViewLookupKey(userID: f.author, context: .relationship)
        let available = Task { try await f.repository.presentation(for: other, activation: activation) }
        try await f.reader.waitForCalls(2)
        await f.reader.release(1, with: .success(try f.batch(revision: 1, keys: [other])))
        #expect(try await available.value != nil)
        try await f.repository.ingest(f.received(view: view, revision: 2, sequence: 2), binding: binding)
        #expect(await f.repository.cachedPresentation(for: f.key, activation: activation) != nil)
        await f.repository.close()
    }

    @Test("lower profile, visibility or context observations never replace an accepted value")
    func revisionFloor() async throws {
        let f = Fixture(), first = await f.repository.activate()
        let a = Task { try await f.repository.presentation(for: f.key, activation: first) }
        try await f.reader.waitForCalls(1)
        await f.reader.release(0, with: .success(try f.batch(revision: 5)))
        _ = try await a.value
        let second = await f.repository.activate()
        let b = Task { try await f.repository.presentation(for: f.key, activation: second) }
        try await f.reader.waitForCalls(2)
        await f.reader.release(1, with: .success(try f.batch(revision: 4)))
        await #expect(throws: V2ProfilePresentationError.staleResponse) { _ = try await b.value }
        #expect(await f.repository.cachedPresentation(for: f.key, activation: first)?.view.revision.rawValue == 5)
        #expect(await f.repository.cachedPresentation(for: f.key, activation: second) == nil)
        await f.repository.close()
    }
}

private struct Fixture: Sendable {
    let actor = UserID(uuid: UUID()), device = DeviceID(uuid: UUID()), room = RoomID(uuid: UUID()), author = UserID(uuid: UUID())
    let reader = ControlledReader(), date = Date(timeIntervalSince1970: 2_000_000_000)
    let repository: V2ProfilePresentationRepository
    let receiver: V2AuthorPresentationReceiver
    var key: V2ProfileViewLookupKey { .init(userID: author, context: .room(room)) }
    init(nicknameRevisions: (@Sendable (Set<V2ProfileViewLookupKey>) async throws -> [V2ProfileViewLookupKey: UInt64])? = nil,
         aliasRevisions: (@Sendable (Set<V2ProfileViewLookupKey>) async throws -> [V2ProfileViewLookupKey: UInt64])? = nil) {
        repository = .init(actorUserID: actor, deviceID: device, reader: reader, nicknameRevisions: nicknameRevisions, aliasRevisions: aliasRevisions)
        receiver = .init(actorUserID: actor, deviceID: device)
    }
    func value(key: V2ProfileViewLookupKey, revision: UInt64, actor override: UserID? = nil, media: MediaID? = nil,
               groupMember: V2GroupMemberPresentation? = nil, contactAlias: V2ContactAlias? = nil, state: V2ProfileState = .active,
               authority: V2PresentationAuthorityVersion? = nil) throws -> V2AuthorizedProfilePresentation {
        let rev = try #require(V2ProfileRevision(rawValue: revision))
        let view = try V2ProfileView(userID: key.userID,
            publicIdentity: state == .active ? .init(userID: key.userID, handle: .init("author"), displayName: "Name \(revision)", accountKind: .regular) : nil,
            avatar: state == .active ? media.map { .init(mediaID: $0) } : nil, state: state, revision: rev, visibilityRevision: rev)
        let version = authority ?? .fixture(key, contextRevision: revision)
        let lease = try V2PresentationAccessLease(actorUserID: override ?? actor, deviceID: device, key: key,
            profileRevision: rev, visibilityRevision: rev, contextRevision: version.membershipRevision,
            authorityVersion: version, observedAt: date, validUntil: date.addingTimeInterval(120))
        return try .init(view: view, lease: lease, groupMember: groupMember, contactAlias: contactAlias)
    }
    func batch(revision: UInt64, keys: [V2ProfileViewLookupKey]? = nil) throws -> V2ProfilePresentationBatch {
        .init(presentations: try Dictionary(uniqueKeysWithValues: (keys ?? [key]).map { ($0, try value(key: $0, revision: revision)) }), unavailable: [], serverNow: date)
    }
    func nicknameBatch(_ revision: UInt64) throws -> V2ProfilePresentationBatch {
        let member = try V2GroupMemberPresentation(roomID: room, userID: author, groupNickname: "Nickname \(revision)",
                                                 revision: #require(.init(rawValue: revision)))
        return .init(presentations: [key: try value(key: key, revision: 1, groupMember: member)], unavailable: [], serverNow: date)
    }
    func alias(_ revision: UInt64, name: String? = "Private name") throws -> V2ContactAlias {
        try .init(ownerUserID: actor, targetUserID: author, remarkName: name, revision: #require(.init(rawValue: revision)))
    }
    func aliasBatch(_ revision: UInt64, name: String? = "Private name") throws -> V2ProfilePresentationBatch {
        .init(presentations: [key: try value(key: key, revision: 1, contactAlias: alias(revision, name: name))], unavailable: [], serverNow: date)
    }
    func denied(view: V2AuthorPresentationView, sequence: UInt64, version: V2PresentationAuthorityVersion) async throws -> V2ReceivedAuthorPresentationDelta {
        let delta = try V2AuthorPresentationDelta(streamID: view.streamID, viewID: view.viewID, sequence: sequence,
            actorUserID: actor, deviceID: device, roomID: room,
            batch: .init(serverNowUnixMilliseconds: 2_000_000_000_000, results: [.unavailable(.init(key: key, authorityVersion: version))]))
        return try #require(await receiver.receive(delta.encoded(), for: view))
    }
    func received(view: V2AuthorPresentationView, revision: UInt64, sequence: UInt64 = 1,
                  groupMember: V2GroupMemberPresentation? = nil, contactAlias: V2ContactAlias? = nil, state: V2ProfileState = .active,
                  authority: V2PresentationAuthorityVersion? = nil) async throws -> V2ReceivedAuthorPresentationDelta {
        let delta = try V2AuthorPresentationDelta(streamID: view.streamID, viewID: view.viewID, sequence: sequence,
            actorUserID: actor, deviceID: device, roomID: room,
            batch: .init(serverNowUnixMilliseconds: 2_000_000_000_000, results: [.presentation(value(key: key, revision: revision, groupMember: groupMember, contactAlias: contactAlias, state: state, authority: authority), avatar: nil)]))
        return try #require(await receiver.receive(delta.encoded(), for: view))
    }
}
private actor ControlledReader: V2ProfilePresentationReading {
    private var requests: [[V2ProfileViewLookupKey]] = []
    var calls: Int { requests.count }
    private var continuations: [Int: CheckedContinuation<V2ProfilePresentationBatch, Error>] = [:]
    func readPresentations(_ keys: [V2ProfileViewLookupKey]) async throws -> V2ProfilePresentationBatch {
        let id = requests.count; requests.append(keys)
        return try await withCheckedThrowingContinuation { continuations[id] = $0 }
    }
    func keys(_ id: Int) -> [V2ProfileViewLookupKey] { requests[id] }
    func release(_ id: Int, with result: Result<V2ProfilePresentationBatch, Error>) { continuations.removeValue(forKey: id)?.resume(with: result) }
    func waitForCalls(_ count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while requests.count < count { guard .now < deadline else { throw WaitExpired() }; try await Task.sleep(for: .milliseconds(1)) }
    }
}
private func wait(_ predicate: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !(await predicate()) { guard .now < deadline else { throw WaitExpired() }; try await Task.sleep(for: .milliseconds(1)) }
}
private struct WaitExpired: Error {}

private actor NicknameFloors {
    private var values: [V2ProfileViewLookupKey: UInt64] = [:]
    func set(_ key: V2ProfileViewLookupKey, revision: UInt64) { values[key] = revision }
    func read(_ keys: Set<V2ProfileViewLookupKey>) -> [V2ProfileViewLookupKey: UInt64] {
        Dictionary(uniqueKeysWithValues: keys.map { ($0, values[$0] ?? 0) })
    }
}
