import IMV2ServerContracts
import Crypto
import Foundation
import IMV2Core
import Synchronization

/// 为一次消息接受生成消息和事件两个标识，支持生产生成器与测试注入。
public struct V2AcceptanceIDFactory: Sendable {
    /// 实际标识生成闭包，生产路径使用接受时间，测试路径可忽略时间。
    private let makeIdentifiers: @Sendable (Date) throws -> V2AcceptanceIdentifiers

    /// 使用进程共享生成器生成带时间前缀的接受标识。
    ///
    /// 生成器用进程密钥和计数器进行 HMAC 扩展，给两个标识分配不同字节段；毫秒前缀在进程内防回退。
    /// 接受时间仍以请求中的日期为准，有序标识的前缀在时钟回拨后可能保持在较早观察到的最大时间。
    public init() {
        let generator = V2SecureProcessUUIDGenerator.shared
        makeIdentifiers = { acceptedAt in
            let identifiers = try generator.makeOrderedPair(at: acceptedAt)
            return V2AcceptanceIdentifiers(
                messageID: MessageID(uuid: identifiers.0),
                eventID: EventID(uuid: identifiers.1)
            )
        }
    }

    /// 使用可注入的 UUID 来源，便于确定性领域测试。
    ///
    /// - Parameter makeUUID: 每次调用依次生成消息和事件标识；调用方负责唯一性。此路径不使用接受时间生成有序前缀。
    public init(makeUUID: @escaping @Sendable () -> UUID) {
        makeIdentifiers = { _ in
            try V2AcceptanceIdentifiers(
                messageID: MessageID(makeUUID().uuidString),
                eventID: EventID(makeUUID().uuidString)
            )
        }
    }

    /// 生成同一次接受操作使用的两个标识。
    ///
    /// - Parameter acceptedAt: 接受时间，生产路径用于生成毫秒前缀。
    /// - Returns: 消息和事件标识；事务重试应复用返回值。
    /// - Throws: 生产路径遇到不可表示时间时抛出 `V2AcceptanceIdentifierError.invalidTimestamp`，或传播注入生成路径的错误。
    public func make(at acceptedAt: Date) throws -> V2AcceptanceIdentifiers {
        try makeIdentifiers(acceptedAt)
    }
}

