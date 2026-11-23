package cn.higheq.high_eq

import android.app.Activity
import android.app.AlertDialog
import android.os.Bundle

/** System-linked permission usage screen; never launches a collection flow. */
class HealthNotice : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        AlertDialog.Builder(this).setTitle("健康数据用途").setMessage("仅用于会员个人基线和事后复盘。心率、HRV、步数及训练状态在本机按 30 秒汇总；服务端加密保留摘要 180 天。可在我的 → 健康数据撤回，或在系统健康权限中关闭读取。拒绝不影响其他练习。")
            .setPositiveButton("关闭") { _, _ -> finish() }.setOnCancelListener { finish() }.show()
    }
}
