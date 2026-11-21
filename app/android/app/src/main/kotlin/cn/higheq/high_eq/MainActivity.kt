package cn.higheq.high_eq

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val replyShare = ReplyShare()
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        replyShare.receive(intent)
    }
    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        replyShare.install(engine, intent)
        Commerce.install(this, MethodChannel(engine.dartExecutor.binaryMessenger, "cn.higheq/mobile-commerce"))
    }
}
