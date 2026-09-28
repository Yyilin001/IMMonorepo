import Crypto
import Foundation
import IMV2Core

/// 群房间创建成员清单的一页。
public struct V2GroupRoomCreationManifestSlice: Equatable, Sendable {
    /// 本页成员用户标识。
    public let memberUserIDs: [UserID]
    /// 是否还有后续页。
    public let hasMore: Bool

    /// 保存成员清单分片。
    ///
    /// - Parameters:
    ///   - memberUserIDs: 本页成员。
    ///   - hasMore: 是否还有后续页。
    public init(memberUserIDs: [UserID], hasMore: Bool) {
        self.memberUserIDs = memberUserIDs
        self.hasMore = hasMore
    }
}

/// 从控制面创建意图复制到房间归属的不可变键集分页。
///
/// 单页规模刻意保持很小，使包含十万成员的分阶段建群在 SQL 与内存上仍然有界。
public struct V2GroupRoomCreationManifestPage: Equatable, Sendable {
    /// 单页允许的最大成员数。
    public static let maximumMemberCount = 512

    /// 从零开始的页序号。
    public let pageNumber: Int
    /// 本页成员，按用户标识排序存放。
    public let memberUserIDs: [UserID]
    /// 是否为清单最后一页。
    public let isFinal: Bool
    /// 由页序号、成员与终页标记计算的摘要。
    public let digest: Data

    /// 规范化并校验分页后计算摘要。
    ///
    /// 成员会按用户标识排序，因此同一集合的不同输入顺序得到相同摘要；
    /// 成员为空、超过 ``maximumMemberCount``、存在重复，或页序号为负或超出 `Int32` 时拒绝构造。
    ///
    /// - Parameters:
    ///   - pageNumber: 从零开始的页序号。
    ///   - memberUserIDs: 本页成员，允许乱序输入。
    ///   - isFinal: 是否为最后一页。
    /// - Throws: 任一约束不满足时抛出
    ///   ``V2GroupRoomCreationIntentStoreError/invalidIntent``。
    public init(
        pageNumber: Int,
        memberUserIDs: [UserID],
        isFinal: Bool
    ) throws {
        let canonical = memberUserIDs.sorted()
        guard pageNumber >= 0, Int32(exactly: pageNumber) != nil,
              (1 ... Self.maximumMemberCount).contains(canonical.count),
              Set(canonical).count == canonical.count
        else { throw V2GroupRoomCreationIntentStoreError.invalidIntent }
        self.pageNumber = pageNumber
        self.memberUserIDs = canonical
        self.isFinal = isFinal
        digest = Self.digest(
            pageNumber: pageNumber,
            memberUserIDs: canonical,
            isFinal: isFinal
        )
    }

    /// 计算分页摘要，绑定版本前缀、页序号、终页标记与全部成员标识。
    ///
    /// - Parameters:
    ///   - pageNumber: 页序号。
    ///   - memberUserIDs: 已排序的成员标识。
    ///   - isFinal: 是否为最后一页。
    /// - Returns: SHA-256 摘要。
    private static func digest(
        pageNumber: Int,
        memberUserIDs: [UserID],
        isFinal: Bool
    ) -> Data {
        var bytes = Data("im-v2-group-manifest-page-v1\0".utf8)
        var page = UInt64(pageNumber).bigEndian
        withUnsafeBytes(of: &page) { bytes.append(contentsOf: $0) }
        bytes.append(isFinal ? 1 : 0)
        for userID in memberUserIDs {
            bytes.append(contentsOf: userID.rawValue.utf8)
            bytes.append(0)
        }
        return Data(SHA256.hash(data: bytes))
    }
}
