import Foundation
import IMV2Core
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct V2ResourceTransferStaging: Sendable {
    let id: UUID
    let fileURL: URL
}

/// One actual file consumer. A lease protects file lifetime, not server access.
public final class V2ResourceFileLease: Sendable {
    public let fileURL: URL
    fileprivate let id: UUID
    fileprivate let owner: V2ResourceFileStore

    fileprivate init(fileURL: URL, id: UUID, owner: V2ResourceFileStore) {
        self.fileURL = fileURL; self.id = id; self.owner = owner
    }

    public func release() async { await owner.release(id) }
    /// A separately owned hard link for platform readers that infer a type
    /// from its extension. The original borrow can be returned immediately.
    public func forPresentation(fileExtension: String) async throws -> V2ResourceFileLease {
        try await owner.borrowForPresentation(from: id, fileExtension: fileExtension)
    }
    public func forExport(fileName: V2ResourceExportFileName) async throws -> V2ResourceFileLease {
        try await owner.borrowForExport(from: id, fileName: fileName)
    }
    deinit {
        let owner = owner, id = id
        Task { await owner.release(id) }
    }
}

/// One bounded derived upload slice. Only its file owner removes the bytes.
public final class V2ResourceTemporaryFile: Sendable {
    public let fileURL: URL
    private let id: UUID
    private let owner: V2ResourceFileStore
    fileprivate init(fileURL: URL, id: UUID, owner: V2ResourceFileStore) {
        self.fileURL = fileURL; self.id = id; self.owner = owner
    }
    public func release() async throws { try await owner.releaseTransient(id, discard: true) }
    deinit {
        let owner = owner, id = id
        Task { try? await owner.releaseTransient(id, discard: true) }
    }
}

