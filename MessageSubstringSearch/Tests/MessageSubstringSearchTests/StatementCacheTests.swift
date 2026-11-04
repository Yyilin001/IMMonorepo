import Testing
@testable import MessageSubstringSearch

@Test(arguments: [0, 1, 64])
func statementReusePreservesBindingsNestedCallsAndErrorRecovery(capacity: Int) throws {
    let db = try SQLiteConnection(path: ":memory:", cacheCapacity: capacity)
    try db.execute("CREATE TABLE test(id INTEGER PRIMARY KEY, text TEXT NOT NULL)")
    try db.run("INSERT INTO test VALUES(?,?)", [.integer(1), .text("a\0b")])
    #expect(throws: SearchIndexError.self) { try db.run("INSERT INTO test VALUES(?,?)", [.integer(1), .text("duplicate")]) }
    try db.run("INSERT INTO test VALUES(?,?)", [.integer(2), .text("second")])
    #expect(try db.string("SELECT text FROM test WHERE id=?", [.integer(1)]) == "a\0b")
    #expect(try db.string("SELECT text FROM test WHERE id=?", [.integer(2)]) == "second")
    try db.statement("SELECT ?", values: [.text("outer")]) { statement in
        let nested = try db.string("SELECT ?", [.text("inner")])
        let hasRow = try db.step(statement)
        #expect(nested == "inner"); #expect(hasRow); #expect(db.text(statement, 0) == "outer")
    }
    try db.execute("ALTER TABLE test ADD COLUMN extra TEXT")
    #expect(try db.string("SELECT text FROM test WHERE id=?", [.integer(2)]) == "second")
    try db.close()
    #expect(throws: SearchIndexError.closed) { try db.integer("SELECT 1") }
}
