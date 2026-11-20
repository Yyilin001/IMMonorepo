import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core
import IMV2ClientRuntime

private struct SharedProfileUpload: V2ProfileAvatarPreparing {
    let business: V2ResourceService
    func ensureReady(_ source: V2ProfileAvatarUpload) async throws -> V2AvatarReference {
        let id = try await business.prepareUpload(id: source.id, localAssetID: source.localAssetID, usage: .userAvatar)
        let job = try await business.uploads.resume(id: id)
        guard job.stage == .ready else { throw V2ClientMediaTransferError.scanPending }
        return .init(mediaID: job.request.mediaID)
    }
}
struct SharedAvatarEditor: Encodable, Sendable {
    let roomID: String?; let revision: UInt64; let canManage: Bool; let remainingMilliseconds: Int64
    let image: String?; let hasAvatar: Bool; let works: [SharedWork]; let failure: String?
}
/// Account-owned composition of existing resource, profile and group-avatar services.
actor SharedAvatars {
    private let account: UserID
    private let store: GRDBV2LocalSyncStore
    let resources: V2ResourceCenter
    let transfers: V2ResourceTransferEngine
    private let capabilities: V2ResourceCapabilitiesCache
    private let profile: V2OwnProfileService
    let business: V2ResourceService
    let profiles: V2ProfileService
    let resolver: SharedMediaResolver
    private let group: V2GroupAvatarIntentEngine
    private let groups: V2GroupAvatarPresentationRepository
    private let people: V2ProfilePresentationRepository
    private var tasks: [Task<Void, Never>] = []
    private var observation: Task<Void, Never>?
    private var profileWork: SharedWork?
    private var groupID: GroupAvatarOperationID?
    private var groupPage: V2GroupAvatarActivation?
    private var profilePage: V2ProfilePageActivation?
    private var view: (room: RoomID?, revision: UInt64, canManage: Bool, hasAvatar: Bool, deadline: ContinuousClock.Instant)?
    private var image: (V2AvatarReadGrant, Data)?
    private var failure: SharedFailure?
    init(session: V2SharedSession, profiles: V2ProfileService, account: UserID, device: DeviceID, store: GRDBV2LocalSyncStore, resources: V2ResourceCenter, base: URL, http: V2SessionHTTPAuthorization, uploader: any V2ResourcePlanExecuting, rangeTransport: any V2RangeDownloadTransport) async throws {
        self.profiles = profiles
        self.account = account; self.store = store; self.resources = resources
        let control = try V2HTTPResourceUploadClient(endpoint: base.appendingPathComponent("v2/resource-uploads"), credentials: http, transport: http)
        capabilities = .init(reader: control)
        let engine = V2ResourceTransferEngine(store: store, control: control, executor: uploader, resources: resources, capabilities: capabilities)
        transfers = engine
        let commands = try V2HTTPGroupAvatarCommandClient(roomsEndpoint: base.appendingPathComponent("v2/rooms"), actorUserID: account, credentials: http, transport: http)
        group = .init(actorUserID: account, store: store, transfers: engine, submissions: commands, recovery: commands)
        let manager = V2GroupAvatarService(actorUserID: account, deviceID: device, store: store, intents: group,
            reader: try V2HTTPGroupAvatarPresentationClient(roomsEndpoint: base.appendingPathComponent("v2/rooms"), actorUserID: account, credentials: http, transport: http), capabilities: control, resources: resources)
        groups = manager.presentations; people = profiles.presentations
        resolver = try SharedMediaResolver(base: base, http: http)
        let cache = try await resources.downloadCache(using: .init(targetResolver: resolver,
            byteTransfer: V2URLSessionMediaByteTransfer(transport: rangeTransport)))
        business = try await session.resources(for: store, accountID: account, library: resources, uploads: engine, downloads: cache, groupAvatars: manager)
        profile = try await profiles.ownProfile(using: .init(store: store, accountID: account,
            manager: try V2HTTPOwnProfileClient(endpoint: base.appendingPathComponent("v2/profile/me"), credentials: http, transport: http),
            avatars: SharedProfileUpload(business: business)))
    }

    func start() async throws {
        try await resources.attachUploads(transfers)
        tasks = [Task { do { try await transfers.runRecovery() } catch is CancellationError {} catch { failure = sharedFailure(error) } },
            Task { do { try await profile.runPreparation() } catch is CancellationError {} catch { failure = sharedFailure(error) } },
            Task { while !Task.isCancelled { do { try await group.recoverOnce(); try await Task.sleep(for: .seconds(1)) } catch is CancellationError { return } catch { failure = sharedFailure(error); try? await Task.sleep(for: .seconds(2)) } } }]
    }
    func handlers() -> [V2OperationWorkDispatcher.Handler] { profile.handlers() }
    func clear() async {
        view = nil; image = nil
        if let page = groupPage { await groups.deactivate(page) }; groupPage = nil
        if let page = profilePage { await people.deactivate(page) }; profilePage = nil
        observation?.cancel(); await observation?.value; observation = nil; profileWork = nil; groupID = nil
    }
    func close() async {
        tasks.forEach { $0.cancel() }; await clear()
        await profiles.close(); await business.close()
        for task in tasks { await task.value }; tasks = []
    }
    private func observe(_ intent: V2ProfileIntent) async {
        observation?.cancel(); await observation?.value
        observation = Task { do { for try await status in await profile.observe(intentID: intent.id) {
            profileWork = .init(id: intent.id.uuidString, kind: "profileUpdate", target: account.rawValue, status: status.phase == .needsAttention && status.canReplace ? "needsDecision" : String(describing: status.phase), retryable: status.phase == .needsAttention && !status.canReplace, roomID: nil)
        } } catch is CancellationError {} catch { failure = sharedFailure(error) } }
    }
    private func bytes(_ grant: V2AvatarReadGrant) async throws {
        image = (grant, try await business.avatarBytes(grant))
    }
    func open(room: RoomID?) async throws {
        await clear()
        if let room {
            guard try await store.roomAllowsLocalRead(roomID: room) else { throw SharedFailure.invalidInput }
            let page = try await groups.activate(roomID: room); groupPage = page
            let value = try await groups.presentation(for: page)
            guard let deadline = try await groups.authorizationDeadline(for: page) else { throw SharedFailure.operationFailed }
            view = (room, value.state.revision, value.canManage, value.state.mediaID != nil, deadline)
            if let grant = try await groups.avatarReadGrant(for: page) { try await bytes(grant) }
        } else {
            let value = try await profile.refreshProfile()
            view = (nil, value.revision.rawValue, true, value.avatar != nil, .now.advanced(by: .seconds(60)))
            if let intent = try await profile.pendingIntent() { await observe(intent) }
            let page = await people.activate(); profilePage = page
            let key = V2ProfileViewLookupKey(userID: account, context: .relationship)
            _ = try await people.presentation(for: key, activation: page)
            if let grant = await people.avatarReadGrant(for: key, activation: page) { try await bytes(grant) }
        }
    }
    func change(_ request: SharedRequest) async throws {
        let room = try request.roomID.map(RoomID.init)
        guard let view, view.room == room, view.canManage, view.deadline > .now,
              let revision = request.revision, revision == view.revision else { throw SharedFailure.invalidInput }
        if let room {
            guard try await store.roomAllowsLocalRead(roomID: room), try await store.pendingGroupAvatarIntents(in: room).isEmpty else { throw SharedFailure.busy }
            // Reauthorize without replacing the revision explicitly confirmed by the user.
            await groups.invalidate(roomID: room)
            guard let page = groupPage else { throw SharedFailure.invalidInput }
            let value = try await groups.presentation(for: page)
            guard value.canManage, value.state.revision == revision else { throw SharedFailure.invalidInput }
        } else { guard try await profile.pendingIntent() == nil else { throw SharedFailure.busy } }
        var asset: V2LocalResourceAsset?
        if let encoded = request.image {
            guard let data = Data(base64Encoded: encoded), (1...524_288).contains(data.count), data.starts(with: [0xff, 0xd8]),
                  let width = request.width, let height = request.height, width == height, (1...1024).contains(width) else { throw SharedFailure.invalidInput }
            let value = try await resources.importLocal(data: data, displayName: .init("avatar.jpg"), contentType: .init("image/jpeg"), purpose: room.map(V2LocalResourceAssetPurpose.groupAvatar) ?? .personalAvatar,
                imageDimensions: .init(width: width, height: height), maximumBytes: 524_288, maximumSelections: 4)
            asset = value
        }
        do {
            if let room {
                groupID = try await business.groupAvatars.change(roomID: room, expectedRevision: revision,
                    image: asset.map { .init(id: $0.id.value, localAssetID: $0.id, contentType: $0.contentType.value, byteCount: $0.byteCount) })
            } else {
                guard let expected = V2ProfileRevision(rawValue: revision) else { throw SharedFailure.invalidInput }
                let id = UUID()
                let upload = try asset.map { try V2ProfileAvatarUpload(id: id, localAssetID: $0.id, displayName: $0.displayName.value, contentType: $0.contentType.value, byteCount: $0.byteCount) }
                let intent = try await profile.enqueue(expectedRevision: expected, patch: .init(avatar: asset == nil ? .remove : .set(.init(mediaID: .init(uuid: id)))), avatarUpload: upload)
                await observe(intent)
            }
        } catch { if let asset { try? await resources.discardLocalSelection(asset.id) }; throw error }
        if let asset { try? await resources.discardLocalSelection(asset.id) }
    }
    func action(_ request: SharedRequest) async throws {
        if let room = request.roomID {
            let id = try GroupAvatarOperationID(request.intentID ?? "")
            guard let intent = try await store.groupAvatarIntent(id), intent.actorUserID == account, intent.command.roomID.rawValue == room else { throw SharedFailure.invalidInput }
            let action: V2GroupAvatarManagementAction
            switch request.action {
            case "retry": action = .retry
            case "query": action = .query
            case "cancel": action = .cancel
            case "close": action = .closeIfAbsent
            case "discard": action = .abandon
            default: throw SharedFailure.invalidInput
            }
            try await business.groupAvatars.act(roomID: RoomID(room), operationID: id, action: action)

        } else {
            guard let id = UUID(uuidString: request.intentID ?? ""), let intent = try await store.profileIntent(id: id), intent.accountID == account else { throw SharedFailure.invalidInput }
            if request.action == "discard" { try await profile.discard(intentID: id) }
            else if request.action == "reapply" { _ = try await profile.resumeOrReapply(intentID: id) }
            else if request.action == "retry" {
                if let workID = intent.workID { guard let work = try await store.operationWork(id: workID), !work.execution.isTerminal else { throw SharedFailure.invalidInput } }
                _ = try await profile.resumeOrReapply(intentID: id)
            }
            else { throw SharedFailure.invalidInput }
        }
    }
    func snapshot() async throws -> SharedAvatarEditor? {
        guard let view else { return nil }
        var works: [SharedWork] = []
        var valid = view.deadline > .now
        if let room = view.room {
            let readable = try await store.roomAllowsLocalRead(roomID: room); valid = valid && readable
            if let page = groupPage { let cached = try await groups.cachedPresentation(for: page); valid = valid && cached != nil }
            var intents = try await store.pendingGroupAvatarIntents(in: room)
            if let groupID, !intents.contains(where: { $0.id == groupID }), let last = try await store.groupAvatarIntent(groupID) { intents.append(last) }
            works = intents.prefix(50).map { .init(id: $0.id.rawValue, kind: "groupAvatar", target: room.rawValue, status: $0.stage.rawValue, retryable: $0.stage == .needsAttention, roomID: room.rawValue) }
        } else {
            if let local = try await profile.localProfile(), local.revision.rawValue > view.revision { valid = false }
            if let profileWork { works = [profileWork] }
        }
        var encoded: String?
        var deadline = view.deadline
        if valid, let image, (try? await image.0.requireValid()) != nil { encoded = image.1.base64EncodedString(); deadline = min(deadline, image.0.deadline) }
        let duration = ContinuousClock.now.duration(to: deadline)
        let ms = max(0, duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
        return .init(roomID: view.room?.rawValue, revision: view.revision, canManage: valid && view.canManage,
            remainingMilliseconds: valid ? ms : 0, image: encoded, hasAvatar: view.hasAvatar, works: works, failure: failure?.rawValue)
    }
}
