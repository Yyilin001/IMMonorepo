import Foundation

extension ConversationMessage {
    var positiveServerSequence: UInt64 {
        get throws { try imPositiveUInt64Sequence(serverSequence, field: "server_sequence") }
    }

    var positiveTimelineSequence: UInt64 {
        get throws { try imPositiveUInt64Sequence(timelineSequence, field: "timeline_sequence") }
    }
}

extension ConversationDomainEvent {
    var positiveAggregateSequence: UInt64 {
        get throws { try imPositiveUInt64Sequence(aggregateSequence, field: "aggregate_sequence") }
    }
}

extension ContactDomainEvent {
    var positiveOwnerSequence: UInt64 {
        get throws { try imPositiveUInt64Sequence(ownerSequence, field: "owner_sequence") }
    }
}

extension ConversationTimelineNotice {
    var positiveTimelineSequence: UInt64 {
        get throws { try imPositiveUInt64Sequence(timelineSequence, field: "timeline_sequence") }
    }
}

extension MessageFavorite {
    var positiveServerSequence: UInt64 {
        get throws { try imPositiveUInt64Sequence(serverSequence, field: "server_sequence") }
    }
}

extension MessageVisibilityOverride {
    var positiveServerSequence: UInt64 {
        get throws { try imPositiveUInt64Sequence(serverSequence, field: "server_sequence") }
    }
}

extension ConversationVisibilityOverride {
    var nonNegativeHiddenBeforeSequence: UInt64? {
        get throws {
            try hiddenBeforeSequence.map {
                try imNonNegativeUInt64Sequence($0, field: "hidden_before_sequence")
            }
        }
    }
}

extension ConversationMediaAssetReference {
    var positiveServerSequence: UInt64 {
        get throws { try imPositiveUInt64Sequence(serverSequence, field: "server_sequence") }
    }
}

extension ConversationMediaAssetReferenceDirectory {
    var positiveServerSequence: UInt64 {
        get throws { try imPositiveUInt64Sequence(serverSequence, field: "server_sequence") }
    }
}

extension ConversationMessageSearchIndex {
    var positiveServerSequence: UInt64 {
        get throws { try imPositiveUInt64Sequence(serverSequence, field: "server_sequence") }
    }
}
