package cn.higheq.high_eq

import android.content.Intent
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** One pending draft, owned by this Activity. Never follow URIs or inspect ClipData. */
internal class ReplyShare {
    private var pending: String? = null
    private var channel: MethodChannel? = null

    fun install(engine: FlutterEngine, intent: Intent?) {
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, "cn.higheq/reply-share").apply {
            setMethodCallHandler { call, result ->
                if (call.method == "take") {
                    val text = pending
                    pending = null
                    result.success(text)
                } else result.notImplemented()
            }
        }
        receive(intent)
    }

    fun receive(intent: Intent?) {
        if (intent?.action != Intent.ACTION_SEND || intent.type != "text/plain") return
        val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
        intent.removeExtra(Intent.EXTRA_TEXT)
        intent.action = null
        if (text.isNullOrBlank() || text.length > 65536) return
        pending = text
        channel?.invokeMethod("available", null)
    }
}
