import HTTPTypes
import Foundation
import IMV2Core
@testable import IMV2Server
import IMV2ServerHTTP
import Testing
import Vapor
import VaporTesting

@Suite("V2 group invitation response clocks")
struct V2VaporGroupInvitationRoutesTests {
    @Test("invitation responses reject invalid dates and preserve valid results", arguments: [
        "cancel:created_at_ms", "cancel:decided_at_ms", "cancelled_submission:decided_at_ms", "create:created_at_ms", "create:expires_at_ms", "list:created_at_ms", "list:expires_at_ms",
        "preview:expires_at_ms", "submitted:created_at_ms", "pending_submission:created_at_ms",
        "rejected_submission:created_at_ms", "rejected_submission:decided_at_ms", "member_submission:expires_at_ms",
        "pending_page:created_at_ms", "approve:created_at_ms", "approve:decided_at_ms",
        "reject:created_at_ms", "reject:decided_at_ms", "already:created_at_ms", "already:decided_at_ms"
    ])
    func responseClockBounds(scenario: String) async throws {
        let parts = scenario.split(separator: ":").map(String.init)
        let route = parts[0], field = parts[1]
        let fixture = InvitationClockFixture()
        let store = InvitationClockStore(fixture: fixture, route: route, field: field)
        let app = try await Application(.testing)
        do {
            let service = V2GroupInvitationService(store: store, capacityProfile: try invitationClockProfile(), secretIssuer: try .init(rawKey: Data(repeating: 0x19, count: 32)), now: { fixture.base })
            V2VaporGroupInvitationRoutes(authenticator: InvitationClockAuthenticator(userID: fixture.userID), invitations: service).register(on: app)
            let method: HTTPRequest.Method = route == "list" || route == "pending_page" ? .get : .post
            let path: String
            switch route {
            case "cancel": path = "v2/group-join-requests/\(fixture.requestID.rawValue)/cancel"
            case "create": path = "v2/group-invites"
            case "list": path = "v2/group-invites?room_id=\(fixture.roomID.rawValue)"
            case "preview": path = "v2/group-invites/preview"
            case "pending_page": path = "v2/group-join-requests?room_id=\(fixture.roomID.rawValue)&page_size=2"
            case "approve", "reject", "already": path = "v2/group-join-requests/\(fixture.requestID.rawValue)/decision"
            default: path = "v2/group-join-requests"
            }
            let body = InvitationClockBody(roomID: fixture.roomID.rawValue, operationID: fixture.operationID.uuidString, token: String(repeating: "a", count: 43), lifetimeSeconds: 3600, maximumApprovedUses: 1, decision: route == "reject" ? "reject" : "approve")
            let invalid = [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude, Double(Int64.max) / 1_000, Double(Int64.min) / 1_000 - 2]
            let valid: [(Double, Int64)] = [(1_750_000_000.125, 1_750_000_000_125), (-1.00025, -1_000), (946_684_800 - 211_813_488_000, -210_866_803_200_000), (946_684_800 + 9_223_371_331_200 - 10, 9_224_318_015_990_000)]
            for (seconds, expected) in invalid.map({ ($0, Optional<Int64>.none) }) + valid.map({ ($0.0, Optional($0.1)) }) {
                await store.setDate(Date(timeIntervalSince1970: seconds))
                try await app.testing { client in
                    let response = try await client.send(method, to: URI(string: path), beforeSend: { request in
                    request.headers.bearerAuthorization = .init(token: "invitation-clock-fixture")
                    request.headers[HTTPField.Name("X-IM-Device-ID")!] = fixture.deviceID.rawValue
                    if method == .post { try request.content.encode(body) }
                })
                    #expect(response.headers[.cacheControl] == "no-store")
                    #expect(response.headers[.pragma] == "no-cache")
                    guard let expected else {
                        #expect(response.status == .serviceUnavailable)
                        let error = try JSONSerialization.jsonObject(with: (try await response.body.data() ?? Data())) as? [String: Any]
                        #expect(error?["error"] as? Bool == true)
                        #expect(error?["items"] == nil && error?["token"] == nil && error?["request"] == nil)
                        return
                    }
                    #expect(response.status == .ok)
                    let root = try #require(try JSONSerialization.jsonObject(with: (try await response.body.data() ?? Data())) as? [String: Any])
                    let value: [String: Any]
                    switch route {
                    case "list", "pending_page":
                        let items = try #require(root["items"] as? [[String: Any]])
                        #expect(items.count == 2)
                        value = try #require(items.last)
                        if route == "pending_page" { #expect(root["next_cursor"] as? String == "next-page") }
                    case "submitted", "pending_submission", "cancelled_submission", "rejected_submission", "approve", "reject", "already":
                        value = try #require(root["request"] as? [String: Any])
                        let expectedKind: String
                        switch route {
                        case "cancelled_submission": expectedKind = "cancelled"
                        case "pending_submission": expectedKind = "already_pending"
                        case "rejected_submission", "reject": expectedKind = "rejected"
                        case "approve": expectedKind = "approved"
                        case "already": expectedKind = "already_decided"
                        default: expectedKind = "submitted"
                        }
                        #expect(root["kind"] as? String == expectedKind)
                    case "member_submission":
                        value = try #require(root["preview"] as? [String: Any])
                        #expect(root["kind"] as? String == "already_member")
                    default: value = root
                    }
                    #expect((value[field] as? NSNumber)?.int64Value == expected)
                    #expect(value["room_id"] as? String == fixture.roomID.rawValue)
                    if value["request_id"] != nil {
                        #expect(value["applicant_user_id"] as? String == fixture.userID.rawValue)
                        #expect(value["applicant"] == nil && value["display_name"] == nil && value["handle"] == nil)
                    }
                    if route == "create" || route == "list" {
                        #expect(value["state"] as? String == "active")
                        #expect((value["token"] as? String)?.isEmpty == false)
                    }
                    if route == "pending_page" || route == "submitted" || route == "pending_submission" {
                        #expect(value["decided_at_ms"] == nil)
                    }
                }
            }
            try await app.shutdown()
        } catch {
            try? await app.shutdown()
            throw error
        }
    }
}

private struct InvitationClockBody: Content {
    let roomID: String
    let operationID: String
    let token: String
    let lifetimeSeconds: Int
    let maximumApprovedUses: Int
    let decision: String
    enum CodingKeys: String, CodingKey {
        case roomID = "room_id", operationID = "operation_id", token
        case lifetimeSeconds = "lifetime_seconds", maximumApprovedUses = "maximum_approved_uses", decision
    }
}

private struct InvitationClockFixture: Sendable {
    let roomID = RoomID(uuid: UUID())
    let userID = UserID(uuid: UUID())
    let deviceID = DeviceID(uuid: UUID())
    let inviteID = GroupInviteID(uuid: UUID())
    let requestID = GroupJoinRequestID(uuid: UUID())
    let operationID = UUID()
    let base = Date(timeIntervalSince1970: 1_750_000_000)
}

private struct InvitationClockAuthenticator: V2GatewayAuthenticator {
    let userID: UserID
    func authenticateSession(accessToken: String, deviceID: DeviceID) async throws -> V2GatewayAuthentication {
        guard accessToken == "invitation-clock-fixture" else { throw V2GroupInvitationServiceError.permissionDenied }
        return .init(userID: userID, expiresAt: nil)
    }
}

private actor InvitationClockStore: V2GroupInvitationStore {
    let fixture: InvitationClockFixture
    let route: String
    let field: String
    var date: Date

    init(fixture: InvitationClockFixture, route: String, field: String) {
        self.fixture = fixture; self.route = route; self.field = field; date = fixture.base
    }
    func setDate(_ date: Date) { self.date = date }

    private func link(at date: Date) -> V2StoredGroupInvite {
        var created = fixture.base, expiry = fixture.base.addingTimeInterval(3600)
        if field == "created_at_ms" {
            created = date
            if expiry <= created { expiry = created.addingTimeInterval(3600) }
            if expiry <= created { expiry = Date(timeIntervalSince1970: .infinity) }
        } else {
            expiry = date
            if created >= expiry { created = expiry.addingTimeInterval(-3600) }
            if created >= expiry { created = Date(timeIntervalSince1970: -.infinity) }
        }
        return .init(inviteID: fixture.inviteID, roomID: fixture.roomID, roomTitle: "Clock fixture", createdByUserID: fixture.userID, creationOperationID: .init(uuid: fixture.operationID), state: .active, expiresAt: expiry, maximumApprovedUses: 1, approvedUseCount: 0, createdAt: created)
    }
    private func preview() -> V2GroupInvitePreviewRecord {
        .init(inviteID: fixture.inviteID, roomID: fixture.roomID, roomTitle: "Clock fixture", expiresAt: date, requestState: nil, requestID: nil, isAlreadyMember: route == "member_submission")
    }
    private func record(at date: Date) throws -> V2GroupJoinRequestRecord {
        let state: V2GroupJoinRequestState
        switch route {
        case "cancel", "cancelled_submission": state = .cancelled
        case "approve", "already": state = .approved
        case "reject", "rejected_submission": state = .rejected
        default: state = .pending
        }
        let decided = state == .approved || state == .rejected || state == .cancelled
        return try .init(requestID: fixture.requestID, inviteID: fixture.inviteID, roomID: fixture.roomID, applicant: .init(userID: fixture.userID, handle: .init("clock_applicant"), displayName: "Clock Applicant", accountKind: .regular), note: "fixture request", state: state, decisionOperationID: decided && state != .cancelled ? .init(uuid: fixture.operationID) : nil, decidedByUserID: decided ? fixture.userID : nil, createdAt: field == "created_at_ms" ? date : fixture.base, decidedAt: decided ? (field == "decided_at_ms" ? date : fixture.base) : nil)
    }
    func create(_ request: V2GroupInviteCreatePersistenceRequest) -> V2StoredGroupInvite { link(at: date) }
    func activeInvites(roomID: RoomID, actorUserID: UserID, now: Date) -> [V2StoredGroupInvite] { [link(at: fixture.base), link(at: date)] }
    func revoke(inviteID: GroupInviteID, roomID: RoomID, actorUserID: UserID, operationID: GroupInviteOperationID, now: Date) throws { throw V2GroupInvitationServiceError.invalidRequest }
    func preview(tokenDigest: Data, applicantUserID: UserID, now: Date) -> V2GroupInvitePreviewPersistenceOutcome { .available(preview()) }
    func submit(_ request: V2GroupJoinSubmissionPersistenceRequest) throws -> V2GroupJoinSubmissionPersistenceOutcome {
        switch route {
        case "cancelled_submission": .cancelled(try record(at: date))
        case "pending_submission": .alreadyPending(try record(at: date))
        case "rejected_submission": .rejected(try record(at: date))
        case "member_submission": .alreadyMember(preview())
        default: .submitted(try record(at: date))
        }
    }
    func pendingRequests(roomID: RoomID, reviewerUserID: UserID, cursor: String?, pageSize: Int, now: Date) throws -> V2GroupJoinRequestRecordPage {
        try .init(requests: [record(at: fixture.base), record(at: date)], nextCursor: "next-page")
    }
    func approve(roomID: RoomID, requestID: GroupJoinRequestID, reviewerUserID: UserID, operationID: GroupJoinDecisionOperationID, capacityProfile: V2CapacityProfile, eventID: EventID, now: Date) throws -> V2GroupJoinApprovalPersistenceOutcome {
        route == "already" ? .alreadyDecided(try record(at: date)) : .approved(try record(at: date))
    }
    func cancel(roomID: RoomID, requestID: GroupJoinRequestID, applicantUserID: UserID, now: Date) async throws -> V2GroupJoinRequestRecord {
        #expect(roomID == fixture.roomID && requestID == fixture.requestID && applicantUserID == fixture.userID)
        return try record(at: date)
    }
    func reject(roomID: RoomID, requestID: GroupJoinRequestID, reviewerUserID: UserID, operationID: GroupJoinDecisionOperationID, now: Date) throws -> V2GroupJoinDecisionPreparationOutcome { .rejected(try record(at: date)) }
}

private func invitationClockProfile() throws -> V2CapacityProfile {
    try .init(id: "standard", limits: .init(maxEligibleMembers: 100, maxCommandsPerWindow: 100,    retryAfterSeconds: 1))
}