/// Account-owned byte lifecycle. Synchronous journal/file steps stay on this
/// actor, so publication, borrowing and retirement cannot interleave halfway.
public actor V2ResourceFileStore {
    enum PublicationCheckpoint: CaseIterable, Sendable { case partialWritten, renamed, published }
    enum PlacementCheckpoint: CaseIterable, Sendable { case targetLinked, catalogCommitted, sourceRemoved }
    enum BackgroundSourceCheckpoint: CaseIterable, Sendable { case reserved, partialWritten, renamed, ready }
    private let root: URL
    private let cacheRoot: URL
    nonisolated let backgroundDirectory: URL
    private let journal: V2ResourceFileJournal
    private var policy: V2ResourceStoragePolicy
    private let protection: any V2ResourceFileProtectionWriting
    private var leases: [UUID: V2LocalResourceFileID] = [:]
    private var presentationAliases: [UUID: URL] = [:]
    private var cleanupPlans: [UUID: V2ResourceCleanupPlan] = [:]
    private var closing = false
    private var recovered = false
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var transientReservations: [UUID: Int64] = [:]
    private var backgroundConsumers: [UUID: UUID] = [:]
    private let checkpoint: @Sendable (PublicationCheckpoint) throws -> Void
    private let placementCheckpoint: @Sendable (PlacementCheckpoint) throws -> Void
    private let backgroundSourceCheckpoint: @Sendable (BackgroundSourceCheckpoint) throws -> Void

    init(root: URL, cacheRoot: URL? = nil, backgroundRoot: URL? = nil, journal: V2ResourceFileJournal, policy: V2ResourceStoragePolicy = .standard,
                protection: any V2ResourceFileProtectionWriting = V2SystemResourceFileProtectionWriter()) throws {
        guard root.isFileURL, cacheRoot?.isFileURL ?? true else { throw V2ResourceStorageError.invalidRecord }
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.cacheRoot = (cacheRoot ?? root.appending(path: "cache")).standardizedFileURL.resolvingSymlinksInPath()
        backgroundDirectory = (backgroundRoot ?? root.appendingPathExtension("background")).standardizedFileURL
        guard self.cacheRoot != self.root else { throw V2ResourceStorageError.invalidRecord }
        self.journal = journal; self.policy = try journal.storagePolicy(defaults: policy); self.protection = protection
        checkpoint = { _ in }
        placementCheckpoint = { _ in }
        backgroundSourceCheckpoint = { _ in }
    }

    public init(scope: V2AccountStorageScope, journal: V2ResourceFileJournal, policy: V2ResourceStoragePolicy = .standard,
                protection: any V2ResourceFileProtectionWriting = V2SystemResourceFileProtectionWriter()) throws {
        guard try journal.accountID() == scope.accountID else { throw V2AccountStorageError.scopeMismatch }
        try self.init(root: scope.resourceFilesDirectory, cacheRoot: scope.resourceCacheDirectory, backgroundRoot: scope.backgroundDirectory,
            journal: journal, policy: policy, protection: protection)
    }

    init(root: URL, cacheRoot: URL? = nil, backgroundRoot: URL? = nil, journal: V2ResourceFileJournal, policy: V2ResourceStoragePolicy,
         placementCheckpoint: @escaping @Sendable (PlacementCheckpoint) throws -> Void = { _ in },
         backgroundSourceCheckpoint: @escaping @Sendable (BackgroundSourceCheckpoint) throws -> Void = { _ in },
         checkpoint: @escaping @Sendable (PublicationCheckpoint) throws -> Void) throws {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.cacheRoot = (cacheRoot ?? root.appending(path: "cache")).standardizedFileURL.resolvingSymlinksInPath()
        backgroundDirectory = (backgroundRoot ?? root.appendingPathExtension("background")).standardizedFileURL
        self.journal = journal; self.policy = try journal.storagePolicy(defaults: policy)
        protection = V2SystemResourceFileProtectionWriter(); self.checkpoint = checkpoint
        self.placementCheckpoint = placementCheckpoint
        self.backgroundSourceCheckpoint = backgroundSourceCheckpoint
    }

    /// Copies a caller-owned input; never removes the caller's only original.
    /// Published files are immutable and use internally generated filenames.
    public func publishCopy(of source: URL, fileID id: V2LocalResourceFileID = .init(), byteCount: Int64, checksum: V2ResourceChecksum,
                            retention: V2ResourceFileRetention, now: Date = Date()) throws -> V2LocalResourceFileID {
        try publishCopy(of: .file(source), fileID: id, byteCount: byteCount, checksum: checksum, retention: retention,
                        storage: retention == .cache ? .cache : .persistent, publicationClass: retention, now: now)
    }

    private func publishCopy(of source: V2ResourcePublicationInput, fileID id: V2LocalResourceFileID, byteCount: Int64, checksum: V2ResourceChecksum,
                             retention: V2ResourceFileRetention, storage: V2ResourceFileStorage, publicationClass: V2ResourceFileRetention,
                             reservation: UUID? = nil, now: Date) throws -> V2LocalResourceFileID {
        try prepare()
        guard byteCount > 0 else { throw V2ResourceStorageError.invalidRecord }
        if let existing = try journal.record(id) {
            guard existing.state == .published, existing.checksum == checksum,
                  existing.byteCount == byteCount, existing.retention == retention else { throw V2ResourceStorageError.conflict }
            try verifyPublished(existing)
            return id
        }
        if let existing = try journal.matchingFile(checksum: checksum, byteCount: byteCount) {
            do {
                try verifyPublished(existing)
                if publicationClass == .original {
                    try ensureOriginalCapacity(reusing: existing)
                }
                if storage == .persistent { try ensurePlacement(existing.id, storage: .persistent) }
                if retention != .cache { try journal.setRetention(retention, id: existing.id) }
                try journal.touch(existing.id, now: now)
                return existing.id
            } catch is CancellationError { throw CancellationError() }
            catch {
                // A disposable corrupt candidate cannot block a fresh copy.
                // Original/retained bytes remain protected for user recovery.
                guard try journal.record(existing.id)?.state == .invalid else { throw error }
                try retireCachedFile(existing.id)
            }
        }
        if case .file(let url) = source { try Self.requireRegularFile(url) }
        let credit = try reservation.map { try journal.publicationCredit($0, bytes: byteCount) } ?? 0
        try ensureAdmission(category: publicationClass, bytes: byteCount, managedAddition: byteCount - credit)
        try journal.beginPublication(id: id, checksum: checksum, bytes: byteCount, retention: retention, storage: storage,
                                     publicationClass: publicationClass, policy: policy, reservation: reservation, now: now)
        // Any interruption leaves enough journal state for the next prepare().
        recovered = false
        let partial = partialURL(id, storage: storage), final = fileURL(id, storage: storage)
        do {
            guard FileManager.default.createFile(atPath: partial.path, contents: nil) else { throw V2ResourceStorageError.unavailable }
            try protection.apply(.complete, to: partial)
            try V2LocalBackupExclusion.apply(to: partial)
            let output = try FileHandle(forWritingTo: partial)
            defer { try? output.close() }
            try source.write(to: output, expectedBytes: byteCount)
            try output.synchronize()
            try verify(partial, bytes: byteCount, checksum: checksum)
            try checkpoint(.partialWritten)
            try FileManager.default.moveItem(at: partial, to: final)
            try protection.apply(.complete, to: final)
            try V2LocalBackupExclusion.apply(to: final)
            try synchronizeDirectory(final.deletingLastPathComponent())
            try synchronizeDirectory(partial.deletingLastPathComponent())
            try checkpoint(.renamed)
            try journal.finishPublication(id, allocatedBytes: allocatedBytes(final))
            try checkpoint(.published)
            recovered = true
            return id
        } catch {
            // A journaled, unreturned copy is recoverable. Do not clean paths
            // here: publication may have committed immediately before failure.
            throw error
        }
    }

    /// The caller keeps security-scoped access open until this returns. A
    /// durable import record precedes publication, so a crash after rename can
    /// restore the draft's identity without persisting an external file URL.
    func importOriginal(source: URL, id: V2LocalResourceAssetID, displayName: V2ResourceDisplayName,
                        contentType: V2ResourceContentType, purpose: V2LocalResourceAssetPurpose,
                        imageDimensions: V2LocalResourceImageDimensions? = nil, maximumBytes: Int64, maximumSelections: Int, now: Date = Date()) throws -> V2LocalResourceAsset {
        try prepare(); try Task.checkCancellation()
        try Self.requireRegularFile(source)
        let facts = try source.resourceValues(forKeys: [.fileSizeKey])
        guard let size = facts.fileSize, size > 0, maximumBytes > 0, (1...256).contains(maximumSelections) else { throw V2ResourceStorageError.invalidRecord }
        let bytes = Int64(size)
        return try importOriginal(input: .file(source), bytes: bytes, id: id, displayName: displayName, contentType: contentType,
            purpose: purpose, imageDimensions: imageDimensions, maximumBytes: maximumBytes, maximumSelections: maximumSelections, now: now)
    }

    func importOriginal(data: Data, id: V2LocalResourceAssetID, displayName: V2ResourceDisplayName,
                        contentType: V2ResourceContentType, purpose: V2LocalResourceAssetPurpose,
                        imageDimensions: V2LocalResourceImageDimensions? = nil, maximumBytes: Int64, maximumSelections: Int, now: Date = Date()) throws -> V2LocalResourceAsset {
        try prepare(); try Task.checkCancellation()
        return try importOriginal(input: .data(data), bytes: Int64(data.count), id: id, displayName: displayName, contentType: contentType,
            purpose: purpose, imageDimensions: imageDimensions, maximumBytes: maximumBytes, maximumSelections: maximumSelections, now: now)
    }

    private func importOriginal(input: V2ResourcePublicationInput, bytes: Int64, id: V2LocalResourceAssetID,
                                displayName: V2ResourceDisplayName, contentType: V2ResourceContentType, purpose: V2LocalResourceAssetPurpose,
                                imageDimensions: V2LocalResourceImageDimensions? = nil, maximumBytes: Int64, maximumSelections: Int, now: Date) throws -> V2LocalResourceAsset {
        guard bytes > 0, maximumBytes > 0, (1...256).contains(maximumSelections) else { throw V2ResourceStorageError.invalidRecord }
        guard bytes <= maximumBytes else { throw V2ResourceStorageError.capacityExceeded }
        let checksum = try V2ResourceChecksum(value: input.checksum(expectedBytes: bytes))
        if let existing = try journal.localAsset(id), existing.availability == .local {
            guard existing.selectionActive, existing.checksum == checksum, existing.byteCount == bytes,
                  existing.displayName == displayName, existing.contentType == contentType, existing.purpose == purpose, existing.imageDimensions == imageDimensions,
                  let file = existing.fileID else { throw V2ResourceStorageError.conflict }
            _ = try verifiedFile(id: file, checksum: checksum, bytes: bytes)
            return existing
        }
        var reusable = false
        if let matching = try journal.matchingFile(checksum: checksum, byteCount: bytes) {
            do { try verifyPublished(matching); try ensureOriginalCapacity(reusing: matching); reusable = true }
            catch is CancellationError { throw CancellationError() }
            catch { guard try journal.record(matching.id)?.state == .invalid else { throw error } }
        }
        if !reusable {
            try ensureAdmission(category: .original, bytes: bytes)
        }
        let planned = try journal.localAsset(id)?.plannedFileID ?? V2LocalResourceFileID()
        try journal.beginAssetImport(id: id, plannedFile: planned, name: displayName, contentType: contentType,
            bytes: bytes, checksum: checksum, purpose: purpose, imageDimensions: imageDimensions, maximumSelections: maximumSelections, now: now)
        do {
            // Asset ownership is installed by finishAssetImport, rather than a
            // second unconditional original claim on the same physical blob.
            let file = try publishCopy(of: input, fileID: planned, byteCount: bytes, checksum: checksum, retention: .cache, storage: .persistent, publicationClass: .original, now: now)
            try Task.checkCancellation()
            try journal.finishAssetImport(id, fileID: file)
            guard let asset = try journal.localAsset(id) else { throw V2ResourceStorageError.unavailable }
            return asset
        } catch is CancellationError {
            recovered = false
            try journal.releaseAssetSelection(id)
            throw CancellationError()
        } catch {
            recovered = false
            throw error
        }
    }

    func borrowSelection(_ id: V2LocalResourceAssetID) throws -> V2ResourceFileLease {
        try borrowOriginal(for: .selection(id))
    }

    func borrowOriginal(for context: V2LocalResourceReadContext) throws -> V2ResourceFileLease {
        try prepare()
        let asset = try journal.original(for: context)
        guard let file = asset.fileID else { throw V2ResourceStorageError.unavailable }
        return try borrow(file)
    }

    func localAsset(_ id: V2LocalResourceAssetID) throws -> V2LocalResourceAsset? {
        try prepare(); return try journal.localAsset(id)
    }

    func discardSelection(_ id: V2LocalResourceAssetID) throws {
        try prepare()
        try journal.releaseAssetSelection(id)
    }

    func selectedAssets(purpose: V2LocalResourceAssetPurpose) throws -> [V2LocalResourceAsset] {
        try prepare(); return try journal.selectedAssets(purpose: purpose)
    }

    public func snapshot() throws -> V2ResourceStorageSnapshot {
        try prepare()
        let staging = try journal.stagingReservations()
        var temporaryBytes: Int64 = 0
        for entry in staging where entry.location == .foreground {
            let url = transferURL(entry.id)
            for candidate in [url,url.appendingPathExtension("range-part"),url.appendingPathExtension("range-journal")] where FileManager.default.fileExists(atPath: candidate.path) {
                try Self.requireRegularFile(candidate)
                temporaryBytes += try allocatedBytes(candidate)
            }
        }
        let backgrounds = try journal.backgroundSources()
        var backgroundAllocated: Int64 = 0
        for entry in backgrounds {
            for candidate in [backgroundURL(entry), backgroundURL(entry).appendingPathExtension("partial")] where FileManager.default.fileExists(atPath: candidate.path) {
                guard candidate.deletingLastPathComponent().resolvingSymlinksInPath().path == candidate.deletingLastPathComponent().path else { throw V2ResourceStorageError.unsafeFile }
                try Self.requireRegularFile(candidate)
                backgroundAllocated += try allocatedBytes(candidate)
            }
        }
        let backgroundDownloads = staging.filter { $0.location != .foreground }
        for entry in backgroundDownloads {
            if case .backgroundDownload(let session, let mapping) = entry.location {
                backgroundAllocated += try downloadInbox(session).allocatedBytes(mapping)
            }
        }
        return .init(files: try journal.records(), avatarOnlyCacheFileIDs: try journal.avatarOnlyCacheFiles(),
            transferReservedBytes: staging.filter { $0.location == .foreground }.reduce(0) { $0 + $1.reservedBytes }, transferAllocatedBytes: temporaryBytes,
            backgroundReservedBytes: backgrounds.reduce(0) { $0 + $1.reservedBytes } + backgroundDownloads.reduce(0) { $0 + $1.reservedBytes }, backgroundAllocatedBytes: backgroundAllocated,
            quota: try journal.quotaSnapshot(policy: policy))
    }

    public func setStoragePolicy(_ value: V2ResourceStoragePolicy) throws -> V2ResourceQuotaSnapshot {
        try prepare(); try Task.checkCancellation()
        try journal.setStoragePolicy(value)
        policy = value
        try reclaimForAdmission(cacheAddition: 0, temporaryAddition: 0, managedAddition: 0)
        return try journal.quotaSnapshot(policy: policy)
    }

    /// Module-only: access authorization must be acquired by ResourceCenter
    /// before it invokes this byte-lifetime operation.
    func borrow(_ id: V2LocalResourceFileID, now: Date = Date()) throws -> V2ResourceFileLease {
        try prepare()
        guard leases.count < 64 else { throw V2ResourceStorageError.capacityExceeded }
        guard let record = try journal.record(id), record.state == .published else { throw V2ResourceStorageError.unavailable }
        let file = fileURL(id, storage: record.storage)
        try verifyPublished(record)
        try journal.touch(id, now: now)
        let leaseID = UUID()
        leases[leaseID] = id
        return V2ResourceFileLease(fileURL: file, id: leaseID, owner: self)
    }

    fileprivate func borrowForPresentation(from sourceLease: UUID, fileExtension: String) throws -> V2ResourceFileLease {
        try prepare()
        guard !fileExtension.isEmpty, fileExtension.utf8.count <= 16,
              fileExtension.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) }) else {
            throw V2ResourceStorageError.invalidRecord
        }
        guard leases.count < 64 else { throw V2ResourceStorageError.capacityExceeded }
        guard let id = leases[sourceLease], let record = try journal.record(id), record.state == .published else {
            throw V2ResourceStorageError.unavailable
        }
        try verifyPublished(record)
        let leaseID = UUID()
        let alias = root.appending(path: "presentations").appending(path: leaseID.uuidString + "." + fileExtension)
        // Same-volume hard links add no second payload. There are at most 64
        // live aliases and no caller-controlled basename or external path.
        try FileManager.default.linkItem(at: fileURL(id, storage: record.storage), to: alias)
        leases[leaseID] = id; presentationAliases[leaseID] = alias
        return .init(fileURL: alias, id: leaseID, owner: self)
    }

    fileprivate func borrowForExport(from sourceLease: UUID, fileName: V2ResourceExportFileName) throws -> V2ResourceFileLease {
        try prepare()
        guard leases.count < 64 else { throw V2ResourceStorageError.capacityExceeded }
        guard let id = leases[sourceLease], let record = try journal.record(id), record.state == .published else {
            throw V2ResourceStorageError.unavailable
        }
        try verifyPublished(record)
        let leaseID = UUID()
        let directory = root.appending(path: "exports").appending(path: leaseID.uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            try protection.apply(.complete, to: directory)
            try V2LocalBackupExclusion.apply(to: directory)
            let alias = directory.appendingPathComponent(fileName.value)
            try FileManager.default.linkItem(at: fileURL(id, storage: record.storage), to: alias)
            leases[leaseID] = id; presentationAliases[leaseID] = alias
            return .init(fileURL: alias, id: leaseID, owner: self)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    public func setRetained(_ retained: Bool, fileID: V2LocalResourceFileID) throws {
        try prepare()
        guard let record = try journal.record(fileID) else { throw V2ResourceStorageError.unavailable }
        if retained, record.state == .published { try ensurePlacement(fileID, storage: .persistent) }
        try journal.setRetention(retained ? .retained : .cache, id: fileID)
        try reconcilePlacements()
    }

    /// Publication can precede a resource's variant binding. This observation
    /// avoids admitting duplicate work in that window; it grants no read access.
    /// Consumers must still authorize and verify through the download cache.
    func hasPublishedBytes(checksum: V2ResourceChecksum, bytes: Int64) throws -> Bool {
        try prepare()
        guard let record = try journal.matchingFile(checksum: checksum, byteCount: bytes) else { return false }
        do {
            let values = try fileURL(record.id, storage: record.storage).resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            return values.isRegularFile == true && values.isSymbolicLink == false && values.fileSize == Int(exactly: bytes)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return false }
    }

    func variantSnapshots(for resource: V2ResourceKey) throws -> [V2ResourceVariantSnapshot] {
        try prepare()
        return try journal.variants(for: resource).map { variant in
            let local: V2ResourceVariantSnapshot.LocalState
            if let id = variant.fileID, let file = try journal.record(id) {
                switch file.state {
                case .published: local = .available(storage: file.storage, allocatedBytes: file.allocatedBytes)
                case .invalid: local = .invalid
                default: local = .needsDownload
                }
            } else { local = .needsDownload }
            return .init(descriptor: variant.descriptor, isRetained: variant.isRetained, localState: local)
        }
    }

    func setVariantRetained(_ retained: Bool, key: V2ResourceVariantKey, now: Date = Date()) throws {
        try prepare(); try Task.checkCancellation()
        guard let variant = try journal.variant(key) else { throw V2ResourceStorageError.unavailable }
        var binding: V2LocalResourceFileID?
        if retained, let record = try journal.matchingFile(checksum: variant.descriptor.checksum, byteCount: variant.descriptor.byteCount) {
            do {
                try verifyPublished(record)
                try ensurePlacement(record.id, storage: .persistent)
                binding = record.id
            } catch {
                guard try journal.record(record.id)?.state == .invalid else { throw error }
            }
        }
        // The intent and binding share one transaction, including other
        // retained variants using these already-verified bytes.
        try journal.setVariantRetained(retained, key: key, now: now, binding: binding)
        try reconcilePlacements()
    }

    func releaseUnavailableRetention(_ selections: [V2ResourceRetentionSelection], expiresAt: Date) throws -> V2ResourceUnavailableRetentionResult {
        try prepare(); try Task.checkCancellation()
        guard expiresAt > Date() else { throw V2ResourceStorageError.expiredCleanupPlan }
        let result = try journal.releaseUnavailableRetention(selections)
        try reconcilePlacements()
        return result
    }

    func bindDownload(identity: String, family: String, mediaID: MediaID, fileID: V2LocalResourceFileID,
                      variant: V2ResourceVariantDescriptor?) throws -> [V2LocalResourceFileID] {
        try prepare(); try Task.checkCancellation()
        if let variant, try journal.variant(variant.key)?.isRetained == true {
            try ensurePlacement(fileID, storage: .persistent)
        }
        let previous = try journal.bindCache(identity: identity, family: family, mediaID: mediaID, fileID: fileID, variant: variant)
        try reconcilePlacements()
        return previous
    }

    public func planCleanup(fileIDs: [V2LocalResourceFileID]? = nil, now: Date = Date()) throws -> V2ResourceCleanupPlan {
        try prepare()
        guard now.timeIntervalSince1970.isFinite, now.timeIntervalSince1970 >= 0 else { throw V2ResourceStorageError.invalidRecord }
        cleanupPlans = cleanupPlans.filter { $0.value.expiresAt > now }
        guard cleanupPlans.count < 16 else { throw V2ResourceStorageError.capacityExceeded }
        let selection = fileIDs.map(Set.init)
        let records = try journal.records().filter { selection?.contains($0.id) ?? true }
        var candidates: [V2ResourceFileRecord] = [], skipped = 0
        for record in records {
            let protected = try journal.hasConsumers(record.id)
            if record.retention != .cache || ![.published,.invalid,.missing].contains(record.state) || leases.values.contains(record.id) || protected {
                skipped += 1
            } else { candidates.append(record) }
        }
        let stages = fileIDs == nil ? try journal.stagingReservations() : []
        let inactive = stages.filter { $0.location == .foreground && transientReservations[$0.id] == nil }
        skipped += stages.count - inactive.count
        if fileIDs == nil { skipped += try journal.backgroundSources().count }
        let temporaryBytes = try inactive.reduce(Int64(0)) { $0 + (try transferAllocatedBytes($1.id)) }
        let plan = V2ResourceCleanupPlan(id: UUID(), fileIDs: candidates.map(\.id), transferStagingIDs: inactive.map(\.id),
            estimatedBytes: candidates.reduce(temporaryBytes) { $0 + $1.allocatedBytes }, skippedCount: skipped, expiresAt: now.addingTimeInterval(30))
        cleanupPlans[plan.id] = plan
        return plan
    }

    public func commitCleanup(_ plan: V2ResourceCleanupPlan, now: Date = Date()) throws -> V2ResourceCleanupResult {
        try prepare()
        guard now.timeIntervalSince1970.isFinite,
              cleanupPlans.removeValue(forKey: plan.id) == plan, now < plan.expiresAt else { throw V2ResourceStorageError.expiredCleanupPlan }
        var deleted = 0, released: Int64 = 0, skipped = plan.skippedCount, failed = 0
        for id in plan.fileIDs {
            try Task.checkCancellation()
            if leases.values.contains(id) { skipped += 1; continue }
            do {
                guard let record = try journal.record(id), try journal.beginDeletion(id) else { skipped += 1; continue }
                let file = fileURL(id, storage: record.storage)
                let existingBytes = FileManager.default.fileExists(atPath: file.path) ? try allocatedBytes(file) : 0
                try removeAllPlacements(id)
                try journal.finishDeletion(id)
                deleted += 1; released += min(record.allocatedBytes, existingBytes)
            } catch { failed += 1; recovered = false }
        }
        for id in plan.transferStagingIDs {
            try Task.checkCancellation()
            if transientReservations[id] != nil { skipped += 1; continue }
            do {
                guard try journal.stagingReservations().contains(where: { $0.id == id }) else { skipped += 1; continue }
                let bytes = try transferAllocatedBytes(id)
                try removeTransferFiles(id)
                try journal.removeStaging(id)
                deleted += 1; released += bytes
            } catch { failed += 1 }
        }
        return .init(deletedCount: deleted, releasedBytes: released, skippedCount: skipped, failedCount: failed)
    }

    public func reconcileFiles() throws {
        recovered = false
        try prepare()
        try reclaimForAdmission(cacheAddition: 0, temporaryAddition: 0, managedAddition: 0)
    }

    func cancelForegroundDownload(_ id: UUID) throws {
        try prepare()
        let identity = try journal.requestForegroundDownloadCancellation(id)
        try discardCancelledForegroundDownload(id, identity: identity)
    }
    private func discardCancelledForegroundDownload(_ id: UUID, identity: String) throws {
        let stages = try journal.stagingReservations().filter { $0.location == .foreground && $0.identity == identity }
        guard stages.allSatisfy({ transientReservations[$0.id] == nil }) else { throw V2ResourceStorageError.fileInUse }
        for stage in stages { try removeTransferFiles(stage.id); try journal.removeStaging(stage.id) }
        try journal.finishForegroundDownloadCancellation(id)
    }

    /// Age and LRU decisions use journal facts, never caller-writable mtimes.
    /// Real borrows and durable consumers always win over automatic eviction.
    func maintainCache(maximumEntryCount: Int, maximumAge: TimeInterval, now: Date = Date(), excluding: Set<V2LocalResourceFileID> = []) throws {
        try Task.checkCancellation()
        try prepare()
        guard maximumEntryCount > 0, maximumAge.isFinite, maximumAge > 0,
              now.timeIntervalSince1970.isFinite else { throw V2ResourceStorageError.invalidRecord }
        let records = try journal.records().filter { $0.retention == .cache }
        var remaining = records.count
        for record in records {
            try Task.checkCancellation()
            let expired = record.lastAccessAt <= now.addingTimeInterval(-maximumAge)
            guard expired || remaining > maximumEntryCount || record.state == .invalid || record.state == .missing else { continue }
            guard !excluding.contains(record.id), !leases.values.contains(record.id), try !journal.hasConsumers(record.id) else { continue }
            try retireCachedFile(record.id)
            if try journal.record(record.id) == nil { remaining -= 1 }
        }
        try Task.checkCancellation()
        try reclaimForAdmission(cacheAddition: 0, temporaryAddition: 0, managedAddition: 0, excluding: excluding)
    }

    /// The network output and its future publication share one durable peak
    /// reservation. Publication transfers credit instead of charging it twice.
    func reserveTransient(identity: String, bytes: Int64,
                          footprint: V2ResourceTemporaryFootprint = .downloadAndPublication,
                          location: V2ResourceTemporaryReservationRecord.Location = .foreground) throws -> V2ResourceTransferStaging {
        try prepare()
        guard bytes > 0, bytes <= Int64.max / 8,
              !identity.isEmpty, identity.utf8.count <= 1024 else { throw V2ResourceStorageError.capacityExceeded }
        let reservations = try journal.stagingReservations()
        let existing = reservations.first { $0.identity == identity }
        let publication = footprint.publicationBytes(for: bytes)
        let addition = max(0, bytes + publication - (existing?.reservedBytes ?? 0))
        if addition > policy.maximumTemporaryBytes { throw V2ResourceStorageError.capacityExceeded }
        if let existing { guard existing.bytes == bytes, existing.location == location, transientReservations[existing.id] == nil else { throw V2ResourceStorageError.conflict } }
        // An admission can reclaim other abandoned GET checkpoints, never the
        // very checkpoint this request is about to resume.
        if let existing { transientReservations[existing.id] = bytes }
        var admitted = false
        defer { if !admitted, let existing { transientReservations.removeValue(forKey: existing.id); resumeCloseWaitersIfDrained() } }
        if existing == nil && reservations.count >= 128 {
            let plan = try planCleanup()
            _ = try commitCleanup(plan)
        }
        let remainingStages = try journal.stagingReservations().count
        guard existing != nil || remainingStages < 128 else { throw V2ResourceStorageError.capacityExceeded }
        try ensureAdmission(category: nil, bytes: 0, temporaryAddition: addition, managedAddition: addition)
        let id = existing?.id ?? UUID()
        if let existing {
            if existing.publicationBytes != publication { try journal.updatePublicationReservation(id, bytes: publication) }
        } else { try journal.addStaging(id: id, identity: identity, bytes: bytes, publicationBytes: publication, location: location, now: Date()) }
        transientReservations[id] = bytes
        admitted = true
        return .init(id: id, fileURL: temporaryURL(id: id, location: location))
    }

    func releaseTransient(_ id: UUID, discard: Bool) throws {
        // A producer relinquishes its own live claim exactly once. Delayed
        // release from a closed owner must not unlink a resumed checkpoint.
        guard transientReservations[id] != nil else { return }
        defer { transientReservations.removeValue(forKey: id); resumeCloseWaitersIfDrained() }
        if discard {
            try removeTransferFiles(id)
            try journal.removeStaging(id)
        }
    }

    func makeUploadPart(from source: V2ResourceFileLease, range: V2ResourceByteRange) throws -> V2ResourceTemporaryFile {
        try prepare()
        guard source.owner === self, let fileID = leases[source.id],
              let record = try journal.record(fileID), range.upperBound < record.byteCount,
              range.byteCount <= 16 * 1_024 * 1_024 else { throw V2ResourceStorageError.invalidRecord }
        let staging = try reserveTransient(identity: "upload-part:\(UUID().uuidString)", bytes: range.byteCount, footprint: .singleFile)
        do {
            try Task.checkCancellation()
            try Data().write(to: staging.fileURL, options: .withoutOverwriting)
            try protection.apply(.complete, to: staging.fileURL)
            try V2LocalBackupExclusion.apply(to: staging.fileURL)
            let input = try FileHandle(forReadingFrom: source.fileURL)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: staging.fileURL)
            defer { try? output.close() }
            try input.seek(toOffset: UInt64(range.lowerBound))
            var remaining = range.byteCount
            while remaining > 0 {
                try Task.checkCancellation()
                guard let data = try input.read(upToCount: Int(min(65_536, remaining))), !data.isEmpty else { throw V2ResourceStorageError.integrityMismatch }
                try output.write(contentsOf: data); remaining -= Int64(data.count)
            }
            try output.synchronize()
            return .init(fileURL: staging.fileURL, id: staging.id, owner: self)
        } catch {
            try? releaseTransient(staging.id, discard: true)
            throw error
        }
    }

    func verifiedFile(id: V2LocalResourceFileID, checksum: V2ResourceChecksum, bytes: Int64) throws -> URL {
        try prepare()
        guard let row = try journal.record(id), row.state == .published, row.checksum == checksum, row.byteCount == bytes else { throw V2ResourceStorageError.unavailable }
        try verifyPublished(row)
        return fileURL(id, storage: row.storage)
    }

    func borrowVerified(id: V2LocalResourceFileID, checksum: V2ResourceChecksum, bytes: Int64) throws -> V2ResourceFileLease {
        _ = try verifiedFile(id: id, checksum: checksum, bytes: bytes)
        return try borrow(id)
    }

    func publishDownload(of source: URL, reservation: V2ResourceTransferStaging,
                         byteCount: Int64, checksum: V2ResourceChecksum) throws -> (id: V2LocalResourceFileID, lease: V2ResourceFileLease) {
        try prepare()
        guard let record = try journal.stagingReservations().first(where: { $0.id == reservation.id }),
              transientReservations[reservation.id] == byteCount,
              reservation.fileURL.path == temporaryURL(id: record.id, location: record.location).path else { throw V2ResourceStorageError.conflict }
        if case .backgroundDownload(let session, let mapping) = record.location {
            guard source.path == reservation.fileURL.path else { throw V2ResourceStorageError.conflict }
            let permit = try downloadInbox(session).permit(mapping)
            guard permit.reservationID == reservation.id, permit.expectedBytes == byteCount, permit.checksum == checksum,
                  case .received = permit.state else { throw V2ResourceStorageError.unavailable }
        }
        _ = try journal.publicationCredit(reservation.id, bytes: byteCount)
        let retained = try journal.hasRetainedBytes(checksum: checksum, byteCount: byteCount)
        let id = try publishCopy(of: .file(source), fileID: .init(), byteCount: byteCount, checksum: checksum, retention: .cache,
            storage: retained ? .persistent : .cache, publicationClass: retained ? .retained : .cache, reservation: reservation.id, now: Date())
        if retained { try journal.bindRetainedBytes(fileID: id, checksum: checksum, byteCount: byteCount) }
        // Reusing a verified blob also completes this publication handoff.
        // Its existing file row already bears the byte charge; release future
        // copy credit so cold recovery can retire the redundant raw receipt.
        try journal.updatePublicationReservation(reservation.id, bytes: 0)
        // No actor suspension between publication and the first real claim.
        return (id, try borrow(id))
    }

    func retireCachedFile(_ id: V2LocalResourceFileID) throws {
        try prepare()
        guard try journal.beginDeletion(id) else { return }
        guard !leases.values.contains(id) else { return }
        try removeAllPlacements(id)
        try journal.finishDeletion(id)
    }

    /// Waits for real consumers; cancellation signalling alone is not a drain.
    public func close() async {
        closing = true
        cleanupPlans.removeAll()
        if !leases.isEmpty || !transientReservations.isEmpty || !backgroundConsumers.isEmpty {
            await withCheckedContinuation { closeWaiters.append($0) }
        }
    }

    fileprivate func release(_ id: UUID) {
        if let alias = presentationAliases.removeValue(forKey: id) {
            do {
                try FileManager.default.removeItem(at: alias)
                let directory = alias.deletingLastPathComponent()
                if directory.deletingLastPathComponent().standardizedFileURL.path == root.appending(path: "exports").standardizedFileURL.path {
                    try FileManager.default.removeItem(at: directory)
                }
            }
            catch { recovered = false }
        }
        let file = leases.removeValue(forKey: id)
        if let file, !leases.values.contains(file) {
            do {
                if try journal.record(file)?.state == .retiring {
                    try removeAllPlacements(file); try journal.finishDeletion(file)
                } else {
                    try reconcilePlacements()
                }
            } catch { recovered = false }
        }
        resumeCloseWaitersIfDrained()
    }

    private func resumeCloseWaitersIfDrained() {
        if leases.isEmpty && transientReservations.isEmpty && backgroundConsumers.isEmpty {
            let waiters = closeWaiters; closeWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    private func ensureOriginalCapacity(reusing record: V2ResourceFileRecord) throws {
        guard record.retention != .original else { return }
        let used = try journal.quotaSnapshot(policy: policy).originalBytes
        let addition = max(record.byteCount, record.allocatedBytes)
        guard addition <= policy.maximumOriginalBytes, used <= policy.maximumOriginalBytes - addition else { throw V2ResourceStorageError.capacityExceeded }
    }

    private func ensureAdmission(category: V2ResourceFileRetention?, bytes: Int64, temporaryAddition: Int64 = 0, managedAddition: Int64? = nil) throws {
        guard bytes >= 0, bytes <= Int64.max / 8, temporaryAddition >= 0, temporaryAddition <= policy.maximumTemporaryBytes else { throw V2ResourceStorageError.capacityExceeded }
        let addition = managedAddition ?? (bytes + temporaryAddition)
        if let maximum = policy.maximumManagedBytes, addition > maximum { throw V2ResourceStorageError.capacityExceeded }
        if category == .cache, bytes > policy.maximumCacheBytes { throw V2ResourceStorageError.capacityExceeded }
        if category == .original {
            let used = try journal.quotaSnapshot(policy: policy).originalBytes
            guard bytes <= policy.maximumOriginalBytes, used <= policy.maximumOriginalBytes - bytes else { throw V2ResourceStorageError.capacityExceeded }
        }
        let cache = category == .cache ? bytes : 0
        try reclaimForAdmission(cacheAddition: cache, temporaryAddition: temporaryAddition, managedAddition: addition)
        let usage = try journal.quotaSnapshot(policy: policy)
        if category == .cache {
            guard bytes <= policy.maximumCacheBytes, usage.cacheBytes <= policy.maximumCacheBytes - bytes else { throw V2ResourceStorageError.capacityExceeded }
        }
        if category == .original {
            guard bytes <= policy.maximumOriginalBytes, usage.originalBytes <= policy.maximumOriginalBytes - bytes else { throw V2ResourceStorageError.capacityExceeded }
        }
        if temporaryAddition > 0 {
            guard usage.temporaryReservedBytes <= policy.maximumTemporaryBytes - temporaryAddition else { throw V2ResourceStorageError.capacityExceeded }
        }
        if addition > 0, let maximum = policy.maximumManagedBytes {
            guard addition <= maximum, usage.managedBytes <= maximum - addition else { throw V2ResourceStorageError.capacityExceeded }
        }
        let capacity = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        // Small mounted volumes can report zero (or nil) for the purge-aware
        // estimate despite having ordinary free blocks. Without a useful
        // estimate, fall back to those actual blocks; unknown remains zero.
        let estimate = capacity.volumeAvailableCapacityForImportantUsage ?? 0
        let free = estimate > 0 ? estimate : capacity.volumeAvailableCapacity.map(Int64.init) ?? 0
        guard free >= usage.temporaryReservedBytes + addition + policy.minimumFreeBytes else { throw V2ResourceStorageError.capacityExceeded }
    }

    /// Trim only reconstructable, unborrowed bytes. Lowering a preference may
    /// leave a visible overage until active consumers or protected work finish.
    private func reclaimForAdmission(cacheAddition: Int64, temporaryAddition: Int64, managedAddition: Int64,
                                     excluding: Set<V2LocalResourceFileID> = []) throws {
        let usage = try journal.quotaSnapshot(policy: policy)
        var cache = usage.cacheBytes, temporary = usage.temporaryReservedBytes, managed = usage.managedBytes
        for record in try journal.records() where record.retention == .cache {
            guard cacheAddition > policy.maximumCacheBytes || cache > policy.maximumCacheBytes - cacheAddition || needsManagedSpace(used: managed, addition: managedAddition) else { break }
            guard !excluding.contains(record.id), !leases.values.contains(record.id), try !journal.hasConsumers(record.id) else { continue }
            let charge = record.state == .missing ? 0 : max(record.byteCount,record.allocatedBytes)
            try retireCachedFile(record.id)
            if try journal.record(record.id) == nil { cache -= charge; managed -= charge }
        }
        for stage in try journal.stagingReservations() where stage.location == .foreground {
            guard temporaryAddition > policy.maximumTemporaryBytes || temporary > policy.maximumTemporaryBytes - temporaryAddition || needsManagedSpace(used: managed, addition: managedAddition) else { break }
            guard transientReservations[stage.id] == nil else { continue }
            try removeTransferFiles(stage.id); try journal.removeStaging(stage.id)
            temporary -= stage.reservedBytes; managed -= stage.reservedBytes
        }
    }

    private func needsManagedSpace(used: Int64, addition: Int64) -> Bool {
        guard let maximum = policy.maximumManagedBytes else { return false }
        return addition > maximum || used > maximum - addition
    }

    private func prepare() throws {
        guard !closing else { throw V2ResourceStorageError.closed }
        for directory in [root, cacheRoot, root.appendingPathComponent("files"), root.appendingPathComponent("partials"), root.appendingPathComponent("presentations"), root.appendingPathComponent("exports"),
                          cacheRoot.appendingPathComponent("files"), cacheRoot.appendingPathComponent("partials"), cacheRoot.appendingPathComponent("transfers")] {
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            let facts = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard facts.isSymbolicLink == false, facts.isDirectory == true,
                  directory.resolvingSymlinksInPath().path == directory.path else { throw V2ResourceStorageError.unsafeFile }
            try protection.apply(.complete, to: directory)
            try V2LocalBackupExclusion.apply(to: directory)
        }
        if !recovered { try recover(); recovered = true }
        try reconcilePlacements()
    }

    private func recover() throws {
        for cancelled in try journal.cancelledForegroundDownloads() {
            // Failed unlink stays explicit and retryable without preventing
            // unrelated resources in this account from opening.
            try? discardCancelledForegroundDownload(cancelled.id, identity: cancelled.identity)
        }
        // Runtime borrows do not survive a process restart. Remove only flat
        // aliases in this owner's validated directory, never follow links.
        let aliases = root.appending(path: "presentations")
        let liveAliases = Set(presentationAliases.values.map { $0.standardizedFileURL.path })
        for alias in try FileManager.default.contentsOfDirectory(at: aliases, includingPropertiesForKeys: nil) where !liveAliases.contains(alias.standardizedFileURL.path) {
            try Self.requireRegularFile(alias)
            try FileManager.default.removeItem(at: alias)
        }
        // Export names are confined to one UUID directory per lease. Never
        // recursively follow an untrusted directory or symlink during recovery.
        for directory in try FileManager.default.contentsOfDirectory(at: root.appending(path: "exports"), includingPropertiesForKeys: nil) {
            guard UUID(uuidString: directory.lastPathComponent) != nil else { throw V2ResourceStorageError.unsafeFile }
            let facts = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard facts.isDirectory == true, facts.isSymbolicLink == false,
                  directory.resolvingSymlinksInPath().standardizedFileURL.path == directory.standardizedFileURL.path else { throw V2ResourceStorageError.unsafeFile }
            var active = false
            for alias in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                try Self.requireRegularFile(alias)
                if liveAliases.contains(alias.standardizedFileURL.path) { active = true }
                else { try FileManager.default.removeItem(at: alias) }
            }
            if !active { try FileManager.default.removeItem(at: directory) }
        }
        for operation in try journal.relocations() { try recoverPlacement(operation) }
        for record in try journal.records() {
            let file = fileURL(record.id, storage: record.storage), partial = partialURL(record.id, storage: record.storage)
            switch record.state {
            case .publishing:
                // A renamed final file is recoverable; partial bytes are never
                // published even if complete, because publication did not occur.
                if FileManager.default.fileExists(atPath: file.path) {
                    do { try verifyPublished(record) }
                    catch {
                        // Isolate proven bad bytes. A temporarily locked file
                        // still fails activation and is never called corrupt.
                        guard try journal.record(record.id)?.state == .invalid else { throw error }
                        continue
                    }
                    try protection.apply(.complete, to: file)
                    try synchronizeDirectory(file.deletingLastPathComponent())
                    try journal.finishPublication(record.id, allocatedBytes: allocatedBytes(file))
                } else {
                    try removeManaged(partial)
                    try journal.discardUnpublished(record.id)
                }
            case .retiring:
                guard !leases.values.contains(record.id) else { continue }
                try removeAllPlacements(record.id)
                try journal.finishDeletion(record.id)
            case .published:
                try restoreFromPresentationAlias(record, to: file)
                if !FileManager.default.fileExists(atPath: file.path) { try journal.markMissing(record.id) }
            case .missing, .invalid: break
            }
        }
        for asset in try journal.importingAssets() {
            let candidate = try journal.record(asset.plannedFileID) ?? journal.matchingFile(checksum: asset.checksum, byteCount: asset.byteCount)
            guard let candidate, candidate.state == .published,
                  candidate.checksum == asset.checksum, candidate.byteCount == asset.byteCount else {
                try journal.markAssetUnavailable(asset.id); continue
            }
            do { try verifyPublished(candidate) }
            catch {
                guard try journal.record(candidate.id)?.state == .invalid else { throw error }
                try journal.markAssetUnavailable(asset.id); continue
            }
            try journal.finishAssetImport(asset.id, fileID: candidate.id)
        }
        for stage in try journal.stagingReservations() where stage.location == .foreground && stage.identity.hasPrefix("upload-part:") && transientReservations[stage.id] == nil {
            try removeTransferFiles(stage.id); try journal.removeStaging(stage.id)
        }
    }

    private func storageRoot(_ storage: V2ResourceFileStorage) -> URL { storage == .persistent ? root : cacheRoot }
    private func fileURL(_ id: V2LocalResourceFileID, storage: V2ResourceFileStorage) -> URL { storageRoot(storage).appendingPathComponent("files").appendingPathComponent(id.value.uuidString) }
    private func partialURL(_ id: V2LocalResourceFileID, storage: V2ResourceFileStorage) -> URL { storageRoot(storage).appendingPathComponent("partials").appendingPathComponent(id.value.uuidString) }
    private func transferURL(_ id: UUID) -> URL { cacheRoot.appendingPathComponent("transfers").appendingPathComponent(id.uuidString) }
    private func temporaryURL(id: UUID, location: V2ResourceTemporaryReservationRecord.Location) -> URL {
        switch location {
        case .foreground: transferURL(id)
        case .backgroundDownload(let session, let mapping): downloadInbox(session).fileURL(mapping)
        }
    }

    private func removeAllPlacements(_ id: V2LocalResourceFileID) throws {
        for storage in V2ResourceFileStorage.allCases { try removeManaged(fileURL(id, storage: storage)) }
    }

    private func reconcilePlacements() throws {
        for operation in try journal.relocations() { try recoverPlacement(operation) }
        for record in try journal.placementCandidates() {
            try ensurePlacement(record.id, storage: record.retention == .cache ? .cache : .persistent)
        }
    }

    private func recoverPlacement(_ operation: V2ResourceFileRelocation) throws {
        do { try finishPlacement(operation) }
        catch {
            // Proven corruption is isolated to its record. Protected bytes are
            // preserved, while a locked/unreadable filesystem still propagates.
            guard try journal.record(operation.fileID)?.state == .invalid else { throw error }
        }
    }

    private func ensurePlacement(_ id: V2LocalResourceFileID, storage: V2ResourceFileStorage) throws {
        guard let record = try journal.record(id), record.state == .published else { throw V2ResourceStorageError.unavailable }
        guard record.storage != storage else { return }
        let operation = V2ResourceFileRelocation(fileID: id, source: record.storage, target: storage)
        do {
            try journal.beginRelocation(operation)
            try finishPlacement(operation)
        } catch { recovered = false; throw error }
    }

    /// Both roots are on the app data volume. A hard link publishes the same
    /// immutable bytes without a second allocation. Existing lease URLs remain
    /// valid until all actual consumers release; restart has no runtime leases.
    private func finishPlacement(_ operation: V2ResourceFileRelocation) throws {
        guard let record = try journal.record(operation.fileID), record.state == .published else {
            try journal.finishRelocation(operation); return
        }
        let source = fileURL(operation.fileID, storage: operation.source)
        let target = fileURL(operation.fileID, storage: operation.target)
        if !FileManager.default.fileExists(atPath: target.path) {
            try restoreFromPresentationAlias(record, to: source)
        }
        let hasSource = FileManager.default.fileExists(atPath: source.path)
        let hasTarget = FileManager.default.fileExists(atPath: target.path)
        if !hasSource && !hasTarget {
            try journal.markMissing(record.id); try journal.finishRelocation(operation); return
        }
        do {
            if hasSource { try verify(source, bytes: record.byteCount, checksum: record.checksum) }
            if hasTarget {
                try verify(target, bytes: record.byteCount, checksum: record.checksum)
                if hasSource {
                    let a = try FileManager.default.attributesOfItem(atPath: source.path)
                    let b = try FileManager.default.attributesOfItem(atPath: target.path)
                    guard a[.systemNumber] as? NSNumber == b[.systemNumber] as? NSNumber,
                          a[.systemFileNumber] as? NSNumber == b[.systemFileNumber] as? NSNumber else { throw V2ResourceStorageError.unsafeFile }
                }
            } else {
                try FileManager.default.linkItem(at: source, to: target)
                try protection.apply(.complete, to: target)
                try V2LocalBackupExclusion.apply(to: target)
                try synchronizeDirectory(target.deletingLastPathComponent())
                try placementCheckpoint(.targetLinked)
            }
        } catch {
            if (error as? V2ResourceStorageError) == .integrityMismatch || (error as? V2ResourceStorageError) == .unsafeFile {
                let present = hasSource ? source : target
                let bytes = (try? allocatedBytes(present)) ?? record.allocatedBytes
                try journal.markInvalid(record.id, allocatedBytes: bytes)
                try journal.finishRelocation(operation)
            }
            throw error
        }
        try journal.commitRelocation(operation)
        try placementCheckpoint(.catalogCommitted)
        guard !leases.values.contains(record.id) else { return }
        try removeManaged(source)
        try placementCheckpoint(.sourceRemoved)
        try journal.finishRelocation(operation)
    }

    private func transferAllocatedBytes(_ id: UUID) throws -> Int64 {
        let url = transferURL(id)
        return try [url,url.appendingPathExtension("range-part"),url.appendingPathExtension("range-journal")].reduce(0) { total, file in
            guard FileManager.default.fileExists(atPath: file.path) else { return total }
            try Self.requireRegularFile(file)
            return total + (try allocatedBytes(file))
        }
    }

    private func removeTransferFiles(_ id: UUID) throws {
        if let record = try journal.stagingReservations().first(where: { $0.id == id }),
           case .backgroundDownload(let session, let mapping) = record.location {
            try downloadInbox(session).discard(mapping); return
        }
        let url = transferURL(id)
        for candidate in [url,url.appendingPathExtension("range-part"),url.appendingPathExtension("range-journal")] { try removeManaged(candidate) }
    }

    private static func requireRegularFile(_ file: URL) throws {
        guard file.isFileURL else { throw V2ResourceStorageError.unsafeFile }
        let facts = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        guard facts.isSymbolicLink == false, facts.isRegularFile == true else { throw V2ResourceStorageError.unsafeFile }
    }

    private func verify(_ file: URL, bytes: Int64, checksum: V2ResourceChecksum) throws {
        try Self.requireRegularFile(file)
        guard try V2ResourceFileDigest.sha256(fileURL: file, expectedByteCount: bytes) == checksum.value else {
            throw V2ResourceStorageError.integrityMismatch
        }
    }

    private func verifyPublished(_ record: V2ResourceFileRecord) throws {
        let file = fileURL(record.id, storage: record.storage)
        try restoreFromPresentationAlias(record, to: file)
        do { try verify(file, bytes: record.byteCount, checksum: record.checksum) }
        catch {
            let storage = error as? V2ResourceStorageError
            let cocoa = error as? CocoaError
            if storage == .integrityMismatch || storage == .unsafeFile || cocoa?.code == .fileReadNoSuchFile {
                let regular = (try? file.resourceValues(forKeys: [.isRegularFileKey,.isSymbolicLinkKey]))
                let bytes = regular?.isRegularFile == true && regular?.isSymbolicLink == false ? (try allocatedBytes(file)) : 0
                try journal.markInvalid(record.id, allocatedBytes: bytes)
            }
            throw error
        }
    }

    /// Caches can disappear while a platform consumer still owns a persistent
    /// hard link. Restore that same verified inode instead of declaring its
    /// live payload missing (and accidentally ceasing to account for it).
    private func restoreFromPresentationAlias(_ record: V2ResourceFileRecord, to file: URL) throws {
        guard !FileManager.default.fileExists(atPath: file.path),
              let alias = presentationAliases.first(where: { leases[$0.key] == record.id })?.value else { return }
        try verify(alias, bytes: record.byteCount, checksum: record.checksum)
        try FileManager.default.linkItem(at: alias, to: file)
    }

    private func allocatedBytes(_ file: URL) throws -> Int64 {
        let facts = try file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey])
        return Int64(facts.totalFileAllocatedSize ?? facts.fileAllocatedSize ?? facts.fileSize ?? 0)
    }

    private func removeManaged(_ file: URL) throws {
        let parent = file.deletingLastPathComponent()
        guard parent.resolvingSymlinksInPath().path == parent.path else { throw V2ResourceStorageError.unsafeFile }
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        try Self.requireRegularFile(file)
        try FileManager.default.removeItem(at: file)
        try synchronizeDirectory(file.deletingLastPathComponent())
    }

    private func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw V2ResourceStorageError.unavailable }
        defer { _ = closeResourceDirectoryDescriptor(descriptor) }
        guard fsync(descriptor) == 0 else { throw V2ResourceStorageError.unavailable }
    }
}

