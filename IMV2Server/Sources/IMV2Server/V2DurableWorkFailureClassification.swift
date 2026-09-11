import Foundation

/// 判定一次持久化工作失败是瞬时的还是确定性的。
///
/// 判定只覆盖能够证明“重复执行不会改变结果”的错误：持久状态与不变量不一致，
/// 或不可变业务身份发生冲突。其余全部按瞬时处理，包括数据库连接、超时、死锁、
/// 路由读取失败和依赖不可用——它们的共同点是根因恢复后同一行仍可完成。
///
/// 判定保持保守是刻意的：把瞬时误判为确定性只是暂停一行，与分类前的行为相同；
/// 把确定性误判为瞬时会让该行以封顶退避持续重试，需要由“最老未完成工作年龄”
/// 告警而不是暂停计数来发现。任何无法归入下列错误类别的失败都必须保持瞬时。
///
/// - Parameter error: 工作器捕获到的失败。
/// - Returns: 该失败的类别。
func v2DurableWorkFailureKind(for error: any Error) -> V2DurableWorkFailureKind {
    switch error {
    case V2FanoutDeliveryError.inboxAlreadyCommitted:
        // 收件箱唯一键代表不可变的投递身份。同一身份已被提交而同步日志行缺失，
        // 重复执行只会反复命中同一冲突。
        return .deterministic
    // 消息与房间写入路径的 `corruptPersistenceState` 表示持久内容身份不再自洽
    // （载荷身份、投影状态、队列序号或既有回执），重复执行不会改变结论，
    // 继续重试只会让毒丸行持续占用预算，因此判为确定性并交给运维修复。
    //
    // 其余存储的同名 case 不在此列：它们在时钟、延迟或容量无法编码时走的是
    // **优雅降级**路径（例如 forward export 的 pendingDelay 无法编码时回退到重试
    // 策略），把这类失败判为确定性会破坏既有降级行为并让可恢复的工作停工。
    // 依据是 `Forward clocks preserve exports …` 与 `Propagation sequence exhaustion …`
    // 的数据库回归。
    case V2RoomWriteStoreError.corruptPersistenceState,
         V2ForwardInboxError.corruptPersistenceState,
         V2MessageEditStoreError.corruptPersistenceState,
         V2MessageWithdrawalStoreError.corruptPersistenceState,
         V2MessageReactionStoreError.corruptPersistenceState,
         V2ModerationStoreError.corruptPersistenceState,
         V2RoomMembershipStoreError.corruptPersistenceState,
         V2GroupMessagingStoreError.corruptPersistenceState,
         V2DirectMessagingStoreError.corruptPersistenceState:
        return .deterministic
    default:
        return .transient
    }
}
