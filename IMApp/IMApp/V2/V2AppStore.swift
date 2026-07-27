import Foundation
import IMV2ClientKit
import IMV2Core
import Observation
import UIKit

@MainActor
@Observable
final class V2AppStore: V2PushDeviceTokenReceiving, V2PushWakeHandling {
    enum StartupMode: Sendable, Equatable {
        case production
        case uiTestingSignedOut
        /// Keeps the real Debug account and gateway configuration while
        /// deliberately avoiding a restore from an existing simulator
        /// Keychain. This mode exists only behind a DEBUG launch argument for
        /// the opt-in local-account integration test; it is never reachable
        /// from a Release build.
        case uiTestingLiveLocalAccount
        /// Performs the opt-in local-account test scope cleanup. Like the
        /// registration mode, this is reachable only from a DEBUG launch
        /// argument and requires a valid random test scope.
        case uiTestingLiveLocalAccountCleanup

        var restoresPersistedSession: Bool {
            self == .production
        }

        var needsRuntimeConfiguration: Bool {
            self != .uiTestingSignedOut
        }

        var usesLiveLocalAccountE2ETestScope: Bool {
            self == .uiTestingLiveLocalAccount || self == .uiTestingLiveLocalAccountCleanup
        }
    }

    enum Route: Equatable {
        case launching
        case signedOut
        case authenticating
        case signedIn(userID: String)
        /// A Keychain read was temporarily denied while protected data was
        /// unavailable. This is distinct from a terminal configuration or
        /// local-store failure because a foreground retry may recover it.
        case protectedDataUnavailable
        /// The user has signed out, but iOS has not yet allowed the protected
        /// credential deletion to complete. Old credentials must not restore
        /// until this state has finished.
        case signOutPendingCredentialDeletion
        case uiTestingLiveLocalAccountCleanupCompleted
        case unavailable(message: String)
    }

    enum PasswordMode: Sendable { case register, signIn }

    private let configuration: V2AppConfiguration?
    @ObservationIgnored private let startupMode: StartupMode
    @ObservationIgnored private let authSession: V2AuthSession?
    @ObservationIgnored private let bootstrapper: V2ClientSessionBootstrapper?
    @ObservationIgnored private let deviceIdentityProvider: (any V2DeviceIdentityProvider)?
    @ObservationIgnored private let localKeychainService: String?
    @ObservationIgnored private let localDatabaseURL: URL?
    @ObservationIgnored private let liveLocalAccountE2ETestScope: V2LiveLocalAccountE2ETestScope?
    @ObservationIgnored private let pendingCredentialDeletionStore: (any V2PendingCredentialDeletionStoring)?
    @ObservationIgnored private weak var remoteNotificationRegistrar: (any V2RemoteNotificationRegistering)?
    @ObservationIgnored private var realtimeRuntime: V2ClientRuntime?
    @ObservationIgnored private var realtimeTask: Task<Void, Never>?
    @ObservationIgnored private var realtimeGeneration: UInt64 = 0
    @ObservationIgnored private var isApplicationActive = true

    private(set) var route: Route
    private(set) var authenticationMessage: String?
    private(set) var conversationStore: V2ConversationListStore?
    private(set) var privacySettingsStore: V2PrivacySettingsStore?
    private(set) var userBlockSettingsStore: V2UserBlockSettingsStore?
    private(set) var publicIdentitySettingsStore: V2PublicIdentitySettingsStore?
    private(set) var pushWakeSettingsStore: V2PushWakeSettingsStore?

