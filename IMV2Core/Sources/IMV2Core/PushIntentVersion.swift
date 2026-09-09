import Foundation

/// 推送意图版本或会话申请预期代际无效。
public enum V2PushIntentVersionError: Error, Equatable, Sendable {
    /// 版本字段不满足规定的正数或可递增范围。
    case invalidVersion
}

/// 服务端授予的会话代际与客户端持久化递增的意图版本组合，不是授权凭证。
public struct V2PushIntentVersion: Equatable, Sendable {
    /// 服务端意图会话代际，范围为 1 到 Int64.max。
    public let epoch: UInt64
    /// 本代际的意图修订号，范围为 1 到 Int64.max。
    public let revision: UInt64

    /// 校验代际与修订号均为可存储的正 Int64 范围值，否则抛出 invalidVersion；不比较已有状态或自动递增。
    public init(epoch: UInt64, revision: UInt64) throws {
        guard epoch > 0, epoch <= UInt64(Int64.max), revision > 0, revision <= UInt64(Int64.max) else {
            throw V2PushIntentVersionError.invalidVersion
        }
        self.epoch = epoch
        self.revision = revision
    }
}

/// 基于预期代际比较后申请新会话的请求身份。
///
/// 响应丢失后必须保留同一 requestID 和 expectedEpoch 重试，服务端据此阻止迟到旧请求覆盖新会话。
public struct V2PushIntentSessionClaim: Equatable, Sendable {
    /// 会话申请的稳定 UUID，用于同次请求重放。
    public let requestID: UUID
    /// 期望服务端当前代际，允许零且必须小于 Int64.max，为递增保留空间。
    public let expectedEpoch: UInt64

    /// 保存稳定申请身份并要求 expectedEpoch 小于 Int64.max，否则抛出 invalidVersion；不在本地执行比较交换。
    public init(requestID: UUID, expectedEpoch: UInt64) throws {
        guard expectedEpoch < UInt64(Int64.max) else { throw V2PushIntentVersionError.invalidVersion }
        self.requestID = requestID
        self.expectedEpoch = expectedEpoch
    }
}
