import Foundation
import IMV2Core
@testable import IMV2Server
import Testing

// Fixed owner/replay and permanent proof are exercised through the actual
// PostgresV2GroupCreationOperationStore in the PostgreSQL integration suite.
// These former mock-coordinator cases retain the manifest admission boundary.
@Suite("Group creation frozen manifest")
struct V2RoutedGroupMessagingStoreTests {
    @Test("Malformed pages cannot change an accepted frozen audience", arguments: ["empty", "over-count", "duplicate", "oversized", "unordered", "owner", "offset"])
    func rejectsMalformedManifestPages(scenario: String) throws {
        let actor = UserID(uuid: UUID())
        let members = try (1...600).map { try UserID(String(format: "00000000-0000-0000-0000-%012x", $0)) }
        let identity = try V2OperationIdentity(accountID: actor, scope: .account(actor), operation: .groupRoom(.init(uuid: UUID())))
        let audience = Array(members.prefix(3))
        let intent = try V2GroupCreationIntent(identity: identity, title: "manifest", capacityClass: .standard,
            initialMemberCount: audience.count, audienceDigest: V2GroupCreationAudience.digest(audience), firstSubmissionDeadlineMilliseconds: 1_750_000_600_000)
        var page = audience, offset = 0
        switch scenario {
        case "empty": page = []
        case "over-count": page = Array(members.prefix(4))
        case "duplicate": page = [members[0], members[0], members[1]]
        case "oversized": page = Array(members.prefix(513))
        case "unordered": page.reverse()
        case "owner": page = [actor]
        default: offset = 4
        }
        #expect(throws: V2GroupCreationValidationError.invalidPage) { try V2GroupCreationAppendRequest(intent: intent, offset: offset, memberUserIDs: page) }
        let valid = try V2GroupCreationAppendRequest(intent: intent, offset: 0, memberUserIDs: audience)
        let replay = try JSONDecoder().decode(V2GroupCreationAppendRequest.self, from: JSONEncoder().encode(valid))
        #expect(replay == valid)
        #expect(try V2GroupCreationAudience.prefixDigest(audience, acceptedMemberCount: audience.count) == intent.audienceDigest)
    }
}