    init(
        startupMode: StartupMode = .production,
        liveLocalAccountE2ETestScope: V2LiveLocalAccountE2ETestScope? = nil,
        remoteNotificationRegistrar: (any V2RemoteNotificationRegistering)? = nil
    ) {
        self.startupMode = startupMode
        self.remoteNotificationRegistrar = remoteNotificationRegistrar
        guard startupMode.needsRuntimeConfiguration else {
            configuration = nil
            authSession = nil
            bootstrapper = nil
            deviceIdentityProvider = nil
            localKeychainService = nil
            localDatabaseURL = nil
            self.liveLocalAccountE2ETestScope = nil
            pendingCredentialDeletionStore = nil
            route = .signedOut
            authenticationMessage = nil
            conversationStore = nil
            privacySettingsStore = nil
            userBlockSettingsStore = nil
            publicIdentitySettingsStore = nil
            pushWakeSettingsStore = nil
            realtimeRuntime = nil
            realtimeTask = nil
            return
        }
        do {
            let configuration = try V2AppConfiguration()
            #if DEBUG
            let liveLocalAccountE2ETestScope = startupMode.usesLiveLocalAccountE2ETestScope
                ? liveLocalAccountE2ETestScope
                : nil
            #else
            let liveLocalAccountE2ETestScope: V2LiveLocalAccountE2ETestScope? = nil
            #endif
            let keychainService = liveLocalAccountE2ETestScope?.keychainService(
                basedOn: configuration.keychainService
            ) ?? configuration.keychainService
            let refreshTransport = try V2HTTPDeviceCredentialAuthTransport(
                refreshEndpoint: configuration.endpoint("v2/device-credentials/refresh")
            )
            let credentialStore = V2KeychainCredentialStore(service: keychainService)
            let authSession = V2AuthSession(credentialStore: credentialStore, transport: refreshTransport)
            let databaseURL = try Self.databaseURL(
                fileName: liveLocalAccountE2ETestScope?.databaseFileName
            )
            self.configuration = configuration
            self.authSession = authSession
            localKeychainService = keychainService
            localDatabaseURL = databaseURL
            self.liveLocalAccountE2ETestScope = liveLocalAccountE2ETestScope
            pendingCredentialDeletionStore = V2UserDefaultsPendingCredentialDeletionStore(
                key: keychainService + ".pending-credential-deletion"
            )
            self.bootstrapper = V2ClientSessionBootstrapper(
                authSession: authSession,
                localStoreBootstrapper: .init(bindingStore: V2KeychainInstallationBindingStore(service: keychainService)),
                databaseURL: databaseURL
            )
            #if DEBUG
            if let liveLocalAccountE2ETestScope {
                self.deviceIdentityProvider = V2LiveLocalAccountE2ETestDeviceIdentityProvider(
                    deviceID: liveLocalAccountE2ETestScope.deviceID
                )
            } else {
                self.deviceIdentityProvider = V2KeychainDeviceIdentityProvider(service: keychainService)
            }
            #else
            self.deviceIdentityProvider = V2KeychainDeviceIdentityProvider(service: keychainService)
            #endif
            route = .launching
            authenticationMessage = nil
            conversationStore = nil
            privacySettingsStore = nil
            userBlockSettingsStore = nil
            publicIdentitySettingsStore = nil
            pushWakeSettingsStore = nil
            realtimeRuntime = nil
            realtimeTask = nil
        } catch {
            configuration = nil
            authSession = nil
            bootstrapper = nil
            deviceIdentityProvider = nil
            localKeychainService = nil
            localDatabaseURL = nil
            self.liveLocalAccountE2ETestScope = nil
            pendingCredentialDeletionStore = nil
            route = .unavailable(message: "V2 账户服务配置无效。")
            authenticationMessage = nil
            conversationStore = nil
            privacySettingsStore = nil
            userBlockSettingsStore = nil
            publicIdentitySettingsStore = nil
            pushWakeSettingsStore = nil
            realtimeRuntime = nil
            realtimeTask = nil
        }
    }

    func restore() async {
        if startupMode == .uiTestingLiveLocalAccountCleanup {
            await cleanupLiveLocalAccountE2ETestScope()
            return
        }
        guard startupMode.restoresPersistedSession else {
            route = .signedOut
            authenticationMessage = nil
            return
        }
        if await finishPendingCredentialDeletionIfNeeded() {
            return
        }
        guard let bootstrapper else { return }
        route = .launching
        authenticationMessage = nil
        do {
            let localStore = try await bootstrapper.openEstablishedSession()
            try await activate(localStore: localStore)
        } catch V2ClientSessionBootstrapError.authenticationRequired {
            route = .signedOut
        } catch V2ClientSessionBootstrapError.credentialsUnavailable {
            route = .protectedDataUnavailable
        } catch {
            route = .unavailable(message: "无法打开本地 V2 数据。")
        }
    }

