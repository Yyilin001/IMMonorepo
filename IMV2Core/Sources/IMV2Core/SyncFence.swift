import Foundation

/// 服务端签发的不透明同步游标能力。
///
/// 服务端能力边界之外不应解析其内容。普通构造器仅检查非空，合成 Codable 解码不经过该校验；有效性与权限仍由服务端确认。
public struct V2SyncToken: Equatable, Codable, Sendable {
    /// 原始不透明值，保留输入，不裁剪空白。
    public let rawValue: String

    /// 要求移除首尾空白后非空，否则抛出 invalidIdentifier；保存原始字符串，不验证签名或有效期。
    public init(_ rawValue: String) throws {
        guard !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw V2CoreError.invalidIdentifier
        }
        self.rawValue = rawValue
    }
}

/// 将 ACK 限定到已签发增量范围或快照的不透明回执。
///
/// 服务端能力边界之外不应解析其内容。普通构造器仅检查非空，合成 Codable 解码不经过该校验；有效性与权限仍由服务端确认。
public struct V2SyncReceipt: Equatable, Codable, Sendable {
    /// 原始不透明值，保留输入，不裁剪空白。
    public let rawValue: String

    /// 要求移除首尾空白后非空，否则抛出 invalidIdentifier；保存原始字符串，不验证签名或有效期。
    public init(_ rawValue: String) throws {
        guard !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw V2CoreError.invalidIdentifier
        }
        self.rawValue = rawValue
    }
}

/// 同一同步代际中的顺序位置，代际与序号必须共同参与比较。
public struct SyncPosition: Equatable, Sendable {
    /// 正同步代际，最大为 Int64.max。
    public let generation: UInt64
    /// 本代际同步序号，允许零，最大为 Int64.max。
    public let sequence: UInt64

    /// 校验代际为 1 到 Int64.max、序号为 0 到 Int64.max，分别以 invalidGeneration 或 outOfRange 报告无效值。
    public init(generation: UInt64, sequence: UInt64) throws {
        guard generation > 0, generation <= UInt64(Int64.max) else {
            throw V2CoreError.invalidGeneration
        }
        guard sequence <= UInt64(Int64.max) else {
            throw V2RevisionValidationError.outOfRange
        }
        self.generation = generation
        self.sequence = sequence
    }
}

/// 待确认快照及其基线位置，确认必须同时匹配快照身份与完整位置。
public struct PendingReset: Equatable, Sendable {
    /// 待应用快照身份。
    public let snapshotID: SnapshotID
    /// 快照绑定的新代际和基线序号。
    public let basePosition: SyncPosition

    /// 保存快照与已校验位置，不创建快照或修改游标。
    public init(snapshotID: SnapshotID, basePosition: SyncPosition) {
        self.snapshotID = snapshotID
        self.basePosition = basePosition
    }
}

/// 设备游标的就绪或等待快照重置状态。
public enum DeviceSyncState: Equatable, Sendable {
    /// 可继续增量同步的当前位置。
    case ready(SyncPosition)
    /// 新快照等待精确确认，尚未进入增量就绪状态。
    case resetPending(PendingReset)
}

/// 设备同步重置的纯值状态机，只维护就绪与待确认转换，不执行存储、网络或回执认证。
public struct DeviceSyncCursor: Equatable, Sendable {
    /// 当前同步状态，只能通过状态机方法改变。
    public private(set) var state: DeviceSyncState

    /// 以指定已校验位置创建就绪游标。
    public init(readyAt position: SyncPosition) {
        self.state = .ready(position)
    }

    /// 仅从 ready 且新基线代际严格大于当前代际时开始重置，否则抛出 invalidResetTransition；不比较新旧序号大小。
    public mutating func beginReset(_ pendingReset: PendingReset) throws {
        guard case .ready(let current) = state,
              pendingReset.basePosition.generation > current.generation
        else {
            throw DeviceSyncCursorError.invalidResetTransition
        }
        state = .resetPending(pendingReset)
    }

    /// 确认当前等待的精确快照及基线位置，成功后转为 ready。
    ///
    /// - Parameters:
    ///   - snapshotID: 收到确认的快照身份。
    ///   - basePosition: 收到确认的完整代际及序号。
    /// - Returns: 按无待重置、快照不匹配、位置不匹配的顺序检查并返回拒绝原因；成功返回下一位置。
    ///
    /// 拒绝不修改状态，重复确认在已经 ready 后会返回 noResetPending。
    public mutating func acknowledgeSnapshot(
        snapshotID: SnapshotID,
        basePosition: SyncPosition
    ) -> SnapshotAcknowledgementResult {
        guard case .resetPending(let pending) = state else {
            return .rejected(.noResetPending)
        }
        guard pending.snapshotID == snapshotID else {
            return .rejected(.snapshotMismatch)
        }
        guard pending.basePosition == basePosition else {
            return .rejected(.generationOrWatermarkMismatch)
        }
        state = .ready(basePosition)
        return .accepted(nextPosition: basePosition)
    }
}

/// 同步游标状态转换错误。
public enum DeviceSyncCursorError: Error, Equatable, Sendable {
    /// 当前并非就绪状态，或新快照代际没有严格前进。
    case invalidResetTransition
}

/// 快照确认被拒绝的具体原因。
public enum SnapshotAcknowledgementRejection: Equatable, Sendable {
    /// 当前没有待确认快照。
    case noResetPending
    /// 快照身份不匹配。
    case snapshotMismatch
    /// 基线代际或序号不完全匹配。
    case generationOrWatermarkMismatch
}

/// 快照确认的状态机结果，与传输错误分离。
public enum SnapshotAcknowledgementResult: Equatable, Sendable {
    /// 确认通过，携带已进入的就绪位置。
    case accepted(nextPosition: SyncPosition)
    /// 确认未通过，游标状态保持原值。
    case rejected(SnapshotAcknowledgementRejection)
}
