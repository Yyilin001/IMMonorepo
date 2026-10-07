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

/// Injects local trust/storage ports without constructing platform Keychain or remote cleanup runners.
struct V2AppLocalRestorationDependencies {
    let configuration: V2AppConfiguration
    let authSession: V2AuthSession
    let bootstrapper: V2ClientSessionBootstrapper
    let exitMarker: any V2PendingCredentialDeletionStoring
    let databaseURL: URL
    let serviceIdentifier: String
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
        case localReadOnly(userID: String)
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

    enum AccountAccessMode: Equatable { case blocked, localReadOnly, authenticated }
    private(set) var accountAccessMode: AccountAccessMode = .blocked
    private(set) var offlinePresentation: V2OfflineProjectionPresentation?
    @ObservationIgnored private var offlinePermit: V2OfflineReadBootstrap?
    @ObservationIgnored private var offlineLocalStore: GRDBV2LocalSyncStore?
    @ObservationIgnored private var offlineUpgradeTask: (id: UUID, task: Task<Void, Never>)?

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
    private(set) var realtimeCoverage: V2AppRealtimeCoverage?

    @ObservationIgnored private var accountRuntime: V2AccountRuntime?
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
    @ObservationIgnored private var accountProfileRepository: V2ProfileRepository?
    @ObservationIgnored private var mediaCacheDownloader: V2ForegroundConversationMediaDownloader?
    private(set) var mediaThumbnailCache: V2LocalMediaThumbnailCache? = nil
    private(set) var avatarPipeline: V2AvatarPipeline? = nil
    @ObservationIgnored private var avatarInvalidationTask: Task<Void, Never>?
    @ObservationIgnored private var accountActivityObservation: Task<Void, Never>?
    @ObservationIgnored private var networkDiagnosticsObservation: Task<Void, Never>?
    private(set) var accountWorkPaused = false
    private(set) var isResumingAccountWork = false
    private(set) var conversationStore: V2ConversationListStore?
    private(set) var contactsStore: V2ContactsStore?
    private(set) var privacySettingsStore: V2PrivacySettingsStore?
    private(set) var userBlockSettingsStore: V2UserBlockSettingsStore?
    private(set) var publicIdentitySettingsStore: V2PublicIdentitySettingsStore?
    private(set) var pushWakeSettingsStore: V2PushWakeSettingsStore?
    private(set) var deviceSessionsStore: V2DeviceSessionsStore?
    private(set) var groupInvitationStore: V2GroupInvitationStore?
    private(set) var pendingGroupAvatarsStore: V2PendingGroupAvatarsStore?

