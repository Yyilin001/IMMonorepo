import Flutter
import UIKit

final class PushTokenBridge {
  static let shared = PushTokenBridge()
  private var result: FlutterResult?
  var token: String?

  func request(_ result: @escaping FlutterResult) {
    if let token {
      result(token)
      return
    }
    self.result = result
    UIApplication.shared.registerForRemoteNotifications()
  }

  func receive(_ token: String) {
    self.token = token
    result?(token)
    result = nil
  }

  func fail() {
    result?(FlutterError(code: "pushUnavailable", message: "此设备暂无法获取推送令牌", details: nil))
    result = nil
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var pushChannel: FlutterMethodChannel?
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "LocalImPush") else { return }
    let channel = FlutterMethodChannel(name: "local_im/push", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "requestToken": PushTokenBridge.shared.request(result)
      case "cachedToken": result(PushTokenBridge.shared.token)
      default: result(FlutterMethodNotImplemented)
      }
    }
    pushChannel = channel
  }

  override func application(_ application: UIApplication,
      didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    let token = deviceToken.map { String(format: "%02x", $0) }.joined()
    PushTokenBridge.shared.receive(token)
    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
  }

  override func application(_ application: UIApplication,
      didFailToRegisterForRemoteNotificationsWithError error: Error) {
    PushTokenBridge.shared.fail()
    super.application(application, didFailToRegisterForRemoteNotificationsWithError: error)
  }
}
