import Foundation
import IMV2ClientKit
import IMV2Core
import Observation
import OSLog
import UIKit

/// Tracks the short-lived task that starts the foreground realtime runtime.
/// The runtime itself owns its live loops after startup; this gate only keeps
/// a completed or cancelled startup task from blocking a later retry.
@MainActor
struct V2RealtimeAttemptGate {
    private(set) var generation: UInt64 = 0
    private(set) var hasInFlightAttempt = false

    mutating func begin(ifApplicationActive isApplicationActive: Bool) -> UInt64? {
        guard isApplicationActive, !hasInFlightAttempt else { return nil }
        generation &+= 1
        hasInFlightAttempt = true
        return generation
    }

    /// Returns `true` only when this completion belongs to the current task.
    /// A stopped runtime may finish its cancelled task after a newer attempt
    /// has been created, and must not clear that newer task's ownership.
    mutating func finish(generation completedGeneration: UInt64) -> Bool {
        guard hasInFlightAttempt, generation == completedGeneration else { return false }
        hasInFlightAttempt = false
        return true
    }

    mutating func cancel() {
        generation &+= 1
        hasInFlightAttempt = false
    }

    func matchesCurrentGeneration(_ candidate: UInt64) -> Bool {
        generation == candidate
    }
}

/// Gives each explicit sign-in request ownership of the authentication UI
/// state. A transport may complete after its Task was cancelled, so Task
/// cancellation alone cannot let an older request overwrite a newer login.
@MainActor
struct V2AuthenticationAttemptGate {
    private(set) var generation: UInt64 = 0

    mutating func begin() -> UInt64 {
        generation &+= 1
        return generation
    }

    func matchesCurrentGeneration(_ candidate: UInt64) -> Bool {
        generation == candidate
    }
}

/// A background push owns only the bounded catch-up it starts. If the scene
/// returns to the foreground before that catch-up finishes, foreground
/// lifecycle ownership takes over and the shared runtime must stay alive.
@MainActor
enum V2PushWakeRuntimeOwnership {
    static func shouldStopAfterFetch(
        startedWhileApplicationInactive: Bool,
        isApplicationActive: Bool
    ) -> Bool {
        startedWhileApplicationInactive && !isApplicationActive
    }
}

/// Sign-out spans authenticated endpoint removal and protected credential
/// deletion. It is a single-flight operation so duplicate user taps or a
/// simultaneous terminal-auth callback cannot interleave those two steps.
@MainActor
struct V2SignOutAttemptGate {
    private(set) var isInFlight = false

    mutating func begin() -> Bool {
        guard !isInFlight else { return false }
        isInFlight = true
        return true
    }

    mutating func finish() {
        isInFlight = false
    }
}

@MainActor
@Observable
final class V2AppStore: V2PushDeviceTokenReceiving, V2PushWakeHandling {
    private static let authenticationLogger = Logger(
        subsystem: "com.stskcxfz.imapp",
        category: "v2.authentication"
    )

    enum StartupMode: Sendable, Equatable {
        case production
        case uiTestingSignedOut
        /// Keeps the real Debug account and gateway configuration while
        /// deliberately avoiding a restore from an existing simulator
        /// Keychain. This mode exists only behind a DEBUG launch argument for
        /// the opt-in local-account integration test; it is never reachable
        /// from a Release build.
        case uiTestingLiveLocalAccount
        /// Reopens only the explicitly scoped Keychain and SQLite state from
        /// a preceding local-account UI-test launch. This lets two distinct
        /// simulator installations prove an offline recipient catches up
        /// after it is relaunched; it cannot reach a production session.
        case uiTestingLiveLocalAccountRestore
        /// Performs the opt-in local-account test scope cleanup. Like the
        /// registration mode, this is reachable only from a DEBUG launch
        /// argument and requires a valid random test scope.
        case uiTestingLiveLocalAccountCleanup

        var restoresPersistedSession: Bool {
            self == .production || self == .uiTestingLiveLocalAccountRestore
        }

        var needsRuntimeConfiguration: Bool {
            self != .uiTestingSignedOut
        }

