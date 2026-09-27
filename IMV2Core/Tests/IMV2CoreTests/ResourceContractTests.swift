import Foundation
import IMV2Core
import Testing

@Suite("Supplier-independent resource contracts")
struct ResourceContractTests {
    private let expiry = Date(timeIntervalSince1970: 2_000_000_000)
    private var checksum: V2ResourceChecksum { get throws { try .init(value: String(repeating: "a", count: 64)) } }

    @Test("review and membership scopes are distinct even for the same room")
    func reviewContextBudget() throws {
        let user = UserID(uuid: UUID())
        let rooms = (0..<4).map { _ in RoomID(uuid: UUID()) }
        let keys = rooms.flatMap { room in [
            V2ProfileViewLookupKey(userID: user, context: .room(room)),
            V2ProfileViewLookupKey(userID: user, context: .groupJoinReview(room))
        ] }
        let request = try V2ProfilePresentationBatchRequest(keys: keys)
        #expect(try JSONDecoder().decode(V2ProfilePresentationBatchRequest.self, from: JSONEncoder().encode(request)) == request)
        #expect(throws: V2ResourceValidationError.invalidPresentationLease) {
            try V2ProfilePresentationBatchRequest(keys: keys + [.init(userID: user, context: .directConversation)])
        }
        #expect(keys[0] != keys[1] && keys[1].context.authorizationRoomID == rooms[0])
    }

    @Test("resolved direct-conversation contexts count toward the room fanout budget")
    func directContextBudget() throws {
        let keys = try (0..<9).map { V2ProfileViewLookupKey(userID: try .init("user\($0)"), context: .directConversation) }
        #expect(throws: V2ResourceValidationError.invalidPresentationLease) { try V2ProfilePresentationBatchRequest(keys: keys) }
        #expect(try V2ProfilePresentationBatchRequest(keys: Array(keys.prefix(8))).keys.count == 8)
        let relationshipKeys = keys.map { V2ProfileViewLookupKey(userID: $0.userID, context: .relationship) }
        #expect(try V2ProfilePresentationBatchRequest(keys: relationshipKeys).keys.count == 9)
    }

    @Test("cross-home import retains authorized source context and cannot reuse the source identity")
    func importContracts() throws {
        let source = V2ResourceImportSource.message(location: try .init(roomID: .init("room-a"), messageID: .init("message")),
                                                   mediaID: try .init("source"), variantID: nil)
        let request = try V2ResourceImportRequest(operationID: .init("import"), source: source,
            targetUsage: .messageAttachment(.init("room-b")), targetMediaID: .init("copy"))
        #expect(try JSONDecoder().decode(V2ResourceImportRequest.self, from: JSONEncoder().encode(request)) == request)
        #expect(throws: V2ResourceValidationError.invalidDescriptor) {
            try V2ResourceImportRequest(operationID: request.operationID, source: source,
                targetUsage: request.targetUsage, targetMediaID: source.mediaID)
        }
        let locator = V2ResourceImportLocator(home: try .room(.init("room-b")), operationID: request.operationID)
        let ready = try V2ResourceImportStatus(locator: locator, mediaID: request.targetMediaID, state: .ready, bindableUntil: expiry)
        #expect(try JSONDecoder().decode(V2ResourceImportStatus.self, from: JSONEncoder().encode(ready)) == ready)
        let malformed = try replacing(JSONEncoder().encode(ready), key: "state", value: "cancelled")
        #expect(throws: (any Error).self) { try JSONDecoder().decode(V2ResourceImportStatus.self, from: malformed) }
    }

    @Test("home derives from authenticated actor for avatars and the explicit room for attachments")
    func homeAndRequestRoundTrip() throws {
        let actor = try UserID("actor"), room = try RoomID("room")
        #expect(V2ResourceUsage.userAvatar.home(actorUserID: actor) == .account(actor))
        #expect(V2ResourceUsage.messageAttachment(room).home(actorUserID: actor) == .room(room))
        let request = try V2ResourceUploadRequest(operationID: .init("op"), mediaID: .init("media"),
            usage: .messageAttachment(room), contentType: "image/png", byteCount: 128, checksum: checksum)
        #expect(try JSONDecoder().decode(V2ResourceUploadRequest.self, from: JSONEncoder().encode(request)) == request)
        let encoded = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        #expect(!encoded.contains("https"))
        #expect(!encoded.contains("storageBinding"))
    }

    @Test("upload decoding cannot bypass size, MIME, checksum or negotiated mode validation")
    func uploadDecodeValidation() throws {
        let request = try V2ResourceUploadRequest(operationID: .init("op"), mediaID: .init("media"),
            usage: .userAvatar, contentType: "image/png", byteCount: 128, checksum: checksum)
        let data = try JSONEncoder().encode(request)
        for change: (String, Any) in [("byteCount", -1), ("contentType", "Image/PNG"), ("clientModes", ["http_get"]), ("clientModes", [])] {
            let mutated = try replacing(data, key: change.0, value: change.1)
            #expect(throws: (any Error).self) { try JSONDecoder().decode(V2ResourceUploadRequest.self, from: mutated) }
        }
        #expect(throws: V2ResourceValidationError.invalidChecksum) { try V2ResourceChecksum(value: "ETag") }
        #expect(throws: V2ResourceValidationError.invalidChecksum) { try V2ResourceChecksum(value: String(repeating: "A", count: 64)) }
    }

    @Test("transfer methods are derived and HTTPS plans reject credentialed URLs and duplicate headers")
    func transferTargetValidation() throws {
        let plan = try V2ResourceTransferPlan(mode: .httpPut, url: #require(URL(string: "https://objects.invalid/upload")),
            expiresAt: expiry, expectedByteCount: 128, checksum: checksum)
        #expect(plan.httpMethod == "PUT")
        #expect(try JSONDecoder().decode(V2ResourceTransferPlan.self, from: JSONEncoder().encode(plan)) == plan)
        for url in ["http://objects.invalid/object", "https://user:password@objects.invalid/object", "https://objects.invalid/object#fragment"] {
            let mutated = try replacing(JSONEncoder().encode(plan), key: "url", value: url)
            #expect(throws: (any Error).self) { try JSONDecoder().decode(V2ResourceTransferPlan.self, from: mutated) }
        }
        #expect(throws: V2ResourceValidationError.invalidTransferPlan) {
            try V2ResourceTransferPlan(mode: .httpGet, url: plan.url,
                headers: [.init(name: "Digest", value: "one"), .init(name: "digest", value: "two")],
                expiresAt: expiry, expectedByteCount: 128)
        }
    }

    @Test("generic header validation denies request smuggling without a cloud-prefix allow list")
    func headerValidation() throws {
        for name in ["Host", "Cookie", "Proxy-Authorization", "Content-Length", "Transfer-Encoding", "Connection", "Range", "x-forwarded-host", "Bad\r\nHeader"] {
            #expect(throws: V2ResourceValidationError.invalidTransferHeader) {
                try V2ResourceTransferHeader(name: name, value: "value", kind: .objectCapability)
            }
        }
        #expect(throws: V2ResourceValidationError.invalidTransferHeader) {
            try V2ResourceTransferHeader(name: "Authorization", value: "token", kind: .content)
        }
        let header = try V2ResourceTransferHeader(name: "X-Independent-Signature", value: "short-object-token", kind: .objectCapability)
        #expect(header.name == "X-Independent-Signature")
        let mutated = try replacing(JSONEncoder().encode(header), key: "value", value: "one\r\nInjected: true")
        #expect(throws: (any Error).self) { try JSONDecoder().decode(V2ResourceTransferHeader.self, from: mutated) }
    }

    @Test("part and Range plans have exact lengths and cannot overflow")
    func rangesAndForms() throws {
        #expect(throws: V2ResourceValidationError.invalidByteRange) {
            try V2ResourceByteRange(lowerBound: 0, upperBound: Int64.max)
        }
        let range = try V2ResourceByteRange(lowerBound: 100, upperBound: 199)
        let url = try #require(URL(string: "https://objects.invalid/object"))
        let part = try V2ResourceTransferPlan(mode: .httpPartPut, url: url, expiresAt: expiry,
            expectedByteCount: 100, byteRange: range, partNumber: 2)
        #expect(part.byteRange?.byteCount == 100)
        #expect(throws: V2ResourceValidationError.invalidTransferPlan) {
            try V2ResourceTransferPlan(mode: .httpRangeGet, url: url, expiresAt: expiry, expectedByteCount: 101, byteRange: range)
        }
        #expect(throws: V2ResourceValidationError.invalidTransferPlan) {
            try V2ResourceTransferPlan(mode: .httpFormPost, url: url, formFields: ["file": "collision"],
                formFileField: "file", expiresAt: expiry, expectedByteCount: 100)
        }
        let form = try V2ResourceTransferPlan(mode: .httpFormPost, url: url, formFields: ["policy": "opaque"],
            formFileField: "file", expiresAt: expiry, expectedByteCount: 100)
        #expect(form.httpMethod == "POST")
    }

    @Test("ready requires a completed upload and a bind deadline; cancelled sessions cannot masquerade as ready")
    func uploadSessionStates() throws {
        let locator = V2ResourceUploadLocator(home: .account(try .init("actor")), sessionID: try .init("session"))
        let ready = try V2ResourceUploadSession(locator: locator, mediaID: .init("media"), generation: 1,
            state: .completed, resourceState: .ready, expiresAt: expiry, bindableUntil: expiry)
        #expect(try JSONDecoder().decode(V2ResourceUploadSession.self, from: JSONEncoder().encode(ready)) == ready)
        for change: (String, Any) in [("state", "cancelled"), ("generation", 0), ("bindableUntilUnixMilliseconds", NSNull())] {
            let mutated = try replacing(JSONEncoder().encode(ready), key: change.0, value: change.1)
            #expect(throws: (any Error).self) { try JSONDecoder().decode(V2ResourceUploadSession.self, from: mutated) }
        }
        #expect(throws: V2ResourceValidationError.invalidPart) {
            try V2ResourceUploadTargetsRequest(locator: locator, generation: 1, partNumbers: [1, 1])
        }
    }

    @Test("presentation leases are viewer/context scoped and cannot exceed five minutes or overflow")
    func presentationLeaseValidation() throws {
        let lease = try makeLease()
        #expect(try JSONDecoder().decode(V2PresentationAccessLease.self, from: JSONEncoder().encode(lease)) == lease)
        let mutated = try replacing(JSONEncoder().encode(lease), key: "validUntilUnixMilliseconds", value: Int64.max)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(V2PresentationAccessLease.self, from: mutated) }
        let view = try V2ProfileView(userID: .init("other"), publicIdentity: nil, avatar: nil, state: .hidden,
            revision: #require(V2ProfileRevision(rawValue: 1)), visibilityRevision: #require(V2ProfileRevision(rawValue: 1)))
        #expect(throws: V2ResourceValidationError.invalidPresentationLease) { try V2AuthorizedProfilePresentation(view: view, lease: lease) }
    }

    @Test("batch bounds preserve contexts and stale leases do not revive via a newer server clock")
    func batchValidation() throws {
        let lease = try makeLease()
        let otherContext = V2ProfileViewLookupKey(userID: lease.key.userID, context: .relationship)
        let request = try V2ProfilePresentationBatchRequest(keys: [lease.key, otherContext])
        #expect(request.keys.count == 2)
        #expect(throws: V2ResourceValidationError.invalidPresentationLease) { try V2ProfilePresentationBatchRequest(keys: [lease.key, lease.key]) }
        let view = try V2ProfileView(userID: lease.key.userID, publicIdentity: nil, avatar: nil, state: .hidden,
            revision: lease.profileRevision, visibilityRevision: lease.visibilityRevision)
        let presentation = try V2AuthorizedProfilePresentation(view: view, lease: lease)
        #expect(throws: V2ResourceValidationError.invalidPresentationLease) {
            try V2ProfilePresentationBatchResponse(serverNowUnixMilliseconds: lease.validUntilUnixMilliseconds,
                results: [.presentation(presentation, avatar: nil)])
        }
        let result = try V2ProfilePresentationBatchResponse(serverNowUnixMilliseconds: lease.observedAtUnixMilliseconds,
            results: [.presentation(presentation, avatar: nil), .retryable(otherContext)])
        #expect(try JSONDecoder().decode(V2ProfilePresentationBatchResponse.self, from: JSONEncoder().encode(result)) == result)
    }

    private func makeLease() throws -> V2PresentationAccessLease {
        try .init(actorUserID: .init("viewer"), deviceID: .init("device"),
            key: .init(userID: .init("author"), context: .room(.init("room"))),
            profileRevision: #require(V2ProfileRevision(rawValue: 1)), visibilityRevision: #require(V2ProfileRevision(rawValue: 1)),
            contextRevision: 3, observedAt: expiry, validUntil: expiry.addingTimeInterval(300))
    }

    private func replacing(_ data: Data, key: String, value: Any) throws -> Data {
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object[key] = value
        return try JSONSerialization.data(withJSONObject: object)
    }
}
