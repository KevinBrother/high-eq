package cn.higheq.high_eq

import android.app.Activity
import android.content.pm.PackageManager
import android.health.connect.*
import android.health.connect.datatypes.*
import android.health.connect.datatypes.Record
import android.os.OutcomeReceiver
import androidx.annotation.RequiresApi
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel.Result
import java.time.Instant

@RequiresApi(34)
internal class HealthHistory(private val activity: Activity) {
    private val manager = activity.getSystemService(HealthConnectManager::class.java)
    private val phone = PhoneSteps(activity)
    private val motion = "android.permission.ACTIVITY_RECOGNITION"
    private val health = arrayOf("HEART_RATE", "STEPS", "EXERCISE", "HEART_RATE_VARIABILITY").map { "android.permission.health.READ_$it" }
    private fun granted(p: String) = activity.checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED
    private fun ready() = manager != null && granted(motion) && health.take(3).all(::granted)
    private var prompt: Result? = null
    private var pending: Result? = null
    fun stop() {
        phone.clear(); pending?.error("stopped", null, null); pending = null
    }
    fun destroy() { stop(); prompt?.success(false); prompt = null }
    fun permissionResult(code: Int) {
        val result = prompt ?: return
        if (code == 2801 && granted(motion)) { requestHealth(); return }
        if (code !in 2801..2802) return
        prompt = null; result.success(ready())
    }
    private fun requestHealth() {
        if (health.all(::granted)) { permissionResult(2802); return }
        activity.requestPermissions(health.toTypedArray(), 2802)
    }
    fun handle(call: MethodCall, result: Result) {
        when(call.method) {
            "source" -> result.success(if(manager != null) "health_connect" else null)
            "queryable" -> result.success(ready())
            "request" -> if(manager == null || prompt != null) result.success(false) else {
                prompt = result
                if(granted(motion)) requestHealth() else activity.requestPermissions(arrayOf(motion), 2801)
            }
            "stop" -> { stop(); result.success(null) }
            "read" -> {
                val from = call.argument<Number>("from")?.toLong(); val to = call.argument<Number>("to")?.toLong()
                if (!ready() || from == null || to == null || to <= from || to-from > 600000 || pending != null) {
                    result.error("unavailable", null, null); return
                }
                val filter = TimeInstantRangeFilter.Builder().setStartTime(Instant.ofEpochMilli(from)).setEndTime(Instant.ofEpochMilli(to)).build()
                val rows = phone.range(from,to).toMutableList(); phone.observe(); pending = result
                val types = mutableListOf<Class<out Record>>(HeartRateRecord::class.java, StepsRecord::class.java, ExerciseSessionRecord::class.java)
                if(granted(health.last())) types.add(HeartRateVariabilityRmssdRecord::class.java)
                fun next(i: Int) {
                    if(pending !== result) return
                    if(i == types.size) { pending=null; result.success(rows); return }
                    page(types[i], filter, -1, result, rows) { next(i+1) }
                }
                next(0)
            }
            else -> result.notImplemented()
        }
    }
    private fun <T:Record> page(type:Class<T>, filter:TimeInstantRangeFilter, token:Long, result:Result,
                                 rows:MutableList<List<Any>>, done:()->Unit) {
        val req=ReadRecordsRequestUsingFilters.Builder(type).setTimeRangeFilter(filter).setPageSize(250)
        if(token != -1L) req.setPageToken(token)
        fun fail() { if(pending === result) { pending=null; result.error("health_read",null,null) } }
        try { manager!!.readRecords(req.build(),activity.mainExecutor,object:OutcomeReceiver<ReadRecordsResponse<T>,HealthConnectException>{
            override fun onError(error:HealthConnectException) = fail()
            override fun onResult(value:ReadRecordsResponse<T>) {
                if(pending !== result) return
                for(r in value.records) {
                    when(r) {
                        is HeartRateRecord -> for(s in r.samples) rows.add(listOf("heart_rate",s.time.toEpochMilli(),s.time.toEpochMilli(),s.beatsPerMinute))
                        is HeartRateVariabilityRmssdRecord -> rows.add(listOf("hrv",r.time.toEpochMilli(),r.time.toEpochMilli(),r.heartRateVariabilityMillis))
                        is StepsRecord -> rows.add(listOf("steps",r.startTime.toEpochMilli(),r.endTime.toEpochMilli(),r.count))
                        is ExerciseSessionRecord -> if(r.metadata.dataOrigin.packageName != activity.packageName) rows.add(listOf("exercise",r.startTime.toEpochMilli(),r.endTime.toEpochMilli(),1))
                    }
                    if(rows.size>8192) { fail(); return }
                }
                val next=value.nextPageToken
                if(next == -1L) done() else if(next == token) fail() else page(type,filter,next,result,rows,done)
            }
        }) } catch (_:RuntimeException) { fail() }
    }
}
