import Foundation
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Visible profile interests and early author supplements", .timeLimit(.minutes(1)))
struct V2ProfileVisiblePageTests {
    @Test("a visible page declares author delivery before its coordinator task starts")
    func activationDeclaresAuthorDelivery() async throws {
        let f = Fixture(), page = await f.repository.activateVisiblePage(delivery: .authorStream)
        let row = try await f.repository.retainVisibleInterest(for: f.key, activation: page)
        let read = Task { try await f.repository.presentation(for: f.key, activation: page) }
        // Deliberately do not start the coordinator or call expectAuthorDelivery.
        // A runnable UI read can precede that task by more than one merge window.
        try await Task.sleep(for: .milliseconds(120))
        #expect(await f.reader.calls == 0)
        #expect(await f.repository.cachedSnapshot(for: f.key, activation: page) == nil)
        let (view, binding) = try await f.bind(page)
        try await f.repository.ingest(f.delta(view, keys: [f.key]), binding: binding)
        #expect(try await read.value?.view.revision.rawValue == 2)
        #expect(await f.reader.calls == 0)
        await f.repository.releaseVisibleInterest(row); await f.repository.close()
    }

    @Test("an expected author stream gets a bounded chance before HTTP starts")
    func expectedStreamAvoidsRacingHTTP() async throws {
        let f = Fixture(), page = await f.repository.activateVisiblePage()
        try await f.repository.expectAuthorDelivery(for: page)
        let row = try await f.repository.retainVisibleInterest(for: f.key, activation: page)
        let read = Task { try await f.repository.presentation(for: f.key, activation: page) }
        // Real socket/SQL latency exceeds the ordinary 32 ms merge window.
        try await Task.sleep(for: .milliseconds(120))
        #expect(await f.reader.calls == 0)
        let (view, binding) = try await f.bind(page)
        try await f.repository.ingest(f.delta(view, keys: [f.key]), binding: binding)
        #expect(try await read.value?.view.revision.rawValue == 2)
        #expect(await f.reader.calls == 0)
        await f.repository.releaseVisibleInterest(row); await f.repository.close()
    }

    @Test("a missing author stream cannot defer HTTP indefinitely")
    func missingExpectedStreamFallsBack() async throws {
        let f = Fixture(), page = await f.repository.activateVisiblePage(delivery: .authorStream)
        let row = try await f.repository.retainVisibleInterest(for: f.key, activation: page)
        let start = ContinuousClock.now
        #expect(try await f.repository.presentation(for: f.key, activation: page) == nil)
        #expect(start.duration(to: .now) >= .seconds(2))
        #expect(start.duration(to: .now) < .seconds(4))
        #expect(await f.reader.calls == 1)
        await f.repository.releaseVisibleInterest(row); await f.repository.close()
    }

    @Test("an unrelated explicit query is not delayed behind an author stream")
    func independentDemandBypassesAuthorWait() async throws {
        let f = Fixture(), page = await f.repository.activateVisiblePage()
        try await f.repository.expectAuthorDelivery(for: page)
        let row = try await f.repository.retainVisibleInterest(for: f.key, activation: page)
        let waiting = Task { try await f.repository.presentation(for: f.key, activation: page) }
        try await Task.sleep(for: .milliseconds(80))
        let ordinary = await f.repository.activate(), start = ContinuousClock.now
        #expect(try await f.repository.presentation(for: f.key, activation: ordinary) == nil)
        #expect(start.duration(to: .now) < .seconds(1))
        _ = try await waiting.value
        #expect(await f.reader.calls == 1)
        await f.repository.releaseVisibleInterest(row); await f.repository.close()
    }

