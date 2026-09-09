import CIMV2Argon2
import Foundation
import Testing
@testable import IMV2Server

@Suite("V2 Argon2id password work", .serialized)
struct V2PasswordHashWorkerTests {
    @Test("portable Argon2id matches the upstream v19 vector")
    func officialVector() throws {
        let password = Array("password".utf8), salt = Array("somesalt".utf8)
        var output = [UInt8](repeating: 0, count: 32)
        let status = password.withUnsafeBytes { password in
            salt.withUnsafeBytes { salt in
                argon2id_hash_raw(2, 65_536, 1, password.baseAddress, password.count,
                    salt.baseAddress, salt.count, &output, output.count)
            }
        }
        #expect(status == ARGON2_OK.rawValue)
        #expect(output.map { String(format: "%02x", $0) }.joined() == "09316115d5cf24ed5a15a31a3ba326e5cf32edc24702987c02b6566f61913cf7")
    }

    @Test("PHC parsing bounds resources and rejects ambiguous encodings")
    func boundedParameters() async throws {
        let canonical = V2PasswordHashPolicy.dummyDigest
        #expect(V2PasswordHashPolicy.supports(canonical))
        let invalid = [
            canonical.replacingOccurrences(of: "65536", with: "4294967295"),
            canonical.replacingOccurrences(of: "t=3", with: "t=999999999"),
            canonical.replacingOccurrences(of: "p=1", with: "p=16"),
            canonical.replacingOccurrences(of: "v=19", with: "v=16"),
            canonical.replacingOccurrences(of: "argon2id", with: "argon2i"),
            canonical + "\u{0}ignored", canonical + "=", String(canonical.dropLast()),
            canonical.replacingOccurrences(of: "m=65536,t=3", with: "t=3,m=65536"),
            "$2b$12$legacy", String(repeating: "x", count: 10_000)
        ]
        let primitive = ObservedPasswordPrimitive()
        let worker = V2PasswordHashWorker(maximumConcurrent: 1, primitive: primitive)
        do {
            for digest in invalid {
                #expect(!V2PasswordHashPolicy.supports(digest))
                #expect(try await !worker.verify("valid-input-password", created: digest))
            }
            #expect(primitive.digests == Array(repeating: canonical, count: invalid.count))
            try await worker.shutdown()
        } catch { try? await worker.shutdown(); throw error }
    }

    @Test("UTF-8, whitespace and normalization remain distinct password inputs")
    func exactInput() async throws {
        let worker = V2PasswordHashWorker()
        do {
            for (password, different) in [
                (String(repeating: "a", count: 70) + "界", String(repeating: "a", count: 70) + "甲"),
                ("  twelve-bytes  ", "twelve-bytes  "),
                ("prefix-prefix-é", "prefix-prefix-e\u{301}")
            ] {
                let digest = try await worker.hash(password)
                #expect(try await worker.verify(password, created: digest))
                #expect(try await !worker.verify(different, created: digest))
                #expect(try await worker.hash(password) != digest)
            }
            for invalid in ["", String(repeating: "x", count: 11), String(repeating: "x", count: 1025), "valid-password\u{0}suffix"] {
                await #expect(throws: V2PasswordHashError.invalidInput) { _ = try await worker.hash(invalid) }
                await #expect(throws: V2PasswordHashError.invalidInput) { _ = try await worker.verify(invalid, created: V2PasswordHashPolicy.dummyDigest) }
            }
            try await worker.shutdown()
        } catch { try? await worker.shutdown(); throw error }
    }

    @Test("real KDF burst sheds excess work and remains usable afterward")
    func realHashBurst() async throws {
        let worker = V2PasswordHashWorker()
        do {
            let began = ContinuousClock.now
            let counts = try await withThrowingTaskGroup(of: Bool.self) { group in
                for index in 0..<32 {
                    group.addTask {
                        do {
                            let hash = try await worker.hash("burst-password-\(index)")
                            #expect(V2PasswordHashPolicy.supports(hash))
                            return true
                        } catch V2PasswordHashError.busy { return false }
                    }
                }
                var admitted = 0, rejected = 0
                for try await result in group { if result { admitted += 1 } else { rejected += 1 } }
                return (admitted, rejected)
            }
            #expect(counts.0 > 0 && counts.1 > 0 && counts.0 + counts.1 == 32)
            let recovered = try await worker.hash("after-burst-password")
            #expect(try await worker.verify("after-burst-password", created: recovered))
            print("Argon2id local burst: 32 requests, \(counts.0) derived, \(counts.1) busy, elapsed \(began.duration(to: .now)); two execution slots, 64 MiB each")
            try await worker.shutdown()
        } catch { try? await worker.shutdown(); throw error }
    }

    @Test("cancelled running hashes retain their slots and shutdown drains the pool")
    func cancellationBudgetAndShutdown() async throws {
        let gate = GatedPasswordPrimitive()
        let worker = V2PasswordHashWorker(maximumConcurrent: 2, primitive: gate)
        let first = Task { try await worker.hash("first-password") }
        let second = Task { try await worker.hash("second-password") }
        do {
            for _ in 0..<1000 {
                if gate.entered == 2 { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            #expect(gate.entered == 2)
            await #expect(throws: V2PasswordHashError.busy) { _ = try await worker.hash("excess-password") }
            first.cancel()
            await #expect(throws: V2PasswordHashError.busy) { _ = try await worker.verify("dummy-password", created: V2PasswordHashPolicy.dummyDigest) }
            let closing = Task { try await worker.shutdown() }
            // Give the shutdown message time to enter the actor, without
            // releasing either blocked C-call substitute.
            for _ in 0..<1000 {
                do { _ = try await worker.hash("probe-password") }
                catch V2PasswordHashError.stopped { break }
                catch V2PasswordHashError.busy { try await Task.sleep(for: .milliseconds(1)) }
            }
            await #expect(throws: V2PasswordHashError.stopped) { _ = try await worker.hash("closed-password") }
            #expect(gate.entered == 2)
            gate.release()
            await #expect(throws: CancellationError.self) { _ = try await first.value }
            #expect(try await second.value == V2PasswordHashPolicy.dummyDigest)
            try await closing.value
            try await worker.shutdown()
        } catch {
            gate.release(); _ = try? await first.value; _ = try? await second.value
            try? await worker.shutdown(); throw error
        }
    }
}

// Synchronization is the test's synchronous worker-thread boundary. All
// mutable fields are protected; only snapshots leave the lock.
private final class ObservedPasswordPrimitive: V2PasswordHashPrimitive, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    var digests: [String] { lock.withLock { values } }
    func hash(_ password: String) throws -> String { V2PasswordHashPolicy.dummyDigest }
    func verify(_ password: String, created digest: String) throws -> Bool {
        lock.withLock { values.append(digest) }
        return true
    }
}
private final class GatedPasswordPrimitive: V2PasswordHashPrimitive, @unchecked Sendable {
    private let condition = NSCondition()
    private var calls = 0
    private var released = false
    var entered: Int { condition.lock(); defer { condition.unlock() }; return calls }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
    func hash(_ password: String) throws -> String {
        condition.lock(); calls += 1
        while !released { condition.wait() }
        condition.unlock()
        return V2PasswordHashPolicy.dummyDigest
    }
    func verify(_ password: String, created digest: String) throws -> Bool { _ = try hash(password); return false }
}
