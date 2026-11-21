import SwiftUI

@MainActor
private final class Phone: ObservableObject {
    let link = Link()
    @Published var online = false
    @Published var snapshot: Snapshot?
    @Published var result = "未发送"
    private var sequence = 0
    private var pending: (tap: Tap, start: ContinuousClock.Instant)?
    init() {
        link.changed = { [weak self] live in
            guard let self else { return }
            self.online = live; self.snapshot = nil; self.pending = nil
            self.result = "未发送"; if live { self.link.send(.status) }
        }
        link.receive = { [weak self] packet in
            guard let self else { return }
            switch packet {
            case .snapshot(let latest):
                guard self.online, latest.sent >= self.snapshot?.sent ?? .distantPast else { return }
                self.snapshot = latest
            case .receipt(let tap, let ok):
                guard let pending = self.pending, pending.tap.token == tap.token,
                      pending.tap.sequence == tap.sequence else { return }
                let delay = pending.start.duration(to: .now).formatted(.units(allowed: [.seconds, .milliseconds]))
                self.result = ok ? "手表已调用轻震 · 往返 \(delay)" : "手表拒绝了此指令"
                self.pending = nil
            default: break
            }
        }
        link.activate()
    }
    func ping() {
        guard online, let token = snapshot?.token else { return }
        sequence += 1
        let tap = Tap(token: token, sequence: sequence, sent: .now)
        pending = (tap, .now); result = "等待手表回执…"
        link.send(.tap(tap))
        Task {
            try? await Task.sleep(for: .seconds(6))
            if pending?.tap.sequence == tap.sequence {
                pending = nil; result = "未收到回执，不补发"
            }
        }
    }
}

@main
struct PhoneProbe: App {
    @StateObject private var phone = Phone()
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                List {
                    Section("配对链路") {
                        Label(phone.online ? "手表可达" : "手表不可达", systemImage: "applewatch")
                        Button("刷新手表状态") { phone.link.send(.status) }.disabled(!phone.online)
                    }
                    if let s = phone.snapshot {
                        Section("最近一次快照 · \(s.sent.formatted(date: .omitted, time: .standard))") {
                            Text(s.token == nil ? "无可测试的会话" : "手表会话中")
                            counts("心率", s.heart); counts("步频", s.cadence)
                        }
                    }
                    Section {
                        Button("发送一次测试轻震") { phone.ping() }
                            .disabled(!phone.online || phone.snapshot?.token == nil)
                        Text(phone.result).foregroundStyle(.secondary)
                    } footer: { Text("回执只证明手表调用了轻震。是否感觉到，请佩戴者单独记录。无自动提醒，不录音。") }
                }.navigationTitle("对话链路测试")
            }
        }
    }
    private func counts(_ label: String, _ c: Counts) -> some View {
        VStack(alignment: .leading) {
            Text("\(label) · \(c.total) 次更新")
            Text("最近 \(c.last?.formatted(date: .omitted, time: .standard) ?? "—") · 最长间隔 \(c.maxGap, specifier: "%.1f") 秒").font(.caption)
        }
    }
}
