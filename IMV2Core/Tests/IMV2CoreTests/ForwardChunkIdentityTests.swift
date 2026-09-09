import Foundation
import Testing
@testable import IMV2Core

@Suite("Forward chunk UUID contract")
struct ForwardChunkIdentityTests {
    @Test("independent SHA-256 vectors produce stable PostgreSQL UUID identities")
    func goldenVectors() throws {
        let plan = try MessageForwardOperationID("00000000-0000-0000-0000-00000000f001")
        for (index, expected): (UInt64, String) in [
            (0, "59993946-8967-8ccb-9846-764840d87627"),
            (1, "41f95845-6d1c-8b1c-b362-ca68cef9c21f"),
            (UInt64(Int64.max), "1b4622b6-de15-8e72-9f46-742f8429e35b")
        ] {
            let actual = try V2ForwardChunkIdentity.operationID(planID: plan, chunkIndex: index)
            #expect(actual.uuidValue == UUID(uuidString: expected))
            #expect(actual.rawValue.count == 36)
        }
        let ids = try (0..<1_000).map { try V2ForwardChunkIdentity.operationID(planID: plan, chunkIndex: UInt64($0)) }
        #expect(Set(ids).count == 1_000)
        #expect(try V2ForwardChunkIdentity.operationID(planID: .init(uuid: UUID()), chunkIndex: 0) != ids[0])
    }

    @Test("invalid parents and unrepresentable storage indices fail before hashing")
    func invalidInputs() throws {
        #expect(throws: V2CoreError.invalidIdentifier) {
            try V2ForwardChunkIdentity.operationID(planID: .init("opaque-plan"), chunkIndex: 0)
        }
        #expect(throws: V2CoreError.invalidNonNegativeValue) {
            try V2ForwardChunkIdentity.operationID(planID: .init(uuid: UUID()), chunkIndex: UInt64(Int64.max) + 1)
        }
    }
}
