package com.motonav.app.data

import org.json.JSONObject

/** 提醒点位类型 */
enum class PoiType(val label: String, val color: Int, val voicePrefix: String) {
    RED_LIGHT("闯红灯拍照", 0xFFFF5252.toInt(), "闯红灯拍照"),
    RESTRICTION("限行/禁摩", 0xFFFFB300.toInt(), "限行禁摩路段"),
    LANE("车道拍照", 0xFF40C4FF.toInt(), "车道违章拍照");

    companion object {
        fun from(name: String?): PoiType =
            values().firstOrNull { it.name == name } ?: LANE
    }
}

/** 单个提醒点位 */
data class Poi(
    val id: Long,
    val type: PoiType,
    val name: String,
    val lat: Double,
    val lon: Double,
    val radiusM: Float = 120f,
    var enabled: Boolean = true,
    val note: String = ""
) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("id", id)
        put("type", type.name)
        put("name", name)
        put("lat", lat)
        put("lon", lon)
        put("radiusM", radiusM)
        put("enabled", enabled)
        put("note", note)
    }

    companion object {
        fun fromJson(o: JSONObject): Poi = Poi(
            id = o.optLong("id"),
            type = PoiType.from(o.optString("type")),
            name = o.optString("name", "未命名点位"),
            lat = o.optDouble("lat", 0.0),
            lon = o.optDouble("lon", 0.0),
            radiusM = o.optDouble("radiusM", 120.0).toFloat(),
            enabled = o.optBoolean("enabled", true),
            note = o.optString("note", "")
        )
    }
}
