package cn.higheq.high_eq

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val replyShare = ReplyShare()
    private lateinit var voiceCapture: VoiceCapture
    private var health: HealthHistory? = null

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        replyShare.receive(intent)
    }

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        replyShare.install(engine, intent)
        voiceCapture = VoiceCapture(this)
        voiceCapture.install(engine.dartExecutor.binaryMessenger)
        MethodChannel(engine.dartExecutor.binaryMessenger, "cn.higheq/health-history")
            .setMethodCallHandler { call, result ->
                if (
                    resources.getBoolean(R.bool.t28_platform_history) &&
                    android.os.Build.VERSION.SDK_INT >= 34
                ) {
                    val adapter = health ?: HealthHistory(this).also { health = it }
                    adapter.handle(call, result)
                } else if (resources.getBoolean(R.bool.t28_huawei_history)) {
                    // Report only the release channel's source. The pinned HMS
                    // plugin handles authorization and reads after Dart elects it.
                    when (call.method) {
                        "source" -> result.success("huawei_history")
                        "huaweiAppId" ->
                            result.success(resources.getString(R.string.t28_huawei_app_id))
                        "stop" -> result.success(null)
                        else -> result.success(false)
                    }
                } else {
                    when (call.method) {
                        "source", "stop" -> result.success(null)
                        else -> result.success(false)
                    }
                }
            }
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
        if (android.os.Build.VERSION.SDK_INT >= 34) health?.permissionResult(requestCode)
    }

    override fun onStop() {
        if (android.os.Build.VERSION.SDK_INT >= 34) health?.stop()
        super.onStop()
    }

    override fun onDestroy() {
        voiceCapture.dispose()
        if (android.os.Build.VERSION.SDK_INT >= 34) health?.destroy()
        super.onDestroy()
    }
}
