package com.motonav.app.engine

import com.motonav.app.data.Poi
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

/** 命中一个提醒点位时回调 */
fun interface AlertCallback {
    fun onAlert(poi: Poi, distanceM: Double)
}

/**
 * 接近提醒引擎：根据当前位置与点位集合，判断是否触发提醒。
 * 规则：
 *  - 点位启用且距离 <= 半径 -> 触发
 *  - 冷却时间避免重复轰炸（进入后 90 秒内不重复）
 *  - 离开半径后再进入可再次触发
 */
class AlertEngine(private val callback: AlertCallback) {

    private val cooldownMs = 90_000L
    private val lastTrigger = HashMap<Long, Long>()

    /** @return 本次是否触发了某个提醒 */
    fun update(lat: Double, lon: Double, pois: List<Poi>): Boolean {
        var triggered = false
        val now = System.currentTimeMillis()
        for (p in pois) {
            if (!p.enabled) continue
            val d = distanceM(lat, lon, p.lat, p.lon)
            if (d <= p.radiusM) {
                val last = lastTrigger[p.id] ?: 0L
                if (now - last >= cooldownMs) {
                    lastTrigger[p.id] = now
                    callback.onAlert(p, d)
                    triggered = true
                }
            } else {
                // 离开范围，重置冷却，允许再次进入时重新提醒
                lastTrigger.remove(p.id)
            }
        }
        return triggered
    }

    companion object {
        private const val EARTH_R = 6371000.0

        /** Haversine 距离（米） */
        fun distanceM(lat1: Double, lon1: Double, lat2: Double, lon2: Double): Double {
            val dLat = Math.toRadians(lat2 - lat1)
            val dLon = Math.toRadians(lon2 - lon1)
            val a = sin(dLat / 2) * sin(dLat / 2) +
                cos(Math.toRadians(lat1)) * cos(Math.toRadians(lat2)) *
                sin(dLon / 2) * sin(dLon / 2)
            return EARTH_R * 2 * atan2(sqrt(a), sqrt(1 - a))
        }
    }
}
