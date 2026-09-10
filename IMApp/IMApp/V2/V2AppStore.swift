import Foundation
import IMV2ClientKit
import IMV2Core
import Observation
import OSLog
import UIKit

/// 跟踪那个用于启动前台实时运行时的短生命周期任务。
///
/// 启动完成后，实时循环归运行时自身所有；
/// 这个闸门只负责防止一个已完成或被取消的启动任务阻塞后续重试。
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

    /// 仅当本次完成属于当前任务时才返回 `true`。
    ///
    /// 一个已停止的运行时可能在新尝试创建之后才完成其已取消的任务，
    /// 此时不得清除新任务的所有权。
    ///
    /// - Parameter completedGeneration: 完成方持有的代次。
    /// - Returns: 该完成是否属于当前任务。
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

/// 让每个显式登录请求各自拥有认证 UI 状态。
///
/// 传输层可能在自身 Task 被取消之后才完成，
/// 因此仅靠 Task 取消无法阻止较早的请求覆盖较新的登录。
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

/// 登出闸门。
///
/// 登出负责本地任务关闭与持久凭据交接。重复点击与终态认证回调共用此闸门；
/// 网络吊销则由另一个独立于 App 生命周期的所有者负责。
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
/// 应用账号根状态与依赖生命周期的 MainActor 所有者。
///
/// 负责登录／恢复 route、认证代次、前后台 runtime、页面依赖和退出收尾。
/// 异步激活返回后需要重新验证 attempt generation 和认证 epoch，
/// 防止旧账号结果覆盖新状态。普通退出保留数据库 outbox，与显式擦除不同。
final class V2AppStore: V2PushDeviceTokenReceiving, V2PushWakeHandling {
    private static let authenticationLogger = Logger(
        subsystem: "com.stskcxfz.imapp",
        category: "v2.authentication"
    )

    enum StartupMode: Sendable, Equatable {
        case production
        case uiTestingSignedOut
        /// 保留真实的 Debug 账号与网关配置，同时刻意不恢复既有模拟器 Keychain。
        ///
        /// 该模式只存在于 DEBUG 启动参数之后，供可选的本地账号集成测试使用；
        /// 在 Release 构建中永远无法到达。
        case uiTestingLiveLocalAccount
        /// 只重新打开此前一次本地账号 UI 测试启动所显式限定的 Keychain 与 SQLite 状态。
        ///
        /// 这使两个不同的模拟器安装可以验证：离线接收方在重启后能够补齐；
        /// 它无法触达生产会话。
        case uiTestingLiveLocalAccountRestore
        /// 执行可选的本地账号测试作用域清理。
        ///
        /// 与注册模式一样，它只能通过 DEBUG 启动参数到达，并要求有效的随机测试作用域。
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
        /// 在受保护数据不可用期间，一次 Keychain 读取被临时拒绝。
        ///
        /// 它与终态配置或本地存储失败不同，因为前台重试可能使其恢复。
        case protectedDataUnavailable
        /// 用户已登出，但 iOS 尚未允许受保护的凭据删除完成。
        ///
        /// 在该状态结束之前，旧凭据不得被恢复。
        case signOutPendingCredentialDeletion
        case uiTestingLiveLocalAccountCleanupCompleted
        case unavailable(message: String)
    }

    enum PasswordMode: Sendable { case register, signIn }

    private let configuration: V2AppConfiguration?
    @ObservationIgnored let startupMode: StartupMode
    @ObservationIgnored private let authSession: V2AuthSession?
    @ObservationIgnored private let bootstrapper: V2ClientSessionBootstrapper?
    @ObservationIgnored private let deviceRegistrationStore: V2DeviceRegistrationStore?
    @ObservationIgnored private let deviceRevocationStore: V2DeviceRevocationStore?
    @ObservationIgnored private let issuedCredentialRecovery: V2IssuedCredentialRecoveryStore?
    @ObservationIgnored private var recoveredIssuedCredentials = false
    @ObservationIgnored private let deviceRevocationRunner: V2DeviceRevocationRunner?
    @ObservationIgnored private let registrationCancellationRunner: V2DeviceRegistrationCancellationRunner?
    @ObservationIgnored private var registrationCancellationTask: Task<Void, Never>?
    @ObservationIgnored private var registrationCancellationObservation: Task<Void, Never>?
    private var registrationCancellationNeedsRetry = false
    private var registrationCancellationObservationState: RevocationObservationState = .unknown
    @ObservationIgnored private var deviceRevocationTask: Task<Void, Never>?
    private(set) var deviceRevocationNeedsRetry = false
    @ObservationIgnored private var deviceRevocationObservation: Task<Void, Never>?
    private var revocationObservationState: RevocationObservationState = .unknown
    private var revocationRetrying = false
    private enum RevocationObservationState { case unknown, known(V2DeviceRevocationQueueStatus), unavailable }