extension V2ResourceFileStore {
    private func downloadInbox(_ session: UUID) -> V2ResourceBackgroundDownloadInbox {
        .init(root: backgroundDirectory, sessionID: session, protection: protection)
    }
    func reserveBackgroundDownload(mapping: UUID, session: UUID, target: V2ClientMediaTransferTarget) throws -> V2ResourceTransferStaging {
        _ = try V2BackgroundDownloadRequest.make(target: target)
        guard let grant = target.backgroundDownloadAuthorization, let origin = V2BackgroundResultInbox.originDigest(target.url) else { throw V2BackgroundTransferError.invalidAuthorization }
        let reservation = try reserveTransient(identity: "background-download:\(mapping.uuidString)", bytes: target.expectedByteCount,
            location: .backgroundDownload(session: session, mapping: mapping))
        do { try downloadInbox(session).prepare(reservation: reservation.id, mapping: mapping, grant: grant, origin: origin) }
        catch { try? releaseTransient(reservation.id, discard: true); throw error }
        return reservation
    }
    func installBackgroundDownload(_ reservation: V2ResourceTransferStaging, task: V2BackgroundDownloadTask) throws {
        try prepare()
        guard transientReservations[reservation.id] == task.expectedByteCount else { throw V2ResourceStorageError.conflict }
        let permit = try downloadInbox(task.sessionID).permit(task.id)
        guard permit.reservationID == reservation.id, permit.grant.id == task.grantID,
              permit.expectedBytes == task.expectedByteCount, permit.checksum == task.checksum,
              permit.originDigest == task.originDigest, permit.expiresAtMilliseconds == task.expiresAtMilliseconds else { throw V2BackgroundTransferError.mappingConflict }
        try downloadInbox(task.sessionID).install(mapping: task.id, identifier: task.identifier)
    }
    func adoptBackgroundDownload(_ task: V2BackgroundDownloadTask, suspended: Bool = false) throws -> V2ResourceTransferStaging {
        try prepare()
        guard let row = try journal.stagingReservations().first(where: { $0.location == .backgroundDownload(session: task.sessionID, mapping: task.id) }),
              row.bytes == task.expectedByteCount else { throw V2ResourceStorageError.unavailable }
        let permit = try downloadInbox(task.sessionID).permit(task.id)
        guard permit.reservationID == row.id, permit.grant.id == task.grantID, permit.expectedBytes == row.bytes,
              permit.checksum == task.checksum, permit.originDigest == task.originDigest,
              permit.expiresAtMilliseconds == task.expiresAtMilliseconds,
              permit.state.identifier == task.identifier || (permit.state == .prepared && suspended) else { throw V2BackgroundTransferError.mappingConflict }
        let reservation: V2ResourceTransferStaging
        if transientReservations[row.id] == row.bytes {
            reservation = .init(id: row.id, fileURL: temporaryURL(id: row.id, location: row.location))
        } else {
            reservation = try reserveTransient(identity: row.identity, bytes: row.bytes, location: row.location)
        }
        if permit.state == .prepared { try downloadInbox(task.sessionID).install(mapping: task.id, identifier: task.identifier) }
        return reservation
    }
    func rearmBackgroundDownload(_ task: V2BackgroundDownloadTask, reservation: V2ResourceTransferStaging) throws {
        try prepare()
        guard transientReservations[reservation.id] == task.expectedByteCount,
              let row = try journal.stagingReservations().first(where: { $0.id == reservation.id }),
              row.location == .backgroundDownload(session: task.sessionID, mapping: task.id) else { throw V2ResourceStorageError.conflict }
        let addition = row.bytes - row.publicationBytes
        guard addition > 0 else { return }
        // Preserve the live raw-source claim throughout retry admission. A
        // failed copy must not expose the OS receipt to a cleanup race.
        try ensureAdmission(category: nil, bytes: 0, temporaryAddition: addition, managedAddition: addition)
        try journal.updatePublicationReservation(row.id, bytes: row.bytes)
    }

