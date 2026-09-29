import IMV2ServerContracts

func v2TelemetryCommand(for envelope: IMV2Envelope) -> V2GatewayTelemetryCommand {
    switch envelope.body {
    case .messageSendOperation: .messageSendOperation
    case .messageSendOperationRecover: .messageSendOperationRecover
    case .recordReadReceipt: .recordReadReceipt
    case .syncPull: .syncPull
    case .syncAck: .syncAck
    case .syncSnapshot: .syncSnapshot
    case .snapshotPagePull: .snapshotPagePull
    case .snapshotAck: .snapshotAck
    case .listRoomMembers: .listRoomMembers
    case .userRoomDirectoryList: .userRoomDirectoryList
    case .accountRoomChangesStart: .accountRoomChangesStart
    case .roomSyncStateBatch: .roomSyncStateBatch
    case .roomLatestVisibleBatch: .roomLatestVisibleBatch
    case .getGroupRolePolicyBaseline: .getGroupRolePolicyBaseline
    case .groupEventPull: .groupEventPull
    case .groupEventSubscribe: .groupEventSubscribe
    case .groupEventUnsubscribe: .groupEventUnsubscribe
    default: .unsupported
    }
}

/// 以两个单调时钟时刻计算指标使用的完整毫秒数。
///
/// - Parameters:
///   - startedAt: 操作开始时刻。
///   - now: 本次观测时刻；早于开始时刻时按无效观测处理。
/// - Returns: 向下截断的非负毫秒数；时刻逆序或转换溢出时返回零。
func v2ElapsedMilliseconds(since startedAt: ContinuousClock.Instant, now: ContinuousClock.Instant) -> UInt64 {
    v2ElapsedMilliseconds(startedAt.duration(to: now))
}

/// 将耗时转换为遥测使用的完整毫秒数，避免指标转换失败影响业务结果。
///
/// - Parameter elapsed: 来自单调时钟的耗时。
/// - Returns: 正耗时向下截断后的 `UInt64` 毫秒值；非正耗时或乘加运算溢出时返回零。
///
/// 小于一毫秒的有效耗时与无效观测都会得到零，调用方不能仅凭零值区分两者。
func v2ElapsedMilliseconds(_ elapsed: Duration) -> UInt64 {
    guard elapsed > .zero else { return 0 }
    let components = elapsed.components
    let (whole, overflow) = UInt64(components.seconds).multipliedReportingOverflow(by: 1_000)
    let fraction = UInt64(components.attoseconds / 1_000_000_000_000_000)
    let (milliseconds, sumOverflow) = whole.addingReportingOverflow(fraction)
    return overflow || sumOverflow ? 0 : milliseconds
}
