package cn.higheq.high_eq

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.AudioTimestamp
import android.media.AudioTrack
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.os.SystemClock
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.max
import kotlin.concurrent.thread

/**
 * In-memory 16 kHz mono PCM16LE capture and playback.
 *
 * This class deliberately has no file, transcription, or network path. The
 * only sink is the Flutter event channel owned by the current app process.
 */
class VoiceCapture(private val activity: Activity) :
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {
    companion object {
        const val CONTROL_CHANNEL = "cn.higheq/voice-capture"
        const val PCM_CHANNEL = "cn.higheq/voice-capture/pcm"
        const val PERMISSION_REQUEST = 2919
        private const val SAMPLE_RATE = 16000
        private const val CHANNEL_MASK = AudioFormat.CHANNEL_IN_MONO
        private const val ENCODING = AudioFormat.ENCODING_PCM_16BIT
        private const val MAX_TIMESTAMP_AGE_NANOS = 1_000_000_000L
    }

    private val main = Handler(Looper.getMainLooper())
    private val lock = Any()

    @Volatile private var eventSink: EventChannel.EventSink? = null
    @Volatile private var recording = false
    private var recorder: AudioRecord? = null
    private var captureThread: Thread? = null
    private var pendingPermission: MethodChannel.Result? = null

    @Volatile private var playing = false
    private var player: AudioTrack? = null
    private var playbackThread: Thread? = null

    fun install(messenger: BinaryMessenger) {
        MethodChannel(messenger, CONTROL_CHANNEL).setMethodCallHandler(this)
        EventChannel(messenger, PCM_CHANNEL).setStreamHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "checkPermission" -> result.success(hasPermission())
            "requestPermission" -> requestPermission(result)
            "start" -> start(result)
            "stop" -> {
                stop()
                result.success(null)
            }
            "play" -> play(call, result)
            "stopPlayback" -> {
                stopPlayback()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun hasPermission(): Boolean =
        activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED

    private fun requestPermission(result: MethodChannel.Result) {
        if (hasPermission()) {
            result.success(true)
            return
        }
        if (pendingPermission != null) {
            result.success(false)
            return
        }
        pendingPermission = result
        activity.requestPermissions(
            arrayOf(Manifest.permission.RECORD_AUDIO),
            PERMISSION_REQUEST,
        )
    }

    fun handlePermissionResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        if (requestCode != PERMISSION_REQUEST) return
        val pending = pendingPermission ?: return
        pendingPermission = null
        pending.success(
            grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED,
        )
    }

    private fun start(result: MethodChannel.Result) {
        if (!hasPermission()) {
            result.error("permission_denied", "Microphone permission is not granted.", null)
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) {
            result.error(
                "audio_unavailable",
                "Microphone hardware timestamps require Android 7.0 or newer.",
                null,
            )
            return
        }
        if (recording) {
            result.success(null)
            return
        }

        val minBuffer = AudioRecord.getMinBufferSize(SAMPLE_RATE, CHANNEL_MASK, ENCODING)
        if (minBuffer <= 0) {
            result.error("audio_unavailable", "Unable to size the microphone buffer.", null)
            return
        }
        val audioRecord = try {
            AudioRecord.Builder()
                .setAudioSource(MediaRecorder.AudioSource.MIC)
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(ENCODING)
                        .setSampleRate(SAMPLE_RATE)
                        .setChannelMask(CHANNEL_MASK)
                        .build(),
                )
                .setBufferSizeInBytes(max(minBuffer * 2, SAMPLE_RATE))
                .build()
        } catch (error: Exception) {
            result.error("audio_unavailable", "Unable to open the microphone.", null)
            return
        }
        if (audioRecord.state != AudioRecord.STATE_INITIALIZED) {
            audioRecord.release()
            result.error("audio_unavailable", "The microphone did not initialize.", null)
            return
        }

        synchronized(lock) {
            recorder = audioRecord
            recording = true
        }
        captureThread = thread(start = true, name = "high-eq-voice-capture") {
            Process.setThreadPriority(Process.THREAD_PRIORITY_AUDIO)
            val shorts = ShortArray(1600)
            val timestamp = AudioTimestamp()
            var framesRead = 0L
            val anchorWallClockUs = System.currentTimeMillis() * 1_000L
            val anchorBootNanos = SystemClock.elapsedRealtimeNanos()
            try {
                audioRecord.startRecording()
                while (recording) {
                    val blockStartFrame = framesRead
                    val read = audioRecord.read(shorts, 0, shorts.size)
                    if (read <= 0) {
                        if (read < 0) break
                        continue
                    }
                    framesRead += read.toLong()
                    val capturedAtUs = mapBlockStartToWallClock(
                        audioRecord,
                        timestamp,
                        blockStartFrame,
                        anchorWallClockUs,
                        anchorBootNanos,
                    )
                    if (capturedAtUs == null) {
                        failCapture(
                            audioRecord,
                            "capture_timestamp_invalid",
                            "The microphone timestamp is unavailable or inconsistent.",
                        )
                        break
                    }
                    val bytes = ByteArray(read * 2)
                    ByteBuffer.wrap(bytes)
                        .order(ByteOrder.LITTLE_ENDIAN)
                        .asShortBuffer()
                        .put(shorts, 0, read)
                    val event = mapOf(
                        "pcm" to bytes,
                        "captured_at_us" to capturedAtUs,
                    )
                    val sink = eventSink ?: continue
                    main.post {
                        if (recording) sink.success(event)
                    }
                }
            } catch (_: Exception) {
                if (recording) {
                    failCapture(
                        audioRecord,
                        "capture_failed",
                        "The microphone stream stopped.",
                    )
                }
            } finally {
                releaseRecorder(audioRecord)
            }
        }
        result.success(null)
    }

    private fun mapBlockStartToWallClock(
        audioRecord: AudioRecord,
        timestamp: AudioTimestamp,
        blockStartFrame: Long,
        anchorWallClockUs: Long,
        anchorBootNanos: Long,
    ): Long? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return null
        val timestampStatus: Int =
            audioRecord.getTimestamp(timestamp, AudioTimestamp.TIMEBASE_BOOTTIME)
        if (timestampStatus != AudioRecord.SUCCESS) return null
        if (timestamp.nanoTime <= 0L || timestamp.framePosition < blockStartFrame) {
            return null
        }
        val ageNanos = SystemClock.elapsedRealtimeNanos() - timestamp.nanoTime
        if (ageNanos !in 0L..MAX_TIMESTAMP_AGE_NANOS) return null
        val framesFromBlockStart = timestamp.framePosition - blockStartFrame
        val blockStartBootNanos = timestamp.nanoTime -
            (framesFromBlockStart * 1_000_000_000L / SAMPLE_RATE)
        if (blockStartBootNanos < anchorBootNanos) return null
        return anchorWallClockUs + (blockStartBootNanos - anchorBootNanos) / 1_000L
    }

    private fun failCapture(audioRecord: AudioRecord, code: String, message: String) {
        recording = false
        try {
            audioRecord.stop()
        } catch (_: Exception) {
            // The recorder may already have been stopped by the platform.
        }
        main.post {
            eventSink?.error(code, message, null)
        }
    }

    private fun stop() {
        val current: AudioRecord?
        synchronized(lock) {
            recording = false
            current = recorder
            recorder = null
        }
        try {
            current?.stop()
        } catch (_: Exception) {
            // A recorder can already be stopped by the OS.
        }
        captureThread?.interrupt()
        try {
            captureThread?.join(800)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
        captureThread = null
        if (current != null) current.release()
    }

    private fun releaseRecorder(record: AudioRecord) {
        synchronized(lock) {
            if (recorder === record) recorder = null
        }
        try {
            record.release()
        } catch (_: Exception) {
            // Release is best effort during lifecycle teardown.
        }
    }

    private fun play(call: MethodCall, result: MethodChannel.Result) {
        val pcm = call.argument<ByteArray>("pcm")
        if (pcm == null || pcm.isEmpty()) {
            result.error("invalid_pcm", "PCM data is required.", null)
            return
        }
        stopPlayback()
        val minBuffer = AudioTrack.getMinBufferSize(
            SAMPLE_RATE,
            AudioFormat.CHANNEL_OUT_MONO,
            ENCODING,
        )
        if (minBuffer <= 0) {
            result.error("audio_unavailable", "Unable to size the playback buffer.", null)
            return
        }
        val track = try {
            AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build(),
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(ENCODING)
                        .setSampleRate(SAMPLE_RATE)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                        .build(),
                )
                .setTransferMode(AudioTrack.MODE_STATIC)
                .setBufferSizeInBytes(max(minBuffer, pcm.size))
                .build()
        } catch (_: Exception) {
            result.error("audio_unavailable", "Unable to open playback.", null)
            return
        }
        val written = track.write(pcm, 0, pcm.size, AudioTrack.WRITE_BLOCKING)
        if (written <= 0) {
            track.release()
            result.error("audio_unavailable", "Unable to load playback audio.", null)
            return
        }
        synchronized(lock) {
            player = track
            playing = true
        }
        playbackThread = thread(start = true, name = "high-eq-voice-playback") {
            try {
                track.play()
                val totalFrames = written / 2
                while (playing && track.playbackHeadPosition < totalFrames) {
                    Thread.sleep(20)
                }
            } catch (_: Exception) {
                // Playback ends on stop, route changes, or device teardown.
            } finally {
                releasePlayer(track)
            }
        }
        result.success(null)
    }

    private fun stopPlayback() {
        val current: AudioTrack?
        synchronized(lock) {
            playing = false
            current = player
            player = null
        }
        try {
            current?.stop()
        } catch (_: Exception) {
            // The track may have completed already.
        }
        playbackThread?.interrupt()
        try {
            playbackThread?.join(500)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
        playbackThread = null
        current?.release()
    }

    private fun releasePlayer(track: AudioTrack) {
        synchronized(lock) {
            if (player === track) player = null
        }
        try {
            track.release()
        } catch (_: Exception) {
            // Release is best effort after playback completion.
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    fun dispose() {
        stop()
        stopPlayback()
        eventSink = null
    }
}
