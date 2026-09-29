import IMV2Core

public enum V2PasswordLifecycleError: Error, Equatable, Sendable {
    case rejected, invalidInput, unavailable
    case rateLimited(Int)
}

public protocol V2PasswordLifecycleManaging: Sendable {
    func setRecoveryCode(accountHandle: String, password: String, recoveryCode: String, deviceID: DeviceID) async throws
    func changePassword(accountHandle: String, currentPassword: String, newPassword: String, deviceID: DeviceID) async throws
    func resetPassword(accountHandle: String, recoveryCode: String, newPassword: String, deviceID: DeviceID) async throws
}
