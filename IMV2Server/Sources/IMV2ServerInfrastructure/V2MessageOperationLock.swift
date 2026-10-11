import Foundation
import SQLKit

/// 此键须与有类型数组或 JSON 批次语句使用的键完全一致。
func v2AcquireMessageOperationLock(roomID: UUID, senderID: UUID, clientMessageID: UUID, sql: any SQLDatabase) async throws {
    let key = "v2-message-operation:" + roomID.uuidString.lowercased() + ":" + senderID.uuidString.lowercased() + ":" + clientMessageID.uuidString.lowercased()
    try await sql.raw("SELECT pg_advisory_xact_lock(hashtextextended(\(bind: key), 0))").run()
}
