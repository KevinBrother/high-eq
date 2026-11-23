import AVFoundation
import Foundation

private struct TestFailure: Error, CustomStringConvertible {
  let description: String
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
  if !condition() { throw TestFailure(description: message) }
}

private func inputFormat(sampleRate: Double) throws -> AVAudioFormat {
  guard let format = AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: sampleRate,
    channels: 1,
    interleaved: false
  ) else {
    throw TestFailure(description: "unable to create input format")
  }
  return format
}

private func makeBuffer(
  format: AVAudioFormat,
  frameLength: AVAudioFrameCount,
  sequence: Int,
  value: Float? = nil
) throws -> AVAudioPCMBuffer {
  guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength),
        let samples = buffer.floatChannelData?[0] else {
    throw TestFailure(description: "unable to create input buffer")
  }
  buffer.frameLength = frameLength
  if let value {
    samples.update(repeating: value, count: Int(frameLength))
    return buffer
  }
  for index in 0..<Int(frameLength) {
    let phase = Double(sequence * Int(frameLength) + index)
    samples[index] = Float(sin(phase * 2 * Double.pi / 97) * 0.25)
  }
  return buffer
}

private func feed(
  converter: VoicePCMConverter,
  sampleRate: Double,
  durationSeconds: Double,
  baseTimestampUs: Int64,
  jitterUs: [Int64] = [0],
  bufferSizes: [AVAudioFrameCount] = [1024],
  value: Float? = nil,
  sampleOffsetUs: (Int) -> Int64 = { _ in 0 }
) throws -> [VoicePCMConverterFrame] {
  let format = try inputFormat(sampleRate: sampleRate)
  let totalFrames = Int((sampleRate * durationSeconds).rounded())
  var offset = 0
  var sequence = 0
  var output: [VoicePCMConverterFrame] = []
  while offset < totalFrames {
    let requestedFrames = bufferSizes[sequence % bufferSizes.count]
    let count = min(Int(requestedFrames), totalFrames - offset)
    let buffer = try makeBuffer(
      format: format,
      frameLength: AVAudioFrameCount(count),
      sequence: sequence,
      value: value
    )
    let timestamp = baseTimestampUs + Int64((Double(offset) * 1_000_000 / sampleRate).rounded())
      + jitterUs[sequence % jitterUs.count] + sampleOffsetUs(sequence)
    output.append(contentsOf: converter.convert(buffer, capturedAtUs: timestamp))
    offset += count
    sequence += 1
  }
  return output
}

private func assertFiftyMillisecondFrames(
  _ frames: [VoicePCMConverterFrame],
  baseTimestampUs: Int64,
  label: String
) throws {
  try require(frames.count >= 1200, "\(label): expected at least two 30-second windows")
  for (index, frame) in frames.enumerated() {
    try require(frame.pcm.count == 1600, "\(label): frame \(index) was not 50 ms")
    let expected = baseTimestampUs + Int64(index) * 50_000
    try require(frame.capturedAtUs == expected, "\(label): frame \(index) timestamp drifted")
  }
  try require(frames.contains { $0.pcm.contains(where: { $0 != 0 }) }, "\(label): PCM was empty")
}

private func test48kAcrossMultipleWindows() throws {
  let base = Int64(1_800_000_000_000_000)
  guard let converter = VoicePCMConverter(
    inputFormat: try inputFormat(sampleRate: 48_000)
  ) else {
    throw TestFailure(description: "48k: converter creation failed")
  }
  let frames = try feed(
    converter: converter,
    sampleRate: 48_000,
    durationSeconds: 61,
    baseTimestampUs: base
  )
  try assertFiftyMillisecondFrames(frames, baseTimestampUs: base, label: "48k")
}

private func test441kAcrossMultipleWindows() throws {
  let base = Int64(1_800_000_000_000_000)
  guard let converter = VoicePCMConverter(
    inputFormat: try inputFormat(sampleRate: 44_100)
  ) else {
    throw TestFailure(description: "44.1k: converter creation failed")
  }
  let frames = try feed(
    converter: converter,
    sampleRate: 44_100,
    durationSeconds: 61,
    baseTimestampUs: base,
    jitterUs: [0, 320, -250, 120, -310, 70]
  )
  try assertFiftyMillisecondFrames(frames, baseTimestampUs: base, label: "44.1k")
}

