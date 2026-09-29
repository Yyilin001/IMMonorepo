import Foundation
import IMV2Core

/// Request-local, bounded references to the exact events actually returned.
/// This is neither an authorization cache nor part of a wire/persistent DTO.
/// Prepared-page hits retain their shared encoded frame; no frame is decoded.
package struct V2AuthorPresentationPageSample: Sendable {
    package static let maximumEvents = 16, maximumBytes = 64 * 1_024, maximumAuthors = 8
    package let roomID: RoomID
    package let events: [V2GroupEventLogEntry]

    package init?(roomID: RoomID, events: some Sequence<V2GroupEventLogEntry>) {
        guard roomID.uuidValue != nil else { return nil }
        var selected: [V2GroupEventLogEntry] = [], bytes = 0
        for entry in events.prefix(Self.maximumEvents) {
            guard entry.payload.count <= Self.maximumBytes - bytes else { break }
            bytes += entry.payload.count
            if entry.projectionKind == "message" { selected.append(entry) }
        }
        guard !selected.isEmpty else { return nil }
        self.roomID = roomID; self.events = selected
    }


}
