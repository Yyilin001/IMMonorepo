@testable import IMV2ServerInfrastructure
import Testing

@Suite("Room SQL deadline scope reuse")
struct V2RoomSQLDeadlineScopeTests {
    @Test("nested scopes retain the earliest deadline and restore it after tightening")
    func nestedDeadlines() async {
        let outer = ContinuousClock.now + .seconds(10)
        let earlier = outer - .seconds(1)
        #expect(V2RoomSQLDeadline.current == nil)
        await V2RoomSQLDeadline.withDeadline(outer) {
            await V2RoomSQLDeadline.withDeadline(outer + .seconds(1)) {
                #expect(V2RoomSQLDeadline.current == outer)
            }
            await V2RoomSQLDeadline.withDeadline(outer) {
                #expect(V2RoomSQLDeadline.current == outer)
            }
            await V2RoomSQLDeadline.withDeadline(earlier) {
                #expect(V2RoomSQLDeadline.current == earlier)
            }
            #expect(V2RoomSQLDeadline.current == outer)
        }
        #expect(V2RoomSQLDeadline.current == nil)
    }

    @Test("selected batches replace inherited deadlines, including clearing the scope")
    func selectedDeadlineReplacesInherited() async {
        let inherited = ContinuousClock.now + .seconds(1)
        let selected = inherited + .seconds(1)
        await V2RoomSQLDeadline.withDeadline(inherited) {
            await V2RoomSQLDeadline.withSelectedDeadline(selected) {
                #expect(V2RoomSQLDeadline.current == selected)
            }
            await V2RoomSQLDeadline.withSelectedDeadline(nil) {
                #expect(V2RoomSQLDeadline.current == nil)
            }
            #expect(V2RoomSQLDeadline.current == inherited)
        }
    }

    @Test("throwing from a reused scope preserves task-local restoration")
    func throwingScopeRestoresDeadline() async {
        enum Failure: Error { case expected }
        let deadline = ContinuousClock.now + .seconds(1)
        do {
            try await V2RoomSQLDeadline.withDeadline(deadline) {
                try await V2RoomSQLDeadline.withDeadline(deadline) { throw Failure.expected }
            }
            Issue.record("expected failure")
        } catch {
            #expect(error is Failure)
        }
        #expect(V2RoomSQLDeadline.current == nil)
    }
}
