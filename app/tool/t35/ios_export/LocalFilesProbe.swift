import CryptoKit
import UIKit
import UniformTypeIdentifiers

final class LocalFilesProbe: UIViewController, UIDocumentPickerDelegate {
  private let manager = FileManager.default
  private let export = PrivacyExportShare()
  private let status = UILabel()
  private let source: URL
  private let readback: Bool
  private var receipts: [String] = []

  init(id: UUID, readback: Bool) {
    let compactID = id.uuidString.replacingOccurrences(of: "-", with: "")
    let serial = UInt64(compactID.prefix(16), radix: 16)!
    source = FileManager.default.temporaryDirectory
      .appendingPathComponent("high-eq-privacy-exports", isDirectory: true)
      .appendingPathComponent("v1_" + compactID + String(repeating: "f", count: 11), isDirectory: true)
      .appendingPathComponent("high-eq-export-\(serial).zip")
    self.readback = readback
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("Programmatic probe") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground

    let filename = UILabel()
    filename.text = source.lastPathComponent
    filename.accessibilityIdentifier = "local-files-filename"
    filename.numberOfLines = 0
    status.accessibilityIdentifier = "probe-result"
    status.accessibilityValue = "picker=idle"
    status.numberOfLines = 0
    status.text = readback ? (sourceExists ? "source=present" : "source=absent") : "ready"

    let action = UIButton(type: .system)
    action.setTitle(readback ? "Read ZIP from Files" : "Share ZIP to Files", for: .normal)
    action.accessibilityIdentifier = readback ? "local-files-read" : "local-files-share"
    action.addTarget(self, action: readback ? #selector(readZIP) : #selector(stageAndShare), for: .touchUpInside)

    let controls = UIStackView(arrangedSubviews: readback ? [action, status] : [filename, action, status])
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

  private var sourceExists: Bool { manager.fileExists(atPath: source.path) }

  @objc private func stageAndShare(_ button: UIButton) {
    button.isEnabled = false
    do {
      try manager.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
      try ExportFixture.zip.write(to: source, options: .withoutOverwriting)
      guard try Data(contentsOf: source) == ExportFixture.zip else {
        status.text = "FAIL(files.stage-bytes)"
        return
      }
      status.text = "waiting for system"
      export.present(path: source.path, mimeType: "application/zip", from: view.window, onPresented: {
        self.status.text = self.receipts.isEmpty ? "system sheet presented" : "FAIL(files.share-presentation)"
      }) { outcome in
        self.record(outcome)
      }
    } catch {
      status.text = "FAIL(files.stage)"
    }
  }

  private func record(_ outcome: PrivacyExportShare.Outcome) {
    receipts.append(outcome.rawValue)
    let receipt = "receipt=\(receipts.joined(separator: ","))"
    status.text = receipt
    guard receipts.count == 1, case .completed = outcome else { return }

    do {
      guard try Data(contentsOf: source) == ExportFixture.zip else {
        status.text = receipt + " | FAIL(files.source-at-completion)"
        return
      }
      // The Flutter caller cleans up after the native callback. The probe owns
      // this synthetic file and removes it at the same boundary.
      try manager.removeItem(at: source)
      status.text = receipt + (sourceExists ? " | FAIL(files.source-cleanup)" : " | source=verified then removed")
    } catch {
      status.text = receipt + " | FAIL(files.source-cleanup)"
    }
  }

  @objc private func readZIP(_ button: UIButton) {
    button.isEnabled = false
    guard !sourceExists else {
      status.accessibilityValue = "picker=not-opened"
      status.text = "FAIL(files.source-before-read)"
      return
    }
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.zip], asCopy: false)
    picker.delegate = self
    status.accessibilityValue = "picker=presenting"
    present(picker, animated: true) {
      self.status.accessibilityValue = "picker=presented"
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    status.accessibilityValue = "picker=cancelled"
    status.text = "FAIL(files.read-cancelled)"
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    status.accessibilityValue = "picker=returned"
    guard urls.count == 1, let picked = urls.first, picked.isFileURL,
          picked.lastPathComponent == source.lastPathComponent else {
      status.text = "FAIL(files.read-filename)"
      return
    }
    guard !sourceExists else {
      status.text = "FAIL(files.source-before-read)"
      return
    }

    let hasAccess = picked.startAccessingSecurityScopedResource()
    defer { if hasAccess { picked.stopAccessingSecurityScopedResource() } }
    let homePath = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
      .resolvingSymlinksInPath().path
    func isExternal(_ url: URL) -> Bool {
      let path = url.standardizedFileURL.resolvingSymlinksInPath().path
      return path != homePath && !path.hasPrefix(homePath + "/")
    }

    guard isExternal(picked) else {
      status.text = "FAIL(files.read-external)"
      return
    }
    var coordinationError: NSError?
    var bytes: Data?
    var coordinatedURLIsExternal = false
    NSFileCoordinator().coordinate(readingItemAt: picked, options: [], error: &coordinationError) { url in
      coordinatedURLIsExternal = isExternal(url)
      if coordinatedURLIsExternal { bytes = try? Data(contentsOf: url) }
    }
    guard coordinationError == nil else {
      status.text = "FAIL(files.read-coordination)"
      return
    }
    guard coordinatedURLIsExternal else {
      status.text = "FAIL(files.read-external)"
      return
    }
    guard let bytes, bytes == ExportFixture.zip else {
      status.text = "FAIL(files.read-bytes)"
      return
    }
    guard !sourceExists else {
      status.text = "FAIL(files.source-after-read)"
      return
    }
    let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    status.text = "source=absent | destination=external | bytes=\(bytes.count) | sha256=\(digest)"
  }
}
