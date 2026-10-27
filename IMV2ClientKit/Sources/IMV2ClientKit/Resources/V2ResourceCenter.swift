import Foundation
import IMV2Core

public struct V2ResourceDirectoryQuery: Equatable, Sendable {
    public let roomID: RoomID?
    public let kind: V2MediaPresentation.Kind?
    public let category: V2ResourceCategory
    public let search: String
    public let retainedOnly: Bool
    public let before: V2ResourceDirectoryCursor?
    public let limit: Int

    public init(roomID: RoomID? = nil, kind: V2MediaPresentation.Kind? = nil, category: V2ResourceCategory = .all, search: String = "",
                retainedOnly: Bool = false, before: V2ResourceDirectoryCursor? = nil, limit: Int = 50) throws {
        guard (1...100).contains(limit), search.utf8.count <= 255 else { throw V2ResourceStorageError.invalidRecord }
        self.roomID = roomID; self.kind = kind; self.category = category; self.search = search; self.before = before; self.limit = limit
        self.retainedOnly = retainedOnly
    }
}

public enum V2ResourceDirectorySnapshot: Equatable, Sendable {
    case available(V2ResourceDirectoryPage)
    case unavailable(previous: V2ResourceDirectoryPage?)
}

/// One coordinator per account incarnation. Streams carry only immutable
/// directory values; transfer executors remain the owners of job transitions.
public actor V2ResourceCenter {
    private struct OwnerSubscription {
        let query: V2ResourceBusinessOwnerQuery
        let continuation: AsyncStream<V2ResourceBusinessOwnerSnapshot>.Continuation
        var previous: V2ResourceBusinessOwnerSnapshot?
        var readGeneration: UInt64 = 0
    }
    private struct TransferSubscription {
        let query: V2ResourceTransferQuery
        let continuation: AsyncStream<V2ResourceTransferSnapshot>.Continuation
        var base: V2ResourceTransferSnapshot?
        var previous: V2ResourceTransferSnapshot?
        var readGeneration: UInt64 = 0
    }
    private struct Subscription {
        let query: V2ResourceDirectoryQuery
        let continuation: AsyncStream<V2ResourceDirectorySnapshot>.Continuation
        var previous: V2ResourceDirectorySnapshot?
        var readGeneration: UInt64 = 0
    }
    public let scope: V2AccountStorageScope
    let files: V2ResourceFileStore
    private let store: GRDBV2LocalSyncStore
    private var subscriptions: [UUID: Subscription] = [:]
    private var transferSubscriptions: [UUID: TransferSubscription] = [:]
    private var ownerSubscriptions: [UUID: OwnerSubscription] = [:]
    private var observation: Task<Void, Never>?
    private let progress = V2ResourceTransferProgressHub()
    private var progressObservation: Task<Void, Never>?
    private var nativeProgressPolling: Task<Void, Never>?
    private var nativeSamples: [V2ManagedResourceTransferID: V2ResourceTransferAttemptProgress] = [:]
    private var nativeSampleGeneration: UInt64 = 0
    private var closed = false
    private let operations = V2ResourceOperationScope(limit: 4)
    private var downloads: V2ResourceDownloadCache?
    private var backgroundDownloads: V2BackgroundDownloadCoordinator?
    private var uploads: V2ResourceTransferEngine?
    private var preparationCancellations: [UUID: V2SharedOperation<Void>] = [:]
    private var uploadPauses: [UUID: V2SharedOperation<Void>] = [:]
    private var closing: Task<Void, Never>?
    private let commandOwner = UUID()

    private init(scope: V2AccountStorageScope, store: GRDBV2LocalSyncStore, files: V2ResourceFileStore) {
        self.scope = scope; self.store = store; self.files = files
    }

    public static func make(scope: V2AccountStorageScope, store: GRDBV2LocalSyncStore,
                            policy: V2ResourceStoragePolicy = .standard,
                            protection: any V2ResourceFileProtectionWriting = V2SystemResourceFileProtectionWriter()) async throws -> V2ResourceCenter {
        let journal = await store.resourceFileJournal()
        let files = try V2ResourceFileStore(scope: scope, journal: journal, policy: policy, protection: protection)
        // The previous account process cannot still own foreground I/O. Show
        // interrupted intent immediately, even before any new download starts.
        try journal.recoverForegroundDownloads(owner: UUID())
        try journal.recoverBackgroundResumeOwners(owner: UUID())
        try await files.reconcileFiles()
        try await store.pruneResourceTransferHistory()
        let center = V2ResourceCenter(scope: scope, store: store, files: files)
        await center.start()
        return center
    }

    public func snapshots(for query: V2ResourceDirectoryQuery) async throws -> AsyncStream<V2ResourceDirectorySnapshot> {
        guard !closed else { throw V2ResourceStorageError.closed }
        guard subscriptions.count + transferSubscriptions.count + ownerSubscriptions.count < 16 else { throw V2ResourceStorageError.capacityExceeded }
        let id = UUID()
        let (stream, continuation) = AsyncStream<V2ResourceDirectorySnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.onTermination = { [weak self] _ in Task { await self?.remove(id) } }
        subscriptions[id] = .init(query: query, continuation: continuation)
        await refresh(id)
        return stream
    }

    public func close() async {
        if let closing { await closing.value; return }
        let work = Task { await self.performClose() }
        closing = work
        await work.value
    }

    private func performClose() async {
        if !closed {
            closed = true
            for subscription in subscriptions.values { subscription.continuation.finish() }
            subscriptions.removeAll()
            for subscription in transferSubscriptions.values { subscription.continuation.finish() }
            transferSubscriptions.removeAll()
            for subscription in ownerSubscriptions.values { subscription.continuation.finish() }
            ownerSubscriptions.removeAll()
            observation?.cancel()
            progress.close()
            progressObservation?.cancel()
            nativeProgressPolling?.cancel()
        }
        let cancellations = Array(preparationCancellations.values) + Array(uploadPauses.values)
        for work in cancellations { work.cancel() }
        let engine = uploads; uploads = nil
        await engine?.close()
        await operations.close()
        for work in cancellations { _ = await work.result }
        let task = observation
        await task?.value
        observation = nil
        await progressObservation?.value
        progressObservation = nil
        await nativeProgressPolling?.value
        nativeProgressPolling = nil
        await downloads?.close()
        await backgroundDownloads?.close()
        await files.close()
    }

    public func transferSnapshots(for query: V2ResourceTransferQuery) async throws -> AsyncStream<V2ResourceTransferSnapshot> {
        guard !closed else { throw V2ResourceStorageError.closed }
        try await operations.run { try await self.store.pruneResourceTransferHistory() }
        guard !closed else { throw V2ResourceStorageError.closed }
        guard subscriptions.count + transferSubscriptions.count + ownerSubscriptions.count < 16 else { throw V2ResourceStorageError.capacityExceeded }
        let id = UUID()
        let (stream, continuation) = AsyncStream<V2ResourceTransferSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.onTermination = { [weak self] _ in Task { await self?.removeTransferSubscription(id) } }
        transferSubscriptions[id] = .init(query: query, continuation: continuation)
        startNativeProgressPolling()
        await refreshTransfer(id)
        return stream
    }

    func beginUploadProgress(job: UUID, expectedBytes: Int64) throws -> V2ResourceTransferProgressReporter {
        guard !closed else { throw V2ResourceStorageError.closed }
        return try progress.begin(transfer: .upload(job), expectedBytes: expectedBytes)
    }
    /// Installs read-only scheduling observations, never another task owner.
    public func observingTransfer<T: Sendable>(_ transfer: V2ManagedResourceTransferID,
        operation: @escaping @Sendable () async throws -> T) async throws -> T {
        guard !closed else { throw V2ResourceStorageError.closed }
        return try await V2ResourceTransferWaitScope.$context.withValue(.init(transfer: transfer, hub: progress), operation: operation)
    }

    public func retryTransfer(_ id: V2ManagedResourceTransferID) async throws {
        guard !closed else { throw V2ResourceStorageError.closed }
        try await operations.run { try await self.store.retryManagedResourceTransfer(id) }
    }
    public func enqueueDownload(_ key: V2ResourceKey, source: V2ResourceMessageSource) async throws -> V2ManagedResourceTransferID {
        try Task.checkCancellation()
        guard !closed else { throw V2ResourceStorageError.closed }
        return try await operations.run {
            let id = try await self.store.resourceFileJournal().enqueueManualDownload(key, source: source)
            return .download(id)
        }
    }
    public func prepareMessageDownload(mediaID: MediaID, message: V2MediaMessageLocation) async throws -> V2ResourceReadPreparation {
        try Task.checkCancellation()
        guard !closed else { throw V2ResourceStorageError.closed }
        return try await operations.run {
            let journal = await self.store.resourceFileJournal()
            try journal.requireMessageAccess(message, mediaID: mediaID)
            let key = V2ResourceKey(home: .room(message.roomID), mediaID: mediaID)
            let source = try await self.store.resourceMessageSource(key, location: message)
            let original = try await self.files.variantSnapshots(for: key).first(where: { $0.descriptor.key.rendition == .original })
            if let original {
                if try await self.files.hasPublishedBytes(checksum: original.descriptor.checksum, bytes: original.descriptor.byteCount) { return .local }
            }
            let job: UUID
            if let source, original != nil { job = try journal.enqueueManualDownload(key, source: source) }
            else { job = try journal.enqueueUnresolvedDownload(mediaID: mediaID, message: message) }
            return .queued(.download(job))
        }
    }
    public func businessOwnerSnapshots(for query: V2ResourceBusinessOwnerQuery) async throws -> AsyncStream<V2ResourceBusinessOwnerSnapshot> {
        guard !closed else { throw V2ResourceStorageError.closed }
        guard subscriptions.count + transferSubscriptions.count + ownerSubscriptions.count < 16 else { throw V2ResourceStorageError.capacityExceeded }
        let id = UUID(), pair = AsyncStream<V2ResourceBusinessOwnerSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.removeOwnerSubscription(id) } }
        ownerSubscriptions[id] = .init(query: query, continuation: pair.continuation)
        await refreshOwner(id)
        return pair.stream
    }
    public func containsBusinessOwner(_ owner: V2ResourceBusinessOwner, transfer: V2ManagedResourceTransferID) async throws -> Bool {
        guard !closed else { throw V2ResourceStorageError.closed }
        return try await operations.run { try await self.store.resourceHasBusinessOwner(owner, transfer: transfer) }
    }
    public func planProfileDisposition(transfer: V2ManagedResourceTransferID, intentID: UUID) async throws -> V2ResourceProfileDispositionPlan {
        guard !closed else { throw V2ResourceStorageError.closed }
        return try await operations.run {
            let intent = try await self.store.profileResourceDisposition(transfer: transfer, intentID: intentID)
            return .init(id: UUID(), transfer: transfer, incarnation: self.scope.incarnation, owner: self.commandOwner, intent: intent)
        }
    }
    public func commitProfileDisposition(_ plan: V2ResourceProfileDispositionPlan) async throws {
        try Task.checkCancellation()
        guard !closed else { throw V2ResourceStorageError.closed }
        guard plan.incarnation == scope.incarnation, plan.owner == commandOwner else { throw V2AccountStorageError.scopeMismatch }
        let work: V2SharedOperation<Void>
        if let existing = preparationCancellations[plan.id] { work = existing }
        else {
            guard preparationCancellations.count < 4 else { throw V2ResourceOperationScopeError.busy }
            work = V2SharedOperation { try await self.performProfileDisposition(plan) }
            preparationCancellations[plan.id] = work
        }
        try await work.value
    }
    private func performProfileDisposition(_ plan: V2ResourceProfileDispositionPlan) async throws {
        defer { preparationCancellations[plan.id] = nil }
        try await operations.run {
            if let id = try await self.store.commitResourceProfileDisposition(plan), let engine = await self.uploads {
                try await engine.drainRequestedCancellation(id: id)
            }
        }
    }
    public func retryCancellation(_ id: V2ManagedResourceTransferID) async throws {
        guard !closed else { throw V2ResourceStorageError.closed }
        try await operations.run { try await self.store.retryManagedResourceCancellation(id) }
    }
    public func downloadNetworkPreferences() async throws -> V2ResourceDownloadNetworkPreferences {
        guard !closed else { throw V2ResourceStorageError.closed }
        return try await operations.run {
            try await self.store.resourceFileJournal().downloadNetworkPreferences()
        }
    }
    public func setDownloadNetworkPreferences(_ value: V2ResourceDownloadNetworkPreferences) async throws {
        guard !closed else { throw V2ResourceStorageError.closed }
        try await operations.run {
            try await self.store.resourceFileJournal().setDownloadNetworkPreferences(value)
        }
    }
    public func cancelTransfer(_ id: V2ManagedResourceTransferID) async throws {
        guard !closed else { throw V2ResourceStorageError.closed }
        guard case .download(let job) = id else { throw V2ResourceTransferManagementError.actionUnavailable }
        try await operations.run { try await self.performDownloadCancellation(job) }
    }

    public func attachUploads(_ engine: V2ResourceTransferEngine) async throws {
        guard !closed else { throw V2ResourceStorageError.closed }
        try await engine.requireAttachment(resources: self, store: store)
        guard !closed else { throw V2ResourceStorageError.closed }
        guard uploads == nil || uploads === engine else { throw V2ResourceStorageError.conflict }
        uploads = engine
    }

    public func planPreparationCancellation(_ transfer: V2ManagedResourceTransferID) async throws -> V2ResourcePreparationCancellationPlan {
        guard !closed else { throw V2ResourceStorageError.closed }
        return try await operations.run {
            guard let intents = try await self.store.preparationCancellationParents(transfer) else { throw V2ResourceTransferManagementError.actionUnavailable }
            return .init(id: UUID(), transfer: transfer, incarnation: self.scope.incarnation, owner: self.commandOwner, intents: intents)
        }
    }
    public func planUnboundCancellation(_ transfer: V2ManagedResourceTransferID) async throws -> V2ResourceUnboundCancellationPlan {
        guard !closed else { throw V2ResourceStorageError.closed }
        return try await operations.run {
            guard let identity = try await self.store.unboundResourceIdentity(transfer) else { throw V2ResourceTransferManagementError.actionUnavailable }
            return .init(id: UUID(), transfer: transfer, incarnation: self.scope.incarnation, owner: self.commandOwner, identity: identity)
        }
    }
    public func cancelUnbound(_ plan: V2ResourceUnboundCancellationPlan) async throws {
        try Task.checkCancellation()
        guard !closed else { throw V2ResourceStorageError.closed }
        guard plan.incarnation == scope.incarnation, plan.owner == commandOwner else { throw V2AccountStorageError.scopeMismatch }
        let work: V2SharedOperation<Void>
        if let existing = preparationCancellations[plan.id] { work = existing }
        else {
            guard preparationCancellations.count < 4 else { throw V2ResourceOperationScopeError.busy }
            work = V2SharedOperation { try await self.performUnboundCancellation(plan) }
            preparationCancellations[plan.id] = work
        }
        try await work.value
    }
    private func performUnboundCancellation(_ plan: V2ResourceUnboundCancellationPlan) async throws {
        defer { preparationCancellations[plan.id] = nil }
        try await operations.run {
            if let id = try await self.store.cancelUnboundResource(plan), let engine = await self.uploads {
                try await engine.drainRequestedCancellation(id: id)
            }
        }
    }

    /// The account owns this command after confirmation. A disappearing page
    /// detaches its waiter, while the committed withdrawal and I/O drain finish.
    public func cancelPreparation(_ plan: V2ResourcePreparationCancellationPlan) async throws {
        try Task.checkCancellation()
        guard !closed else { throw V2ResourceStorageError.closed }
        guard plan.incarnation == scope.incarnation, plan.owner == commandOwner else { throw V2AccountStorageError.scopeMismatch }
        let work: V2SharedOperation<Void>
        if let existing = preparationCancellations[plan.id] { work = existing }
        else {
            guard preparationCancellations.count < 4 else { throw V2ResourceOperationScopeError.busy }
            work = V2SharedOperation { try await self.performPreparationCancellation(plan) }
            preparationCancellations[plan.id] = work
        }
        try await work.value
    }

    private func performPreparationCancellation(_ plan: V2ResourcePreparationCancellationPlan) async throws {
        defer { preparationCancellations[plan.id] = nil }
        try await operations.run {
            let ids = try await self.store.cancelResourcePreparation(plan)
            for id in ids {
                try Task.checkCancellation()
                if let engine = await self.uploads { try await engine.drainRequestedCancellation(id: id) }
            }
        }
    }
    private func performDownloadCancellation(_ job: UUID) async throws {
        guard !closed else { throw V2ResourceStorageError.closed }
        let journal = await store.resourceFileJournal()
        if try journal.downloadIsBackground(job) {
            if let backgroundDownloads { try await backgroundDownloads.requestCancellation(jobID: job) }
            else {
                // Native initialization will reconcile this durable command
                // when the account transport is attached after local startup.
                try await store.requestBackgroundDownloadCancellation(id: job, accountID: scope.accountID)
            }
            await downloads?.cancelBackgroundResumption(job)
        }
        else if let downloads { try await downloads.controlForegroundDownload(job, control: .cancel) }
        else { try await files.cancelForegroundDownload(job) }
    }
    public func pauseTransfer(_ id: V2ManagedResourceTransferID) async throws {
        try Task.checkCancellation()
        guard !closed else { throw V2ResourceStorageError.closed }
        if case .serverImport(let job) = id {
            try await operations.run { try await self.store.requestManagedImportPause(job) }
            return
        }
        if case .upload(let job) = id {
            let work: V2SharedOperation<Void>
            if let existing = uploadPauses[job] { work = existing }
            else {
                guard uploadPauses.count < 4 else { throw V2ResourceOperationScopeError.busy }
                work = V2SharedOperation { try await self.performUploadPause(job) }
                uploadPauses[job] = work
            }
            try await work.value
            return
        }
        guard case .download(let job) = id else { throw V2ResourceTransferManagementError.actionUnavailable }
        try await operations.run {
            let journal = await self.store.resourceFileJournal()
            if try journal.downloadIsBackground(job) {
                if let coordinator = await self.backgroundDownloads { try await coordinator.requestPause(jobID: job) }
                else { try await self.store.requestBackgroundDownloadPause(id: job, accountID: self.scope.accountID) }
            } else if let cache = await self.downloads { try await cache.controlForegroundDownload(job, control: .pause) }
            else { _ = try journal.requestForegroundDownloadControl(job, control: .pause, liveOwner: nil) }
        }
    }
    private func performUploadPause(_ job: UUID) async throws {
        defer { uploadPauses[job] = nil }
        try await operations.run {
            try await self.store.requestManagedUploadPause(job)
            if let engine = await self.uploads { try await engine.drainRequestedPause(id: job) }
        }
    }
    public func resumeTransfer(_ id: V2ManagedResourceTransferID) async throws {
        guard !closed else { throw V2ResourceStorageError.closed }
        try await operations.run { try await self.store.resumeManagedResourceTransfer(id) }
    }

    /// The account runtime supplies its authenticated network leaf once. File
    /// ownership remains here for cache, avatars, staging and management UI.
    public func downloadCache(using network: V2ClientMediaDownloadService, automaticNetwork: V2ResourceAutomaticNetworkSource = .system, recoveryNow: @escaping @Sendable () -> Date = Date.init) async throws -> V2ResourceDownloadCache {
        guard !closed else { throw V2ResourceStorageError.closed }
        if let downloads { return downloads }
        let journal = await store.resourceFileJournal()
        guard !closed else { throw V2ResourceStorageError.closed }
        if let downloads { return downloads }
        let cache = try V2ResourceDownloadCache(files: files, journal: journal, network: network, progress: progress, background: backgroundDownloads, automaticNetwork: automaticNetwork, recoveryNow: recoveryNow)
        downloads = cache
        return cache
    }

    public func attachBackgroundDownloads(_ coordinator: V2BackgroundDownloadCoordinator) async throws {
        guard !closed else { throw V2ResourceStorageError.closed }
        try await coordinator.requireAttachment(accountID: scope.accountID, files: files)
        guard !closed else { throw V2ResourceStorageError.closed }
        guard backgroundDownloads == nil || backgroundDownloads === coordinator else { throw V2ResourceStorageError.conflict }
        backgroundDownloads = coordinator
        await downloads?.attachBackgroundDownloads(coordinator)
        guard !closed else { await coordinator.close(); throw V2ResourceStorageError.closed }
    }

    public func containsSource(_ source: V2ResourceMessageSource, for key: V2ResourceKey) async throws -> Bool {
        guard !closed else { throw V2ResourceStorageError.closed }
        return try await operations.run {
            let visible = try await self.store.resourceContainsSource(key, source: source)
            guard await !self.closed else { throw V2ResourceStorageError.closed }
            return visible
        }
    }

    public func details(for key: V2ResourceKey, beforeSources: V2ResourceSourceCursor? = nil) async throws -> V2ResourceDetailSnapshot? {
        guard !closed else { throw V2ResourceStorageError.closed }
        return try await operations.run {
            let journal = await self.store.resourceFileJournal()
            let generation = try journal.currentAccessGeneration()
            guard try await self.store.resourceIsVisible(key) else { return nil }
            let variants = try await self.files.variantSnapshots(for: key)
            let metadata = try await self.store.resourceDetailMetadata(key, before: beforeSources)
            guard generation == (try journal.currentAccessGeneration()), let metadata else { return nil }
            return .init(descriptor: metadata.descriptor, sources: metadata.sources,
                nextSourceCursor: metadata.nextSourceCursor, variants: variants)
        }
    }

    public func storageSnapshot(reconcile: Bool = false) async throws -> V2ResourceStorageSnapshot {
        guard !closed else { throw V2ResourceStorageError.closed }
        if reconcile {
            return try await operations.run {
                try await self.files.reconcileFiles()
                return try await self.files.snapshot()
            }
        }
        return try await files.snapshot()
    }

    /// Creating/reconnecting a native session is account work too. Close drains
    /// setup and its cancelled result before retiring the scoped directories.
    func withBackgroundSetup<Result: Sendable>(
        onCancelledValue: @escaping @Sendable (Result) async -> Void,
        _ operation: @escaping @Sendable (V2ResourceFileStore, V2AccountStorageScope) async throws -> Result
    ) async throws -> Result {
        guard !closed else { throw V2ResourceStorageError.closed }
        return try await operations.run(onCancelledValue: onCancelledValue) {
            try await operation(self.files, self.scope)
        }
    }

    public func setStoragePolicy(_ policy: V2ResourceStoragePolicy) async throws -> V2ResourceQuotaSnapshot {
        guard !closed else { throw V2ResourceStorageError.closed }
        return try await operations.run { try await self.files.setStoragePolicy(policy) }
    }

    public func planCleanup(fileIDs: [V2LocalResourceFileID]? = nil) async throws -> V2ResourceCleanupPlan {
        guard !closed else { throw V2ResourceStorageError.closed }
        return try await operations.run { try await self.files.planCleanup(fileIDs: fileIDs) }
    }

    public func planCleanup(resources: [V2ResourceKey]) async throws -> V2ResourceSelectionCleanupPlan {
        guard !closed else { throw V2ResourceStorageError.closed }
        guard !resources.isEmpty, resources.count <= 100 else { throw V2ResourceStorageError.invalidRecord }
        let resources = Array(Set(resources))
        return try await operations.run {
            let journal = await self.store.resourceFileJournal()
            var fileIDs = Set<V2LocalResourceFileID>(), unavailable = 0, absent = 0
            for resource in resources {
                try Task.checkCancellation()
                guard try await self.store.resourceIsVisible(resource) else { unavailable += 1; continue }
                let ids = try journal.cleanupFileIDs(for: resource)
                if ids.isEmpty { absent += 1 }
                fileIDs.formUnion(ids)
            }
            // An empty explicit selection must never become nil (all files).
            let plan = try await self.files.planCleanup(fileIDs: Array(fileIDs))
            return V2ResourceSelectionCleanupPlan(plan: plan, resourceCount: resources.count,
                unavailableResourceCount: unavailable, absentResourceCount: absent)
        }
    }

    public func commitCleanup(_ plan: V2ResourceCleanupPlan) async throws -> V2ResourceCleanupResult {
        guard !closed else { throw V2ResourceStorageError.closed }
        return try await operations.run { try await self.files.commitCleanup(plan) }
    }

    public func variants(for resource: V2ResourceKey) async throws -> [V2ResourceVariantSnapshot] {
        guard !closed else { throw V2ResourceStorageError.closed }
        return try await operations.run {
            let journal = await self.store.resourceFileJournal()
            let generation = try journal.currentAccessGeneration()
            guard try await self.store.resourceIsVisible(resource) else { return [] }
            let values = try await self.files.variantSnapshots(for: resource)
            guard generation == (try journal.currentAccessGeneration()), try await self.store.resourceIsVisible(resource) else { return [] }
            return values
        }
    }

    public func setRetained(_ retained: Bool, variant: V2ResourceVariantKey) async throws {
        guard !closed else { throw V2ResourceStorageError.closed }
        try await operations.run {
            if retained, try await !self.store.resourceIsVisible(variant.resource) { throw V2ResourceStorageError.unavailable }
            try await self.files.setVariantRetained(retained, key: variant)
        }
    }

    public func planUnavailableRetentionRelease() async throws -> V2ResourceUnavailableRetentionPlan {
        guard !closed else { throw V2ResourceStorageError.closed }
        return try await operations.run {
            let journal = await self.store.resourceFileJournal()
            let selection = try journal.unavailableRetentionSelections()
            return .init(id: UUID(), count: selection.values.count, hasMore: selection.hasMore,
                expiresAt: Date().addingTimeInterval(60), scope: self.scope, selections: selection.values)
        }
    }

    public func releaseUnavailableRetention(_ plan: V2ResourceUnavailableRetentionPlan) async throws -> V2ResourceUnavailableRetentionResult {
        guard !closed else { throw V2ResourceStorageError.closed }
        guard plan.scope == scope else { throw V2AccountStorageError.scopeMismatch }
        return try await operations.run {
            guard plan.expiresAt > Date() else { throw V2ResourceStorageError.expiredCleanupPlan }
            return try await self.files.releaseUnavailableRetention(plan.selections, expiresAt: plan.expiresAt)
        }
    }

    /// Security-scoped access remains the platform caller's responsibility.
    /// Only opaque asset identity and validated metadata enter the journal.
    public func importLocal(at source: URL, displayName: V2ResourceDisplayName, contentType: V2ResourceContentType,
                            purpose: V2LocalResourceAssetPurpose, imageDimensions: V2LocalResourceImageDimensions? = nil, id: V2LocalResourceAssetID = .init(),
                            maximumBytes: Int64 = 50 * 1_024 * 1_024, maximumSelections: Int = 64) async throws -> V2LocalResourceAsset {
        guard !closed else { throw V2ResourceStorageError.closed }
        return try await operations.run(onCancelledValue: { asset in
            try? await self.files.discardSelection(asset.id)
        }) {
            try await self.files.importOriginal(source: source, id: id, displayName: displayName, contentType: contentType,
                purpose: purpose, imageDimensions: imageDimensions, maximumBytes: maximumBytes, maximumSelections: maximumSelections)
        }
    }

    public func borrowLocalSelection(_ id: V2LocalResourceAssetID) async throws -> V2ResourceFileLease {
        try await borrowLocalOriginal(for: .selection(id))
    }

    /// Publishes bounded caller-owned bytes directly. No normalization or
    /// provider staging file is created outside the account file owner.
    public func importLocal(data: Data, displayName: V2ResourceDisplayName, contentType: V2ResourceContentType,
                            purpose: V2LocalResourceAssetPurpose, imageDimensions: V2LocalResourceImageDimensions? = nil, id: V2LocalResourceAssetID = .init(),
                            maximumBytes: Int64 = 50 * 1_024 * 1_024, maximumSelections: Int = 64) async throws -> V2LocalResourceAsset {
        guard !closed else { throw V2ResourceStorageError.closed }
        return try await operations.run(onCancelledValue: { asset in
            try? await self.files.discardSelection(asset.id)
        }) {
            try await self.files.importOriginal(data: data, id: id, displayName: displayName, contentType: contentType,
                purpose: purpose, imageDimensions: imageDimensions, maximumBytes: maximumBytes, maximumSelections: maximumSelections)
        }
    }

    public func borrowLocalOriginal(for context: V2LocalResourceReadContext) async throws -> V2ResourceFileLease {
        guard !closed else { throw V2ResourceStorageError.closed }
        let lease = try await files.borrowOriginal(for: context)
        guard !closed, !Task.isCancelled else { await lease.release(); throw CancellationError() }
        return lease
    }

    public func localAsset(_ id: V2LocalResourceAssetID) async throws -> V2LocalResourceAsset? {
        guard !closed else { throw V2ResourceStorageError.closed }
        return try await files.localAsset(id)
    }

    public func makeUploadPart(from source: V2ResourceFileLease, range: V2ResourceByteRange) async throws -> V2ResourceTemporaryFile {
        guard !closed else { throw V2ResourceStorageError.closed }
        return try await operations.run { try await self.files.makeUploadPart(from: source, range: range) }
    }

    public func discardLocalSelection(_ id: V2LocalResourceAssetID) async throws {
        guard !closed else { throw V2ResourceStorageError.closed }
        // Idempotent dependency release is also required by cancelled callers.
        // FileStore serializes this synchronous mutation with its own close;
        // it neither publishes new bytes nor grants access after cancellation.
        try await files.discardSelection(id)
    }

    public func selectedLocalAssets(purpose: V2LocalResourceAssetPurpose) async throws -> [V2LocalResourceAsset] {
        guard !closed else { throw V2ResourceStorageError.closed }
        return try await files.selectedAssets(purpose: purpose)
    }

    /// Automatic housekeeping may defer when account work fills admission.
    /// Publication still enforces the durable byte quota independently.
    public func maintainCache(now: Date = Date()) async throws {
        do { try await maintainCache(maximumEntryCount: 256, maximumAge: 7 * 24 * 60 * 60, now: now) }
        catch V2ResourceOperationScopeError.busy { }
    }

    /// Controlled limits are internal so feature adapters cannot create a
    /// second production cache policy. Tests still use the real file owner.
    func maintainCache(maximumEntryCount: Int, maximumAge: TimeInterval, now: Date = Date()) async throws {
        guard !closed else { throw V2ResourceStorageError.closed }
        try await operations.run {
            try await self.files.reconcileFiles()
            try Task.checkCancellation()
            try await self.files.maintainCache(maximumEntryCount: maximumEntryCount, maximumAge: maximumAge, now: now)
        }
    }

    /// Page lifetime cancellation reaches HTTP. Account close cancels and
    /// drains both the request and its final database admission.
    public func synchronize(roomID: RoomID, query: V2RoomResourceQuery,
                            using reader: any V2RoomResourceDirectoryReading, restart: Bool = true) async throws -> V2RoomResourcePage? {
        guard !closed else { throw V2ResourceStorageError.closed }
        guard query.cursor == nil else { throw V2ResourceStorageError.invalidRecord }
        return try await operations.run {
            try await self.synchronizePage(roomID: roomID, query: query, reader: reader, restart: restart)
        }
    }

    private func synchronizePage(roomID: RoomID, query: V2RoomResourceQuery,
                                 reader: any V2RoomResourceDirectoryReading, restart: Bool) async throws -> V2RoomResourcePage? {
        guard !closed else { throw V2ResourceStorageError.closed }
        let scan: V2ResourceDirectoryScan
        if !restart, let existing = try await store.resourceDirectoryScan(roomID: roomID, category: query.category, before: query.before, after: query.after) {
            if existing.hasPage && existing.query.cursor == nil { return nil }
            scan = existing
        } else { scan = try await store.beginResourceDirectoryScan(roomID: roomID, query: query) }
        try Task.checkCancellation()
        guard !closed else { throw V2ResourceStorageError.closed }
        let page: V2RoomResourcePage
        do { page = try await reader.query(roomID: roomID, query: scan.query) }
        catch V2ClientResourceDirectoryError.notVisible {
            try Task.checkCancellation()
            guard !closed else { throw V2ResourceStorageError.closed }
            try await store.denyResourceDirectory(scan: scan)
            throw V2ClientResourceDirectoryError.notVisible
        }
        try Task.checkCancellation()
        guard !closed else { throw V2ResourceStorageError.closed }
        try await store.applyResourceDirectoryPage(page, to: scan)
        return page
    }

    private func start() async {
        let pulses = progress.updates
        progressObservation = Task { [weak self] in
            for await _ in pulses {
                do { try await Task.sleep(for: .milliseconds(250)) }
                catch { break }
                guard !Task.isCancelled else { break }
                await self?.publishTransferProgress()
            }
        }
        let changes = await store.projectionChanges()
        guard !closed else { return }
        observation = Task { [weak self] in
            await self?.indexProjectionBatch()
            for await change in changes {
                guard !Task.isCancelled else { break }
                guard change.scopes.contains(.resources) else { continue }
                if !change.requiresImmediateRefresh {
                    do { try await Task.sleep(for: .milliseconds(250)) }
                    catch { break }
                }
                await self?.indexProjectionBatch()
                await self?.refreshAll()
            }
        }
    }

    private func indexProjectionBatch() async {
        guard !closed, !Task.isCancelled else { return }
        // Deletes and newly indexed facts emit the next resource invalidation.
        // One batch per pulse keeps page snapshots and close responsive.
        _ = try? await store.indexResourceProjectionBatch()
    }

    private func refreshAll() async {
        guard !closed else { return }
        for id in Array(subscriptions.keys) {
            guard !Task.isCancelled else { return }
            await refresh(id)
        }
        for id in Array(transferSubscriptions.keys) {
            guard !Task.isCancelled else { return }
            await refreshTransfer(id)
        }
        for id in Array(ownerSubscriptions.keys) {
            guard !Task.isCancelled else { return }
            await refreshOwner(id)
        }
    }

    private func refresh(_ id: UUID) async {
        guard !closed, var subscription = subscriptions[id] else { return }
        subscription.readGeneration &+= 1
        subscriptions[id] = subscription
        let query = subscription.query
        let snapshot: V2ResourceDirectorySnapshot
        do {
            snapshot = .available(try await store.resourceDirectory(roomID: query.roomID, kind: query.kind, category: query.category,
                search: query.search, retainedOnly: query.retainedOnly, before: query.before, limit: query.limit))
        } catch {
            let previous: V2ResourceDirectoryPage?
            switch subscription.previous {
            case .available(let page), .unavailable(let page?): previous = page
            default: previous = nil
            }
            snapshot = .unavailable(previous: previous)
        }
        guard !closed, var current = subscriptions[id], current.readGeneration == subscription.readGeneration,
              current.previous != snapshot else { return }
        current.previous = snapshot; subscriptions[id] = current
        current.continuation.yield(snapshot)
    }

    private func remove(_ id: UUID) { subscriptions.removeValue(forKey: id) }

    private func refreshTransfer(_ id: UUID) async {
        guard !closed, var subscription = transferSubscriptions[id] else { return }
        subscription.readGeneration &+= 1
        transferSubscriptions[id] = subscription
        let snapshot: V2ResourceTransferSnapshot
        do { snapshot = .available(try await store.managedResourceTransfers(subscription.query)) }
        catch { snapshot = .unavailable }
        guard !closed, var latest = transferSubscriptions[id], latest.readGeneration == subscription.readGeneration else { return }
        if latest.base != snapshot { nativeSampleGeneration &+= 1; nativeSamples.removeAll() }
        latest.base = snapshot
        // The first local page must never wait for an OS session query. Native
        // counters join the same snapshot on the coalesced observation loop.
        let merged = snapshot.applyingTransferProgress(progress.snapshot()).applyingTransferWaiting(progress.waitingSnapshot())
        let changed = latest.previous != merged
        latest.previous = merged; transferSubscriptions[id] = latest
        if changed { latest.continuation.yield(merged) }
    }
    private func publishTransferProgress() async {
        guard !closed, !transferSubscriptions.isEmpty else { return }
        let values = transferProgressValues()
        guard !closed else { return }
        for id in Array(transferSubscriptions.keys) {
            guard var current = transferSubscriptions[id], let base = current.base else { continue }
            let merged = base.applyingTransferProgress(values).applyingTransferWaiting(progress.waitingSnapshot())
            guard current.previous != merged else { continue }
            current.previous = merged; transferSubscriptions[id] = current
            current.continuation.yield(merged)
        }
    }
    private func transferProgressValues() -> [V2ManagedResourceTransferID: V2ResourceTransferAttemptProgress] {
        var values = progress.snapshot()
        for (id, sample) in nativeSamples {
            // Two physical owners for the same canonical job are ambiguous;
            // do not invent progress by choosing or summing their byte counts.
            if values[id] != nil { values[id] = nil } else { values[id] = sample }
        }
        return values
    }
    private func startNativeProgressPolling() {
        guard nativeProgressPolling == nil else { return }
        let hub = progress
        nativeProgressPolling = Task {
            defer {
                nativeProgressPolling = nil
                if !closed, !transferSubscriptions.isEmpty { startNativeProgressPolling() }
            }
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .milliseconds(250))
                    let generation = nativeSampleGeneration
                    async let uploadValues = uploads?.nativeTransferProgress() ?? [:]
                    async let downloadValues = backgroundDownloads?.transferProgress() ?? [:]
                    let values = await (uploadValues, downloadValues)
                    guard !Task.isCancelled, !closed, !transferSubscriptions.isEmpty else { return }
                    // A query begun before a journal transition may describe
                    // the previous OS attempt. Never overlay it on the new one.
                    guard nativeSampleGeneration == generation else { continue }
                    nativeSamples = values.0.merging(values.1, uniquingKeysWith: { first, _ in first })
                    hub.requestRefresh()
                }
            } catch { }
        }
    }
    private func removeTransferSubscription(_ id: UUID) {
        transferSubscriptions.removeValue(forKey: id)
        if transferSubscriptions.isEmpty { nativeProgressPolling?.cancel(); nativeSamples.removeAll(); nativeSampleGeneration &+= 1 }
    }
    private func refreshOwner(_ id: UUID) async {
        guard !closed, var subscription = ownerSubscriptions[id] else { return }
        subscription.readGeneration &+= 1; ownerSubscriptions[id] = subscription
        let snapshot: V2ResourceBusinessOwnerSnapshot
        do { snapshot = .available(try await store.resourceBusinessOwners(subscription.query)) }
        catch { snapshot = .unavailable }
        guard !closed, var current = ownerSubscriptions[id], current.readGeneration == subscription.readGeneration, current.previous != snapshot else { return }
        current.previous = snapshot; ownerSubscriptions[id] = current
        current.continuation.yield(snapshot)
    }
    private func removeOwnerSubscription(_ id: UUID) { ownerSubscriptions[id] = nil }
}
