import AVFoundation
import Flutter
import Foundation

/// In-memory microphone capture and local PCM playback for T29.
///
/// The bridge never writes audio to disk, transcribes it, or sends it over the
/// network. Flutter receives only 16 kHz mono PCM16LE chunks; the Dart layer
/// performs aggregation and persistence.
final class VoiceCapture: NSObject, FlutterStreamHandler {
  static let controlChannelName = "cn.higheq/voice-capture"
  static let pcmChannelName = "cn.higheq/voice-capture/pcm"

  private let captureEngine = AVAudioEngine()
  private let playbackEngine = AVAudioEngine()
  private let playbackPlayer = AVAudioPlayerNode()
  private let targetFormat: AVAudioFormat
  private var converter: AVAudioConverter?
  private var eventSink: FlutterEventSink?
  private var controlChannel: FlutterMethodChannel?
  private var eventChannel: FlutterEventChannel?
  private var tapInstalled = false
  private var recording = false
  private var playing = false
  private var pendingPermission: FlutterResult?
  private var captureClockAnchor: CaptureClockAnchor?
  private var lastCapturedAtUs: Int64?

  override init() {
    guard let format = AVAudioFormat(
      commonFormat: .pcmFormatInt16,
      sampleRate: 16_000,
      channels: 1,
      interleaved: true
    ) else {
      fatalError("Unable to create the T29 PCM format")
    }
    targetFormat = format
    super.init()
  }

  func install(messenger: FlutterBinaryMessenger) {
    let control = FlutterMethodChannel(
      name: Self.controlChannelName,
      binaryMessenger: messenger
    )
    control.setMethodCallHandler(handle)
    controlChannel = control

    let events = FlutterEventChannel(
      name: Self.pcmChannelName,
      binaryMessenger: messenger
    )
    events.setStreamHandler(self)
    eventChannel = events
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "checkPermission":
      result(hasRecordPermission())
    case "requestPermission":
      requestRecordPermission(result)
    case "start":
      start(result)
    case "stop":
      stop()
      result(nil)
    case "play":
      play(call, result: result)
    case "stopPlayback":
      stopPlayback()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  private func hasRecordPermission() -> Bool {
    if #available(iOS 17.0, *) {
      return AVAudioApplication.shared.recordPermission == .granted
    }
    return AVAudioSession.sharedInstance().recordPermission == .granted
  }

