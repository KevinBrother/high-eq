import Foundation

/// Resolves the app's system temp/cache aliases, then checks each private
/// staging component without trusting a symbolic link at or below the root.
struct PrivacyExportFiles {
  private static let directoryName = "high-eq-privacy-exports"
  private let manager = FileManager.default
  private let bases: Set<URL>

  init(bases: [URL]) {
    self.bases = Set(bases.map { $0.standardizedFileURL.resolvingSymlinksInPath() })
  }

  static var appStorage: Self {
    let manager = FileManager.default
    return Self(bases: [manager.temporaryDirectory] +
      manager.urls(for: .cachesDirectory, in: .userDomainMask))
  }

  /// A missing root is expected before the first export. The account-bound
  /// Dart store owns file reclamation and checks the persisted owner record.
  var invalidRootCount: Int {
    bases.filter { base in
      let root = base.appendingPathComponent(Self.directoryName, isDirectory: true)
      if (try? manager.destinationOfSymbolicLink(atPath: root.path)) != nil {
        return true
      }
      var isDirectory: ObjCBool = false
      return manager.fileExists(atPath: root.path, isDirectory: &isDirectory) &&
        !isDirectory.boolValue
    }.count
  }

  func validatedSource(path: String, mimeType: String) -> URL? {
    guard path.hasPrefix("/"), mimeType == "application/zip" else { return nil }
    let input = URL(fileURLWithPath: path).standardizedFileURL
    let inputNamespace = input.deletingLastPathComponent()
    let inputRoot = inputNamespace.deletingLastPathComponent()
    let base = inputRoot.deletingLastPathComponent().resolvingSymlinksInPath()
    guard bases.contains(where: { $0.path == base.path }),
          inputRoot.lastPathComponent == Self.directoryName,
          inputNamespace.lastPathComponent.range(
            of: #"^v1_[A-Za-z0-9_-]{43}$"#, options: .regularExpression
          ) != nil,
          input.lastPathComponent.range(
            of: #"^high-eq-export-[0-9]+(?:-[0-9]+)?\.zip$"#, options: .regularExpression
          ) != nil else { return nil }

    let root = base.appendingPathComponent(Self.directoryName, isDirectory: true)
    let namespace = root.appendingPathComponent(inputNamespace.lastPathComponent, isDirectory: true)
    let source = namespace.appendingPathComponent(input.lastPathComponent)
    let directoryKeys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
    let rootValues = try? root.resourceValues(forKeys: directoryKeys)
    let namespaceValues = try? namespace.resourceValues(forKeys: directoryKeys)
    let sourceValues = try? source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard rootValues?.isDirectory == true, rootValues?.isSymbolicLink == false,
          namespaceValues?.isDirectory == true, namespaceValues?.isSymbolicLink == false,
          sourceValues?.isRegularFile == true, sourceValues?.isSymbolicLink == false
    else { return nil }
    return source
  }
}
