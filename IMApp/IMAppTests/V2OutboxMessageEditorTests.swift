import Foundation
@testable import IMV2ClientKit
import IMV2Core
import Testing
@testable import IMApp

@MainActor
@Suite("App durable message editor")
struct V2OperationMessageEditorTests {
    @Test("older completion cannot change the current page enqueue outcome",arguments:[false,true])
    func editOutcomeCorrelation(rejectOld:Bool) async throws {
        let f=try V2AppMessageWorkFixture(rejectOld:rejectOld);defer { f.remove() }
        let oldID=try await f.mutation.enqueueEdit(roomID:f.room,messageID:.init(uuid:UUID()),expectedRevision:1,text:"old")
        let old=try #require(try await f.store.operationWork(id:oldID))
        try await f.mutation.execute(f.claim(old))
        let editor=V2OperationMessageEditor(service:f.mutation)
        #expect(try await editor.edit(messageID:MessageID(uuid:UUID()).rawValue,in:f.room.rawValue,expectedMessageRevision:1,text:"new") == .queuedForRetry)
        let pending=try await f.store.dueOperationWork(now:.now,kinds:[.editMessage])
        #expect(pending.count==1 && pending[0].id != old.id)
        guard case .edit(let saved)=try await f.store.messageMutationPayload(workID:pending[0].id) else { Issue.record("missing edit");return }
        #expect(saved.text=="new")
        #expect(await f.remote.calls==1)
        try await f.store.close()
    }
}
