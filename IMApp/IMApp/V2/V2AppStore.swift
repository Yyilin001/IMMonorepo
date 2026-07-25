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
    }

    enum Route: Equatable {
        case launching
        case signedOut
        case authenticating
        case signedIn(userID: String)
        case unavailable(message: String)
    }

    enum PasswordMode: Sendable { case register, signIn }

    private let configuration: V2AppConfiguration?
    @ObservationIgnored private let authSession: V2AuthSession?
    @ObservationIgnored private let bootstrapper: V2ClientSessionBootstrapper?
    @ObservationIgnored private let deviceIdentityProvider: (any V2DeviceIdentityProvider)?
    @ObservationIgnored private weak var remoteNotificationRegistrar: (any V2RemoteNotificationRegistering)?
    @ObservationIgnored private var realtimeRuntime: V2ClientRuntime?
    @ObservationIgnored private var realtimeTask: Task<Void, Never>?

    private(set) var route: Route
    private(set) var authenticationMessage: String?
    private(set) var conversationStore: V2ConversationListStore?
    private(set) var privacySettingsStore: V2PrivacySettingsStore?
    private(set) var publicIdentitySettingsStore: V2PublicIdentitySettingsStore?
    private(set) var pushWakeSettingsStore: V2PushWakeSettingsStore?

    init(
        startupMode: StartupMode = .production,
        remoteNotificationRegistrar: (any V2RemoteNotificationRegistering)? = nil
    ) {
        self.remoteNotificationRegistrar = remoteNotificationRegistrar
        guard startupMode == .production else {
            configuration = nil
            authSession = nil
            bootstrapper = nil
            deviceIdentityProvider = nil
            route = .signedOut
            authenticationMessage = nil
            conversationStore = nil
            privacySettingsStore = nil
            publicIdentitySettingsStore = nil
            pushWakeSettingsStore = nil
            realtimeRuntime = nil
            realtimeTask = nil
            return
        }
        do {
            let configuration = try V2AppConfiguration()
            let refreshTransport = try V2HTTPDeviceCredentialAuthTransport(
                refreshEndpoint: configuration.endpoint("v2/device-credentials/refresh")
            )
            let credentialStore = V2KeychainCredentialStore(service: configuration.keychainService)
            let authSession = V2AuthSession(credentialStore: credentialStore, transport: refreshTransport)
            let databaseURL = try Self.databaseURL()
            self.configuration = configuration
            self.authSession = authSession
            self.bootstrapper = V2ClientSessionBootstrapper(
                authSession: authSession,
                localStoreBootstrapper: .init(bindingStore: V2KeychainInstallationBindingStore(service: configuration.keychainService)),
                databaseURL: databaseURL
            )
            self.deviceIdentityProvider = V2KeychainDeviceIdentityProvider(service: configuration.keychainService)
            route = .launching
            authenticationMessage = nil
            conversationStore = nil
            privacySettingsStore = nil
            publicIdentitySettingsStore = nil
            pushWakeSettingsStore = nil
            realtimeRuntime = nil
            realtimeTask = nil
        } catch {
            configuration = nil
            authSession = nil
            bootstrapper = nil
            deviceIdentityProvider = nil
            route = .unavailable(message: "V2 账户服务配置无效。")
            authenticationMessage = nil
            conversationStore = nil
            privacySettingsStore = nil
            publicIdentitySettingsStore = nil
            pushWakeSettingsStore = nil
            realtimeRuntime = nil
            realtimeTask = nil
        }
    }

    func restore() async {
        guard let bootstrapper else { return }
        route = .launching
        authenticationMessage = nil
        do {
            let localStore = try await bootstrapper.openEstablishedSession()
            try await activate(localStore: localStore)
        } catch V2ClientSessionBootstrapError.authenticationRequired {
            route = .signedOut
        } catch V2ClientSessionBootstrapError.credentialsUnavailable {
            route = .unavailable(message: "受保护凭据暂不可用，请解锁设备后重试。")
        } catch {
            route = .unavailable(message: "无法打开本地 V2 数据。")
        }
    }

    func signInWithPasskey() async {
        guard let configuration, let bootstrapper, let deviceIdentityProvider else { return }
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
                operationStore: V2KeychainDeviceCredentialRegistrationOperationStore(service: configuration.keychainService)
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
        guard let configuration, let bootstrapper, let deviceIdentityProvider else { return }
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
                operationStore: V2KeychainDeviceCredentialRegistrationOperationStore(service: configuration.keychainService)
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
        } catch {
            route = .signedOut
            authenticationMessage = "账户服务暂不可用，请稍后重试。"
        }
    }

    func signOut() async {
        await pushWakeSettingsStore?.deactivateForSignOut()
        try? await authSession?.handleTerminalRejection()
        realtimeTask?.cancel()
        realtimeTask = nil
        await realtimeRuntime?.stop()
        realtimeRuntime = nil
        authenticationMessage = nil
        conversationStore = nil
        privacySettingsStore = nil
        publicIdentitySettingsStore = nil
        pushWakeSettingsStore = nil
        route = .signedOut
    }

    private func currentUserID() async throws -> String {
        guard let authSession else { throw V2AppConfigurationError.invalidAccountBaseURL }
        let credentials = try await authSession.realtimeCredentials()
        return credentials.userID.rawValue
    }

    private func activate(localStore: GRDBV2LocalSyncStore) async throws {
        guard let configuration, let authSession else { throw V2AppConfigurationError.invalidRealtimeEndpoint }
        try Self.applyDatabaseStoragePolicy()
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
        let conversations = V2ConversationListStore(
            dataSource: V2GRDBConversationDataSource(localStore: localStore),
            userID: userID,
            sender: realtime.sender,
            messageWithdrawer: realtime.messageWithdrawer,
            messageReactionChanger: realtime.messageReactionChanger,
            messageEditor: realtime.messageEditor,
            readReceiptReporter: realtime.readReceiptReporter,
            directConversationOpener: realtime.directConversationOpener,
            publicIdentityResolver: try V2HTTPPublicIdentityDirectory(
                endpoint: configuration.endpoint("v2/public-identities/resolve"),
                credentials: authSession
            ),
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
                    key: configuration.keychainService + ".push-wake-enabled." + userID
                ),
                endpointClient: endpointClient,
                remoteNotificationRegistrar: remoteNotificationRegistrar,
                environment: configuration.pushEndpointEnvironment
            )
        } else {
            pushWakeSettings = nil
        }
        realtimeTask?.cancel()
        await realtimeRuntime?.stop()
        realtimeRuntime = realtime.runtime
        conversationStore = conversations
        privacySettingsStore = privacySettings
        publicIdentitySettingsStore = publicIdentitySettings
        pushWakeSettingsStore = pushWakeSettings
        route = .signedIn(userID: userID)
        await conversations.refresh()
        await pushWakeSettings?.activate()
        realtimeTask = Task { [weak self, runtime = realtime.runtime, conversations] in
            do {
                _ = try await runtime.start()
                await conversations.refresh()
            } catch is CancellationError {
                return
            } catch V2RealtimeSessionCoordinatorError.authenticationRequired {
                await self?.signOut()
            } catch {
                // Local projections remain readable while offline. The next
                // foreground activation deliberately creates a new attempt.
            }
        }
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

    private static func databaseURL(fileManager: FileManager = .default) throws -> URL {
        let base = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = base.appending(path: "IMAppV2", directoryHint: .isDirectory)
        let managedDirectory = try V2DeviceLocalStoragePolicy.prepareManagedDirectory(directory, fileManager: fileManager)
        return managedDirectory.appending(path: "sync.sqlite", directoryHint: .notDirectory)
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
    private static func applyDatabaseStoragePolicy(fileManager: FileManager = .default) throws {
        let database = try databaseURL(fileManager: fileManager)
        for url in [
            database,
            URL(fileURLWithPath: database.path + "-wal", isDirectory: false),
            URL(fileURLWithPath: database.path + "-shm", isDirectory: false)
        ] where fileManager.fileExists(atPath: url.path) {
            try V2DeviceLocalStoragePolicy.applyToManagedFile(url, fileManager: fileManager)
        }
    }
}
