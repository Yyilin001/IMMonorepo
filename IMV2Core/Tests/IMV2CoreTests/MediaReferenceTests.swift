import Foundation
import IMV2Core
import Testing

@Suite("V2 media reference state machine")
struct MediaReferenceTests {
    @Test("upload intent validates opaque metadata without accepting a URL")
    func uploadIntentValidation() throws {
        let checksum = try V2ResourceChecksum(value: String(repeating: "a", count: 64))
        let command = try V2ResourceUploadRequest(operationID: .init("operation"), mediaID: .init("media"), usage: .userAvatar,
            contentType: "image/png", byteCount: 128, checksum: checksum)
        #expect(command.contentType == "image/png")
        #expect(throws: V2ResourceValidationError.invalidUploadRequest) {
            _ = try V2ResourceUploadRequest(operationID: .init("operation"), mediaID: .init("media"), usage: .userAvatar,
                contentType: "Image/PNG", byteCount: 128, checksum: checksum)
        }
    }

    @Test("media becomes referenceable only after a successful scan")
    func scanningLifecycle() throws {
        let expiresAt = Date(timeIntervalSince1970: 100)
        let pending = V2MediaObject(mediaID: try .init("media"), ownerUserID: try .init("owner"), contentType: "image/png", byteCount: 10, expiresAt: expiresAt)
        let scanning = try V2MediaLifecycle.transition(pending, event: .uploadCompleted, now: Date(timeIntervalSince1970: 1))
        let available = try V2MediaLifecycle.transition(scanning, event: .scanPassed, now: Date(timeIntervalSince1970: 2))
        #expect(available.state == .available)
        #expect(throws: V2MediaValidationError.invalidStateTransition) {
            _ = try V2MediaLifecycle.transition(available, event: .scanPassed, now: Date(timeIntervalSince1970: 3))
        }
    }

    @Test("an attachment-only message retains its opaque references")
    func attachmentOnlyMessage() throws {
        let media = V2MediaReference(mediaID: try .init("media"))
        let command = try V2SendMessageCommand(roomID: .init("room"), senderUserID: .init("sender"), clientMessageID: .init("client"), text: "", media: [media], limits: .init(maxUTF8Bytes: 64))
        #expect(command.text.isEmpty)
        #expect(command.media == [media])
    }

    @Test("presentation facts classify scanned media without carrying a URL")
    func mediaPresentationClassification() throws {
        let mediaID = try MediaID("media")
        let image = try V2MediaPresentation(mediaID: mediaID, kind: V2MediaPresentation.kind(forContentType: "image/png"), contentType: "image/png", byteCount: 128)
        #expect(image.kind == .image)
        #expect(V2MediaPresentation.kind(forContentType: "image/gif") == .animatedImage)
        #expect(V2MediaPresentation.kind(forContentType: "video/mp4") == .video)
        #expect(V2MediaPresentation.kind(forContentType: "audio/ogg") == .audio)
        #expect(V2MediaPresentation.kind(forContentType: "application/pdf") == .file)
        #expect(throws: V2MediaValidationError.invalidPresentation) {
            _ = try V2MediaPresentation(mediaID: mediaID, kind: .image, contentType: "Image/PNG", byteCount: 128)
        }
    }

    @Test("download envelopes encode only a validated plan")
    func downloadTargetEnvelope() throws {
        let plan = try V2ResourceTransferPlan(mode: .httpGet,
            url: #require(URL(string: "https://media.invalid/object")),
            headers: [.init(name: "X-Object-Ticket", value: "opaque")],
            expiresAt: Date(timeIntervalSince1970: 1_750_000_000.123), expectedByteCount: 12,
            checksum: .init(value: String(repeating: "a", count: 64)))
        let envelope = try V2MediaDownloadTargetEnvelope(plan: plan)
        let bytes = try JSONEncoder().encode(envelope)
        let json = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(Set(json.keys) == ["plan"])
        #expect(envelope.plan == plan)
        #expect(envelope.plan.expiresAtUnixMilliseconds == 1_750_000_000_123)
        #expect(try JSONDecoder().decode(V2MediaDownloadTargetEnvelope.self, from: bytes) == envelope)
    }

    @Test("download envelopes reject incomplete and wrong-purpose wire plans", arguments: ["missing-plan", "upload", "missing-checksum", "missing-length"])
    func rejectsInvalidDownloadEnvelope(scenario: String) throws {
        let plan = try V2ResourceTransferPlan(mode: .httpGet,
            url: #require(URL(string: "https://media.invalid/object")), expiresAt: .now,
            expectedByteCount: 12, checksum: .init(value: String(repeating: "a", count: 64)))
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any])
        switch scenario {
        case "upload": json["mode"] = "http_put"
        case "missing-checksum": json.removeValue(forKey: "checksum")
        case "missing-length": json.removeValue(forKey: "expectedByteCount")
        default: break
        }
        // A URL-only response cannot silently bypass the resource contract.
        let wire: [String: Any] = scenario == "missing-plan" ? ["url": plan.url.absoluteString] : ["plan": json]
        let bytes = try JSONSerialization.data(withJSONObject: wire)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(V2MediaDownloadTargetEnvelope.self, from: bytes) }
    }

}
