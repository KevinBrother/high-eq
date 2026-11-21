package cn.higheq.high_eq

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        Commerce.install(this, MethodChannel(engine.dartExecutor.binaryMessenger, "cn.higheq/mobile-commerce"))
    }
}
