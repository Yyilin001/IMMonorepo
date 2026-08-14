import Foundation
@testable import IMV2Server
import Testing

@Suite("V2 gateway connection admission")
struct V2GatewayConnectionAdmissionTests {
    @Test("the process connection ceiling is exact under concurrent acquisition")
    func enforcesConcurrentCeiling() async {
        let admission = V2GatewayConnectionAdmission(maximumConnections: 17)

        let admitted = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<200 {
                group.addTask { admission.acquire() }
            }
            var admitted = 0
            for await didAcquire in group where didAcquire { admitted += 1 }
            return admitted
        }

        #expect(admitted == 17)
        for _ in 0..<17 { admission.release() }
        #expect(admission.acquire())
        admission.release()
    }
}