private func testVariableSizedBuffersAcrossMultipleWindows() throws {
  let base = Int64(1_800_000_000_000_000)
  guard let converter = VoicePCMConverter(
    inputFormat: try inputFormat(sampleRate: 48_000)
  ) else {
    throw TestFailure(description: "variable buffers: converter creation failed")
  }
  let frames = try feed(
    converter: converter,
    sampleRate: 48_000,
    durationSeconds: 61,
    baseTimestampUs: base,
    bufferSizes: [4_800, 384]
  )
  try assertFiftyMillisecondFrames(
    frames,
    baseTimestampUs: base,
    label: "48k variable buffers"
  )
}

private func testShortGapStartsANewTimeline() throws {
  let base = Int64(1_800_000_000_000_000)
  let pauseStartUs = Int64(20_009_000)
  let resumeUs = pauseStartUs + 5_000
  guard let converter = VoicePCMConverter(
    inputFormat: try inputFormat(sampleRate: 48_000)
  ) else {
    throw TestFailure(description: "short gap: converter creation failed")
  }
  var frames = try feed(
    converter: converter,
    sampleRate: 48_000,
    durationSeconds: 20.009,
    baseTimestampUs: base
  )
  frames.append(contentsOf: try feed(
    converter: converter,
    sampleRate: 48_000,
    durationSeconds: 41,
    baseTimestampUs: base + resumeUs
  ))

  let firstAfterGap = frames.first { $0.capturedAtUs >= base + resumeUs }
  try require(
    firstAfterGap?.capturedAtUs == base + resumeUs,
    "short gap: post-gap frames did not restart at the resumed hardware time"
  )
  let beforeGap = frames.filter { $0.capturedAtUs < base + resumeUs }
  try require(!beforeGap.isEmpty, "short gap: expected complete pre-gap frames")
  try require(
    beforeGap.last!.capturedAtUs + 50_000 < firstAfterGap!.capturedAtUs,
    "short gap: adjacent frames did not expose the sample-time discontinuity"
  )
}

private func testGapStartsANewTimeline() throws {
  let utcBoundary: Int64 = 1_800_000_030_000_000
  for sampleRate in [44_100.0, 48_000.0] {
    let format = try inputFormat(sampleRate: sampleRate)
    guard let converter = VoicePCMConverter(inputFormat: format),
          let freshConverter = VoicePCMConverter(inputFormat: format) else {
      throw TestFailure(description: "gap: converter creation failed")
    }
    let before = try feed(
      converter: converter,
      sampleRate: sampleRate,
      durationSeconds: 0.12,
      baseTimestampUs: utcBoundary - 120_000
    )
    try require(before.count == 2, "gap: expected two frames and an incomplete tail")

    let afterGapUs = utcBoundary + 5_000_000
    let after = try feed(
      converter: converter,
      sampleRate: sampleRate,
      durationSeconds: 0.225,
      baseTimestampUs: afterGapUs
    )
    let fresh = try feed(
      converter: freshConverter,
      sampleRate: sampleRate,
      durationSeconds: 0.225,
      baseTimestampUs: afterGapUs
    )
    try require(after.count == 4, "gap: expected four complete post-gap frames")
    for (index, frame) in after.enumerated() {
      let expected = afterGapUs + Int64(index) * 50_000
      try require(
        frame.capturedAtUs == expected,
        "gap at \(sampleRate) Hz: post-gap frame \(index) was timestamped \(frame.capturedAtUs - utcBoundary) µs from the UTC boundary"
      )
    }
    try require(
      after.map(\.pcm) == fresh.map(\.pcm),
      "gap at \(sampleRate) Hz: pre-gap PCM or converter history crossed the interruption"
    )
  }
}

