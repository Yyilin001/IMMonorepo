import Foundation

enum HTTPFixtures {
    static let baseURL = URL(string: "https://example.com")!

    static func response(
        statusCode: Int,
        headers: [String: String] = [:],
        body: Data = Data(),
        url: URL = baseURL
    ) -> (Data, HTTPURLResponse) {
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: headers
        )!
        return (body, response)
    }

    static func jsonBody(_ object: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(object)
    }
}

struct ErrorEnvelope: Encodable {
    let reason: String
}
