import Foundation

/// One protected, non-backed-up handoff between the extension and its container.
/// Rename on take so a simultaneous new share cannot be removed by the old reader.
enum ReplyInbox {
    private static let claimName = "claimed"

    private static func location() throws -> URL {
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.cn.higheq.highEq.reply") else { throw CocoaError(.fileNoSuchFile) }
        let caches = root.appendingPathComponent("Library/Caches/T22", isDirectory: true)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        return caches.appendingPathComponent("incoming")
    }

    static func store(_ text: String) throws {
        try store(text, at: location())
    }

    static func store(_ text: String, at target: URL) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 65536 else { throw CocoaError(.fileWriteInapplicableStringEncoding) }
        #if os(iOS)
        let options: Data.WritingOptions = [.atomic, .completeFileProtection]
        #else
        // macOS test binaries do not grant the iOS data-protection class.
        let options: Data.WritingOptions = .atomic
        #endif
        try Data(text.utf8).write(to: target, options: options)
    }

    static func take() -> String? {
        guard let source = try? location() else { return nil }
        return take(at: source)
    }

    static func take(at source: URL) -> String? {
        // A fixed claim name makes an interrupted move discoverable on the next
        // take. New shares always use `incoming`, so they remain untouched.
        let claim = source.deletingLastPathComponent().appendingPathComponent(claimName)
        do {
            if FileManager.default.fileExists(atPath: claim.path) {
                try FileManager.default.removeItem(at: claim)
            }
            try FileManager.default.moveItem(at: source, to: claim)
            defer { try? FileManager.default.removeItem(at: claim) }
            let values = try claim.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            guard let stamp = values.contentModificationDate, (-600...0).contains(stamp.timeIntervalSinceNow), (values.fileSize ?? Int.max) <= 65536 else { return nil }
            return try String(contentsOf: claim, encoding: .utf8)
        } catch { return nil }
    }
}
