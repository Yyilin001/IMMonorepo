import Foundation
import Crypto

/// 当前可见投影的稳定排序键，用于快照的键集分页及跨页重复检查。
///
/// 按投影类型、实体键依次比较 Swift 字符串；数据库分页顺序必须与协议顺序一致。
/// 合成 `Codable` 解码不执行初始化校验；页面编解码器会从线格式字段重新构造键。
public struct V2SnapshotProjectionKey: Equatable, Hashable, Comparable, Sendable, Codable {
    /// 投影类型字符串，初始化要求非空且不超过 64 个 UTF-8 字节。
    public let projectionKind: String
    /// 类型内实体键，初始化要求非空且不超过 512 个 UTF-8 字节。
    public let entityKey: String

    /// 检查字节长度后保存排序键，不裁剪、规范化或过滤控制字符。
    ///
    /// - Parameters:
    ///   - projectionKind: 投影类型，非空且最多 64 个 UTF-8 字节。
    ///   - entityKey: 实体键，非空且最多 512 个 UTF-8 字节。
    /// - Throws: 长度不合法时抛出 ``V2SnapshotProjectionV3Error/invalidKey``。
    public init(projectionKind: String, entityKey: String) throws {
        guard !projectionKind.isEmpty, projectionKind.utf8.count <= 64,
              !entityKey.isEmpty, entityKey.utf8.count <= 512
        else { throw V2SnapshotProjectionV3Error.invalidKey }
        self.projectionKind = projectionKind
        self.entityKey = entityKey
    }

    /// 先比较投影类型，再比较实体键；相同键不小于自身。
    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.projectionKind, lhs.entityKey) < (rhs.projectionKind, rhs.entityKey)
    }

    /// 独立编码排序键时使用的蛇形字段名。
    private enum CodingKeys: String, CodingKey {
        /// 投影类型的线格式字段名。
        case projectionKind = "projection_kind"
        /// 实体键的线格式字段名。
        case entityKey = "entity_key"
    }
}

/// 快照中的一条当前状态投影，保留与增量同步一致的 JSON 载荷词汇。
///
/// 这里只检查序列号及载荷字节边界；不解析 JSON，不核对载荷内容与键、源事件的一致性。
public struct V2SnapshotProjectionItem: Equatable, Sendable {
    /// 投影稳定排序键。
    public let key: V2SnapshotProjectionKey
    /// 产生该当前状态的源事件标识。
    public let sourceEventID: EventID
    /// 源投影序列号，范围为 1 至 Int64.max。
    public let sequence: UInt64
    /// 不透明的投影 JSON 字节，页面编码时会转为 Base64。
    public let payload: Data

    /// 创建一条有界投影。
    ///
    /// - Parameters:
    ///   - key: 已构造的投影键；此处不重复校验其字段。
    ///   - sourceEventID: 源事件标识。
    ///   - sequence: 正的有符号 64 位范围内序列号。
    ///   - payload: 非空且不超过 44 KiB 的载荷。
    /// - Throws: 序列号或载荷大小不合法时抛出 ``V2SnapshotProjectionV3Error/invalidItem``。
    public init(key: V2SnapshotProjectionKey, sourceEventID: EventID, sequence: UInt64, payload: Data) throws {
        guard sequence > 0, sequence <= UInt64(Int64.max), !payload.isEmpty,
              payload.count <= V2SnapshotProjectionV3Codec.maximumItemBytes
        else { throw V2SnapshotProjectionV3Error.invalidItem }
        self.key = key
        self.sourceEventID = sourceEventID
        self.sequence = sequence
        self.payload = payload
    }
}

/// 非空且按键严格递增的快照页面。
///
/// 初始化只保证页内有序与唯一；跨页连续性、全局唯一性和总量限制需由构建器及导入器维护。
public struct V2SnapshotProjectionV3Page: Equatable, Sendable {
    /// 已按键严格递增排列的投影条目。
    public let items: [V2SnapshotProjectionItem]

