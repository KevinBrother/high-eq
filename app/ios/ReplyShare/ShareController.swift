import UIKit
import UniformTypeIdentifiers

/// No authentication, clipboard access, networking or unsupported open-app tricks in the extension.
final class ShareController: UIViewController {
    private let message = UILabel(), save = UIButton(type: .system)
    private var draft: String?
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let heading = UILabel(); heading.text = "回复助手"; heading.font = .preferredFont(forTextStyle: .title1)
        message.numberOfLines = 0; message.text = "正在读取选中的文字…"
        save.setTitle("带入草稿", for: .normal); save.isEnabled = false
        save.addTarget(self, action: #selector(commit), for: .touchUpInside)
        let cancel = UIButton(type: .system); cancel.setTitle("关闭", for: .normal)
        cancel.addTarget(self, action: #selector(done), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [heading, message, save, cancel]); stack.axis = .vertical; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor), stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor), stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor)])
        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        guard items.count == 1, let shared = items.first else { message.text = "请只选择一段纯文字。"; return }
        let providers = shared.attachments ?? []
        if providers.isEmpty { prepare(shared.attributedContentText?.string); return }
        let plain = UTType.plainText.identifier
        guard providers.count == 1, let item = providers.first, item.hasItemConformingToTypeIdentifier(plain) else { message.text = "请选择一段纯文字后再分享。"; return }
        item.loadItem(forTypeIdentifier: plain, options: nil) { item, _ in
            let value = item as? String ?? (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
            DispatchQueue.main.async { self.prepare(value) }
        }
    }
    private func prepare(_ value: String?) {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.utf8.count <= 65536 else { message.text = "未收到可用文字，请分享较短的一段纯文字。"; return }
        draft = value
        message.text = "只暂存本次选中的文字，不会发送。请在 10 分钟内打开「对话手记」，登录后可编辑并决定是否分析。"
        save.isEnabled = true
    }
    @objc private func commit() {
        guard let draft else { return }
        do { try ReplyInbox.store(draft); self.draft = nil; done() }
        catch { message.text = "无法暂存，请解锁设备后重试。" }
    }
    @objc private func done() { extensionContext?.completeRequest(returningItems: nil) }
}
