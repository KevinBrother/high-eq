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
  private var captureSession: VoicePCMCaptureSession?
  private var eventSink: FlutterEventSink?
  private var controlChannel: FlutterMethodChannel?
  private var eventChannel: FlutterEventChannel?
  private var tapInstalled = false
  private var playing = false
  private var pendingPermission: FlutterResult?

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
    if eventSink != nil, captureSession != nil {
      stop()
    }
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    if captureSession != nil {
      stop()
    }
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
    if captureSession != nil {
      result(nil)
      return
    }

    do {
      let audioSession = AVAudioSession.sharedInstance()
      try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
      try audioSession.setActive(true, options: [])

      let input = captureEngine.inputNode
      let inputFormat = input.inputFormat(forBus: 0)
      let anchorHostTime = AVAudioTime.hostTime(
        forSeconds: ProcessInfo.processInfo.systemUptime
      )
      guard let capture = VoicePCMCaptureSession(
        inputFormat: inputFormat,
        wallClockUs: Int64(Date().timeIntervalSince1970 * 1_000_000),
        hostTime: anchorHostTime
      ) else {
        throw VoiceCaptureError.audioUnavailable
      }

      captureSession = capture
      let deliver: (VoicePCMCaptureSession.Event) -> Void = { [weak self] event in
        self?.deliverCapture(event)
      }
      input.installTap(
        onBus: 0,
        bufferSize: 1024,
        format: inputFormat
      ) { buffer, when in
        capture.receive(buffer, at: when, deliver: deliver)
      }
      tapInstalled = true
      captureEngine.prepare()
      try captureEngine.start()
      result(nil)
    } catch {
      stop()
      result(FlutterError(
        code: "audio_unavailable",
        message: "Unable to start microphone capture.",
        details: nil
      ))
    }
  }

  private func deliverCapture(_ event: VoicePCMCaptureSession.Event) {
    switch event {
    case .frames(let frames):
      for frame in frames {
        eventSink?(frame.channelEvent { FlutterStandardTypedData(bytes: $0) })
      }
    case .invalidTimestamp:
      stop()
      eventSink?(FlutterError(
        code: "capture_timestamp_invalid",
        message: "The microphone timestamp is unavailable or inconsistent.",
        details: nil
      ))
    }
  }

  private func stop() {
    captureSession?.deactivate()
    captureSession = nil
    removeCaptureTap()
    captureEngine.stop()
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
        sampleRate: VoicePCMConverter.sampleRate,
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
  }
}

private extension AVAudioPlayerNode {
  func engineIsAttached(to engine: AVAudioEngine) -> Bool {
    engine.attachedNodes.contains(self)
  }
}
