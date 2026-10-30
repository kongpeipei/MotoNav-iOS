package com.motonav.app.data

import android.content.Context
import com.motonav.app.BuildConfig
import org.json.JSONArray
import org.json.JSONObject

/**
 * 点位仓库：从 assets/poi.json 加载示例数据，支持增删、开关；
 * 变更可持久化到私有目录。内部存储带 appVersion：
 * 应用升级后若内置点位有更新，会自动重新加载新版内置点位。
 */
class PoiRepository(private val context: Context) {

    private val fileName = "pois.json"
    private val pois = mutableListOf<Poi>()
    private var nextId = 1000L

    fun load(): List<Poi> {
        pois.clear()
        val file = context.getFileStreamPath(fileName)
        if (file.exists()) {
            val text = file.readText()
            try {
                val obj = JSONObject(text)
                val storedVer = obj.optInt("appVersion", 0)
                if (storedVer >= BuildConfig.VERSION_CODE) {
                    val arr = obj.getJSONArray("pois")
                    pois.addAll((0 until arr.length()).map { Poi.fromJson(arr.getJSONObject(it)) })
                    nextId = (pois.maxOfOrNull { it.id } ?: 0L) + 1
                    return pois.toList()
                }
                // 内置点位升级，回退到 assets 重新加载
            } catch (_: Exception) {
                // 旧格式（纯数组），兼容解析后直接持久化
                pois.addAll(parseArray(text))
                persist()
                nextId = (pois.maxOfOrNull { it.id } ?: 0L) + 1
                return pois.toList()
            }
        }
        val raw = context.assets.open("poi.json").bufferedReader().use { it.readText() }
        pois.addAll(parseArray(raw))
        persist()
        nextId = (pois.maxOfOrNull { it.id } ?: 0L) + 1
        return pois.toList()
    }

    fun all(): List<Poi> = pois.toList()

    fun add(type: PoiType, name: String, lat: Double, lon: Double, radiusM: Float = 120f): Poi {
        val p = Poi(nextId++, type, name, lat, lon, radiusM, true)
        pois.add(p)
        persist()
        return p
    }

    fun setEnabled(id: Long, enabled: Boolean) {
        pois.firstOrNull { it.id == id }?.enabled = enabled
        persist()
    }

    /** 更新点位信息（用于坐标校准） */
    fun update(id: Long, type: PoiType, name: String, lat: Double, lon: Double, radiusM: Float): Boolean {
        val idx = pois.indexOfFirst { it.id == id }
        if (idx < 0) return false
        pois[idx] = pois[idx].copy(type = type, name = name, lat = lat, lon = lon, radiusM = radiusM)
        persist()
        return true
    }

    fun remove(id: Long) {
        pois.removeAll { it.id == id }
        persist()
    }

    /** 从 JSON 文本导入点位，自动分配新 id；返回导入条数 */
    fun importJson(text: String): Int {
        var added = 0
        for (p in parseArray(text)) {
            pois.add(p.copy(id = nextId++))
            added++
        }
        persist()
        return added
    }

    /** 导出全部点位为 JSON 文本（含启用状态） */
    fun exportJson(): String {
        val arr = JSONArray()
        pois.forEach { arr.put(it.toJson()) }
        return arr.toString(2)
    }

    private fun parseArray(text: String): List<Poi> {
        val arr = JSONArray(text)
        return (0 until arr.length()).map { Poi.fromJson(arr.getJSONObject(it)) }
    }

    private fun persist() {
        val arr = JSONArray()
        pois.forEach { arr.put(it.toJson()) }
        val wrapper = JSONObject()
        wrapper.put("appVersion", BuildConfig.VERSION_CODE)
        wrapper.put("pois", arr)
        context.openFileOutput(fileName, Context.MODE_PRIVATE).use {
            it.write(wrapper.toString().toByteArray())
        }
    }
}