        var usesLiveLocalAccountE2ETestScope: Bool {
            self == .uiTestingLiveLocalAccount
                || self == .uiTestingLiveLocalAccountRestore
                || self == .uiTestingLiveLocalAccountCleanup
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
    @ObservationIgnored private var messageSearchIndexTask: Task<Void, Never>?
    @ObservationIgnored private var realtimeAttemptGate = V2RealtimeAttemptGate()
    @ObservationIgnored private var authenticationAttemptGate = V2AuthenticationAttemptGate()
    @ObservationIgnored private var signOutAttemptGate = V2SignOutAttemptGate()
    @ObservationIgnored private var isApplicationActive = true

    private(set) var route: Route
    private(set) var authenticationMessage: String?
    private(set) var conversationStore: V2ConversationListStore?
    private(set) var contactsStore: V2ContactsStore?
    private(set) var privacySettingsStore: V2PrivacySettingsStore?
    private(set) var userBlockSettingsStore: V2UserBlockSettingsStore?
    private(set) var publicIdentitySettingsStore: V2PublicIdentitySettingsStore?
    private(set) var pushWakeSettingsStore: V2PushWakeSettingsStore?

    init(
        startupMode: StartupMode = .production,
        liveLocalAccountE2ETestScope: V2LiveLocalAccountE2ETestScope? = nil,
        debugForcesUnavailableRealtimeForLiveLocalAccountE2E: Bool = false,
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
            contactsStore = nil
            privacySettingsStore = nil
            userBlockSettingsStore = nil
            publicIdentitySettingsStore = nil
            pushWakeSettingsStore = nil
            realtimeRuntime = nil
            realtimeTask = nil
            messageSearchIndexTask = nil
            return
        }
        do {
            #if DEBUG
            let configuration = try V2AppConfiguration(
                localE2ETestForcesUnavailableRealtime: startupMode.usesLiveLocalAccountE2ETestScope
                    && debugForcesUnavailableRealtimeForLiveLocalAccountE2E
            )
            #else
            let configuration = try V2AppConfiguration()
            #endif
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
            contactsStore = nil
            privacySettingsStore = nil
            userBlockSettingsStore = nil
            publicIdentitySettingsStore = nil
            pushWakeSettingsStore = nil
            realtimeRuntime = nil
            realtimeTask = nil
            messageSearchIndexTask = nil
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
            contactsStore = nil
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
            try Task.checkCancellation()
            try await activate(localStore: localStore)
        } catch V2ClientSessionBootstrapError.authenticationRequired {
            route = .signedOut
        } catch V2ClientSessionBootstrapError.credentialsUnavailable {
            route = .protectedDataUnavailable
        } catch is CancellationError {
            return
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
        let attemptGeneration = beginAuthenticationAttempt()
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
            try Task.checkCancellation()
            guard authenticationAttemptGate.matchesCurrentGeneration(attemptGeneration) else { return }
            try await activate(localStore: localStore, authenticationAttemptGeneration: attemptGeneration)
        } catch is CancellationError {
            guard !Task.isCancelled else { return }
            guard authenticationAttemptGate.matchesCurrentGeneration(attemptGeneration) else { return }
            route = .signedOut
        } catch {
            guard authenticationAttemptGate.matchesCurrentGeneration(attemptGeneration) else { return }
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
        let attemptGeneration = beginAuthenticationAttempt()
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
            try Task.checkCancellation()
            guard authenticationAttemptGate.matchesCurrentGeneration(attemptGeneration) else { return }
            try await activate(localStore: localStore, authenticationAttemptGeneration: attemptGeneration)
        } catch is CancellationError {
            guard !Task.isCancelled else { return }
            guard authenticationAttemptGate.matchesCurrentGeneration(attemptGeneration) else { return }
            route = .signedOut
        } catch V2AccountAuthenticationError.invalidAccountHandle {
            guard authenticationAttemptGate.matchesCurrentGeneration(attemptGeneration) else { return }
            route = .signedOut
            authenticationMessage = "账号须为 3–64 位小写字母、数字、下划线或连字符。"
        } catch V2AccountAuthenticationError.invalidPassword {
            guard authenticationAttemptGate.matchesCurrentGeneration(attemptGeneration) else { return }
            route = .signedOut
            authenticationMessage = "密码须为 12–1024 个 UTF-8 字节。"
        } catch V2AccountAuthenticationError.invalidPublicHandle {
            guard authenticationAttemptGate.matchesCurrentGeneration(attemptGeneration) else { return }
            route = .signedOut
            authenticationMessage = "公开 ID 须为 3–32 位小写字母、数字或下划线。"
        } catch V2AccountAuthenticationError.invalidDisplayName {
            guard authenticationAttemptGate.matchesCurrentGeneration(attemptGeneration) else { return }
            route = .signedOut
            authenticationMessage = "显示名称须为 1–80 个 UTF-8 字节，且不能包含换行或控制字符。"
        } catch V2AccountAuthenticationError.accountAlreadyExists {
            guard authenticationAttemptGate.matchesCurrentGeneration(attemptGeneration) else { return }
            route = .signedOut
            authenticationMessage = "该账号已存在，请改用密码登录。"
        } catch V2AccountAuthenticationError.authenticationRejected {
            guard authenticationAttemptGate.matchesCurrentGeneration(attemptGeneration) else { return }
            route = .signedOut
            authenticationMessage = "账号或密码不正确。"
        } catch let error as V2AccountAuthenticationError {
            // Every remaining case contains only a transport classification or
            // HTTP status. Keep it local to diagnostics; it is not user-facing
            // and has no account or credential material.
            guard authenticationAttemptGate.matchesCurrentGeneration(attemptGeneration) else { return }
            Self.authenticationLogger.error(
                "Password account authentication failed: \(String(reflecting: error), privacy: .public)"
            )
            route = .signedOut
            authenticationMessage = "账户服务暂不可用，请稍后重试。"
        } catch V2AccountAssertionCredentialProviderError.deviceIdentityUnavailable {
            guard authenticationAttemptGate.matchesCurrentGeneration(attemptGeneration) else { return }
            route = .signedOut
            authenticationMessage = "受保护凭据暂不可用，请解锁设备后重试。"
        } catch V2AccountAssertionCredentialProviderError.registrationOperationUnavailable {
            guard authenticationAttemptGate.matchesCurrentGeneration(attemptGeneration) else { return }
            route = .signedOut
            authenticationMessage = "无法保存本次设备注册，请稍后重试。"
        } catch V2AuthSessionError.credentialsUnavailable {
            // Device credentials were issued but could not be durably written.
            // This is normally a temporary protected-data/keychain state; never
            // discard the server-side registration or misreport it as a network
            // outage.
            guard authenticationAttemptGate.matchesCurrentGeneration(attemptGeneration) else { return }
            route = .protectedDataUnavailable
        } catch V2LocalStoreBootstrapError.installationBindingUnavailable {
            // The device-only installation anchor uses the same protected
            // Keychain boundary as credentials. It can recover after unlock.
            guard authenticationAttemptGate.matchesCurrentGeneration(attemptGeneration) else { return }
            route = .protectedDataUnavailable
        } catch V2ClientLocalStorageError.backupExclusionVerificationFailed {
            guard authenticationAttemptGate.matchesCurrentGeneration(attemptGeneration) else { return }
            route = .signedOut
            authenticationMessage = "无法按安全策略准备本地数据存储。"
        } catch is V2DeviceLocalStorageError {
            guard authenticationAttemptGate.matchesCurrentGeneration(attemptGeneration) else { return }
            route = .signedOut
            authenticationMessage = "无法按安全策略准备本地数据存储。"
        } catch {
            // Keep diagnostics useful without exposing account identifiers,
            // assertion material, credentials, or server response bodies.
            guard authenticationAttemptGate.matchesCurrentGeneration(attemptGeneration) else { return }
            Self.authenticationLogger.error(
                "Password authentication failed with error type \(String(reflecting: type(of: error)), privacy: .public)"
            )
            route = .signedOut
            authenticationMessage = "账户服务暂不可用，请稍后重试。"
        }
    }

