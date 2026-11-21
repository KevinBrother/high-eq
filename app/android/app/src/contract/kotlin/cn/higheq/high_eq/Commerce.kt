package cn.higheq.high_eq

import android.app.Activity
import io.flutter.plugin.common.MethodChannel

// No vendor libraries, identifiers or accounts in the default build.
object Commerce {
    fun install(activity: Activity, channel: MethodChannel) {
        channel.setMethodCallHandler { call, reply ->
            if (call.method == "available") reply.success(false)
            else reply.error("unavailable", null, null)
        }
    }
}
