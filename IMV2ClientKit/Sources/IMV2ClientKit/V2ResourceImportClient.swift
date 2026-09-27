import Foundation
import GRDB
import IMV2Core
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct V2ResourceImportJob: Sendable {
    public let id: UUID
    public let request: V2ResourceImportRequest
    public let status: V2ResourceImportStatus?
    public let cancellationRequested: Bool
    public let attempts: Int
    public let retryAt: Date
}
public protocol V2ResourceImportControlling: Sendable {
    func create(_ request: V2ResourceImportRequest) async throws -> V2ResourceImportStatus
    func status(_ locator: V2ResourceImportLocator) async throws -> V2ResourceImportStatus
    func cancel(_ locator: V2ResourceImportLocator) async throws -> V2ResourceImportStatus
}
public struct V2HTTPResourceImportClient: V2ResourceImportControlling {
    let endpoint: URL
    let credentials: any V2ClientMediaEdgeCredentialProvider
    let transport: any V2ClientMediaEdgeHTTPTransport
    public init(endpoint: URL, credentials: any V2ClientMediaEdgeCredentialProvider, transport: any V2ClientMediaEdgeHTTPTransport) throws {
        guard endpoint.scheme == "https", endpoint.host != nil, endpoint.user == nil, endpoint.password == nil else { throw V2ClientMediaTransferError.invalidMediaEdgeEndpoint }
        self.endpoint = endpoint; self.credentials = credentials; self.transport = transport
    }
    public func create(_ request: V2ResourceImportRequest) async throws -> V2ResourceImportStatus { try await send(path: nil, body: request) }
    public func status(_ locator: V2ResourceImportLocator) async throws -> V2ResourceImportStatus { try await send(path: "status", body: locator) }
    public func cancel(_ locator: V2ResourceImportLocator) async throws -> V2ResourceImportStatus { try await send(path: "cancel", body: locator) }
    private func send<T: Encodable & Sendable>(path: String?, body: T) async throws -> V2ResourceImportStatus {
        try Task.checkCancellation()
        let credential = try await credentials.mediaEdgeCredentials()
        guard !credential.accessToken.isEmpty, !credential.accessToken.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw V2ClientMediaTransferError.authorizationUnavailable }
        var request = URLRequest(url: path.map { endpoint.appendingPathComponent($0) } ?? endpoint, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"; request.httpBody = try JSONEncoder().encode(body)
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credential.deviceID.rawValue, forHTTPHeaderField: "X-IM-Device-ID")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let (data, response) = try await transport.data(for: request)
        try Task.checkCancellation()
        guard response.statusCode == 200, V2HTTPContract.isJSON(response), data.count <= 64 * 1_024 else { throw V2ClientMediaTransferError.invalidMediaEdgeResponse }
        return try JSONDecoder().decode(V2ResourceImportStatus.self, from: data)
    }
}

extension GRDBV2LocalSyncStore {
    public func prepareResourceImport(id: UUID, request: V2ResourceImportRequest) throws {
        try databasePool.write { db in
            if let existing = try Self.readResourceImport(id, db: db) {
                guard existing.request == request else { throw V2ResourceJournalError.conflict }; return
            }
            try db.execute(sql: "INSERT INTO v2_resource_import_jobs(job_id,request,stage,created_at) VALUES(?,?,'pending',?)", arguments: [id.uuidString, try JSONEncoder().encode(request), Date().timeIntervalSince1970])
        }
    }
    public func resourceImport(id: UUID) throws -> V2ResourceImportJob? { try databasePool.read { try Self.readResourceImport(id, db: $0) } }
    public func saveResourceImport(_ status: V2ResourceImportStatus, id: UUID) throws {
        try databasePool.write { db in
            guard let job = try Self.readResourceImport(id, db: db), job.request.targetMediaID == status.mediaID,
                  job.request.operationID == status.locator.operationID,
                  job.status.map({ $0.locator == status.locator && $0.state != .cancelled && $0.state != .failed }) ?? true else { throw V2ResourceJournalError.conflict }
            if case .messageAttachment(let room) = job.request.targetUsage {
                guard status.locator.home == .room(room) else { throw V2ResourceJournalError.conflict }
            }
            try db.execute(sql: "UPDATE v2_resource_import_jobs SET status=?,stage=?,retry_at=? WHERE job_id=?", arguments: [try JSONEncoder().encode(status), status.state.rawValue, Date().addingTimeInterval(5).timeIntervalSince1970, id.uuidString])
        }
    }
    public func requestImportCancellation(id: UUID) throws {
        try databasePool.write { try $0.execute(sql: "UPDATE v2_resource_import_jobs SET cancellation_requested=1 WHERE job_id=?", arguments: [id.uuidString]) }
    }
    public func pendingImportCancellations() throws -> [UUID] {
        try databasePool.read { db in
            try String.fetchAll(db, sql: "SELECT job_id FROM v2_resource_import_jobs WHERE cancellation_requested=1 AND stage NOT IN ('ready','cancelled','failed') ORDER BY created_at LIMIT 16").compactMap(UUID.init(uuidString:))
        }
    }
    public func retryResourceImport(id: UUID) throws {
        try databasePool.write { try $0.execute(sql: "UPDATE v2_resource_import_jobs SET attempts=0,retry_at=0 WHERE job_id=? AND cancellation_requested=0 AND stage NOT IN ('ready','cancelled','failed')", arguments: [id.uuidString]) }
    }
    public func pauseResourceImport(id: UUID) throws {
        try databasePool.write { try $0.execute(sql: "UPDATE v2_resource_import_jobs SET attempts=attempts+1,retry_at=? WHERE job_id=?", arguments: [Date().addingTimeInterval(5).timeIntervalSince1970, id.uuidString]) }
    }
    static func readResourceImport(_ id: UUID, db: Database) throws -> V2ResourceImportJob? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_resource_import_jobs WHERE job_id=?", arguments: [id.uuidString]) else { return nil }
        let status: Data? = row["status"]
        return try .init(id: id, request: JSONDecoder().decode(V2ResourceImportRequest.self, from: row["request"]), status: status.map { try JSONDecoder().decode(V2ResourceImportStatus.self, from: $0) }, cancellationRequested: row["cancellation_requested"], attempts: row["attempts"], retryAt: Date(timeIntervalSince1970: row["retry_at"]))
    }
}
