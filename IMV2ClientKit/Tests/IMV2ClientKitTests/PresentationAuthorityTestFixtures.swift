@testable import IMV2ClientKit
import Testing
import Foundation
import IMV2Core

// Explicit genesis observations for existing transport/content fixtures. Wire
// decoding still requires authorityVersion; production has no versionless API.
extension V2PresentationAuthorityVersion {
    static func fixture(_ key: V2ProfileViewLookupKey, contextRevision: UInt64 = 0, controlSequence: UInt64 = 0,
                        permissionRevision: UInt64 = 0) -> Self {
        let room: RoomID?
        switch key.context {
        case .relationship: room = nil
        case .directConversation: room = try! RoomID("fixture-direct-room")
        case .room(let value), .groupJoinReview(let value): room = value
        }
        return try! .init(controlSequence: controlSequence, roomID: room,
            membershipRevision: room == nil ? 0 : contextRevision, permissionRevision: permissionRevision)
    }
}
extension V2PresentationAccessLease {
    init(actorUserID: UserID, deviceID: DeviceID, key: V2ProfileViewLookupKey,
         profileRevision: V2ProfileRevision, visibilityRevision: V2ProfileRevision,
         contextRevision: UInt64, observedAt: Date, validUntil: Date) throws {
        try self.init(actorUserID: actorUserID, deviceID: deviceID, key: key,
            profileRevision: profileRevision, visibilityRevision: visibilityRevision, contextRevision: key.context == .relationship ? 0 : contextRevision,
            authorityVersion: .fixture(key, contextRevision: contextRevision), observedAt: observedAt, validUntil: validUntil)
    }
}
extension V2ProfilePresentationBatchEntry {
    static func unavailable(_ key: V2ProfileViewLookupKey) -> Self {
        .unavailable(try! .init(key: key, authorityVersion: .fixture(key)))
    }
}

import IMV2ClientKit
extension V2ReceivedAuthorPresentationEntry {
    static func unavailable(_ key: V2ProfileViewLookupKey, until: ContinuousClock.Instant) -> Self {
        .unavailable(try! .init(key: key, authorityVersion: .fixture(key)), until: until)
    }
}
extension V2ProfilePresentationBatch {
    init(presentations: [V2ProfileViewLookupKey: V2AuthorizedProfilePresentation], unavailable: Set<V2ProfileViewLookupKey>,
         serverNow: Date, avatars: [V2ProfileViewLookupKey: V2ResourceAvatarAccess] = [:], retryable: Set<V2ProfileViewLookupKey> = []) {
        self.init(presentations: presentations, denials: Dictionary(uniqueKeysWithValues: unavailable.map { ($0, .fixture($0)) }),
            serverNow: serverNow, avatars: avatars, retryable: retryable)
    }
}


extension V2AuthorPresentationDelta {
    init(streamID: UUID, viewID: UUID, sequence: UInt64, actorUserID: UserID, deviceID: DeviceID,
         roomID: RoomID, batch: V2ProfilePresentationBatchResponse, retryAfterMilliseconds: Int64? = nil) throws {
        try self.init(streamID: streamID, viewID: viewID, sequence: sequence, actorUserID: actorUserID,
            deviceID: deviceID, roomID: roomID, serverViewAgeMilliseconds: 0, batch: batch,
            retryAfterMilliseconds: retryAfterMilliseconds)
    }
}
extension V2AuthorPresentationReceipt {
    init(streamID: UUID, viewID: UUID, roomID: RoomID, sequence: UInt64, userIDs: [UserID]) throws {
        try self.init(streamID: streamID, viewID: viewID, roomID: roomID, sequence: sequence,
            userIDs: userIDs, minimumRemainingMilliseconds: 120_000)
    }
}


extension V2ResourceAvatarAccess {
    init(mediaID: MediaID, variantID: ResourceVariantID, version: Int64,
         checksum: V2ResourceChecksum, plan: V2ResourceTransferPlan) throws {
        try self.init(mediaID: mediaID, variantID: variantID, version: version,
            checksum: checksum, byteCount: plan.expectedByteCount, plan: plan)
    }
}


extension V2ResourceDownloadCache {
    func avatar(_ access: V2ResourceAvatarAccess, home: V2ResourceHome) async throws -> V2ResourceCachedFile {
        let plan = try #require(access.plan)
        let remaining = plan.expiresAt.timeIntervalSinceNow
        let deadline = ContinuousClock.now + .seconds(max(0, remaining))
        return try await avatar(.init(avatar: access, home: home, deadline: deadline,
            downloadDeadline: deadline, validate: { true }))
    }
}
