import IMV2Core

/// 关闭当前网关上某台已吊销设备的连接。
public protocol V2DeviceConnectionRevoking: Sendable {
    func revoke(deviceID: DeviceID) async
}
