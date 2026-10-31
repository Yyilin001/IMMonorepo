import Foundation
import IMV2Core
import IMV2ActorContracts
@testable import IMV2ServerApplication
import Testing

@Suite("Bounded author acknowledgement content identity")
struct V2AuthorPresentationFingerprintTests {
    @Test("independent content and authority changes cannot compare as an already applied value", arguments: [
        "name", "profile", "visibility", "group_name", "group_revision", "alias", "alias_revision",
        "clear_group", "clear_alias", "remove_avatar", "avatar_version", "avatar_checksum", "avatar_size",
        "permission", "control", "membership"
    ])
    func changesRemainVisible(field: String) throws {
        let original = FingerprintFixture()
        var changed = original
        switch field {
        case "name": changed.name = "New name"
        case "profile": changed.profile = 2
        case "visibility": changed.visibility = 2
        case "group_name": changed.nickname = "New group name"
        case "group_revision": changed.nicknameRevision = 2
        case "alias": changed.alias = "New private name"
        case "alias_revision": changed.aliasRevision = 2
        case "clear_group": changed.nickname = nil
        case "clear_alias": changed.alias = nil
        case "remove_avatar": changed.hasAvatar = false
        case "avatar_version": changed.avatarVersion = 2
        case "avatar_checksum": changed.checksum = String(repeating: "b", count: 64)
        case "avatar_size": changed.byteCount = 11
        case "permission": changed.permission = 2
        case "control": changed.control = 2
        case "membership": changed.membership = 4
        default: Issue.record("Unexpected field \(field)")
        }
        #expect(try original.fingerprint() != changed.fingerprint())
        var batch = V2AuthorPresentationFingerprint.Batch()
        let first = try original.prepare(in: &batch), second = try changed.prepare(in: &batch)
        #expect(first.fingerprint != second.fingerprint)
        #expect(batch.calculations == 2 && batch.count == 1)
    }

    @Test("a renewed lease or rotated download plan does not change content equality", arguments: [false, true])
    func temporaryAccessIsNotContent(removePlan: Bool) throws {
        let original = FingerprintFixture()
        var changed = original
        changed.now.addTimeInterval(10); changed.lifetime = 140
        changed.token = "rotated"; changed.hasPlan = !removePlan
        #expect(try original.fingerprint() == changed.fingerprint())
        var batch = V2AuthorPresentationFingerprint.Batch()
        let first = try original.prepare(in: &batch), second = try changed.prepare(in: &batch)
        #expect(first.fingerprint == second.fingerprint && first.retainedBytes == second.retainedBytes)
        #expect(batch.calculations == 1)
    }

    @Test("retained acknowledgement cost stays fixed for long names, aliases and avatar metadata")
    func retainedCostIsBounded() throws {
        var small = FingerprintFixture(); small.hasAvatar = false
        var rich = small
        rich.name = String(repeating: "名", count: 26)
        rich.nickname = String(repeating: "群", count: 26)
        rich.alias = String(repeating: "备", count: 26)
        rich.hasAvatar = true; rich.token = String(repeating: "x", count: 7_500)
        let smallCost = try V2ActorPayloadBudget.retainedBytes(of: small.fingerprint())
        let richCost = try V2ActorPayloadBudget.retainedBytes(of: rich.fingerprint())
        #expect(smallCost == richCost && richCost <= 512)
    }

    @Test("batch hashing shares identical content across recipients and keeps private aliases separate")
    func recipientContent() throws {
        var first = FingerprintFixture(); first.hasAlias = false
        var second = first; second.viewer = .init(uuid: UUID()); second.device = .init(uuid: UUID())
        var batch = V2AuthorPresentationFingerprint.Batch()
        let a = try first.prepare(in: &batch), b = try second.prepare(in: &batch)
        #expect(a.fingerprint == b.fingerprint && batch.calculations == 1)
        let firstValue = try first.presentation().0, secondValue = try second.presentation().0
        #expect(firstValue.lease.actorUserID != secondValue.lease.actorUserID)
        first.hasAlias = true; second.hasAlias = true
        let privateA = try first.prepare(in: &batch), privateB = try second.prepare(in: &batch)
        #expect(privateA.fingerprint != privateB.fingerprint && batch.calculations == 3)
    }

