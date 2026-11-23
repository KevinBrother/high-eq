import AVFoundation
import Foundation

/// One PCM block emitted by `VoicePCMConverter`.
struct VoicePCMConverterFrame {
  let pcm: Data
  let capturedAtUs: Int64
  let startsNewSegment: Bool
}

/// Converts live microphone buffers to 16 kHz mono PCM16LE and reblocks them
/// into 50 ms blocks aligned to the first complete UTC window.
final class VoicePCMConverter {
  static let sampleRate: Double = 16_000
  private static let frameDurationUs: Int64 = 50_000
  private static let windowDurationUs: Int64 = 30_000_000
  private static let microsecondsPerSecond = 1_000_000.0
  private static let outputSamplesPerFrame = AVAudioFrameCount(
    sampleRate * Double(frameDurationUs) / microsecondsPerSecond
  )
  private static let outputSampleBytes = MemoryLayout<Int16>.size
  // Allow host-clock jitter and rounding while checking adjacent tap buffers.
  private static let inputTimestampToleranceUs: Int64 = 1_000

  private let converter: AVAudioConverter
  private let inputFrame: AVAudioPCMBuffer
  private let outputFrame: AVAudioPCMBuffer
  private let inputSampleStride: Int
  private var anchors: [(originUs: Int64, input: AVAudioPCMBuffer)] = []
  private var anchorSamples: Int64 = 0
  private var segmentStartUs: Int64?
  private var consumedInputSamples: Int64 = 0
  private var bufferedInputSamples = 0
  private var nextInputTimestampUs: Int64?
  private var nextFrameTimestampUs: Int64?
  private var leadingToBoundary = false
  private var hasEmittedFrame = false
  private var startsNewSegment = false

