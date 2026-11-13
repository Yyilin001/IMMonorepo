import Foundation
#if canImport(Android)
import Android
#elseif canImport(Darwin)
import Darwin
#endif
import IMV2ClientRuntime
import IMV2ClientAndroid
import IMV2SharedRuntime

extension V2AndroidSecurePersistence: SharedSecurePersistence {}

extension SharedPlatform {
    package static func android() -> Self {
        .init(credentials: { V2AndroidCredentialStore(name: $0) },
              installationBinding: { V2AndroidInstallationBindingStore(name: $0) },
              securePersistence: { V2AndroidSecurePersistence(name: $0) },
              http: V2AndroidAuthHTTPTransport(), imageHTTP: V2AndroidAuthHTTPTransport(),
              uploader: SharedResourceUpload(), rangeTransport: SharedResourceRangeTransport(),
              tlsConnection: { V2AndroidTLSByteConnection(endpoint: $0) },
              registrationMetadata: .init(deviceName: "Android", platform: "Android shared Swift"),
              createStagingFile: { url in
                  #if canImport(Android)
                  let descriptor = Android.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                  #elseif canImport(Darwin)
                  let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                  #else
                  let descriptor: Int32 = -1
                  #endif
                  guard descriptor >= 0 else { throw SharedFailure.storageUnavailable }
                  return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
              },
              isAbsolutePath: { $0.hasPrefix("/") && !$0.utf8.contains(0) })
    }
}