/// 为消息接受生成进程内伪随机标识，并为连接与跟踪生成轻量标识。
///
/// 接受标识使用 256 位进程密钥与递增计数器的 HMAC 扩展；三个互不重叠的十字节片段分别提供有序 UUID 的随机部分。
/// 每次进程重启重新生成密钥。`@unchecked Sendable` 依赖密钥模板只读、所有可变计数器使用原子操作。
/// 轻量标识不能当作授权凭据，采用独立计数器与进程随机前缀。
package final class V2SecureProcessUUIDGenerator: @unchecked Sendable {
    /// 进程共享生成器，使同一进程的接受请求复用密钥与计数空间。
    package static let shared = V2SecureProcessUUIDGenerator()

    /// 只读 HMAC 初始模板，每次生成时复制后写入独立计数值，避免重复构造密钥散列状态。
    private let authenticationTemplate: HMAC<SHA256>
    /// 接受标识的原子计数器；回绕至零时触发前置条件失败。
    private let authenticationCounter = Atomic<UInt64>(0)
    /// 连接与跟踪标识使用的七字节进程随机前缀，不用于授权。
    private let localIdentifierPrefix: (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    )
    /// 轻量标识的独立原子计数器。
    private let localIdentifierCounter = Atomic<UInt64>(0)
    /// 已发布的最大毫秒前缀，用于钳制进程内的时钟回拨。
    private let lastOrderedUnixMilliseconds = Atomic<UInt64>(0)

    /// 生成进程密钥并初始化只读 HMAC 模板与轻量标识前缀。
    init() {
        let key = SymmetricKey(size: .bits256)
        authenticationTemplate = HMAC(key: key)
        localIdentifierPrefix = key.withUnsafeBytes { bytes in
            (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6])
        }
    }

    /// 生成连接或跟踪使用的轻量 UUID 形式标识。
    ///
    /// - Returns: 由进程随机前缀与递增计数器组成的标识；不能将其作为不可预测的访问凭据。
    ///
    /// 计数器空间耗尽会触发前置条件失败，进程间唯一性依赖随机前缀。
    package func makeOne() -> UUID {
        let increment = localIdentifierCounter.wrappingAdd(1, ordering: .relaxed)
        precondition(increment.newValue != 0, "process-local identifier space exhausted")
        let value = increment.newValue
        return UUID(uuid: (
            localIdentifierPrefix.0,
            localIdentifierPrefix.1,
            localIdentifierPrefix.2,
            localIdentifierPrefix.3,
            localIdentifierPrefix.4,
            localIdentifierPrefix.5,
            0x40 | UInt8(truncatingIfNeeded: value >> 60),
            UInt8(truncatingIfNeeded: value >> 52),
            0x80 | UInt8(truncatingIfNeeded: value >> 46) & 0x3f,
            UInt8(truncatingIfNeeded: value >> 38),
            UInt8(truncatingIfNeeded: value >> 30),
            UInt8(truncatingIfNeeded: value >> 22),
            UInt8(truncatingIfNeeded: value >> 14),
            UInt8(truncatingIfNeeded: value >> 6),
            UInt8(truncatingIfNeeded: value) & 0x3f,
            localIdentifierPrefix.6
        ))
    }

    /// 生成共享毫秒前缀、使用不同伪随机字节段的两个有序标识。
    ///
    /// - Parameter date: 本次接受时间。
    /// - Returns: 依次用于消息和事件的标识。
    /// - Throws: 时间不在可表示范围内时抛出无效时间错误。
    func makeOrderedPair(at date: Date) throws -> (UUID, UUID) {
        let unixMilliseconds = try orderedUnixMilliseconds(for: date)
        let authenticationCode = nextAuthenticationCode()
        return authenticationCode.withUnsafeBytes { bytes in
            (
                v2UUIDv7(bytes, offset: 0, unixMilliseconds: unixMilliseconds),
                v2UUIDv7(bytes, offset: 10, unixMilliseconds: unixMilliseconds)
            )
        }
    }

    /// 把日期向下取整为 Unix 毫秒，并在进程内保持前缀不回退。
    ///
    /// - Parameter date: 待转换日期。
    /// - Returns: 当前候选时间与进程已观察最大时间中的较大值。
    /// - Throws: 负数、非有限值或超出 48 位毫秒范围时抛出无效时间错误。
    ///
    /// 此操作只维护前缀顺序，标识唯一性仍来自计数器驱动的 HMAC。并发调用的返回先后不保证等同于前缀递增顺序。
    private func orderedUnixMilliseconds(for date: Date) throws -> UInt64 {
        let milliseconds = date.timeIntervalSince1970 * 1_000
        guard milliseconds >= 0,
              let candidate = UInt64(exactly: milliseconds.rounded(.down)),
              candidate <= 0x0000_ffff_ffff_ffff else {
            throw V2AcceptanceIdentifierError.invalidTimestamp
        }
        var observed = lastOrderedUnixMilliseconds.load(ordering: .relaxed)
        while observed < candidate {
            let exchanged = lastOrderedUnixMilliseconds.compareExchange(
                expected: observed,
                desired: candidate,
                ordering: .relaxed
            )
            if exchanged.exchanged { return candidate }
            observed = exchanged.original
        }
        return observed
    }

    /// 把递增计数器按大端序输入复制的 HMAC 模板，生成下一段伪随机字节；计数器回绕时触发前置条件失败。
    private func nextAuthenticationCode() -> HMAC<SHA256>.MAC {
        let increment = authenticationCounter.wrappingAdd(1, ordering: .relaxed)
        precondition(increment.newValue != 0, "acceptance identifier space exhausted")
        var input = increment.newValue.bigEndian
        return withUnsafeBytes(of: &input) { bytes in
            var authenticator = authenticationTemplate
            authenticator.update(data: Data(bytes))
            return authenticator.finalize()
        }
    }
}

/// 用 48 位 Unix 毫秒前缀和十字节随机片段构造有序 UUID。
///
/// - Parameters:
///   - bytes: 从零起始、采用整数索引的随机字节集合。
///   - offset: 十字节片段的起始位置。
///   - unixMilliseconds: 可由 48 位表示的毫秒前缀。
/// - Returns: 设置了版本与变体位的 UUID。
///
/// 调用方必须保证片段存在且时间不越界，否则触发前置条件失败。
private func v2UUIDv7<Bytes: RandomAccessCollection>(
    _ bytes: Bytes,
    offset: Int,
    unixMilliseconds: UInt64
) -> UUID where Bytes.Element == UInt8, Bytes.Index == Int {
    precondition(offset >= 0 && bytes.count >= offset + 10)
    precondition(unixMilliseconds <= 0x0000_ffff_ffff_ffff)
    let versionAndRandom = (bytes[offset] & 0x0f) | 0x70
    let variantAndRandom = (bytes[offset + 2] & 0x3f) | 0x80
    return UUID(uuid: (
        UInt8(truncatingIfNeeded: unixMilliseconds >> 40),
        UInt8(truncatingIfNeeded: unixMilliseconds >> 32),
        UInt8(truncatingIfNeeded: unixMilliseconds >> 24),
        UInt8(truncatingIfNeeded: unixMilliseconds >> 16),
        UInt8(truncatingIfNeeded: unixMilliseconds >> 8),
        UInt8(truncatingIfNeeded: unixMilliseconds),
        versionAndRandom, bytes[offset + 1],
        variantAndRandom, bytes[offset + 3], bytes[offset + 4], bytes[offset + 5],
        bytes[offset + 6], bytes[offset + 7], bytes[offset + 8], bytes[offset + 9]
    ))
}
