/// 消息内容版本，取值范围为 `1...Int64.max`。
///
/// 进入幂等查询前即应构造此值，防止重放分支绕过持久化整数边界。
/// 此类型验证可表达范围；是否为当前消息版本仍由业务事务检查。
public struct V2MessageRevision: Equatable, Hashable, Sendable {
    /// 可直接绑定到有符号数据库整数列的已验证值。
    public let signedValue: Int64
    /// 用于协议边缘的无符号表示；转换保留原值。
    public var rawValue: UInt64 { UInt64(signedValue) }

    /// 验证协议输入并构造持久化版本或水位。
    ///
    /// - Parameter rawValue: 待验证的无符号数；具体零值语义见类型说明。
    /// - Throws: 输入不满足该类型范围时抛出 ``V2RevisionValidationError/outOfRange``。
    public init(_ rawValue: UInt64) throws {
        guard let value = Int64(exactly: rawValue), value > 0 else {
            throw V2RevisionValidationError.outOfRange
        }
        signedValue = value
    }
}

/// 成员资格栅栏版本，允许初始版本零，最大为 `Int64.max`。
///
/// 不使用截断或钳制转换，避免改变调用者预期的成员资格版本。
public struct V2MembershipRevision: Equatable, Hashable, Sendable {
    /// 可直接绑定到有符号数据库整数列的已验证值。
    public let signedValue: Int64
    /// 用于协议边缘的无符号表示；转换保留原值。
    public var rawValue: UInt64 { UInt64(signedValue) }

    /// 验证协议输入并构造持久化版本或水位。
    ///
    /// - Parameter rawValue: 待验证的无符号数；具体零值语义见类型说明。
    /// - Throws: 输入不满足该类型范围时抛出 ``V2RevisionValidationError/outOfRange``。
    public init(_ rawValue: UInt64) throws {
        guard let value = Int64(exactly: rawValue) else {
            throw V2RevisionValidationError.outOfRange
        }
        signedValue = value
    }
}

/// 版本或游标无法按领域约束写入持久化整数时的错误。
public enum V2RevisionValidationError: Error, Equatable, Sendable {
    /// 数值超出该类型允许的持久化范围。
    case outOfRange
}

/// 可持久化的房间日志水位，零表示空房间或尚未读取。
///
/// 水位只表达位置，不证明调用者有权访问相应房间历史。
public struct V2RoomCursor: Equatable, Hashable, Sendable {
    /// 可直接绑定到有符号数据库整数列的已验证值。
    public let signedValue: Int64
    /// 用于协议边缘的无符号表示；转换保留原值。
    public var rawValue: UInt64 { UInt64(signedValue) }

    /// 验证协议输入并构造持久化版本或水位。
    ///
    /// - Parameter rawValue: 待验证的无符号数；具体零值语义见类型说明。
    /// - Throws: 输入不满足该类型范围时抛出 ``V2RevisionValidationError/outOfRange``。
    public init(_ rawValue: UInt64) throws {
        guard let value = Int64(exactly: rawValue) else {
            throw V2RevisionValidationError.outOfRange
        }
        signedValue = value
    }
}