    func verifyBackgroundDownload(_ task: V2BackgroundDownloadTask, reservation: V2ResourceTransferStaging) throws {
        try prepare()
        guard transientReservations[reservation.id] == task.expectedByteCount else { throw V2ResourceStorageError.unavailable }
        let permit = try downloadInbox(task.sessionID).permit(task.id)
        guard permit.reservationID == reservation.id, permit.state == .received(task.identifier), permit.checksum == task.checksum else { throw V2ResourceStorageError.unavailable }
        let file = downloadInbox(task.sessionID).fileURL(task.id)
        guard file.path == reservation.fileURL.path else { throw V2ResourceStorageError.conflict }
        guard file.deletingLastPathComponent().resolvingSymlinksInPath().path == file.deletingLastPathComponent().standardizedFileURL.path else { throw V2ResourceStorageError.unsafeFile }
        try verify(file, bytes: task.expectedByteCount, checksum: task.checksum)
    }
    func backgroundDownloadWasPublished(_ task: V2BackgroundDownloadTask) throws -> Bool {
        try prepare()
        guard let row = try journal.stagingReservations().first(where: { $0.location == .backgroundDownload(session: task.sessionID, mapping: task.id) }),
              row.publicationBytes == 0, let file = try journal.matchingFile(checksum: task.checksum, byteCount: task.expectedByteCount) else { return false }
        try verifyPublished(file)
        return true
    }
    /// The native owner calls only after the mapped OS writer has drained.
    /// A cold coordinator may not have adopted the previous reservation into
    /// its runtime map; cleanup must still retire that exact scoped source.
    func discardBackgroundDownload(mapping: UUID, session: UUID) throws {
        try prepare()
        if let row = try journal.stagingReservations().first(where: { $0.location == .backgroundDownload(session: session, mapping: mapping) }) {
            if transientReservations[row.id] != nil { try releaseTransient(row.id, discard: true) }
            else { try removeTransferFiles(row.id); try journal.removeStaging(row.id) }
        }
        try downloadInbox(session).discard(mapping)
    }