    var deviceRevocationPresentation: V2DeviceRevocationPresentation {
        if revocationRetrying { return .retrying }
        if deviceRevocationNeedsRetry || registrationCancellationNeedsRetry { return .unavailable }
        let states = [revocationObservationState, registrationCancellationObservationState]
        if states.contains(where: { if case .unavailable = $0 { true } else { false } }) { return .unavailable }
        if states.contains(where: { if case .known(.paused) = $0 { true } else { false } }) { return .paused }
        if states.contains(where: { if case .known(.pending) = $0 { true } else { false } }) { return .pending }
        return .hidden
    }
    @ObservationIgnored private let localKeychainService: String?
    @ObservationIgnored private let localDatabaseURL: URL?
    @ObservationIgnored private let liveLocalAccountE2ETestScope: V2LiveLocalAccountE2ETestScope?
    @ObservationIgnored private let pendingCredentialDeletionStore: (any V2PendingCredentialDeletionStoring)?
    @ObservationIgnored private weak var remoteNotificationRegistrar: (any V2RemoteNotificationRegistering)?
    @ObservationIgnored private var realtimeRuntime: V2ClientRuntime?
    @ObservationIgnored private var backgroundSync: V2BackgroundSyncRunner?
    @ObservationIgnored private var realtimeTask: Task<Void, Never>?
    @ObservationIgnored private var messageSearchIndexTask: Task<Void, Never>?
    @ObservationIgnored private var messageSearchLocalStore: GRDBV2LocalSyncStore?
    @ObservationIgnored private var realtimeAttemptGate = V2RealtimeAttemptGate()
    @ObservationIgnored private var authenticationAttemptGate = V2AuthenticationAttemptGate()
    @ObservationIgnored private var signOutAttemptGate = V2SignOutAttemptGate()
    @ObservationIgnored private var isApplicationActive = false
    @ObservationIgnored private let restoration = V2SessionRestoration()
    @ObservationIgnored private let authenticationObserver = V2AuthenticationStateObserver()

