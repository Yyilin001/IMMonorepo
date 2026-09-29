import IMV2ServerApplication
import IMV2ServerContracts
import Foundation
import IMV2Core
import SwiftProtobuf

/// Core NATS 群通知的版本化进程间编码。
///
/// 五字节前缀可避免畸形 JSON 或未来的线路版本被误按当前 protobuf 解析。
/// PostgreSQL 仍是权威来源：加速载荷非法时降级为已校验的房间水位，信封非法时直接丢弃。
enum V2NATSGroupEventProtobufCodec {
    private static let magic: [UInt8] = [0x49, 0x4D, 0x4E, 0x47] // "IMNG"
    private static let version: UInt8 = 1
    private static let header = Data(magic + [version])
    private static let maximumGroupEvents = 64

    /// 判断载荷是否带有本编解码器的魔数与版本前缀。
    ///
    /// - Parameter payload: 待判断载荷。
    /// - Returns: 前缀匹配时为 `true`。
    static func recognizes(_ payload: Data) -> Bool {
        payload.count >= header.count
            && payload.prefix(header.count).elementsEqual(header)
    }

    /// 编码一条前台群事件通知。
    ///
    /// 群批量通知要求：非空、不超过 64 条、具有相同的房间与成员修订，
    /// 且全部事件都没有逐条受众或连接排除，以保证整批共享一次编码结果。
    ///
    /// - Parameter notification: 待编码通知。
    /// - Returns: 前缀加 protobuf 载荷。
    /// - Throws: 标识无法编码，或群批量不满足上述一致性要求时抛出
    ///   ``V2NATSGroupEventWakeBrokerError/invalidPayload``。
    static func encode(
        _ notification: V2ForegroundGroupEventNotification
    ) throws -> Data {
        var wire = IMV2InternalGroupEventNotification()
        switch notification {
        case .wake(let wake):
            wire.roomID = try identifierBytes(wake.roomID)
            wire.highWatermark = wake.highWatermark
            wire.wake = .init()
        case .directEvent(let event):
            wire.roomID = try identifierBytes(event.roomID)
            wire.highWatermark = event.highWatermark
            wire.directEvent = try directEvent(event)
        case .groupEvents(let events):
            guard let first = events.first,
                  let last = events.last,
                  events.count <= maximumGroupEvents,
                  let membershipRevision = first.groupMembershipRevision,
                  membershipRevision > 0,
                  first.recipientUserIDs.isEmpty,
                  first.excludedConnectionID == nil,
                  events.allSatisfy({ event in
                      event.roomID == first.roomID
                          && event.groupMembershipRevision == membershipRevision
                          && event.recipientUserIDs.isEmpty
                          && event.excludedConnectionID == nil
                  })
            else { throw V2NATSGroupEventWakeBrokerError.invalidPayload }
            var batch = IMV2InternalGroupEventBatch()
            batch.membershipRevision = membershipRevision
            batch.events = try events.map { event in
                var value = IMV2InternalGroupEvent()
                value.sourceEventID = try identifierBytes(event.sourceEventID)
                value.roomSequence = event.roomSequence
                value.projectionKind = event.projectionKind
                value.payload = event.payload
                return value
            }
            wire.roomID = try identifierBytes(first.roomID)
            wire.highWatermark = last.highWatermark
            wire.groupEvents = batch
        }
        var result = header
        result.append(try wire.serializedData())
        return result
    }

