import Foundation
#if canImport(Security)
import Security
#else
import Crypto
#endif

public enum V2SecureRandom {
    public enum Failure: Error { case unavailable }
    public static func recoveryCodeBytes() throws -> Data {
        #if canImport(Security)
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw Failure.unavailable }
        return Data(bytes)
        #else
        return SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        #endif
    }
}
