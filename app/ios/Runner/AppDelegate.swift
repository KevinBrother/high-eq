import Flutter
import UIKit
#if canImport(WechatOpenSDK)
import WechatOpenSDK
#endif

@main
@objc class AppDelegate: FlutterAppDelegate {
  private let healthHistory = HealthHistory()
  private let commerce = MobileCommerce()
  private let voiceCapture = VoiceCapture()
  #if canImport(WechatOpenSDK)
  override func application(_ application: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
    WXApi.handleOpen(url, delegate: commerce) || super.application(application, open: url, options: options)
  }
  override func application(_ application: UIApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
    WXApi.handleOpenUniversalLink(userActivity, delegate: commerce) || super.application(application, continue: userActivity, restorationHandler: restorationHandler)
  }
  #endif
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let registrar = registrar(forPlugin: "ReplyShare") {
      FlutterMethodChannel(name: "cn.higheq/reply-share", binaryMessenger: registrar.messenger()).setMethodCallHandler { call, result in
        if call.method == "take" { result(ReplyInbox.take()) } else { result(FlutterMethodNotImplemented) }
      }
    }
    if let registrar = registrar(forPlugin: "HealthHistory") {
      FlutterMethodChannel(name: "cn.higheq/health-history", binaryMessenger: registrar.messenger()).setMethodCallHandler(healthHistory.handle)
    }
    if let registrar = registrar(forPlugin: "MobileCommerce") {
      let channel = FlutterMethodChannel(name: "cn.higheq/mobile-commerce", binaryMessenger: registrar.messenger())
      commerce.onExportPresented = { requestId in
        channel.invokeMethod("shareExportPresented", arguments: requestId)
      }
      channel.setMethodCallHandler { [weak self] call, result in
        guard let self else { result(FlutterMethodNotImplemented); return }
        self.commerce.window = self.window
        self.commerce.handle(call, result: result)
      }
    }
    if let registrar = registrar(forPlugin: "VoiceCapture") {
      voiceCapture.install(messenger: registrar.messenger())
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
