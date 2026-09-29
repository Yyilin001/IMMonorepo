import IMV2ServerApplication
import IMV2ServerContracts
import CIMV2Argon2
import Crypto
import Foundation
import NIOPosix


/// 同步密码哈希原语，供工作器在专属线程池上调用。
protocol V2PasswordHashPrimitive: Sendable {
    /// 同步计算密码哈希。
    ///
    /// - Parameter password: 明文密码。
    /// - Returns: 哈希串。
    /// - Throws: 计算失败或输出不符合策略时抛出。
    func hash(_ password: String) throws -> String

    /// 同步校验密码。
    ///
    /// - Parameters:
    ///   - password: 明文密码。
    ///   - digest: 已持久化的哈希串。
    /// - Returns: 匹配时为 `true`。
    /// - Throws: 校验过程出错时抛出。
    func verify(_ password: String, created digest: String) throws -> Bool
}

/// 基于 libargon2 的 Argon2id 原语实现。
struct V2Argon2id: V2PasswordHashPrimitive {
    /// 生成随机盐并计算 Argon2id 编码串。
    ///
    /// - Parameter password: 明文密码。
    /// - Returns: 编码后的 Argon2id 哈希串。
    /// - Throws: 底层返回非成功码，或输出串不符合部署策略时抛出
    ///   ``V2PasswordHashError/derivationFailed``。
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

    /// 校验密码与既有哈希是否匹配。
    ///
    /// - Parameters:
    ///   - password: 明文密码。
    ///   - digest: 已持久化的哈希串，需符合部署策略。
    /// - Returns: 校验通过时为 `true`；明确不匹配时为 `false`。
    /// - Throws: 哈希串不符合策略，或底层返回既非成功也非不匹配时抛出
    ///   ``V2PasswordHashError/derivationFailed``。
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

/// 由应用独占的密码哈希工作器。
///
/// 线程池上限为两个并发推导，即最多两份 64 MiB 内存开销。这里不设等待队列：
/// 超出额度时立即返回可重试的忙碌错误。取消不会立刻释放额度，
/// 而是等底层 C 调用真正返回；整个过程中不持有任何数据库连接。
public actor V2PasswordHashWorker: V2PasswordHashing {
    private let pool: NIOThreadPool
    private let primitive: any V2PasswordHashPrimitive
    private let maximumConcurrent: Int
    private var active = 0
    private var shutdownTask: Task<Void, Error>?

    /// 以生产参数构造工作器：两个线程与两个并发额度。
    public init() {
        maximumConcurrent = 2
        primitive = V2Argon2id()
        pool = NIOThreadPool(numberOfThreads: 2)
        pool.start()
    }

    /// 以可注入的并发额度与原语构造工作器，供测试使用。
    ///
    /// - Parameters:
    ///   - maximumConcurrent: 并发额度，需落在 `1...2`。
    ///   - primitive: 实际执行计算的哈希原语。
    ///
    /// 额度越界时直接失败，避免运行期超出内存预算。
    init(maximumConcurrent: Int, primitive: any V2PasswordHashPrimitive) {
        precondition((1...2).contains(maximumConcurrent))
        self.maximumConcurrent = maximumConcurrent
        self.primitive = primitive
        pool = NIOThreadPool(numberOfThreads: maximumConcurrent)
        pool.start()
    }

    /// 计算密码哈希。
    ///
    /// - Parameter password: 明文密码。
    /// - Returns: 符合部署策略的哈希串。
    /// - Throws: 密码不符合长度或字符约束时抛出
    ///   ``V2PasswordHashError/invalidInput``；额度已满或已关闭时分别抛出
    ///   ``V2PasswordHashError/busy`` 与 ``V2PasswordHashError/stopped``。
    public func hash(_ password: String) async throws -> String {
        guard V2PasswordHashPolicy.accepts(password) else { throw V2PasswordHashError.invalidInput }
        let primitive = self.primitive
        return try await run { try primitive.hash(password) }
    }

    /// 校验密码与既有哈希是否匹配。
    ///
    /// 哈希串不符合部署策略时会对固定假串执行等代价校验，避免通过响应时间区分
    /// 「账号不存在」与「密码错误」，但结果始终为不匹配；历史 bcrypt 串无法建立完整输入同一性，
    /// 因此不会据此触发重新哈希或签发断言。
    ///
    /// - Parameters:
    ///   - password: 明文密码。
    ///   - digest: 已持久化的哈希串。
    /// - Returns: 哈希串受支持且校验通过时为 `true`。
    /// - Throws: 密码不符合约束时抛出 ``V2PasswordHashError/invalidInput``；
    ///   额度已满、已关闭或计算失败时抛出对应错误。
    public func verify(_ password: String, created digest: String) async throws -> Bool {
        guard V2PasswordHashPolicy.accepts(password) else { throw V2PasswordHashError.invalidInput }
        let supported = V2PasswordHashPolicy.supports(digest)
        let candidate = supported ? digest : V2PasswordHashPolicy.dummyDigest
        let primitive = self.primitive
        let matches = try await run { try primitive.verify(password, created: candidate) }
        // 旧版 bcrypt 无法确认完整输入的身份。绝不能根据其截断或
        // 与 NUL 等价的校验结果重新计算哈希或签发断言。
        return supported && matches
    }

    /// 在额度约束下把一次同步计算提交到线程池。
    ///
    /// - Parameter work: 在专属线程上执行的同步计算。
    /// - Returns: 计算结果。
    /// - Throws: 任务已取消时抛出 `CancellationError`；已关闭时抛出
    ///   ``V2PasswordHashError/stopped``；额度已满时抛出 ``V2PasswordHashError/busy``。
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

    /// 关闭线程池并等待其收敛。
    ///
    /// 并发调用会加入同一次关闭流程，不会重复触发。
    ///
    /// - Throws: 线程池关闭失败时抛出。
    public func shutdown() async throws {
        if let shutdownTask { return try await shutdownTask.value }
        let pool = self.pool
        // 仅用于让并发关闭调用方等待同一次排空操作。
        let task = Task { try await pool.shutdownGracefully() }
        shutdownTask = task
        try await task.value
    }
}
