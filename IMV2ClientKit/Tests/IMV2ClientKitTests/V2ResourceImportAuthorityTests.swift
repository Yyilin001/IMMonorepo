import Foundation
import IMV2Core
import Testing
@testable import IMV2ClientKit

@Suite("Import results remain bound to the destination account and room")
struct V2ResourceImportAuthorityTests {
    enum Usage: CaseIterable, Sendable { case attachment, personalAvatar, groupAvatar }

    @Test(arguments: Usage.allCases)
    func wrongHomeCannotReplacePendingOrAcceptedStatus(usage: Usage) async throws {
        let f = try Fixture(usage: usage)
        let owner = UUID()
        try await f.store.prepareResourceImport(id: f.job, request: f.request)
        #expect(try await f.store.claimResourceImport(f.job, owner: owner))
        let wrongHomes: [V2ResourceHome] = switch usage {
        case .attachment, .groupAvatar: [.room(.init(uuid: UUID())), .account(f.user)]
        case .personalAvatar: [.account(.init(uuid: UUID())), .room(f.room)]
        }
        for home in wrongHomes {
            await #expect(throws: V2ResourceJournalError.conflict) {
                try await f.store.saveResourceImport(f.status(.copying, home: home), id: f.job, owner: owner)
            }
            #expect(try await f.store.resourceImport(id: f.job)?.status == nil)
        }
        let accepted = try f.status(.copying, home: f.home)
        try await f.store.saveResourceImport(accepted, id: f.job, owner: owner)
        for home in wrongHomes {
            await #expect(throws: V2ResourceJournalError.conflict) {
                try await f.store.saveResourceImport(f.status(.ready, home: home), id: f.job, owner: owner)
            }
            #expect(try await f.store.resourceImport(id: f.job)?.status == accepted)
        }
        let ready = try f.status(.ready, home: f.home)
        try await f.store.saveResourceImport(ready, id: f.job, owner: owner)
        #expect(try await f.store.resourceImport(id: f.job)?.status == ready)
        try await f.store.releaseResourceImportExecution(f.job, owner: owner)
        try await f.close()
    }

    @Test(arguments: Usage.allCases)
    func wrongOperationOrMediaCannotMutatePendingOrAcceptedJournal(usage: Usage) async throws {
        let f = try Fixture(usage: usage), owner = UUID()
        try await f.store.prepareResourceImport(id: f.job, request: f.request)
        #expect(try await f.store.claimResourceImport(f.job, owner: owner))
        for state in [V2ResourceImportState.copying, .ready] {
            let before = try await f.store.resourceImport(id: f.job)?.status
            let deadline: Date? = state == .ready ? .distantFuture : nil
            let wrongOperation = try V2ResourceImportStatus(locator: .init(home: f.home, operationID: .init(uuid: UUID())),
                mediaID: f.request.targetMediaID, state: state, bindableUntil: deadline)
            let wrongMedia = try V2ResourceImportStatus(locator: .init(home: f.home, operationID: f.request.operationID),
                mediaID: .init(uuid: UUID()), state: state, bindableUntil: deadline)
            for wrong in [wrongOperation, wrongMedia] {
                await #expect(throws: V2ResourceJournalError.conflict) {
                    try await f.store.saveResourceImport(wrong, id: f.job, owner: owner)
                }
                #expect(try await f.store.resourceImport(id: f.job)?.status == before)
            }
            let valid = try f.status(state, home: f.home)
            try await f.store.saveResourceImport(valid, id: f.job, owner: owner)
            #expect(try await f.store.resourceImport(id: f.job)?.status == valid)
        }
        try await f.store.releaseResourceImportExecution(f.job, owner: owner)
        try await f.close()
    }

    @Test func personalAvatarUsesBoundAccountInsteadOfSourceRoomAcrossReopen() async throws {
        let f = try Fixture(usage: .personalAvatar)
        try await f.store.prepareResourceImport(id: f.job, request: f.request)
        try await f.store.close()
        let reopened = try GRDBV2LocalSyncStore(databaseURL: f.root.appending(path: "V2.sqlite"), installationBinding: f.binding, userID: f.user)
        let owner = UUID()
        #expect(try await reopened.claimResourceImport(f.job, owner: owner))
        await #expect(throws: V2ResourceJournalError.conflict) {
            try await reopened.saveResourceImport(f.status(.ready, home: .room(f.room)), id: f.job, owner: owner)
        }
        let ready = try f.status(.ready, home: .account(f.user))
        try await reopened.saveResourceImport(ready, id: f.job, owner: owner)
        #expect(try await reopened.resourceImport(id: f.job)?.status == ready)
        try await reopened.releaseResourceImportExecution(f.job, owner: owner)
        try await reopened.close()
        try FileManager.default.removeItem(at: f.root)
    }

    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "import-authority-\(UUID())")
        let user = UserID(uuid: UUID()), room = RoomID(uuid: UUID()), job = UUID()
        let binding = V2LocalInstallationBinding(value: UUID())
        let request: V2ResourceImportRequest
        let home: V2ResourceHome
        let store: GRDBV2LocalSyncStore
        init(usage: Usage) throws {
            let target: V2ResourceUsage = switch usage {
            case .attachment: .messageAttachment(room)
            case .personalAvatar: .userAvatar
            case .groupAvatar: .groupAvatar(room)
            }
            home = target.home(actorUserID: user)
            request = try .init(operationID: .init(uuid: UUID()),
                source: .message(location: .init(roomID: room, messageID: .init(uuid: UUID())), mediaID: .init(uuid: UUID()), variantID: nil),
                targetUsage: target, targetMediaID: .init(uuid: UUID()))
            store = try .init(databaseURL: root.appending(path: "V2.sqlite"), installationBinding: binding, userID: user)
        }
        func status(_ state: V2ResourceImportState, home: V2ResourceHome) throws -> V2ResourceImportStatus {
            try .init(locator: .init(home: home, operationID: request.operationID), mediaID: request.targetMediaID,
                state: state, bindableUntil: state == .ready ? .distantFuture : nil)
        }
        func close() async throws { try await store.close(); try FileManager.default.removeItem(at: root) }
    }
}
