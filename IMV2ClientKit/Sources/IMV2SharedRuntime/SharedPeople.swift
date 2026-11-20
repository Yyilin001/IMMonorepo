import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core
import IMV2ClientRuntime

struct SharedProfile: Encodable, Sendable {
    let userID: String; let name: String; let handle: String; let alias: String?
    let aliasRevision: UInt64?; let remainingMilliseconds: Int64; let avatar: String?
}
/// Only authorized presentation values cross the binding. Files, object capabilities and
/// account credentials never cross it; decoded pixels retain the original grant's deadline.
actor SharedPeople {
    private let repository: V2ProfilePresentationRepository
    private let names: V2ProfileNameService
    private let store: GRDBV2LocalSyncStore
    private var activation: V2ProfilePageActivation?
    private var keys: [V2ProfileViewLookupKey] = []
    private var loader: Task<Void, Never>?
    private var observer: Task<Void, Never>?
    private var image: (V2AvatarReadGrant, Data)?
    private var work: SharedWork?
    private let resources: V2ResourceService
    private var failure: SharedFailure?
    private(set) var selected: UserID?
    init(store: GRDBV2LocalSyncStore, profiles: V2ProfileService, resources: V2ResourceService) {
        self.store = store; repository = profiles.presentations; names = profiles.names; self.resources = resources
    }
    func handlers() -> [V2OperationWorkDispatcher.Handler] { names.handlers() }
    func clear() async {
        let old = activation; activation = nil; keys = []; selected = nil; image = nil; work = nil
        loader?.cancel(); observer?.cancel()
        if let old { await repository.deactivate(old) }
        await loader?.value; await observer?.value; loader = nil; observer = nil
    }
    func close() async { await clear() }
    func showContacts(_ ids: [String]) async throws {
        let next = try ids.prefix(50).map { V2ProfileViewLookupKey(userID: try UserID($0), context: .relationship) }
        guard next != keys || selected != nil else { return }
        await clear(); keys = next
        let page = await repository.activate(); activation = page
        loader = Task { [repository] in
            await withTaskGroup(of: Void.self) { group in
                for key in next { group.addTask { _ = try? await repository.presentation(for: key, activation: page) } }
            }
        }
    }
    func open(_ id: UserID) async throws {
        await clear(); selected = id
        let key = V2ProfileViewLookupKey(userID: id, context: .relationship)
        keys = [key]; let page = await repository.activate(); activation = page
        _ = try await repository.presentation(for: key, activation: page)
        try Task.checkCancellation()
        _ = try await names.refresh(.contact(id))
        observer = Task {
            do { for try await row in await names.updates(.contact(id)) {
                work = row.map { SharedWork(id: $0.id.uuidString, kind: "contactAlias", target: id.rawValue,
                    status: $0.work.execution.isTerminal ? $0.work.execution.rawValue : $0.work.scheduling.rawValue,
                    retryable: !$0.work.execution.isTerminal && $0.work.scheduling == .needsAttention, roomID: nil) }
                if row?.work.execution == .committed {
                    _ = try await repository.presentation(for: key, activation: page)
                    try await loadAvatar(key, page: page)
                }
            } } catch is CancellationError {} catch { failure = sharedFailure(error) }
        }
        // A missing/failed avatar must not discard an otherwise authorized contact card.
        do { try await loadAvatar(key, page: page) }
        catch is CancellationError { throw CancellationError() }
        catch { image = nil }
    }
    private func loadAvatar(_ key: V2ProfileViewLookupKey, page: V2ProfilePageActivation) async throws {
        guard let snapshot = await repository.cachedSnapshot(for: key, activation: page),
              let end = snapshot.avatarDeadline, end > .now,
              let grant = await repository.avatarReadGrant(for: key, activation: page) else { return }
        let data = try await resources.avatarBytes(grant)
        guard activation == page, end > .now else { throw CancellationError() }
        image = (grant, data)
    }
    func save(_ request: SharedRequest) async throws {
        guard let id = selected, id.rawValue == request.targetUserID else { throw SharedFailure.invalidInput }
        let revision = request.revision.flatMap(V2ProfileRevision.init(rawValue:))
        guard request.revision == nil || revision != nil else { throw SharedFailure.invalidInput }
        _ = try await names.save(.contact(id), name: request.text?.isEmpty == false ? request.text : nil, expectedRevision: revision)
    }
    func retry(_ id: UUID) async throws { try await names.continueConfirmation(id: id) }
    func snapshot() async throws -> ([SharedProfile], SharedWork?, String?) {
        guard let page = activation else { return ([], nil, nil) }
        let floors = try await store.pendingProfileInvalidations(limit: 100)
        var output: [SharedProfile] = []
        for key in keys {
            guard let value = await repository.cachedSnapshot(for: key, activation: page) else { continue }
            if floors.contains(where: { $0.userID == key.userID && $0.minimumRevision.rawValue > value.presentation.view.revision.rawValue }) {
                await repository.invalidate([key]); continue
            }
            guard let identity = value.presentation.view.publicIdentity else { continue }
            var deadline = value.deadline
            var avatar: String?
            if selected == key.userID, let image, (try? await image.0.requireValid()) != nil {
                deadline = min(deadline, image.0.deadline); avatar = image.1.base64EncodedString()
            }
            let remaining = ContinuousClock.now.duration(to: deadline)
            let milliseconds = remaining.components.seconds * 1_000 + remaining.components.attoseconds / 1_000_000_000_000_000
            guard milliseconds > 0, activation == page else { continue }
            output.append(.init(userID: key.userID.rawValue, name: identity.displayName, handle: identity.handle.rawValue,
                alias: value.presentation.contactAlias?.remarkName, aliasRevision: value.presentation.contactAlias?.revision.rawValue,
                remainingMilliseconds: milliseconds, avatar: avatar))
        }
        return (output, work, failure?.rawValue)
    }
}
