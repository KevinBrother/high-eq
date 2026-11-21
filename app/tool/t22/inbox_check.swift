import Foundation

@main struct InboxCheck {
    static func main() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let file = temp.appendingPathComponent("incoming")
        try ReplyInbox.store("合成文字 A", at: file)
        try ReplyInbox.store("合成文字 B", at: file)
        precondition(ReplyInbox.take(at: file) == "合成文字 B")
        precondition(ReplyInbox.take(at: file) == nil)
        try ReplyInbox.store("过期合成文字", at: file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -601)], ofItemAtPath: file.path)
        precondition(ReplyInbox.take(at: file) == nil)
        precondition(!FileManager.default.fileExists(atPath: file.path))
        try ReplyInbox.store("中断前旧文字", at: file)
        let interruptedClaim = temp.appendingPathComponent("claimed")
        try FileManager.default.moveItem(at: file, to: interruptedClaim)
        try ReplyInbox.store("重开后的新文字", at: file)
        precondition(ReplyInbox.take(at: file) == "重开后的新文字")
        precondition(!FileManager.default.fileExists(atPath: interruptedClaim.path))
        print("PASS: synthetic inbox replacement, one-shot read, expiry and interrupted-claim cleanup")
    }
}