    @Test("denial tombstones have a fixed bound and overflow requires a fresh causal page")
    func boundedAuthorityDenials() async throws {
        let f = Fixture(), page = await f.repository.activateVisiblePage()
        let (view, binding) = try await f.bind(page)
        for sequence in 1...126 {
            let entries = try (0..<16).map { _ -> V2ReceivedAuthorPresentationEntry in
                let key = f.freshKey()
                return .unavailable(try .init(key: key, authorityVersion: .fixture(key, contextRevision: 2)), until: .now + .seconds(30))
            }
            try await f.repository.ingest(.init(view: view, sequence: UInt64(sequence), entries: entries), binding: binding)
        }
        let state = await f.repository.diagnostics()
        #expect(state.authorityDenials == 2_000 && state.bufferedAuthorEntries <= 64 && state.trackedKeys == 0)
        let row = try await f.repository.retainVisibleInterest(for: f.key, activation: page)
        try await f.repository.ingest(f.delta(view, keys: [f.key], authoritySequence: 100), binding: binding)
        #expect(await f.repository.cachedSnapshot(for: f.key, activation: page) == nil)
        let (fresh, replacement) = try await f.bind(page)
        try await f.repository.ingest(f.delta(fresh, keys: [f.key], authoritySequence: 100), binding: replacement)
        #expect(await f.repository.cachedSnapshot(for: f.key, activation: page) != nil)
        await f.repository.releaseVisibleInterest(row); await f.repository.close()
        #expect(await f.repository.diagnostics().authorityDenials == 0)
    }