    func signOut() async {
        guard signOutAttemptGate.begin() else { return }
        defer { signOutAttemptGate.finish() }
        guard let authSession, let pendingCredentialDeletionStore else {
            await discardAuthenticatedPresentation(route: .signedOut)
            return
        }
        // Persist intent before the first await so a process termination while
        // protected data is locked cannot resurrect a session on next launch.
        await pendingCredentialDeletionStore.markPending()
        do {
            try await removePushEndpointBeforeCredentialDeletion()
            try Task.checkCancellation()
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
            try await removePushEndpointBeforeCredentialDeletion()
            try Task.checkCancellation()
            try await authSession.handleTerminalRejection()
            await pendingCredentialDeletionStore.clearPending()
            await discardAuthenticatedPresentation(route: .signedOut)
        } catch {
            await discardAuthenticatedPresentation(route: .signOutPendingCredentialDeletion)
        }
        return true
    }

    /// The device endpoint is authenticated by the same credential record as
    /// sign-out. Never discard that record before an endpoint DELETE has
    /// succeeded; a persisted pending sign-out retries this idempotent DELETE
    /// on the next launch even though the prior UI store has been discarded.
    private func removePushEndpointBeforeCredentialDeletion() async throws {
        if let pushWakeSettingsStore {
            try await pushWakeSettingsStore.deactivateForSignOut()
            return
        }
        guard let configuration, let authSession else { return }
        let endpointClient = try V2HTTPPushEndpointClient(
            endpoint: configuration.pushEndpoint,
            credentials: authSession
        )
        try await endpointClient.remove()
    }

