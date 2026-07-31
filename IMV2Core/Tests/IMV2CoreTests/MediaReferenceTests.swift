import Foundation
import IMV2Core
import Testing

@Suite("V2 media reference state machine")
struct MediaReferenceTests {
    @Test("upload intent validates opaque metadata without accepting a URL")
    func uploadIntentValidation() throws {
        let limits = try V2MediaUploadLimits(maximumBytes: 1_024)
        let command = try V2RequestMediaUploadCommand(actorUserID: .init("user"), operationID: .init("operation"), mediaID: .init("media"), contentType: "image/png", byteCount: 128, limits: limits)
        #expect(command.contentType == "image/png")
        #expect(throws: V2MediaValidationError.invalidUploadIntent) {
            _ = try V2RequestMediaUploadCommand(actorUserID: .init("user"), operationID: .init("operation"), mediaID: .init("media"), contentType: "Image/PNG", byteCount: 128, limits: limits)
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

    @Test("the media edge envelope is HTTPS-only and uses stable millisecond expiry")
    func downloadTargetEnvelope() throws {
        let expiry = Date(timeIntervalSince1970: 1_750_000_000.123)
        let envelope = try V2MediaDownloadTargetEnvelope(
            url: #require(URL(string: "https://media.invalid/object")),
            headers: ["x-provider": "opaque"],
            expiresAt: expiry,
            expectedByteCount: 12
        )

        #expect(envelope.url == "https://media.invalid/object")
        #expect(envelope.expiresAtUnixMilliseconds == 1_750_000_000_123)
        #expect(envelope.expectedByteCount == 12)
        #expect(throws: V2MediaValidationError.invalidDownloadTarget) {
            _ = try V2MediaDownloadTargetEnvelope(
                url: #require(URL(string: "http://media.invalid/object")),
                expiresAt: expiry
            )
        }
    }

    @Test("the upload edge envelope is independently HTTPS-only")
    func uploadTargetEnvelope() throws {
        let expiry = Date(timeIntervalSince1970: 1_750_000_000.123)
        let envelope = try V2MediaUploadTargetEnvelope(
            url: #require(URL(string: "https://media.invalid/upload")),
            headers: ["x-provider": "opaque"],
            expiresAt: expiry,
            expectedByteCount: 12
        )

        #expect(envelope.url == "https://media.invalid/upload")
        #expect(envelope.expiresAtUnixMilliseconds == 1_750_000_000_123)
        #expect(throws: V2MediaValidationError.invalidUploadTarget) {
            _ = try V2MediaUploadTargetEnvelope(
                url: #require(URL(string: "http://media.invalid/upload")),
                expiresAt: expiry
            )
        }
    }
}
