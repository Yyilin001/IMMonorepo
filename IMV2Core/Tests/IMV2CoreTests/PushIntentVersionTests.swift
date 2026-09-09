import Foundation
@testable import IMV2Core
import Testing

@Suite("Push intent version bounds")
struct PushIntentVersionTests {
    @Test("published intent versions fit positive PostgreSQL bigint domains")
    func versionBounds() throws {
        #expect(try V2PushIntentVersion(epoch: 1, revision: UInt64(Int64.max)).revision == UInt64(Int64.max))
        for (epoch, revision) in [(UInt64(0), UInt64(1)), (1, 0), (UInt64.max, 1), (1, UInt64.max)] {
            #expect(throws: V2PushIntentVersionError.invalidVersion) { try V2PushIntentVersion(epoch: epoch, revision: revision) }
        }
    }

    @Test("a claim permits the initial epoch but cannot overflow its successor")
    func claimBounds() throws {
        let request = UUID()
        #expect(try V2PushIntentSessionClaim(requestID: request, expectedEpoch: 0).requestID == request)
        #expect(try V2PushIntentSessionClaim(requestID: request, expectedEpoch: UInt64(Int64.max) - 1).expectedEpoch == UInt64(Int64.max) - 1)
        for epoch in [UInt64(Int64.max), UInt64.max] {
            #expect(throws: V2PushIntentVersionError.invalidVersion) { try V2PushIntentSessionClaim(requestID: request, expectedEpoch: epoch) }
        }
    }
}