    /// 校验页面条目数与严格排序，不自动排序或去重。
    ///
    /// - Parameter items: 1 至 500 条投影，任意相邻键必须严格递增。
    /// - Throws: 空页、超量、乱序或重复键抛出 ``V2SnapshotProjectionV3Error/invalidPage``。
    /// - Note: 页面编码后的字节预算由编码器另行检查。
    public init(items: [V2SnapshotProjectionItem]) throws {
        guard !items.isEmpty, items.count <= V2SnapshotProjectionV3Codec.maximumPageItems else {
            throw V2SnapshotProjectionV3Error.invalidPage
        }
        for pair in zip(items, items.dropFirst()) where pair.0.key >= pair.1.key {
            throw V2SnapshotProjectionV3Error.invalidPage
        }
        self.items = items
    }

    /// 页首排序键；初始化器保证页面非空。
    public var firstKey: V2SnapshotProjectionKey { items[0].key }
    /// 页尾排序键，可供下一页的键集分页使用。
    public var lastKey: V2SnapshotProjectionKey { items[items.count - 1].key }
}

/// 快照 V3 的有界 JSON 页面编解码器。
///
/// 使用蛇形字段名、Base64 载荷、排序 JSON 键和不转义斜杠的输出格式。
/// 整份快照的页数、条目数及总字节限制在此声明，由上层累计执行。
public enum V2SnapshotProjectionV3Codec {
    /// 页面线格式版本号 31，与产品名 V3 分开维护。
    public static let schemaVersion: UInt32 = 31
    /// 单页最多 500 项。
    public static let maximumPageItems = 500
    // Item bytes are JSON-embedded as base64 inside a page. Keeping the raw
    // payload below 44 KiB guarantees one valid item can always fit in the
    // 60 KiB page/frame budget with its ordering and identity metadata.
    /// 单条原始载荷最多 44 KiB，为 Base64 和元数据保留页面空间。
    public static let maximumItemBytes = 44 * 1_024
    // Leaves headroom for the protobuf envelope inside the protocol's current
    // 64 KiB frame limit.
    /// 单页编码后最多 60 KiB，为协议帧的外层封装保留空间。
    public static let maximumPageBytes = 60 * 1_024
    /// 整份快照最多 4096 页；单页编解码不会累计检查。
    public static let maximumPageCount = 4_096
    /// 整份快照最多一百万项；由构建器和导入器累计检查。
    public static let maximumTotalItems: UInt64 = 1_000_000
    /// 整份快照最多 256 MiB；由构建器和导入器累计检查。
    public static let maximumTotalBytes: UInt64 = 256 * 1_024 * 1_024

    /// 编码页面并检查最终 JSON 字节预算。
    ///
    /// - Parameter page: 已构造的有序页面。
    /// - Returns: 使用固定编码选项的 JSON 字节。
    /// - Throws: JSON 编码错误原样传播；超过 60 KiB 抛出 ``V2SnapshotProjectionV3Error/pageTooLarge``。
    /// - Note: 不重新构造各条目或排序键；页面内的原始载荷不作为 JSON 解析。
    public static func encode(_ page: V2SnapshotProjectionV3Page) throws -> Data {
        let wire = Page(
            schemaVersion: schemaVersion,
            items: page.items.map(Item.init)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(wire)
        guard data.count <= maximumPageBytes else { throw V2SnapshotProjectionV3Error.pageTooLarge }
        return data
    }

    /// 从线格式解码，并通过领域初始化器重新校验键、条目与页面。
    ///
    /// - Parameter payload: 非空且不超过 60 KiB 的页面 JSON。
    /// - Returns: 已通过页内校验的快照页面。
    /// - Throws: 空输入或超预算抛出 `pageTooLarge`；JSON 结构错误抛出 `invalidPage`；版本不符抛出 `unsupportedSchemaVersion`。领域校验错误保持原值，其他条目转换错误归为 `invalidPage`。
    /// - Note: 不验证跨页顺序、摘要链及载荷内部的业务字段。
    public static func decode(_ payload: Data) throws -> V2SnapshotProjectionV3Page {
        guard !payload.isEmpty, payload.count <= maximumPageBytes else {
            throw V2SnapshotProjectionV3Error.pageTooLarge
        }
        let wire: Page
        do { wire = try JSONDecoder().decode(Page.self, from: payload) }
        catch { throw V2SnapshotProjectionV3Error.invalidPage }
        guard wire.schemaVersion == schemaVersion else {
            throw V2SnapshotProjectionV3Error.unsupportedSchemaVersion
        }
        do { return try .init(items: wire.items.map { try $0.value() }) }
        catch let error as V2SnapshotProjectionV3Error { throw error }
        catch { throw V2SnapshotProjectionV3Error.invalidPage }
    }

    /// 页面内部 JSON 结构，仅供编解码使用。
    private struct Page: Codable {
        let schemaVersion: UInt32
        let items: [Item]
        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case items
        }
    }

