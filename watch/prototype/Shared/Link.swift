import Foundation
import WatchConnectivity

/// Interactive traffic only: no queue, retry, application context or historical reminders.
@MainActor
final class Link: NSObject, WCSessionDelegate {
    var receive: (Packet) -> Void = { _ in }
    var changed: (Bool) -> Void = { _ in }
    private(set) var online = false

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }
    func send(_ packet: Packet) {
        guard online, WCSession.default.isReachable, let data = try? JSONEncoder().encode(packet) else { return }
        WCSession.default.sendMessageData(data, replyHandler: nil, errorHandler: nil)
    }
    private func update(_ reachable: Bool) {
        guard online != reachable else { return }
        online = reachable
        changed(reachable)
    }
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        let live = state == .activated && session.isReachable
        Task { @MainActor in update(live) }
    }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let live = session.isReachable
        Task { @MainActor in update(live) }
    }
    nonisolated func session(_ session: WCSession, didReceiveMessageData data: Data) {
        guard let packet = try? JSONDecoder().decode(Packet.self, from: data) else { return }
        Task { @MainActor in receive(packet) }
    }
    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) { Task { @MainActor in update(false) } }
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        Task { @MainActor in update(false); activate() }
    }
    #endif
}
