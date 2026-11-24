import AuthenticationServices
import Flutter
import StoreKit
import UIKit
#if canImport(WechatOpenSDK)
import WechatOpenSDK
#endif

/// No SDK is asked for authorization until the corresponding user gesture.
final class MobileCommerce: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
  weak var window: UIWindow?
  var onExportPresented: ((Int) -> Void)?
  private let privacyExport = PrivacyExportShare()
  private var authorizing: FlutterResult?
  private var appleController: ASAuthorizationController?
  private var pending: [String: StoreKit.Transaction] = [:]
  private var nonce: String?
  private func configured(_ name: String) -> String? {
    guard let v = Bundle.main.object(forInfoDictionaryKey: name) as? String,
          !v.isEmpty, !v.contains("$(") else { return nil }; return v
  }
  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String:Any] ?? [:]
    let unavailable = FlutterError(code: "unavailable", message: nil, details: nil)
    switch call.method {
    case "authorize":
      guard authorizing == nil, window != nil else { result(unavailable); return }
      let state = UUID().uuidString
      if args["provider"] as? String == "apple" {
        let req = ASAuthorizationAppleIDProvider().createRequest(); req.state = state
        let controller = ASAuthorizationController(authorizationRequests: [req]); controller.delegate = self
        controller.presentationContextProvider = self; appleController = controller
        nonce = state; authorizing = result; controller.performRequests(); return
      }
      #if canImport(WechatOpenSDK)
      if args["provider"] as? String == "wechat", let appID = configured("WeChatAppID"),
         let link = configured("WeChatUniversalLink"), WXApi.registerApp(appID, universalLink: link) {
        let req = SendAuthReq(); req.scope = "snsapi_userinfo"; req.state = state
        authorizing = result; nonce = state
        WXApi.send(req) { ok in if !ok { self.resolve(nil) } }; return
      }
      #endif
      result(unavailable)
    case "cleanupStatus":
      result(privacyExport.cleanupStatus)
    case "shareExport":
      guard let requestId = args["requestId"] as? Int, requestId > 0 else {
        result(unavailable); return
      }
      privacyExport.present(
        path: args["path"] as? String,
        mimeType: args["mimeType"] as? String,
        from: window,
        onPresented: { [weak self] in self?.onExportPresented?(requestId) }
      ) { outcome in
        result(outcome == .completed
          ? nil
          : FlutterError(code: outcome.rawValue, message: nil, details: nil))
      }
    case "available": result(configured("SubscriptionMonthly") != nil && configured("SubscriptionYearly") != nil)
    case "purchase", "restore", "finish":
      Task { @MainActor in
        do {
          if call.method == "finish" {
            if let signed = args["signed"] as? String, let tx = pending.removeValue(forKey: signed) { await tx.finish() }; result(nil); return
          }
          guard let monthly = configured("SubscriptionMonthly"), let yearly = configured("SubscriptionYearly") else { result(unavailable); return }
          if call.method == "restore" {
            try await AppStore.sync()
            var found = Set<String>()
            for await entry in StoreKit.Transaction.currentEntitlements {
              if case .verified(let tx) = entry, [monthly,yearly].contains(tx.productID) {
                pending[entry.jwsRepresentation] = tx; found.insert(entry.jwsRepresentation)
              }
            }
            for await entry in StoreKit.Transaction.unfinished {
              if case .verified(let tx) = entry, [monthly,yearly].contains(tx.productID) {
                pending[entry.jwsRepresentation] = tx; found.insert(entry.jwsRepresentation)
              }
            }
            result(Array(found)); return
          }
          guard let raw = args["appAccountToken"] as? String, let token = UUID(uuidString: raw),
                let product = try await Product.products(for: [args["plan"] as? String == "yearly" ? yearly : monthly]).first, product.type == .autoRenewable else { result(unavailable); return }
          switch try await product.purchase(options: [.appAccountToken(token)]) {
          case .success(let entry):
            guard case .verified(let tx) = entry else { result(unavailable); return }
            pending[entry.jwsRepresentation] = tx; result([entry.jwsRepresentation])
          case .userCancelled: result(FlutterError(code: "cancelled", message: nil, details: nil))
          case .pending: result(FlutterError(code: "pending", message: nil, details: nil))
          @unknown default: result(unavailable)
          }
        } catch { result(FlutterError(code: "store_error", message: nil, details: nil)) }
      }
    default: result(FlutterMethodNotImplemented)
    }
  }
  func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor { window ?? UIWindow() }
  func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
    guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential, credential.state == nonce, let code = credential.authorizationCode else { resolve(nil); return }
    resolve(String(data: code, encoding: .utf8))
  }
  func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) { resolve(nil) }
  private func resolve(_ code: String?) { let callback = authorizing; authorizing = nil; appleController = nil; nonce = nil
    if let code = code, !code.isEmpty { callback?(code) } else { callback?(FlutterError(code: "cancelled", message: nil, details: nil)) }
  }
}
#if canImport(WechatOpenSDK)
extension MobileCommerce: WXApiDelegate {
  func onResp(_ resp: BaseResp) { guard let resp = resp as? SendAuthResp, resp.state == nonce else { return }; resolve(resp.errCode == 0 ? resp.code : nil) }
}
#endif