    func reconcileBackgroundDownloads(session: UUID, retained: Set<UUID>) throws {
        try prepare()
        for row in try journal.stagingReservations() {
            guard case .backgroundDownload(let owner, let mapping) = row.location, owner == session,
                  !retained.contains(mapping), transientReservations[row.id] == nil else { continue }
            try removeTransferFiles(row.id); try journal.removeStaging(row.id)
        }
        let known = Set(try journal.stagingReservations().compactMap { row -> UUID? in
            guard case .backgroundDownload(let owner, let mapping) = row.location, owner == session else { return nil }; return mapping
        })
        for permit in try downloadInbox(session).permits() where !known.contains(permit.mappingID) && !retained.contains(permit.mappingID) {
            try downloadInbox(session).discard(permit.mappingID)
        }
    }

    /// Only a live original lease can mint an AFU part. The coordinator owns
    /// the supplied id even on failure and releases it after actual task drain.
    func makeBackgroundUploadSource(from source: V2ResourceFileLease, sessionID: UUID, id: UUID,
                                    range: V2ResourceByteRange) throws -> URL {
        try makeBackgroundUploadSource(from: source, sessionID: sessionID, id: id, extent: .part(range))
    }

    func makeBackgroundWholeUploadSource(from source: V2ResourceFileLease, sessionID: UUID, id: UUID) throws -> URL {
        try makeBackgroundUploadSource(from: source, sessionID: sessionID, id: id, extent: .whole)
    }

