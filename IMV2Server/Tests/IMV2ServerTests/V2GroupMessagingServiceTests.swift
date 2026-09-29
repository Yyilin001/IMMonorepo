@testable import IMV2ServerApplication
@testable import IMV2ServerContracts
import Foundation
import IMV2Core
@testable import IMV2Server
@testable import IMV2ServerInfrastructure
import Testing

@Suite("V2 group creation admission values")
struct V2GroupMessagingServiceTests {
    @Test("Frozen command counts reserve room for the owner without overflow", arguments: [Int.min, -1, 0, 4_999, 5_000, 99_999, 100_000, Int.max - 1, Int.max])
    func stagedCommandCountBounds(count: Int) throws {
        let actor = UserID(uuid: UUID())
        let identity = try V2OperationIdentity(accountID: actor, scope: .account(actor), operation: .groupRoom(.init(uuid: UUID())))
        func command() throws -> V2GroupCreationIntent {
            let mode = count >= 5_000 ? V2GroupCapacityClass.large : .standard
            return try .init(identity: identity, title: "boundary", capacityClass: mode,
                initialMemberCount: count, audienceDigest: V2GroupCreationAudience.digest([]), firstSubmissionDeadlineMilliseconds: 1_750_000_600_000)
        }
        if count < 0 || count >= 100_000 {
            #expect(throws: V2GroupCreationValidationError.invalidIntent) { try command() }
        } else {
            let value = try command()
            #expect(value.initialMemberCount + 1 == count + 1)
            #expect(value.capacityClass == V2GroupCapacityPolicy().capacityClass(forInitialMemberCount: count + 1))
        }
    }

    @Test("Manifest page numbers fit the PostgreSQL integer column",
          arguments: [Int.min, -1, 0, Int(Int32.max), Int(Int32.max) + 1, Int.max])
    func manifestPageNumberBounds(number: Int) throws {
        let members = [UserID(uuid: UUID())]
        if number < 0 || number > Int(Int32.max) {
            #expect(throws: V2GroupRoomCreationIntentStoreError.invalidIntent) {
                try V2GroupRoomCreationManifestPage(pageNumber: number, memberUserIDs: members, isFinal: true)
            }
        } else {
            let page = try V2GroupRoomCreationManifestPage(pageNumber: number, memberUserIDs: members, isFinal: true)
            #expect(page.pageNumber == number)
            #expect(page.digest.count == 32)
            #expect(page == (try V2GroupRoomCreationManifestPage(pageNumber: number, memberUserIDs: members, isFinal: true)))
        }
    }

    @Test("The frozen audience is canonical and excludes its owner")
    func forwardsCanonicalAudience() throws {
        let actor = UserID(uuid: UUID()), first = UserID(uuid: UUID()), second = UserID(uuid: UUID())
        let canonical = try V2GroupCreationAudience.canonical([second, first], actorUserID: actor)
        #expect(canonical == [first, second].sorted { $0.uuidValue!.uuidString < $1.uuidValue!.uuidString })
        #expect(throws: V2GroupCreationValidationError.invalidIntent) { try V2GroupCreationAudience.canonical([actor], actorUserID: actor) }
        #expect(throws: V2GroupCreationValidationError.invalidIntent) { try V2GroupCreationAudience.canonical([first, first], actorUserID: actor) }
    }
}
