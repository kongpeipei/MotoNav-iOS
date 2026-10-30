package com.motonav.app.engine

import org.json.JSONArray
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.URL

/** 转向步骤：距起点里程(米) + 动作 + 方向修饰 + 位置 */
data class RouteTurn(
    val fromStartM: Int,
    val action: String,
    val modifier: String,
    val lat: Double,
    val lon: Double
)

/** 路由结果：折线点(纬度, 经度) + 距离 + 耗时 + 转向步骤 */
data class RouteResult(
    val points: List<Pair<Double, Double>>,
    val distanceM: Int,
    val durationS: Int,
    val turns: List<RouteTurn> = emptyList()
)

/**
 * 免费骑行/驾车路径规划（OSRM 公共服务，无需 API Key）。
 * 返回 null 表示网络失败或服务不可达；调用方应降级为直线显示。
 */
object RouteFetcher {

    fun fetch(startLat: Double, startLon: Double, endLat: Double, endLon: Double): RouteResult? {
        return try {
            val coord = "$startLon,$startLat;$endLon,$endLat"
            val url = URL(
                "https://router.project-osrm.org/route/v1/driving/$coord" +
                    "?overview=full&geometries=geojson&steps=true"
            )
            val conn = url.openConnection() as HttpURLConnection
            conn.connectTimeout = 8000
            conn.readTimeout = 8000
            conn.requestMethod = "GET"
            val body = BufferedReader(InputStreamReader(conn.inputStream)).use { it.readText() }
            conn.disconnect()
            parse(body)
        } catch (_: Exception) {
            null
        }
    }

    private fun parse(body: String): RouteResult? {
        val root = org.json.JSONObject(body)
        val routes = root.optJSONArray("routes")
        if (routes == null || routes.length() == 0) return null
        val r = routes.getJSONObject(0)
        val geo = r.getJSONObject("geometry").getJSONArray("coordinates")
        val pts = mutableListOf<Pair<Double, Double>>()
        for (i in 0 until geo.length()) {
            val c = geo.getJSONArray(i) // [lon, lat]
            pts.add(Pair(c.getDouble(1), c.getDouble(0)))
        }
        val turns = parseTurns(r.optJSONArray("legs"))
        return RouteResult(
            points = pts,
            distanceM = r.optInt("distance", 0),
            durationS = r.optInt("duration", 0),
            turns = turns
        )
    }

    /** 解析 legs[].steps[].maneuver，累计里程得到每个转向动作距起点的位置 */
    private fun parseTurns(legs: JSONArray?): List<RouteTurn> {
        if (legs == null || legs.length() == 0) return emptyList()
        val out = mutableListOf<RouteTurn>()
        var acc = 0
        for (i in 0 until legs.length()) {
            val leg = legs.getJSONObject(i)
            val steps = leg.optJSONArray("steps") ?: continue
            for (j in 0 until steps.length()) {
                val step = steps.getJSONObject(j)
                val mv = step.optJSONObject("maneuver") ?: continue
                val action = mv.optString("type", "")
                val modifier = mv.optString("modifier", "")
                if (action == "depart") continue
                val loc = mv.optJSONArray("location")
                val lat = if (loc != null) loc.getDouble(1) else 0.0
                val lon = if (loc != null) loc.getDouble(0) else 0.0
                acc += step.optInt("distance", 0)
                out.add(RouteTurn(acc, action, modifier, lat, lon))
            }
        }
        return out
    }
}
