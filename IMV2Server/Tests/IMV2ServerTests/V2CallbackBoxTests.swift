import Testing
import Synchronization
@testable import IMV2ServerContracts

@Suite struct V2CallbackBoxTests {
    @Test func repeatedReadsKeepConstantCallDepth() {
        let depth = Mutex<UInt>(0)
        let callback = Mutex<V2CallbackBox<@Sendable () -> Void>?>(.init {
            var probe: UInt8 = 0
            withUnsafePointer(to: &probe) { pointer in
                depth.withLock { $0 = UInt(bitPattern: pointer) }
            }
        })
        callback.withLock { $0?.callback }?()
        let baseline = depth.withLock { $0 }
        for _ in 0..<20_000 { callback.withLock { $0?.callback }?() }
        let final = depth.withLock { $0 }
        let drift = max(baseline, final) - min(baseline, final)
        #expect(drift < 4096)
    }
}