    /// Retries only the explicitly recoverable protected-data state. A normal
    /// signed-out route never restores credentials merely because a prior
    /// sign-out deletion encountered a temporarily locked Keychain.
    func retryProtectedDataAccess() async {
        guard route == .protectedDataUnavailable else { return }
        // Claim the state before awaiting the actor. This coalesces a user
        // tapping retry with a simultaneous scene-activation callback.
        route = .launching
        await authSession?.retryCredentialStoreAccess()
        await restore()
    }

    func signInWithPasskey() async {
        guard let configuration,
              let bootstrapper,
              let deviceIdentityProvider,
              let localKeychainService
        else { return }
        route = .authenticating
        authenticationMessage = nil
        do {
            let passkeyService = try V2HTTPPasskeyAssertionService(
                optionsEndpoint: configuration.endpoint("v2/account-auth/passkeys/assertion-options"),
                completionEndpoint: configuration.endpoint("v2/account-auth/passkeys/assertion")
            )
            let accountProvider = V2PasskeyAccountAssertionProvider(
                requestProvider: passkeyService,
                authorizer: V2ApplePasskeyAuthorizer(),
                submitter: passkeyService
            )
            let issuer = try V2HTTPAccountAssertionDeviceCredentialProvider(
                issueEndpoint: configuration.endpoint("v2/device-credentials"),
                assertionProvider: accountProvider,
                deviceIdentityProvider: deviceIdentityProvider,
                operationStore: V2KeychainDeviceCredentialRegistrationOperationStore(service: localKeychainService)
            )
            let localStore = try await bootstrapper.establishSession(using: issuer)
            try await activate(localStore: localStore)
        } catch is CancellationError {
            route = .signedOut
        } catch {
            route = .signedOut
            authenticationMessage = "Passkey 服务尚未启用，或身份验证未通过。"
        }
    }

    func authenticatePassword(accountHandle: String, password: String, mode: PasswordMode, publicHandle: String? = nil, displayName: String? = nil) async {
        guard let configuration,
              let bootstrapper,
              let deviceIdentityProvider,
              let localKeychainService
        else { return }
        route = .authenticating
        authenticationMessage = nil
        do {
            let passwordAuthenticator = try V2HTTPPasswordAccountAuthenticator(
                registrationEndpoint: configuration.endpoint("v2/account-auth/password/register"),
                assertionEndpoint: configuration.endpoint("v2/account-auth/password/assertion")
            )
            let accountProvider = V2OneTimePasswordAccountAssertionProvider(
                accountHandle: accountHandle,
                password: password,
                mode: mode == .register ? .register : .authenticate,
                publicHandle: publicHandle,
                displayName: displayName,
                authenticator: passwordAuthenticator
            )
            let issuer = try V2HTTPAccountAssertionDeviceCredentialProvider(
                issueEndpoint: configuration.endpoint("v2/device-credentials"),
                assertionProvider: accountProvider,
                deviceIdentityProvider: deviceIdentityProvider,
                operationStore: V2KeychainDeviceCredentialRegistrationOperationStore(service: localKeychainService)
            )
            let localStore = try await bootstrapper.establishSession(using: issuer)
            try await activate(localStore: localStore)
        } catch is CancellationError {
            route = .signedOut
        } catch V2AccountAuthenticationError.invalidAccountHandle {
            route = .signedOut
            authenticationMessage = "账号须为 3–64 位小写字母、数字、下划线或连字符。"
        } catch V2AccountAuthenticationError.invalidPassword {
            route = .signedOut
            authenticationMessage = "密码须为 12–1024 个 UTF-8 字节。"
        } catch V2AccountAuthenticationError.invalidPublicHandle {
            route = .signedOut
            authenticationMessage = "公开 ID 须为 3–32 位小写字母、数字或下划线。"
        } catch V2AccountAuthenticationError.invalidDisplayName {
            route = .signedOut
            authenticationMessage = "显示名称须为 1–80 个 UTF-8 字节，且不能包含换行或控制字符。"
        } catch V2AccountAuthenticationError.accountAlreadyExists {
            route = .signedOut
            authenticationMessage = "该账号已存在，请改用密码登录。"
        } catch V2AccountAuthenticationError.authenticationRejected {
            route = .signedOut
            authenticationMessage = "账号或密码不正确。"
        } catch V2AccountAssertionCredentialProviderError.deviceIdentityUnavailable {
            route = .signedOut
            authenticationMessage = "受保护凭据暂不可用，请解锁设备后重试。"
        } catch V2AccountAssertionCredentialProviderError.registrationOperationUnavailable {
            route = .signedOut
            authenticationMessage = "无法保存本次设备注册，请稍后重试。"
        } catch {
            route = .signedOut
            authenticationMessage = "账户服务暂不可用，请稍后重试。"
        }
    }