    @Test("distinct visible authors are bounded without truncating the advertised snapshot")
    func distinctAuthorBudget() async throws {
        let f = Fixture(), page = await f.repository.activateVisiblePage()
        var rows: [V2ProfileVisibleInterest] = []
        for _ in 0..<V2AuthorPresentationInterests.maximumAuthors {
            rows.append(try await f.repository.retainVisibleInterest(for: f.freshKey(), activation: page))
        }
        let next = f.freshKey()
        await #expect(throws: V2ProfilePresentationError.overloaded) {
            _ = try await f.repository.retainVisibleInterest(for: next, activation: page)
        }
        #expect(try await f.repository.visibleAuthorIDs(for: page, roomID: f.room).count == 128)
        let duplicate = try await f.repository.retainVisibleInterest(for: rows[0].key, activation: page)
        await f.repository.releaseVisibleInterest(duplicate)
        await f.repository.releaseVisibleInterest(rows.removeLast())
        rows.append(try await f.repository.retainVisibleInterest(for: next, activation: page))
        #expect(try await f.repository.visibleAuthorIDs(for: page, roomID: f.room).contains(next.userID))
        for row in rows { await f.repository.releaseVisibleInterest(row) }
        await f.repository.close()
    }
    @Test("the account key budget spans pages while duplicate keys share one slot")
    func accountVisibleKeyBudget() async throws {
        let f = Fixture(), a = await f.repository.activateVisiblePage(), b = await f.repository.activateVisiblePage()
        var rows: [V2ProfileVisibleInterest] = []
        for index in 0..<V2AuthorPresentationInterests.maximumAuthors {
            rows.append(try await f.repository.retainVisibleInterest(for: f.freshKey(), activation: index % 2 == 0 ? a : b))
        }
        let next = f.freshKey()
        await #expect(throws: V2ProfilePresentationError.overloaded) {
            _ = try await f.repository.retainVisibleInterest(for: next, activation: b)
        }
        let duplicate = try await f.repository.retainVisibleInterest(for: rows[0].key, activation: b)
        #expect(try await f.repository.visibleProfileKeys(for: [a, b]).count == 128)
        await f.repository.releaseVisibleInterest(rows.removeFirst())
        await #expect(throws: V2ProfilePresentationError.overloaded) {
            _ = try await f.repository.retainVisibleInterest(for: next, activation: a)
        }
        await f.repository.releaseVisibleInterest(duplicate)
        rows.append(try await f.repository.retainVisibleInterest(for: next, activation: a))
        #expect(try await f.repository.visibleProfileKeys(for: [a, b]).count == 128)
        for row in rows { await f.repository.releaseVisibleInterest(row) }
        #expect(try await f.repository.visibleProfileKeys(for: [a, b]).isEmpty)
        await f.repository.close()
    }

    @Test("offscreen snapshot subscriptions yield capacity to visible rows on another page")
    func cachedRowsCannotStarveAnotherPage() async throws {
        let f = Fixture(), list = await f.repository.activateVisiblePage(), chat = await f.repository.activateVisiblePage()
        var cached: [V2ProfileVisibleInterest] = []
        for _ in 0..<V2AuthorPresentationInterests.maximumAuthors {
            cached.append(try await f.repository.retainCachedVisibleInterest(for: f.freshKey(), activation: list))
        }
        let pinned = try await f.repository.retainVisibleInterest(for: cached[0].key, activation: list)
        let newest = f.freshKey()
        let visible = try await f.repository.retainVisibleInterest(for: newest, activation: chat)
        let keys = try await f.repository.visibleProfileKeys(for: [list, chat])
        #expect(keys.count == 128)
        #expect(keys.contains(pinned.key) && keys.contains(newest))
        #expect(await f.repository.diagnostics().visibleRows == 129)
        // Releasing an evicted snapshot is idempotent and cannot steal the
        // replacement row's capacity or subscription.
        for row in cached { await f.repository.releaseVisibleInterest(row) }
        #expect(try await f.repository.visibleProfileKeys(for: [list, chat]).count == 2)
        #expect(await f.repository.diagnostics().visibleRows == 2)
        await f.repository.releaseVisibleInterest(pinned)
        await f.repository.deactivate(chat)
        #expect(await f.repository.diagnostics().visibleRows == 0)
        await f.repository.releaseVisibleInterest(visible)
        await f.repository.close()
    }

    @Test("detaching one bound page blocks delayed ingestion and candidate promotion without deactivating HTTP")
    func detachDoesNotReviveFromOldView() async throws {
        let f = Fixture(), a = await f.repository.activateVisiblePage(), b = await f.repository.activateVisiblePage()
        let receiver = V2AuthorPresentationReceiver(actorUserID: f.actor, deviceID: f.device)
        let view = try await receiver.beginView(streamID: UUID(), roomID: f.room)
        let binding = try await f.repository.bindAuthorView(view, activations: [a, b])
        let rowA = try await f.repository.retainVisibleInterest(for: f.key, activation: a)
        let rowB = try await f.repository.retainVisibleInterest(for: f.key, activation: b)
        try await f.repository.ingest(f.delta(view, keys: [f.key]), binding: binding)
        #expect(try await f.repository.presentation(for: f.key, activation: a) != nil)
        #expect(try await f.repository.presentation(for: f.key, activation: b) != nil)
        await f.repository.detachAuthorPage(b)
        #expect(await f.repository.cachedSnapshot(for: f.key, activation: b) == nil)
        let receipt = try await f.repository.ingest(f.delta(view, keys: [f.key], authoritySequence: 1), binding: binding)
        #expect(receipt?.keys == [f.key])
        #expect(await f.repository.cachedSnapshot(for: f.key, activation: a) != nil)
        #expect(await f.repository.cachedSnapshot(for: f.key, activation: b) == nil)
        #expect(await f.repository.diagnostics().bufferedAuthorEntries == 0)
        await #expect(throws: V2ProfilePresentationError.inactive) {
            _ = try await f.repository.bindAuthorView(view, activations: [a, b])
        }
        // Detachment owns author grants only: the activation and row tokens
        // remain usable by the caller's independently authorized HTTP path.
        #expect(try await f.repository.visibleProfileKeys(for: [b]) == [f.key])
        for row in [rowA, rowB] { await f.repository.releaseVisibleInterest(row) }
        await f.repository.close()
    }

    @Test("a supplement arriving before its row satisfies the later visible read without HTTP")
    func earlySupplement() async throws {
        let f = Fixture(), page = await f.repository.activateVisiblePage()
        let (view, binding) = try await f.bind(page)
        try await f.repository.ingest(f.delta(view, keys: [f.key]), binding: binding)
        #expect(await f.repository.diagnostics().bufferedAuthorEntries == 1)
        #expect(await f.repository.cachedSnapshot(for: f.key, activation: page) == nil)
        let a = try await f.repository.retainVisibleInterest(for: f.key, activation: page)
        #expect(try await f.repository.presentation(for: f.key, activation: page)?.view.revision.rawValue == 2)
        #expect(await f.reader.calls == 0)
        let b = try await f.repository.retainVisibleInterest(for: f.key, activation: page)
        await f.repository.releaseVisibleInterest(a)
        await f.repository.releaseVisibleInterest(a)
        #expect(await f.repository.cachedSnapshot(for: f.key, activation: page) != nil)
        #expect(await f.repository.diagnostics().visibleRows == 1)
        await f.repository.releaseVisibleInterest(b)
        #expect(await f.repository.cachedSnapshot(for: f.key, activation: page) == nil)
        let c = try await f.repository.retainVisibleInterest(for: f.key, activation: page)
        #expect(try await f.repository.presentation(for: f.key, activation: page) != nil)
        #expect(await f.reader.calls == 0)
        await f.repository.releaseVisibleInterest(c)
        await f.repository.close()
    }

    @Test("one early supplement serves only its bound pages and closing one page preserves the other")
    func sharedViewPagesRetainIndependentGrants() async throws {
        let f = Fixture()
        let first = await f.repository.activateVisiblePage(), second = await f.repository.activateVisiblePage()
        let receiver = V2AuthorPresentationReceiver(actorUserID: f.actor, deviceID: f.device)
        let view = try await receiver.beginView(streamID: UUID(), roomID: f.room)
        let binding = try await f.repository.bindAuthorView(view, activations: [first, second])
        let delta = try f.delta(view, keys: [f.key], large: true)
        #expect(try await f.repository.ingest(delta, binding: binding) == nil)
        let rowA = try await f.repository.retainVisibleInterest(for: f.key, activation: first)
        #expect(try await f.repository.presentation(for: f.key, activation: first) != nil)
        let firstGrant = try #require(await f.repository.avatarReadGrant(for: f.key, activation: first))
        #expect(await f.repository.cachedSnapshot(for: f.key, activation: second) == nil)
        #expect(await f.repository.diagnostics().bufferedAuthorEntries == 1)
        let rowB = try await f.repository.retainVisibleInterest(for: f.key, activation: second)
        #expect(try await f.repository.presentation(for: f.key, activation: second) != nil)
        #expect(await f.repository.cachedSnapshot(for: f.key, activation: second) != nil)
        #expect(await f.repository.diagnostics().bufferedAuthorEntries == 0)
        // Promoting the same received access for another page must not revoke
        // an in-flight image read already owned by the first page.
        try await firstGrant.requireValid()
        await f.repository.deactivate(first)
        #expect(await f.repository.cachedSnapshot(for: f.key, activation: first) == nil)
        let receipt = try await f.repository.ingest(f.delta(view, keys: [f.key], authoritySequence: 1), binding: binding)
        #expect(receipt?.userIDs == [f.key.userID])
        #expect(await f.repository.cachedSnapshot(for: f.key, activation: second) != nil)
        #expect(await f.reader.calls == 0)
        await f.repository.releaseVisibleInterest(rowA)
        await f.repository.releaseVisibleInterest(rowB)
        await f.repository.deactivate(second)
        await #expect(throws: V2ProfilePresentationError.inactive) {
            try await f.repository.ingest(delta, binding: binding)
        }
        await f.repository.close()
    }

    @Test("an applied delta remains available to another bound page whose row appears later")
    func appliedDeltaAlsoStagesForOtherBoundPages() async throws {
        let f = Fixture()
        let first = await f.repository.activateVisiblePage(), second = await f.repository.activateVisiblePage()
        let rowA = try await f.repository.retainVisibleInterest(for: f.key, activation: first)
        let receiver = V2AuthorPresentationReceiver(actorUserID: f.actor, deviceID: f.device)
        let view = try await receiver.beginView(streamID: UUID(), roomID: f.room)
        let binding = try await f.repository.bindAuthorView(view, activations: [first, second])
        let receipt = try await f.repository.ingest(f.delta(view, keys: [f.key]), binding: binding)
        #expect(receipt?.userIDs == [f.key.userID])
        #expect(await f.repository.diagnostics().bufferedAuthorEntries == 1)
        let rowB = try await f.repository.retainVisibleInterest(for: f.key, activation: second)
        #expect(try await f.repository.presentation(for: f.key, activation: second) != nil)
        #expect(await f.repository.cachedSnapshot(for: f.key, activation: second) != nil)
        #expect(await f.reader.calls == 0)
        await f.repository.unbindAuthorView(binding)
        #expect(await f.repository.cachedSnapshot(for: f.key, activation: first) == nil)
        #expect(await f.repository.cachedSnapshot(for: f.key, activation: second) == nil)
        await f.repository.releaseVisibleInterest(rowA)
        await f.repository.releaseVisibleInterest(rowB)
        await f.repository.close()
    }

    @Test("joining a page requires a new nonce even when it existed before the old nonce")
    func bindingCannotExpandAnExistingNonce() async throws {
        let f = Fixture()
        let first = await f.repository.activateVisiblePage(), second = await f.repository.activateVisiblePage()
        let rowA = try await f.repository.retainVisibleInterest(for: f.key, activation: first)
        let receiver = V2AuthorPresentationReceiver(actorUserID: f.actor, deviceID: f.device)
        let stream = UUID(), view = try await receiver.beginView(streamID: stream, roomID: f.room)
        let original = try await f.repository.bindAuthorView(view, activation: first)
        try await f.repository.ingest(f.delta(view, keys: [f.key]), binding: original)
        await #expect(throws: V2ProfilePresentationError.inactive) {
            try await f.repository.bindAuthorView(view, activations: [first, second])
        }
        #expect(await f.repository.cachedSnapshot(for: f.key, activation: first) != nil)
        let nextView = try await receiver.beginView(streamID: stream, roomID: f.room)
        let joined = try await f.repository.bindAuthorView(nextView, activations: [first, second])
        #expect(await f.repository.cachedSnapshot(for: f.key, activation: first) != nil)
        #expect(await f.repository.cachedSnapshot(for: f.key, activation: second) == nil)
        let rowB = try await f.repository.retainVisibleInterest(for: f.key, activation: second)
        try await f.repository.ingest(f.delta(nextView, keys: [f.key]), binding: joined)
        #expect(await f.repository.cachedSnapshot(for: f.key, activation: second) != nil)
        // Late cleanup from the former page set cannot tear down the new set.
        await f.repository.unbindAuthorView(original)
        #expect(await f.repository.cachedSnapshot(for: f.key, activation: first) != nil)
        #expect(await f.repository.cachedSnapshot(for: f.key, activation: second) != nil)
        await f.repository.releaseVisibleInterest(rowA)
        await f.repository.releaseVisibleInterest(rowB)
        await f.repository.close()
    }

    @Test("unbinding does not allow a nonce to be reused for another page or replayed after renewal")
    func retiredNonceDoesNotExpandOrReplay() async throws {
        let f = Fixture()
        let first = await f.repository.activateVisiblePage(), second = await f.repository.activateVisiblePage()
        let receiver = V2AuthorPresentationReceiver(actorUserID: f.actor, deviceID: f.device)
        let stream = UUID(), oldView = try await receiver.beginView(streamID: stream, roomID: f.room)
        let original = try await f.repository.bindAuthorView(oldView, activation: first)
        await f.repository.unbindAuthorView(original)
        await #expect(throws: V2ProfilePresentationError.inactive) {
            try await f.repository.bindAuthorView(oldView, activations: [first, second])
        }
        let nextView = try await receiver.beginView(streamID: stream, roomID: f.room)
        let joined = try await f.repository.bindAuthorView(nextView, activations: [first, second])
        await f.repository.unbindAuthorView(joined)
        await #expect(throws: V2ProfilePresentationError.inactive) {
            try await f.repository.bindAuthorView(oldView, activation: first)
        }
        await f.repository.close()
    }

    @Test("a new page cannot borrow another page's early supplement or its retained grants")
    func pageIsolation() async throws {
        let f = Fixture(), page = await f.repository.activateVisiblePage()
        let (view, binding) = try await f.bind(page)
        try await f.repository.ingest(f.delta(view, keys: [f.key]), binding: binding)
        let next = await f.repository.activateVisiblePage()
        let row = try await f.repository.retainVisibleInterest(for: f.key, activation: next)
        #expect(try await f.repository.presentation(for: f.key, activation: next) == nil)
        #expect(await f.reader.calls == 1)
        await f.repository.releaseVisibleInterest(row)
        await f.repository.deactivate(page)
        #expect(await f.repository.diagnostics().bufferedAuthorEntries == 0)
        await f.repository.close()
    }

    @Test("early supplements have both entry and encoded-byte budgets", arguments: [false, true])
    func candidateBudgets(large: Bool) async throws {
        let f = Fixture(), page = await f.repository.activateVisiblePage()
        let (view, binding) = try await f.bind(page)
        for _ in 0..<80 {
            let key = f.freshKey()
            try await f.repository.ingest(f.delta(view, keys: [key], large: large), binding: binding)
        }
        let state = await f.repository.diagnostics()
        #expect(state.bufferedAuthorEntries <= 64 && state.bufferedAuthorBytes <= 256 * 1_024)
        #expect(large ? state.bufferedAuthorEntries < 64 : state.bufferedAuthorEntries == 64)
        #expect(state.cachedBytes == 0 && state.trackedKeys == 0 && state.inFlight == 0)
        await f.repository.close()
    }

    @Test("an expired early grant falls back to HTTP without extending either deadline")
    func expiredCandidate() async throws {
        let f = Fixture(), page = await f.repository.activateVisiblePage()
        let (view, binding) = try await f.bind(page)
        try await f.repository.ingest(f.delta(view, keys: [f.key], lifetime: .milliseconds(10)), binding: binding)
        try await Task.sleep(for: .milliseconds(20))
        let row = try await f.repository.retainVisibleInterest(for: f.key, activation: page)
        #expect(try await f.repository.presentation(for: f.key, activation: page) == nil)
        #expect(await f.reader.calls == 1)
        #expect(await f.repository.diagnostics().bufferedAuthorEntries == 0)
        await f.repository.releaseVisibleInterest(row); await f.repository.close()
    }

    @Test("releasing a denied key does not let the old nonce resurrect it after its state was evicted")
    func deniedInterestReentry() async throws {
        let f = Fixture(), page = await f.repository.activateVisiblePage()
        let (view, binding) = try await f.bind(page)
        let old = try await f.repository.retainVisibleInterest(for: f.key, activation: page)
        await f.repository.invalidate([f.key])
        await f.repository.releaseVisibleInterest(old)
        #expect(await f.repository.diagnostics().trackedKeys == 0)
        try await f.repository.ingest(f.delta(view, keys: [f.key]), binding: binding)
        #expect(await f.repository.diagnostics().bufferedAuthorEntries == 0)
        let row = try await f.repository.retainVisibleInterest(for: f.key, activation: page)
        try await f.repository.ingest(f.delta(view, keys: [f.key]), binding: binding)
        #expect(await f.repository.cachedSnapshot(for: f.key, activation: page) == nil)
        let (fresh, replacement) = try await f.bind(page)
        try await f.repository.ingest(f.delta(fresh, keys: [f.key]), binding: replacement)
        #expect(await f.repository.cachedSnapshot(for: f.key, activation: page) != nil)
        await f.repository.releaseVisibleInterest(row); await f.repository.close()
    }

    @Test("an early supplement is discarded after five seconds even when its display lease is still live")
    func candidateAgeLimit() async throws {
        let f = Fixture(), page = await f.repository.activateVisiblePage()
        let (view, binding) = try await f.bind(page)
        try await f.repository.ingest(f.delta(view, keys: [f.key]), binding: binding)
        try await Task.sleep(for: .milliseconds(5_050))
        let row = try await f.repository.retainVisibleInterest(for: f.key, activation: page)
        #expect(try await f.repository.presentation(for: f.key, activation: page) == nil)
        #expect(await f.reader.calls == 1)
        await f.repository.releaseVisibleInterest(row); await f.repository.close()
    }

    @Test("evicting a negative candidate preserves its authority floor and permits a newer observation")
    func evictedNegative() async throws {
        let f = Fixture(), page = await f.repository.activateVisiblePage()
        let (view, binding) = try await f.bind(page)
        try await f.repository.ingest(.init(view: view, sequence: 1,
            entries: [.unavailable(.init(key: f.key, authorityVersion: .fixture(f.key, contextRevision: 2)), until: .now + .seconds(30))]), binding: binding)
        for _ in 0..<64 { try await f.repository.ingest(f.delta(view, keys: [f.freshKey()]), binding: binding) }
        let row = try await f.repository.retainVisibleInterest(for: f.key, activation: page)
        try await f.repository.ingest(f.delta(view, keys: [f.key]), binding: binding)
        #expect(await f.repository.cachedSnapshot(for: f.key, activation: page) == nil)
        try await f.repository.ingest(f.delta(view, keys: [f.key], authoritySequence: 1), binding: binding)
        #expect(await f.repository.cachedSnapshot(for: f.key, activation: page) != nil)
        await f.repository.releaseVisibleInterest(row); await f.repository.close()
    }

    @Test("coalesced notifications preserve distinct keys while unchanged keys keep their revision")
    func completeRevisionSnapshot() async throws {
        let f = Fixture(), page = await f.repository.activateVisiblePage(), other = f.freshKey(), stable = f.freshKey()
        _ = try await f.repository.invalidations(for: page)
        let rows = try await [f.key, other, stable].asyncMap { try await f.repository.retainVisibleInterest(for: $0, activation: page) }
        await f.repository.invalidate([f.key]); await f.repository.invalidate([other])
        let versions = try await f.repository.invalidationRevisions(for: page)
        #expect(versions.count == 2 && versions[f.key] != nil && versions[other] != nil && versions[stable] == nil)
        for row in rows { await f.repository.releaseVisibleInterest(row) }
        #expect(try await f.repository.invalidationRevisions(for: page).isEmpty)
        await f.repository.close()
    }

    @Test("visible interest and historical grant budgets do not limit a long page to its first 256 authors")
    func longScroll() async throws {
        let f = Fixture(), page = await f.repository.activateVisiblePage()
        let (view, binding) = try await f.bind(page)
        for _ in 0..<2_025 {
            let key = f.freshKey(), row = try await f.repository.retainVisibleInterest(for: key, activation: page)
            try await f.repository.ingest(f.delta(view, keys: [key]), binding: binding)
            #expect(await f.repository.cachedSnapshot(for: key, activation: page) != nil)
            await f.repository.releaseVisibleInterest(row)
        }
        let state = await f.repository.diagnostics()
        #expect(state.visibleRows == 0 && state.trackedKeys <= 2_000 && state.cachedBytes <= 2 * 1_024 * 1_024)
        #expect(await f.reader.calls == 0)
        await f.repository.close()
    }

    @Test("visible-row admission and unretained reads remain bounded")
    func rowBudget() async throws {
        let f = Fixture(), page = await f.repository.activateVisiblePage()
        await #expect(throws: V2ProfilePresentationError.inactive) { _ = try await f.repository.presentation(for: f.key, activation: page) }
        var rows: [V2ProfileVisibleInterest] = []
        for _ in 0..<512 { rows.append(try await f.repository.retainVisibleInterest(for: f.key, activation: page)) }
        await #expect(throws: V2ProfilePresentationError.overloaded) { _ = try await f.repository.retainVisibleInterest(for: f.key, activation: page) }
        await f.repository.releaseVisibleInterest(rows.removeLast())
        rows.append(try await f.repository.retainVisibleInterest(for: f.key, activation: page))
        await f.repository.deactivate(page)
        #expect(await f.repository.diagnostics().visibleRows == 0)
        for row in rows { await f.repository.releaseVisibleInterest(row) }
        #expect(await f.repository.diagnostics().visibleRows == 0)
        await f.repository.close()
    }
}

