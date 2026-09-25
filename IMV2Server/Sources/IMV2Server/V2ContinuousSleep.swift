import Foundation

/// 基于连续时钟的可取消延迟，计入系统休眠时间。
/// 显式截止时间可避免 Apple Swift 优化构建中，Task.sleep(for:)
/// 跨模块特化导致的崩溃（swiftlang/swift#86204）。
public func v2Sleep(for duration: Duration) async throws {
    let clock = ContinuousClock()
    try await clock.sleep(until: clock.now.advanced(by: duration))
}
