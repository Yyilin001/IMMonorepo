import Crypto
import Foundation
import IMV2Core

public struct V2GroupRoomCreationManifestSlice: Equatable, Sendable {
    public let memberUserIDs: [UserID]
    public let hasMore: Bool

    public init(memberUserIDs: [UserID], hasMore: Bool) {
        self.memberUserIDs = memberUserIDs
        self.hasMore = hasMore
    }
}

/// One immutable keyset page copied from the control intent to a room owner.
/// Pages are deliberately small enough for bounded SQL/heap use even when a
/// staged group contains 100,000 members.
public struct V2GroupRoomCreationManifestPage: Equatable, Sendable {
    public static let maximumMemberCount = 512

    public let pageNumber: Int
    public let memberUserIDs: [UserID]
    public let isFinal: Bool
    public let digest: Data

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

/// Owner capability for bounded, digest-fenced transfer of a control-validated
/// audience. `stage` and `create` are independently idempotent so a process
/// crash can resume at any page or after the owner transaction commits.
public protocol V2ControlValidatedStagedGroupMessagingStore:
    V2ControlValidatedGroupMessagingStore
{
    func stageControlValidatedAudience(
        intent: V2GroupRoomCreationIntent,
        page: V2GroupRoomCreationManifestPage,
        now: Date
    ) async throws

    func createControlValidatedStaged(
        command: V2StagedGroupRoomCommand,
        intent: V2GroupRoomCreationIntent,
        capacityProfile: V2CapacityProfile,
        now: Date
    ) async throws -> V2CreateGroupRoomOutcome
}