    /// 解码一条前台群事件通知。
    ///
    /// 信封、房间标识或水位不合法时返回 `nil`；正文不合法时降级为纯水位唤醒，
    /// 使接收端仍能按持久化房间日志补齐内容。群批量要求序号严格递增且最后一条与水位一致。
    ///
    /// - Parameter payload: 待解码载荷。
    /// - Returns: 解码结果；无法识别时返回 `nil`。
    static func decode(
        _ payload: Data
    ) -> V2ForegroundGroupEventNotification? {
        guard recognizes(payload), payload.count > header.count,
              let wire = try? IMV2InternalGroupEventNotification(
                  serializedBytes: payload.dropFirst(header.count)
              ),
              let roomUUID = uuid(wire.roomID),
              wire.highWatermark > 0
        else { return nil }
        let roomID = RoomID(uuid: roomUUID)
        let wake = V2ForegroundGroupEventNotification.wake(.init(
            roomID: roomID,
            highWatermark: wire.highWatermark
        ))
        switch wire.body {
        case .wake, nil:
            return wake
        case .directEvent(let direct):
            guard direct.roomSequence == wire.highWatermark,
                  direct.roomSequence > 0,
                  !direct.projectionKind.isEmpty,
                  !direct.payload.isEmpty,
                  let sourceEventUUID = uuid(direct.sourceEventID)
            else { return wake }
            let recipientValues = direct.recipientUserIds.compactMap(uuid)
            let recipients = Set(recipientValues.map(UserID.init(uuid:)))
            let isExactAudience = !recipients.isEmpty
                && recipientValues.count == direct.recipientUserIds.count
                && recipients.count == direct.recipientUserIds.count
                && !direct.hasGroupMembershipRevision
            let isGroupAudience = direct.recipientUserIds.isEmpty
                && direct.hasGroupMembershipRevision
                && direct.groupMembershipRevision > 0
                && !direct.hasExcludedConnectionID
            guard isExactAudience || isGroupAudience else { return wake }
            let excludedConnectionID: UUID?
            if direct.hasExcludedConnectionID {
                guard let excluded = uuid(direct.excludedConnectionID) else {
                    return wake
                }
                excludedConnectionID = excluded
            } else {
                excludedConnectionID = nil
            }
            let revision = direct.hasGroupMembershipRevision
                ? direct.groupMembershipRevision
                : nil
            return .directEvent(.init(
                roomID: roomID,
                highWatermark: wire.highWatermark,
                sourceEventID: EventID(uuid: sourceEventUUID),
                roomSequence: direct.roomSequence,
                projectionKind: direct.projectionKind,
                payload: direct.payload,
                recipientUserIDs: recipients,
                groupMembershipRevision: revision,
                acceptedMembershipRevision: revision,
                excludedConnectionID: excludedConnectionID
            ))
        case .groupEvents(let batch):
            guard !batch.events.isEmpty,
                  batch.events.count <= maximumGroupEvents,
                  batch.membershipRevision > 0
            else { return wake }
            var previousSequence: UInt64 = 0
            var events: [V2DirectRoomLiveEvent] = []
            events.reserveCapacity(batch.events.count)
            for event in batch.events {
                guard event.roomSequence > previousSequence,
                      !event.projectionKind.isEmpty,
                      !event.payload.isEmpty,
                      let sourceEventUUID = uuid(event.sourceEventID)
                else { return wake }
                previousSequence = event.roomSequence
                events.append(.init(
                    roomID: roomID,
                    highWatermark: event.roomSequence,
                    sourceEventID: EventID(uuid: sourceEventUUID),
                    roomSequence: event.roomSequence,
                    projectionKind: event.projectionKind,
                    payload: event.payload,
                    recipientUserIDs: [],
                    groupMembershipRevision: batch.membershipRevision,
                    acceptedMembershipRevision: batch.membershipRevision,
                    excludedConnectionID: nil
                ))
            }
            guard previousSequence == wire.highWatermark else { return wake }
            return .groupEvents(events)
        }
    }

    /// 编码单条私聊实时事件。
    ///
    /// 受众按用户标识排序后写入，使同一受众集合产生字节一致的编码结果。
    ///
    /// - Parameter event: 待编码事件。
    /// - Returns: protobuf 私聊事件。
    /// - Throws: 标识无法编码时抛出
    ///   ``V2NATSGroupEventWakeBrokerError/invalidPayload``。
    private static func directEvent(
        _ event: V2DirectRoomLiveEvent
    ) throws -> IMV2InternalDirectEvent {
        var wire = IMV2InternalDirectEvent()
        wire.sourceEventID = try identifierBytes(event.sourceEventID)
        wire.roomSequence = event.roomSequence
        wire.projectionKind = event.projectionKind
        wire.payload = event.payload
        wire.recipientUserIds = try event.recipientUserIDs
            .sorted()
            .map(identifierBytes)
        if let revision = event.groupMembershipRevision {
            wire.groupMembershipRevision = revision
        }
        if let excludedConnectionID = event.excludedConnectionID {
            wire.excludedConnectionID = uuidBytes(excludedConnectionID)
        }
        return wire
    }

    /// 把标识编码为 16 字节 UUID。
    ///
    /// - Parameter identifier: 待编码标识。
    /// - Returns: 原始 UUID 字节。
    /// - Throws: 标识原始值不是合法 UUID 时抛出
    ///   ``V2NATSGroupEventWakeBrokerError/invalidPayload``。
    private static func identifierBytes<Tag>(
        _ identifier: V2Identifier<Tag>
    ) throws -> Data {
        guard let value = identifier.uuidValue else {
            throw V2NATSGroupEventWakeBrokerError.invalidPayload
        }
        return uuidBytes(value)
    }

    /// 把 UUID 写为 16 字节数据。
    ///
    /// - Parameter value: 待编码 UUID。
    /// - Returns: 原始字节。
    private static func uuidBytes(_ value: UUID) -> Data {
        var bytes = value.uuid
        return withUnsafeBytes(of: &bytes) { Data($0) }
    }

    /// 从 16 字节数据还原 UUID。
    ///
    /// - Parameter data: 待解码数据。
    /// - Returns: 还原的 UUID；长度不为 16 字节时返回 `nil`。
    private static func uuid(_ data: Data) -> UUID? {
        guard data.count == 16 else { return nil }
        return data.withUnsafeBytes { bytes in
            let value = bytes.bindMemory(to: UInt8.self)
            return UUID(uuid: (
                value[0], value[1], value[2], value[3],
                value[4], value[5], value[6], value[7],
                value[8], value[9], value[10], value[11],
                value[12], value[13], value[14], value[15]
            ))
        }
    }
}