private struct Fixture: Sendable {
    let actor = UserID(uuid: UUID()), device = DeviceID(uuid: UUID()), room = RoomID(uuid: UUID())
    let key: V2ProfileViewLookupKey
    let reader = Reader()
    let repository: V2ProfilePresentationRepository
    init() {
        key = .init(userID: .init(uuid: UUID()), context: .room(room))
        repository = .init(actorUserID: actor, deviceID: device, reader: reader)
    }
    func freshKey() -> V2ProfileViewLookupKey { .init(userID: .init(uuid: UUID()), context: .room(room)) }
    func bind(_ page: V2ProfilePageActivation) async throws -> (V2AuthorPresentationView, V2ProfileAuthorBinding) {
        let receiver = V2AuthorPresentationReceiver(actorUserID: actor, deviceID: device)
        let view = try await receiver.beginView(streamID: UUID(), roomID: room)
        return (view, try await repository.bindAuthorView(view, activation: page))
    }
    func delta(_ view: V2AuthorPresentationView, keys: [V2ProfileViewLookupKey], large: Bool = false,
               lifetime: Duration = .seconds(120), authoritySequence: UInt64 = 0) throws -> V2ReceivedAuthorPresentationDelta {
        let now = Date(), rev = try #require(V2ProfileRevision(rawValue: 2))
        return .init(view: view, sequence: 1, entries: try keys.map { key in
            let media = MediaID(uuid: UUID())
            let profile = try V2ProfileView(userID: key.userID,
                publicIdentity: .init(userID: key.userID, handle: .init("author"), displayName: "Author", accountKind: .regular),
                avatar: large ? .init(mediaID: media) : nil, state: .active, revision: rev, visibilityRevision: rev)
            let presentation = try V2AuthorizedProfilePresentation(view: profile, lease: .init(actorUserID: actor, deviceID: device, key: key,
                profileRevision: rev, visibilityRevision: rev, contextRevision: 2,
                authorityVersion: .fixture(key, contextRevision: 2, controlSequence: authoritySequence),
                observedAt: now, validUntil: now.addingTimeInterval(120)))
            let checksum = try V2ResourceChecksum(value: String(repeating: "a", count: 64))
            let avatar: V2ResourceAvatarAccess? = large ? try .init(mediaID: media, variantID: .init(uuid: UUID()), version: 1, checksum: checksum,
                plan: .init(mode: .httpGet, url: #require(URL(string: "https://delivery.invalid/avatar")),
                    headers: [.init(name: "X-Object-Token", value: String(repeating: "x", count: 8_000), kind: .objectCapability)],
                    expiresAt: now.addingTimeInterval(120), expectedByteCount: 1, checksum: checksum)) : nil
            let deadline = view.started + lifetime
            return .presentation(presentation, avatar: avatar, presentationDeadline: deadline, avatarDeadline: large ? deadline : nil)
        })
    }
}
private actor Reader: V2ProfilePresentationReading {
    var calls = 0
    func readPresentations(_ keys: [V2ProfileViewLookupKey]) -> V2ProfilePresentationBatch {
        calls += 1
        return .init(presentations: [:], denials: Dictionary(uniqueKeysWithValues: keys.map {
            ($0, V2PresentationAuthorityVersion.fixture($0, contextRevision: 2))
        }), serverNow: Date())
    }
}
private extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        for item in self { result.append(try await transform(item)) }
        return result
    }
}
