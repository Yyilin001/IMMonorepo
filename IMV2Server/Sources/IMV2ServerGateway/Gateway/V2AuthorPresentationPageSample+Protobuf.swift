import IMV2ServerApplication
import IMV2ServerContracts
import IMV2Core

extension V2AuthorPresentationPageSample {
    init?(page: IMV2GroupEventPage) {
        guard let room = try? RoomID(page.roomID) else { return nil }
        self.init(roomID: room, events: page.events.prefix(Self.maximumEvents).lazy.compactMap { event in
            guard let source = try? EventID(event.sourceEventID) else { return nil }
            return try? V2GroupEventLogEntry(sourceEventID: source, roomSequence: event.roomSequence,
                projectionKind: event.projectionKind, payload: event.payload)
        })
    }
}
