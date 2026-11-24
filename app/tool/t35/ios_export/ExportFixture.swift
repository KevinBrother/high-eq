import Foundation

struct ExportFixture {
  // A ZIP containing only fixture.txt with "T35 synthetic export\n".
  static let zip = Data(base64Encoded:
    "UEsDBBQAAAAAAAAAIQDU2NfFFQAAABUAAAALAAAAZml4dHVyZS50eHRUMzUgc3ludGhldGljIGV4cG9ydApQSwECFAMUAAAAAAAAACEA1NjXxRUAAAAVAAAACwAAAAAAAAAAAAAAgAEAAAAAZml4dHVyZS50eHRQSwUGAAAAAAEAAQA5AAAAPgAAAAAA"
  )!

  let temporaryZIP: URL
  let cachesZIP: URL
  let rejected: [(String, URL)]
  private let files: [URL: Data]
  private let links: [URL: URL]

  init() throws {
    let manager = FileManager.default
    let caches = try manager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let temporary = manager.temporaryDirectory
    let id = UUID().uuidString.replacingOccurrences(of: "-", with: "")

    func account(in parent: URL, marker: Character) -> URL {
      parent.appendingPathComponent("v1_" + id + String(repeating: String(marker), count: 11), isDirectory: true)
    }

    let staging = "high-eq-privacy-exports"
    let temporaryRoot = temporary.appendingPathComponent(staging, isDirectory: true)
    let cachesRoot = caches.appendingPathComponent(staging, isDirectory: true)
    let tmpAccount = account(in: temporaryRoot, marker: "a")
    let cachesAccount = account(in: cachesRoot, marker: "a")
    let otherAccount = account(in: temporaryRoot, marker: "b")
    let linkedAccount = account(in: temporaryRoot, marker: "c")
    let outsideAccount = account(in: temporary.appendingPathComponent(staging + "-outside"), marker: "a")

    let name = "high-eq-export-1730000000000.zip"
    temporaryZIP = tmpAccount.appendingPathComponent(name)
    cachesZIP = cachesAccount.appendingPathComponent(name)
    let outside = outsideAccount.appendingPathComponent(name)
    let nested = tmpAccount.appendingPathComponent("nested", isDirectory: true).appendingPathComponent(name)
    let fileLink = tmpAccount.appendingPathComponent("high-eq-export-1730000000001.zip")
    rejected = [
      ("outside", outside),
      ("nested", nested),
      ("file-link", fileLink),
      ("directory-link", linkedAccount.appendingPathComponent(name)),
    ]
    files = [
      temporaryZIP: Self.zip,
      cachesZIP: Self.zip,
      outside: Self.zip,
      nested: Self.zip,
      otherAccount.appendingPathComponent(name): Self.zip,
      tmpAccount.appendingPathComponent("high-eq-export-1730000000002.zip"): Self.zip,
      tmpAccount.appendingPathComponent("keep.txt"): Data("unrelated tmp".utf8),
      cachesAccount.appendingPathComponent("keep.txt"): Data("unrelated caches".utf8),
    ]
    links = [fileLink: temporaryZIP, linkedAccount: tmpAccount]

    for (file, bytes) in files {
      try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try bytes.write(to: file, options: .withoutOverwriting)
    }
    for (link, target) in links {
      try manager.createSymbolicLink(at: link, withDestinationURL: target)
    }
  }

  var isIntact: Bool {
    files.allSatisfy { file, bytes in
      let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      return values?.isRegularFile == true && values?.isSymbolicLink == false
        && (try? Data(contentsOf: file)) == bytes
    } && links.allSatisfy { link, target in
      (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == target.path
    }
  }
}