    private(set) var route: Route
    private(set) var authenticationMessage: String?
    @ObservationIgnored private var accountAttachmentUploader: V2ForegroundConversationAttachmentUploader?
    @ObservationIgnored private var accountAttachmentStager: V2FileConversationAttachmentStager?
    @ObservationIgnored private var mediaCacheDownloader: V2ForegroundConversationMediaDownloader?
    private(set) var mediaThumbnailCache: V2LocalMediaThumbnailCache? = nil
    private(set) var conversationStore: V2ConversationListStore?
    private(set) var contactsStore: V2ContactsStore?
    private(set) var privacySettingsStore: V2PrivacySettingsStore?
    private(set) var userBlockSettingsStore: V2UserBlockSettingsStore?
    private(set) var publicIdentitySettingsStore: V2PublicIdentitySettingsStore?
    private(set) var pushWakeSettingsStore: V2PushWakeSettingsStore?
    private(set) var deviceSessionsStore: V2DeviceSessionsStore?
    private(set) var groupInvitationStore: V2GroupInvitationStore?

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
            deviceRegistrationStore = nil
            deviceRevocationStore = nil
            issuedCredentialRecovery = nil
            deviceRevocationRunner = nil
            registrationCancellationRunner = nil
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
            deviceSessionsStore = nil
            groupInvitationStore = nil
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
            #if DEBUG
            if startupMode.usesLiveLocalAccountE2ETestScope && startupMode != .uiTestingLiveLocalAccountCleanup {
                try V2LegacyRegistrationE2EFixture.installIfRequested(baseService: configuration.keychainService,
                    scope: liveLocalAccountE2ETestScope, arguments: ProcessInfo.processInfo.arguments)
            }
            #endif
            let refreshTransport = try V2HTTPDeviceCredentialAuthTransport(
                refreshEndpoint: configuration.endpoint("v2/device-credentials/refresh")
            )
            let credentialStore = V2KeychainCredentialStore(service: keychainService)
            let revocationStore = V2DeviceRevocationStore(service: keychainService)
            let registrationStore = V2DeviceRegistrationStore(service: keychainService)
            let cancellationClient = try V2HTTPDeviceRegistrationCancellationClient(endpoint: configuration.endpoint("v2/device-credentials/cancel-registration"))
            let authSession = V2AuthSession(credentialStore: credentialStore, transport: refreshTransport,
                revocationScheduler: revocationStore)
            let databaseURL = try Self.databaseURL(
                fileName: liveLocalAccountE2ETestScope?.databaseFileName
            )
            let revocationClient = try V2HTTPDeviceRevocationClient(endpoint: configuration.endpoint("v2/device-credentials/revoke"))
            self.configuration = configuration
            self.authSession = authSession
            self.deviceRevocationStore = revocationStore
            self.issuedCredentialRecovery = V2IssuedCredentialRecoveryStore(service: keychainService, revocations: revocationStore)
            self.deviceRevocationRunner = V2DeviceRevocationRunner(store: revocationStore,
                client: revocationClient)
            registrationCancellationRunner = V2DeviceRegistrationCancellationRunner(store: registrationStore, client: cancellationClient)
            localKeychainService = keychainService
            localDatabaseURL = databaseURL
            self.liveLocalAccountE2ETestScope = liveLocalAccountE2ETestScope
            pendingCredentialDeletionStore = V2FilePendingCredentialDeletionStore(
                url: V2FilePendingCredentialDeletionStore.fileURL(databaseURL: databaseURL, legacyKey: keychainService + ".pending-credential-deletion"),
                legacyKey: keychainService + ".pending-credential-deletion"
            )
            self.bootstrapper = V2ClientSessionBootstrapper(
                authSession: authSession,
                localStoreBootstrapper: .init(bindingStore: V2KeychainInstallationBindingStore(service: keychainService)),
                databaseURL: databaseURL,
                accountStorageRoot: databaseURL.appendingPathExtension("accounts")
            )
            deviceRegistrationStore = registrationStore
            route = .launching
            authenticationMessage = nil
            conversationStore = nil
            contactsStore = nil
            privacySettingsStore = nil
            userBlockSettingsStore = nil
            publicIdentitySettingsStore = nil
            pushWakeSettingsStore = nil
            deviceSessionsStore = nil
            groupInvitationStore = nil
            realtimeRuntime = nil
            realtimeTask = nil
            messageSearchIndexTask = nil
        } catch {
            configuration = nil
            authSession = nil
            bootstrapper = nil
            deviceRegistrationStore = nil
            deviceRevocationStore = nil
            issuedCredentialRecovery = nil
            deviceRevocationRunner = nil
            registrationCancellationRunner = nil
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
            deviceSessionsStore = nil
            groupInvitationStore = nil
            realtimeRuntime = nil
            realtimeTask = nil
        }
    }

    func restore() async {
        do { try await restore(until: nil) } catch { /* A later scene/Push may retry. */ }
    }

    private func restore(until deadline: ContinuousClock.Instant?) async throws {
        guard route == .launching else { return }
        try await restoration.run(until: deadline) { [weak self] in await self?.performRestore() }
    }

    private func performRestore() async {
        if startupMode == .uiTestingLiveLocalAccountCleanup {
            await cleanupLiveLocalAccountE2ETestScope()
            return
        }
        if !recoveredIssuedCredentials, let issuedCredentialRecovery, let localKeychainService {
            do {
                let record: V2AuthCredentialRecord?
                do { record = try await V2KeychainCredentialStore(service: localKeychainService).load() }
                catch V2CredentialStoreError.malformedRecord { record = nil }
                catch V2CredentialStoreError.permanentlyInvalidated { record = nil }
                try await deviceRegistrationStore?.recoverUnclaimed(ownedBy: record)
                try await issuedCredentialRecovery.recoverUnclaimed(ownedBy: record)
                recoveredIssuedCredentials = true
            } catch V2CredentialStoreError.unavailable, V2IssuedCredentialRecoveryError.unavailable, V2DeviceCredentialRegistrationOperationStoreError.unavailable {
                route = .protectedDataUnavailable
                return
            } catch {
                route = .unavailable(message: "无法恢复待确认的登录结果，请重新打开应用后重试。")
                return
            }
        }
        guard startupMode.restoresPersistedSession else {
            route = .signedOut
            authenticationMessage = nil
            return
        }
        if await finishPendingCredentialDeletionIfNeeded() {
            return
        }
        guard !Task.isCancelled, !signOutAttemptGate.isInFlight, let bootstrapper else { return }
        let attemptGeneration = authenticationAttemptGate.begin()
        route = .launching
        authenticationMessage = nil
        do {
            let localStore = try await bootstrapper.openEstablishedSession()
            try Task.checkCancellation()
            guard authenticationAttemptGate.matchesCurrentGeneration(attemptGeneration) else { return }
            try await activate(localStore: localStore, authenticationAttemptGeneration: attemptGeneration)
        } catch V2ClientSessionBootstrapError.authenticationRequired, V2AuthSessionError.unauthenticated {
            guard authenticationAttemptGate.matchesCurrentGeneration(attemptGeneration) else { return }
            route = .signedOut
        } catch V2ClientSessionBootstrapError.credentialsUnavailable, V2AuthSessionError.credentialsUnavailable {
            guard authenticationAttemptGate.matchesCurrentGeneration(attemptGeneration) else { return }
            route = .protectedDataUnavailable
        } catch is CancellationError {
            return
        } catch {
            guard authenticationAttemptGate.matchesCurrentGeneration(attemptGeneration) else { return }
            route = .unavailable(message: "无法打开本地 V2 数据。")
        }
    }

    /// 只重试明确可恢复的受保护数据状态。
    ///
    /// 常规的已登出流程绝不会仅仅因为此前一次登出删除遇到了临时锁定的 Keychain
    /// 就恢复凭据。
    func retryProtectedDataAccess() async {
        guard route == .protectedDataUnavailable else { return }
        // Claim the state before awaiting the actor. This coalesces a user
        // tapping retry with a simultaneous scene-activation callback.
        route = .launching
        await authSession?.retryCredentialStoreAccess()
        await restore()
    }

    func authenticatePassword(accountHandle: String, password: String, mode: PasswordMode, publicHandle: String? = nil, displayName: String? = nil) async {
        guard route == .signedOut, !signOutAttemptGate.isInFlight else { return }
        guard let configuration,
              let bootstrapper,
              let deviceRegistrationStore,
              let issuedCredentialRecovery,
              let authSession
        else { return }
        let attemptGeneration = beginAuthenticationAttempt()
        do {
            let expectedEpoch = await authSession.currentEpoch()
            guard authenticationAttemptGate.matchesCurrentGeneration(attemptGeneration) else { return }
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
            let registration = try await deviceRegistrationStore.prepare(accountHandle: accountHandle)
            try Task.checkCancellation()
            guard authenticationAttemptGate.matchesCurrentGeneration(attemptGeneration) else { return }
            let issuer = try V2HTTPAccountAssertionDeviceCredentialProvider(
                issueEndpoint: configuration.endpoint("v2/device-credentials"),
                assertionProvider: registration.recoveringLegacyRegistration(using: accountProvider,
                    client: try V2HTTPLegacyRegistrationCancellationClient(endpoint: configuration.endpoint("v2/device-credentials/cancel-legacy-registration"))),
                deviceIdentityProvider: registration,
                operationStore: registration,
                recovery: issuedCredentialRecovery,
                registrationMetadata: Self.deviceRegistrationMetadata()
            )
            let localStore = try await bootstrapper.establishSession(using: issuer, ifCurrent: expectedEpoch)
            try Task.checkCancellation()
            guard authenticationAttemptGate.matchesCurrentGeneration(attemptGeneration) else { return }
            try await activate(localStore: localStore, authenticationAttemptGeneration: attemptGeneration)
        } catch V2ClientSessionBootstrapError.credentialIssueRecoveryPending {
            deviceRevocationNeedsRetry = true
            guard authenticationAttemptGate.matchesCurrentGeneration(attemptGeneration) else { return }
            route = .signedOut
            authenticationMessage = "登录结果暂时无法完成交接，请解锁并重新打开应用后重试。"
        } catch is V2IssuedCredentialRecoveryError {
            deviceRevocationNeedsRetry = true
            guard authenticationAttemptGate.matchesCurrentGeneration(attemptGeneration) else { return }
            route = .signedOut
            authenticationMessage = "登录结果暂时无法完成交接，请解锁并重新打开应用后重试。"
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
        } catch let error as V2LegacyRegistrationCancellationError {
            guard authenticationAttemptGate.matchesCurrentGeneration(attemptGeneration) else { return }
            route = .signedOut
            switch error {
            case .authenticationRequired:
                authenticationMessage = "登录验证已过期，请重新输入密码后重试。"
            case .targetUnavailable, .conflict:
                authenticationMessage = "旧登录记录暂时无法核实，已保留记录，请稍后重试。"
            case .capacityExceeded:
                authenticationMessage = "旧登录记录已达到服务端上限，暂时无法继续登录。"
            default:
                authenticationMessage = "旧登录尚未完成清理，记录已保留，请稍后重新登录。"
            }
        } catch V2AccountAssertionCredentialProviderError.deviceIdentityUnavailable {
            guard authenticationAttemptGate.matchesCurrentGeneration(attemptGeneration) else { return }
            route = .signedOut
            authenticationMessage = "受保护凭据暂不可用，请解锁设备后重试。"
        } catch V2AccountAssertionCredentialProviderError.registrationExpired {
            guard authenticationAttemptGate.matchesCurrentGeneration(attemptGeneration) else { return }
            route = .signedOut
            authenticationMessage = "本次登录已超时，请重新提交登录。"
        } catch V2AccountAssertionCredentialProviderError.registrationOperationUnavailable {
            guard authenticationAttemptGate.matchesCurrentGeneration(attemptGeneration) else { return }
            route = .signedOut
            authenticationMessage = "无法保存本次设备注册，请稍后重试。"
        } catch is V2DeviceCredentialRegistrationOperationStoreError {
            guard authenticationAttemptGate.matchesCurrentGeneration(attemptGeneration) else { return }
            route = .signedOut
            authenticationMessage = "无法保存本次设备注册，请解锁设备后重试。"
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
        _ = authenticationAttemptGate.begin()
        route = .launching
        groupInvitationStore?.invalidate()
        guard let authSession, let pendingCredentialDeletionStore else {
            await discardAuthenticatedPresentation(route: .signedOut)
            return
        }
        do {
            // Commit intent before credential deletion. Failure keeps the
            // credential and the pending UI so a later retry can commit it.
            try await pendingCredentialDeletionStore.markPending()
            await authSession.invalidateOutstandingWork()
            try Task.checkCancellation()
            try await completeLocalSignOut(authSession: authSession, marker: pendingCredentialDeletionStore)
        } catch {
            await discardAuthenticatedPresentation(route: .signOutPendingCredentialDeletion)
        }
    }

    /// 在受保护数据可用之后，尝试完成此前已持久化的登出收尾。
    ///
    /// 它绝不会打开已认证会话。
    func retryPendingCredentialDeletion() async {
        guard route == .signOutPendingCredentialDeletion, signOutAttemptGate.begin() else { return }
        defer { signOutAttemptGate.finish() }
        _ = await finishPendingCredentialDeletionIfNeeded()
    }

    private func finishPendingCredentialDeletionIfNeeded() async -> Bool {
        guard let pendingCredentialDeletionStore else { return false }
        let retryingFailedWrite = route == .signOutPendingCredentialDeletion
        route = .launching
        do {
            let persisted = try await pendingCredentialDeletionStore.isPending()
            guard persisted || retryingFailedWrite else { return false }
            // Also retries an earlier write failure retained by the UI.
            try await pendingCredentialDeletionStore.markPending()
        } catch {
            await discardAuthenticatedPresentation(route: .signOutPendingCredentialDeletion)
            return true
        }
        guard let authSession else {
            route = .unavailable(message: "V2 账户服务配置无效。")
            return true
        }
        do {
            try Task.checkCancellation()
            try await completeLocalSignOut(authSession: authSession, marker: pendingCredentialDeletionStore)
        } catch {
            await discardAuthenticatedPresentation(route: .signOutPendingCredentialDeletion)
        }
        return true
    }

    private func completeLocalSignOut(authSession: V2AuthSession, marker: any V2PendingCredentialDeletionStoring) async throws {
        await discardAuthenticatedPresentation(route: .signOutPendingCredentialDeletion)
        guard route == .signOutPendingCredentialDeletion else { return }
        try await authSession.handleTerminalRejection()
        try await deviceRegistrationStore?.discardPendingRegistrations()
        // Keep intent if closing the captured local store failed. A cold
        // start must still finish cleanup when credentials are already gone.
        guard route == .signOutPendingCredentialDeletion else { return }
        route = .launching
        try await marker.clearPending()
        route = .signedOut
    }

    /// 撤下账号界面，停止任务并关闭捕获的本地存储。
    ///
    /// 先隐藏页面，再依次等待观察、运行时、索引和媒体任务；上传结束后才删暂存。
    /// 清理失败进入不可用 route，不伪装成已经完成。
    ///
    /// - Parameter nextRoute: 全部本地收尾成功后要进入的 route。
    private func discardAuthenticatedPresentation(route nextRoute: Route) async {
        authenticationObserver.stop()
        groupInvitationStore?.invalidate()
        let thumbnails = mediaThumbnailCache
        mediaThumbnailCache = nil
        let indexer = messageSearchIndexTask
        let localStore = messageSearchLocalStore
        let pushSettings = pushWakeSettingsStore
        indexer?.cancel()
        messageSearchIndexTask = nil
        messageSearchLocalStore = nil
        // Hide account-owned views before awaits; their late results cannot
        // be presented in the next account's view hierarchy.
        route = .launching
        conversationStore = nil
        contactsStore = nil
        privacySettingsStore = nil
        userBlockSettingsStore = nil
        publicIdentitySettingsStore = nil
        pushWakeSettingsStore = nil
        deviceSessionsStore = nil
        groupInvitationStore = nil
        await thumbnails?.close()
        await pushSettings?.stop()
        await backgroundSync?.stop()
        backgroundSync = nil
        await stopRealtime()
        realtimeRuntime = nil
        await indexer?.value
        do {
            try await mediaCacheDownloader?.close()
            mediaCacheDownloader = nil
            await accountAttachmentUploader?.close()
            accountAttachmentUploader = nil
            try await accountAttachmentStager?.close()
            accountAttachmentStager = nil
            if let localStore { try await bootstrapper?.closeLocalStore(localStore) }
            authenticationMessage = nil
            route = nextRoute
        } catch {
            route = .unavailable(message: "无法关闭本地数据，请重新启动应用后重试。")
        }
    }

    private static func deviceRegistrationMetadata() -> V2ClientDeviceRegistrationMetadata {
        .init(deviceName: UIDevice.current.name, platform: UIDevice.current.model)
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
        guard let configuration, let authSession, let localKeychainService else {
            throw V2AppConfigurationError.invalidRealtimeEndpoint
        }
        guard let scope = try await bootstrapper?.storageScope(for: localStore) else {
            throw V2AccountLocalStoreError.staleStore
        }
        try Self.applyDatabaseStoragePolicy(databaseURL: scope.database.primary)
        let credentials = try await authSession.realtimeCredentials()
        let userID = credentials.userID
        guard let authEpoch = credentials.sessionEpoch else { throw V2AuthSessionError.sessionInvalidated }
        guard scope.accountID == userID else { throw V2AccountLocalStoreError.staleStore }
        try Task.checkCancellation()
        try await mediaCacheDownloader?.close()
        mediaCacheDownloader = nil
        await accountAttachmentUploader?.close()
        accountAttachmentUploader = nil
        try await accountAttachmentStager?.close()
        accountAttachmentStager = nil
        try Task.checkCancellation()
        guard authenticationAttemptGeneration.map(authenticationAttemptGate.matchesCurrentGeneration) ?? true else { return }
        try await authSession.requireAuthenticatedEpoch(authEpoch)
        let realtime = try V2AppRealtimeRuntime(
            configuration: configuration,
            authSession: authSession,
            authEpoch: authEpoch,
            localStore: localStore,
            mediaCacheDirectory: scope.mediaCacheDirectory
        )
        let attachmentStager = try? V2FileConversationAttachmentStager(directory: scope.mediaStagingDirectory)
        await attachmentStager?.discardOrphanedStagedFiles()
        try Task.checkCancellation()
        await realtime.mediaCacheMaintenance.performMaintenance()
        try Task.checkCancellation()
        let accountHTTP = V2SessionHTTPAuthorization(session: authSession, epoch: authEpoch)
        let publicIdentityDirectory = try V2HTTPPublicIdentityDirectory(
            endpoint: configuration.endpoint("v2/public-identities/resolve"),
            credentials: accountHTTP, transport: accountHTTP
        )
        let conversationDataSource = V2GRDBConversationDataSource(localStore: localStore)
        let contactsDataSource = V2GRDBContactsDataSource(
            localStore: localStore,
            profiles: realtime.profileRepository,
            currentUserID: userID
        )
        let conversationEnvironment = V2ConversationFeatureEnvironment(
            userID: userID.rawValue,
            projections: .init(
                dataSource: conversationDataSource,
                messageSearcher: conversationDataSource
            ),
            messages: .init(
                sender: realtime.sender,
                withdrawer: realtime.messageWithdrawer,
                reactionChanger: realtime.messageReactionChanger,
                editor: realtime.messageEditor,
                readReceiptReporter: realtime.readReceiptReporter,
                stateChanger: realtime.conversationStateChanger,
                favoriter: realtime.messageFavoriter,
                groupPinner: realtime.groupMessagePinner,
                forwarder: realtime.messageForwarder
            ),
            groups: .init(
                announcementManager: realtime.groupAnnouncementManager,
                memberRoleChanger: realtime.groupMemberRoleChanger,
                rolePolicyChanger: realtime.groupRolePolicyChanger,
                readReceiptReader: realtime.groupReadReceiptReader,
                conversationCreator: realtime.groupConversationCreator,
                memberDirectory: realtime.groupMemberDirectory,
                membershipChanger: realtime.groupMembershipChanger,
                memberMuter: realtime.groupMemberMuter,
                moderatedMemberRemover: realtime.moderatedGroupMemberRemover
            ),
            discovery: .init(
                directConversationOpener: realtime.directConversationOpener,
                publicIdentityResolver: publicIdentityDirectory
            ),
            media: .init(
                attachmentStager: attachmentStager,
                attachmentUploader: realtime.attachmentUploader,
                downloader: realtime.mediaDownloader
            ),
            runtime: .init(
                liveActivity: realtime.conversationLiveActivity,
                projectionChangeNotifier: realtime.projectionChangeNotifier,
                activeHybridGroupSynchronizer: realtime.activeHybridGroupSynchronizer,
                roomSubscriptions: realtime.roomSubscriptions
            )
        )
        let conversations = V2ConversationListStore(environment: conversationEnvironment)
        let privacySettings = V2PrivacySettingsStore(
            reader: V2GRDBStrangerMessagePreferenceDataSource(localStore: localStore),
            updater: realtime.strangerMessagePreferenceUpdater,
            userAddReader: V2GRDBUserAddPreferenceDataSource(localStore: localStore),
            userAddUpdater: realtime.userAddPreferenceUpdater,
            readReceiptUpdater: realtime.readReceiptPreferenceUpdater,
            readReceiptReader: V2GRDBReadReceiptPreferenceDataSource(localStore: localStore),
            liveActivityUpdater: realtime.liveActivityPreferenceUpdater,
            liveActivityReader: realtime.liveActivityPreferenceReader,
            projectionChangeNotifier: realtime.projectionChangeNotifier
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
        let publicIdentitySettings = V2PublicIdentitySettingsStore(
            manager: try V2HTTPOwnProfileClient(
                endpoint: configuration.endpoint("v2/profile/me"),
                credentials: accountHTTP, transport: accountHTTP
            ),
            attachmentStager: attachmentStager,
            attachmentUploader: realtime.attachmentUploader,
            mediaDownloader: realtime.mediaDownloader
        )
        let deviceSessions = try V2DeviceSessionsStore(
            manager: V2HTTPDeviceSessionClient(
                endpoint: configuration.endpoint("v2/devices"),
                credentials: accountHTTP, transport: accountHTTP
            )
        )
        let groupInvitations = V2GroupInvitationStore(
            client: try V2HTTPGroupInvitationClient(
                baseURL: configuration.accountBaseURL,
                credentials: accountHTTP, transport: accountHTTP
            )
        )
        let pushWakeSettings: V2PushWakeSettingsStore?
        if let remoteNotificationRegistrar {
            guard authenticationAttemptGeneration.map(authenticationAttemptGate.matchesCurrentGeneration) ?? true else { return }
            try await authSession.requireAuthenticatedEpoch(authEpoch)
            await pushWakeSettingsStore?.stop()
            let preferences = V2UserDefaultsPushWakePreferenceStore(key: localKeychainService + ".push-wake-enabled." + userID.rawValue)
            let initialPreference = preferences.isEnabled()
            let pushScope = try await localStore.pushIntentScope(deviceID: credentials.deviceID)
            guard authenticationAttemptGeneration.map(authenticationAttemptGate.matchesCurrentGeneration) ?? true else { return }
            try await authSession.requireAuthenticatedEpoch(authEpoch)
            let reconciler = try await V2PushIntentReconciler.activate(
                store: localStore,
                transport: V2HTTPPushEndpointClient(endpoint: configuration.pushEndpoint, session: authSession, epoch: authEpoch),
                scope: pushScope, initialPreference: initialPreference
            )
            guard authenticationAttemptGeneration.map(authenticationAttemptGate.matchesCurrentGeneration) ?? true else {
                await reconciler.stop(); return
            }
            do { try await authSession.requireAuthenticatedEpoch(authEpoch); try Task.checkCancellation() }
            catch { await reconciler.stop(); throw error }
            pushWakeSettings = .init(reconciler: reconciler, preferences: preferences, remoteNotificationRegistrar: remoteNotificationRegistrar, environment: configuration.pushEndpointEnvironment)
        } else { pushWakeSettings = nil }
        guard authenticationAttemptGeneration.map(authenticationAttemptGate.matchesCurrentGeneration) ?? true else { return }
        await stopRealtime()
        let previousThumbnails = mediaThumbnailCache
        mediaThumbnailCache = nil
        await previousThumbnails?.close()
        try Task.checkCancellation()
        guard authenticationAttemptGeneration.map(authenticationAttemptGate.matchesCurrentGeneration) ?? true else { return }
        try await authSession.requireAuthenticatedEpoch(authEpoch)
        try Task.checkCancellation()
        guard authenticationAttemptGeneration.map(authenticationAttemptGate.matchesCurrentGeneration) ?? true else { return }
        accountAttachmentUploader = realtime.attachmentUploader
        accountAttachmentStager = attachmentStager
        mediaCacheDownloader = realtime.mediaCacheMaintenance
        mediaThumbnailCache = V2LocalMediaThumbnailCache(directory: scope.directory)
        realtimeRuntime = realtime.runtime
        backgroundSync = realtime.backgroundSync
        conversationStore = conversations
        contactsStore = contacts
        privacySettingsStore = privacySettings
        userBlockSettingsStore = userBlockSettings
        publicIdentitySettingsStore = publicIdentitySettings
        pushWakeSettingsStore = pushWakeSettings
        deviceSessionsStore = deviceSessions
        groupInvitationStore = groupInvitations
        messageSearchLocalStore = localStore
        route = .signedIn(userID: userID.rawValue)
        authenticationObserver.start(session: authSession, epoch: authEpoch) { [weak self] change in
            await self?.authenticationStateDidChange(change)
        }
        guard isApplicationActive else { return }
        startMessageSearchIndexing(localStore: localStore)
        await conversations.refresh()
        guard authenticationAttemptGeneration.map(authenticationAttemptGate.matchesCurrentGeneration) ?? true else { return }
        await pushWakeSettings?.activate()
        guard authenticationAttemptGeneration.map(authenticationAttemptGate.matchesCurrentGeneration) ?? true else { return }
        startRealtimeIfApplicationActive(runtime: realtime.runtime, conversations: conversations)
    }

    private func authenticationStateDidChange(_ change: V2AuthenticationStateObserver.Change) async {
        guard case .signedIn = route, signOutAttemptGate.begin() else { return }
        defer { signOutAttemptGate.finish() }
        _ = authenticationAttemptGate.begin()
        route = .launching
        let destination: Route
        switch change {
        case .authenticationRequired, .superseded:
            // The event belongs to the old observed epoch. Never delete or
            // revoke whatever credential is now current in the auth owner.
            destination = .signedOut
        case .protectedDataUnavailable:
            destination = .protectedDataUnavailable
        case .credentialDeletionPending:
            do { try await pendingCredentialDeletionStore?.markPending() }
            catch { /* The pending route retries the failed durable write. */ }
            destination = .signOutPendingCredentialDeletion
        }
        await discardAuthenticatedPresentation(route: destination)
    }

    /// 仅在 iOS 确实将场景切入后台之后，才停止前台实时连接。
    ///
    /// `inactive` 刻意不被视为进入后台，因为系统权限弹窗覆盖在 App 之上时也会出现该状态。
    func applicationDidEnterBackground() async {
        isApplicationActive = false
        deviceRevocationTask?.cancel()
        deviceRevocationObservation?.cancel()
        registrationCancellationTask?.cancel()
        registrationCancellationObservation?.cancel()
        messageSearchIndexTask?.cancel()
        messageSearchIndexTask = nil
        await stopRealtime()
    }

    /// 在 App 回到前台后，复用已登录的本地投影并显式发起一次新的实时尝试。
    func applicationDidBecomeActive() async {
        isApplicationActive = true
        startDeviceRevocationObservationIfActive()
        startDeviceRevocationIfActive()
        startRegistrationCancellationObservationIfActive()
        startRegistrationCancellationIfActive()
        await backgroundSync?.stop()
        if route == .launching { await restore() }
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
        if let messageSearchLocalStore {
            startMessageSearchIndexing(localStore: messageSearchLocalStore)
        }
        let activationGeneration = authenticationAttemptGate.generation
        await conversationStore.refresh()
        guard isApplicationActive, authenticationAttemptGate.matchesCurrentGeneration(activationGeneration) else { return }
        await pushWakeSettingsStore?.activate()
        guard isApplicationActive, authenticationAttemptGate.matchesCurrentGeneration(activationGeneration), case .signedIn = route else { return }
        startRealtimeIfApplicationActive(runtime: realtimeRuntime, conversations: conversationStore)
    }

    /// 保留任务，直到其真实的网络在途请求排空。
    ///
    /// 若取消期间发生前台切换，只会在旧任务结束后才重启。
    private func startDeviceRevocationIfActive() {
        guard isApplicationActive, deviceRevocationTask == nil, let deviceRevocationRunner else { return }
        deviceRevocationNeedsRetry = false
        let recovery = issuedCredentialRecovery
        deviceRevocationTask = Task { [weak self, deviceRevocationRunner, recovery] in
            var cancelled = false
            do {
                try await recovery?.drainAbandoned()
                try await deviceRevocationRunner.run()
            }
            catch is CancellationError { cancelled = true }
            catch { self?.deviceRevocationNeedsRetry = true }
            guard let self else { return }
            self.deviceRevocationTask = nil
            if cancelled { self.startDeviceRevocationIfActive() }
        }
    }

    private func startDeviceRevocationObservationIfActive() {
        guard isApplicationActive, deviceRevocationObservation == nil, let deviceRevocationStore else { return }
        deviceRevocationObservation = Task { [weak self, deviceRevocationStore] in
            do {
                for try await status in await deviceRevocationStore.statusUpdates() {
                    try Task.checkCancellation()
                    self?.revocationObservationState = .known(status)
                }
            } catch is CancellationError { }
            catch { if !Task.isCancelled { self?.revocationObservationState = .unavailable } }
            guard let self else { return }
            self.deviceRevocationObservation = nil
            if Task.isCancelled { self.startDeviceRevocationObservationIfActive() }
        }
    }

    private func startRegistrationCancellationIfActive() {
        guard isApplicationActive, registrationCancellationTask == nil, let registrationCancellationRunner else { return }
        registrationCancellationNeedsRetry = false
        registrationCancellationTask = Task { [weak self, registrationCancellationRunner] in
            var cancelled = false
            do { try await registrationCancellationRunner.run() }
            catch is CancellationError { cancelled = true }
            catch { self?.registrationCancellationNeedsRetry = true }
            guard let self else { return }
            self.registrationCancellationTask = nil
            if cancelled { self.startRegistrationCancellationIfActive() }
        }
    }

    private func startRegistrationCancellationObservationIfActive() {
        guard isApplicationActive, registrationCancellationObservation == nil, let deviceRegistrationStore else { return }
        registrationCancellationObservation = Task { [weak self, deviceRegistrationStore] in
            do {
                for try await status in await deviceRegistrationStore.cancellationStatusUpdates() {
                    try Task.checkCancellation()
                    self?.registrationCancellationObservationState = .known(status)
                }
            } catch is CancellationError { }
            catch { if !Task.isCancelled { self?.registrationCancellationObservationState = .unavailable } }
            guard let self else { return }
            self.registrationCancellationObservation = nil
            if Task.isCancelled { self.startRegistrationCancellationObservationIfActive() }
        }
    }

    func retryDeviceRevocation() async {
        guard !revocationRetrying, let deviceRevocationStore else { return }
        revocationRetrying = true
        defer { revocationRetrying = false }
        do {
            try await issuedCredentialRecovery?.drainAbandoned()
            try await deviceRevocationStore.retryPaused()
            try await deviceRegistrationStore?.retryPausedCancellations()
            try Task.checkCancellation()
            // A successful no-op retry may not emit a queue notification.
            // Re-subscribe for a fresh snapshot after a prior read failure.
            let observation = deviceRevocationObservation
            observation?.cancel()
            await observation?.value
            try Task.checkCancellation()
            startDeviceRevocationObservationIfActive()
            startDeviceRevocationIfActive()
            let cancellationObservation = registrationCancellationObservation
            cancellationObservation?.cancel()
            await cancellationObservation?.value
            try Task.checkCancellation()
            startRegistrationCancellationObservationIfActive()
            startRegistrationCancellationIfActive()
        } catch is CancellationError { }
        catch { revocationObservationState = .unavailable }
    }

    deinit {
        deviceRevocationTask?.cancel(); deviceRevocationObservation?.cancel()
        registrationCancellationTask?.cancel(); registrationCancellationObservation?.cancel()
    }

    private func startMessageSearchIndexing(localStore: GRDBV2LocalSyncStore) {
        messageSearchIndexTask?.cancel()
        messageSearchIndexTask = Task { [localStore] in
            do {
                try await localStore.runMessageSearchIndexer()
            } catch is CancellationError {
                return
            } catch {
                // The search UI reports persistent state. A derived-index
                // failure must never interrupt authenticated messaging.
            }
        }
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
        let deadline = ContinuousClock.now.advanced(by: .seconds(25))
        do { try await restore(until: deadline) } catch { return .failed }
        guard case .signedIn = route,
              let backgroundSync
        else { return .noData }
        do {
            let result = try await backgroundSync.run(until: deadline)
            return result.didCommitNewRecords ? .newData : .noData
        } catch is CancellationError {
            return .noData
        } catch V2RealtimeSessionCoordinatorError.authenticationRequired {
            // The coordinator already notified the auth owner. Its observer
            // owns UI/logout cleanup; never add that work to the fetch budget.
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
            try await issuedCredentialRecovery?.recoverUnclaimed(ownedBy: nil)
            if let deviceRevocationStore {
                for job in try await deviceRevocationStore.jobs() { try await deviceRevocationStore.complete(job) }
            }
            try await deviceRegistrationStore?.discardPendingRegistrations()
            if let deviceRegistrationStore {
                for cancellation in try await deviceRegistrationStore.pendingCancellations() {
                    try await deviceRegistrationStore.completeCancellation(cancellation)
                }
            }
            try await V2KeychainDeviceCredentialRegistrationOperationStore(
                service: localKeychainService
            ).delete()
            #if DEBUG
            try V2LegacyRegistrationE2EFixture.remove(baseService: configuration.keychainService, scope: liveLocalAccountE2ETestScope)
            #endif
            try await V2KeychainInstallationBindingStore(service: localKeychainService).delete()
            try await pendingCredentialDeletionStore?.clearPending()
            try Self.eraseDatabaseArtifacts(at: localDatabaseURL)
            let deletionMarker = V2FilePendingCredentialDeletionStore.fileURL(databaseURL: localDatabaseURL, legacyKey: localKeychainService + ".pending-credential-deletion")
            if FileManager.default.fileExists(atPath: deletionMarker.path) { try FileManager.default.removeItem(at: deletionMarker) }
            let scopedRoot = localDatabaseURL.appendingPathExtension("accounts")
            if FileManager.default.fileExists(atPath: scopedRoot.path) { try FileManager.default.removeItem(at: scopedRoot) }
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

    /// 应用数据库存储策略。
    ///
    /// SQLite 可能主数据库文件之后才创建 WAL/SHM 文件；
    /// 因此每次打开之后都要重新应用并校验策略，
    /// 而不是假设目录级状态已覆盖所有文件系统实现。
    ///
    /// - Parameters:
    ///   - database: 主数据库文件地址。
    ///   - fileManager: 使用的文件管理器。
    /// - Throws: 策略应用或校验失败时抛出。
    private static func applyDatabaseStoragePolicy(databaseURL database: URL, fileManager: FileManager = .default) throws {
        for url in V2LocalDatabaseArtifacts(primary: database).files where fileManager.fileExists(atPath: url.path) {
            try V2DeviceLocalStoragePolicy.applyToManagedFile(url, fileManager: fileManager)
        }
    }

    private static func eraseDatabaseArtifacts(at databaseURL: URL, fileManager: FileManager = .default) throws {
        for artifact in V2LocalDatabaseArtifacts(primary: databaseURL).files where fileManager.fileExists(atPath: artifact.path) {
            try fileManager.removeItem(at: artifact)
        }
    }
}
