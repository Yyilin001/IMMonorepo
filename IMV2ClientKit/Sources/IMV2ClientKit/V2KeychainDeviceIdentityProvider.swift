import Foundation
import IMV2Core

/// 设备身份存储的访问、格式与失效错误分类。
public enum V2DeviceIdentityStoreError: Error, Equatable, Sendable {
    /// Keychain 当前不可访问，不代表设备身份不存在。
    case unavailable
    /// 存储结果不是合法 UTF-8 设备标识。
    case malformedRecord
    /// 系统报告身份项认证失败，需要上层显式处理。
    case permanentlyInvalidated
    /// 未分类的 Keychain 状态码。
    case unexpectedStatus(Int32)
}
