import Foundation
import IMV2Core
import IMV2ClientRuntime

/// Durable local exit intent. Implementations preserve the host's existing storage namespace.
public protocol V2SharedExitIntentStoring: Sendable {
    func isPending() async throws -> Bool
    func markPending() async throws
    func clearPending() async throws
}

public enum V2SharedSessionError: Error, Sendable { case busy, accountResourcesStillOpen }

/// Native Swift session ownership, shared by Apple hosts and the C ABI composition.
/// UI routes and platform lifecycle notifications stay with the host. This owner retains
/// opening and realtime tasks until they drain, and never deletes credentials before stores close.
public actor V2SharedSession {
    private let auth: V2AuthSession
    private let bootstrap: V2ClientSessionBootstrapper
    private let exit: any V2SharedExitIntentStoring
    private let registrations: V2DeviceRegistrationStore?
    private var accounts: [ObjectIdentifier: (store: ObjectIdentifier, runtime: V2AccountRuntime)] = [:]
    private var searchServices: [ObjectIdentifier: V2SearchService] = [:]
    private var receiptServices: [ObjectIdentifier: V2ReadReceiptService] = [:]
    private var messageServices: [ObjectIdentifier: V2MessageService] = [:]
    private var conversationServices: [ObjectIdentifier: V2ConversationService] = [:]
    private var stores: [ObjectIdentifier: GRDBV2LocalSyncStore] = [:]
    private struct Opened: Sendable { let store: GRDBV2LocalSyncStore; let identity: V2LocalAccountIdentity? }
    private var opening: (id: UUID, task: Task<Opened, Error>)?
    private var openDrainers: [CheckedContinuation<Void, Never>] = []
    private var exitRequested = false
    public enum Maintenance: Sendable, Hashable { case deviceRevocation, registrationCancellation }
    private var maintenance: [Maintenance: (id: UUID, task: Task<Void, Error>)] = [:]
    private var beginningExit: Task<Void, Error>?
    private var finishingExit: Task<Void, Error>?
    private struct Foreground {
        let id: UUID
        let account: V2AccountRuntime
        let runtime: V2ClientRuntime
        let task: Task<Void, Error>
    }
    private var foreground: Foreground?
    private var stoppingForeground: Task<Void, Never>?

    public init(authSession: V2AuthSession, bootstrapper: V2ClientSessionBootstrapper,
                exitIntent: any V2SharedExitIntentStoring, registrations: V2DeviceRegistrationStore? = nil) {
        auth = authSession; bootstrap = bootstrapper; exit = exitIntent; self.registrations = registrations
    }

    public func authenticatePassword(accountHandle: String, password: String,
        mode: V2OneTimePasswordAccountAssertionProvider.Mode = .authenticate,
        publicHandle: String? = nil, displayName: String? = nil, baseURL: URL,
        metadata: V2ClientDeviceRegistrationMetadata, recovery: V2IssuedCredentialRecoveryStore,
        transport: any V2AuthHTTPTransport = V2URLSessionAuthHTTPTransport(),
        ifCurrent epoch: V2AuthSessionEpoch? = nil) async throws -> GRDBV2LocalSyncStore {
        guard let registrations else { throw V2AccountAssertionCredentialProviderError.registrationOperationUnavailable }
        return try await open { [bootstrap] in
            let prepared = try await registrations.prepare(accountHandle: accountHandle)
            try Task.checkCancellation()
            let authenticator = try V2HTTPPasswordAccountAuthenticator(
                registrationEndpoint: baseURL.appendingPathComponent("v2/account-auth/password/register"),
                assertionEndpoint: baseURL.appendingPathComponent("v2/account-auth/password/assertion"), transport: transport)
            let assertion = V2OneTimePasswordAccountAssertionProvider(accountHandle: accountHandle, password: password,
                mode: mode, publicHandle: publicHandle, displayName: displayName, authenticator: authenticator)
            let provider = try V2HTTPAccountAssertionDeviceCredentialProvider(
                issueEndpoint: baseURL.appendingPathComponent("v2/device-credentials"), assertionProvider: assertion,
                deviceIdentityProvider: prepared, operationStore: prepared, recovery: recovery,
                registrationMetadata: metadata, transport: transport)
            return Opened(store: try await bootstrap.establishSession(using: provider, ifCurrent: epoch), identity: nil)
        }.store
    }

    public func openEstablishedSession() async throws -> GRDBV2LocalSyncStore {
        try await open { [bootstrap] in .init(store: try await bootstrap.openEstablishedSession(), identity: nil) }.store
    }

    public func openLocallyEstablishedSession() async throws -> (store: GRDBV2LocalSyncStore, identity: V2LocalAccountIdentity) {
        let result = try await open { [bootstrap, exit] in
            let local = try await bootstrap.openLocallyEstablishedSession(isLocalExitPending: { try await exit.isPending() })
            return .init(store: local.store, identity: local.identity)
        }
        // Only the locally-established operation constructs this result.
        guard let identity = result.identity else { throw V2AuthSessionError.sessionInvalidated }
        return (result.store, identity)
    }

    private func open(_ operation: @escaping @Sendable () async throws -> Opened) async throws -> Opened {
        guard opening == nil, finishingExit == nil else { throw V2SharedSessionError.busy }
        guard !exitRequested else { throw V2OfflineReadBootstrapError.localExitPending }
        // Reserve before checking persistence: another actor call may enter during that read.
        let id = UUID()
        let task = Task { [exit] in
            guard try await !exit.isPending() else { throw V2OfflineReadBootstrapError.localExitPending }
            try Task.checkCancellation()
            return try await operation()
        }
        opening = (id, task)
        defer {
            if opening?.id == id {
                opening = nil
                let waiting = openDrainers; openDrainers.removeAll()
                for waiter in waiting { waiter.resume() }
            }
        }
        let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        do {
            try Task.checkCancellation()
            guard !exitRequested else { throw V2OfflineReadBootstrapError.localExitPending }
            stores[ObjectIdentifier(result.store)] = result.store
            return result
        } catch {
            // Cancellation may arrive after a successful open; ownership is not handed to the caller.
            stores[ObjectIdentifier(result.store)] = result.store
            try await closeLocalStore(result.store)
            throw error
        }
    }

    /// Retain the native account's scheduler and business activities before the UI adopts its handles.
    public func adoptAccount(_ account: V2AccountRuntime, store: GRDBV2LocalSyncStore) throws {
        let key = ObjectIdentifier(store)
        guard !exitRequested, stores[key] != nil, !accounts.values.contains(where: { $0.store == key }) else {
            throw V2SharedSessionError.busy
        }
        accounts[ObjectIdentifier(account)] = (key, account)
    }

    public func closeAccount(_ account: V2AccountRuntime) async {
        if foreground?.account === account { await suspendRealtime() }
        if let key = accounts[ObjectIdentifier(account)]?.store {
            await receiptServices[key]?.close()
            receiptServices.removeValue(forKey: key)
            await messageServices[key]?.close()
            messageServices.removeValue(forKey: key)
        }
        await account.close()
        accounts.removeValue(forKey: ObjectIdentifier(account))
    }

    /// One business facade per opened account store; all native and ABI windows share it.
    public func conversations(for store: GRDBV2LocalSyncStore, accountID: UserID,
        requiresAuthorization: Bool = true,
        requestLatestVisible: @escaping @Sendable ([RoomID]) async throws -> Void = { _ in }) throws -> V2ConversationService {
        let key = ObjectIdentifier(store)
        guard !exitRequested, stores[key] != nil else { throw V2SharedSessionError.busy }
        if let existing = conversationServices[key] {
            guard existing.accountID == accountID else { throw V2SharedSessionError.busy }
            return existing
        }
        let service = V2ConversationService(accountID: accountID, store: store,
            requiresAuthorization: requiresAuthorization, requestLatestVisible: requestLatestVisible)
        conversationServices[key] = service
        return service
    }

    public func messages(for store: GRDBV2LocalSyncStore, accountID: UserID,
        sends: V2MessageSendOperationService, mutations: V2MessageMutationOperationService,
        reactions: V2MessageReactionOperationService, forwards: V2ForwardPlanOperationService) throws -> V2MessageService {
        let key = ObjectIdentifier(store)
        guard !exitRequested, stores[key] != nil else { throw V2SharedSessionError.busy }
        if let existing = messageServices[key] {
            guard existing.accountID == accountID else { throw V2SharedSessionError.busy }
            return existing
        }
        let service = V2MessageService(accountID: accountID, store: store, sends: sends,
            mutations: mutations, reactions: reactions, forwards: forwards)
        messageServices[key] = service
        return service
    }

    public func search(for store: GRDBV2LocalSyncStore) throws -> V2SearchService {
        let key = ObjectIdentifier(store)
        guard !exitRequested, stores[key] != nil else { throw V2SharedSessionError.busy }
        if let existing = searchServices[key] { return existing }
        let service = V2SearchService(store: store)
        searchServices[key] = service
        return service
    }

    public func readReceipts(for store: GRDBV2LocalSyncStore, accountID: UserID,
        receipts: V2ReadReceiptOperationService, transport: any V2ClientReadReceiptTransport) throws -> V2ReadReceiptService {
        let key = ObjectIdentifier(store)
        guard !exitRequested, stores[key] != nil else { throw V2SharedSessionError.busy }
        if let existing = receiptServices[key] {
            guard existing.accountID == accountID else { throw V2SharedSessionError.busy }
            return existing
        }
        let service = V2ReadReceiptService(accountID: accountID, store: store, receipts: receipts, transport: transport)
        receiptServices[key] = service
        return service
    }

    public func closeLocalStore(_ store: GRDBV2LocalSyncStore) async throws {
        guard !accounts.values.contains(where: { $0.store == ObjectIdentifier(store) }) else {
            throw V2SharedSessionError.accountResourcesStillOpen
        }
        await receiptServices[ObjectIdentifier(store)]?.close()
        await searchServices[ObjectIdentifier(store)]?.close()
        await messageServices[ObjectIdentifier(store)]?.close()
        await conversationServices[ObjectIdentifier(store)]?.close()
        try await bootstrap.closeLocalStore(store)
        receiptServices.removeValue(forKey: ObjectIdentifier(store))
        searchServices.removeValue(forKey: ObjectIdentifier(store))
        messageServices.removeValue(forKey: ObjectIdentifier(store))
        conversationServices.removeValue(forKey: ObjectIdentifier(store))
        stores.removeValue(forKey: ObjectIdentifier(store))
    }

    /// Commit intent first; a failed write still blocks this owner's next login until retry.
    public func beginSignOut() async throws {
        if let finishingExit { return try await finishingExit.value }
        if let beginningExit { return try await beginningExit.value }
        exitRequested = true
        let task = Task { try await self.commitExitAndDrainOpening() }
        beginningExit = task
        defer { beginningExit = nil }
        try await task.value
    }

    private func commitExitAndDrainOpening() async throws {
        try await exit.markPending()
        opening?.task.cancel()
        await auth.invalidateOutstandingWork()
        if let task = opening?.task {
            _ = await task.result
            if opening != nil { await withCheckedContinuation { openDrainers.append($0) } }
        }
        await suspendRealtime()
    }

    /// The host first drains its page/media resources and closes captured stores through this owner.
    /// This durable tail belongs to the session, so cancellation of a disappearing view cannot truncate it.
    public func completeSignOut() async throws {
        if let beginningExit { try await beginningExit.value }
        if let finishingExit { return try await finishingExit.value }
        guard opening == nil, stores.isEmpty, accounts.isEmpty, foreground == nil, stoppingForeground == nil else {
            throw V2SharedSessionError.accountResourcesStillOpen
        }
        guard exitRequested else { throw V2OfflineReadBootstrapError.localExitPending }
        let task = Task { [auth, registrations, exit] in
            guard try await exit.isPending() else { throw V2OfflineReadBootstrapError.localExitPending }
            try await auth.handleTerminalRejection()
            try await registrations?.discardPendingRegistrations()
            try await exit.clearPending()
        }
        finishingExit = task
        defer { finishingExit = nil }
        try await task.value
        exitRequested = false
    }

    /// The host awaits this native operation; the shared owner retains the physical task until drained.
    public func runRealtime(_ runtime: V2ClientRuntime, account: V2AccountRuntime,
                            onConnected: @escaping @Sendable () async -> Void = {}) async throws {
        guard !exitRequested, foreground == nil, stoppingForeground == nil else { throw V2SharedSessionError.busy }
        let id = UUID()
        let task = Task {
            do { try await account.runRealtime(runtime, onConnected: onConnected) }
            catch {
                await account.suspendRealtime()
                await runtime.stop()
                throw error
            }
            await account.suspendRealtime()
            await runtime.stop()
        }
        foreground = .init(id: id, account: account, runtime: runtime, task: task)
        defer { if foreground?.id == id { foreground = nil } }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    public func suspendRealtime() async {
        if let stoppingForeground { await stoppingForeground.value; return }
        guard let previous = foreground else { return }
        previous.task.cancel()
        let drain = Task {
            await previous.account.suspendRealtime()
            await previous.runtime.stop()
            _ = await previous.task.result
        }
        stoppingForeground = drain
        await drain.value
        if foreground?.id == previous.id { foreground = nil }
        stoppingForeground = nil
    }

    /// Maintenance belongs to the client, including while signed out. Platform observers only render results.
    public func runMaintenance(_ kind: Maintenance, operation: @escaping @Sendable () async throws -> Void) async throws {
        guard maintenance[kind] == nil else { throw V2SharedSessionError.busy }
        let id = UUID(), task = Task { try await operation() }
        maintenance[kind] = (id, task)
        defer { if maintenance[kind]?.id == id { maintenance.removeValue(forKey: kind) } }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    public func suspendMaintenance() async {
        let captured = maintenance
        for item in captured.values { item.task.cancel() }
        for (kind, item) in captured {
            _ = await item.task.result
            if maintenance[kind]?.id == item.id { maintenance.removeValue(forKey: kind) }
        }
    }

    public func ownedStoreCount() -> Int { stores.count }
    public func activeTaskCount() -> Int { (opening == nil ? 0 : 1) + (foreground == nil ? 0 : 1) + maintenance.count }

}