    func signOut() async {
        guard let authSession, let pendingCredentialDeletionStore else {
            await discardAuthenticatedPresentation(route: .signedOut)
            return
        }
        // Persist intent before the first await so a process termination while
        // protected data is locked cannot resurrect a session on next launch.
        await pendingCredentialDeletionStore.markPending()
        await pushWakeSettingsStore?.deactivateForSignOut()
        do {
            try await authSession.handleTerminalRejection()
            await pendingCredentialDeletionStore.clearPending()
            await discardAuthenticatedPresentation(route: .signedOut)
        } catch {
            await discardAuthenticatedPresentation(route: .signOutPendingCredentialDeletion)
        }
    }

    /// Attempts the already-persisted logout completion after protected data
    /// becomes available. It never opens an authenticated session.
    func retryPendingCredentialDeletion() async {
        guard route == .signOutPendingCredentialDeletion else { return }
        _ = await finishPendingCredentialDeletionIfNeeded()
    }

    private func finishPendingCredentialDeletionIfNeeded() async -> Bool {
        guard let pendingCredentialDeletionStore,
              await pendingCredentialDeletionStore.isPending()
        else { return false }
        guard let authSession else {
            route = .unavailable(message: "V2 账户服务配置无效。")
            return true
        }
        // Claim the route before awaiting the actor so manual retry and scene
        // activation cannot issue duplicate Keychain deletion attempts.
        route = .launching
        do {
            try await authSession.handleTerminalRejection()
            await pendingCredentialDeletionStore.clearPending()
            await discardAuthenticatedPresentation(route: .signedOut)
        } catch {
            await discardAuthenticatedPresentation(route: .signOutPendingCredentialDeletion)
        }
        return true
    }

    private func discardAuthenticatedPresentation(route nextRoute: Route) async {
        await stopRealtime()
        realtimeRuntime = nil
        authenticationMessage = nil
        conversationStore = nil
        privacySettingsStore = nil
        userBlockSettingsStore = nil
        publicIdentitySettingsStore = nil
        pushWakeSettingsStore = nil
        route = nextRoute
    }

    private func currentUserID() async throws -> String {
        guard let authSession else { throw V2AppConfigurationError.invalidAccountBaseURL }
        let credentials = try await authSession.realtimeCredentials()
        return credentials.userID.rawValue
    }

