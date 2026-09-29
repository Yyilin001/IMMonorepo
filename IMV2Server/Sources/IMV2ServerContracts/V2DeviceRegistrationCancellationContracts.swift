import Foundation
import IMV2Core

/// 设备注册请求与其取消请求的组合。
public struct V2CancellableDeviceRegistration: Sendable {
    /// 待签发的受信设备注册请求。
    public let registration: V2TrustedDeviceRegistration
    /// 对应的取消请求。
    public let cancellation: V2DeviceRegistrationCancellation

    /// 校验两者指向同一设备与同一操作后组合。
    ///
    /// - Parameters:
    ///   - registration: 设备注册请求。
    ///   - cancellation: 取消请求。
    /// - Throws: 设备标识或操作标识不一致时抛出
    ///   ``V2DeviceSessionServiceError/invalidRequest``。
    public init(registration: V2TrustedDeviceRegistration, cancellation: V2DeviceRegistrationCancellation) throws {
        guard UUID(uuidString: registration.deviceID.rawValue) == UUID(uuidString: cancellation.deviceID.rawValue),
              registration.operationID == cancellation.operationID else { throw V2DeviceSessionServiceError.invalidRequest }
        self.registration = registration; self.cancellation = cancellation
    }
}

/// 设备注册取消结果。
public enum V2DeviceRegistrationCancellationOutcome: Equatable, Sendable {
    /// 本次调用实际写入取消或吊销了绑定会话。
    case applied
    /// 该取消请求此前已生效，未产生第二次效果。
    case idempotent
    /// 取消到达过晚，签发窗口已关闭，不再处理。
    case expired
}

/// 设备注册取消能力。
public protocol V2DeviceRegistrationCancelling: Sendable {
    /// 取消一次尚未完成或刚完成的设备注册。
    ///
    /// - Parameter request: 取消请求。
    /// - Returns: 取消结果。
    /// - Throws: 请求非法或持久化状态异常时抛出。
    func cancel(_ request: V2DeviceRegistrationCancellation) async throws -> V2DeviceRegistrationCancellationOutcome
}
