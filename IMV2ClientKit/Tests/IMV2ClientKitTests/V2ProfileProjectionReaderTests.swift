import Foundation
import IMV2Core
import Synchronization
import Testing
@testable import IMV2ClientKit

@Suite("Shared authorized profile projection refresh", .timeLimit(.minutes(1)))
struct V2ProfileProjectionReaderTests {
    @Test("100 explicit direct requests respect the eight-context and shared two-flight limits")
    func boundedDirectRefresh() async throws {
        let actor = UserID(uuid: UUID()), device = DeviceID(uuid: UUID())
        let keys = (0..<100).map { _ in V2ProfileViewLookupKey(userID: .init(uuid: UUID()), context: .directConversation) }
        let remote = ProjectionPresentationReader(actor: actor, device: device)
        let presentations = V2ProfilePresentationRepository(actorUserID: actor, deviceID: device, reader: remote)
        let store = ProjectionContentStore(invalidations: keys.map {
            .init(userID: $0.userID, minimumRevision: .init(rawValue: 1)!)
        })
        let repository = V2ProfileRepository(store: store, reader: V2ProfileProjectionReader(presentations: presentations))
        #expect(try await repository.hydrate(keys) == Set(keys.map(\.userID)))
        let batches = await remote.batches
        #expect(batches.count >= 13)
        #expect(batches.allSatisfy { $0.count <= 8 })
        #expect(Set(batches.flatMap { $0 }) == Set(keys))
        #expect(await remote.maximumInFlight <= 2)
        #expect(await store.writes == 1)
        #expect(try await store.pendingProfileInvalidations(limit: 100).isEmpty)
        // A persisted value and the hydration's former activation cannot grant
        // another page permission to show it without a new authorized read.
        let page = await presentations.activate()
        #expect(await presentations.cachedSnapshot(for: keys[0], activation: page) == nil)
        await presentations.deactivate(page)
        await repository.close(); await presentations.close()
    }

    @Test("leases for another viewer/device/context, partial or retryable data never overwrite content",
          arguments: [ProjectionResponseMode.wrongActor, .wrongDevice, .wrongContext, .partial, .retryable, .expired])
    func rejectsUnusableReply(mode: ProjectionResponseMode) async throws {
        let actor = UserID(uuid: UUID()), device = DeviceID(uuid: UUID())
        let key = V2ProfileViewLookupKey(userID: .init(uuid: UUID()), context: .relationship)
        let remote = ProjectionPresentationReader(actor: actor, device: device, mode: mode)
        let presentations = V2ProfilePresentationRepository(actorUserID: actor, deviceID: device, reader: remote)
        let cached = try projectionView(key.userID)
        let store = ProjectionContentStore(invalidations: [.init(userID: key.userID, minimumRevision: .init(rawValue: 2)!)])
        await store.seed(cached)
        let repository = V2ProfileRepository(store: store, reader: V2ProfileProjectionReader(presentations: presentations))
        await #expect(throws: (any Error).self) { try await repository.hydrate([key]) }
        #expect(try await store.profileView(userID: key.userID) == cached)
        #expect(await store.writes == 0)
        #expect(try await store.pendingProfileInvalidations(limit: 100).count == 1)
        await repository.close(); await presentations.close()
    }