    private func activate(localStore: GRDBV2LocalSyncStore) async throws {
        guard let configuration, let authSession, let localKeychainService, let localDatabaseURL else {
            throw V2AppConfigurationError.invalidRealtimeEndpoint
        }
        try Self.applyDatabaseStoragePolicy(databaseURL: localDatabaseURL)
        let userID = try await currentUserID()
        let realtime = try V2AppRealtimeRuntime(
            configuration: configuration,
            authSession: authSession,
            localStore: localStore,
            mediaCacheDirectory: try Self.mediaCacheDirectory()
        )
        let attachmentStager = try? V2FileConversationAttachmentStager(directory: try Self.attachmentStagingDirectory())
        await attachmentStager?.discardOrphanedStagedFiles()
        await realtime.mediaCacheMaintenance.discardOrphanedTemporaryFiles()
        let publicIdentityDirectory = try V2HTTPPublicIdentityDirectory(
            endpoint: configuration.endpoint("v2/public-identities/resolve"),
            credentials: authSession
        )
        let conversations = V2ConversationListStore(
            dataSource: V2GRDBConversationDataSource(localStore: localStore),
            userID: userID,
            sender: realtime.sender,
            messageWithdrawer: realtime.messageWithdrawer,
            messageReactionChanger: realtime.messageReactionChanger,
            messageEditor: realtime.messageEditor,
            readReceiptReporter: realtime.readReceiptReporter,
            directConversationOpener: realtime.directConversationOpener,
            publicIdentityResolver: publicIdentityDirectory,
            groupConversationCreator: realtime.groupConversationCreator,
            groupMemberDirectory: realtime.groupMemberDirectory,
            groupMembershipChanger: realtime.groupMembershipChanger,
            attachmentStager: attachmentStager,
            attachmentUploader: realtime.attachmentUploader,
            mediaDownloader: realtime.mediaDownloader
        )
        let privacySettings = V2PrivacySettingsStore(
            reader: V2GRDBStrangerMessagePreferenceDataSource(localStore: localStore),
            updater: realtime.strangerMessagePreferenceUpdater
        )
        let userBlockSettings = V2UserBlockSettingsStore(
            resolver: publicIdentityDirectory,
            changer: realtime.userBlockChanger,
            currentUserID: userID
        )
        let publicIdentitySettings = try V2PublicIdentitySettingsStore(
            manager: V2HTTPPublicIdentityProfileClient(
                endpoint: configuration.endpoint("v2/public-identities/me"),
                credentials: authSession
            )
        )
        let pushWakeSettings: V2PushWakeSettingsStore?
        if let remoteNotificationRegistrar,
           let endpointClient = try? V2HTTPPushEndpointClient(
               endpoint: configuration.pushEndpoint,
               credentials: authSession
           ) {
            pushWakeSettings = .init(
                preferences: V2UserDefaultsPushWakePreferenceStore(
                    key: localKeychainService + ".push-wake-enabled." + userID
                ),
                endpointClient: endpointClient,
                remoteNotificationRegistrar: remoteNotificationRegistrar,
                environment: configuration.pushEndpointEnvironment
            )
        } else {
            pushWakeSettings = nil
        }
        await stopRealtime()
        realtimeRuntime = realtime.runtime
        conversationStore = conversations
        privacySettingsStore = privacySettings
        userBlockSettingsStore = userBlockSettings
        publicIdentitySettingsStore = publicIdentitySettings
        pushWakeSettingsStore = pushWakeSettings
        route = .signedIn(userID: userID)
        await conversations.refresh()
        await pushWakeSettings?.activate()
        startRealtimeIfApplicationActive(runtime: realtime.runtime, conversations: conversations)
    }

    /// Stops the foreground realtime connection only after iOS has actually
    /// backgrounded the scene. `inactive` is intentionally not treated as a
    /// background transition because it also occurs while passkey and system
    /// permission UI is presented over the app.
    func applicationDidEnterBackground() async {
        isApplicationActive = false
        await stopRealtime()
    }

    /// Reuses the signed-in local projection and makes one explicit new
    /// realtime attempt after the app returns to the foreground.
    func applicationDidBecomeActive() async {
        isApplicationActive = true
        if route == .signOutPendingCredentialDeletion {
            await retryPendingCredentialDeletion()
            return
        }
        if route == .protectedDataUnavailable {
            await retryProtectedDataAccess()
            return
        }
        guard case .signedIn = route,
              let realtimeRuntime,
              let conversationStore
        else { return }
        startRealtimeIfApplicationActive(runtime: realtimeRuntime, conversations: conversationStore)
    }

    private func startRealtimeIfApplicationActive(
        runtime: V2ClientRuntime,
        conversations: V2ConversationListStore
    ) {
        guard isApplicationActive, realtimeTask == nil else { return }
        realtimeGeneration &+= 1
        let taskGeneration = realtimeGeneration
        realtimeTask = Task { [weak self, runtime, conversations] in
            do {
                _ = try await runtime.start()
                await conversations.refresh()
            } catch is CancellationError {
                return
            } catch V2RealtimeSessionCoordinatorError.authenticationRequired {
                await self?.signOutIfCurrentRealtimeAttempt(taskGeneration)
            } catch {
                // Local projections remain readable while offline. The next
                // foreground activation deliberately creates a new attempt.
            }
        }
    }

