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
    public let control: V2ResourceTransferControl
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
    public func create(_ request: V2ResourceImportRequest) async throws -> V2ResourceImportStatus {
        let result = try await send(path: nil, body: request)
        guard result.locator.operationID == request.operationID, result.mediaID == request.targetMediaID else {
            throw V2ClientMediaTransferError.invalidMediaEdgeResponse
        }
        switch request.targetUsage {
        case .messageAttachment(let room), .groupAvatar(let room):
            guard result.locator.home == .room(room) else { throw V2ClientMediaTransferError.invalidMediaEdgeResponse }
        case .userAvatar:
            // The journal additionally binds this account to its authenticated
            // local installation. Credentials here do not expose an actor ID.
            guard case .account = result.locator.home else { throw V2ClientMediaTransferError.invalidMediaEdgeResponse }
        }
        return result
    }
    public func status(_ locator: V2ResourceImportLocator) async throws -> V2ResourceImportStatus {
        try await send(path: "status", locator: locator)
    }
    public func cancel(_ locator: V2ResourceImportLocator) async throws -> V2ResourceImportStatus {
        try await send(path: "cancel", locator: locator)
    }
    private func send(path: String, locator: V2ResourceImportLocator) async throws -> V2ResourceImportStatus {
        let result = try await send(path: path, body: locator)
        guard result.locator == locator else { throw V2ClientMediaTransferError.invalidMediaEdgeResponse }
        return result
    }
    private func send<T: Encodable & Sendable>(path: String?, body: T) async throws -> V2ResourceImportStatus {
        try Task.checkCancellation()
        let credential = try await credentials.mediaEdgeCredentials()
        try Task.checkCancellation()
        guard !credential.accessToken.isEmpty, !credential.accessToken.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw V2ClientMediaTransferError.authorizationUnavailable }
        var request = URLRequest(url: path.map { endpoint.appendingPathComponent($0) } ?? endpoint, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"; request.httpBody = try JSONEncoder().encode(body)
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credential.deviceID.rawValue, forHTTPHeaderField: "X-IM-Device-ID")
        V2HTTPRequestDeadline.attach(credential.requestDeadline, to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let (data, response) = try await transport.data(for: request)
        try Task.checkCancellation()
        guard response.statusCode == 200 else {
            if response.statusCode == 401 { throw V2ClientMediaTransferError.authorizationUnavailable }
            throw V2HTTPFailure.status(response, service: "resources")
        }
        guard V2HTTPContract.isJSON(response), data.count <= 64 * 1_024 else { throw V2ClientMediaTransferError.invalidMediaEdgeResponse }
        do { return try JSONDecoder().decode(V2ResourceImportStatus.self, from: data) }
        catch { throw V2ClientMediaTransferError.invalidMediaEdgeResponse }
    }
}

