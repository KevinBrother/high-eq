import Flutter
import HealthKit

/// Read-only, foreground history. No background delivery, writes or Watch bridge.
final class HealthHistory {
  private let store = HKHealthStore()
  private let heart = HKQuantityType.quantityType(forIdentifier: .heartRate)!
  private let hrv = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!
  private let steps = HKQuantityType.quantityType(forIdentifier: .stepCount)!
  private let workout = HKObjectType.workoutType()
  private var types: Set<HKObjectType> { [heart, hrv, steps, workout] }
  private var queries: [HKSampleQuery] = []
  private var pending: FlutterResult?
  private var generation = 0

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "stop" { cancel(); result(nil); return }
    guard HKHealthStore.isHealthDataAvailable() else {
      if call.method == "source" { result(nil) } else { result(false) }; return
    }
    switch call.method {
    case "source": result("apple_history")
    case "request":
      store.requestAuthorization(toShare: [], read: types) { completed, err in
        DispatchQueue.main.async { result(completed && err == nil) }
      }
    case "queryable":
      // Apple deliberately does not disclose whether read access was granted.
      store.getRequestStatusForAuthorization(toShare: [], read: types) { status, err in
        DispatchQueue.main.async { result(err == nil && status == .unnecessary) }
      }
    case "read":
      guard let args = call.arguments as? [String: NSNumber], let a = args["from"]?.doubleValue,
            let b = args["to"]?.doubleValue, b > a, b-a <= 600000, pending == nil else {
        result(FlutterError(code: "invalid_range", message: nil, details: nil)); return
      }
      // Point samples use their strict start so a reading from an earlier read
      // batch is never replayed. Steps and workouts are intervals: the Dart
      // window builder applies the durable consent cutoff to steps and keeps
      // only the overlap for both, so a later batch does not lose their tail.
      let rangeStart = Date(timeIntervalSince1970: a/1000)
      let rangeEnd = Date(timeIntervalSince1970: b/1000)
      let strict = HKQuery.predicateForSamples(
        withStart: rangeStart,
        end: rangeEnd,
        options: .strictStartDate
      )
      let overlap = HKQuery.predicateForSamples(
        withStart: rangeStart,
        end: rangeEnd,
        options: []
      )
      pending = result
      let token = generation
      var remaining = 4
      var rows: [[Any]] = []
      for (kind, type) in [("heart_rate", heart as HKSampleType), ("hrv", hrv), ("steps", steps), ("exercise", workout)] {
        let predicate = kind == "exercise" || kind == "steps" ? overlap : strict
        let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: 4097, sortDescriptors: nil) { _, samples, error in
          DispatchQueue.main.async {
            guard self.generation == token else { return }
            // A denied/empty type must not block the remaining types (notably HRV).
            let hkError = error as? HKError
            let hidden = hkError?.code == .errorAuthorizationDenied || hkError?.code == .errorNoData
            guard error == nil || hidden else { self.cancel(); return }
            let samples = hidden ? [] : samples ?? []
            guard samples.count <= 4096 else { self.cancel(); return }
            for sample in samples {
              let start = Int64((sample.startDate.timeIntervalSince1970 * 1000).rounded())
              let end = Int64((sample.endDate.timeIntervalSince1970 * 1000).rounded())
              if kind == "exercise" {
                if sample.sourceRevision.source.bundleIdentifier != Bundle.main.bundleIdentifier { rows.append([kind,start,end,1]) }
              } else if let q = sample as? HKQuantitySample {
                let unit: HKUnit = kind == "steps" ? .count() : kind == "hrv" ? .secondUnit(with: .milli) : HKUnit.count().unitDivided(by: .minute())
                rows.append([kind,start,end,q.quantity.doubleValue(for: unit)])
              }
            }
            remaining -= 1
            if remaining == 0 { self.queries.removeAll(); self.pending = nil; result(rows) }
          }
        }
        queries.append(query); store.execute(query)
      }
    default: result(FlutterMethodNotImplemented)
    }
  }
  private func cancel() {
    generation += 1
    queries.forEach { store.stop($0) }; queries.removeAll()
    pending?(FlutterError(code: "stopped", message: nil, details: nil)); pending = nil
  }
}
