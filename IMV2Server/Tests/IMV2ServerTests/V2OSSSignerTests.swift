import Foundation
import Testing
import IMV2ServerApplication
@testable import IMV2ServerInfrastructure

struct V2OSSSignerTests {
    private let query = ["param1": "value1", "+param1": "value3", "|param1": "value4",
                         "+param2": "", "|param2": "", "param2": ""]
    private func signer(token: String? = nil) -> V2OSSSigner {
        .init(region: "cn-hangzhou", bucket: "bucket",
              credentials: .init(accessKeyID: "ak", accessKeySecret: "sk", securityToken: token))
    }
    // Fixed independent vectors from aliyun/alibabacloud-oss-swift-sdk-v2,
    // Tests/OSSUnitTests/Signer/SignerV4Tests.swift (Apache-2.0).
    @Test func officialHeaderVectors() throws {
        let headers = ["x-oss-head1": "value", "abc": "value", "ZAbc": "value",
                       "XYZ": "value", "content-type": "text/plain"]
        let cases: [(String?, Double, Set<String>, String)] = [
            (nil, 1_702_743_657, [], "e21d18daa82167720f9b1047ae7e7f1ce7cb77a31e8203a7d5f4624fa0284afe"),
            ("token", 1_702_784_856, [], "b94a3f999cf85bcdc00d332fbd3734ba03e48382c36fa4d5af5df817395bd9ea"),
            (nil, 1_702_747_512, ["ZAbc", "abc"], "4a4183c187c07c8947db7620deb0a6b38d9fbdd34187b6dbaccb316fa251212f")
        ]
        for (token, time, additional, expected) in cases {
            let signed = try signer(token: token).authorization(method: "PUT", key: "1234+-/123/1.txt",
                query: query, headers: headers, additionalHeaders: additional, now: Date(timeIntervalSince1970: time))
            #expect(signed["authorization"]?.hasSuffix("Signature=" + expected) == true)
            #expect(signed["x-oss-security-token"] == token)
        }
    }

    @Test func officialURLVector() throws {
        let url = try signer().presignedURL(endpoint: #require(URL(string: "https://bucket.oss-cn-hangzhou.aliyuncs.com")),
            method: "PUT", key: "1234+-/123/1.txt", query: query,
            headers: ["x-oss-head1": "value", "abc": "value", "ZAbc": "value", "XYZ": "value", "content-type": "application/octet-stream"],
            now: Date(timeIntervalSince1970: 1_702_781_677), expiresAt: Date(timeIntervalSince1970: 1_702_782_276))
        #expect(url.absoluteString.contains("x-oss-signature=a39966c61718be0d5b14e668088b3fa07601033f6518ac7b523100014269c0fe"))
        #expect(url.absoluteString.contains("/1234%2B-/123/1.txt?"))
    }

    @Test func rejectsAmbiguousHeadersAndExpiredCapabilities() throws {
        let now = Date()
        #expect(throws: V2ResourceProviderError.configurationInvalid) {
            _ = try signer().authorization(method: "GET", key: "object", headers: ["Content-Type": "a", "content-type": "b"], now: now)
        }
        #expect(throws: V2ResourceProviderError.configurationInvalid) {
            _ = try signer().authorization(method: "GET", key: "object", headers: ["x-oss-meta-test": "a\r\nb"], now: now)
        }
        #expect(throws: V2ResourceProviderError.configurationInvalid) {
            _ = try signer().presignedURL(endpoint: URL(string: "https://bucket.oss-cn-hangzhou.aliyuncs.com")!,
                method: "GET", key: "object", now: now, expiresAt: now)
        }
    }

    @Test func signingCannotExtendFractionalDeadline() throws {
        let start = Date(timeIntervalSince1970: 1_702_781_677.75)
        let end = start.addingTimeInterval(120)
        let url = try signer().presignedURL(endpoint: #require(URL(string: "https://bucket.oss-cn-hangzhou.aliyuncs.com")),
            method: "GET", key: "中文 /+?%", now: start, expiresAt: end)
        #expect(url.absoluteString.contains("x-oss-expires=120"))
        #expect(url.absoluteString.contains("%E4%B8%AD%E6%96%87%20/%2B%3F%25"))
    }
}
