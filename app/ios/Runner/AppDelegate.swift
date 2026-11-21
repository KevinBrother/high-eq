import Flutter
import UIKit
#if canImport(WechatOpenSDK)
import WechatOpenSDK
#endif

@main
@objc class AppDelegate: FlutterAppDelegate {
  private let commerce = MobileCommerce()
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
    commerce.window = window
    if let registrar = registrar(forPlugin: "MobileCommerce") {
      FlutterMethodChannel(name: "cn.higheq/mobile-commerce", binaryMessenger: registrar.messenger()).setMethodCallHandler(commerce.handle)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
