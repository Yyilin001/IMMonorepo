import Foundation
import Crypto
import GRDB
import IMV2Core
import IMV2Compression
import ProbeProtocol

enum ProbeFailure: Error { case assertion(String), oversized, deadline }
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw ProbeFailure.assertion(message) }
}

func dependenciesProbe(path: String) throws -> ProbeResult {
    let original = Data("Swift Android 中文消息 0123456789".utf8)
    let compressed = try V2ZlibFrameCompression.compress(original, maximumInputBytes: 1024)
    try require(try V2ZlibFrameCompression.decompress(compressed, maximumOutputBytes: 1024) == original, "zlib round trip")
    let digest = SHA256.hash(data: Data("abc".utf8)).map { String(format: "%02x", $0) }.joined()
    try require(digest == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA256 vector")
    let key = SymmetricKey(size: .bits256)
    let sealed = try AES.GCM.seal(original, using: key)
    try require(try AES.GCM.open(sealed, using: key) == original, "AES-GCM round trip")
    let command = V2FrameCommand(rawValue: 127)
    try require(command == .messageSendOperation, "IMV2Core contract")
    var hello = IMV2ClientHello()
    hello.deviceID = "phase-one-设备"
    hello.supportedProtocolVersions = [55]
    hello.supportedCapabilityProfiles = ["base"]
    let wire = try hello.serializedData()
    try require(try IMV2ClientHello(serializedBytes: wire) == hello, "repository protobuf round trip")

    let pool = try DatabasePool(path: path)
    let mode = try pool.read { try String.fetchOne($0, sql: "PRAGMA journal_mode") }
    try require(mode == "wal", "WAL enabled")
    try pool.write { db in
        try db.execute(sql: "CREATE TABLE IF NOT EXISTS probe_messages(id INTEGER PRIMARY KEY, body TEXT NOT NULL)")
        try db.execute(sql: "CREATE TABLE IF NOT EXISTS probe_ack(id INTEGER PRIMARY KEY, cursor INTEGER NOT NULL)")
        try db.execute(sql: "CREATE VIRTUAL TABLE IF NOT EXISTS probe_fts USING fts5(tokens, tokenize='ascii', detail=full)")
        try db.execute(sql: "DELETE FROM probe_messages; DELETE FROM probe_ack; DELETE FROM probe_fts")
        try db.execute(sql: "INSERT INTO probe_messages VALUES (1, '中文消息'); INSERT INTO probe_ack VALUES (1, 42)")
        try db.execute(sql: "INSERT INTO probe_fts(rowid,tokens) VALUES (1, 'u4e2d u6587 u6d88 u606f')")
    }
    do {
        try pool.write { db in
            try db.execute(sql: "INSERT INTO probe_messages VALUES (2, 'must rollback'); UPDATE probe_ack SET cursor=99")
            throw ProbeFailure.assertion("intentional rollback")
        }
    } catch ProbeFailure.assertion("intentional rollback") {}
    let snapshot = try pool.read { db in
        (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM probe_messages")!,
         try Int.fetchOne(db, sql: "SELECT cursor FROM probe_ack")!,
         try Int.fetchOne(db, sql: "SELECT count(*) FROM probe_fts WHERE probe_fts MATCH '\"u4e2d u6587\"'")!,
         try String.fetchOne(db, sql: "SELECT sqlite_version()")!)
    }
    try require(snapshot.0 == 1 && snapshot.1 == 42, "message and ACK atomic rollback")
    try require(snapshot.2 == 1, "FTS5 phrase positions")
    try pool.close()
    let reopened = try DatabasePool(path: path)
    defer { try? reopened.close() }
    try require(try reopened.read { try Int.fetchOne($0, sql: "SELECT cursor FROM probe_ack") } == 42, "reopen persistence")
    return .init(outcome: "ok", values: ["sqlite": snapshot.3, "wal": mode!, "fts5Phrase": "true", "atomicRollback": "true", "reopen": "true", "crypto": "SHA256,AES-GCM", "protobuf": "repository-generated", "compression": "zlib", "core": "IMV2Core"])
}
