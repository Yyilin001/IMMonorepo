import Foundation
import IMV2Core

/// 混合群组房间事件提交后产生的纯元数据工作项。
///
/// 其载荷刻意不包含事件内容与接收者身份。
public struct V2GroupEventWake: Equatable, Sendable {
    public let roomID: RoomID
    public let highWatermark: UInt64

    public init(roomID: RoomID, highWatermark: UInt64) {
        self.roomID = roomID
        self.highWatermark = highWatermark
    }
}

public protocol V2GroupEventWakePublishing: Sendable {
    func publish(_ wake: V2GroupEventWake) async throws
    /// Each submitted ordinal settles once, including the caller's persistence
    /// callback. Cancellation/fatal callback failure stops dispatch and drains
    /// submitted work; unsubmitted ordinals may remain when this throws.
    func publishBatch(_ wakes: [V2GroupEventWake],
        onSettled: @escaping @Sendable (Int, Result<Void, any Error>) async throws -> Void) async throws
}

public extension V2GroupEventWakePublishing {
    /// Bounded local/test implementation. Production Actor publishing overrides
    /// this with destination-aware preparation under the same owned window.
    func publishBatch(_ wakes: [V2GroupEventWake],
        onSettled: @escaping @Sendable (Int, Result<Void, any Error>) async throws -> Void) async throws {
        let execute: @Sendable (Int) async -> Result<Void, any Error> = { index in
            do {
                try Task.checkCancellation()
                let result: Result<Void, any Error>
                do { try await self.publish(wakes[index]); result = .success(()) }
                catch is CancellationError { throw CancellationError() }
                catch { result = .failure(error) }
                try await onSettled(index, result)
                return .success(())
            } catch { return .failure(error) }
        }
        let terminal = await withTaskGroup(of: Result<Void, any Error>.self) { group in
            var next = 0
            var failure: (any Error)?
            while next < min(8, wakes.count), !Task.isCancelled {
                let index = next; next += 1
                group.addTask { await execute(index) }
            }
            if Task.isCancelled { failure = CancellationError() }
            while let result = await group.next() {
                if case .failure(let error) = result, failure == nil { failure = error }
                if Task.isCancelled, failure == nil { failure = CancellationError() }
                if failure == nil, next < wakes.count {
                    let index = next; next += 1
                    group.addTask { await execute(index) }
                }
            }
            return failure
        }
        if let terminal { throw terminal }
    }
}
