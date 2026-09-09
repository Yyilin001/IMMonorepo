import CIMV2Argon2
import Crypto
import Foundation
import NIOPosix

public enum V2PasswordHashError: Error, Equatable, Sendable {
    case invalidInput
    case busy
    case stopped
    case derivationFailed
}

public enum V2PasswordHashPolicy {
    public static let memoryKiB: UInt32 = 65_536
    public static let iterations: UInt32 = 3
    public static let parallelism: UInt32 = 1
    public static let algorithmVersion: UInt32 = 19

    // Fixed public verifier for equal-cost rejection; it never represents an account.
    public static let dummyDigest = "$argon2id$v=19$m=65536,t=3,p=1$aW0tdjItZHVtbXktc2FsdA$9tW2aGVfIp/L14eL1G4XTaY+ksHcPZCQLoqjvLwIkq8"

    public static func accepts(_ password: String) -> Bool {
        (12...1_024).contains(password.utf8.count) && !password.utf8.contains(0)
    }

    /// Parse before allocating KDF memory. Only the deployed policy is accepted;
    /// a database row cannot request arbitrary memory, iterations, or lanes.
    public static func supports(_ digest: String) -> Bool {
        guard digest.utf8.count <= 128 else { return false }
        let fields = digest.split(separator: "$", omittingEmptySubsequences: false)
        guard fields.count == 6, fields[0].isEmpty, fields[1] == "argon2id",
              fields[2] == "v=19", fields[3] == "m=65536,t=3,p=1" else { return false }
        return canonicalBase64(fields[4], bytes: 16) && canonicalBase64(fields[5], bytes: 32)
    }

    private static func canonicalBase64(_ value: Substring, bytes: Int) -> Bool {
        let encoded = String(value)
        let padding = String(repeating: "=", count: (4 - encoded.utf8.count % 4) % 4)
        guard !encoded.contains("="), let data = Data(base64Encoded: encoded + padding), data.count == bytes else { return false }
        return data.base64EncodedString().replacingOccurrences(of: "=", with: "") == encoded
    }
}

public protocol V2PasswordHashing: Sendable {
    func hash(_ password: String) async throws -> String
    func verify(_ password: String, created digest: String) async throws -> Bool
}

protocol V2PasswordHashPrimitive: Sendable {
    func hash(_ password: String) throws -> String
    func verify(_ password: String, created digest: String) throws -> Bool
}

struct V2Argon2id: V2PasswordHashPrimitive {
    func hash(_ password: String) throws -> String {
        let salt = SymmetricKey(size: .bits128).withUnsafeBytes { Array($0) }
        let bytes = Array(password.utf8)
        var encoded = [CChar](repeating: 0, count: 128)
        let result = bytes.withUnsafeBytes { input in
            salt.withUnsafeBytes { salt in
                argon2id_hash_encoded(V2PasswordHashPolicy.iterations, V2PasswordHashPolicy.memoryKiB,
                    V2PasswordHashPolicy.parallelism, input.baseAddress, input.count,
                    salt.baseAddress, salt.count, 32, &encoded, encoded.count)
            }
        }
        guard result == ARGON2_OK.rawValue else { throw V2PasswordHashError.derivationFailed }
        let digest = String(decoding: encoded.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard V2PasswordHashPolicy.supports(digest) else { throw V2PasswordHashError.derivationFailed }
        return digest
    }

    func verify(_ password: String, created digest: String) throws -> Bool {
        guard V2PasswordHashPolicy.supports(digest) else { throw V2PasswordHashError.derivationFailed }
        let bytes = Array(password.utf8)
        let result = bytes.withUnsafeBytes { input in
            digest.withCString { encoded in argon2id_verify(encoded, input.baseAddress, input.count) }
        }
        if result == ARGON2_VERIFY_MISMATCH.rawValue { return false }
        guard result == ARGON2_OK.rawValue else { throw V2PasswordHashError.derivationFailed }
        return true
    }
}

/// One application-owned pool; at most two 64 MiB derivations. There is no
/// waiting queue: excess callers receive retryable busy immediately. Cancellation
/// retains the slot until the C call actually returns. No DB connection is held.
public actor V2PasswordHashWorker: V2PasswordHashing {
    private let pool: NIOThreadPool
    private let primitive: any V2PasswordHashPrimitive
    private let maximumConcurrent: Int
    private var active = 0
    private var shutdownTask: Task<Void, Error>?

    public init() {
        maximumConcurrent = 2
        primitive = V2Argon2id()
        pool = NIOThreadPool(numberOfThreads: 2)
        pool.start()
    }

    init(maximumConcurrent: Int, primitive: any V2PasswordHashPrimitive) {
        precondition((1...2).contains(maximumConcurrent))
        self.maximumConcurrent = maximumConcurrent
        self.primitive = primitive
        pool = NIOThreadPool(numberOfThreads: maximumConcurrent)
        pool.start()
    }

    public func hash(_ password: String) async throws -> String {
        guard V2PasswordHashPolicy.accepts(password) else { throw V2PasswordHashError.invalidInput }
        let primitive = self.primitive
        return try await run { try primitive.hash(password) }
    }

    public func verify(_ password: String, created digest: String) async throws -> Bool {
        guard V2PasswordHashPolicy.accepts(password) else { throw V2PasswordHashError.invalidInput }
        let supported = V2PasswordHashPolicy.supports(digest)
        let candidate = supported ? digest : V2PasswordHashPolicy.dummyDigest
        let primitive = self.primitive
        let matches = try await run { try primitive.verify(password, created: candidate) }
        // Legacy bcrypt cannot establish full-input identity. Never rehash or
        // issue an assertion based on its truncated/NUL-equivalent verifier.
        return supported && matches
    }

    private func run<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        guard shutdownTask == nil else { throw V2PasswordHashError.stopped }
        guard active < maximumConcurrent else { throw V2PasswordHashError.busy }
        active += 1
        defer { active -= 1 }
        let result = try await pool.runIfActive(work)
        try Task.checkCancellation()
        return result
    }

    public func shutdown() async throws {
        if let shutdownTask { return try await shutdownTask.value }
        let pool = self.pool
        // Retained solely to let concurrent shutdown callers join the same drain.
        let task = Task { try await pool.shutdownGracefully() }
        shutdownTask = task
        try await task.value
    }
}
