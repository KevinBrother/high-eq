package cn.higheq.high_eq

import android.app.Activity
import android.content.Context
import com.alipay.sdk.app.PayTask
import com.tencent.mm.opensdk.modelmsg.SendAuth
import com.tencent.mm.opensdk.modelpay.PayReq
import com.tencent.mm.opensdk.openapi.WXAPIFactory
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.util.UUID

object Commerce {
    private var auth: MethodChannel.Result? = null
    private var state: String? = null
    fun wx(context: Context) = WXAPIFactory.createWXAPI(context, context.getString(R.string.wechat_app_id), true)
    fun authorized(response: SendAuth.Resp) {
        val result = auth ?: return
        if (response.state != state && response.errCode == 0) return
        auth = null; state = null
        if (response.errCode == 0 && !response.code.isNullOrBlank()) result.success(response.code)
        else result.error("cancelled", null, null)
    }
    fun install(activity: Activity, channel: MethodChannel) {
        channel.setMethodCallHandler { call, result ->
            try {
                val provider = call.argument<String>("channel")
                when (call.method) {
                    "available" -> result.success(provider == "alipay" || provider == "wechat" && wx(activity).isWXAppInstalled)
                    "authorize" -> {
                        val api = wx(activity)
                        if (call.argument<String>("provider") != "wechat" || auth != null || !api.isWXAppInstalled) {
                            result.error("unavailable", null, null); return@setMethodCallHandler
                        }
                        val request = SendAuth.Req().apply { scope = "snsapi_userinfo"; state = UUID.randomUUID().toString() }
                        state = request.state; auth = result; api.registerApp(activity.getString(R.string.wechat_app_id))
                        if (!api.sendReq(request)) { auth = null; state = null; result.error("unavailable", null, null) }
                    }
                    "pay" -> {
                        val payload = requireNotNull(call.argument<String>("payload"))
                        if (provider == "alipay") {
                            Thread {
                                val status = runCatching { PayTask(activity).payV2(payload, true)["resultStatus"] }.getOrNull()
                                activity.runOnUiThread {
                                    when(status) {
                                        "9000", "8000", "6004" -> result.success(null) // only refresh server rights
                                        "6001" -> result.error("cancelled", null, null)
                                        else -> result.error("vendor_error", null, null)
                                    }
                                }
                            }.start()
                        } else if (provider == "wechat") {
                            val p = JSONObject(payload); val id = activity.getString(R.string.wechat_app_id)
                            require(p.getString("appid") == id)
                            val req = PayReq().apply {
                                appId = id; partnerId = p.getString("partnerid"); prepayId = p.getString("prepayid")
                                packageValue = p.getString("package"); nonceStr = p.getString("noncestr")
                                timeStamp = p.getString("timestamp"); sign = p.getString("sign")
                            }
                            val api = wx(activity); api.registerApp(id)
                            if (api.sendReq(req)) result.success(null) else result.error("unavailable", null, null)
                        } else result.notImplemented()
                    }
                    else -> result.notImplemented()
                }
            } catch (_: Exception) { result.error("vendor_error", null, null) }
        }
    }
}
