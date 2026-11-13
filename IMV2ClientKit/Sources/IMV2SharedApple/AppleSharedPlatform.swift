import Foundation
import IMV2ClientRuntime
import IMV2ClientApple
import IMV2SharedRuntime
#if canImport(Security)
import Security
import Darwin

extension SharedPlatform {
    package static func apple() -> Self {
        #if os(macOS)
        let name = "macOS"
        #else
        let name = "iOS"
        #endif
        return .init(credentials: { V2KeychainCredentialStore(service: "im.shared.sdk." + $0) },
                     installationBinding: { V2KeychainInstallationBindingStore(service: "im.shared.sdk." + $0) },
                     securePersistence: { AppleSharedSecurePersistence(name: $0) },
                     http: V2URLSessionAuthHTTPTransport(), imageHTTP: AppleSharedImageHTTP(),
                     uploader: V2URLSessionResourcePlanExecutor(), rangeTransport: V2URLSessionRangeDownloadTransport(),
                     tlsConnection: { V2NetworkTLSByteConnection(endpoint: $0) },
                     registrationMetadata: .init(deviceName: name, platform: name + " shared Swift"),
                     createStagingFile: { url in
                         let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                         guard descriptor >= 0 else { throw SharedFailure.storageUnavailable }
                         return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                     },
                     isAbsolutePath: { $0.hasPrefix("/") && !$0.utf8.contains(0) })
    }
}

private struct AppleSharedImageHTTP: V2AuthHTTPTransport {
    private let executor = V2HTTPExecutor(session: V2SecureURLSession.mediaProvider)
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await executor.execute(request, budget: .init(timeout: min(15, max(0.001, request.timeoutInterval)), maximumResponseBytes: 2_097_152), service: "mediaProvider")
    }
}

/// New shared desktop namespace; existing iOS Keychain records and constructors are untouched.
private struct AppleSharedSecurePersistence: SharedSecurePersistence {
    let name: String
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "im.shared.sdk.opaque",
         kSecAttrAccount as String: name, kSecAttrSynchronizable as String: false]
    }
    func load() throws -> Data? {
        var query = query; query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = value as? Data else { throw V2CredentialStoreError.malformedRecord }
        return data
    }
    func save(_ data: Data) throws {
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var record = query; attributes.forEach { record[$0.key] = $0.value }
            let added = SecItemAdd(record as CFDictionary, nil)
            if added == errSecDuplicateItem { try check(SecItemUpdate(query as CFDictionary, attributes as CFDictionary)) }
            else { try check(added) }
        } else { try check(status) }
    }
    func delete() throws { let status = SecItemDelete(query as CFDictionary); if status != errSecItemNotFound { try check(status) } }
    private func check(_ status: OSStatus) throws { guard status == errSecSuccess else { throw V2CredentialStoreError.unavailable } }
}
#endif
