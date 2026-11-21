import Foundation

// No platform frameworks, permissions, device or wall clock involved.
let now = Date(timeIntervalSince1970: 300)
let first = UUID(), afterReconnect = UUID()
var gate = TapGate()
@MainActor func tap(_ token: UUID, _ sequence: Int, age: Double = 0) -> Bool {
    gate.accept(Tap(token: token, sequence: sequence, sent: now.addingTimeInterval(-age)), at: now)
}
precondition(!tap(first, 1))
gate.reset(first)
precondition(!tap(first, 1, age: 5.01) && !tap(first, 1, age: -1))
precondition(tap(first, 1, age: 5) && !tap(first, 1))
precondition(tap(first, 3) && !tap(first, 2))
gate.reset(afterReconnect)
precondition(!tap(first, 4) && tap(afterReconnect, 1))
gate.reset(nil)
precondition(!tap(afterReconnect, 2))
print("PASS: inactive / expired / future / fresh / duplicate / reordered / reconnect / stopped")

var counts = Counts()
for offset in [0, 2, 2, 1, 8] { counts.add(at: now.addingTimeInterval(Double(offset))) }
precondition(counts.total == 3 && counts.maxGap == 6 && counts.last == now.addingTimeInterval(8))
let snapshot = Snapshot(token: first, heart: counts, cadence: Counts(), sent: now)
let bytes = try JSONEncoder().encode(Packet.snapshot(snapshot))
guard case .snapshot(let decoded) = try JSONDecoder().decode(Packet.self, from: bytes) else { fatalError() }
precondition(decoded.token == first && decoded.heart.total == 3 && decoded.cadence.last == nil)
print("PASS: distinct sample timestamps / missing cadence / snapshot round trip")
precondition(stepsPerMinute(1.5) == 90 && stepsPerMinute(0) == 0)
precondition(stepsPerMinute(nil) == nil && stepsPerMinute(-1) == nil)
print("PASS: cadence units / unavailable is not zero")