    private enum BackgroundUploadExtent { case part(V2ResourceByteRange), whole }
    private func makeBackgroundUploadSource(from source: V2ResourceFileLease, sessionID: UUID, id: UUID,
                                            extent: BackgroundUploadExtent) throws -> URL {
        try prepare(); try Task.checkCancellation()
        guard source.owner === self, let original = leases[source.id], let record = try journal.record(original),
              record.state == .published else {
            throw V2ResourceStorageError.invalidRecord
        }
        let range: V2ResourceByteRange
        switch extent {
        case .part(let part):
            guard part.upperBound < record.byteCount, part.byteCount <= 8 * 1_024 * 1_024 else { throw V2ResourceStorageError.invalidRecord }
            range = part
        case .whole:
            guard record.byteCount > 0, record.byteCount <= 256 * 1_024 * 1_024 else { throw V2ResourceStorageError.invalidRecord }
            range = try .init(lowerBound: 0, upperBound: record.byteCount - 1)
        }
        try ensureAdmission(category: nil, bytes: 0, temporaryAddition: range.byteCount * 2)
        try journal.beginBackgroundSource(id: id, session: sessionID, bytes: range.byteCount)
        backgroundConsumers[id] = sessionID
        try backgroundSourceCheckpoint(.reserved)
        let destination = backgroundURL(id: id, session: sessionID), partial = destination.appendingPathExtension("partial")
        try prepareBackgroundDirectories(session: sessionID)
        try Data().write(to: partial, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: partial.path)
        try protection.apply(.untilFirstAuthentication, to: partial)
        try V2LocalBackupExclusion.apply(to: partial)
        let input = try FileHandle(forReadingFrom: source.fileURL), output = try FileHandle(forWritingTo: partial)
        defer { try? input.close(); try? output.close() }
        try input.seek(toOffset: UInt64(range.lowerBound))
        var remaining = range.byteCount
        while remaining > 0 {
            try Task.checkCancellation()
            guard let bytes = try input.read(upToCount: Int(min(remaining, 65_536))), !bytes.isEmpty else { throw V2ResourceStorageError.integrityMismatch }
            try output.write(contentsOf: bytes); remaining -= Int64(bytes.count)
        }
        try output.synchronize()
        let checksum = try V2ResourceChecksum(value: V2ResourceFileDigest.sha256(fileURL: partial, expectedByteCount: range.byteCount))
        try backgroundSourceCheckpoint(.partialWritten)
        try FileManager.default.moveItem(at: partial, to: destination)
        try protection.apply(.untilFirstAuthentication, to: destination)
        try V2LocalBackupExclusion.apply(to: destination)
        try synchronizeDirectory(destination.deletingLastPathComponent())
        try backgroundSourceCheckpoint(.renamed)
        try journal.finishBackgroundSource(id: id, checksum: checksum, allocatedBytes: allocatedBytes(destination))
        try backgroundSourceCheckpoint(.ready)
        return destination
    }

