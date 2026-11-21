import Foundation

// Only sample timing/counts cross the link. Neither bpm nor steps/min is in the wire format.
struct Counts: Codable {
    private(set) var total = 0
    private(set) var last: Date?
    private(set) var maxGap: TimeInterval = 0

    mutating func add(at time: Date) {
        if let last {
            guard time > last else { return }
            maxGap = max(maxGap, time.timeIntervalSince(last))
        }
        last = time
        total += 1
    }
}

struct Snapshot: Codable {
    let token: UUID? // Issued only for an active, reachable run; rotated on reconnect.
    let heart, cadence: Counts
    let sent: Date
}
struct Tap: Codable {
    let token: UUID
    let sequence: Int
    let sent: Date
}
enum Packet: Codable {
    case status, snapshot(Snapshot), tap(Tap), receipt(Tap, accepted: Bool)
}
struct TapGate {
    private(set) var token: UUID?
    private var highWater = 0
    mutating func reset(_ token: UUID?) { self.token = token; highWater = 0 }
    mutating func accept(_ tap: Tap, at now: Date) -> Bool {
        guard tap.token == token, tap.sequence > highWater,
              (0...5).contains(now.timeIntervalSince(tap.sent)) else { return false }
        highWater = tap.sequence
        return true
    }
}

// Core Motion's currentCadence is in steps/second; nil is not a stationary sample.
func stepsPerMinute(_ rate: Double?) -> Double? {
    guard let rate, rate.isFinite, rate >= 0 else { return nil }
    return rate * 60
}