private func testStopDiscardsPartialFrameAndSessionTimestamp() throws {
  let format = try inputFormat(sampleRate: 48_000)
  guard let converter = VoicePCMConverter(inputFormat: format) else {
    throw TestFailure(description: "session isolation: converter creation failed")
  }
  let oldBase = Int64(1_800_000_000_000_000)
  for sequence in 0..<2 {
    let buffer = try makeBuffer(format: format, frameLength: 1024, sequence: sequence)
    _ = converter.convert(
      buffer,
      capturedAtUs: oldBase + Int64(sequence) * 21_333
    )
  }
  converter.stop()

  let newBase = oldBase + 10_000_000
  var frames: [VoicePCMConverterFrame] = []
  for sequence in 0..<4 {
    let buffer = try makeBuffer(format: format, frameLength: 1024, sequence: sequence)
    frames.append(contentsOf: converter.convert(
      buffer,
      capturedAtUs: newBase + Int64(sequence) * 21_333
    ))
  }
  try require(frames.count == 1, "session isolation: partial output crossed stop")
  try require(frames[0].capturedAtUs == newBase, "session isolation: timestamp crossed stop")
  try require(frames[0].pcm.count == 1600, "session isolation: frame was not 50 ms")
}

private func testNumberedFirstWindow() throws {
  let base: Int64 = 1_800_000_000_000_000
  for rate in [16_000, 44_100, 48_000] {
    let format = try inputFormat(sampleRate: Double(rate))
    func cut(_ relativeUs: Int) -> Int {
      Int(ceil(Double(relativeUs * rate) / 1_000_000))
    }
    func run(originUs: Int, firstSample: Int = 0, samples: Int, sizes: [Int],
             jitterUs: Int = 0, jitterTap: Int = 0, splitLastSample: Bool = false)
      throws -> (frames: [VoicePCMConverterFrame], beforeLastSample: Int) {
      guard let converter = VoicePCMConverter(inputFormat: format) else {
        throw TestFailure(description: "numbered PCM: cannot create converter")
      }
      var frames: [VoicePCMConverterFrame] = []
      var offset = 0
      var tap = 0
      var beforeLastSample = 0
      while offset < samples {
        let finalSample = splitLastSample && offset == samples - 1
        if finalSample { beforeLastSample = frames.filter { $0.capturedAtUs >= base }.count }
        let limit = splitLastSample && !finalSample ? samples - 1 : samples
        let count = min(sizes[tap % sizes.count], limit - offset)
        let buffer = try makeBuffer(format: format, frameLength: AVAudioFrameCount(count), sequence: 0, value: 0)
        let pcm = buffer.floatChannelData![0]
        for index in 0..<count {
          let sequence = firstSample + offset + index
          let digit = (sequence / 4) >> ((sequence % 4) * 5) & 31
          pcm[index] = Float(digit + (sequence % 4) * 32 - 64) / 256
        }
        let offsetUs = Int((Double(offset * 1_000_000) / Double(rate)).rounded())
        let timestamp = base + Int64(originUs + offsetUs + (tap == jitterTap ? jitterUs : 0))
        frames += converter.convert(buffer, capturedAtUs: timestamp)
        offset += count
        tap += 1
      }
      converter.stop()
      return (frames, beforeLastSample)
    }

    var failures: [String] = []
    for originUs in [-100_000, -50_137, -900, 0, 250, 900, 1_100, 25_137] {
      let end = cut(30_000_000 - originUs)
      for sizes in [[rate / 10], [rate / 400, rate / 16, 333]] {
        let reference = try run(
          originUs: originUs > 0 ? 30_000_000 : 0,
          firstSample: originUs > 0 ? end : cut(-originUs),
          samples: originUs > 0 ? rate / 10 : rate * 30,
          sizes: [rate / 20]
        ).frames
        for (jitterTap, jitterUs) in [(0, 0), (0, -900), (0, -1), (0, 1), (0, 900),
                                      (1, -900), (1, -1), (1, 1), (1, 900)] {
          let label = "\(rate) Hz, origin \(originUs), taps \(sizes), jitter \(jitterUs) at \(jitterTap)"
          let actual = try run(originUs: originUs, samples: end, sizes: sizes,
                               jitterUs: jitterUs, jitterTap: jitterTap, splitLastSample: true)
          let window = actual.frames.filter { $0.capturedAtUs >= base }
          if originUs > 0 {
            let continued = try run(originUs: originUs, samples: end + rate / 10, sizes: sizes,
                                    jitterUs: jitterUs, jitterTap: jitterTap).frames
            let next = continued.filter { $0.capturedAtUs >= base + 30_000_000 }
            if window.count != 599 || window.first?.capturedAtUs != base + Int64(originUs) ||
               next.map(\.pcm) != reference.map(\.pcm) || next.first?.capturedAtUs != base + 30_000_000 {
              failures.append("\(label): late start produced \(window.count) prefix frames or shifted next-window PCM")
            }
          } else if actual.beforeLastSample != 599 || window.count != 600 ||
                    window.map(\.capturedAtUs) != reference.map(\.capturedAtUs) ||
                    window.map(\.pcm) != reference.map(\.pcm) {
            failures.append("\(label): \(actual.beforeLastSample)/\(window.count) frames before/after the last sample, or shifted PCM")
          }
          let segmentStarts = actual.frames.filter(\.startsNewSegment).map(\.capturedAtUs)
          let expectedSegmentStarts = originUs == -50_137 ? [base] : []
          if segmentStarts != expectedSegmentStarts {
            failures.append(
              "\(label): expected segment starts \(expectedSegmentStarts), got \(segmentStarts)"
            )
          }
        }
      }
    }
    try require(failures.isEmpty, failures.joined(separator: "\n"))
  }
}

