import Foundation
@testable import IMV2Core
import Testing

@Suite("Media target timestamp bounds")
struct MediaTimestampBoundsTests {
    @Test("unrepresentable provider expiry throws instead of trapping", arguments: [
        Double(Int64.max) / 1_000, Double(Int64.min).nextDown / 1_000,
        Double.infinity, -Double.infinity, Double.nan
    ], [false, true])
    func rejectsUnrepresentableExpiry(seconds: Double, upload: Bool) throws {
        let expiry = Date(timeIntervalSince1970: seconds)
        let url = try #require(URL(string: "https://media.example.test/object"))
        if upload {
            #expect(throws: V2MediaValidationError.invalidUploadTarget) {
                try V2MediaUploadTargetEnvelope(url: url, expiresAt: expiry)
            }
        } else {
            #expect(throws: V2MediaValidationError.invalidDownloadTarget) {
                try V2MediaDownloadTargetEnvelope(url: url, expiresAt: expiry)
            }
        }
    }

    @Test("valid expiry retains floor rounding and numeric wire values", arguments: [
        (1_750_000_000.1239, Int64(1_750_000_000_123)),
        (-0.5001, Int64(-501)), (0.0, Int64(0)),
        (9_000_000_000_000_000.0, Int64(9_000_000_000_000_000_000)),
        (-9_000_000_000_000_000.0, Int64(-9_000_000_000_000_000_000))
    ])
    func preservesExpiry(sample: (Double, Int64)) throws {
        let url = try #require(URL(string: "https://media.example.test/object"))
        let expiry = Date(timeIntervalSince1970: sample.0)
        let download = try V2MediaDownloadTargetEnvelope(url: url, expiresAt: expiry)
        let upload = try V2MediaUploadTargetEnvelope(url: url, expiresAt: expiry)
        #expect(download.expiresAtUnixMilliseconds == sample.1)
        #expect(upload.expiresAtUnixMilliseconds == sample.1)
        #expect(try JSONDecoder().decode(V2MediaDownloadTargetEnvelope.self, from: JSONEncoder().encode(download)) == download)
        #expect(try JSONDecoder().decode(V2MediaUploadTargetEnvelope.self, from: JSONEncoder().encode(upload)) == upload)
    }
}
