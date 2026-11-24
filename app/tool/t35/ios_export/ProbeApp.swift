import UIKit

@main
final class ProbeAppDelegate: UIResponder, UIApplicationDelegate {}

final class ProbeSceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?

  func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
    guard let scene = scene as? UIWindowScene else { return }
    let window = UIWindow(windowScene: scene)
    let environment = ProcessInfo.processInfo.environment
    if let id = environment["T35_LOCAL_FILES_ID"].flatMap(UUID.init(uuidString:)) {
      window.rootViewController = LocalFilesProbe(id: id, readback: environment["T35_LOCAL_FILES_READBACK"] == "1")
    } else {
      window.rootViewController = ProbeViewController()
    }
    self.window = window
    window.makeKeyAndVisible()
  }
}

private final class ProbeViewController: UIViewController {
  private static let zipMIMEType = "application/zip"
  private let export = PrivacyExportShare()
  private let status = UILabel()
  private var presentationAttempts = 0
  private var visibleSheets = 0

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    status.accessibilityIdentifier = "probe-result"
    status.numberOfLines = 0
    status.text = "ready"

    let controls = UIStackView(arrangedSubviews: [
      makeButton("Share temporary ZIP", "share-tmp", #selector(shareTemporary)),
      makeButton("Share caches ZIP", "share-caches", #selector(shareCaches)),
      makeButton("Check rejected paths", "check-rejections", #selector(checkRejections)),
      status,
    ])
    controls.axis = .vertical
    controls.spacing = 20
    controls.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(controls)
    NSLayoutConstraint.activate([
      controls.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
      controls.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
      controls.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
    ])
  }

  override func present(_ controller: UIViewController, animated: Bool, completion: (() -> Void)? = nil) {
    presentationAttempts += 1
    super.present(controller, animated: animated) {
      if controller is UIActivityViewController,
         self.presentedViewController === controller,
         controller.viewIfLoaded?.window != nil {
        self.visibleSheets += 1
      }
      completion?()
    }
  }

  private func makeButton(_ title: String, _ identifier: String, _ action: Selector) -> UIButton {
    let button = UIButton(type: .system)
    button.setTitle(title, for: .normal)
    button.accessibilityIdentifier = identifier
    button.addTarget(self, action: action, for: .touchUpInside)
    return button
  }

  @objc private func shareTemporary() { share(useCaches: false) }
  @objc private func shareCaches() { share(useCaches: true) }

  private func share(useCaches: Bool) {
    withFixture { fixture in
      let expected = useCaches ? fixture.cachesZIP : fixture.temporaryZIP
      let source = PrivacyExportFiles.appStorage.validatedSource(
        path: expected.path, mimeType: Self.zipMIMEType
      )
      guard let source, source.isFileURL,
            source.path == expected.standardizedFileURL.resolvingSymlinksInPath().path,
            try Data(contentsOf: source) == ExportFixture.zip else {
        status.text = "invalid staged URL"
        return
      }

      var receipts: [String] = []
      var presentationReports: [String] = []
      func report() {
        self.status.text = "URL=file ZIP | receipt=\(receipts.joined(separator: ","))"
          + " | attempts=\(self.presentationAttempts) | visible=\(self.visibleSheets)"
          + " | presentation=\(presentationReports.joined(separator: ","))"
          + " | files=\(fixture.isIntact ? "unchanged" : "changed")"
      }
      export.present(path: expected.path, mimeType: Self.zipMIMEType, from: view.window, onPresented: {
        presentationReports.append(receipts.isEmpty && self.visibleSheets == 1 ? "shown" : "out-of-order")
        if !receipts.isEmpty { report() }
      }) { outcome in
        receipts.append(outcome.rawValue)
        report()
      }
    }
  }

  @objc private func checkRejections() {
    withFixture { fixture in
      var receipts: [String: [String]] = [:]
      var presentationReports = 0
      func report() {
        let paths = fixture.rejected.map { label, _ in
          "\(label)=\(receipts[label, default: []].joined(separator: ","))"
        }.joined(separator: " | ")
        status.text = paths + " | attempts=\(presentationAttempts) | visible=\(visibleSheets)"
          + " | presentation=\(presentationReports)"
          + " | files=\(fixture.isIntact ? "unchanged" : "changed")"
      }
      for (label, path) in fixture.rejected {
        export.present(path: path.path, mimeType: Self.zipMIMEType, from: view.window, onPresented: {
          presentationReports += 1
          report()
        }) { outcome in
          receipts[label, default: []].append(outcome.rawValue)
          report()
        }
      }
      report()
    }
  }

  private func withFixture(_ work: (ExportFixture) throws -> Void) {
    view.subviews.compactMap { $0 as? UIStackView }.first?.arrangedSubviews
      .compactMap { $0 as? UIButton }.forEach { $0.isEnabled = false }
    do {
      let fixture = try ExportFixture()
      status.text = "waiting for system"
      try work(fixture)
    } catch {
      status.text = "FAIL(probe.fixture)"
    }
  }
}