    private func stopRealtime() async {
        realtimeGeneration &+= 1
        realtimeTask?.cancel()
        realtimeTask = nil
        await realtimeRuntime?.stop()
    }

    private func signOutIfCurrentRealtimeAttempt(_ taskGeneration: UInt64) async {
        guard realtimeGeneration == taskGeneration else { return }
        await signOut()
    }

    func receiveAPNSToken(_ token: String) async {
        await pushWakeSettingsStore?.receiveAPNSToken(token)
    }

    func remoteNotificationRegistrationFailed() async {
        await pushWakeSettingsStore?.remoteNotificationRegistrationFailed()
    }

    func handlePushWake() async -> UIBackgroundFetchResult {
        guard case .signedIn = route,
              let realtimeRuntime,
              let conversationStore
        else { return .noData }
        do {
            _ = try await realtimeRuntime.start()
            await conversationStore.refresh()
            return .newData
        } catch is CancellationError {
            return .noData
        } catch V2RealtimeSessionCoordinatorError.authenticationRequired {
            await signOut()
            return .failed
        } catch {
            return .failed
        }
    }

    private func cleanupLiveLocalAccountE2ETestScope() async {
        guard let configuration,
              let liveLocalAccountE2ETestScope,
              let localKeychainService,
              let localDatabaseURL,
              localKeychainService == liveLocalAccountE2ETestScope.keychainService(
                  basedOn: configuration.keychainService
              ),
              localDatabaseURL.lastPathComponent == liveLocalAccountE2ETestScope.databaseFileName
        else {
            route = .unavailable(message: "本地 E2E 测试存储域无效。")
            return
        }

        do {
            try await V2KeychainCredentialStore(service: localKeychainService).delete()
            try await V2KeychainDeviceCredentialRegistrationOperationStore(
                service: localKeychainService
            ).delete()
            try await V2KeychainInstallationBindingStore(service: localKeychainService).delete()
            await pendingCredentialDeletionStore?.clearPending()
            try Self.eraseDatabaseArtifacts(at: localDatabaseURL)
            route = .uiTestingLiveLocalAccountCleanupCompleted
        } catch {
            route = .unavailable(message: "无法清理本地 E2E 测试数据。")
        }
    }

    private static func databaseURL(fileName: String? = nil, fileManager: FileManager = .default) throws -> URL {
        let base = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = base.appending(path: "IMAppV2", directoryHint: .isDirectory)
        let managedDirectory = try V2DeviceLocalStoragePolicy.prepareManagedDirectory(directory, fileManager: fileManager)
        return managedDirectory.appending(path: fileName ?? "sync.sqlite", directoryHint: .notDirectory)
    }

    private static func attachmentStagingDirectory(fileManager: FileManager = .default) throws -> URL {
        let base = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base
            .appending(path: "IMAppV2", directoryHint: .isDirectory)
            .appending(path: "media-staging", directoryHint: .isDirectory)
    }

    private static func mediaCacheDirectory(fileManager: FileManager = .default) throws -> URL {
        let base = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base
            .appending(path: "IMAppV2", directoryHint: .isDirectory)
            .appending(path: "media-cache", directoryHint: .isDirectory)
    }

    /// SQLite may create its WAL/SHM after the main database file; re-apply and
    /// verify the policy after each open rather than assuming directory state
    /// covers every file-system implementation.
    private static func applyDatabaseStoragePolicy(databaseURL database: URL, fileManager: FileManager = .default) throws {
        for url in [
            database,
            URL(fileURLWithPath: database.path + "-wal", isDirectory: false),
            URL(fileURLWithPath: database.path + "-shm", isDirectory: false)
        ] where fileManager.fileExists(atPath: url.path) {
            try V2DeviceLocalStoragePolicy.applyToManagedFile(url, fileManager: fileManager)
        }
    }

    private static func eraseDatabaseArtifacts(at databaseURL: URL, fileManager: FileManager = .default) throws {
        for artifact in [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal", isDirectory: false),
            URL(fileURLWithPath: databaseURL.path + "-shm", isDirectory: false)
        ] where fileManager.fileExists(atPath: artifact.path) {
            try fileManager.removeItem(at: artifact)
        }
    }
}