    func adoptBackgroundUploadSource(id: UUID, sessionID: UUID) throws {
        try prepare(); try Task.checkCancellation()
        if backgroundConsumers[id] == sessionID { return }
        guard let record = try journal.backgroundSources().first(where: { $0.id == id && $0.sessionID == sessionID }),
              record.state == .ready, let checksum = record.checksum else { throw V2ResourceStorageError.unavailable }
        guard backgroundURL(record).deletingLastPathComponent().resolvingSymlinksInPath().path == backgroundURL(record).deletingLastPathComponent().path else { throw V2ResourceStorageError.unsafeFile }
        try verify(backgroundURL(record), bytes: record.bytes, checksum: checksum)
        backgroundConsumers[id] = sessionID
    }

    /// Caller has observed actual system completion or cancelAndDrain. Even if
    /// Complete-protected SQL is locked, relinquish the runtime claim; the row
    /// and AFU file remain conservative durable debt until unlock/reconcile.
    func releaseBackgroundUploadSource(id: UUID, sessionID: UUID) throws {
        guard backgroundConsumers[id] == sessionID else { return }
        defer { backgroundConsumers.removeValue(forKey: id); resumeCloseWaitersIfDrained() }
        guard let record = try journal.backgroundSources().first(where: { $0.id == id && $0.sessionID == sessionID }) else { return }
        try removeBackgroundSource(record)
    }

