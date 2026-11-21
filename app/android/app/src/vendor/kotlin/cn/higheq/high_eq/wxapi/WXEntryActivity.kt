package cn.higheq.high_eq.wxapi

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import cn.higheq.high_eq.Commerce
import com.tencent.mm.opensdk.modelbase.BaseReq
import com.tencent.mm.opensdk.modelbase.BaseResp
import com.tencent.mm.opensdk.modelmsg.SendAuth
import com.tencent.mm.opensdk.openapi.IWXAPIEventHandler

open class WXEntryActivity : Activity(), IWXAPIEventHandler {
    override fun onCreate(savedInstanceState: Bundle?) { super.onCreate(savedInstanceState); dispatch(intent) }
    override fun onNewIntent(intent: Intent) { super.onNewIntent(intent); dispatch(intent) }
    private fun dispatch(intent: Intent) { if (!Commerce.wx(this).handleIntent(intent, this)) finish() }
    override fun onReq(req: BaseReq) { finish() }
    override fun onResp(resp: BaseResp) { if (resp is SendAuth.Resp) Commerce.authorized(resp); finish() }
}
class WXPayEntryActivity : WXEntryActivity()