private func testTrimmedLeadingResidualMarksAlignedBlock() throws {
  let utcBoundary: Int64 = 1_800_000_030_000_000
  let cases: [(phaseUs: Int64, jitterUs: Int64, expectsMarker: Bool)] = [
    (48_900, 0, true),
    (49_000, 0, true),
    (49_500, 0, true),
    (49_500, -900, true),
    (49_500, 900, true),
    (50_500, 0, true),
    (99_500, 0, true),
    (50_000, 0, false),
    (0, 0, false),
  ]

  for rate in [16_000, 44_100, 48_000] {
    let format = try inputFormat(sampleRate: Double(rate))
    for item in cases {
      let label = "\(rate) Hz leading phase \(item.phaseUs), jitter \(item.jitterUs)"
      guard let converter = VoicePCMConverter(inputFormat: format) else {
        throw TestFailure(description: "\(label): converter creation failed")
      }
      let frames = try feed(
        converter: converter,
        sampleRate: Double(rate),
        durationSeconds: 60.1,
        baseTimestampUs: utcBoundary - 30_000_000 + item.phaseUs,
        bufferSizes: [1024, 2137, 777, 1900],
        value: 0.23,
        sampleOffsetUs: { $0 == 0 ? item.jitterUs : 0 }
      )
      let window = frames.filter {
        $0.capturedAtUs >= utcBoundary && $0.capturedAtUs < utcBoundary + 30_000_000
      }
      try require(
        window.first?.capturedAtUs == utcBoundary,
        "\(label): first complete block did not start at UTC"
      )
      let markers = window.filter(\.startsNewSegment).map(\.capturedAtUs)
      let expectedMarkers = item.expectsMarker ? [utcBoundary] : []
      try require(
        markers == expectedMarkers,
        "\(label): expected segment markers \(expectedMarkers), got \(markers)"
      )
    }
  }
}

