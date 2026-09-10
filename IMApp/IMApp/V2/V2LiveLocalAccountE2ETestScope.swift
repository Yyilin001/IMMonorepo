import Foundation
import IMV2ClientKit
import IMV2Core

/// 仅用于 DEBUG 的启动夹具作用域。
///
/// 它让需显式开启的本地账号界面测试可重复执行，同时不触碰模拟器真实的 App 会话、
/// 钥匙串身份或本地数据库；Release 构建的调用方完全忽略该值。
struct V2LiveLocalAccountE2ETestScope: Sendable, Equatable {
    /// 该作用域使用的设备标识。
    let deviceID: DeviceID
    private let namespace: UUID

    /// 由原始字符串解析作用域。
    ///
    /// - Parameter rawValue: 命名空间 UUID 字符串。
    ///
    /// 取值不是合法 UUID 时返回 `nil`，调用方不应据此开启夹具。
    init?(rawValue: String) {
        guard let namespace = UUID(uuidString: rawValue),
              let deviceID = try? DeviceID(namespace.uuidString)
        else { return nil }
        self.namespace = namespace
        self.deviceID = deviceID
    }

    /// 由生产服务名派生本作用域专用的钥匙串服务名。
    ///
    /// - Parameter productionService: 生产环境的钥匙串服务名。
    /// - Returns: 追加本地端到端命名空间后的服务名。
    func keychainService(basedOn productionService: String) -> String {
        productionService + ".local-e2e." + namespace.uuidString.lowercased()
    }

    /// 本作用域使用的数据库文件名。
    var databaseFileName: String {
        "sync-local-e2e-\(namespace.uuidString.lowercased()).sqlite"
    }
}

/// 面向双安装本地端到端测试的窄化 Debug 启动夹具。
///
/// 它只能预填私聊、建群与群输入框中的表单取值，绝不会绕过已认证目录、开房或发消息路径。
struct V2LiveLocalAccountE2EConversationLaunchFixture: Sendable, Equatable {
    /// 私聊目标账号名。
    let directTargetHandle: String?
    /// 预填的初始消息正文。
    let initialMessage: String?
    /// 预填的提及账号名列表。
    let initialMentionHandles: String?
    /// 预填的群标题。
    let initialGroupTitle: String?
    /// 预填的群成员账号名列表。
    let initialGroupMemberHandles: String?

    /// 保存预填取值；只保留去除首尾空白后非空的输入。
    ///
    /// - Parameters:
    ///   - directTargetHandle: 私聊目标账号名。
    ///   - initialMessage: 初始消息正文。
    ///   - initialMentionHandles: 提及账号名列表。
    ///   - initialGroupTitle: 群标题。
    ///   - initialGroupMemberHandles: 群成员账号名列表。
    init(
        directTargetHandle: String?,
        initialMessage: String?,
        initialMentionHandles: String?,
        initialGroupTitle: String?,
        initialGroupMemberHandles: String?
    ) {
        self.directTargetHandle = Self.nonEmptyValue(directTargetHandle)
        self.initialMessage = Self.nonEmptyValue(initialMessage)
        self.initialMentionHandles = Self.nonEmptyValue(initialMentionHandles)
        self.initialGroupTitle = Self.nonEmptyValue(initialGroupTitle)
        self.initialGroupMemberHandles = Self.nonEmptyValue(initialGroupMemberHandles)
    }

    /// 过滤空白取值。
    ///
    /// - Parameter value: 原始取值。
    /// - Returns: 去除首尾空白后非空的取值；否则为 `nil`。
    private static func nonEmptyValue(_ value: String?) -> String? {
        guard let value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return value
    }
}

#if DEBUG
/// 以固定设备标识提供身份，供本地端到端测试使用。
struct V2LiveLocalAccountE2ETestDeviceIdentityProvider: V2DeviceIdentityProvider {
    /// 固定返回的设备标识。
    let value: DeviceID

    /// 保存固定设备标识。
    ///
    /// - Parameter deviceID: 本次测试使用的设备标识。
    init(deviceID: DeviceID) {
        value = deviceID
    }

    /// 返回固定设备标识。
    ///
    /// - Returns: 构造时给出的设备标识。
    /// - Throws: 本实现不会抛出。
    func deviceID() async throws -> DeviceID { value }
}
#endif