    /// 投影条目的内部 JSON 结构；解码后须调用转换方法执行领域校验。
    private struct Item: Codable {
        let projectionKind: String
        let entityKey: String
        let sourceEventID: String
        let sequence: UInt64
        let payload: Data

        init(_ value: V2SnapshotProjectionItem) {
            projectionKind = value.key.projectionKind
            entityKey = value.key.entityKey
            sourceEventID = value.sourceEventID.rawValue
            sequence = value.sequence
            payload = value.payload
        }

        func value() throws -> V2SnapshotProjectionItem {
            try .init(
                key: .init(projectionKind: projectionKind, entityKey: entityKey),
                sourceEventID: .init(sourceEventID),
                sequence: sequence,
                payload: payload
            )
        }

        enum CodingKeys: String, CodingKey {
            case projectionKind = "projection_kind"
            case entityKey = "entity_key"
            case sourceEventID = "source_event_id"
            case sequence
            case payload
        }
    }
}

/// 快照键、条目、页面和版本的校验错误。
public enum V2SnapshotProjectionV3Error: Error, Equatable, Sendable {
    /// 键为空或超出字节限制。
    case invalidKey
    /// 条目序列号或载荷长度非法。
    case invalidItem
    /// 页面结构、条目数量、排序或条目转换非法。
    case invalidPage
    /// 编码页面超过字节预算，或待解码输入为空、超过预算。
    case pageTooLarge
    /// 页面声明的线格式版本不受支持。
    case unsupportedSchemaVersion
}

/// 快照构建器、传输层与本地导入器共享的 SHA-256 摘要链规则。
///
/// 摘要以小写十六进制输出；链用于核对内容与顺序，本身不是签名或身份认证。
/// 辅助方法直接散列输入，不校验索引、摘要格式或键的业务合法性。
public enum V2SnapshotV3Digest {
    /// 计算绑定基线序列、能力配置和当前线格式版本的初始摘要。
    ///
    /// - Parameters:
    ///   - baseSequence: 快照基线序列号，以十进制文本参与摘要。
    ///   - capabilityProfile: 能力配置字符串，原样参与摘要。
    /// - Returns: 对协议域标识、版本、基线与配置以 NUL 分隔后的 UTF-8 字节计算的摘要。
    public static func initial(baseSequence: UInt64, capabilityProfile: String) -> String {
        sha256(Data("IM-SNAPSHOT-V3\u{0}\(V2SnapshotProjectionV3Codec.schemaVersion)\u{0}\(baseSequence)\u{0}\(capabilityProfile)".utf8))
    }

    /// 把一页的摘要与边界追加到摘要链。
    ///
    /// - Parameters:
    ///   - previous: 上一链节点的摘要文本。
    ///   - pageIndex: 本页索引；连续性由调用者检查。
    ///   - pageDigest: 本页原始编码字节的摘要。
    ///   - firstKey: 页首投影键。
    ///   - lastKey: 页尾投影键。
    ///   - itemCount: 页内条目数量；此处不与页面核对。
    /// - Returns: 按参数定义顺序以 NUL 分隔后计算的 SHA-256 摘要。
    /// - Note: 字符串直接拼接而非长度前缀编码；该方法不检查输入内是否含 NUL，调用方须维持协议输入约束。
    public static func next(
        previous: String,
        pageIndex: UInt32,
        pageDigest: String,
        firstKey: V2SnapshotProjectionKey,
        lastKey: V2SnapshotProjectionKey,
        itemCount: UInt32
    ) -> String {
        sha256(Data([
            previous, String(pageIndex), pageDigest,
            firstKey.projectionKind, firstKey.entityKey,
            lastKey.projectionKind, lastKey.entityKey,
            String(itemCount),
        ].joined(separator: "\u{0}").utf8))
    }

    /// 计算页面原始字节的摘要，不解码或重新规范化 JSON。
    ///
    /// - Parameter payload: 实际传输或保存的页面字节。
    /// - Returns: 小写十六进制 SHA-256 摘要。
    public static func page(_ payload: Data) -> String { sha256(payload) }

    /// 统一将 SHA-256 的每个字节格式化为两位小写十六进制。
    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
