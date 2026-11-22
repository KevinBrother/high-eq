package cn.higheq.high_eq

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val replyShare = ReplyShare()
    private lateinit var voiceCapture: VoiceCapture

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        replyShare.receive(intent)
    }

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        replyShare.install(engine, intent)
        voiceCapture = VoiceCapture(this)
        voiceCapture.install(engine.dartExecutor.binaryMessenger)
        Commerce.install(
            this,
            MethodChannel(engine.dartExecutor.binaryMessenger, "cn.higheq/mobile-commerce"),
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        voiceCapture.handlePermissionResult(requestCode, permissions, grantResults)
    }

    override fun onDestroy() {
        voiceCapture.dispose()
        super.onDestroy()
    }
}