@MainActor
private func testCaptureAtThirtySecondBoundary() async throws {
  enum Scenario: String, CaseIterable {
    case stop, gap, continuous
  }

  let base: Int64 = 1_800_000_000_000_000
  let hostAnchor = AVAudioTime.hostTime(forSeconds: 20)
  let tap = DispatchQueue(label: "synthetic-tap")
  var failures: [String] = []

  for rate in [16_000, 44_100, 48_000] {
    let format = try inputFormat(sampleRate: Double(rate))
    for sizes in [[1024], [4_800, 384]] {
      for scenario in Scenario.allCases {
        let deficits = scenario == .continuous ? [0] : [0, 1]
        for missing in deficits {
          let label = "\(rate) Hz \(sizes), \(scenario), \(missing) missing sample(s)"
          guard let capture = VoicePCMCaptureSession(
            inputFormat: format, wallClockUs: base, hostTime: hostAnchor
          ) else {
            throw TestFailure(description: "\(label): unable to create capture session")
          }
          var events: [VoicePCMCaptureSession.Event] = []
          let deliver: (VoicePCMCaptureSession.Event) -> Void = { events.append($0) }

          func feed(
            _ session: VoicePCMCaptureSession,
            startUs: Int64,
            samples: Int,
            value: Float,
            splitFirstTap: Bool = false,
            deliver: @escaping (VoicePCMCaptureSession.Event) -> Void
          ) {
            var offset = 0
            var index = 0
            while offset < samples {
              let limit = splitFirstTap && index == 0 ? rate / 20 : samples
              let count = min(sizes[index % sizes.count], samples - offset, limit)
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
              buffer.frameLength = AVAudioFrameCount(count)
              buffer.floatChannelData![0].update(repeating: value, count: count)
              // After two startup anchors, subsequent taps can report a
              // slightly late host time without supplying the missing sample.
              let jitter = missing == 1 && index >= 2 ? 0.00025 : 0
              let seconds = Double(startUs) / 1_000_000 + Double(offset) / Double(rate) + jitter
              let time = AVAudioTime(hostTime: hostAnchor + AVAudioTime.hostTime(forSeconds: seconds))
              session.receive(buffer, at: time, deliver: deliver)
              offset += count
              index += 1
            }
          }

          let beforeGap = missing == 0 ? 600 : 599
          let resumeUs: Int64 = 30_005_000
          let fresh = scenario == .gap ? VoicePCMCaptureSession(
            inputFormat: format, wallClockUs: base, hostTime: hostAnchor
          ) : nil
          var freshFrames: [VoicePCMConverterFrame] = []
          tap.sync {
            if scenario == .continuous {
              feed(capture, startUs: 0, samples: 60 * rate, value: 0.23, deliver: deliver)
            } else {
              feed(capture, startUs: 0, samples: 30 * rate - missing, value: 0.23, deliver: deliver)
              if let fresh {
                // Preserve the 100 ms prefix while supplying a second anchor,
                // even when the tap size would normally fit the whole prefix.
                feed(capture, startUs: resumeUs, samples: rate / 10, value: -0.23,
                     splitFirstTap: true, deliver: deliver)
                feed(fresh, startUs: resumeUs, samples: rate / 10, value: -0.23, splitFirstTap: true) { event in
                  if case .frames(let frames) = event { freshFrames.append(contentsOf: frames) }
                }
              }
            }
          }
          await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { done.resume() }
          }
          capture.deactivate()

          do {
            let frames = try events.flatMap { event in
              guard case .frames(let frames) = event else {
                throw TestFailure(description: "unexpected timestamp error")
              }
              return frames
            }
            let expected = scenario == .continuous ? 1200 : beforeGap + (scenario == .gap ? 2 : 0)
            try require(frames.count == expected, "expected \(expected) frames, got \(frames.count)")
            if scenario == .gap {
              // Compare from the first sample, including the converter's startup transient.
              try require(
                frames.suffix(2).map(\.pcm) == freshFrames.map(\.pcm),
                "pre-gap PCM or converter history crossed the interruption"
              )
            }
            for (index, frame) in frames.enumerated() {
              let resumed = scenario == .gap && index >= beforeGap
              let offset = resumed ? resumeUs + Int64(index - beforeGap) * 50_000 : Int64(index) * 50_000
              try require(frame.capturedAtUs == base + offset, "frame \(index) timestamp drifted")
              try require(frame.pcm.count == 1600, "frame \(index) was not 50 ms")
              try require(
                frame.startsNewSegment == (resumed && index == beforeGap),
                "frame \(index) had an incorrect segment boundary"
              )
              if index == beforeGap - 1 || index == frames.count - 1 {
                let hasExpectedSignal = frame.pcm.withUnsafeBytes { bytes in
                  bytes.bindMemory(to: Int16.self).allSatisfy { resumed ? $0 < -1_000 : $0 > 1_000 }
                }
                try require(
                  hasExpectedSignal,
                  "frame \(index) contained silent padding or PCM from the other segment"
                )
              }
            }
          } catch {
            failures.append("\(label): \(error)")
          }
        }
      }
    }
  }
  try require(failures.isEmpty, failures.joined(separator: "\n"))
}

