package cn.higheq.high_eq

import android.content.Context
import android.hardware.*
import android.os.*

/** Two actual cumulative sensor events delimit a measured interval. Never
 * manufacture idle samples; keep only a bounded foreground history in RAM. */
internal class PhoneSteps(context: Context) {
    private val sensors = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    private val handler = Handler(Looper.getMainLooper())
    private val rows = ArrayDeque<Pair<Long, List<Any>>>()
    private var active: SensorEventListener? = null
    private val finish = Runnable {
        active?.let { sensors.unregisterListener(it) }; active = null
    }
    fun observe() {
        finish.run(); handler.removeCallbacks(finish)
        val sensor = sensors.getDefaultSensor(Sensor.TYPE_STEP_COUNTER) ?: return
        val listener = object : SensorEventListener {
            var last: Pair<Long, Long>? = null
            override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
            override fun onSensorChanged(event: SensorEvent) {
                // A queued callback after stop/logout belongs to the old read.
                if (active !== this) return
                val t = System.currentTimeMillis() - (SystemClock.elapsedRealtimeNanos() - event.timestamp) / 1000000L
                val n = event.values[0].toLong()
                last?.let { (before, count) -> if (t > before && t-before <= 30000 && n >= count) {
                    rows.addLast(t to listOf("phone_steps", before, t, n-count))
                } }
                last = t to n
                while (rows.isNotEmpty() && (rows.first().first < t-900000 || rows.size > 4096)) rows.removeFirst()
            }
        }
        if (sensors.registerListener(listener, sensor, SensorManager.SENSOR_DELAY_NORMAL, handler)) {
            active = listener; handler.postDelayed(finish, 30000)
        }
    }
    fun range(from: Long, to: Long) = rows.filter { it.first > from && (it.second[1] as Long) < to }.map { it.second }
    fun clear() { finish.run(); handler.removeCallbacks(finish); rows.clear() }
}