    @Test("explicit denial purges SQLite content; accepted content survives restart without its lease")
    func sqliteContentOnly() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "projection-reader-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "store.sqlite"), binding = V2LocalInstallationBinding(value: UUID())
        let actor = UserID(uuid: UUID()), device = DeviceID(uuid: UUID())
        let key = V2ProfileViewLookupKey(userID: .init(uuid: UUID()), context: .relationship)
        let remote = ProjectionPresentationReader(actor: actor, device: device)
        let presentations = V2ProfilePresentationRepository(actorUserID: actor, deviceID: device, reader: remote)
        let store = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        let repository = V2ProfileRepository(store: store, reader: V2ProfileProjectionReader(presentations: presentations))
        do {
            _ = try await repository.hydrate([key])
            #expect(try await store.profileView(userID: key.userID) == projectionView(key.userID))
            await repository.close(); await presentations.close(); try await store.close()
        } catch { await repository.close(); await presentations.close(); try? await store.close(); throw error }
        let reopened = try GRDBV2LocalSyncStore(databaseURL: url, installationBinding: binding)
        await remote.setMode(.unavailable)
        let nextPresentations = V2ProfilePresentationRepository(actorUserID: actor, deviceID: device, reader: remote)
        let nextRepository = V2ProfileRepository(store: reopened, reader: V2ProfileProjectionReader(presentations: nextPresentations))
        do {
            #expect(try await reopened.profileView(userID: key.userID) == projectionView(key.userID))
            _ = try await nextRepository.hydrate([key])
            #expect(try await reopened.profileView(userID: key.userID) == nil)
            await nextRepository.close(); await nextPresentations.close(); try await reopened.close()
        } catch { await nextRepository.close(); await nextPresentations.close(); try? await reopened.close(); throw error }
    }

    @Test("account close waits for non-cooperative content writes and rejects further local reads")
    func closeDrainsPersistence() async throws {
        let actor = UserID(uuid: UUID()), device = DeviceID(uuid: UUID())
        let key = V2ProfileViewLookupKey(userID: .init(uuid: UUID()), context: .relationship)
        let gate = ProjectionGate(), store = ProjectionContentStore(writeGate: gate)
        let presentations = V2ProfilePresentationRepository(actorUserID: actor, deviceID: device,
            reader: ProjectionPresentationReader(actor: actor, device: device))
        let repository = V2ProfileRepository(store: store, reader: V2ProfileProjectionReader(presentations: presentations))
        let hydrate = Task { try await repository.hydrate([key]) }
        await gate.entered()
        let finished = Mutex(false)
        let closing = Task { await repository.close(); finished.withLock { $0 = true } }
        await gate.cancelled()
        #expect(!finished.withLock { $0 })
        await #expect(throws: CancellationError.self) { try await repository.profileView(userID: key.userID) }
        await #expect(throws: CancellationError.self) { try await repository.hydrate([key]) }
        await gate.release()
        await closing.value
        await #expect(throws: CancellationError.self) { try await hydrate.value }
        #expect(await store.writes == 1)
        await presentations.close()
    }

    @Test("an old cancelled HTTP flight remains owned until the shared repository closes")
    func closeDrainsRemote() async throws {
        let actor = UserID(uuid: UUID()), device = DeviceID(uuid: UUID())
        let key = V2ProfileViewLookupKey(userID: .init(uuid: UUID()), context: .relationship)
        let gate = ProjectionGate(), store = ProjectionContentStore()
        let remote = ProjectionPresentationReader(actor: actor, device: device, gate: gate)
        let presentations = V2ProfilePresentationRepository(actorUserID: actor, deviceID: device, reader: remote)
        let repository = V2ProfileRepository(store: store, reader: V2ProfileProjectionReader(presentations: presentations))
        let hydrate = Task { try await repository.hydrate([key]) }
        await gate.entered()
        let finished = Mutex(false)
        let closing = Task {
            await repository.close(); await presentations.close()
            finished.withLock { $0 = true }
        }
        await gate.cancelled()
        #expect(!finished.withLock { $0 })
        #expect(await store.writes == 0)
        await gate.release()
        await closing.value
        await #expect(throws: CancellationError.self) { try await hydrate.value }
        #expect(await store.writes == 0)
    }

    @Test("invalid hydration inputs cause neither network requests nor writes")
    func admissionValidation() async throws {
        let actor = UserID(uuid: UUID()), device = DeviceID(uuid: UUID())
        let key = V2ProfileViewLookupKey(userID: .init(uuid: UUID()), context: .relationship)
        let remote = ProjectionPresentationReader(actor: actor, device: device), store = ProjectionContentStore()
        let presentations = V2ProfilePresentationRepository(actorUserID: actor, deviceID: device, reader: remote)
        let reader = V2ProfileProjectionReader(presentations: presentations)
        let repository = V2ProfileRepository(store: store, reader: reader)
        for keys in [[], [key, key], Array(repeating: key, count: 101)] {
            await #expect(throws: V2ProfileViewClientError.invalidRequest) { try await reader.readProfileViews(keys) }
        }
        await #expect(throws: V2ProfileViewClientError.invalidRequest) { try await repository.hydrate([key, key]) }
        #expect(await remote.batches.isEmpty)
        #expect(await store.writes == 0)
        await repository.close(); await presentations.close()
    }
}

enum ProjectionResponseMode: Sendable {
    case valid, wrongActor, wrongDevice, wrongContext, partial, retryable, expired, unavailable
}