    @Test("batch content memory stays bounded even when handed more keys than an authority batch")
    func batchBound() throws {
        var batch = V2AuthorPresentationFingerprint.Batch()
        for _ in 0..<101 { _ = try FingerprintFixture().prepare(in: &batch) }
        #expect(batch.count == 100 && batch.calculations == 101)
    }
}

private struct FingerprintFixture {
    let author = UserID(uuid: UUID())
    var viewer = UserID(uuid: UUID()), device = DeviceID(uuid: UUID())
    let room = RoomID(uuid: UUID()), media = MediaID(uuid: UUID()), variant = ResourceVariantID(uuid: UUID())
    var name = "Author", nickname: String? = "Group name", alias: String? = "Private name"
    var profile: UInt64 = 1, visibility: UInt64 = 1, nicknameRevision: UInt64 = 1, aliasRevision: UInt64 = 1
    var control: UInt64 = 0, membership: UInt64 = 3, permission: UInt64 = 1
    var now = Date(timeIntervalSince1970: 1_000), lifetime: TimeInterval = 120
    var hasAvatar = true, hasPlan = true, hasAlias = true
    var avatarVersion: Int64 = 1, byteCount: Int64 = 10
    var checksum = String(repeating: "a", count: 64), token = "first"

    func fingerprint() throws -> V2AuthorPresentationFingerprint {
        let (value, avatar) = try presentation()
        return try .init(value, avatar: avatar)
    }

    func prepare(in batch: inout V2AuthorPresentationFingerprint.Batch) throws -> V2AuthorPresentationFingerprint.Batch.Prepared {
        let (value, avatar) = try presentation()
        return try batch.prepare(value, avatar: avatar)
    }

    func presentation() throws -> (V2AuthorizedProfilePresentation, V2ResourceAvatarAccess?) {
        let profile = try #require(V2ProfileRevision(rawValue: profile))
        let visibility = try #require(V2ProfileRevision(rawValue: visibility))
        let key = V2ProfileViewLookupKey(userID: author, context: .room(room))
        let view = try V2ProfileView(userID: author,
            publicIdentity: .init(userID: author, handle: .init("author"), displayName: name, accountKind: .regular),
            avatar: hasAvatar ? .init(mediaID: media) : nil, state: .active, revision: profile, visibilityRevision: visibility)
        let lease = try V2PresentationAccessLease(actorUserID: viewer, deviceID: device, key: key,
            profileRevision: profile, visibilityRevision: visibility, contextRevision: membership,
            authorityVersion: .init(controlSequence: control, roomID: room, membershipRevision: membership, permissionRevision: permission),
            observedAt: now, validUntil: now.addingTimeInterval(lifetime))
        let value = try V2AuthorizedProfilePresentation(view: view, lease: lease,
            groupMember: .init(roomID: room, userID: author, groupNickname: nickname,
                revision: #require(V2ProfileRevision(rawValue: nicknameRevision))),
            contactAlias: hasAlias ? .init(ownerUserID: viewer, targetUserID: author, remarkName: alias,
                revision: #require(V2ProfileRevision(rawValue: aliasRevision))) : nil)
        let access: V2ResourceAvatarAccess?
        if hasAvatar {
            let checksum = try V2ResourceChecksum(value: checksum)
            let url = try #require(URL(string: "https://objects.invalid/avatar?token=" + token))
            access = try .init(mediaID: media, variantID: variant, version: avatarVersion, checksum: checksum,
                byteCount: byteCount, plan: hasPlan ? .init(mode: .httpGet, url: url,
                    expiresAt: now.addingTimeInterval(60), expectedByteCount: byteCount, checksum: checksum) : nil)
        } else { access = nil }
        return (value, access)
    }
}
