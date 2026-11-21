import SwiftUI
import HealthKit
import CoreMotion
import WatchKit

@MainActor
final class Run: NSObject, ObservableObject, HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
    @Published private(set) var phase = "未开始"
    @Published private(set) var busy = false
    @Published private(set) var reachable = false
    @Published private(set) var heart = Counts()
    @Published private(set) var cadence = Counts()
    @Published private(set) var bpm: Double?
    @Published private(set) var stepRate: Double?
    @Published private(set) var motion = "未采集"
    @Published private(set) var taps = 0
    private let health = HKHealthStore(), pedometer = CMPedometer(), link = Link()
    private let hr = HKQuantityType(.heartRate)
    private var workout: HKWorkoutSession?, builder: HKLiveWorkoutBuilder?
    private var attempt: UUID?, live = false, gate = TapGate()

    override init() {
        super.init()
        link.receive = { [weak self] packet in
            guard let self else { return }
            if case .status = packet { self.publish(); return }
            guard case .tap(let tap) = packet else { return }
            let ok = self.live && self.link.online && self.gate.accept(tap, at: .now)
            if ok { WKInterfaceDevice.current().play(.click); self.taps += 1 }
            self.link.send(.receipt(tap, accepted: ok))
        }
        link.changed = { [weak self] online in
            guard let self else { return }
            self.reachable = online
            self.rotateLink()
        }
        link.activate()
    }
    private func rotateLink() {
        gate.reset(live && reachable ? UUID() : nil)
        publish()
    }
    private func publish() {
        link.send(.snapshot(Snapshot(token: gate.token, heart: heart, cadence: cadence, sent: .now)))
    }

    func begin() async {
        guard !busy else { return }
        guard HKHealthStore.isHealthDataAvailable() else { phase = "此设备不支持健康数据"; return }
        let id = UUID()
        attempt = id; busy = true; phase = "等待系统权限"
        heart = Counts(); cadence = Counts(); taps = 0; motion = "未采集"
        do {
            try await health.requestAuthorization(toShare: [.workoutType()], read: [hr])
            guard attempt == id else { return }
            guard health.authorizationStatus(for: .workoutType()) == .sharingAuthorized else {
                stop("未授权测试会话"); return
            }
            let config = HKWorkoutConfiguration()
            config.activityType = .other
            config.locationType = .unknown
            let session = try HKWorkoutSession(healthStore: health, configuration: config)
            let b = session.associatedWorkoutBuilder()
            let start = Date()
            let source = HKLiveWorkoutDataSource(healthStore: health, workoutConfiguration: config)
            for type in source.typesToCollect where type != hr { source.disableCollection(for: type) }
            source.enableCollection(for: hr, predicate: HKQuery.predicateForSamples(withStart: start, end: nil, options: .strictStartDate))
            workout = session; builder = b
            session.delegate = self; b.delegate = self; b.dataSource = source
            phase = "正在开启"; session.startActivity(with: start)
            try await b.beginCollection(at: start)
            guard attempt == id else { return }
            live = true; phase = "对话测试中"; rotateLink()
            guard CMPedometer.isCadenceAvailable() else { motion = "设备无实时步频"; return }
            motion = "等待有效步频"
            pedometer.startUpdates(from: start) { @Sendable [weak self] sample, error in
                let stamp = sample?.endDate, rate = stepsPerMinute(sample?.currentCadence?.doubleValue), failed = error != nil
                Task { @MainActor in
                    guard let self, self.attempt == id, self.live else { return }
                    self.stepRate = failed ? nil : rate
                    if !failed, rate != nil, let stamp { self.cadence.add(at: stamp) }
                    self.motion = failed ? "步频不可用，检查权限" : rate != nil ? "已收到步频" : "本次无步频"
                    self.publish()
                }
            }
        } catch {
            if attempt == id { stop("启动失败，检查健康权限") }
        }
    }
    func stop(_ reason: String = "已结束") {
        attempt = nil; live = false; gate.reset(nil)
        pedometer.stopUpdates()
        let old = workout, b = builder
        workout = nil; builder = nil
        old?.delegate = nil; b?.delegate = nil
        old?.end(); b?.discardWorkout()
        bpm = nil; stepRate = nil
        busy = false; phase = reason; motion = "已停止"; publish()
    }
    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf types: Set<HKSampleType>) {
        Task { @MainActor in
            guard workoutBuilder === builder, types.contains(hr),
                  let stats = workoutBuilder.statistics(for: hr), let value = stats.mostRecentQuantity(),
                  let stamp = stats.mostRecentQuantityDateInterval()?.end else { return }
            bpm = value.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
            heart.add(at: stamp); publish()
        }
    }
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
    nonisolated func workoutSession(_ session: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in if session === workout { stop("会话中断，采集已停") } }
    }
    nonisolated func workoutSession(_ session: HKWorkoutSession, didChangeTo to: HKWorkoutSessionState,
                                    from: HKWorkoutSessionState, date: Date) {
        guard to == .ended || to == .paused || to == .stopped else { return }
        Task { @MainActor in if session === workout { stop("系统停止了会话") } }
    }
}