private actor ProjectionPresentationReader: V2ProfilePresentationReading {
    let actor: UserID, device: DeviceID
    var mode: ProjectionResponseMode
    let gate: ProjectionGate?
    private(set) var batches: [[V2ProfileViewLookupKey]] = []
    private var inFlight = 0
    private(set) var maximumInFlight = 0
    init(actor: UserID, device: DeviceID, mode: ProjectionResponseMode = .valid, gate: ProjectionGate? = nil) {
        self.actor = actor; self.device = device; self.mode = mode; self.gate = gate
    }
    func setMode(_ mode: ProjectionResponseMode) { self.mode = mode }
    func readPresentations(_ keys: [V2ProfileViewLookupKey]) async throws -> V2ProfilePresentationBatch {
        // Real wire construction rejects more than eight room/direct contexts.
        _ = try V2ProfilePresentationBatchRequest(keys: keys)
        batches.append(keys); inFlight += 1; maximumInFlight = max(maximumInFlight, inFlight)
        defer { inFlight -= 1 }
        let now = Date()
        if let gate { await gate.wait() }
        else { try await Task.sleep(for: .milliseconds(30)) }
        if mode == .partial { return .init(presentations: [:], unavailable: [], serverNow: now) }
        if mode == .retryable { return .init(presentations: [:], unavailable: [], serverNow: now, retryable: Set(keys)) }
        if mode == .unavailable { return .init(presentations: [:], unavailable: Set(keys), serverNow: now) }
        var values: [V2ProfileViewLookupKey: V2AuthorizedProfilePresentation] = [:]
        for key in keys {
            let view = try projectionView(key.userID)
            let lease = try V2PresentationAccessLease(actorUserID: mode == .wrongActor ? .init(uuid: UUID()) : actor,
                deviceID: mode == .wrongDevice ? .init(uuid: UUID()) : device,
                key: mode == .wrongContext ? .init(userID: key.userID, context: .directConversation) : key,
                profileRevision: view.revision, visibilityRevision: view.visibilityRevision, contextRevision: 1,
                observedAt: now, validUntil: now.addingTimeInterval(mode == .expired ? 0.001 : 300))
            values[key] = try .init(view: view, lease: lease)
        }
        return .init(presentations: values, unavailable: [], serverNow: now)
    }
}

private func projectionView(_ user: UserID) throws -> V2ProfileView {
    try .init(userID: user, publicIdentity: .init(userID: user, handle: .init("projection_test"),
        displayName: "Cached content", accountKind: .regular), avatar: nil, state: .active,
        revision: .init(rawValue: 1)!, visibilityRevision: .init(rawValue: 1)!)
}

private actor ProjectionContentStore: V2ClientProfileProjectionStore {
    private var profiles: [UserID: V2ProfileView] = [:]
    private var invalidations: [V2ProfileInvalidation]
    private let writeGate: ProjectionGate?
    private(set) var writes = 0
    init(invalidations: [V2ProfileInvalidation] = [], writeGate: ProjectionGate? = nil) {
        self.invalidations = invalidations; self.writeGate = writeGate
    }
    func seed(_ profile: V2ProfileView) { profiles[profile.userID] = profile }
    func profileView(userID: UserID) throws -> V2ProfileView? { profiles[userID] }
    func profileViews(userIDs: [UserID]) throws -> [UserID: V2ProfileView] { profiles.filter { userIDs.contains($0.key) } }
    func saveProfileView(_ profile: V2ProfileView) throws { profiles[profile.userID] = profile }
    func markProfileUnavailable(userID: UserID) throws { profiles.removeValue(forKey: userID) }
    func pendingProfileInvalidations(limit: Int) throws -> [V2ProfileInvalidation] { Array(invalidations.prefix(limit)) }
    func applyProfileViewResults(_ results: [V2ProfileViewLookupResult]) async throws {
        if let writeGate { await writeGate.wait() }
        writes += 1
        let batch = V2ProfileViewResultBatch(results)
        for value in batch.profiles.values { profiles[value.userID] = value }
        for user in batch.unavailableUserIDs.subtracting(batch.profiles.keys) { profiles.removeValue(forKey: user) }
        invalidations.removeAll { invalidation in
            batch.profiles[invalidation.userID].map { $0.revision >= invalidation.minimumRevision } == true
                || batch.unavailableUserIDs.contains(invalidation.userID)
        }
    }
}

private actor ProjectionGate {
    private let starts = AsyncStream<Void>.makeStream(), cancellations = AsyncStream<Void>.makeStream()
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation = $0; starts.continuation.yield(()) }
        } onCancel: { cancellations.continuation.yield(()) }
    }
    func entered() async { var iterator = starts.stream.makeAsyncIterator(); _ = await iterator.next() }
    func cancelled() async { var iterator = cancellations.stream.makeAsyncIterator(); _ = await iterator.next() }
    func release() { continuation?.resume(); continuation = nil }
}
