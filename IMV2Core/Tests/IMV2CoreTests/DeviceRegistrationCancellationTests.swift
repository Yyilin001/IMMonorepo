import Foundation
import Testing
@testable import IMV2Core

struct DeviceRegistrationCancellationTests {
    @Test("registration cancellation proof has a distinct purpose and redacted diagnostics")
    func proofBoundary() throws {
        let proof = V2DeviceRegistrationCancellationProof.generate()
        #expect(try JSONDecoder().decode(V2DeviceRegistrationCancellationProof.self, from: JSONEncoder().encode(proof)) == proof)
        #expect(throws: (any Error).self) { try V2DeviceRevocationCredential(rawValue: proof.rawValue) }
        #expect(throws: (any Error).self) { try V2DeviceRegistrationCancellationProof(rawValue: V2DeviceRevocationCredential.generate().rawValue) }
        for invalid in ["", proof.rawValue + "=", proof.rawValue + "\n", String(proof.rawValue.dropLast()), proof.rawValue.replacingOccurrences(of: "v1.", with: "v2.")] {
            #expect(throws: (any Error).self) { try V2DeviceRegistrationCancellationProof(rawValue: invalid) }
        }
        #expect(!String(describing: proof).contains(proof.rawValue))
        #expect(!String(reflecting: proof).contains(proof.rawValue))
        #expect(Mirror(reflecting: proof).children.isEmpty)
    }

    @Test("cancellation identity normalizes UUIDs and rejects malformed persisted deadlines")
    func requestBoundary() throws {
        let id = UUID(), operation = UUID(), proof = V2DeviceRegistrationCancellationProof.generate()
        let request = try V2DeviceRegistrationCancellation(deviceID: DeviceID(id.uuidString.lowercased()),
            operationID: operation, proof: proof, issueBeforeMilliseconds: 1_800_000_000_000)
        #expect(request.deviceID.rawValue == id.uuidString)
        #expect(try JSONDecoder().decode(V2DeviceRegistrationCancellation.self, from: JSONEncoder().encode(request)) == request)
        for deadline in [Int64.min, -1, 0, 253_402_300_799_001, Int64.max] {
            let data = try JSONSerialization.data(withJSONObject: ["deviceID": id.uuidString, "operationID": operation.uuidString,
                "proof": proof.rawValue, "issueBeforeMilliseconds": deadline])
            #expect(throws: (any Error).self) { try JSONDecoder().decode(V2DeviceRegistrationCancellation.self, from: data) }
        }
    }
}