extension GRDBV2LocalSyncStore {
    public func prepareResourceImport(id: UUID, request: V2ResourceImportRequest) throws {
        try databasePool.write { db in
            try Self.prepareResourceImport(id: id, request: request, now: Date(), db: db)
        }
    }
    public func resourceImport(id: UUID) throws -> V2ResourceImportJob? { try databasePool.read { try Self.readResourceImport(id, db: $0) } }
    public func saveResourceImport(_ status: V2ResourceImportStatus, id: UUID, owner: UUID) throws {
        try databasePool.write { db in
            guard try String.fetchOne(db, sql: "SELECT execution_owner FROM v2_resource_import_jobs WHERE job_id=?", arguments: [id.uuidString]) == owner.uuidString else { throw V2ResourceJournalError.conflict }
            try Self.saveResourceImport(status, id: id, db: db)
        }
    }
    static func saveResourceImport(_ status: V2ResourceImportStatus, id: UUID, db: Database) throws {
        guard let job = try Self.readResourceImport(id, db: db), job.request.targetMediaID == status.mediaID,
              job.request.operationID == status.locator.operationID,
              job.status.map({ $0.locator == status.locator && $0.state != .cancelled && $0.state != .failed }) ?? true else { throw V2ResourceJournalError.conflict }
        // A matching operation/media pair does not prove the result belongs
        // to this account or room. Resolve userAvatar from the bound local
        // installation, never from the returned locator or source context.
        guard let rawUser = try String.fetchOne(db, sql: "SELECT user_id FROM v2_local_installation WHERE singleton=1"),
              status.locator.home == job.request.targetUsage.home(actorUserID: try UserID(rawUser)) else {
            throw V2ResourceJournalError.conflict
        }
        guard job.status?.state != .ready || [.ready, .cancelled, .failed].contains(status.state) else { throw V2ResourceJournalError.conflict }
        let polls = (try Int.fetchOne(db, sql: "SELECT poll_attempts FROM v2_resource_import_jobs WHERE job_id=?", arguments: [id.uuidString]) ?? 0) + 1
        let delay: Double = polls < 3 ? 2 : polls < 6 ? 5 : polls < 12 ? 10 : 30
        let terminal = [.ready,.cancelled,.failed].contains(status.state)
        let exhausted = !terminal && polls >= 60
        try db.execute(sql: "UPDATE v2_resource_import_jobs SET status=?,stage=?,retry_at=MAX(server_retry_not_before,?),attempts=?,round_deadline=NULL,poll_attempts=? WHERE job_id=?", arguments: [try JSONEncoder().encode(status), status.state.rawValue, Date().addingTimeInterval(delay).timeIntervalSince1970, exhausted ? 5 : 0, polls, id.uuidString])
    }
    public func requestImportCancellation(id: UUID) throws {
        try databasePool.write { try Self.requestUnboundAvatarImportCancellation(id, db: $0) }
    }
    public func pendingImportCancellations() throws -> [UUID] {
        try databasePool.read { db in
            try String.fetchAll(db, sql: "SELECT job_id FROM v2_resource_import_jobs WHERE cancellation_requested=1 AND stage NOT IN ('ready','cancelled','failed') ORDER BY created_at LIMIT 16").compactMap(UUID.init(uuidString:))
        }
    }
    public func retryResourceImport(id: UUID) throws {
        try databasePool.write { try Self.retryResourceImport(id: id, db: $0) }
    }
    static func retryResourceImport(id: UUID, db: Database) throws {
        try db.execute(sql: "UPDATE v2_resource_import_jobs SET attempts=0,retry_at=server_retry_not_before,poll_attempts=0,round_deadline=NULL WHERE job_id=? AND execution_owner IS NULL AND cancellation_requested=0 AND user_control='run' AND stage NOT IN ('ready','cancelled','failed')", arguments: [id.uuidString])
    }
    public func pauseResourceImport(id: UUID, retryNotBefore: Date? = nil, needsAttention: Bool = false) throws {
        try databasePool.write { db in
            guard try String.fetchOne(db, sql: "SELECT execution_owner FROM v2_resource_import_jobs WHERE job_id=?", arguments: [id.uuidString]) == nil else { throw V2ResourceJournalError.conflict }
            try Self.pauseResourceImport(id: id, retryNotBefore: retryNotBefore, needsAttention: needsAttention, db: db)
        }
    }
    public func pauseResourceImport(id: UUID, owner: UUID, retryNotBefore: Date? = nil, needsAttention: Bool = false) throws {
        try databasePool.write { db in
            guard try String.fetchOne(db, sql: "SELECT execution_owner FROM v2_resource_import_jobs WHERE job_id=?", arguments: [id.uuidString]) == owner.uuidString else { throw V2ResourceJournalError.conflict }
            try Self.pauseResourceImport(id: id, retryNotBefore: retryNotBefore, needsAttention: needsAttention, db: db)
        }
    }
    private static func pauseResourceImport(id: UUID, retryNotBefore: Date?, needsAttention: Bool, db: Database) throws {
        let deadline = try Double.fetchOne(db, sql: "SELECT round_deadline FROM v2_resource_import_jobs WHERE job_id=?", arguments: [id.uuidString])
        let beyondBudget = retryNotBefore.map { $0.timeIntervalSince1970 >= (deadline ?? .infinity) } ?? false
        try db.execute(sql: "UPDATE v2_resource_import_jobs SET attempts=CASE WHEN ? THEN 5 ELSE attempts END,retry_at=MAX(retry_at,?),server_retry_not_before=MAX(server_retry_not_before,?) WHERE job_id=?", arguments: [needsAttention || beyondBudget,retryNotBefore?.timeIntervalSince1970 ?? 0,retryNotBefore?.timeIntervalSince1970 ?? 0,id.uuidString])
    }
    static func readResourceImport(_ id: UUID, db: Database) throws -> V2ResourceImportJob? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM v2_resource_import_jobs WHERE job_id=?", arguments: [id.uuidString]) else { return nil }
        let status: Data? = row["status"]
        guard let control = V2ResourceTransferControl(rawValue: row["user_control"]) else { throw V2ResourceJournalError.invalidRecord }
        return try .init(id: id, request: JSONDecoder().decode(V2ResourceImportRequest.self, from: row["request"]), status: status.map { try JSONDecoder().decode(V2ResourceImportStatus.self, from: $0) }, cancellationRequested: row["cancellation_requested"], control: control, attempts: row["attempts"], retryAt: Date(timeIntervalSince1970: row["retry_at"]))
    }
}
