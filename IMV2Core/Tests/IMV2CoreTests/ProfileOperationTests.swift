import Foundation
import Testing
@testable import IMV2Core

struct ProfileOperationTests {
    @Test("profile field patches keep unchanged, removal and replacement distinct")
    func patchSemantics() throws {
        let user=UserID(uuid:UUID()), operation=ProfileUpdateOperationID(uuid:UUID())
        let revision=try #require(V2ProfileRevision(rawValue:1))
        func command(_ patch:V2ProfilePatch) throws -> V2ProfileUpdateCommand {
            try .init(actorUserID:user,operationID:operation,expectedRevision:revision,patch:patch,firstSubmissionDeadlineMilliseconds:2000)
        }
        let name=try command(.init(displayName:.set(" Name ")))
        #expect(name.patch.displayName == .set("Name"))
        #expect(name.patch.avatar == .unchanged)
        let remove=try command(.init(displayName:.set("Name"),avatar:.remove))
        #expect(name.fingerprint != remove.fingerprint)
        #expect(name.fingerprint == (try command(.init(displayName:.set("Name")))).fingerprint)
        let differentDeadline=try V2ProfileUpdateCommand(actorUserID:user,operationID:operation,expectedRevision:revision,patch:name.patch,firstSubmissionDeadlineMilliseconds:2001)
        #expect(name.fingerprint != differentDeadline.fingerprint)
        #expect(throws:V2ProfileOperationValidationError.emptyPatch) { try V2ProfilePatch() }
        #expect(throws:V2ProfileOperationValidationError.invalidDeadline) {
            try V2ProfileUpdateCommand(actorUserID:user,operationID:operation,expectedRevision:revision,patch:name.patch,firstSubmissionDeadlineMilliseconds:UInt64.max)
        }
    }
    @Test("profile receipt bindings cannot confuse actors or payloads after Codable roundtrip")
    func receiptBinding() throws {
        let actor=UserID(uuid:UUID()), id=ProfileUpdateOperationID(uuid:UUID())
        let fingerprint=try V2OperationFingerprint(kind:.profileUpdate,fields:[.init("name",.text("one"))])
        let receipt=try V2ProfileOperationReceipt(actorUserID:actor,operationID:id,fingerprint:fingerprint,outcome:.closed,resolvedAtMilliseconds:1000)
        let decoded=try JSONDecoder().decode(V2ProfileOperationReceipt.self,from:JSONEncoder().encode(receipt))
        #expect(decoded == receipt)
        #expect(decoded.validates(actorUserID:actor,operationID:id,fingerprint:fingerprint))
        #expect(!decoded.validates(actorUserID:UserID(uuid:UUID()),operationID:id,fingerprint:fingerprint))
        #expect(!decoded.validates(actorUserID:actor,operationID:id,fingerprint:try .init(kind:.profileUpdate,fields:[.init("name",.text("two"))])))
        let result=V2ProfileOperationRecoveryResult.unresolved
        #expect(try JSONDecoder().decode(V2ProfileOperationRecoveryResult.self,from:JSONEncoder().encode(result)) == result)
    }
}