@MainActor
private func testQueuedCaptureEventsStayInTheirSession() async throws {
  let sampleRate = 48_000.0
  let format = try inputFormat(sampleRate: sampleRate)
  let hostAnchor = AVAudioTime.hostTime(forSeconds: 10)
  let oldBase: Int64 = 1_800_000_000_000_000
  let newBase = oldBase + 10_000_000
  guard let oldSession = VoicePCMCaptureSession(
    inputFormat: format, wallClockUs: oldBase, hostTime: hostAnchor
  ), let newSession = VoicePCMCaptureSession(
    inputFormat: format, wallClockUs: newBase, hostTime: hostAnchor
  ) else {
    throw TestFailure(description: "session isolation: creation failed")
  }

  var events: [VoicePCMCaptureSession.Event] = []
  let deliver: (VoicePCMCaptureSession.Event) -> Void = { events.append($0) }
  let buffers = try (0..<4).map {
    try makeBuffer(format: format, frameLength: 1024, sequence: $0)
  }
  func audioTime(_ index: Int, offset: Double = 0) -> AVAudioTime {
    AVAudioTime(hostTime: hostAnchor + AVAudioTime.hostTime(
      forSeconds: Double(index * 1024) / sampleRate + offset
    ))
  }

  for (index, buffer) in buffers.enumerated() {
    oldSession.receive(buffer, at: audioTime(index), deliver: deliver)
  }
  // Also queue the first complete frame after an in-session gap.
  for (index, buffer) in buffers.enumerated() {
    oldSession.receive(buffer, at: audioTime(index + buffers.count, offset: 0.005), deliver: deliver)
  }
  oldSession.deactivate()
  for (index, buffer) in buffers.enumerated() {
    newSession.receive(buffer, at: audioTime(index), deliver: deliver)
  }
  // An old tap can still report an invalid timestamp while shutdown finishes.
  oldSession.receive(
    buffers[0], at: AVAudioTime(sampleTime: 0, atRate: sampleRate), deliver: deliver
  )
  // A repeated timestamp in the current session must still fail closed.
  newSession.receive(buffers[0], at: audioTime(3), deliver: deliver)
  newSession.receive(buffers[0], at: audioTime(4), deliver: deliver)
  await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
    DispatchQueue.main.async { done.resume() }
  }
  guard events.count == 2, case .frames(let frames) = events[0],
        case .invalidTimestamp = events[1] else {
    throw TestFailure(description: "expected only the new session's PCM and timestamp error")
  }
  try require(frames.count == 1, "session isolation: old partial output crossed stop")
  try require(frames[0].capturedAtUs == newBase, "session isolation: old PCM reached the new session")
  try require(frames[0].pcm.count == 1600, "session isolation: frame was not 50 ms")
  try require(!frames[0].startsNewSegment, "session isolation: old boundary reached the new session")
}

