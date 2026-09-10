import Foundation
import IMV2ClientKit

/// 认证状态观察器。
///
/// 它持有唯一一条账号维度的更新流。被替换时只取消本观察器，
/// 已经为旧代次排队的回调不会再影响新代次。
@MainActor
final class V2AuthenticationStateObserver {
    /// 观察到的认证状态变化。
    enum Change: Equatable {
        /// 需要重新认证。
        case authenticationRequired
        /// 受保护数据当前不可用。
        case protectedDataUnavailable
        /// 凭据删除仍在等待处理。
        case credentialDeletionPending
        /// 本次会话已被更新的代次取代。
        case superseded
    }
    private var task: Task<Void, Never>?
    private var observationID = UUID()

    /// 开始观察指定代次的会话状态。
    ///
    /// 开始前会先停止上一次观察，并把回调绑定到本次观察标识，
    /// 使旧代次的滞后回调无法触发新代次的状态变更。
    ///
    /// - Parameters:
    ///   - session: 待观察的认证会话。
    ///   - epoch: 目标会话代次。
    ///   - onChange: 状态变化回调。
    func start(session: V2AuthSession, epoch: V2AuthSessionEpoch,
               onChange: @escaping @MainActor @Sendable (Change) async -> Void) {
        stop()
        let id = observationID
        task = Task { [weak self] in
            let updates = await session.sessionUpdates(for: epoch)
            for await update in updates {
                guard !Task.isCancelled, self?.observationID == id else { return }
                let change: Change
                switch update.status {
                case .active(.credentialsUnavailable): change = .protectedDataUnavailable
                case .active(.unauthenticated), .ended(.authenticationRequired): change = .authenticationRequired
                case .ended(.credentialDeletionPending): change = .credentialDeletionPending
                case .ended(.superseded): change = .superseded
                default: continue
                }
                await onChange(change)
            }
        }
    }

    /// 停止观察并作废当前观察标识。
    func stop() {
        observationID = UUID()
        task?.cancel()
        task = nil
    }

    /// 观察器释放时取消在途任务。
    deinit { task?.cancel() }
}