  private func requestRecordPermission(_ result: @escaping FlutterResult) {
    if hasRecordPermission() {
      result(true)
      return
    }
    if pendingPermission != nil {
      result(false)
      return
    }
    pendingPermission = result

    if #available(iOS 17.0, *) {
      AVAudioApplication.requestRecordPermission { [weak self] granted in
        DispatchQueue.main.async {
          self?.finishPermission(granted)
        }
      }
    } else {
      AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
        DispatchQueue.main.async {
          self?.finishPermission(granted)
        }
      }
    }
  }

  private func finishPermission(_ granted: Bool) {
    guard let result = pendingPermission else { return }
    pendingPermission = nil
    result(granted)
  }

  private func start(_ result: @escaping FlutterResult) {
    guard hasRecordPermission() else {
      result(FlutterError(
        code: "permission_denied",
        message: "Microphone permission is not granted.",
        details: nil
      ))
      return
    }
    if recording {
      result(nil)
      return
    }

    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
      try session.setActive(true, options: [])

      let input = captureEngine.inputNode
      let inputFormat = input.inputFormat(forBus: 0)
      guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
        throw VoiceCaptureError.audioUnavailable
      }
      guard let nextConverter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
        throw VoiceCaptureError.audioUnavailable
      }
      nextConverter.sampleRateConverterQuality = .max
      converter = nextConverter

      let anchorHostTime = AVAudioTime.hostTime(
        forSeconds: ProcessInfo.processInfo.systemUptime
      )
      guard anchorHostTime != 0 else {
        throw VoiceCaptureError.audioTimestampUnavailable
      }
      captureClockAnchor = CaptureClockAnchor(
        wallClockUs: Int64(Date().timeIntervalSince1970 * 1_000_000),
        hostTime: anchorHostTime
      )
      lastCapturedAtUs = nil

      if tapInstalled {
        input.removeTap(onBus: 0)
        tapInstalled = false
      }
      recording = true
      input.installTap(
        onBus: 0,
        bufferSize: 1024,
        format: inputFormat
      ) { [weak self] buffer, when in
        guard let self else { return }
        guard let capturedAtUs = self.capturedAtUs(for: when) else {
          self.failCaptureTimestamp()
          return
        }
        self.convertAndEmit(buffer, capturedAtUs: capturedAtUs)
      }
      tapInstalled = true
      captureEngine.prepare()
      try captureEngine.start()
      result(nil)
    } catch {
      recording = false
      removeCaptureTap()
      captureEngine.stop()
      converter = nil
      captureClockAnchor = nil
      lastCapturedAtUs = nil
      try? AVAudioSession.sharedInstance().setActive(
        false,
        options: .notifyOthersOnDeactivation
      )
      result(FlutterError(
        code: "audio_unavailable",
        message: "Unable to start microphone capture.",
        details: nil
      ))
    }
  }

  private func capturedAtUs(for audioTime: AVAudioTime) -> Int64? {
    guard recording,
          audioTime.isHostTimeValid,
          audioTime.hostTime != 0,
          let anchor = captureClockAnchor,
          audioTime.hostTime >= anchor.hostTime else {
      return nil
    }

    let elapsedSeconds = AVAudioTime.seconds(forHostTime: audioTime.hostTime)
      - AVAudioTime.seconds(forHostTime: anchor.hostTime)
    let elapsedUs = elapsedSeconds * 1_000_000
    guard elapsedSeconds.isFinite,
          elapsedSeconds >= 0,
          elapsedUs.isFinite,
          elapsedUs <= Double(Int64.max - anchor.wallClockUs) else {
      return nil
    }

    let capturedAtUs = anchor.wallClockUs + Int64(elapsedUs.rounded())
    guard capturedAtUs > 0,
          lastCapturedAtUs.map({ capturedAtUs > $0 }) ?? true else {
      return nil
    }
    lastCapturedAtUs = capturedAtUs
    return capturedAtUs
  }

  private func failCaptureTimestamp() {
    DispatchQueue.main.async(execute: DispatchWorkItem { [weak self] in
      guard let self, self.recording else { return }
      self.stop()
      self.eventSink?(FlutterError(
        code: "capture_timestamp_invalid",
        message: "The microphone timestamp is unavailable or inconsistent.",
        details: nil
      ))
    })
  }

  private func convertAndEmit(
    _ input: AVAudioPCMBuffer,
    capturedAtUs: Int64
  ) {
    guard recording, let converter else { return }
    let ratio = targetFormat.sampleRate / input.format.sampleRate
    let capacity = AVAudioFrameCount(
      min(Double(UInt32.max), Double(input.frameLength) * ratio + 32)
    )
    guard capacity > 0,
          let output = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: capacity
          ) else {
      return
    }

    var supplied = false
    var conversionError: NSError?
    let status = converter.convert(
      to: output,
      error: &conversionError
    ) { _, inputStatus in
      if supplied {
        inputStatus.pointee = .endOfStream
        return nil
      }
      supplied = true
      inputStatus.pointee = .haveData
      return input
    }

    guard status != .error,
          output.frameLength > 0,
          let samples = output.int16ChannelData?[0] else {
      return
    }
    let data = Data(
      bytes: samples,
      count: Int(output.frameLength) * MemoryLayout<Int16>.size
    )
    DispatchQueue.main.async { [weak self] in
      guard let self, self.recording else { return }
      self.eventSink?([
        "pcm": FlutterStandardTypedData(bytes: data),
        "captured_at_us": capturedAtUs,
      ])
    }
  }

  private func stop() {
    recording = false
    removeCaptureTap()
    captureEngine.stop()
    converter = nil
    captureClockAnchor = nil
    lastCapturedAtUs = nil
    try? AVAudioSession.sharedInstance().setActive(
      false,
      options: .notifyOthersOnDeactivation
    )
  }

  private func removeCaptureTap() {
    guard tapInstalled else { return }
    captureEngine.inputNode.removeTap(onBus: 0)
    tapInstalled = false
  }

  private func play(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let typed = (call.arguments as? [String: Any])?["pcm"] as? FlutterStandardTypedData,
          !typed.data.isEmpty,
          typed.data.count.isMultiple(of: 2) else {
      result(FlutterError(
        code: "invalid_pcm",
        message: "Playback requires non-empty 16-bit PCM.",
        details: nil
      ))
      return
    }
    stopPlayback()
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .spokenAudio, options: [])
      try session.setActive(true, options: [])

      guard let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: targetFormat.sampleRate,
        channels: 1,
        interleaved: false
      ) else {
        throw VoiceCaptureError.audioUnavailable
      }
      let frameCount = AVAudioFrameCount(typed.data.count / 2)
      guard let buffer = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: frameCount
      ), let channel = buffer.floatChannelData?[0] else {
        throw VoiceCaptureError.audioUnavailable
      }
      buffer.frameLength = frameCount
      typed.data.withUnsafeBytes { raw in
        let source = raw.bindMemory(to: Int16.self)
        for index in 0..<Int(frameCount) {
          channel[index] = Float(Int16(littleEndian: source[index])) / 32768.0
        }
      }

      if !playbackPlayer.engineIsAttached(to: playbackEngine) {
        playbackEngine.attach(playbackPlayer)
        playbackEngine.connect(playbackPlayer, to: playbackEngine.mainMixerNode, format: format)
      }
      playbackEngine.prepare()
      try playbackEngine.start()
      playing = true
      playbackPlayer.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
        DispatchQueue.main.async {
          guard let self, self.playing else { return }
          self.stopPlayback()
        }
      }
      playbackPlayer.play()
      result(nil)
    } catch {
      stopPlayback()
      result(FlutterError(
        code: "audio_unavailable",
        message: "Unable to play local PCM.",
        details: nil
      ))
    }
  }

  private func stopPlayback() {
    playing = false
    playbackPlayer.stop()
    playbackEngine.stop()
    try? AVAudioSession.sharedInstance().setActive(
      false,
      options: .notifyOthersOnDeactivation
    )
  }

  func dispose() {
    stop()
    stopPlayback()
    eventSink = nil
    controlChannel?.setMethodCallHandler(nil)
    eventChannel?.setStreamHandler(nil)
    controlChannel = nil
    eventChannel = nil
  }

  private enum VoiceCaptureError: Error {
    case audioUnavailable
    case audioTimestampUnavailable
  }

  private struct CaptureClockAnchor {
    let wallClockUs: Int64
    let hostTime: UInt64
  }
}

private extension AVAudioPlayerNode {
  func engineIsAttached(to engine: AVAudioEngine) -> Bool {
    engine.attachedNodes.contains(self)
  }
}
