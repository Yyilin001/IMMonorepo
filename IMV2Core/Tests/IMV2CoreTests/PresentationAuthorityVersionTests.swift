import Foundation
import IMV2Core
import Testing

@Suite struct PresentationAuthorityVersionTests {
    @Test("independent committed authority domains form a partial order and preserve concurrent floors")
    func partialOrder() throws {
        let room = RoomID(uuid: UUID())
        let a = try V2PresentationAuthorityVersion(controlSequence: 3, roomID: room, membershipRevision: 2, permissionRevision: 1)
        let b = try V2PresentationAuthorityVersion(controlSequence: 2, roomID: room, membershipRevision: 3, permissionRevision: 2)
        #expect(!a.isAtLeast(b) && !b.isAtLeast(a))
        let merged = try a.merged(with: b)
        #expect(merged.isAtLeast(a) && merged.isAtLeast(b))
        #expect(merged.controlSequence == 3 && merged.membershipRevision == 3 && merged.permissionRevision == 2)
        #expect(try merged.merged(with: a) == merged)
        let different = try V2PresentationAuthorityVersion(controlSequence: 99, roomID: .init(uuid: UUID()), membershipRevision: 99, permissionRevision: 99)
        #expect(!different.isAtLeast(a))
        #expect(throws: V2ResourceValidationError.invalidPresentationLease) { try different.merged(with: a) }
    }

    @Test("missing direct route can advance to an established room without erasing control order")
    func directRoute() throws {
        let missing = try V2PresentationAuthorityVersion(controlSequence: 4, roomID: nil, membershipRevision: 0, permissionRevision: 0)
        let created = try V2PresentationAuthorityVersion(controlSequence: 4, roomID: .init(uuid: UUID()), membershipRevision: 0, permissionRevision: 0)
        #expect(created.isAtLeast(missing) && created != missing && !missing.isAtLeast(created))
        #expect(try missing.merged(with: created) == created)
        #expect(missing.matches(.directConversation, permittingMissingDirectRoom: true))
        #expect(!missing.matches(.directConversation))
    }

    @Test("negative observations are context bound and versionless JSON is rejected")
    func denialContract() throws {
        let key = V2ProfileViewLookupKey(userID: .init(uuid: UUID()), context: .room(.init(uuid: UUID())))
        let version = V2PresentationAuthorityVersion.fixture(key, contextRevision: 3, controlSequence: 4, permissionRevision: 2)
        let denial = try V2PresentationDenial(key: key, authorityVersion: version)
        let bytes = try JSONEncoder().encode(denial)
        #expect(try JSONDecoder().decode(V2PresentationDenial.self, from: bytes) == denial)
        var fields = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(Set(fields.keys) == ["key", "authorityVersion"])
        fields.removeValue(forKey: "authorityVersion")
        let old = try JSONSerialization.data(withJSONObject: fields)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(V2PresentationDenial.self, from: old) }
        #expect(throws: V2ResourceValidationError.invalidPresentationLease) {
            try V2PresentationDenial(key: .init(userID: key.userID, context: .relationship), authorityVersion: version)
        }
        #expect(throws: V2ResourceValidationError.invalidPresentationLease) {
            try V2PresentationAuthorityVersion(controlSequence: UInt64.max, roomID: nil, membershipRevision: 0, permissionRevision: 0)
        }
        #expect(throws: V2ResourceValidationError.invalidPresentationLease) {
            try V2PresentationAuthorityVersion(controlSequence: 1, roomID: nil, membershipRevision: 1, permissionRevision: 0)
        }
    }
}