@MainActor
private func captureRecovery(
  base: Int64, beforeSamples: Int, resumeUs: Int64, afterSamples: Int
) async throws -> [VoicePCMConverterFrame] {
  let rate = 48_000.0
  let format = try inputFormat(sampleRate: rate)
  let hostAnchor = AVAudioTime.hostTime(forSeconds: 20)
  guard let capture = VoicePCMCaptureSession(
    inputFormat: format, wallClockUs: base, hostTime: hostAnchor
  ) else {
    throw TestFailure(description: "recovery: unable to create capture session")
  }
  var events: [VoicePCMCaptureSession.Event] = []

  func feedSegment(startUs: Int64, samples: Int, skewPerTapUs: Int64, value: Float) throws {
    for (tap, offset) in stride(from: 0, to: samples, by: 4_800).enumerated() {
      let buffer = try makeBuffer(
        format: format,
        frameLength: AVAudioFrameCount(min(4_800, samples - offset)),
        sequence: tap,
        value: value
      )
      let offsetUs = Int64((Double(offset) * 1_000_000 / rate).rounded())
      let seconds = Double(startUs + offsetUs + Int64(tap) * skewPerTapUs) / 1_000_000
      let time = AVAudioTime(hostTime: hostAnchor + AVAudioTime.hostTime(forSeconds: seconds))
      capture.receive(buffer, at: time) { events.append($0) }
    }
  }

  try DispatchQueue(label: "synthetic-recovery-tap").sync {
    // Adjacent host timestamps drift by 100 µs per tap. The old output clock
    // therefore reaches the resumed timestamp even though the input had a gap.
    try feedSegment(startUs: 0, samples: beforeSamples, skewPerTapUs: -100, value: -0.23)
    try feedSegment(startUs: resumeUs, samples: afterSamples, skewPerTapUs: 0, value: 0.23)
  }
  await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
    DispatchQueue.main.async { done.resume() }
  }
  capture.deactivate()
  return try events.flatMap { event in
    guard case .frames(let frames) = event else {
      throw TestFailure(description: "recovery: unexpected invalid timestamp")
    }
    return frames
  }
}

@MainActor
private func writeReplays(to directory: URL) async throws {
  let base: Int64 = 1_800_000_000_000_000

  func write(_ frames: [VoicePCMConverterFrame], named name: String) throws {
    // Serialize the production channel map, using base64 in place of typed
    // data to carry the bytes between the host Swift and Dart processes.
    let rows = try frames.map { frame in
      let event = frame.channelEvent { $0.base64EncodedString() }
      let json = try JSONSerialization.data(withJSONObject: event, options: .withoutEscapingSlashes)
      return String(decoding: json, as: UTF8.self) + "\n"
    }
    try rows.joined().write(to: directory.appendingPathComponent(name), atomically: false, encoding: .utf8)
  }

  for rate in [16_000.0, 44_100.0, 48_000.0] {
    let format = try inputFormat(sampleRate: rate)
    for phaseUs in [0, -20, -1, 1, 62, 137, 25_000, 49_999, 50_001, 63_137, 12_345_678] {
      // The first sample at or after the end is outside this fixture.
      let samplesAtWindowEnd = Int((Double(30_000_000 + phaseUs) * rate / 1_000_000).rounded(.up))
      for missing in [0, 1] {
        let frames = try feed(
          converter: VoicePCMConverter(inputFormat: format)!,
          sampleRate: rate,
          durationSeconds: Double(samplesAtWindowEnd - missing) / rate,
          baseTimestampUs: base - Int64(phaseUs),
          bufferSizes: [1024, 4_800, 333, 384],
          value: 0.23
        )
        try write(frames, named: "phase-\(Int(rate))-\(phaseUs)-\(missing)")
      }
    }
    for jitterUs in [-900, 900] {
      for missing in [0, 1] {
        let frames = try feed(
          converter: VoicePCMConverter(inputFormat: format)!,
          sampleRate: rate,
          durationSeconds: 30 - Double(missing) / rate,
          baseTimestampUs: base,
          bufferSizes: [1024, 4_800, 333],
          value: 0.23,
          sampleOffsetUs: { $0 == 0 ? Int64(jitterUs) : 0 }
        )
        try write(frames, named: "signed-\(Int(rate))-\(jitterUs)-\(missing)")
      }
    }
    let lateUs: Int64 = 900
    let lateSamples = (Double(60_000_000 - lateUs) * rate / 1_000_000).rounded(.up)
    let late = try feed(
      converter: VoicePCMConverter(inputFormat: format)!,
      sampleRate: rate,
      durationSeconds: lateSamples / rate,
      baseTimestampUs: base + lateUs,
      bufferSizes: [4_800, 384],
      value: 0.23,
      sampleOffsetUs: { $0 == 0 ? -lateUs : 0 }
    )
    try write(late, named: "signed-late-\(Int(rate))")
  }

  let disputed = try feed(
    converter: VoicePCMConverter(inputFormat: inputFormat(sampleRate: 16_000))!,
    sampleRate: 16_000,
    durationSeconds: 60,
    baseTimestampUs: base,
    bufferSizes: [1_600],
    value: 0.23,
    sampleOffsetUs: { tap in
      let startupJitter: [Int64] = [-900, 30, 500]
      return tap < startupJitter.count ? startupJitter[tap] : 0
    }
  )
  try write(disputed, named: "signed-disputed")

  let rate = 48_000.0
  let format = try inputFormat(sampleRate: rate)
  for gapUs in [0, -5_000, 24_999, 25_000, 25_001, 26_000, 40_000] {
    let frames = try feed(
      converter: VoicePCMConverter(inputFormat: format)!,
      sampleRate: rate,
      durationSeconds: 301,
      baseTimestampUs: base,
      bufferSizes: [4_800],
      sampleOffsetUs: { block in Int64(-block * 10 + (block >= 2_500 ? gapUs : 0)) }
    )
    let replay = frames.filter { ($0.capturedAtUs - base) >= 239_900_000 }
    try write(replay, named: "gap-\(gapUs)")
  }

  // Recover exactly at UTC, or at 15 seconds while the prior window is partial.
  for (name, beforeSamples, resumeUs, afterSamples) in [
    ("recovery-visible", 29 * 48_000 + 43_200, 30_000_000, 30 * 48_000),
    ("recovery-utc", 30 * 48_000, 30_000_000, 30 * 48_000),
    ("recovery-utc-one-short", 30 * 48_000, 30_000_000, 30 * 48_000 - 1),
    ("recovery-partial", 15 * 48_000, 15_000_000, 45 * 48_000),
    ("recovery-partial-reference", 0, 15_000_000, 45 * 48_000),
  ] {
    let frames = try await captureRecovery(
      base: base, beforeSamples: beforeSamples, resumeUs: Int64(resumeUs), afterSamples: afterSamples
    )
    try write(frames, named: name)
  }
}

