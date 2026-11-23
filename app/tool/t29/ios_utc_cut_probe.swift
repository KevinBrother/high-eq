import AVFoundation
import Foundation

private let epoch: Int64 = 1_800_000_000_000_000
private let utcBoundary: Int64 = 30_000_000
private let windowEnd: Int64 = 60_000_000

@main
struct IOSUTCCutProbe {
  @MainActor
  static func main() async throws {
    let host = AVAudioTime.hostTime(forSeconds: 20)
    let tapQueue = DispatchQueue(label: "t29-utc-cut-probe")
    let phases: [Int64] = [48_900, 49_000, 49_500, 50_500, 99_500, 50_000]

    for rate in [16_000, 44_100, 48_000] {
      let format = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 1)!
      for phase in phases {
        let first = ((utcBoundary - phase) * Int64(rate) + 999_999) / 1_000_000
        let last = ((windowEnd - phase) * Int64(rate) + 999_999) / 1_000_000
        let missing = first + Int64(rate) * 30 - 1

        let reference = try await run(
          format: format,
          rate: rate,
          originUs: utcBoundary,
          start: first,
          stops: [last],
          jitterUs: 0,
          host: host,
          tapQueue: tapQueue
        )
        try write(reference[0], named: "cut-\(rate)-\(phase)-reference")

        let jitters: [Int64] = phase == 49_500 ? [-900, 0, 900] : [0]
        for jitter in jitters {
          let stages = try await run(
            format: format,
            rate: rate,
            originUs: phase,
            start: 0,
            stops: [missing, last, last + Int64(rate) / 20],
            jitterUs: jitter,
            host: host,
            tapQueue: tapQueue
          )
          for (index, name) in ["short", "full", "extra"].enumerated() {
            try write(
              stages[index],
              named: "cut-\(rate)-\(phase)-j\(jitter)-\(name)"
            )
          }
        }
      }
    }
  }

  private static func run(
    format: AVAudioFormat,
    rate: Int,
    originUs: Int64,
    start: Int64,
    stops: [Int64],
    jitterUs: Int64,
    host: UInt64,
    tapQueue: DispatchQueue
  ) async throws -> [[VoicePCMConverterFrame]] {
    guard let session = VoicePCMCaptureSession(
      inputFormat: format,
      wallClockUs: epoch,
      hostTime: host
    ) else {
      throw ProbeFailure("unable to create capture session")
    }
    var frames: [VoicePCMConverterFrame] = []
    var stages: [[VoicePCMConverterFrame]] = []
    var offset = start
    var tapNumber = 0
    let tapSizes = [1024, 2137, 777, 1900]

    for stop in stops {
      tapQueue.sync {
        while offset < stop {
          let count = Int(min(stop - offset, Int64(tapSizes[tapNumber % tapSizes.count])))
          let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(count)
          )!
          buffer.frameLength = AVAudioFrameCount(count)
          let signal = buffer.floatChannelData![0]
          for index in 0..<count {
            let sample = offset + Int64(index)
            let digit = (sample / 4) >> ((sample % 4) * 5) & 31
            signal[index] = Float(digit + (sample % 4) * 32 - 64) / 256
          }
          let adjustedUs = Double(originUs)
            + Double(offset - start) * 1_000_000 / Double(rate)
          let jitter = tapNumber == 0 ? Double(jitterUs) : 0
          let time = AVAudioTime(
            hostTime: host + AVAudioTime.hostTime(forSeconds: (adjustedUs + jitter) / 1_000_000)
          )
          session.receive(buffer, at: time) { event in
            switch event {
            case .frames(let next):
              frames += next
            case .invalidTimestamp:
              fatalError("invalid synthetic timestamp")
            }
          }
          offset += Int64(count)
          tapNumber += 1
        }
      }
      await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        DispatchQueue.main.async { done.resume() }
      }
      stages.append(frames)
    }
    session.deactivate()
    return stages
  }

  private static func write(_ frames: [VoicePCMConverterFrame], named name: String) throws {
    let rows = try frames.map { frame in
      let event = frame.channelEvent { $0.base64EncodedString() }
      let data = try JSONSerialization.data(withJSONObject: event)
      return String(decoding: data, as: UTF8.self)
    }
    try rows.joined(separator: "\n").write(
      to: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        .appendingPathComponent("\(name).jsonl"),
      atomically: false,
      encoding: .utf8
    )
    let markers = frames.filter(\.startsNewSegment).map(\.capturedAtUs)
    print("\(name): frames=\(frames.count) markers=\(markers)")
  }
}

private struct ProbeFailure: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}
