import AVFoundation
import Foundation

extension VoicePCMConverterFrame {
  func channelEvent(encodePCM: (Data) -> Any) -> [String: Any] {
    var event: [String: Any] = [
      "pcm": encodePCM(pcm),
      "captured_at_us": capturedAtUs,
    ]
    if startsNewSegment {
      event["starts_new_segment"] = true
    }
    return event
  }
}

/// Owns the tap state and delivery lifetime of one recording.
final class VoicePCMCaptureSession {
  enum Event {
    case frames([VoicePCMConverterFrame])
    case invalidTimestamp
  }

  private let converter: VoicePCMConverter
  private let wallClockUs: Int64
  private let hostTime: UInt64

  // Only the tap reads or mutates the timestamp and converter state.
  private var lastCapturedAtUs: Int64?
  private var timestampFailed = false

  // Only the main queue reads or mutates this flag.
  private var active = true

  init?(inputFormat: AVAudioFormat, wallClockUs: Int64, hostTime: UInt64) {
    guard hostTime != 0, let converter = VoicePCMConverter(inputFormat: inputFormat) else {
      return nil
    }
    self.converter = converter
    self.wallClockUs = wallClockUs
    self.hostTime = hostTime
  }

  func receive(
    _ buffer: AVAudioPCMBuffer,
    at audioTime: AVAudioTime,
    deliver: @escaping (Event) -> Void
  ) {
    guard !timestampFailed else { return }

    let event: Event
    if let capturedAtUs = capturedAtUs(for: audioTime) {
      let frames = converter.convert(buffer, capturedAtUs: capturedAtUs)
      guard !frames.isEmpty else { return }
      event = .frames(frames)
    } else {
      timestampFailed = true
      converter.stop()
      event = .invalidTimestamp
    }

    DispatchQueue.main.async(execute: DispatchWorkItem { [weak self] in
      guard self?.active == true else { return }
      deliver(event)
    })
  }

  /// Called on the main queue before removing the tap or replacing its listener.
  func deactivate() {
    active = false
  }

  private func capturedAtUs(for audioTime: AVAudioTime) -> Int64? {
    guard audioTime.isHostTimeValid, audioTime.hostTime >= hostTime else {
      return nil
    }
    let elapsedUs = AVAudioTime.seconds(forHostTime: audioTime.hostTime - hostTime) * 1_000_000
    guard let roundedElapsedUs = Int64(exactly: elapsedUs.rounded()) else {
      return nil
    }
    let (capturedAtUs, overflow) = wallClockUs.addingReportingOverflow(roundedElapsedUs)
    guard !overflow, capturedAtUs > 0,
          lastCapturedAtUs.map({ capturedAtUs > $0 }) ?? true else {
      return nil
    }
    lastCapturedAtUs = capturedAtUs
    return capturedAtUs
  }
}
