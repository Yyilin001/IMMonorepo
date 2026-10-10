import Foundation
import IMV2Core
import IMV2ServerContracts
import IMV2ServerApplication
@testable import IMV2ServerInfrastructure

/// 基于真实但无害的 EICAR 测试签名的本地扫描器。
///
/// 它可以在没有第三方守护进程的情况下演练扫描通过与被拒两种状态跃迁，
/// 但它不提供恶意软件防护，绝不能在生产部署中被选用。
public struct V2LocalEICARMediaScanner: V2MediaScanProvider, Sendable {
    private let provider: V2LocalFilesystemMediaProvider

    /// 组合本地媒体提供方。
    ///
    /// - Parameter provider: 读取待扫描字节的本地提供方。
    public init(provider: V2LocalFilesystemMediaProvider) { self.provider = provider }

    /// 扫描指定媒体是否包含 EICAR 测试签名。
    ///
    /// - Parameter mediaID: 目标媒体标识。
    /// - Returns: 含签名时判定不通过，否则判定通过。
    /// - Throws: 读取本地字节失败时抛出。
    public func scan(mediaID: MediaID) async throws -> V2MediaScanResult {
        let bytes = try await provider.localBytesForScanning(mediaID: mediaID)
        return bytes.range(of: Self.eicarTestSignature) == nil ? .passed : .failed
    }

    private static let eicarTestSignature = Data(
        "X5O!P%@AP[4\\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*".utf8
    )
}