    private func discardAuthenticatedPresentation(route nextRoute: Route) async {
        messageSearchIndexTask?.cancel()
        messageSearchIndexTask = nil
        await stopRealtime()
        realtimeRuntime = nil
        authenticationMessage = nil
        conversationStore = nil
        contactsStore = nil
        privacySettingsStore = nil
        userBlockSettingsStore = nil
        publicIdentitySettingsStore = nil
        pushWakeSettingsStore = nil
        route = nextRoute
    }

    private func currentUserID() async throws -> UserID {
        guard let authSession else { throw V2AppConfigurationError.invalidAccountBaseURL }
        let credentials = try await authSession.realtimeCredentials()
        return credentials.userID
    }

    private func beginAuthenticationAttempt() -> UInt64 {
        let generation = authenticationAttemptGate.begin()
        route = .authenticating
        authenticationMessage = nil
        return generation
    }

    private func activate(
        localStore: GRDBV2LocalSyncStore,
        authenticationAttemptGeneration: UInt64? = nil
    ) async throws {
        guard let configuration, let authSession, let localKeychainService, let localDatabaseURL else {
            throw V2AppConfigurationError.invalidRealtimeEndpoint
        }
        try Self.applyDatabaseStoragePolicy(databaseURL: localDatabaseURL)
        let userID = try await currentUserID()
        try Task.checkCancellation()
        let realtime = try V2AppRealtimeRuntime(
            configuration: configuration,
            authSession: authSession,
            localStore: localStore,
            mediaCacheDirectory: try Self.mediaCacheDirectory()
        )
        let attachmentStager = try? V2FileConversationAttachmentStager(directory: try Self.attachmentStagingDirectory())
        await attachmentStager?.discardOrphanedStagedFiles()
        try Task.checkCancellation()
        await realtime.mediaCacheMaintenance.discardOrphanedTemporaryFiles()
        try Task.checkCancellation()
        let publicIdentityDirectory = try V2HTTPPublicIdentityDirectory(
            endpoint: configuration.endpoint("v2/public-identities/resolve"),
            credentials: authSession
        )
        let conversationDataSource = V2GRDBConversationDataSource(localStore: localStore)
        let contactsDataSource = V2GRDBContactsDataSource(
            localStore: localStore,
            profiles: realtime.profileRepository
        )
        let conversations = V2ConversationListStore(
            dataSource: conversationDataSource,
            messageSearcher: conversationDataSource,
            userID: userID.rawValue,
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
            groupMemberMuter: realtime.groupMemberMuter,
            moderatedGroupMemberRemover: realtime.moderatedGroupMemberRemover,
            attachmentStager: attachmentStager,
            attachmentUploader: realtime.attachmentUploader,
            mediaDownloader: realtime.mediaDownloader,
            projectionChangeNotifier: realtime.projectionChangeNotifier,
            activeHybridGroupSynchronizer: realtime.activeHybridGroupSynchronizer
        )
        let privacySettings = V2PrivacySettingsStore(
            reader: V2GRDBStrangerMessagePreferenceDataSource(localStore: localStore),
            updater: realtime.strangerMessagePreferenceUpdater,
            userAddReader: V2GRDBUserAddPreferenceDataSource(localStore: localStore),
            userAddUpdater: realtime.userAddPreferenceUpdater
        )
        let contacts = V2ContactsStore(
            dataSource: contactsDataSource,
            identityResolver: publicIdentityDirectory,
            relationshipChanger: realtime.relationshipChanger,
            userBlockChanger: realtime.userBlockChanger,
            directConversationOpener: realtime.directConversationOpener,
            currentUserID: userID,
            projectionChangeNotifier: realtime.projectionChangeNotifier
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
                    key: localKeychainService + ".push-wake-enabled." + userID.rawValue
                ),
                endpointClient: endpointClient,
                remoteNotificationRegistrar: remoteNotificationRegistrar,
                environment: configuration.pushEndpointEnvironment
            )
        } else {
            pushWakeSettings = nil
        }
        guard authenticationAttemptGeneration.map(authenticationAttemptGate.matchesCurrentGeneration) ?? true else { return }
        await stopRealtime()
        try Task.checkCancellation()
        guard authenticationAttemptGeneration.map(authenticationAttemptGate.matchesCurrentGeneration) ?? true else { return }
        realtimeRuntime = realtime.runtime
        conversationStore = conversations
        contactsStore = contacts
        privacySettingsStore = privacySettings
        userBlockSettingsStore = userBlockSettings
        publicIdentitySettingsStore = publicIdentitySettings
        pushWakeSettingsStore = pushWakeSettings
        route = .signedIn(userID: userID.rawValue)
        messageSearchIndexTask?.cancel()
        messageSearchIndexTask = Task { [localStore] in
            do {
                try await localStore.prepareMessageSearchIndex()
            } catch is CancellationError {
                return
            } catch {
                // The search UI reports the persistent index state. A failed
                // derived index must never break the authenticated runtime.
            }
        }
        await conversations.refresh()
        await pushWakeSettings?.activate()
        guard authenticationAttemptGeneration.map(authenticationAttemptGate.matchesCurrentGeneration) ?? true else { return }
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
        guard let taskGeneration = realtimeAttemptGate.begin(ifApplicationActive: isApplicationActive) else { return }
        realtimeTask = Task { [weak self, runtime, conversations] in
            defer { self?.finishRealtimeAttempt(generation: taskGeneration) }
            var retryDelay: Duration = .seconds(1)
            while !Task.isCancelled {
                do {
                    let establishedAt = ContinuousClock.now
                    _ = try await runtime.start()
                    try Task.checkCancellation()
                    await conversations.refresh()
                    // A live-loop failure moves the runtime to `.stopped`.
                    // Waiting on that explicit transition avoids treating a
                    // foreground network handoff as permanent offline mode.
                    await runtime.waitUntilStopped()
                    // Only a genuinely stable session clears backoff. An
                    // immediately failing loop otherwise turns into a one-
                    // second reconnect storm on a bad network path.
                    if establishedAt.duration(to: .now) >= .seconds(15) {
                        retryDelay = .seconds(1)
                    }
                } catch is CancellationError {
                    return
                } catch V2RealtimeSessionCoordinatorError.authenticationRequired {
                    await self?.signOutIfCurrentRealtimeAttempt(taskGeneration)
                    return
                } catch {
                    // Keep local projections readable, but recover while the
                    // app remains foregrounded. The bounded exponential delay
                    // avoids a hot reconnect loop during an outage.
                }
                do {
                    try await Task.sleep(for: retryDelay)
                } catch is CancellationError {
                    return
                } catch {
                    return
                }
                retryDelay = min(retryDelay * 2, .seconds(30))
            }
        }
    }

    private func stopRealtime() async {
        realtimeAttemptGate.cancel()
        realtimeTask?.cancel()
        realtimeTask = nil
        await realtimeRuntime?.stop()
    }

    private func signOutIfCurrentRealtimeAttempt(_ taskGeneration: UInt64) async {
        guard realtimeAttemptGate.matchesCurrentGeneration(taskGeneration) else { return }
        await signOut()
    }

    private func finishRealtimeAttempt(generation taskGeneration: UInt64) {
        guard realtimeAttemptGate.finish(generation: taskGeneration) else { return }
        realtimeTask = nil
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
        let startedWhileApplicationInactive = !isApplicationActive
        let result: UIBackgroundFetchResult
        do {
            _ = try await realtimeRuntime.start()
            await conversationStore.refresh()
            result = .newData
        } catch is CancellationError {
            result = .noData
        } catch V2RealtimeSessionCoordinatorError.authenticationRequired {
            await signOut()
            result = .failed
        } catch {
            result = .failed
        }
        if V2PushWakeRuntimeOwnership.shouldStopAfterFetch(
            startedWhileApplicationInactive: startedWhileApplicationInactive,
            isApplicationActive: isApplicationActive
        ) {
            await realtimeRuntime.stop()
        }
        return result
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