    init(
        startupMode: StartupMode = .production,
        liveLocalAccountE2ETestScope: V2LiveLocalAccountE2ETestScope? = nil,
        debugForcesUnavailableRealtimeForLiveLocalAccountE2E: Bool = false,
        remoteNotificationRegistrar: (any V2RemoteNotificationRegistering)? = nil,
        localRestorationDependencies: V2AppLocalRestorationDependencies? = nil
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
            realtimeRuntime = nil; realtimeCoverage = nil
            realtimeTask = nil
            messageSearchIndexTask = nil
            return
        }
        if let dependencies = localRestorationDependencies {
            configuration = dependencies.configuration
            authSession = dependencies.authSession; bootstrapper = dependencies.bootstrapper
            pendingCredentialDeletionStore = dependencies.exitMarker
            localDatabaseURL = dependencies.databaseURL; localKeychainService = dependencies.serviceIdentifier
            self.liveLocalAccountE2ETestScope = nil
            deviceRegistrationStore = nil; deviceRevocationStore = nil; issuedCredentialRecovery = nil
            deviceRevocationRunner = nil; registrationCancellationRunner = nil
            route = .launching; authenticationMessage = nil
            conversationStore = nil; contactsStore = nil; privacySettingsStore = nil
            userBlockSettingsStore = nil; publicIdentitySettingsStore = nil; pushWakeSettingsStore = nil
            deviceSessionsStore = nil; groupInvitationStore = nil
            realtimeRuntime = nil; realtimeCoverage = nil; realtimeTask = nil; messageSearchIndexTask = nil
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
                url: V2FilePendingCredentialDeletionStore.fileURL(databaseURL: databaseURL, serviceIdentifier: keychainService + ".pending-credential-deletion")
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
            realtimeRuntime = nil; realtimeCoverage = nil
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
            realtimeRuntime = nil; realtimeCoverage = nil
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
            if let marker = pendingCredentialDeletionStore {
                do {
                    let permit = try await bootstrapper.localReadBootstrap(isLocalExitPending: { try await marker.isPending() })
                    let store = try await bootstrapper.openLocalReadSession(permit, isLocalExitPending: { try await marker.isPending() })
                    do {
                        let presentation = V2OfflineProjectionPresentation(userID: permit.identity.userID, store: store,
                            validate: { try await bootstrapper.requireLocalReadBootstrap(permit, isLocalExitPending: { try await marker.isPending() }) },
                            onTrustFailure: { [weak self] error in
                                guard let self, self.authenticationAttemptGate.matchesCurrentGeneration(attemptGeneration) else { return }
                                await self.withdrawOfflineTrust(error)
                            })
                        try await presentation.loadConversations()
                        try Task.checkCancellation()
                        guard authenticationAttemptGate.matchesCurrentGeneration(attemptGeneration), !signOutAttemptGate.isInFlight else {
                            presentation.invalidate(); try await bootstrapper.closeLocalStore(store); return
                        }
                        offlineLocalStore = store; offlinePermit = permit; offlinePresentation = presentation
                        accountAccessMode = .localReadOnly
                        route = .localReadOnly(userID: permit.identity.userID.rawValue)
                        if let authSession {
                            authenticationObserver.start(session: authSession, epoch: permit.identity.epoch) { [weak self] change in
                                await self?.authenticationStateDidChange(change)
                            }
                        }
                        startOfflineUpgradeIfNeeded()
                        return
                    } catch { try? await bootstrapper.closeLocalStore(store); throw error }
                } catch V2OfflineReadBootstrapError.localStoreUnavailable {
                    // No trusted existing projection: the authenticated path may create
                    // fresh local storage, but expired offline credentials cannot do so.
                }
            }
            let localStore = try await bootstrapper.openEstablishedSession()
            try Task.checkCancellation()
            guard authenticationAttemptGate.matchesCurrentGeneration(attemptGeneration) else { return }
            try await activate(localStore: localStore, authenticationAttemptGeneration: attemptGeneration)
        } catch V2ClientSessionBootstrapError.authenticationRequired, V2AuthSessionError.unauthenticated {
            guard authenticationAttemptGate.matchesCurrentGeneration(attemptGeneration) else { return }
            route = .signedOut
        } catch V2OfflineReadBootstrapError.localExitPending {
            guard authenticationAttemptGate.matchesCurrentGeneration(attemptGeneration) else { return }
            await discardAuthenticatedPresentation(route: .signOutPendingCredentialDeletion)
        } catch V2OfflineReadBootstrapError.installationBindingUnavailable {
            guard authenticationAttemptGate.matchesCurrentGeneration(attemptGeneration) else { return }
            route = .protectedDataUnavailable
        } catch V2OfflineReadBootstrapError.installationBindingMismatch {
            guard authenticationAttemptGate.matchesCurrentGeneration(attemptGeneration) else { return }
            route = .unavailable(message: "无法确认本地数据的安装与账户归属。")
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

    private func withdrawOfflineTrust(_ error: any Error) async {
        _ = authenticationAttemptGate.begin()
        let destination: Route
        if (error as? V2OfflineReadBootstrapError) == .localExitPending { destination = .signOutPendingCredentialDeletion }
        else if (error as? V2AuthSessionError) == .credentialsUnavailable || (error as? V2OfflineReadBootstrapError) == .installationBindingUnavailable {
            destination = .protectedDataUnavailable
        } else { destination = .signedOut }
        await discardAuthenticatedPresentation(route: destination)
    }

    func retryOnlineFromLocalReadOnly() async {
        guard case .localReadOnly = route, let permit = offlinePermit, let bootstrapper,
              let marker = pendingCredentialDeletionStore else { return }
        do {
            try await bootstrapper.requireLocalReadBootstrap(permit, isLocalExitPending: { try await marker.isPending() })
            startOfflineUpgradeIfNeeded()
        } catch V2OfflineReadBootstrapError.localExitPending {
            await discardAuthenticatedPresentation(route: .signOutPendingCredentialDeletion)
        } catch V2AuthSessionError.credentialsUnavailable, V2OfflineReadBootstrapError.installationBindingUnavailable {
            await discardAuthenticatedPresentation(route: .protectedDataUnavailable)
        } catch { await discardAuthenticatedPresentation(route: .signedOut) }
    }

    private func startOfflineUpgradeIfNeeded() {
        guard offlineUpgradeTask == nil, case .localReadOnly = route,
              let permit = offlinePermit, let bootstrapper, let authSession,
              let marker = pendingCredentialDeletionStore else { return }
        let generation = authenticationAttemptGate.generation
        let id = UUID()
        offlineUpgradeTask = (id, Task { [weak self] in
            guard let self else { return }
            defer { if self.offlineUpgradeTask?.id == id { self.offlineUpgradeTask = nil } }
            do {
                _ = try await V2HTTPRequestDeadline.run(until: .now.advanced(by: .seconds(15)), service: "authentication") {
                    try await authSession.realtimeCredentials()
                }
                try Task.checkCancellation()
                try await bootstrapper.requireLocalReadBootstrap(permit, isLocalExitPending: { try await marker.isPending() })
                guard self.authenticationAttemptGate.matchesCurrentGeneration(generation), !self.signOutAttemptGate.isInFlight,
                      case .localReadOnly = self.route, let readOnlyStore = self.offlineLocalStore else { return }
                // Remove the read-only dependency, then close and drain it before any writable adoption.
                self.offlinePresentation?.invalidate(); self.offlinePresentation = nil
                self.accountAccessMode = .blocked; self.route = .launching
                try await bootstrapper.closeLocalStore(readOnlyStore)
                // Closing may yield to sign-out or another activation. Do not
                // clear the next account's offline dependencies on a late return.
                try Task.checkCancellation()
                guard self.authenticationAttemptGate.matchesCurrentGeneration(generation),
                      !self.signOutAttemptGate.isInFlight, self.offlineUpgradeTask?.id == id else { return }
                self.offlineLocalStore = nil; self.offlinePermit = nil
                let writable = try await bootstrapper.openEstablishedSession()
                do {
                    try Task.checkCancellation()
                    guard self.authenticationAttemptGate.matchesCurrentGeneration(generation), !self.signOutAttemptGate.isInFlight else {
                        try await bootstrapper.closeLocalStore(writable); return
                    }
                    try await self.activate(localStore: writable, authenticationAttemptGeneration: generation)
                } catch { try await bootstrapper.closeLocalStore(writable); throw error }
            } catch V2AuthSessionError.unauthenticated {
                guard self.authenticationAttemptGate.matchesCurrentGeneration(generation) else { return }
                await self.discardAuthenticatedPresentation(route: .signedOut)
            } catch V2AuthSessionError.credentialsUnavailable, V2OfflineReadBootstrapError.installationBindingUnavailable {
                guard self.authenticationAttemptGate.matchesCurrentGeneration(generation) else { return }
                await self.discardAuthenticatedPresentation(route: .protectedDataUnavailable)
            } catch V2ClientSessionBootstrapError.localStoreCloseFailed {
                guard self.authenticationAttemptGate.matchesCurrentGeneration(generation) else { return }
                self.accountAccessMode = .blocked
                self.route = .unavailable(message: "无法关闭本地只读数据，请重新启动应用后重试。")
            } catch let trustError as V2AuthSessionError where trustError == .sessionInvalidated {
                guard self.authenticationAttemptGate.matchesCurrentGeneration(generation) else { return }
                await self.withdrawOfflineTrust(trustError)
            } catch let trustError as V2OfflineReadBootstrapError {
                guard self.authenticationAttemptGate.matchesCurrentGeneration(generation) else { return }
                await self.withdrawOfflineTrust(trustError)
            } catch is CancellationError { return }
            catch {
                guard self.authenticationAttemptGate.matchesCurrentGeneration(generation), !self.signOutAttemptGate.isInFlight else { return }
                if case .localReadOnly = self.route {
                    do {
                        try await bootstrapper.requireLocalReadBootstrap(permit, isLocalExitPending: { try await marker.isPending() })
                        self.authenticationMessage = "暂时无法连接账户服务，本地内容仍可查看。"
                    } catch { await self.withdrawOfflineTrust(error) }
                } else if self.route == .launching {
                    await self.performRestore()
                }
            }
        })
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

    func passwordLifecycleClient() -> V2PasswordLifecycleClient? {
        guard let configuration else { return nil }
        return try? V2PasswordLifecycleClient(baseURL: configuration.endpoint("v2/account-auth/password"))
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
                assertionProvider: accountProvider,
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
        } catch V2AccountAuthenticationError.publicHandleAlreadyExists {
            guard authenticationAttemptGate.matchesCurrentGeneration(attemptGeneration) else { return }
            route = .signedOut
            authenticationMessage = "该公开 ID 已被占用，请更换公开 ID 后重新注册。"
        } catch V2AccountAuthenticationError.rateLimited(let seconds) {
            guard authenticationAttemptGate.matchesCurrentGeneration(attemptGeneration) else { return }
            route = .signedOut
            authenticationMessage = seconds.map { "登录尝试过于频繁，请在 \($0) 秒后重试。" }
                ?? "登录尝试过于频繁，请稍后重试。"
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
    /// 先隐藏页面，再依次等待观察、运行时、索引和媒体任务；保留账户暂存供下次恢复。
    /// 清理失败进入不可用 route，不伪装成已经完成。
    ///
    /// - Parameter nextRoute: 全部本地收尾成功后要进入的 route。
    private func discardAuthenticatedPresentation(route nextRoute: Route) async {
        let closingGeneration = authenticationAttemptGate.generation
        let closingBootstrapper = bootstrapper
        let closingBackgroundSync = backgroundSync
        let closingAccountRuntime = accountRuntime
        let closingRealtimeRuntime = realtimeRuntime
        let closingRealtimeTask = realtimeTask
        // Capture and detach every account owner before the first suspension.
        // Cleanup of an old account must never stop a subsequently adopted one.
        backgroundSync = nil; accountRuntime = nil; realtimeRuntime = nil; realtimeCoverage = nil
        realtimeAttemptGate.cancel()
        closingRealtimeTask?.cancel(); realtimeTask = nil
        authenticationObserver.stop()
        let oldActivityObservation=accountActivityObservation
        oldActivityObservation?.cancel(); accountActivityObservation=nil; accountWorkPaused=false
        networkDiagnosticsObservation?.cancel(); networkDiagnosticsObservation=nil
        offlineUpgradeTask?.task.cancel()
        accountAccessMode = .blocked
        let closingOfflineStore = offlineLocalStore
        offlineLocalStore = nil; offlinePermit = nil
        offlinePresentation?.invalidate(); offlinePresentation = nil
        groupInvitationStore?.invalidate()
        let thumbnails = mediaThumbnailCache
        let closingAvatarInvalidations = avatarInvalidationTask
        closingAvatarInvalidations?.cancel(); avatarInvalidationTask = nil
        let oldAvatarPipeline = avatarPipeline
        avatarPipeline = nil
        mediaThumbnailCache = nil
        let indexer = messageSearchIndexTask
        let localStore = messageSearchLocalStore
        let pushSettings = pushWakeSettingsStore
        let closingDownloader = mediaCacheDownloader
        let closingUploader = accountAttachmentUploader
        let closingStager = accountAttachmentStager
        let closingProfiles = accountProfileRepository
        accountProfileRepository = nil
        let closingPendingGroupAvatars = pendingGroupAvatarsStore
        pendingGroupAvatarsStore?.suspend()
        pendingGroupAvatarsStore = nil
        mediaCacheDownloader = nil
        accountAttachmentUploader = nil
        accountAttachmentStager = nil
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
        let closingDeviceSessions = deviceSessionsStore
        deviceSessionsStore = nil
        groupInvitationStore = nil
        await closingDeviceSessions?.close()
        await closingPendingGroupAvatars?.close()
        await closingProfiles?.close()
        await oldAvatarPipeline?.close()
        await closingAvatarInvalidations?.value
        await oldActivityObservation?.value
        await thumbnails?.close()
        await pushSettings?.stop()
        await closingBackgroundSync?.stop()
        await closingAccountRuntime?.suspendRealtime()
        await closingRealtimeRuntime?.stop()
        await indexer?.value
        do {
            // The account database and unknown operation journal survive sign-out.
            // Keep source files too; next activation removes only aged orphans
            // after consulting that journal. Closing is not a cancellation proof.
            try await V2AccountResourceCleanup.run([
                { await closingUploader?.close() },
                { await closingAccountRuntime?.close() },
                { try await closingDownloader?.close() },
                { try await closingStager?.close(preservingDurableFiles: true) },
                { if let closingOfflineStore { try await closingBootstrapper?.closeLocalStore(closingOfflineStore) } },
                { if let localStore { try await closingBootstrapper?.closeLocalStore(localStore) } }
            ])
            guard authenticationAttemptGate.matchesCurrentGeneration(closingGeneration) else { return }
            authenticationMessage = nil
            route = nextRoute
        } catch {
            guard authenticationAttemptGate.matchesCurrentGeneration(closingGeneration) else { return }
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
        guard authenticationAttemptGeneration.map(authenticationAttemptGate.matchesCurrentGeneration) ?? true else { return }
        let previousDownloader = mediaCacheDownloader
        let previousUploader = accountAttachmentUploader
        let previousStager = accountAttachmentStager
        let previousProfiles = accountProfileRepository
        accountProfileRepository = nil
        mediaCacheDownloader = nil
        accountAttachmentUploader = nil
        accountAttachmentStager = nil
        try await V2AccountResourceCleanup.run([
            { await previousProfiles?.close() },
            { await previousUploader?.close() },
            { try await previousDownloader?.close() },
            { try await previousStager?.close(preservingDurableFiles: true) }
        ])
        try Task.checkCancellation()
        guard authenticationAttemptGeneration.map(authenticationAttemptGate.matchesCurrentGeneration) ?? true else { return }
        try await authSession.requireAuthenticatedEpoch(authEpoch)
        try await V2AccountActivationScope.withPrepared { activation in
            let attachmentStager = try V2FileConversationAttachmentStager(directory: scope.mediaStagingDirectory)
            activation.onDiscard { try await attachmentStager.close(preservingDurableFiles: true) }
            let realtime = try V2AppRealtimeRuntime(
                configuration: configuration,
                actorUserID: userID,
                deviceID: credentials.deviceID,
                authSession: authSession,
                authEpoch: authEpoch,
                localStore: localStore,
                mediaCacheDirectory: scope.mediaCacheDirectory,
                mediaStagingDirectory: scope.mediaStagingDirectory
            )
            activation.onDiscard {
                await realtime.backgroundSync.stop()
                await realtime.runtime.stop()
                await realtime.accountRuntime.close()
                await realtime.profileRepository.close()
                await realtime.profilePresentations.close()
                await realtime.attachmentUploader.close()
                try await realtime.mediaCacheMaintenance.close()
            }
            let backgroundTransfers=try await V2BackgroundTransferCoordinator.native(store:localStore,
                scheduler:realtime.accountRuntime.scheduler,activationID:realtime.accountRuntime.ownerID,
                diagnostics:realtime.accountRuntime.networkDiagnostics)
            activation.onDiscard { await backgroundTransfers.close() }
            // Adopt existing system I/O before any foreground activity can request the same slots.
            try await realtime.resourceTransfers.attachBackground(backgroundTransfers)
            try Task.checkCancellation()
            try await authSession.requireAuthenticatedEpoch(authEpoch)
            // No source reader is running yet. Multipart slices and interrupted
            // import copies cannot be referenced by any durable resource intent.
            try await attachmentStager.discardInterruptedCopies()
            let retainedTokens = try await localStore.retainedResourceFileTokens()
            await attachmentStager.discardOrphanedStagedFiles(retaining: retainedTokens, olderThan: Date().addingTimeInterval(-86_400))
            try Task.checkCancellation()
            await realtime.mediaCacheMaintenance.performMaintenance()
            try Task.checkCancellation()
            let accountHTTP = V2SessionHTTPAuthorization(session: authSession, epoch: authEpoch,
                transport: try V2RegisteredAccountHTTPTransport(executor: realtime.accountRuntime.httpExecutor,
                    allowedBases: [configuration.accountBaseURL, configuration.mediaEdgeEndpoint.deletingLastPathComponent().deletingLastPathComponent()],
                    scope: realtime.accountRuntime.queryScope(accountID: userID.rawValue, authorizationDomain: "accountHTTP")), scheduler: realtime.accountRuntime.scheduler)
            let publicIdentityDirectory = try V2HTTPPublicIdentityDirectory(
                endpoint: configuration.endpoint("v2/public-identities/resolve"),
                actorUserID: userID,
                credentials: accountHTTP, transport: accountHTTP
            )
            let roomRecovery = realtime.roomRecovery
            let conversationDataSource = V2GRDBConversationDataSource(
                localStore: localStore,
                requestLatestVisible: { try await roomRecovery.requestLatestVisible(roomIDs: $0) }
            )
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
                    moderator: realtime.messageModerationOperations,
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
                    moderatedMemberRemover: realtime.moderatedGroupMemberRemover,
                    avatarManager: realtime.groupAvatarManager,
                    nameOperations: realtime.nameOperations
                ),
                discovery: .init(
                    directConversationOpener: realtime.directConversationOpener,
                    publicIdentityResolver: publicIdentityDirectory
                ),
                media: .init(
                    attachmentStager: attachmentStager,
                    resourceSender: realtime.attachmentUploader.durable,
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
                projectionChangeNotifier: realtime.projectionChangeNotifier,
                nameOperations: realtime.nameOperations
            )
            let userBlockSettings = V2UserBlockSettingsStore(
                resolver: publicIdentityDirectory,
                changer: realtime.userBlockChanger,
                currentUserID: userID
            )
            let profileService = V2ProfileIntentService(
                store: localStore, accountID: userID,
                manager: try V2HTTPOwnProfileClient(
                    endpoint: configuration.endpoint("v2/profile/me"),
                    credentials: accountHTTP, transport: accountHTTP,
                    queries: realtime.accountRuntime.ownProfileQueries,
                    queryScope: realtime.accountRuntime.queryScope(accountID: userID.rawValue, authorizationDomain: "self-profile")
                ),
                avatars: V2ProfileAvatarUploadAdapter(uploader: realtime.attachmentUploader)
            )
            let invitationOperations=V2InvitationOperationService(accountID:userID,activationID:realtime.accountRuntime.ownerID,store:localStore,
                client:try V2HTTPInvitationOperationClient(baseURL:configuration.accountBaseURL,credentials:accountHTTP,transport:accountHTTP),
                secrets:V2KeychainInvitationSecretStore(installationBinding:try await localStore.boundInstallationBinding()))
            let profileDispatcher = V2OperationWorkDispatcher(
                store: localStore,
                handlers: [.init(kind:.groupInvite) {try await invitationOperations.execute($0)},
                    .init(kind:.groupJoinRequest) {try await invitationOperations.execute($0)},
                    .init(kind:.groupJoinDecision) {try await invitationOperations.execute($0)},
                    .init(kind: .profileUpdate) { try await profileService.execute($0) },
                    .init(kind: .conversationPreference) { try await realtime.personalPreferences.execute($0) },
                    .init(kind: .messageFavorite) { try await realtime.personalPreferences.execute($0) },
                    .init(kind: .contactAlias) { try await realtime.nameOperations.execute($0) },
                    .init(kind: .groupNickname) { try await realtime.nameOperations.execute($0) },
                    .init(kind: .readReceipt) { try await realtime.readReceiptOperations.execute($0) },
                    .init(kind: .sendMessage) { try await realtime.messageSendOperations.execute($0) },
                    .init(kind: .editMessage) { try await realtime.messageMutationOperations.execute($0) },
                    .init(kind: .withdrawMessage) { try await realtime.messageMutationOperations.execute($0) },
                    .init(kind: .moderation) { try await realtime.messageModerationOperations.execute($0) },
                    .init(kind: .directRoom) { try await realtime.directRoomOperations.execute($0) },
                    .init(kind: .groupRoom) { try await realtime.groupCreationOperations.execute($0) },
                    .init(kind: .pinnedMessage) { try await realtime.groupCapabilityOperations.execute($0) },
                    .init(kind: .groupAnnouncement) { try await realtime.groupCapabilityOperations.execute($0) },
                    .init(kind: .groupPermission) { try await realtime.groupCapabilityOperations.execute($0) },
                    .init(kind: .groupRole) { try await realtime.groupCapabilityOperations.execute($0) },
                    .init(kind:.strangerMessagePreference) { try await realtime.accountPreferences.execute($0) },
                    .init(kind:.userAddPreference) { try await realtime.accountPreferences.execute($0) },
                    .init(kind:.readReceiptPreference) { try await realtime.accountPreferences.execute($0) },
                    .init(kind:.liveActivityPreference) { try await realtime.accountPreferences.execute($0) },
                    .init(kind:.relationship) { try await realtime.socialOperations.execute($0) },
                    .init(kind:.userBlock) { try await realtime.socialOperations.execute($0) },
                    .init(kind: .membership) { try await realtime.membershipOperations.execute($0) },
                    .init(kind: .memberMute) { try await realtime.memberAdministrationOperations.execute($0) },
                    .init(kind: .moderatedMemberRemoval) { try await realtime.memberAdministrationOperations.execute($0) },
                    .init(kind: .reaction) { try await realtime.messageReactionOperations.execute($0) },
                    .init(kind: .forwardMessage) { try await realtime.forwardPlanOperations.execute($0) }],
                ownerID: realtime.accountRuntime.ownerID, diagnostics: realtime.accountRuntime.networkDiagnostics
            )
            let publicIdentitySettings = V2PublicIdentitySettingsStore(
                service: profileService, attachmentStager: attachmentStager
            )
            let remoteDeviceRevocations = V2RemoteDeviceRevocationService(
                accountID: userID, currentDeviceID: credentials.deviceID,
                storage: V2KeychainRemoteDeviceRevocationMetadataStore(
                    installationBinding: try await localStore.boundInstallationBinding(),
                    accountID: userID, currentDeviceID: credentials.deviceID),
                client: try V2HTTPRemoteDeviceRevocationClient(baseURL: configuration.accountBaseURL,
                    credentials: accountHTTP, transport: accountHTTP))
            let deviceSessions = V2DeviceSessionsStore(
                manager: try V2HTTPDeviceSessionClient(endpoint: configuration.endpoint("v2/devices"),
                    credentials: accountHTTP, transport: accountHTTP), operations: remoteDeviceRevocations)
            activation.onDiscard { await deviceSessions.close() }
            let invitationQueries = V2QueryCoordinator<Data>()
            activation.onDiscard { await invitationQueries.closeAndDrain() }
            let invitationScope = realtime.accountRuntime.queryScope(accountID: userID.rawValue, authorizationDomain: "groupInvitationManagement")
            let groupInvitations = V2GroupInvitationStore(
                client: try V2HTTPGroupInvitationClient(
                    baseURL: configuration.accountBaseURL,
                    credentials: accountHTTP, transport: accountHTTP,
                    queries: invitationQueries, queryScope: invitationScope
                ),operations:invitationOperations
            )
            let groupAvatarManager = realtime.groupAvatarManager, groupAvatarNotifier = realtime.projectionChangeNotifier
            let pendingGroupAvatars = V2PendingGroupAvatarsStore(reader: groupAvatarManager,
                notifier: groupAvatarNotifier) { roomID, operationID in
                V2GroupAvatarManagementStore(roomID: roomID, manager: groupAvatarManager,
                    stager: attachmentStager, notifier: groupAvatarNotifier, focusedOperationID: operationID)
            }
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
                    transport: V2HTTPPushEndpointClient(endpoint: configuration.pushEndpoint, session: authSession, epoch: authEpoch,
                        transport: V2URLSessionPushEndpointHTTPTransport(executor: realtime.accountRuntime.httpExecutor),
                        scheduler: realtime.accountRuntime.scheduler),
                    scope: pushScope, initialPreference: initialPreference
                )
                guard authenticationAttemptGeneration.map(authenticationAttemptGate.matchesCurrentGeneration) ?? true else {
                    await reconciler.stop(); return
                }
                do { try await authSession.requireAuthenticatedEpoch(authEpoch); try Task.checkCancellation() }
                catch { await reconciler.stop(); throw error }
                pushWakeSettings = .init(reconciler: reconciler, preferences: preferences, remoteNotificationRegistrar: remoteNotificationRegistrar, environment: configuration.pushEndpointEnvironment)
            } else { pushWakeSettings = nil }
            activation.onDiscard { await pushWakeSettings?.stop() }
            let thumbnails = V2LocalMediaThumbnailCache(directory: scope.directory)
            activation.onDiscard { await thumbnails.close() }
            let presentations = realtime.profilePresentations
            let groupReader = try V2HTTPGroupAvatarPresentationClient(roomsEndpoint: configuration.endpoint("v2/rooms"),
                actorUserID: userID, credentials: accountHTTP, transport: accountHTTP)
            let groupPresentations = V2GroupAvatarPresentationRepository(actorUserID: userID, deviceID: credentials.deviceID,
                reader: groupReader, minimumRevision: { try await localStore.groupAvatarRevision(roomID: $0) })
            let pipeline = V2AvatarPipeline(profiles: presentations, groups: groupPresentations,
                files: realtime.mediaCacheMaintenance, thumbnails: thumbnails,
                authors: realtime.makeAuthorPresentationCoordinator(presentations))
            activation.onDiscard { await pipeline.close() }
            guard authenticationAttemptGeneration.map(authenticationAttemptGate.matchesCurrentGeneration) ?? true else { return }
            let previousThumbnails = mediaThumbnailCache
            let previousPipeline = avatarPipeline
            mediaThumbnailCache = nil
            avatarPipeline = nil
            let previousAvatarInvalidations = avatarInvalidationTask
            previousAvatarInvalidations?.cancel()
            avatarInvalidationTask = nil
            await stopRealtime()
            await previousPipeline?.close()
            await previousAvatarInvalidations?.value
            await previousThumbnails?.close()
            try Task.checkCancellation()
            guard authenticationAttemptGeneration.map(authenticationAttemptGate.matchesCurrentGeneration) ?? true else { return }
            try await authSession.requireAuthenticatedEpoch(authEpoch)
            try Task.checkCancellation()
            guard authenticationAttemptGeneration.map(authenticationAttemptGate.matchesCurrentGeneration) ?? true else { return }
            // No awaits between adoption and publishing the complete account state.
            try activation.adopt()
            accountAttachmentUploader = realtime.attachmentUploader
            accountAttachmentStager = attachmentStager
            accountProfileRepository = realtime.profileRepository
            mediaCacheDownloader = realtime.mediaCacheMaintenance
            mediaThumbnailCache = thumbnails
            avatarPipeline = pipeline
            avatarInvalidationTask?.cancel()
            avatarInvalidationTask = Task {
                let notifier = realtime.projectionChangeNotifier
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for await _ in await notifier.updates(scopes: .presentations) {
                            guard !Task.isCancelled else { return }
                            await pipeline.suspend()
                        }
                    }
                    group.addTask {
                        for await _ in await notifier.updates(scopes: .groupNicknames) {
                            guard !Task.isCancelled else { return }
                            try? await presentations.refreshNicknameInvalidations()
                        }
                    }
                    group.addTask {
                        for await _ in await notifier.updates(scopes: .contactAliases) {
                            guard !Task.isCancelled else { return }
                            try? await presentations.refreshAliasInvalidations()
                        }
                    }
                    await group.waitForAll()
                }
            }
            realtimeRuntime = realtime.runtime
            realtimeCoverage = realtime.realtimeCoverage
            accountRuntime = realtime.accountRuntime
            backgroundSync = realtime.backgroundSync
            conversationStore = conversations
            contactsStore = contacts
            privacySettingsStore = privacySettings
            userBlockSettingsStore = userBlockSettings
            publicIdentitySettingsStore = publicIdentitySettings
            pushWakeSettingsStore = pushWakeSettings
            deviceSessionsStore = deviceSessions
            groupInvitationStore = groupInvitations
            pendingGroupAvatarsStore = pendingGroupAvatars
            messageSearchLocalStore = localStore
            accountAccessMode = .authenticated
            route = .signedIn(userID: userID.rawValue)
            authenticationObserver.start(session: authSession, epoch: authEpoch) { [weak self] change in
                await self?.authenticationStateDidChange(change)
            }
            await realtime.accountRuntime.startActivity(id: "remoteDeviceRevocations") {
                try await remoteDeviceRevocations.run()
            }
            await realtime.accountRuntime.startActivity(id: "profilePreparation") {
                try await profileService.runPreparation()
            }
            await realtime.accountRuntime.startActivity(id: "personalPreferencePreparation") {
                try await realtime.personalPreferences.runPreparation()
            }
            await realtime.accountRuntime.startActivity(id:"groupCapabilityPreparation") { try await realtime.groupCapabilityOperations.runPreparation() }
            await realtime.accountRuntime.startActivity(id:"accountPreferencePreparation") { try await realtime.accountPreferences.runPreparation() }
            await realtime.accountRuntime.startActivity(id:"invitationSecretCleanup") {
                let wakeups=V2InvitationUnlockWakeups()
                try await invitationOperations.releaseProtectedSecrets()
                for await _ in wakeups.stream {try Task.checkCancellation();try await invitationOperations.releaseProtectedSecrets()}
            }
            await realtime.accountRuntime.startActivity(id:"invitationPreparation") {try await invitationOperations.runPreparation()}
            await realtime.accountRuntime.startActivity(id:"membershipPreparation") { try await realtime.membershipOperations.runPreparation() }
            await realtime.accountRuntime.startActivity(id:"memberAdministrationPreparation") { try await realtime.memberAdministrationOperations.runPreparation() }
            await realtime.accountRuntime.startActivity(id:"reactionPreparation") { try await realtime.messageReactionOperations.runPreparation() }
            await realtime.accountRuntime.startActivity(id: "readReceiptPreparation") {
                try await realtime.readReceiptOperations.runPreparation()
            }
            await realtime.accountRuntime.startActivity(id: "profileOperations") {
                try await profileDispatcher.run()
            }
            await realtime.accountRuntime.startActivity(id: "resourceTransfers") {
                try await realtime.resourceTransfers.runRecovery()
            }
            await realtime.accountRuntime.startActivity(id:"backgroundByteTransfers") {
                try await backgroundTransfers.run()
            }
            await realtime.accountRuntime.startActivity(id: "resourcePreparation", operation: {
                try await realtime.attachmentUploader.durable.runRecovery()
            }, onFailure: { _ in
                Logger(subsystem: "IMApp", category: "ResourceRecovery").error("Resource preparation paused; durable drafts remain available.")
            })
            observeAccountActivities(realtime.accountRuntime)
            recordAccountWorkSnapshot(localStore: localStore, owner: realtime.accountRuntime)
            guard authenticationAttemptGeneration.map(authenticationAttemptGate.matchesCurrentGeneration) ?? true,
                  accountAttachmentUploader === realtime.attachmentUploader, isApplicationActive else { return }
            startMessageSearchIndexing(localStore: localStore)
            await conversations.refresh()
            guard authenticationAttemptGeneration.map(authenticationAttemptGate.matchesCurrentGeneration) ?? true else { return }
            await pushWakeSettings?.activate()
            guard authenticationAttemptGeneration.map(authenticationAttemptGate.matchesCurrentGeneration) ?? true else { return }
            startRealtimeIfApplicationActive(runtime: realtime.runtime, conversations: conversations)
        }
    }

    private func authenticationStateDidChange(_ change: V2AuthenticationStateObserver.Change) async {
        guard accountAccessMode != .blocked, signOutAttemptGate.begin() else { return }
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
        offlineUpgradeTask?.task.cancel()
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
        if case .localReadOnly = route {
            await retryOnlineFromLocalReadOnly()
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
        networkDiagnosticsObservation?.cancel()
        accountActivityObservation?.cancel()
        deviceRevocationTask?.cancel(); deviceRevocationObservation?.cancel()
        registrationCancellationTask?.cancel(); registrationCancellationObservation?.cancel()
    }

    private func observeAccountActivities(_ owner:V2AccountRuntime) {
        networkDiagnosticsObservation?.cancel()
        networkDiagnosticsObservation = Task { [weak self] in
            var lastHTTPRecord: UInt64 = 0, lastOperationRecord: UInt64 = 0, lastProjectionRecord: UInt64 = 0, lastResourceRecord: UInt64 = 0, lastBackgroundRecord: UInt64 = 0
            do {
                for await snapshot in try owner.networkDiagnostics.updates() {
                    try Task.checkCancellation()
                    guard let self, self.accountRuntime === owner, self.accountAccessMode == .authenticated else { return }
                    if snapshot.backgroundRecorded > lastBackgroundRecord, let background = snapshot.backgrounds.last {
                        lastBackgroundRecord = snapshot.backgroundRecorded
                        let sent = background.bodyBytesSent.map(String.init) ?? "unknown"
                        let received = background.bodyBytesReceived.map(String.init) ?? "unknown"
                        let cancellationRelease = background.cancellationToPermitRelease.map { String($0) } ?? "unknown"
                        Logger(subsystem: "IMApp", category: "NetworkDiagnostics").debug("Background bodySent=\(sent, privacy: .public) bodyReceived=\(received, privacy: .public) completionObserved=\(background.completionObserved) cancellationToPermitReleaseSeconds=\(cancellationRelease, privacy: .public)")
                    }
                    if snapshot.resourceRecorded > lastResourceRecord, let resource = snapshot.resources.last {
                        lastResourceRecord = snapshot.resourceRecorded
                        let mode = resource.mode.rawValue, response = resource.response.rawValue
                        let rebuiltPrefix = resource.verifiedRangeRebuildPrefixBytes.map { String($0) } ?? "unknown"
                        Logger(subsystem: "IMApp", category: "NetworkDiagnostics").debug("Resource mode=\(mode, privacy: .public) response=\(response, privacy: .public) bodySent=\(resource.bodyBytesSent) bodyReceived=\(resource.bodyBytesReceived) elapsed=\(resource.elapsed) retryAttempt=\(resource.retryAttempt) failed=\(resource.failed) cancelled=\(resource.cancelled) verifiedRangeRebuildPrefixBytes=\(rebuiltPrefix, privacy: .public)")
                    }
                    if snapshot.projectionRecorded > lastProjectionRecord, let projection = snapshot.projections.last {
                        lastProjectionRecord = snapshot.projectionRecorded
                        let phase = projection.phase.rawValue
                        Logger(subsystem: "IMApp", category: "NetworkDiagnostics").debug("Projection phase=\(phase, privacy: .public) elapsed=\(projection.elapsed) scopes=\(projection.scopes.rawValue)")
                    }
                    if snapshot.operationRecorded > lastOperationRecord, let step = snapshot.operationSteps.last {
                        lastOperationRecord = snapshot.operationRecorded
                        let kind = step.kind.rawValue, action = step.action.rawValue
                        let completion = step.completion.rawValue, certainty = step.certainty.rawValue
                        Logger(subsystem: "IMApp", category: "NetworkDiagnostics").debug("Operation kind=\(kind, privacy: .public) action=\(action, privacy: .public) attempt=\(step.attempt) candidateWait=\(step.candidateWait) handler=\(step.handlerElapsed) completion=\(completion, privacy: .public) certainty=\(certainty, privacy: .public)")
                    }
                    guard snapshot.httpRecorded > lastHTTPRecord, let sample = snapshot.samples.last else { continue }
                    lastHTTPRecord = snapshot.httpRecorded
                    // Fixed vocabulary and numbers only; never log URL, account,
                    // operation identity, credentials, payload or error text.
                    let logger = Logger(subsystem: "IMApp", category: "NetworkDiagnostics")
                    let status = sample.statusCode.map { String($0) } ?? "missing"
                    logger.debug("HTTP service=\(sample.service, privacy: .public) queue=\(sample.queued) transport=\(sample.elapsed) status=\(status, privacy: .public) cancelled=\(sample.cancelled) samples=\(snapshot.recorded)")
                    if let phases = sample.phases {
                        let dns = phases.dns.map { String($0) } ?? "missing"
                        let connect = phases.connect.map { String($0) } ?? "missing"
                        let tls = phases.tls.map { String($0) } ?? "missing"
                        let request = phases.request.map { String($0) } ?? "missing"
                        let response = phases.response.map { String($0) } ?? "missing"
                        let networkProtocol = phases.networkProtocol ?? "missing"
                        logger.debug("HTTP phases dns=\(dns, privacy: .public) connect=\(connect, privacy: .public) tls=\(tls, privacy: .public) request=\(request, privacy: .public) response=\(response, privacy: .public) protocol=\(networkProtocol, privacy: .public)")
                    }
                }
            } catch is CancellationError { }
            catch { /* Diagnostic pressure cannot pause business work. */ }
        }
        accountActivityObservation?.cancel()
        accountActivityObservation=Task { [weak self] in
            do {
                for await states in try await owner.activityUpdates() {
                    try Task.checkCancellation()
                    guard let self, self.accountRuntime === owner, self.accountAccessMode == .authenticated else { return }
                    self.accountWorkPaused=states.values.contains(.failed)
                }
            } catch is CancellationError { }
            catch {
                guard let self, self.accountRuntime === owner, self.accountAccessMode == .authenticated else { return }
                self.accountWorkPaused=true
            }
        }
    }

    /// Explicit account reconstruction preserves durable unknown operations and their existing budgets.
    func resumeAccountWork() async {
        guard accountWorkPaused, !isResumingAccountWork, case .signedIn = route else { return }
        isResumingAccountWork=true
        defer { isResumingAccountWork=false }
        let generation=authenticationAttemptGate.begin()
        await discardAuthenticatedPresentation(route:.launching)
        guard route == .launching, authenticationAttemptGate.matchesCurrentGeneration(generation), !signOutAttemptGate.isInFlight else { return }
        await restore()
        // A successful restore samples through the newly installed runtime.
    }

    /// An explicit read at installation/resume, never a per-wake backlog scan.
    private func recordAccountWorkSnapshot(localStore: GRDBV2LocalSyncStore, owner: V2AccountRuntime) {
        let generation = authenticationAttemptGate.generation
        Task { [weak self] in
            do {
                let snapshot = try await localStore.accountWorkSnapshot()
                try Task.checkCancellation()
                guard let self, self.accountRuntime === owner,
                      self.authenticationAttemptGate.matchesCurrentGeneration(generation),
                      self.accountAccessMode == .authenticated else { return }
                let originalAge = snapshot.oldestUnresolvedOriginalAge.map { String($0) } ?? "none"
                Logger(subsystem: "IMApp", category: "AccountWorkDiagnostics").debug("Work ordinaryCount=\(snapshot.ordinaryCount) ordinaryReservedBytes=\(snapshot.ordinaryReservedBytes) controlCount=\(snapshot.controlCount) controlReservedBytes=\(snapshot.controlReservedBytes) submitting=\(snapshot.submittingCount) processing=\(snapshot.processingCount) awaitingConfirmation=\(snapshot.awaitingConfirmationCount) needsAttention=\(snapshot.needsAttentionCount) oldestUnresolvedOriginalAge=\(originalAge, privacy: .public)")
            } catch is CancellationError { }
            catch {
                guard let self, self.accountRuntime === owner,
                      self.authenticationAttemptGate.matchesCurrentGeneration(generation),
                      self.accountAccessMode == .authenticated else { return }
                Logger(subsystem: "IMApp", category: "AccountWorkDiagnostics").debug("Work snapshot unavailable")
            }
        }
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
            guard let owner = self?.accountRuntime else { return }
            do {
                try await owner.runRealtime(runtime, onConnected: { await conversations.refresh() })
            } catch is CancellationError {
                return
            } catch V2RealtimeSessionCoordinatorError.authenticationRequired {
                await self?.signOutIfCurrentRealtimeAttempt(taskGeneration)
            } catch { return }
        }
    }

    private func stopRealtime() async {
        realtimeAttemptGate.cancel()
        realtimeTask?.cancel()
        realtimeTask = nil
        let stoppingOwner = accountRuntime
        let stoppingRuntime = realtimeRuntime
        await stoppingOwner?.suspendRealtime()
        await stoppingRuntime?.stop()
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
            try await V2KeychainInstallationBindingStore(service: localKeychainService).delete()
            try await pendingCredentialDeletionStore?.clearPending()
            try Self.eraseDatabaseArtifacts(at: localDatabaseURL)
            let deletionMarker = V2FilePendingCredentialDeletionStore.fileURL(databaseURL: localDatabaseURL, serviceIdentifier: localKeychainService + ".pending-credential-deletion")
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

/// Emits no Notification or bearer across isolation; the account activity owns its lifetime.
private final class V2InvitationUnlockWakeups:@unchecked Sendable {
    let stream:AsyncStream<Void>
    private let token:any NSObjectProtocol
    init() {
        let pair=AsyncStream<Void>.makeStream(bufferingPolicy:.bufferingNewest(1))
        stream=pair.stream
        token=NotificationCenter.default.addObserver(forName:UIApplication.protectedDataDidBecomeAvailableNotification,object:nil,queue:nil) {_ in pair.continuation.yield(())}
    }
    deinit {NotificationCenter.default.removeObserver(token)}
}
