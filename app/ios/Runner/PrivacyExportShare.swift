import UIKit

/// The system owns the destination and reports completion through its activity
/// callback. The Dart caller keeps the staged file until this callback returns.
final class PrivacyExportShare {
  enum Outcome: String {
    case completed
    case cancelled
    case unavailable
    case busy
    case cleanupFailed = "cleanup_failed"
    case ioError = "io_error"
  }

  private let files = PrivacyExportFiles.appStorage
  private var presenting = false

  var cleanupStatus: [String: Any] {
    let failed = files.invalidRootCount
    return ["state": failed == 0 ? "ok" : "failed", "removed": 0, "failed": failed]
  }

  func present(
    path: String?,
    mimeType: String?,
    from window: UIWindow?,
    onPresented: @escaping () -> Void,
    completion: @escaping (Outcome) -> Void
  ) {
    guard !presenting else { completion(.busy); return }
    guard files.invalidRootCount == 0 else { completion(.cleanupFailed); return }
    guard let path, let mimeType,
          let source = files.validatedSource(path: path, mimeType: mimeType)
    else { completion(.ioError); return }
    guard let window, let presenter = topController(window.rootViewController),
          presenter.viewIfLoaded?.window === window,
          !presenter.isBeingDismissed, !presenter.isBeingPresented
    else { completion(.unavailable); return }

    let sheet = UIActivityViewController(activityItems: [source], applicationActivities: nil)
    var awaitingReceipt = true
    sheet.completionWithItemsHandler = { [weak self] _, completed, _, error in
      guard awaitingReceipt else { return }
      awaitingReceipt = false
      self?.presenting = false
      completion(error != nil ? .ioError : (completed ? .completed : .cancelled))
    }
    if let popover = sheet.popoverPresentationController {
      popover.sourceView = presenter.view
      popover.sourceRect = presenter.view.bounds
    }
    presenting = true
    presenter.present(sheet, animated: true) { [weak sheet] in
      guard awaitingReceipt, let sheet, sheet.presentingViewController != nil,
            sheet.viewIfLoaded?.window === window else { return }
      onPresented()
    }
  }

  private func topController(_ root: UIViewController?) -> UIViewController? {
    var current = root
    while let presented = current?.presentedViewController { current = presented }
    return current
  }
}
