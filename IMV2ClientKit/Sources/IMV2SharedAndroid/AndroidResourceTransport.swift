import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IMV2Core
import IMV2ClientRuntime
import IMV2ClientAndroid
import IMV2SharedRuntime

struct SharedResourceUpload: V2ResourcePlanExecuting {
    func upload(fileURL: URL, plan: V2ResourceTransferPlan) async throws {
        guard [.httpPut, .httpPartPut].contains(plan.mode), plan.formFields.isEmpty,
              (1...33_554_432).contains(plan.expectedByteCount) else { throw SharedFailure.invalidInput }
        guard plan.expiresAt > Date() else { throw V2ClientMediaTransferError.targetExpired }
        let facts = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard (facts[.size] as? NSNumber)?.int64Value == plan.expectedByteCount else { throw SharedFailure.invalidInput }
        var request = URLRequest(url: plan.url, timeoutInterval: min(60, plan.expiresAt.timeIntervalSinceNow)); request.httpMethod = "PUT"
        for header in plan.headers { request.setValue(header.value, forHTTPHeaderField: header.name) }
        _ = try await V2AndroidStreamingHTTP().stream(request, uploadFile: fileURL, maximumBytes: 65_536, receiveResponse: {
            guard (200...299).contains($0.statusCode) else { throw V2HTTPFailure.status($0, service: "mediaProvider") }
        }, consume: { _ in })
        try Task.checkCancellation()
    }
}
struct SharedResourceRangeTransport: V2RangeDownloadTransport {
    func stream(_ request: URLRequest, maximumBytes: Int64, receiveResponse: @escaping @Sendable (HTTPURLResponse) throws -> Void,
                consume: @escaping @Sendable (Data) throws -> Void) async throws -> V2RangeDownloadResponse {
        .init(response: try await V2AndroidStreamingHTTP().stream(request, maximumBytes: maximumBytes, receiveResponse: receiveResponse, consume: consume))
    }
}
