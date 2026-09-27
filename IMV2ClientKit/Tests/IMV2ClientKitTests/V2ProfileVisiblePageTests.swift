import Foundation
import IMV2Core
@testable import IMV2ClientKit
import Testing

@Suite("Visible profile interests and early author supplements", .timeLimit(.minutes(1)))
struct V2ProfileVisiblePageTests {
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

    @Test("evicting a negative candidate preserves its nonce fence")
    func evictedNegative() async throws {
        let f = Fixture(), page = await f.repository.activateVisiblePage()
        let (view, binding) = try await f.bind(page)
        try await f.repository.ingest(.init(view: view, entries: [.unavailable(f.key, until: .now + .seconds(30))]), binding: binding)
        for _ in 0..<64 { try await f.repository.ingest(f.delta(view, keys: [f.freshKey()]), binding: binding) }
        let row = try await f.repository.retainVisibleInterest(for: f.key, activation: page)
        try await f.repository.ingest(f.delta(view, keys: [f.key]), binding: binding)
        #expect(await f.repository.cachedSnapshot(for: f.key, activation: page) == nil)
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
               lifetime: Duration = .seconds(120)) throws -> V2ReceivedAuthorPresentationDelta {
        let now = Date(), rev = try #require(V2ProfileRevision(rawValue: 2))
        return .init(view: view, entries: try keys.map { key in
            let media = MediaID(uuid: UUID())
            let profile = try V2ProfileView(userID: key.userID,
                publicIdentity: .init(userID: key.userID, handle: .init("author"), displayName: "Author", accountKind: .regular),
                avatar: large ? .init(mediaID: media) : nil, state: .active, revision: rev, visibilityRevision: rev)
            let presentation = try V2AuthorizedProfilePresentation(view: profile, lease: .init(actorUserID: actor, deviceID: device, key: key,
                profileRevision: rev, visibilityRevision: rev, contextRevision: 2, observedAt: now, validUntil: now.addingTimeInterval(120)))
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
        return .init(presentations: [:], unavailable: Set(keys), serverNow: Date())
    }
}
private extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        for item in self { result.append(try await transform(item)) }
        return result
    }
}
