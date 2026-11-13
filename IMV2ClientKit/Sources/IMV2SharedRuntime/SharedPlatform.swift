import Foundation
import IMV2ClientRuntime

/// Platform-owned opaque secure items. Shared ledger owners retain serialization and recovery.
package protocol SharedSecurePersistence: V2DeviceRevocationPersisting, V2DeviceRegistrationPersisting,
    V2IssuedCredentialRecoveryPersisting {
    func delete() throws
}

/// Only physical I/O and platform identity enter here; account and message state stay in SharedRuntime.
package struct SharedPlatform: Sendable {
    package let credentials: @Sendable (String) -> any V2CredentialStore
    package let installationBinding: @Sendable (String) -> any V2InstallationBindingStore
    package let securePersistence: @Sendable (String) -> any SharedSecurePersistence
    package let http: any V2AuthHTTPTransport
    package let imageHTTP: any V2AuthHTTPTransport
    package let uploader: any V2ResourcePlanExecuting
    package let rangeTransport: any V2RangeDownloadTransport
    package let tlsConnection: @Sendable (V2RealtimeEndpoint) -> any V2TLSByteConnection
    package let registrationMetadata: V2ClientDeviceRegistrationMetadata
    package let createStagingFile: @Sendable (URL) throws -> FileHandle
    package let isAbsolutePath: @Sendable (String) -> Bool

    package init(credentials: @escaping @Sendable (String) -> any V2CredentialStore,
                 installationBinding: @escaping @Sendable (String) -> any V2InstallationBindingStore,
                 securePersistence: @escaping @Sendable (String) -> any SharedSecurePersistence,
                 http: any V2AuthHTTPTransport, imageHTTP: any V2AuthHTTPTransport,
                 uploader: any V2ResourcePlanExecuting, rangeTransport: any V2RangeDownloadTransport,
                 tlsConnection: @escaping @Sendable (V2RealtimeEndpoint) -> any V2TLSByteConnection,
                 registrationMetadata: V2ClientDeviceRegistrationMetadata,
                 createStagingFile: @escaping @Sendable (URL) throws -> FileHandle,
                 isAbsolutePath: @escaping @Sendable (String) -> Bool) {
        self.credentials = credentials; self.installationBinding = installationBinding
        self.securePersistence = securePersistence; self.http = http; self.imageHTTP = imageHTTP
        self.uploader = uploader; self.rangeTransport = rangeTransport; self.tlsConnection = tlsConnection
        self.createStagingFile = createStagingFile
        self.registrationMetadata = registrationMetadata; self.isAbsolutePath = isAbsolutePath
    }
}

struct SharedExitIntent: V2SharedExitIntentStoring {
    let persistence: any SharedSecurePersistence
    func isPending() async throws -> Bool { try persistence.load() != nil }
    func markPending() async throws { try persistence.save(Data([1])) }
    func clearPending() async throws { try persistence.delete() }
}
