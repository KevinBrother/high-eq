import SwiftUI

@main
struct WatchProbe: App {
    @StateObject private var run = Run()
    @State private var consenting = false
    var body: some Scene {
        WindowGroup {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Label(run.phase, systemImage: run.busy ? "waveform.path.ecg" : "applewatch")
                        .font(.headline)
                    Text(run.reachable ? "手机可达" : "手机不可达").foregroundStyle(.secondary)
                    if run.busy {
                        Button("结束并停止采集", role: .destructive) { run.stop() }
                    } else {
                        Button("开始对话测试") { consenting = true }.tint(.blue)
                    }
                    if run.busy {
                        Text("最近读数 · 仅本表").font(.caption2)
                        Text("\(run.bpm.map { $0.formatted(.number.precision(.fractionLength(0))) } ?? "—") 次/分")
                        Text("\(run.stepRate.map { $0.formatted(.number.precision(.fractionLength(0))) } ?? "—") 步/分")
                    }
                    Text("有效更新次数").font(.caption2)
                    Text("心率 \(run.heart.total) · 步频 \(run.cadence.total)")
                    Text(run.motion).font(.caption)
                    Text("轻震调用 \(run.taps) 次").font(.caption)
                }
            }
            .sheet(isPresented: $consenting) {
                ScrollView {
                    Text("仅供配对测试").font(.headline)
                    Text("为了测量对话中的更新间隔与轻震，使用体能训练会话读取本次心率和步频。可能增加耗电；不保存训练、不录音，只向配对手机发送计数和时间。可随时结束。请勿中断其他训练。")
                    Button("同意并继续") { consenting = false; Task { await run.begin() } }
                    Button("取消", role: .cancel) { consenting = false }
                }
            }
        }
    }
}
