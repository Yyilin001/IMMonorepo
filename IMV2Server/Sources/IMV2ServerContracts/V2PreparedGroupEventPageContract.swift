import Foundation
import IMV2Core

package struct V2PreparedGroupEventPageKey: Hashable, Sendable {
    package let protocolVersion: UInt8
    package let roomID: String
    package let firstEventID: String
    package let lastEventID: String
    package let firstRoomSequence: UInt64
    package let lastRoomSequence: UInt64
    package let eventCount: Int
    package let nextRoomSequence: UInt64
    package let hasMore: Bool

    package init(
        protocolVersion: UInt8,
        roomID: String,
        firstEventID: String,
        lastEventID: String,
        firstRoomSequence: UInt64,
        lastRoomSequence: UInt64,
        eventCount: Int,
        nextRoomSequence: UInt64,
        hasMore: Bool
    ) {
        self.protocolVersion = protocolVersion
        self.roomID = roomID
        self.firstEventID = firstEventID
        self.lastEventID = lastEventID
        self.firstRoomSequence = firstRoomSequence
        self.lastRoomSequence = lastRoomSequence
        self.eventCount = eventCount
        self.nextRoomSequence = nextRoomSequence
        self.hasMore = hasMore
    }
}

/// Encoding is supplied by the transport adapter; event materialization stays lazy.
package protocol V2GroupEventPageEncoding: Sendable {
    func frame(for key: V2PreparedGroupEventPageKey, events: () -> [V2GroupEventLogEntry]) throws -> V2Frame
    func repeatedFieldBytes(_ entry: V2GroupEventLogEntry) -> Int
    func envelopeBytes(roomID: String, eventFieldBytes: Int, nextRoomSequence: UInt64, hasMore: Bool) -> Int
}

package struct V2PreparedGroupEventPageEncodingContext: Sendable {
    package let requestID: UInt64
    package let frameVersion: UInt8
    package let maximumGroupEventPagePayloadBytes: Int
    package let encoder: any V2GroupEventPageEncoding
    package var captureAuthorSample: Bool

    package init(requestID: UInt64, frameVersion: UInt8,
                 maximumGroupEventPagePayloadBytes: Int,
                 encoder: any V2GroupEventPageEncoding,
                 captureAuthorSample: Bool = false) {
        self.requestID = requestID
        self.frameVersion = frameVersion
        self.maximumGroupEventPagePayloadBytes = maximumGroupEventPagePayloadBytes
        self.encoder = encoder
        self.captureAuthorSample = captureAuthorSample
    }
}

/// 已编码的事件分页响应。
package struct V2PreparedGroupEventPageResponse: Sendable {
    package let frame: V2Frame
    package let roomID: RoomID
    package let nextRoomSequence: UInt64
    package let hasMore: Bool
    package var authorSample: V2AuthorPresentationPageSample?

    package init(frame: V2Frame, roomID: RoomID, nextRoomSequence: UInt64,
                 hasMore: Bool, authorSample: V2AuthorPresentationPageSample? = nil) {
        self.frame = frame
        self.roomID = roomID
        self.nextRoomSequence = nextRoomSequence
        self.hasMore = hasMore
        self.authorSample = authorSample
    }
}

/// 预编码拉取的结果。
package enum V2PreparedGroupEventPullResult: Sendable {
    /// 已按帧编码完成的响应。
    case prepared(V2PreparedGroupEventPageResponse)
    /// 未编码的普通分页。
    case page(V2GroupEventLogPage)
    /// 事件过大，无法在协商上限内编码。
    case eventTooLarge
}

/// 支持预编码分页返回的扩展持久化能力。
package protocol V2PreparedGroupEventLogStore: V2GroupEventLogStore {
    /// 按编码上下文拉取可直接回传的分页。
    ///
    /// - Parameters:
    ///   - roomID: 目标房间。
    ///   - actorUserID: 发起拉取的用户。
    ///   - afterRoomSequence: 起始序号。
    ///   - pageSize: 本页最多返回的事件数。
    ///   - context: 帧与压缩协商上下文。
    /// - Returns: 预编码结果。
    /// - Throws: 无资格、事件过大或持久化失败时抛出。
    func pullPrepared(
        roomID: RoomID,
        actorUserID: UserID,
        afterRoomSequence: UInt64,
        pageSize: Int,
        context: V2PreparedGroupEventPageEncodingContext
    ) async throws -> V2PreparedGroupEventPullResult
}
