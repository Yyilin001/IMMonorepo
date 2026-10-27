import Foundation
import IMV2Core

/// The URL is a cache hint. Every decoder, player and export must borrow its
/// own lease; a copied handle is not a second file-lifetime claim.
public final class V2ResourceCachedFile: Sendable, Identifiable, Hashable {
    public let id: UUID
    public let mediaID: MediaID
    public let fileURL: URL
    private let owner: V2ResourceDownloadCache
    fileprivate init(id: UUID, mediaID: MediaID, fileURL: URL, owner: V2ResourceDownloadCache) {
        self.id = id; self.mediaID = mediaID; self.fileURL = fileURL; self.owner = owner
    }
    public func borrowFile() async throws -> V2ResourceFileLease { try await owner.borrow(id) }
    public static func == (lhs: V2ResourceCachedFile, rhs: V2ResourceCachedFile) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    deinit {
        let owner = owner, id = id
        Task { await owner.releaseHandle(id) }
    }
}

/// Account-local cache. Authorization is per caller; only verified byte work
/// merges across callers. Resource files and runtime borrows have one owner.
public actor V2ResourceDownloadCache {
    private struct AdmissionReady: Error { let ticket: UUID? }
    private struct CapacityWaiter {
        let key: String
        let priority: V2NetworkWorkPriority
        let enqueuedAt: TimeInterval
        let continuation: AsyncStream<Void>.Continuation
    }
    private struct Grant {
        let mediaID: MediaID
        let fileID: V2LocalResourceFileID
        let checksum: V2ResourceChecksum
        let bytes: Int64
        let message: V2MediaMessageLocation?
        let isAvatar: Bool
        var previewSize: V2MediaImagePreviewSize? = nil
        let deadline: Date
        let generation: Data
        let family: String
        let identity: String
    }
    private struct DownloadFlight {
        let operation: V2SharedOperation<V2LocalResourceFileID>
        let demand: V2ByteTransferDemand
        var users = 0
        var publication: V2ResourceFileLease?
        var finished = false
        var requiresFreshAuthorization = false
        var jobID: UUID?
    }
    private struct DownloadUse: Sendable {
        let fileID: V2LocalResourceFileID
        let lease: V2ResourceFileLease
        var requiresFreshAuthorization = false
    }
    private let files: V2ResourceFileStore
    private let journal: V2ResourceFileJournal
    private let network: V2ClientMediaDownloadService
    private let progress: V2ResourceTransferProgressHub
    private let automaticNetwork: V2ResourceAutomaticNetworkSource
    private let recoveryNow: @Sendable () -> Date
    private var automaticConditions = V2ResourceAutomaticNetworkConditions.unavailable
    private var recoveryGeneration: UUID?
    private let operations = V2ResourceOperationScope(limit: 16)
    private let recoveryOperations = V2ResourceOperationScope(limit: 2)
    private let recoveryActivity = V2ResourceOperationScope(limit: 1)
    private var background: V2BackgroundDownloadCoordinator?
    private var flights: [String: DownloadFlight] = [:]
    private var finishedFlightWaiters: [String: [UUID: AsyncStream<Void>.Continuation]] = [:]
    private var capacityWaiters: [UUID: CapacityWaiter] = [:]
    private var capacityOrder: [UUID] = []
    private var capacityReservations: [UUID: String] = [:]
    private var resumedDownloads: [UUID: V2SharedOperation<Void>] = [:]
    private var recoveryRunning = false
    private var recoveryFailure: (any Error)?
    private var recoveryWake: AsyncStream<Void>.Continuation?
    private var grants: [UUID: Grant] = [:]
    private struct PreviewKey: Hashable {
        let message: V2MediaMessageLocation
        let mediaID: MediaID
        let size: V2MediaImagePreviewSize
    }
    // Bounded account-session authorization metadata, never provider URLs or
    // retained handles. Reusing it still checks local access and file integrity.
    private struct PreviewAuthorization {
        let grant: Grant
        let fileURL: URL // Local cache hint only; borrowing still verifies bytes.
    }
    private var previewAuthorizations: [PreviewKey: PreviewAuthorization] = [:]
    private var previewRecency: [PreviewKey] = []
    private var revisions: [MediaID: UUID] = [:]
    private var mediaUsers: [MediaID: Int] = [:]
    private var identities: [String: String] = [:]
    private var avatarVersions: [String: Int64] = [:]
    private var identityUsers: [String: Int] = [:]
    private var closed = false
    private let foregroundOwner = UUID()

    init(files: V2ResourceFileStore, journal: V2ResourceFileJournal, network: V2ClientMediaDownloadService, progress: V2ResourceTransferProgressHub,
         background: V2BackgroundDownloadCoordinator? = nil, automaticNetwork: V2ResourceAutomaticNetworkSource = .system, recoveryNow: @escaping @Sendable () -> Date = Date.init) throws {
        self.files = files; self.journal = journal; self.network = network
        self.progress = progress
        self.background = background; self.automaticNetwork = automaticNetwork; self.recoveryNow = recoveryNow
        try journal.recoverForegroundDownloads(owner: foregroundOwner)
        try journal.recoverBackgroundResumeOwners(owner: foregroundOwner)
    }

    public func download(_ media: V2MediaReference, message: V2MediaMessageLocation? = nil) async throws -> V2ResourceCachedFile {
        try requireOpen()
        let context = try journal.activeMessageDownload(mediaID: media.mediaID, message: message).map {
            V2ResourceTransferWaitContext(transfer: .download($0), hub: progress)
        }
        return try await V2ResourceTransferWaitScope.$context.withValue(context) {
            try await operations.run { try await self.performDownload(media, message: message) }
        }
    }

    public func avatar(_ access: V2ResourceAvatarAccess, home: V2ResourceHome) async throws -> V2ResourceCachedFile {
        try await operations.run { try await self.performAvatar(access, home: home) }
    }

    /// Authorizes the caller normally, but never starts a byte transfer or
    /// creates a job on a cache miss. The lease protects decoding from cleanup.
    public func borrowCached(_ media: V2MediaReference, message: V2MediaMessageLocation?) async throws -> V2ResourceFileLease? {
        try await operations.run(onCancelledValue: { await $0?.release() }) {
            try await self.performBorrowCached(media, message: message)
        }
    }

    /// Recover a normal authorized handle to verified local bytes. A miss never
    /// creates a download demand or transfers bytes; every later use still borrows.
    public func cachedFile(_ media: V2MediaReference, message: V2MediaMessageLocation?) async throws -> V2ResourceCachedFile? {
        try await operations.run { try await self.performCachedFile(media, message: message) }
    }

    private func performCachedFile(_ media: V2MediaReference, message: V2MediaMessageLocation?) async throws -> V2ResourceCachedFile? {
        guard let cached = try await acquireCachedRead(media, message: message) else { return nil }
        do {
            let family = message.map { "message:\($0.roomID.rawValue):\(media.mediaID.rawValue)" } ?? "message:\(media.mediaID.rawValue)"
            let identity = "\(family):\(cached.target.checksum.value):\(cached.target.expectedByteCount)"
            self.identities[family] = identity
            let handle = try await self.handle(fileID: cached.fileID, mediaID: media.mediaID, message: message,
                avatar: false, target: cached.target, generation: cached.generation, family: family, identity: identity)
            await cached.lease.release()
            return handle
        } catch { await cached.lease.release(); throw error }
    }

    private struct CachedRead {
        let fileID: V2LocalResourceFileID
        let target: V2ClientMediaTransferTarget
        let generation: Data
        let lease: V2ResourceFileLease
    }

    private func performBorrowCached(_ media: V2MediaReference, message: V2MediaMessageLocation?) async throws -> V2ResourceFileLease? {
        try await acquireCachedRead(media, message: message)?.lease
    }

    private func acquireCachedRead(_ media: V2MediaReference, message: V2MediaMessageLocation?) async throws -> CachedRead? {
        try requireOpen()
        try journal.requireMessageAccess(message, mediaID: media.mediaID)
        let generation = try journal.currentAccessGeneration()
        let target = try await network.authorizedTarget(mediaID: media.mediaID, message: message)
        try requireOpen()
        guard generation == (try journal.currentAccessGeneration()) else { throw V2ResourceStorageError.unavailable }
        if let message {
            let variants = try journal.variants(for: .init(home: .room(message.roomID), mediaID: media.mediaID))
            guard let original = variants.first(where: { $0.descriptor.key.rendition == .original }),
                  original.descriptor.checksum == target.checksum, original.descriptor.byteCount == target.expectedByteCount
            else { throw V2ResourceStorageError.integrityMismatch }
        }
        guard let file = try journal.matchingFile(checksum: target.checksum, byteCount: target.expectedByteCount) else { return nil }
        let lease = try await files.borrowVerified(id: file.id, checksum: target.checksum, bytes: target.expectedByteCount)
        do {
            try requireOpen()
            try journal.requireMessageAccess(message, mediaID: media.mediaID)
            guard generation == (try journal.currentAccessGeneration()), target.expiresAt > Date() else { throw V2ResourceStorageError.unavailable }
            return .init(fileID: file.id, target: target, generation: generation, lease: lease)
        } catch { await lease.release(); throw error }
    }

    public func attachBackgroundDownloads(_ value: V2BackgroundDownloadCoordinator) {
        guard !closed else { return }; background = value
    }

    private func performDownload(_ media: V2MediaReference, message: V2MediaMessageLocation?, resuming: V2ResourceDownloadResume? = nil) async throws -> V2ResourceCachedFile {
        mediaUsers[media.mediaID, default: 0] += 1
        defer { finishMedia(media.mediaID) }
        var ticket: UUID?
        defer { releaseCapacity(ticket) }
        while true {
            try requireOpen()
            do { return try await performDownloadAttempt(media, message: message, resuming: resuming, ticket: ticket) }
            catch let admission as AdmissionReady {
                releaseCapacity(ticket)
                ticket = admission.ticket
            }
        }
    }

    private func performDownloadAttempt(_ media: V2MediaReference, message: V2MediaMessageLocation?, resuming: V2ResourceDownloadResume?, ticket: UUID?) async throws -> V2ResourceCachedFile {
        try requireOpen()
        try journal.requireMessageAccess(message, mediaID: media.mediaID)
        let revision = revisions[media.mediaID]
        var generation = try journal.currentAccessGeneration()
        var target = try await network.authorizedTarget(mediaID: media.mediaID, message: message)
        let automatic = resuming?.priority == .background || V2NetworkWorkScope.context?.priority == .background
        if automatic { try journal.requireAutomaticDownloadAllowed(mediaID: media.mediaID, message: message, target: target) }
        target = try restrictNetwork(target, automatic: automatic)
        try requireOpen()
        if let resuming {
            guard resuming.mediaID == media.mediaID, resuming.message == message,
                  resuming.bytes.map { $0 == target.expectedByteCount } ?? true, resuming.checksum.map { $0 == target.checksum } ?? true else { throw V2ResourceStorageError.integrityMismatch }
            if resuming.transport == .background {
                guard background != nil, target.backgroundDownloadAuthorization != nil else { throw V2ResourceStorageError.unavailable }
            }
        }
        let hasForegroundDemand = try journal.resolveDownloadDemand(mediaID: media.mediaID, message: message, bytes: target.expectedByteCount, checksum: target.checksum)
        let family = message.map { "message:\($0.roomID.rawValue):\(media.mediaID.rawValue)" } ?? "message:\(media.mediaID.rawValue)"
        let identity = "\(family):\(target.checksum.value):\(target.expectedByteCount)"
        identities[family] = identity
        identityUsers[family, default: 0] += 1
        defer { finishIdentity(family) }
        let use = try await fetch(identity: identity, mediaID: media.mediaID, message: message, target: target,
            allowBackground: resuming?.transport != .foreground && !hasForegroundDemand, restoringNativeJobID: resuming?.transport == .background ? resuming?.id : nil,
            ticket: ticket)
        do {
            let fileID = use.fileID
            try requireOpen()
            guard revisions[media.mediaID] == revision else { throw CancellationError() }
            // A membership/edit change while bytes were in flight needs fresh
            // authority, while another authorized caller can keep using the blob.
            let currentGeneration = try journal.currentAccessGeneration()
            if use.requiresFreshAuthorization || generation != currentGeneration || target.expiresAt <= Date() {
                generation = try journal.currentAccessGeneration()
                let fresh = try await network.authorizedTarget(mediaID: media.mediaID, message: message)
                guard fresh.checksum == target.checksum, fresh.expectedByteCount == target.expectedByteCount else { throw V2ResourceStorageError.unavailable }
                target = fresh
            }
            try requireOpen()
            try journal.requireMessageAccess(message, mediaID: media.mediaID)
            guard generation == (try journal.currentAccessGeneration()), target.expiresAt > Date(), revisions[media.mediaID] == revision else { throw V2ResourceStorageError.unavailable }
            let variant = try message.map { try V2ResourceVariantDescriptor(key: .init(resource: .init(home: .room($0.roomID), mediaID: media.mediaID)),
                checksum: target.checksum, byteCount: target.expectedByteCount) }
            try await bind(identity: identity, family: family, mediaID: media.mediaID, fileID: fileID, variant: variant)
            try journal.completeResolvedMessageDemand(mediaID: media.mediaID, message: message, fileID: fileID, owner: foregroundOwner)
            if let resuming {
                if resuming.transport == .background {
                    guard let background else { throw V2ResourceStorageError.unavailable }
                    try await background.didUseVerifiedCache(jobID: resuming.id, fileID: fileID, checksum: target.checksum, bytes: target.expectedByteCount)
                }
                try journal.completeResumedDownload(resuming, owner: foregroundOwner, fileID: fileID)
            }
            let result = try await handle(fileID: fileID, mediaID: media.mediaID, message: message, avatar: false, target: target, generation: generation, family: family, identity: identity)
            await use.lease.release()
            return result
        } catch { await use.lease.release(); throw error }
    }

    private func performAvatar(_ access: V2ResourceAvatarAccess, home: V2ResourceHome) async throws -> V2ResourceCachedFile {
        mediaUsers[access.mediaID, default: 0] += 1
        defer { finishMedia(access.mediaID) }
        let generation = try journal.currentAccessGeneration(), revision = revisions[access.mediaID]
        var ticket: UUID?
        defer { releaseCapacity(ticket) }
        while true {
            try requireOpen()
            // Unlike messages, an avatar arrives with an already authorized
            // plan rather than a resolver. Never rebase it onto newer authority.
            guard generation == (try journal.currentAccessGeneration()), revision == revisions[access.mediaID] else { throw V2ResourceStorageError.unavailable }
            do { return try await performAvatarAttempt(access, home: home, ticket: ticket) }
            catch let admission as AdmissionReady {
                releaseCapacity(ticket)
                ticket = admission.ticket
            }
        }
    }

    private func performAvatarAttempt(_ access: V2ResourceAvatarAccess, home: V2ResourceHome, ticket: UUID?) async throws -> V2ResourceCachedFile {
        try requireOpen()
        guard access.plan.expectedByteCount <= 2 * 1_024 * 1_024, access.plan.expiresAt > Date() else { throw V2ClientMediaTransferError.invalidTarget }
        let generation = try journal.currentAccessGeneration(), revision = revisions[access.mediaID]
        let target = try restrictNetwork(V2ClientMediaTransferTarget(downloadPlan: access.plan), automatic: V2NetworkWorkScope.context?.priority == .background)
        let homeColumns = GRDBV2LocalSyncStore.resourceHomeColumns(home)
        let family = "avatar:\(homeColumns.kind):\(homeColumns.id):\(access.mediaID.rawValue):\(access.variantID.rawValue)"
        guard access.version >= avatarVersions[family, default: 0] else { throw V2ResourceStorageError.unavailable }
        avatarVersions[family] = access.version
        let identity = "\(family):\(access.version):\(access.checksum.value)"
        identities[family] = identity
        identityUsers[family, default: 0] += 1
        defer { finishIdentity(family) }
        let use = try await fetch(identity: identity, mediaID: access.mediaID, message: nil, target: target, ticket: ticket)
        do {
            let fileID = use.fileID
            try requireOpen()
            guard generation == (try journal.currentAccessGeneration()), access.plan.expiresAt > Date(), revision == revisions[access.mediaID] else { throw V2ResourceStorageError.unavailable }
            let variant = try V2ResourceVariantDescriptor(key: .init(resource: .init(home: home, mediaID: access.mediaID),
                rendition: .derived(id: access.variantID, version: .init(access.version))), checksum: access.checksum, byteCount: target.expectedByteCount)
            try await bind(identity: identity, family: family, mediaID: access.mediaID, fileID: fileID, variant: variant)
            let result = try await handle(fileID: fileID, mediaID: access.mediaID, message: nil, avatar: true, target: target, generation: generation, family: family, identity: identity)
            await use.lease.release()
            return result
        } catch { await use.lease.release(); throw error }
    }

    /// Visible image rows request only the bounded server rendition. Original
    /// download demands remain separate and are never completed by a preview.
    public func imagePreview(_ media: V2MediaReference, message: V2MediaMessageLocation, size: V2MediaImagePreviewSize = .thumbnail) async throws -> V2ResourceCachedFile {
        try await operations.run { try await self.performImagePreview(media, message: message, size: size) }
    }

    /// Memory-only authorization lookup for already decoded presentation pixels.
    /// A miss never resolves a target, verifies a file, waits for admission or
    /// starts a transfer. This handle still requires borrowing before file I/O.
    public func cachedImagePreview(_ media: V2MediaReference, message: V2MediaMessageLocation,
                                   size: V2MediaImagePreviewSize = .thumbnail) throws -> V2ResourceCachedFile? {
        try requireOpen(); try Task.checkCancellation()
        try journal.requireMessageAccess(message, mediaID: media.mediaID)
        let key = PreviewKey(message: message, mediaID: media.mediaID, size: size)
        guard let cached = previewAuthorizations[key] else { return nil }
        let grant = cached.grant
        guard grant.deadline > Date(), grant.generation == (try journal.currentAccessGeneration()),
              identities[grant.family] == nil || identities[grant.family] == grant.identity else { return nil }
        guard grants.count < 256 else { return nil }
        identities[grant.family] = grant.identity
        let id = UUID(); grants[id] = grant
        rememberPreview(grant, fileURL: cached.fileURL, key: key)
        return .init(id: id, mediaID: media.mediaID, fileURL: cached.fileURL, owner: self)
    }

    private func performImagePreview(_ media: V2MediaReference, message: V2MediaMessageLocation, size: V2MediaImagePreviewSize) async throws -> V2ResourceCachedFile {
        mediaUsers[media.mediaID, default: 0] += 1
        defer { finishMedia(media.mediaID) }
        try requireOpen()
        try journal.requireMessageAccess(message, mediaID: media.mediaID)
        let key = PreviewKey(message: message, mediaID: media.mediaID, size: size)
        if let grant = previewAuthorizations[key]?.grant, grant.deadline > Date(),
           grant.generation == (try journal.currentAccessGeneration()),
           identities[grant.family] == nil || identities[grant.family] == grant.identity {
            let generation = grant.generation, revision = revisions[media.mediaID]
            // Only verified local bytes qualify. An evicted file resumes the
            // normal authenticated fetch; a tombstone/closed scope never does.
            if let url = try? await files.verifiedFile(id: grant.fileID, checksum: grant.checksum, bytes: grant.bytes) {
                try requireOpen()
                try journal.requireMessageAccess(message, mediaID: media.mediaID)
                guard generation == (try journal.currentAccessGeneration()), revision == revisions[media.mediaID],
                      grant.deadline > Date(), identities[grant.family] == nil || identities[grant.family] == grant.identity
                else { throw V2ResourceStorageError.unavailable }
                guard grants.count < 256 else { throw V2ResourceStorageError.capacityExceeded }
                identities[grant.family] = grant.identity
                let id = UUID(); grants[id] = grant
                rememberPreview(grant, fileURL: url, key: key)
                return .init(id: id, mediaID: media.mediaID, fileURL: url, owner: self)
            }
        }
        var ticket: UUID?
        defer { releaseCapacity(ticket) }
        while true {
            try requireOpen()
            try journal.requireMessageAccess(message, mediaID: media.mediaID)
            let generation = try journal.currentAccessGeneration(), revision = revisions[media.mediaID]
            let target = try restrictNetwork(await network.imagePreviewTarget(mediaID: media.mediaID, message: message, size: size), automatic: false)
            guard let variant = target.preview, variant.key.resource == .init(home: .room(message.roomID), mediaID: media.mediaID),
                  target.expectedByteCount <= 2 * 1_024 * 1_024 else { throw V2ResourceStorageError.integrityMismatch }
            let family = "preview:\(message.roomID.rawValue):\(media.mediaID.rawValue):\(size.rawValue)"
            let identity = "\(family):\(target.checksum.value):\(target.expectedByteCount)"
            identities[family] = identity
            identityUsers[family, default: 0] += 1
            do {
                let use = try await fetch(identity: identity, mediaID: media.mediaID, message: message, target: target, allowBackground: false, ticket: ticket)
                do {
                    try requireOpen()
                    try journal.requireMessageAccess(message, mediaID: media.mediaID)
                    guard generation == (try journal.currentAccessGeneration()), revision == revisions[media.mediaID], target.expiresAt > Date()
                    else { throw V2ResourceStorageError.unavailable }
                    try await bind(identity: identity, family: family, mediaID: media.mediaID, fileID: use.fileID, variant: variant)
                    let file = try await handle(fileID: use.fileID, mediaID: media.mediaID, message: message, avatar: false,
                        target: target, generation: generation, family: family, identity: identity, previewSize: size)
                    if let grant = grants[file.id] { rememberPreview(grant, fileURL: file.fileURL, key: key) }
                    await use.lease.release(); finishIdentity(family)
                    return file
                } catch { await use.lease.release(); throw error }
            } catch let admission as AdmissionReady {
                finishIdentity(family); releaseCapacity(ticket); ticket = admission.ticket
            } catch { finishIdentity(family); throw error }
        }
    }

    private func rememberPreview(_ grant: Grant, fileURL: URL, key: PreviewKey) {
        previewAuthorizations[key] = .init(grant: grant, fileURL: fileURL)
        previewRecency.removeAll { $0 == key }; previewRecency.append(key)
        while previewRecency.count > 64 {
            previewAuthorizations.removeValue(forKey: previewRecency.removeFirst())
        }
    }

    private func bind(identity: String, family: String, mediaID: MediaID, fileID: V2LocalResourceFileID, variant: V2ResourceVariantDescriptor?) async throws {
        guard identities[family] == identity else { throw V2ResourceStorageError.unavailable }
        let previous = try await files.bindDownload(identity: identity, family: family, mediaID: mediaID, fileID: fileID, variant: variant)
        grants = grants.filter { $0.value.family != family || $0.value.identity == identity }
        previewAuthorizations = previewAuthorizations.filter { $0.value.grant.family != family || $0.value.grant.identity == identity }
        previewRecency.removeAll { previewAuthorizations[$0] == nil }
        for file in previous where try !journal.hasCacheBindings(fileID: file) { try await files.retireCachedFile(file) }
        try requireOpen()
        guard identities[family] == identity else { throw V2ResourceStorageError.unavailable }
    }

    private func handle(fileID: V2LocalResourceFileID, mediaID: MediaID, message: V2MediaMessageLocation?, avatar: Bool,
                        target: V2ClientMediaTransferTarget, generation: Data, family: String, identity: String, previewSize: V2MediaImagePreviewSize? = nil) async throws -> V2ResourceCachedFile {
        guard grants.count < 256 else { throw V2ResourceStorageError.capacityExceeded }
        let url = try await files.verifiedFile(id: fileID, checksum: target.checksum, bytes: target.expectedByteCount)
        try requireOpen()
        guard generation == (try journal.currentAccessGeneration()), identities[family] == identity else { throw V2ResourceStorageError.unavailable }
        let id = UUID()
        grants[id] = .init(mediaID: mediaID, fileID: fileID, checksum: target.checksum, bytes: target.expectedByteCount,
            message: message, isAvatar: avatar, previewSize: previewSize, deadline: target.expiresAt, generation: generation, family: family, identity: identity)
        return .init(id: id, mediaID: mediaID, fileURL: url, owner: self)
    }

    private func fetch(identity: String, mediaID: MediaID, message: V2MediaMessageLocation?, target: V2ClientMediaTransferTarget, allowBackground: Bool = true, restoringNativeJobID: UUID? = nil, ticket: UUID? = nil) async throws -> DownloadUse {
        try requireOpen()
        let key = target.checksum.value + ":" + String(target.expectedByteCount)
        // A native recovery must join its current physical publisher before
        // retiring that publisher's raw inbox. Ordinary cache readers do not
        // dispose native source ownership and can still use ready bytes.
        let joinsNativePublisher = restoringNativeJobID != nil && flights[key]?.finished == false
        if !joinsNativePublisher, let existing = try journal.cacheFile(identity: identity),
           let lease = try? await files.borrowVerified(id: existing, checksum: target.checksum, bytes: target.expectedByteCount) {
            do { try journal.completeCachedForegroundDownloads(identity: key, fileID: existing, idleOwner: flights[key]?.finished != false ? foregroundOwner : nil); return .init(fileID: existing, lease: lease) }
            catch { await lease.release(); throw error }
        }
        try requireOpen()
        if !joinsNativePublisher, let matching = try journal.matchingFile(checksum: target.checksum, byteCount: target.expectedByteCount),
           let lease = try? await files.borrowVerified(id: matching.id, checksum: target.checksum, bytes: target.expectedByteCount) {
            do { try journal.completeCachedForegroundDownloads(identity: key, fileID: matching.id, idleOwner: flights[key]?.finished != false ? foregroundOwner : nil); return .init(fileID: matching.id, lease: lease) }
            catch { await lease.release(); throw error }
        }
        try requireOpen()
        // Failed/cancelled results may still have older consumers unwinding.
        // Do not join that obsolete result or replace its per-key user count.
        if flights[key]?.finished == true {
            try await waitForFinishedFlight(key)
            throw AdmissionReady(ticket: nil)
        }
        if let ticket, capacityReservations[ticket] != key { releaseCapacity(ticket) }
        let ownsCapacity = ticket.map { capacityReservations[$0] == key } ?? false
        if flights[key] == nil, !ownsCapacity,
           flights.count + capacityReservations.count >= 4 || !capacityOrder.isEmpty || capacityReservations.values.contains(key) {
            let reserved = try await waitForPhysicalCapacity(key)
            // Authorization and account facts may change while waiting. The
            // caller rebuilds them while retaining this one reserved slot.
            throw AdmissionReady(ticket: reserved)
        }
        let flight: V2SharedOperation<V2LocalResourceFileID>
        if let existing = flights[key] {
            let priority = V2NetworkWorkScope.context?.priority ?? .interactive
            if let job = existing.jobID {
                try journal.promoteForegroundDownload(job, owner: foregroundOwner, priority: priority)
            }
            existing.demand.promote(to: priority)
            flight = existing.operation
        }
        else {
            guard flights.count < 4 else { throw V2ResourceStorageError.capacityExceeded }
            let demand = V2ByteTransferDemand(priority: V2NetworkWorkScope.context?.priority ?? .interactive)
            flight = V2SharedOperation {
                try await V2ByteTransferWorkScope.$demand.withValue(demand) {
                    try await self.transfer(key: key, mediaID: mediaID, message: message, target: target, allowBackground: allowBackground, restoringNativeJobID: restoringNativeJobID)
                }
            }
            flights[key] = .init(operation: flight, demand: demand)
            releaseCapacity(ticket)
            wakeCapacityWaiters()
        }
        flights[key]?.users += 1
        do {
            let id = try await flight.value
            try requireOpen()
            let lease = try await files.borrowVerified(id: id, checksum: target.checksum, bytes: target.expectedByteCount)
            let requiresFreshAuthorization = flights[key]?.requiresFreshAuthorization ?? false
            await finishFlightUser(key)
            return .init(fileID: id, lease: lease, requiresFreshAuthorization: requiresFreshAuthorization)
        } catch { await finishFlightUser(key); throw error }
    }

    private func transfer(key: String, mediaID: MediaID, message: V2MediaMessageLocation?, target: V2ClientMediaTransferTarget, allowBackground: Bool, restoringNativeJobID: UUID?) async throws -> V2LocalResourceFileID {
        var foreground: V2ResourceTransferStaging?
        var backgroundFile: V2BackgroundDownloadedFile?
        var foregroundJob: UUID?
        do {
            try requireOpen()
            // Another owner may have published identical verified bytes after
            // admission but before this account flight actually began.
            if let matching = try journal.matchingFile(checksum: target.checksum, byteCount: target.expectedByteCount),
               let lease = try? await files.borrowVerified(id: matching.id, checksum: target.checksum, bytes: target.expectedByteCount) {
                flights[key]?.publication = lease
                try journal.completeCachedForegroundDownloads(identity: key, fileID: matching.id)
                await finishFlightTransfer(key)
                return matching.id
            }
            let reservation: V2ResourceTransferStaging
            if allowBackground, let background, target.backgroundDownloadAuthorization != nil {
                flights[key]?.requiresFreshAuthorization = true
                let result = try await background.download(mediaID: mediaID, message: message, initialTarget: target, restoringJobID: restoringNativeJobID)
                backgroundFile = result; reservation = result.reservation
            } else {
                let job = try journal.beginForegroundDownload(identity: key, mediaID: mediaID, message: message,
                    bytes: target.expectedByteCount, checksum: target.checksum, owner: foregroundOwner,
                    priority: flights[key]?.demand.priority ?? V2NetworkWorkScope.context?.priority ?? .interactive)
                foregroundJob = job
                flights[key]?.jobID = job
                reservation = try await files.reserveTransient(identity: key, bytes: target.expectedByteCount)
                foreground = reservation
                try requireOpen()
                try await V2ResourceDownloadProgressScope.$context.withValue(.init(job: job, hub: progress)) {
                    try await V2ResourceTransferWaitScope.$context.withValue(.init(transfer: .download(job), hub: progress)) {
                        try await self.network.download(target: target, to: reservation.fileURL)
                    }
                }
                try requireOpen()
                if let foregroundJob { try journal.foregroundDownloadAwaitingVerification(foregroundJob, owner: foregroundOwner) }
            }
            try requireOpen()
            let publication = try await files.publishDownload(of: reservation.fileURL, reservation: reservation,
                byteCount: target.expectedByteCount, checksum: target.checksum)
            flights[key]?.publication = publication.lease
            if let foregroundJob { try journal.completeForegroundDownload(foregroundJob, owner: foregroundOwner, fileID: publication.id) }
            try requireOpen()
            if let backgroundFile { try await background?.didPublish(backgroundFile) }
            if let foreground { try await files.releaseTransient(foreground.id, discard: true) }
            await finishFlightTransfer(key)
            return publication.id
        } catch {
            // Return the physical writer's claim before exposing an idle job
            // that management commands can cancel or resume.
            if let foreground { try? await files.releaseTransient(foreground.id, discard: false) }
            if let backgroundFile { try? await background?.didNotPublish(backgroundFile) }
            if let foregroundJob {
                if let control = try? journal.pauseForegroundDownload(foregroundJob, owner: foregroundOwner, issue: Self.downloadIssue(error)), control == .cancel {
                    try? await files.cancelForegroundDownload(foregroundJob)
                }
            }
            // Durable foreground checkpoints can resume under a fresh plan.
            // Background bytes retain their single owner until publication or drain.
            await finishFlightTransfer(key)
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    private func finishFlightUser(_ key: String) async {
        guard var flight = flights[key] else { return }
        flight.users -= 1
        flights[key] = flight
        await releaseFinishedFlight(key)
    }

    private func finishFlightTransfer(_ key: String) async {
        flights[key]?.finished = true
        await releaseFinishedFlight(key)
    }

    private func releaseFinishedFlight(_ key: String) async {
        guard let flight = flights[key], flight.finished, flight.users == 0 else { return }
        flights.removeValue(forKey: key)
        wakeCapacityWaiters()
        recoveryWake?.yield(())
        let waiters = finishedFlightWaiters.removeValue(forKey: key) ?? [:]
        for waiter in waiters.values { waiter.yield(()); waiter.finish() }
        await flight.publication?.release()
    }

    private func waitForFinishedFlight(_ key: String) async throws {
        let observation = V2ResourceTransferWaitScope.context?.begin(.transferSlot)
        defer { observation?.end() }
        guard flights[key]?.finished == true else { return }
        let id = UUID(), signal = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        finishedFlightWaiters[key, default: [:]][id] = signal.continuation
        defer {
            finishedFlightWaiters[key]?.removeValue(forKey: id)
            if finishedFlightWaiters[key]?.isEmpty == true { finishedFlightWaiters.removeValue(forKey: key) }
            signal.continuation.finish()
        }
        var iterator = signal.stream.makeAsyncIterator()
        while flights[key]?.finished == true {
            try requireOpen()
            guard await iterator.next() != nil else { throw CancellationError() }
        }
        try requireOpen()
    }

    private func waitForPhysicalCapacity(_ key: String) async throws -> UUID? {
        let observation = V2ResourceTransferWaitScope.context?.begin(.transferSlot)
        defer { observation?.end() }
        // At most 16 page callers plus two independently admitted recovery
        // workers share four physical slots; queue storage is bounded as well.
        guard capacityWaiters.count < 14 else { throw V2ResourceOperationScopeError.busy }
        let id = UUID(), signal = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        capacityWaiters[id] = .init(key: key, priority: V2NetworkWorkScope.context?.priority ?? .interactive,
            enqueuedAt: ProcessInfo.processInfo.systemUptime, continuation: signal.continuation)
        capacityOrder.append(id)
        defer {
            capacityWaiters.removeValue(forKey: id); capacityOrder.removeAll { $0 == id }
            signal.continuation.finish(); wakeCapacityWaiters()
        }
        var iterator = signal.stream.makeAsyncIterator()
        while true {
            try requireOpen()
            if flights[key]?.finished == false { return nil }
            if nextCapacityWaiter() == id, flights[key] == nil,
               !capacityReservations.values.contains(key), flights.count + capacityReservations.count < 4 {
                capacityReservations[id] = key
                return id
            }
            guard await iterator.next() != nil else { throw CancellationError() }
        }
    }

    private func releaseCapacity(_ ticket: UUID?) {
        if let ticket, capacityReservations.removeValue(forKey: ticket) != nil { wakeCapacityWaiters() }
    }
    private func wakeCapacityWaiters() {
        for waiter in capacityWaiters.values { waiter.continuation.yield(()) }
    }

    private func nextCapacityWaiter() -> UUID? {
        let now = ProcessInfo.processInfo.systemUptime
        var selected: UUID?, best = Int.max
        for id in capacityOrder {
            guard let waiter = capacityWaiters[id], flights[waiter.key] == nil,
                  !capacityReservations.values.contains(waiter.key) else { continue }
            let effective = max(0, waiter.priority.rawValue - Int(max(0, now - waiter.enqueuedAt) / 15))
            // Strict comparison preserves FIFO within each effective priority.
            if effective < best { best = effective; selected = id }
        }
        return selected
    }

    var admissionCounts: (waiting: Int, reserved: Int, flights: Int) { (capacityWaiters.count, capacityReservations.count, flights.count) }

    fileprivate func borrow(_ id: UUID) async throws -> V2ResourceFileLease {
        try requireOpen()
        guard var grant = grants[id], identities[grant.family] == grant.identity else { throw V2ResourceStorageError.unavailable }
        if !grant.isAvatar { try journal.requireMessageAccess(grant.message, mediaID: grant.mediaID) }
        if grant.generation != (try journal.currentAccessGeneration()) || grant.deadline <= Date() {
            guard !grant.isAvatar else { throw V2ResourceStorageError.unavailable }
            let generation = try journal.currentAccessGeneration()
            let target: V2ClientMediaTransferTarget
            if let size = grant.previewSize, let message = grant.message {
                target = try await network.imagePreviewTarget(mediaID: grant.mediaID, message: message, size: size)
            } else { target = try await network.authorizedTarget(mediaID: grant.mediaID, message: grant.message) }
            try requireOpen()
            guard grants[id] != nil, identities[grant.family] == grant.identity, generation == (try journal.currentAccessGeneration()), target.checksum == grant.checksum,
                  target.expectedByteCount == grant.bytes, target.expiresAt > Date() else { throw V2ResourceStorageError.unavailable }
            try journal.requireMessageAccess(grant.message, mediaID: grant.mediaID)
            grant = .init(mediaID: grant.mediaID, fileID: grant.fileID, checksum: grant.checksum, bytes: grant.bytes,
                message: grant.message, isAvatar: false, previewSize: grant.previewSize, deadline: target.expiresAt, generation: generation, family: grant.family, identity: grant.identity)
            grants[id] = grant
        }
        let lease = try await files.borrow(grant.fileID)
        do {
            try requireOpen()
            guard grants[id] != nil, identities[grant.family] == grant.identity, grant.generation == (try journal.currentAccessGeneration()) else { throw V2ResourceStorageError.unavailable }
            return lease
        } catch { await lease.release(); throw error }
    }

    fileprivate func releaseHandle(_ id: UUID) {
        if let grant = grants.removeValue(forKey: id) { pruneIdentity(grant.family) }
    }

    private func finishIdentity(_ family: String) {
        let remaining = identityUsers[family, default: 1] - 1
        identityUsers[family] = remaining == 0 ? nil : remaining
        pruneIdentity(family)
    }

    private func pruneIdentity(_ family: String) {
        guard identityUsers[family] == nil, !grants.values.contains(where: { $0.family == family }) else { return }
        identities.removeValue(forKey: family); avatarVersions.removeValue(forKey: family)
    }

    private func finishMedia(_ mediaID: MediaID) {
        let remaining = mediaUsers[mediaID, default: 1] - 1
        mediaUsers[mediaID] = remaining == 0 ? nil : remaining
        if remaining == 0 { revisions.removeValue(forKey: mediaID) }
    }

    public func discard(_ mediaID: MediaID) async throws {
        try requireOpen()
        if mediaUsers[mediaID] != nil { revisions[mediaID] = UUID() }
        previewAuthorizations = previewAuthorizations.filter { $0.key.mediaID != mediaID }
        previewRecency.removeAll { $0.mediaID == mediaID }
        let removedFamilies = Set(grants.values.filter { $0.mediaID == mediaID }.map(\.family))
        grants = grants.filter { $0.value.mediaID != mediaID }
        for family in removedFamilies { pruneIdentity(family) }
        let candidates = try journal.cachedFiles(mediaID: mediaID)
        try journal.removeCacheBindings(mediaID: mediaID)
        for file in candidates where try !journal.hasCacheBindings(fileID: file) { try await files.retireCachedFile(file) }
    }

    /// Management controls the physical task. Cancelling one download() waiter
    /// remains independent and does not invoke this account-level command.
    func controlForegroundDownload(_ id: UUID, control: V2ResourceDownloadControl) async throws {
        try requireOpen()
        let flight = flights.values.first { $0.jobID == id && !$0.finished }?.operation
        let resumption = resumedDownloads[id]
        let idle = try journal.requestForegroundDownloadControl(id, control: control,
            liveOwner: flight != nil || resumption != nil ? foregroundOwner : nil)
        // No suspension between recording intent and signalling actual owners.
        flight?.cancel(); resumption?.cancel()
        if idle && control == .cancel { try await files.cancelForegroundDownload(id) }
    }
    func cancelBackgroundResumption(_ id: UUID) { resumedDownloads[id]?.cancel() }

    public func close() async {
        closed = true; grants.removeAll(); identities.removeAll(); avatarVersions.removeAll()
        previewAuthorizations.removeAll(); previewRecency.removeAll()
        recoveryWake?.finish()
        for waiter in capacityWaiters.values { waiter.continuation.finish() }
        capacityWaiters.removeAll(); capacityOrder.removeAll(); capacityReservations.removeAll()
        for group in finishedFlightWaiters.values { for waiter in group.values { waiter.finish() } }
        finishedFlightWaiters.removeAll()
        let resumptions = Array(resumedDownloads.values)
        for work in resumptions { work.cancel() }
        let active = flights.values.map(\.operation)
        for flight in active { flight.cancel() }
        await background?.close()
        await recoveryActivity.close()
        await operations.close()
        await recoveryOperations.close()
        for work in resumptions { _ = await work.result }
        for flight in active { _ = await flight.result }
    }

    /// Account activity, separate from any page. Cancellation only detaches
    /// the scheduler waiter; close() cancels and drains its actual owned work.
    public func runRecovery() async throws {
        try requireOpen()
        guard !recoveryRunning else { throw V2ResourceOperationScopeError.busy }
        recoveryRunning = true; recoveryFailure = nil
        let generation = UUID(); recoveryGeneration = generation
        automaticConditions = automaticNetwork.initial
        let updates = automaticNetwork.updates()
        let networkObserver = Task {
            for await conditions in updates {
                guard !Task.isCancelled else { return }
                self.updateAutomaticNetwork(conditions, generation: generation)
            }
        }
        let wakes = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        recoveryWake = wakes.continuation
        defer { recoveryRunning = false; recoveryGeneration = nil; networkObserver.cancel(); recoveryWake = nil; wakes.continuation.finish(); progress.setNetworkWaits([:]) }
        try journal.recoverIdleDownloadClaims(owner: foregroundOwner, liveJobs: Set(resumedDownloads.keys),
            liveIdentities: Set(flights.filter { !$0.value.finished }.map(\.key)))
        let schedule = V2CommandRetrySchedule(nextAttemptAt: { try await self.nextRecoveryAttempt() }, updates: journal.downloadResumeSchedule().updates)
            .waking(on: wakes.stream)
        try await recoveryActivity.run {
            try await V2CommandRetryScheduler(schedule: schedule, flush: {
                try await self.resumeRequestedDownloads()
            }, now: self.recoveryNow).run()
        }
    }

    private func resumeRequestedDownloads() async throws {
        try requireOpen()
        if let recoveryFailure { throw recoveryFailure }
        for id in try journal.requestedDownloads(excluding: Set(resumedDownloads.keys), now: recoveryNow(), allowingAutomatic: automaticConditions.permitsAutomaticDownload) {
            guard resumedDownloads.count < 2 else { break }
            let work = V2SharedOperation { try await self.performOwnedResume(id) }
            resumedDownloads[id] = work
        }
    }

    private func nextRecoveryAttempt() throws -> Date? {
        try requireOpen()
        if let recoveryFailure { throw recoveryFailure }
        if resumedDownloads.count < 2 {
            if automaticConditions.permitsAutomaticDownload { try journal.requeueRecoverableAutomaticDownloads() }
            try journal.enqueueAutomaticDownloads()
        }
        let waiting = try journal.automaticNetworkWaitingJobs()
        let reason: V2ResourceTransferWaitingReason? = automaticConditions.permitsAutomaticDownload ? nil : (automaticConditions.available ? .networkPolicy : .network)
        progress.setNetworkWaits(reason.map { value in Dictionary(uniqueKeysWithValues: waiting.map { (.download($0), value) }) } ?? [:])
        guard resumedDownloads.count < 2 else { return nil }
        return try journal.nextRequestedDownloadAttempt(excluding: Set(resumedDownloads.keys), allowingAutomatic: automaticConditions.permitsAutomaticDownload)
    }

    var automaticNetworkConditions: V2ResourceAutomaticNetworkConditions { automaticConditions }

    private func updateAutomaticNetwork(_ value: V2ResourceAutomaticNetworkConditions, generation: UUID) {
        guard !closed, recoveryGeneration == generation, automaticConditions != value else { return }
        automaticConditions = value
        recoveryWake?.yield(())
    }

    private func performOwnedResume(_ id: UUID) async throws {
        defer { resumedDownloads.removeValue(forKey: id); recoveryWake?.yield(()) }
        do { try await performResume(id) }
        catch {
            if !(error is CancellationError), !closed, recoveryRunning { recoveryFailure = error }
            throw error
        }
    }

    private func performResume(_ id: UUID) async throws {
        try requireOpen()
        guard let request = try journal.claimDownloadResume(id, owner: foregroundOwner, now: recoveryNow()) else { return }
        do {
            _ = try await recoveryOperations.run {
                try await V2ResourceTransferWaitScope.$context.withValue(.init(transfer: .download(request.id), hub: self.progress)) {
                    try await V2NetworkWorkScope.$context.withValue(.init(service: "resources", priority: request.priority, isRetry: true)) {
                        try await self.performDownload(.init(mediaID: request.mediaID), message: request.message, resuming: request)
                    }
                }
            }
        } catch {
            // A shared byte writer may outlive this waiter's cancellation.
            // Never expose its own checkpoint as idle before it actually drains.
            if let identity = try journal.currentDownloadIdentity(request.id), let flight = flights[identity], flight.jobID == request.id, !flight.finished { _ = await flight.operation.result }
            // Ordinary transfer failures have now become durable task facts.
            // A journal failure must reach the account activity's diagnostics;
            // swallowing it would strand a claimed job until the next launch.
            if request.transport == .background {
                try journal.releaseBackgroundResume(id, owner: foregroundOwner, issue: Self.downloadIssue(error))
            } else if try journal.pauseForegroundDownload(id, owner: foregroundOwner, issue: Self.downloadIssue(error)) == .cancel {
                try await files.cancelForegroundDownload(id)
            }
            if request.priority == .background, !closed, !Task.isCancelled,
               error is V2ResourceAutomaticDownloadError || Self.retryableAutomaticFailure(error) {
                try journal.recordAutomaticDownloadFailure(request.id, issue: Self.downloadIssue(error), now: recoveryNow(),
                    retryAfter: (error as? V2HTTPFailure)?.retryAfter)
            }
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
        }
    }

    private static func retryableAutomaticFailure(_ error: any Error) -> Bool {
        if case V2ClientMediaTransferError.serverStatus(let status) = error { return [408,429].contains(status) || status >= 500 }
        if error as? V2ClientMediaTransferError == .targetExpired { return true }
        if let error = error as? URLError {
            return [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost,
                    .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed].contains(error.code)
        }
        if let error = error as? V2HTTPFailure {
            return error.kind == .transport || error.kind == .deadlineExceeded || [408,429].contains(error.statusCode ?? 0) || (error.statusCode ?? 0) >= 500
        }
        return false
    }

    private static func downloadIssue(_ error: any Error) -> V2ResourceDownloadIssue {
        switch error {
        case V2ResourceAutomaticDownloadError.policyRestricted: .policy
        case is CancellationError, V2ResourceStorageError.closed: .interrupted
        case V2ResourceStorageError.integrityMismatch, V2ClientMediaTransferError.byteCountMismatch,
             V2ClientMediaTransferError.checksumMismatch, V2RangeDownloadError.versionChanged: .integrity
        case V2ResourceStorageError.capacityExceeded: .space
        case V2ClientMediaTransferError.authorizationDenied, V2ClientMediaTransferError.authorizationUnavailable, V2ResourceStorageError.unavailable: .unavailable
        case V2ClientMediaTransferError.serverStatus(401), V2ClientMediaTransferError.serverStatus(403): .unavailable
        case let error as V2HTTPFailure where [401,403].contains(error.statusCode ?? 0): .unavailable
        case let error as CocoaError where error.code == .fileWriteOutOfSpace: .space
        case let error as POSIXError where error.code == .ENOSPC: .space
        default: .network
        }
    }

    private func restrictNetwork(_ target: V2ClientMediaTransferTarget, automatic: Bool) throws -> V2ClientMediaTransferTarget {
        try target.restrictingNetwork(to: journal.downloadNetworkPreferences().constraints(automatic: automatic))
    }

    private func requireOpen() throws {
        try Task.checkCancellation()
        guard !closed else { throw V2ResourceStorageError.closed }
    }


}