  init?(inputFormat: AVAudioFormat) {
    let inputSamplesPerFrame = inputFormat.sampleRate * Double(Self.frameDurationUs) / Self.microsecondsPerSecond
    let inputCapacity = inputSamplesPerFrame.rounded(.up)
    let inputSampleStride = Int(inputFormat.streamDescription.pointee.mBytesPerFrame)
    guard inputSamplesPerFrame >= 1, inputCapacity <= Double(UInt32.max),
      inputFormat.channelCount > 0,
      inputSampleStride > 0,
      let output = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: Self.sampleRate,
        channels: 1,
        interleaved: true
      ),
      let converter = AVAudioConverter(from: inputFormat, to: output),
      let inputFrame = AVAudioPCMBuffer(
        pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(inputCapacity)
      ),
      let outputFrame = AVAudioPCMBuffer(
        pcmFormat: output, frameCapacity: Self.outputSamplesPerFrame
      )
    else {
      return nil
    }
    self.converter = converter
    self.inputFrame = inputFrame
    self.outputFrame = outputFrame
    self.inputSampleStride = inputSampleStride
    converter.sampleRateConverterQuality = .max
    // The converter must produce the frame without waiting for future input.
    converter.primeMethod = .none
  }

  /// Converts one tap buffer and returns every block backed by complete input.
  func convert(
    _ input: AVAudioPCMBuffer,
    capturedAtUs: Int64
  ) -> [VoicePCMConverterFrame] {
    guard input.frameLength > 0 else { return [] }
    guard input.format == inputFrame.format else {
      resetSegment()
      return []
    }
    if let expected = nextInputTimestampUs {
      let (difference, overflow) = capturedAtUs.subtractingReportingOverflow(expected)
      if overflow || difference.magnitude > UInt64(Self.inputTimestampToleranceUs) {
        resetSegment()
      }
    }
    let durationUs = inputDurationUs(Int64(input.frameLength))
    let (inputEndUs, inputEndOverflow) = capturedAtUs.addingReportingOverflow(durationUs)
    guard !inputEndOverflow else {
      resetSegment()
      return []
    }
    nextInputTimestampUs = inputEndUs

    if let origin = segmentStartUs {
      return convertSamples(input, origin: origin)
    }

    // Back-project each tap's host-clock timestamp to the same input sample.
    // A corroborating pair (within clock rounding) can correct an isolated
    // early or late stamp, including one transmitted exactly on UTC.
    let (projectedUs, overflow) = capturedAtUs.subtractingReportingOverflow(inputDurationUs(anchorSamples))
    guard !overflow else {
      resetSegment()
      return []
    }
    let agreedOrigin = corroboratedOrigin(at: projectedUs)
    let firstOrigin = anchors.first?.originUs ?? projectedUs
    let phase = Self.windowPhase(at: firstOrigin)
    let unresolvedBoundary = agreedOrigin == nil && anchors.count == 2 && phase != 0 &&
      min(phase, Self.windowDurationUs - phase) <= Self.inputTimestampToleranceUs
    if unresolvedBoundary {
      // An off-grid, disputed origin close to UTC cannot identify the first
      // sample of that window. Resume observation at the current tap.
      anchors.removeAll()
      anchorSamples = 0
    }
    let singleWindow = anchors.isEmpty && phase == 0 &&
      Double(input.frameLength) >= inputFrame.format.sampleRate * 30
    if agreedOrigin == nil && anchors.count < 2 && !singleWindow {
      // The tap owns its buffer. Keep a copy until the phase is decided.
      guard let saved = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: input.frameLength),
            copySamples(from: input, offset: 0, to: saved, at: 0, count: Int(input.frameLength)) else {
        resetSegment()
        return []
      }
      saved.frameLength = input.frameLength
      anchors.append((unresolvedBoundary ? capturedAtUs : projectedUs, saved))
      anchorSamples += Int64(input.frameLength)
      return []
    }

    let origin = segmentOrigin(at: agreedOrigin ?? firstOrigin)
    let pending = anchors
    anchors.removeAll()
    anchorSamples = 0
    segmentStartUs = origin
    leadingToBoundary = Self.windowPhase(at: origin) != 0
    var frames: [VoicePCMConverterFrame] = []
    for anchor in pending {
      frames += convertSamples(anchor.input, origin: origin)
      guard segmentStartUs != nil else { return frames }
    }
    frames += convertSamples(input, origin: origin)
    return frames
  }

  private func corroboratedOrigin(at projectedUs: Int64) -> Int64? {
    if anchors.contains(where: { $0.originUs == projectedUs }) { return projectedUs }
    guard anchors.count == 2 else { return nil }

    // A 1 µs mismatch can straddle a sample cut. Wait for a third tap before
    // falling back to clock rounding, so an exact pair takes precedence.
    let estimates = [anchors[0].originUs, anchors[1].originUs, projectedUs].sorted()
    for index in 0..<2 {
      let (difference, overflow) = estimates[index + 1].subtractingReportingOverflow(estimates[index])
      if !overflow && difference <= 1 { return estimates[1] }
    }
    return nil
  }

  private func inputDurationUs(_ samples: Int64) -> Int64 {
    Int64((Double(samples) * Self.microsecondsPerSecond / inputFrame.format.sampleRate).rounded())
  }

  private func convertSamples(_ input: AVAudioPCMBuffer, origin: Int64) -> [VoicePCMConverterFrame] {
    var timestamp = nextFrameTimestampUs ?? origin
    var frames: [VoicePCMConverterFrame] = []
    let inputSampleCount = Int(input.frameLength)
    var inputOffset = 0
    while inputOffset < inputSampleCount {
      let untilBoundary = Self.windowDurationUs - Self.windowPhase(at: timestamp)
      let durationUs = min(Self.frameDurationUs, untilBoundary)
      let (endUs, overflow) = timestamp.addingReportingOverflow(durationUs)
      guard !overflow else {
        resetSegment()
        return frames
      }
      // Use cumulative hardware sample cuts, including the shortened block at
      // the boundary. A short tap cannot complete the window by timestamp alone.
      let inputCut = Int64(
        (Double(endUs - origin) * input.format.sampleRate / Self.microsecondsPerSecond).rounded(.up)
      )
      let requiredInputSamples = Int(inputCut - consumedInputSamples)
      let copyCount = min(inputSampleCount - inputOffset, requiredInputSamples - bufferedInputSamples)
      guard copySamples(from: input, offset: inputOffset, to: inputFrame,
                        at: bufferedInputSamples, count: copyCount) else {
        resetSegment()
        return frames
      }
      inputOffset += copyCount
      bufferedInputSamples += copyCount
      guard bufferedInputSamples == requiredInputSamples else { break }

      consumedInputSamples = inputCut
      bufferedInputSamples = 0
      defer {
        timestamp = endUs
        if leadingToBoundary && Self.windowPhase(at: endUs) == 0 {
          // Resample the first UTC window starting with its own input samples.
          converter.reset()
          leadingToBoundary = false
          startsNewSegment = hasEmittedFrame && durationUs < Self.frameDurationUs
        }
      }

      if durationUs < Self.frameDurationUs {
        // Consume the residual leading fragment without emitting a short block.
        continue
      }

      inputFrame.frameLength = AVAudioFrameCount(requiredInputSamples)
      guard let pcm = convertFrame() else {
        resetSegment()
        return frames
      }
      frames.append(VoicePCMConverterFrame(
        pcm: pcm, capturedAtUs: timestamp, startsNewSegment: startsNewSegment
      ))
      hasEmittedFrame = true
      startsNewSegment = false
    }
    nextFrameTimestampUs = timestamp
    return frames
  }

  private func copySamples(
    from source: AVAudioPCMBuffer, offset: Int, to destination: AVAudioPCMBuffer, at start: Int, count: Int
  ) -> Bool {
    let sources = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
    let destinations = UnsafeMutableAudioBufferListPointer(destination.mutableAudioBufferList)
    for (source, destination) in zip(sources, destinations) {
      guard let sourceData = source.mData, let destinationData = destination.mData else { return false }
      destinationData.advanced(by: start * inputSampleStride).copyMemory(
        from: sourceData.advanced(by: offset * inputSampleStride), byteCount: count * inputSampleStride
      )
    }
    return true
  }

  private static func windowPhase(at timestamp: Int64) -> Int64 {
    let phase = timestamp % windowDurationUs
    return phase < 0 ? phase + windowDurationUs : phase
  }

  private func segmentOrigin(at timestamp: Int64) -> Int64 {
    let phase = Self.windowPhase(at: timestamp)
    // A phase shorter than one input sample still puts sample zero in UTC's
    // first sample cell. A phase past that cell starts in a partial window.
    let (boundary, overflow) = timestamp.subtractingReportingOverflow(phase)
    return !overflow && Double(phase) * inputFrame.format.sampleRate < Self.microsecondsPerSecond
      ? boundary : timestamp
  }

  private func convertFrame() -> Data? {
    outputFrame.frameLength = 0
    var supplied = false
    let status = converter.convert(to: outputFrame, error: nil) { _, inputStatus in
      if supplied {
        inputStatus.pointee = .noDataNow
        return nil
      }
      supplied = true
      inputStatus.pointee = .haveData
      return self.inputFrame
    }
    guard supplied, status == .haveData, outputFrame.frameLength == Self.outputSamplesPerFrame,
      let samples = outputFrame.int16ChannelData?[0] else {
      return nil
    }
    return Data(bytes: samples, count: Int(Self.outputSamplesPerFrame) * Self.outputSampleBytes)
  }

  /// Ends the current timeline and discards any incomplete frame.
  func stop() {
    hasEmittedFrame = false
    resetSegment()
  }

  private func resetSegment() {
    anchors.removeAll()
    anchorSamples = 0
    segmentStartUs = nil
    consumedInputSamples = 0
    bufferedInputSamples = 0
    nextInputTimestampUs = nil
    nextFrameTimestampUs = nil
    leadingToBoundary = false
    // Input discontinuities can be hidden by drift in the output timestamps.
    // Carry the boundary on the next complete frame, even if it takes more taps.
    startsNewSegment = hasEmittedFrame
    converter.reset()
  }
}
