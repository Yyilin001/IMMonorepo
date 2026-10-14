import Foundation
import Testing
import IMV2Core
import IMV2ActorContracts
import IMV2ServerContracts
import IMV2ServerGateway
@testable import IMV2ServerApp

struct GatewayJournalIncrementalRecoveryTests {
    @Test func continuousHistoryDiscoversChangesBeyondTheRemoteHint() {
        let first = UserID(uuid: UUID()), second = UserID(uuid: UUID()), other = UserID(uuid: UUID())
        var hints = V2GatewayJournalRecoveryControls(); hints.versions[first] = 2
        var plan = GatewayJournalControlCatchUp(through: 10, target: 13, controls: hints,
            localUsers: [first, second], installedVersions: [first: 1, second: 1])
        let device = UUID(), room = UUID()
        let accepted = plan.append(batch([
            row(11, other, 100), row(12, first, 2),
            .init(partitionID: 1, sequence: 13, sourceEventID: UUID(), topicKind: "userSync", topicID: second.rawValue,
                changeKind: "userControl", userControlVersion: 3, deviceID: device, membershipRoomID: room)
        ], published: 13), partitionID: 1)
        #expect(accepted)
        #expect(plan.through == 13 && plan.selectedUsers == [first, second])
        #expect(plan.controls.devices == [.init(userID: second.uuidValue!, deviceID: device)])
        #expect(plan.controls.membershipVersions[second] == 3)
        #expect(plan.controls.membershipRooms[second] == [RoomID(uuid: room)])
    }
    @Test func newerPublishedStateCannotAdvanceBeyondTheExaminedTarget() {
        let user = UserID(uuid: UUID())
        var plan = GatewayJournalControlCatchUp(through: 10, target: 11, controls: .init(),
            localUsers: [user], installedVersions: [user: 2])
        let accepted = plan.append(batch([row(11, user, 2), row(12, user, 3)], published: 12), partitionID: 1)
        #expect(accepted)
        #expect(plan.through == 11 && plan.selectedUsers.isEmpty)
    }
    @Test func pagedHistoryDoesNotBecomeCompleteBeforeTheLastPage() {
        let user = UserID(uuid: UUID())
        var plan = GatewayJournalControlCatchUp(through: 10, target: 12, controls: .init(),
            localUsers: [user], installedVersions: [user: 1])
        let first = plan.append(batch([row(11, user, 2)], published: 12), partitionID: 1)
        #expect(first)
        #expect(plan.through < plan.target)
        let last = plan.append(batch([row(12, user, 3)], published: 12), partitionID: 1)
        #expect(last)
        #expect(plan.through == plan.target && plan.controls.versions[user] == 3)
    }
    @Test(arguments: [0, 1, 2, 3, 4]) func incompleteEvidenceRequiresFullRecovery(kind: Int) {
        let user = UserID(uuid: UUID())
        var plan = GatewayJournalControlCatchUp(through: 10, target: 11, controls: .init(),
            localUsers: [user], installedVersions: [user: 1])
        var entry = row(kind == 1 ? 12 : 11, user, 2)
        if kind == 2 {
            entry = .init(partitionID: 1, sequence: 11, sourceEventID: UUID(), topicKind: "userSync", topicID: user.rawValue, changeKind: "opaque")
        }
        let range = V2RealtimeJournalBatch(partitionID: kind == 4 ? 2 : 1, publishedThrough: 11,
            trimmedThrough: kind == 0 ? 11 : 0, requiresSnapshot: kind == 0, entries: kind == 3 ? [] : [entry])
        let accepted = plan.append(range, partitionID: 1)
        #expect(!accepted)
    }
    private func batch(_ entries: [V2RealtimeJournalEntry], published: Int64) -> V2RealtimeJournalBatch {
        .init(partitionID: 1, publishedThrough: published, trimmedThrough: 0, requiresSnapshot: false, entries: entries)
    }
    private func row(_ sequence: Int64, _ user: UserID, _ version: Int64) -> V2RealtimeJournalEntry {
        .init(partitionID: 1, sequence: sequence, sourceEventID: UUID(), topicKind: "userSync", topicID: user.rawValue,
            changeKind: "userControl", userControlVersion: version)
    }
}
