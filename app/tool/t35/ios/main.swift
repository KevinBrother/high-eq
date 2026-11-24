import Foundation

let manager = FileManager.default
let base = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
  .appendingPathComponent(UUID().uuidString, isDirectory: true)
try manager.createDirectory(at: base, withIntermediateDirectories: true)
defer { try? manager.removeItem(at: base) }

let exports = PrivacyExportFiles(bases: [base])
let root = base.appendingPathComponent("high-eq-privacy-exports", isDirectory: true)
let account = root.appendingPathComponent("v1_" + String(repeating: "A", count: 43), isDirectory: true)
let file = account.appendingPathComponent("high-eq-export-100-1.zip")
let bytes = Data([1, 2, 3])

precondition(exports.invalidRootCount == 0)
try manager.createDirectory(at: account, withIntermediateDirectories: true)
try bytes.write(to: file)
precondition(exports.validatedSource(path: file.path, mimeType: "application/zip")?.path == file.path)
precondition(exports.validatedSource(path: file.path, mimeType: "text/plain") == nil)
let part = file.appendingPathExtension("part")
try bytes.write(to: part)
precondition(exports.validatedSource(path: part.path, mimeType: "application/zip") == nil)

let outside = base.appendingPathComponent("high-eq-export-200-1.zip")
try bytes.write(to: outside)
precondition(exports.validatedSource(path: outside.path, mimeType: "application/zip") == nil)
let linkedFile = account.appendingPathComponent(outside.lastPathComponent)
try manager.createSymbolicLink(at: linkedFile, withDestinationURL: outside)
precondition(exports.validatedSource(path: linkedFile.path, mimeType: "application/zip") == nil)

let linkedAccount = root.appendingPathComponent("v1_" + String(repeating: "B", count: 43))
try manager.createSymbolicLink(at: linkedAccount, withDestinationURL: account)
precondition(exports.validatedSource(
  path: linkedAccount.appendingPathComponent(file.lastPathComponent).path,
  mimeType: "application/zip"
) == nil)
let originalRoot = base.appendingPathComponent("original")
try manager.moveItem(at: root, to: originalRoot)
try manager.createSymbolicLink(at: root, withDestinationURL: originalRoot)
precondition(exports.invalidRootCount == 1)
precondition(exports.validatedSource(path: file.path, mimeType: "application/zip") == nil)
precondition(manager.fileExists(atPath: outside.path))
precondition(manager.fileExists(atPath: originalRoot.appendingPathComponent(account.lastPathComponent)
  .appendingPathComponent(part.lastPathComponent).path))

print("iOS export staging policy passed")
