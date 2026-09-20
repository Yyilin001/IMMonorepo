import IMV2Core

/// 通知在线连接有新的持久化个人同步记录可拉取。
public protocol V2LiveSyncNotifier: Sendable {
    func notifySyncAvailable(userID: UserID, eventID: UInt64, highWatermark: UInt64) async
}