@main
struct VoicePCMConverterTests {
  @MainActor
  static func main() async {
    if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--replay" {
      do {
        try await writeReplays(to: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true))
      } catch {
        print("FAIL replay export: \(error)")
        exit(1)
      }
      return
    }
    let tests: [(String, () throws -> Void)] = [
      ("48k capture emits 50 ms frames across multiple windows", test48kAcrossMultipleWindows),
      ("44.1k capture emits 50 ms frames across multiple windows with host jitter", test441kAcrossMultipleWindows),
      ("48k capture preserves samples with alternating 4,800 and 384 frame buffers", testVariableSizedBuffersAcrossMultipleWindows),
      ("a five-millisecond gap starts a new UTC sample timeline", testShortGapStartsANewTimeline),
      ("a five-second gap starts a new UTC timeline without pre-gap PCM", testGapStartsANewTimeline),
      ("stop discards partial frame and isolates the next session", testStopDiscardsPartialFrameAndSessionTimestamp),
      ("first-window sample cuts honor signed jitter, real phase and one-sample deficits", testNumberedFirstWindow),
      ("trimmed leading residuals mark only the next aligned block", testTrimmedLeadingResidualMarksAlignedBlock),
    ]
    var failures = 0
    for (name, test) in tests {
      do {
        try test()
        print("PASS \(name)")
      } catch {
        failures += 1
        print("FAIL \(name): \(error)")
      }
    }
    let captureTests: [(String, @MainActor () async throws -> Void)] = [
      ("capture delivers complete windows before stop and across hardware gaps", testCaptureAtThirtySecondBoundary),
      ("stop suppresses queued PCM and late timestamp errors from old sessions", testQueuedCaptureEventsStayInTheirSession),
    ]
    for (name, test) in captureTests {
      do {
        try await test()
        print("PASS \(name)")
      } catch {
        failures += 1
        print("FAIL \(name): \(error)")
      }
    }
    exit(failures == 0 ? 0 : 1)
  }
}