    /// A session owner invokes this only after adopting/draining its actual OS
    /// tasks. Ordinary cache cleanup never makes this authority decision.
    func reconcileBackgroundUploadSources(sessionID: UUID, retained: Set<UUID>) throws -> Bool {
        try prepare()
        for record in try journal.backgroundSources() where record.sessionID == sessionID && !retained.contains(record.id) && backgroundConsumers[record.id] == nil {
            try removeBackgroundSource(record)
        }
        let directory = backgroundDirectory.appending(path: sessionID.uuidString).appending(path: "sources")
        guard FileManager.default.fileExists(atPath: directory.path) else { return false }
        guard directory.resolvingSymlinksInPath().path == directory.path,
              let iterator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey,.isSymbolicLinkKey],
                  options: [.skipsSubdirectoryDescendants]) else { throw V2ResourceStorageError.unsafeFile }
        let known = Set(try journal.backgroundSources().filter { $0.sessionID == sessionID }.map(\.id))
        var scanned = 0, removed = 0
        for case let file as URL in iterator {
            try Task.checkCancellation()
            if scanned == 256 {
                guard removed > 0 else { throw V2ResourceStorageError.capacityExceeded }
                return true
            }
            scanned += 1
            let name = file.pathExtension == "partial" ? file.deletingPathExtension().lastPathComponent : file.lastPathComponent
            guard let id = UUID(uuidString: name), !known.contains(id), !retained.contains(id), backgroundConsumers[id] == nil else { continue }
            try removeManaged(file); removed += 1
            if removed == 128 { return true }
        }
        return false
    }

    private func backgroundURL(id: UUID, session: UUID) -> URL {
        backgroundDirectory.appending(path: session.uuidString).appending(path: "sources").appending(path: id.uuidString)
    }
    private func backgroundURL(_ record: V2ResourceBackgroundSourceRecord) -> URL { backgroundURL(id: record.id, session: record.sessionID) }
    private func prepareBackgroundDirectories(session: UUID) throws {
        let folder = backgroundDirectory.appending(path: session.uuidString).appending(path: "sources")
        for directory in [backgroundDirectory, folder.deletingLastPathComponent(), folder] {
            guard directory.deletingLastPathComponent().resolvingSymlinksInPath().path == directory.deletingLastPathComponent().path else { throw V2ResourceStorageError.unsafeFile }
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            let facts = try directory.resourceValues(forKeys: [.isDirectoryKey,.isSymbolicLinkKey])
            guard facts.isDirectory == true && facts.isSymbolicLink == false else { throw V2ResourceStorageError.unsafeFile }
            try protection.apply(.untilFirstAuthentication, to: directory)
            try V2LocalBackupExclusion.apply(to: directory)
        }
    }
    private func removeBackgroundSource(_ record: V2ResourceBackgroundSourceRecord) throws {
        try journal.deleteBackgroundSource(record.id, finished: false)
        for file in [backgroundURL(record), backgroundURL(record).appendingPathExtension("partial")] { try removeManaged(file) }
        try journal.deleteBackgroundSource(record.id, finished: true)
    }
}

// Avoid resolving close() to the actor lifecycle method inside the type.
private func closeResourceDirectoryDescriptor(_ descriptor: Int32) -> Int32 {
    #if canImport(Darwin)
    Darwin.close(descriptor)
    #else
    Glibc.close(descriptor)
    #endif
}
