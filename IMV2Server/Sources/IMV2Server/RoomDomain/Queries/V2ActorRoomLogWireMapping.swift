import IMV2ActorContracts

public extension V2ActorRoomLogEntryWire {
    init(_ value: V2GroupEventLogEntry) throws {
        try self.init(
            sourceEventID: value.sourceEventID, roomSequence: value.roomSequence,
            projectionKind: value.projectionKind, payload: value.payload
        )
    }

    func domainValue() throws -> V2GroupEventLogEntry {
        try V2GroupEventLogEntry(
            sourceEventID: sourceEventID, roomSequence: roomSequence,
            projectionKind: projectionKind, payload: payload
        )
    }
}

public extension V2ActorRoomLogPageWire {
    init(_ value: V2GroupEventLogPage) throws {
        try self.init(
            roomID: value.roomID, events: value.events.map(V2ActorRoomLogEntryWire.init),
            nextRoomSequence: value.nextRoomSequence, hasMore: value.hasMore,
            logTrimmedThroughRoomSequence: value.logTrimmedThroughRoomSequence
        )
    }

    func domainValue() throws -> V2GroupEventLogPage {
        try V2GroupEventLogPage(
            roomID: roomID, events: events.map { try $0.domainValue() },
            nextRoomSequence: nextRoomSequence, hasMore: hasMore,
            logTrimmedThroughRoomSequence: logTrimmedThroughRoomSequence
        )
    }
}

public extension V2ActorRoomLogSubscriptionWire {
    init(_ value: V2GroupEventSubscription) throws {
        try self.init(
            roomID: value.roomID, highWatermark: value.highWatermark,
            membershipRevision: value.membershipRevision
        )
    }

    func domainValue() throws -> V2GroupEventSubscription {
        try V2GroupEventSubscription(
            roomID: roomID, highWatermark: highWatermark, membershipRevision: membershipRevision
        )
    }
}
