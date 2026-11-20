import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core
import IMV2ClientRuntime

struct SharedProfile: Encodable, Sendable {
    let page: String
    let userID: String; let name: String; let handle: String; let alias: String?
    let aliasRevision: UInt64?
    let groupNickname: String?
    let groupNicknameRevision: UInt64?
    let remainingMilliseconds: Int64; let avatar: String?
}
/// Only authorized presentation values cross the binding. Files, object capabilities and
/// account credentials never cross it; decoded pixels retain the original grant's deadline.
actor SharedPeople {
    private struct Page {
        let activation: V2ProfilePageActivation
        let context: V2ProfileViewContext
        var keys: [V2ProfileViewLookupKey]
        var selected: UserID?
        var loader: Task<Void, Never>?
        var observer: Task<Void, Never>?
        var image: (key: V2ProfileViewLookupKey, grant: V2AvatarReadGrant, data: Data)?
    }
    private let repository: V2ProfilePresentationRepository
    private let names: V2ProfileNameService
    private let store: GRDBV2LocalSyncStore
    private var pages: [String: Page] = [:]
    private var work: SharedWork?
    private var groupNickname: SharedGroupNickname?
    private let resources: V2ResourceService
    private var failure: SharedFailure?

    init(store: GRDBV2LocalSyncStore, profiles: V2ProfileService, resources: V2ResourceService) {
        self.store = store
        repository = profiles.presentations
        names = profiles.names
        self.resources = resources
    }

    func handlers() -> [V2OperationWorkDispatcher.Handler] { names.handlers() }

    /// Activates one bounded page of authorized presentations. Reusing the same keys keeps the
    /// existing activation and cache; changing them replaces the page and releases its interest.
    func show(page: String, ids: [String], context: V2ProfileViewContext) async throws {
        guard page.utf8.count <= 128, ids.count <= 50 else { throw SharedFailure.invalidInput }
        let next = try ids.map { V2ProfileViewLookupKey(userID: try UserID($0), context: context) }
        if let existing = pages[page], existing.keys == next, existing.context == context { return }
        await clear(page: page)
        guard !next.isEmpty else { return }
        let activation = await repository.activate()
        var value = Page(activation: activation, context: context, keys: next)
        value.loader = Task { [repository] in
            await withTaskGroup(of: Void.self) { group in
                for key in next { group.addTask { _ = try? await repository.presentation(for: key, activation: activation) } }
            }
        }
        pages[page] = value
    }
    func showContacts(_ ids: [String]) async throws {
        try await show(page: "contacts", ids: Array(ids.prefix(50)), context: .relationship)
    }
    /// Waits for the page's initial presentations so callers can render names immediately.
    func load(page: String) async { await pages[page]?.loader?.value }
    func open(_ id: UserID, context: V2ProfileViewContext) async throws {
        let pageID = "selected"
        await clear(page: pageID)
        work = nil
        let key = V2ProfileViewLookupKey(userID: id, context: context)
        let activation = await repository.activate()
        var value = Page(activation: activation, context: context, keys: [key], selected: id)
        pages[pageID] = value
        _ = try await repository.presentation(for: key, activation: activation)
        try Task.checkCancellation()
        if context == .relationship {
            _ = try await names.refresh(.contact(id))
            value.observer = Task { [weak self] in
                guard let self else { return }
                do {
                    for try await row in await self.names.updates(.contact(id)) {
                        await self.publish(row, id: id, key: key, pageID: pageID)
                    }
                } catch is CancellationError {} catch { await self.fail(error) }
            }
            if pages[pageID]?.activation == activation {
                pages[pageID]?.observer = value.observer
            } else {
                value.observer?.cancel()
            }
        }
        // A missing/failed avatar must not discard an otherwise authorized contact card.
        do { try await loadAvatar(key, page: pageID) }
        catch is CancellationError { throw CancellationError() }
        catch { pages[pageID]?.image = nil }
    }
    private func publish(_ row: V2NameIntentSnapshot?, id: UserID, key: V2ProfileViewLookupKey, pageID: String) async {
        work = row.map { SharedWork(id: $0.work.id.uuidString, kind: "contactAlias", target: id.rawValue,
            status: $0.work.execution.isTerminal ? $0.work.execution.rawValue : $0.work.scheduling.rawValue,
            retryable: !$0.work.execution.isTerminal && $0.work.scheduling == .needsAttention, roomID: nil) }
        guard row?.work.execution == .committed, let page = pages[pageID], page.keys.contains(key) else { return }
        await repository.invalidateEditedName(.contact(id))
        _ = try? await repository.presentation(for: key, activation: page.activation)
        try? await loadAvatar(key, page: pageID)
    }
    private func fail(_ error: any Error) { failure = sharedFailure(error) }
    func loadAvatar(page pageID: String, userID: String) async throws {
        guard let page = pages[pageID], let key = page.keys.first(where: { $0.userID.rawValue == userID }) else {
            throw SharedFailure.invalidInput
        }
        try await loadAvatar(key, page: pageID)
    }
    private func loadAvatar(_ key: V2ProfileViewLookupKey, page pageID: String) async throws {
        guard let page = pages[pageID] else { return }
        guard let snapshot = await repository.cachedSnapshot(for: key, activation: page.activation),
              let end = snapshot.avatarDeadline, end > .now,
              let grant = await repository.avatarReadGrant(for: key, activation: page.activation) else { return }
        let data = try await resources.avatarBytes(grant)
        guard pages[pageID]?.activation == page.activation, end > .now else { throw CancellationError() }
        pages[pageID]?.image = (key, grant, data)
    }
    func loadGroupNickname(room: RoomID) async throws {
        let value = try await names.refresh(.group(room))
        groupNickname = SharedGroupNickname(roomID: room.rawValue, name: value.name, revision: value.revision?.rawValue)
    }
    func saveGroupNickname(_ request: SharedRequest) async throws {
        guard let raw = request.roomID else { throw SharedFailure.invalidInput }
        let room = try RoomID(raw)
        let revision = request.revision.flatMap(V2ProfileRevision.init(rawValue:))
        guard request.revision == nil || revision != nil else { throw SharedFailure.invalidInput }
        _ = try await names.save(.group(room), name: request.text?.isEmpty == false ? request.text : nil, expectedRevision: revision)
    }
    var currentGroupNickname: SharedGroupNickname? { groupNickname }
    func save(_ request: SharedRequest) async throws {
        guard let page = pages["selected"], let id = page.selected, id.rawValue == request.targetUserID,
              page.context == .relationship else { throw SharedFailure.invalidInput }
        let revision = request.revision.flatMap(V2ProfileRevision.init(rawValue:))
        guard request.revision == nil || revision != nil else { throw SharedFailure.invalidInput }
        _ = try await names.save(.contact(id), name: request.text?.isEmpty == false ? request.text : nil, expectedRevision: revision)
    }
    func retry(_ id: UUID) async throws { try await names.continueConfirmation(id: id) }
    func snapshot() async throws -> ([SharedProfile], SharedWork?, String?) {
        let floors = try await store.pendingProfileInvalidations(limit: 100)
        var output: [SharedProfile] = []
        for pageID in pages.keys.sorted() {
            guard let page = pages[pageID] else { continue }
            for key in page.keys {
                guard let value = await repository.cachedSnapshot(for: key, activation: page.activation) else { continue }
                if floors.contains(where: { $0.userID == key.userID && $0.minimumRevision.rawValue > value.presentation.view.revision.rawValue }) {
                    await repository.invalidate([key]); continue
                }
                guard let identity = value.presentation.view.publicIdentity else { continue }
                var deadline = value.deadline
                var avatar: String?
                if let image = page.image, image.key == key,
                   (try? await image.grant.requireValid()) != nil {
                    deadline = min(deadline, image.grant.deadline); avatar = image.data.base64EncodedString()
                }
                let remaining = ContinuousClock.now.duration(to: deadline)
                let milliseconds = remaining.components.seconds * 1_000 + remaining.components.attoseconds / 1_000_000_000_000_000
                guard milliseconds > 0, pages[pageID]?.activation == page.activation else { continue }
                let alias = value.presentation.contactAlias
                let member = value.presentation.groupMember
                let name = alias?.remarkName ?? member?.groupNickname ?? identity.displayName
                output.append(.init(page: pageID, userID: key.userID.rawValue, name: name, handle: identity.handle.rawValue,
                    alias: alias?.remarkName, aliasRevision: alias?.revision.rawValue,
                    groupNickname: member?.groupNickname, groupNicknameRevision: member?.revision.rawValue,
                    remainingMilliseconds: milliseconds, avatar: avatar))
            }
        }
        return (output, work, failure?.rawValue)
    }
    var selected: UserID? { pages["selected"]?.selected }
    func clear(page: String) async {
        guard let old = pages.removeValue(forKey: page) else { return }
        old.loader?.cancel(); old.observer?.cancel()
        await repository.deactivate(old.activation)
        await old.loader?.value
        await old.observer?.value
    }
    func clearAll() async {
        for page in Array(pages.keys) { await clear(page: page) }
        pages.removeAll()
    }
    func close() async { await clearAll(); work = nil; failure = nil; groupNickname = nil }
}
