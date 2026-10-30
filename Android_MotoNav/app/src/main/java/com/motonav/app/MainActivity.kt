package com.motonav.app

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.InputType
import android.view.Gravity
import android.view.MenuItem
import android.widget.ArrayAdapter
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.PopupMenu
import android.widget.TextView
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.motonav.app.databinding.ActivityMainBinding
import com.motonav.app.data.Poi
import com.motonav.app.data.PoiRepository
import com.motonav.app.data.PoiType
import com.motonav.app.engine.AlertEngine
import com.motonav.app.engine.RouteFetcher
import com.motonav.app.engine.RouteTurn
import com.motonav.app.ui.MapView
import com.motonav.app.voice.VoiceSpeaker
import java.util.Locale

class MainActivity : AppCompatActivity(), LocationListener {

    private lateinit var binding: ActivityMainBinding
    private lateinit var repo: PoiRepository
    private val engine = AlertEngine { poi, dist -> onAlert(poi, dist) }
    private val voice = VoiceSpeaker(this)
    private val handler = Handler(Looper.getMainLooper())

    private var locationManager: LocationManager? = null
    private var monitoring = false
    private var simulating = false
    private var navigating = false
    private var lastLat = 31.8120
    private var lastLon = 117.2250

    /** 启用中的点位类型（类型筛选） */
    private var enabledTypes: MutableSet<PoiType> = PoiType.values().toMutableSet()
    private var allPoiEnabled = true

    /** 当前目的地与路线 */
    private var destLat = 0.0
    private var destLon = 0.0
    private var destName = ""
    private var routeTurns: List<RouteTurn> = emptyList()
    private var lastTurnSpoken = -1

    /** 历史搜索：name|lat|lon */
    private var history: MutableList<Triple<String, Double, Double>> = mutableListOf()
    private lateinit var prefs: SharedPreferences

    private val simRunnable = object : Runnable {
        private var step = 0
        override fun run() {
            if (!simulating) return
            val pts = arrayOf(
                doubleArrayOf(31.8090, 117.2140),
                doubleArrayOf(31.8120, 117.2220),
                doubleArrayOf(31.8150, 117.2310),
                doubleArrayOf(31.8120, 117.2260),
                doubleArrayOf(31.8090, 117.2140)
            )
            val a = pts[step % pts.size]
            val b = pts[(step + 1) % pts.size]
            val t = (step % 40) / 40f
            lastLat = a[0] + (b[0] - a[0]) * t
            lastLon = a[1] + (b[1] - a[1]) * t
            step += 2
            pushPosition(lastLat, lastLon)
            handler.postDelayed(this, 300)
        }
    }

    private val permLauncher =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { granted ->
            if (granted.values.any { it }) startMonitoring() else showToast("需要定位权限才能使用")
        }

    private val importLauncher =
        registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
            if (uri != null) {
                try {
                    val text = contentResolver.openInputStream(uri)
                        ?.bufferedReader()?.use { it.readText() } ?: ""
                    val n = repo.importJson(text)
                    refreshPois()
                    showToast("导入成功：$n 条点位")
                } catch (e: Exception) {
                    showToast("导入失败：${e.message}")
                }
            }
        }

    private val exportLauncher =
        registerForActivityResult(ActivityResultContracts.CreateDocument("application/json")) { uri ->
            if (uri != null) {
                try {
                    contentResolver.openOutputStream(uri)?.use { it.write(repo.exportJson().toByteArray()) }
                    showToast("点位已导出")
                } catch (e: Exception) {
                    showToast("导出失败：${e.message}")
                }
            }
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)

        prefs = getSharedPreferences("motonav", Context.MODE_PRIVATE)
        loadHistory()

        repo = PoiRepository(this)
        repo.load()
        refreshPois()

        binding.mapView.setPois(visiblePois())

        // 搜索框智能联想：点位名称 + 历史目的地
        val suggestionItems = (repo.all().map { it.name } + history.map { it.first })
            .distinct().take(30).toTypedArray()
        binding.etSearch.setAdapter(
            ArrayAdapter(this, android.R.layout.simple_dropdown_item_1line, suggestionItems)
        )
        binding.etSearch.setOnItemClickListener { _, _, pos, _ ->
            val name = binding.etSearch.adapter.getItem(pos) as String
            doSearch(name)
        }
        binding.btnSearch.setOnClickListener { doSearch(binding.etSearch.text.toString()) }
        binding.etSearch.setOnEditorActionListener { _, _, _ ->
            doSearch(binding.etSearch.text.toString())
            true
        }
        binding.btnMenu.setOnClickListener { showMenu() }
        binding.btnNavigate.setOnClickListener { toggleNavigation() }
        binding.btnClearRoute.setOnClickListener { clearRoute() }
        binding.btnLocate.setOnClickListener {
            binding.mapView.setUser(lastLat, lastLon)
            binding.mapView.centerOnUser()
            showToast("已回到当前位置")
        }
        // 长按地图选点：添加违法拍照 / 导航到这里
        binding.mapView.onLongPress = { lat, lon -> showMapLongPressMenu(lat, lon) }

        createNotificationChannel()
        ensurePermissions()
    }

    override fun onResume() {
        super.onResume()
        binding.mapView.setUser(lastLat, lastLon)
    }

    // ==================== 权限 / 监控 ====================

    private fun ensurePermissions() {
        val perms = mutableListOf(Manifest.permission.ACCESS_FINE_LOCATION)
        if (Build.VERSION.SDK_INT >= 33) perms.add(Manifest.permission.POST_NOTIFICATIONS)
        val missing = perms.filter {
            ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
        }
        if (missing.isNotEmpty()) {
            permLauncher.launch(missing.toTypedArray())
        } else {
            startMonitoring()
        }
    }

    private fun startMonitoring() {
        if (monitoring) return
        locationManager = getSystemService(Context.LOCATION_SERVICE) as LocationManager
        val providers = listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)
        for (p in providers) {
            if (locationManager?.isProviderEnabled(p) == true) {
                try {
                    locationManager?.requestLocationUpdates(p, 1000L, 5f, this)
                } catch (_: SecurityException) { }
            }
        }
        locationManager?.getLastKnownLocation(LocationManager.GPS_PROVIDER)?.let { onLocationChanged(it) }
        monitoring = true
        binding.tvStatus.text = getString(R.string.gps_on)
        if (!navigating) showToast("开始监控，接近点位将语音提醒")
    }

    private fun stopMonitoring() {
        locationManager?.removeUpdates(this)
        locationManager = null
        monitoring = false
        binding.tvStatus.text = getString(R.string.status_waiting)
    }

    private fun toggleSimulate() {
        simulating = !simulating
        if (simulating) {
            stopMonitoring()
            handler.post(simRunnable)
            showToast("模拟测试中：虚拟位置沿样例路线移动")
        } else {
            handler.removeCallbacks(simRunnable)
        }
    }

    override fun onLocationChanged(location: Location) {
        lastLat = location.latitude
        lastLon = location.longitude
        pushPosition(lastLat, lastLon)
    }

    override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
    override fun onProviderEnabled(provider: String) {}
    override fun onProviderDisabled(provider: String) {}

    private fun pushPosition(lat: Double, lon: Double) {
        lastLat = lat; lastLon = lon
        binding.mapView.setUser(lat, lon)
        engine.update(lat, lon, visiblePois())
        if (navigating) checkNavigation(lat, lon)
    }

    private fun onAlert(poi: Poi, dist: Double) {
        val msg = String.format(Locale.CHINA, "前方约%d米%s，%s，请提前减速、注意信号灯", dist.toInt(), poi.type.voicePrefix, poi.name)
        voice.speak(msg)
        binding.tvStatus.text = msg
        binding.mapView.setSelected(poi.id)
        showToast(msg)
        notifyAlert(poi, dist)
    }

    /** 参与提醒与展示的点位（类型筛选 + 总开关） */
    private fun visiblePois(): List<Poi> {
        val all = repo.all()
        if (!allPoiEnabled) return emptyList()
        return all.filter { it.enabled && enabledTypes.contains(it.type) }
    }

    private fun refreshPois() {
        binding.mapView.setPois(visiblePois())
    }

    // ==================== 搜索与历史 ====================

    private fun doSearch(q: String) {
        val query = q.trim()
        if (query.isEmpty()) { showToast("请输入目的地"); return }
        // 支持 纬度,经度
        val coord = query.split(",", "，").map { it.trim() }
        if (coord.size == 2) {
            val lat = coord[0].toDoubleOrNull()
            val lon = coord[1].toDoubleOrNull()
            if (lat != null && lon != null && lat in -90.0..90.0 && lon in -180.0..180.0) {
                planRouteTo(lat, lon, "坐标目的地 $lat,$lon")
                return
            }
        }
        // 在点位库中按名称匹配
        val hits = repo.all().filter { it.name.contains(query, ignoreCase = true) }
        if (hits.isNotEmpty()) {
            if (hits.size == 1) {
                val p = hits.first()
                binding.mapView.setSelected(p.id)
                planRouteTo(p.lat, p.lon, p.name)
            } else {
                AlertDialog.Builder(this)
                    .setTitle("选择目的地（${hits.size} 个匹配）")
                    .setItems(hits.map { "${it.name} · ${it.type.label}" }.toTypedArray()) { _, which ->
                        val p = hits[which]
                        planRouteTo(p.lat, p.lon, p.name)
                    }
                    .setNegativeButton("取消", null)
                    .show()
            }
            return
        }
        showToast("未找到「$query」，请尝试点位名称或输入 纬度,经度")
    }

    /** 规划到任意目的地，并高亮沿途抓拍点位 */
    private fun planRouteTo(lat: Double, lon: Double, name: String) {
        destLat = lat; destLon = lon; destName = name
        addHistory(name, lat, lon)
        showToast("正在规划到「$name」…")
        val fromLat = lastLat; val fromLon = lastLon
        Thread {
            val r = RouteFetcher.fetch(fromLat, fromLon, lat, lon)
            handler.post {
                if (r == null) {
                    binding.mapView.setRoute(listOf(Pair(fromLat, fromLon), Pair(lat, lon)))
                    binding.mapView.setRoutePois(nearbyPoisOnRoute(listOf(Pair(fromLat, fromLon), Pair(lat, lon))))
                    routeTurns = emptyList()
                    binding.tvStatus.text = "路线服务不可用，已显示直线到「$name」"
                } else {
                    binding.mapView.setRoute(r.points)
                    val near = nearbyPoisOnRoute(r.points)
                    binding.mapView.setRoutePois(near)
                    routeTurns = r.turns
                    lastTurnSpoken = -1
                    val km = r.distanceM / 1000.0
                    val min = r.durationS / 60
                    binding.tvStatus.text = String.format(
                        Locale.CHINA, "到「%s」约%.1f公里，预计%d分钟，沿途抓拍点%d处，请留意",
                        name, km, min, near.size
                    )
                }
            }
        }.start()
    }

    /** 筛选距路线折线 130 米内的点位 */
    private fun nearbyPoisOnRoute(points: List<Pair<Double, Double>>): List<Poi> {
        if (points.isEmpty()) return emptyList()
        return repo.all().filter { p ->
            if (!p.enabled || !enabledTypes.contains(p.type)) return@filter false
            var min = Double.MAX_VALUE
            for (i in 0 until points.size - 1) {
                val d = distToSegment(p.lat, p.lon, points[i], points[i + 1])
                if (d < min) min = d
            }
            min <= 130.0
        }
    }

    /** 点 (plat,plon) 到线段 ab 的垂直距离（局部平面近似，米） */
    private fun distToSegment(plat: Double, plon: Double, a: Pair<Double, Double>, b: Pair<Double, Double>): Double {
        val cosLat = Math.cos(Math.toRadians(a.first))
        val x1 = (b.second - a.second) * 111320.0 * cosLat
        val y1 = (b.first - a.first) * 110540.0
        val xp = (plon - a.second) * 111320.0 * cosLat
        val yp = (plat - a.first) * 110540.0
        val len2 = x1 * x1 + y1 * y1
        if (len2 <= 0.0) return Math.hypot(xp, yp)
        val t = ((xp * x1 + yp * y1) / len2).coerceIn(0.0, 1.0)
        val cx = t * x1; val cy = t * y1
        return Math.hypot(xp - cx, yp - cy)
    }

    private fun clearRoute() {
        navigating = false
        binding.btnNavigate.text = getString(R.string.btn_navigate_start)
        binding.mapView.setRoute(emptyList())
        binding.mapView.setRoutePois(emptyList())
        routeTurns = emptyList()
        binding.tvStatus.text = "已清除路线"
    }

    // ==================== 实时导航播报 ====================

    private fun toggleNavigation() {
        if (routeTurns.isEmpty() && binding.mapView.hasRoute().not()) { showToast("请先搜索目的地并规划路线"); return }
        if (navigating) {
            navigating = false
            binding.btnNavigate.text = getString(R.string.btn_navigate_start)
            voice.speak("导航结束")
            showToast("导航已结束")
        } else {
            navigating = true
            startMonitoring()
            binding.btnNavigate.text = getString(R.string.btn_navigate_stop)
            voice.speak("开始导航到$destName，全程${binding.tvStatus.text}")
            showToast("开始导航：沿路线行驶，到达自动播报")
        }
    }

    private fun checkNavigation(lat: Double, lon: Double) {
        // 到达判定
        val toDest = distTo(lat, lon, destLat, destLon)
        if (toDest < 100.0) {
            voice.speak("已到达目的地，$destName，导航结束")
            showToast("已到达：$destName")
            navigating = false
            binding.btnNavigate.text = getString(R.string.btn_navigate_start)
            clearRoutePoisOnly()
            return
        }
        if (routeTurns.isEmpty()) return
        // 当前进度：用户到起点距离
        val progress = distTo(lat, lon, routeTurns.firstOrNull()?.lat ?: lastLat, routeTurns.firstOrNull()?.lon ?: lastLon)
        // 简单策略：按顺序找第一个距用户最近且未播报的转向
        var idx = -1
        var best = Double.MAX_VALUE
        for (i in routeTurns.indices) {
            if (i <= lastTurnSpoken) continue
            val d = distTo(lat, lon, routeTurns[i].lat, routeTurns[i].lon)
            if (d < best) { best = d; idx = i }
        }
        if (idx >= 0 && best < 150.0) {
            lastTurnSpoken = idx
            val t = routeTurns[idx]
            voice.speak(turnText(t) + "，距您${best.toInt()}米")
            binding.tvStatus.text = "导航：${turnText(t)} 距${best.toInt()}米 · 余${(toDest / 1000.0).toInt()}公里"
        }
    }

    private fun clearRoutePoisOnly() {
        binding.mapView.setRoutePois(emptyList())
    }

    private fun turnText(t: RouteTurn): String = when (t.action) {
        "turn" -> when (t.modifier) {
            "left" -> "左转"; "right" -> "右转"
            "slight left" -> "稍向左转"; "slight right" -> "稍向右转"
            "sharp left" -> "急左转"; "sharp right" -> "急右转"
            else -> "转弯"
        }
        "new name" -> "继续直行，进入新路段"
        "merge" -> "并入主路"
        "on ramp" -> "驶入匝道"
        "off ramp" -> "驶出匝道"
        "fork" -> "前方分岔，${if (t.modifier.contains("left")) "靠左" else if (t.modifier.contains("right")) "靠右" else "请减速选择车道"}"
        "end of road" -> "前方道路尽头，${if (t.modifier.contains("left")) "左转" else "右转"}"
        "continue" -> "继续直行"
        "roundabout" -> "进入环岛，按指示方向行驶"
        "uturn" -> "前方掉头"
        "arrive" -> "即将到达目的地"
        else -> "前方注意路况"
    }

    private fun distTo(alat: Double, alon: Double, blat: Double, blon: Double): Double {
        val lat1 = Math.toRadians(alat); val lat2 = Math.toRadians(blat)
        val dLat = Math.toRadians(blat - alat); val dLon = Math.toRadians(blon - alon)
        val av = Math.sin(dLat / 2) * Math.sin(dLat / 2) +
            Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLon / 2) * Math.sin(dLon / 2)
        val c = 2 * Math.atan2(Math.sqrt(av), Math.sqrt(1 - av))
        return 6371000.0 * c
    }

    // ==================== 历史搜索 ====================

    private fun loadHistory() {
        val raw = prefs.getString("history", "") ?: ""
        history.clear()
        if (raw.isNotEmpty()) {
            raw.split(";").forEach { item ->
                val parts = item.split("|")
                if (parts.size == 3) {
                    val lat = parts[1].toDoubleOrNull()
                    val lon = parts[2].toDoubleOrNull()
                    if (lat != null && lon != null) history.add(Triple(parts[0], lat, lon))
                }
            }
        }
        renderHistory()
    }

    private fun saveHistory() {
        val raw = history.take(10).joinToString(";") { "${it.first}|${it.second}|${it.third}" }
        prefs.edit().putString("history", raw).apply()
        renderHistory()
    }

    private fun addHistory(name: String, lat: Double, lon: Double) {
        history.removeAll { it.first == name && it.second == lat && it.third == lon }
        history.add(0, Triple(name, lat, lon))
        if (history.size > 10) history.removeAt(history.size - 1)
        saveHistory()
    }

    private fun renderHistory() {
        binding.historyChips.removeAllViews()
        if (history.isEmpty()) { binding.historyRow.visibility = android.view.View.GONE; return }
        binding.historyRow.visibility = android.view.View.VISIBLE
        history.forEach { (name, lat, lon) ->
            val chip = TextView(this).apply {
                text = name
                setTextColor(android.graphics.Color.WHITE)
                setBackgroundResource(android.R.drawable.editbox_background)
                textSize = 13f
                setPadding(24, 10, 24, 10)
            }
            val lp = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            )
            lp.setMargins(0, 0, 12, 0)
            chip.layoutParams = lp
            chip.setOnClickListener { planRouteTo(lat, lon, name) }
            binding.historyChips.addView(chip)
        }
    }

    private fun clearHistory() {
        history.clear()
        prefs.edit().remove("history").apply()
        renderHistory()
        showToast("历史搜索已清空")
    }

    // ==================== 右上角三点菜单 ====================

    private fun showMenu() {
        val pop = PopupMenu(this, binding.btnMenu)
        pop.menu.add(0, 1, 0, getString(if (monitoring) R.string.btn_stop else R.string.btn_start))
        pop.menu.add(0, 2, 0, if (simulating) "停止模拟" else getString(R.string.menu_simulate))
        pop.menu.add(0, 3, 0, getString(R.string.menu_add_here))
        pop.menu.add(0, 4, 0, getString(R.string.menu_manual))
        pop.menu.add(0, 5, 0, getString(if (allPoiEnabled) R.string.menu_disable_all else R.string.menu_enable_all))
        pop.menu.add(0, 6, 0, getString(R.string.menu_type_filter))
        pop.menu.add(0, 7, 0, getString(R.string.menu_import))
        pop.menu.add(0, 8, 0, getString(R.string.menu_export))
        pop.menu.add(0, 9, 0, getString(R.string.menu_clear_history))
        pop.menu.add(0, 10, 0, getString(R.string.menu_clear_route))
        pop.setOnMenuItemClickListener { item -> onMenuItem(item) }
        pop.show()
    }

    private fun onMenuItem(item: MenuItem): Boolean {
        return when (item.itemId) {
            1 -> { if (monitoring) stopMonitoring() else startMonitoring(); true }
            2 -> { toggleSimulate(); true }
            3 -> { showAddDialog(); true }
            4 -> { showManualDialog(); true }
            5 -> {
                allPoiEnabled = !allPoiEnabled
                refreshPois()
                showToast(if (allPoiEnabled) "全部点位提醒已开启" else "全部点位提醒已关闭")
                true
            }
            6 -> { showTypeFilter(); true }
            7 -> { importLauncher.launch(arrayOf("application/json", "text/plain", "*/*")); true }
            8 -> { exportLauncher.launch("motonav_pois.json"); true }
            9 -> { clearHistory(); true }
            10 -> { clearRoute(); true }
            else -> false
        }
    }

    private fun showTypeFilter() {
        val types = PoiType.values()
        val checked = BooleanArray(types.size) { enabledTypes.contains(types[it]) }
        AlertDialog.Builder(this)
            .setTitle("点位类型筛选（多选）")
            .setMultiChoiceItems(types.map { it.label }.toTypedArray(), checked) { _, which, isChecked ->
                if (isChecked) enabledTypes.add(types[which]) else enabledTypes.remove(types[which])
            }
            .setPositiveButton("确定") { _, _ ->
                refreshPois()
                showToast("已更新筛选：${enabledTypes.map { it.label }.joinToString("、")}")
            }
            .setNegativeButton("取消", null)
            .show()
    }

    // ==================== 点位增删改 ====================

    private fun showAddDialog() {
        val types = PoiType.values().map { it.label }.toTypedArray()
        AlertDialog.Builder(this)
            .setTitle("在当前位置添加点位")
            .setItems(types) { _, which ->
                val type = PoiType.values()[which]
                val name = "我的${type.label}点"
                repo.add(type, name, lastLat, lastLon)
                refreshPois()
                showToast("已添加：$name")
            }
            .setNegativeButton("取消", null)
            .show()
    }

    /** 长按地图选点后的操作菜单 */
    private fun showMapLongPressMenu(lat: Double, lon: Double) {
        AlertDialog.Builder(this)
            .setTitle("地图选点")
            .setMessage(String.format(Locale.CHINA, "纬度 %.5f\n经度 %.5f", lat, lon))
            .setItems(arrayOf("添加违法拍照", "导航到这里")) { _, which ->
                when (which) {
                    0 -> showAddPoiTypeDialog(lat, lon)
                    1 -> planRouteTo(lat, lon, "地图选点")
                }
            }
            .setNegativeButton("取消", null)
            .show()
    }

    /** 在地图选点处选择违法拍照类型并添加 */
    private fun showAddPoiTypeDialog(lat: Double, lon: Double) {
        val types = PoiType.values()
        AlertDialog.Builder(this)
            .setTitle("选择违法拍照类型")
            .setItems(types.map { it.label }.toTypedArray()) { _, which ->
                val type = types[which]
                val name = "地图新增${type.label}点"
                repo.add(type, name, lat, lon)
                refreshPois()
                showToast("已添加：$name（长按校准可编辑）")
            }
            .setNegativeButton("取消", null)
            .show()
    }

    private fun showManualDialog() {
        val nameEt = EditText(this).apply { hint = "名称（可选）" }
        val latEt = EditText(this).apply {
            hint = "纬度，如 31.8120"
            inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL
        }
        val lonEt = EditText(this).apply {
            hint = "经度，如 117.2250"
            inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL
        }
        val layout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(60, 30, 60, 0)
            addView(nameEt)
            addView(latEt)
            addView(lonEt)
        }
        AlertDialog.Builder(this)
            .setTitle("手动添加点位")
            .setView(layout)
            .setPositiveButton("下一步") { _, _ ->
                val lat = latEt.text.toString().trim().toDoubleOrNull()
                val lon = lonEt.text.toString().trim().toDoubleOrNull()
                if (lat == null || lon == null || lat !in -90.0..90.0 || lon !in -180.0..180.0) {
                    showToast("请输入合法的经纬度")
                    return@setPositiveButton
                }
                val name = nameEt.text.toString().trim().ifEmpty { "手动点位" }
                val types = PoiType.values().map { it.label }.toTypedArray()
                AlertDialog.Builder(this)
                    .setTitle("选择类型")
                    .setItems(types) { _, which ->
                        val t = PoiType.values()[which]
                        repo.add(t, name, lat, lon)
                        refreshPois()
                        showToast("已添加：$name")
                    }
                    .show()
            }
            .setNegativeButton("取消", null)
            .show()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= 26) {
            val ch = NotificationChannel(
                "ride", getString(R.string.notification_channel),
                NotificationManager.IMPORTANCE_HIGH
            )
            getSystemService(NotificationManager::class.java).createNotificationChannel(ch)
        }
    }

    private fun notifyAlert(poi: Poi, dist: Double) {
        val nm = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) return
        val n = NotificationCompat.Builder(this, "ride")
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle("前方${poi.type.voicePrefix}")
            .setContentText("${poi.name} · 距离约${dist.toInt()}米 · 请提前减速、注意信号灯")
            .setAutoCancel(true)
            .build()
        nm.notify(poi.id.toInt(), n)
    }

    private fun showToast(msg: String) {
        val toast = Toast.makeText(this, msg, Toast.LENGTH_LONG)
        toast.setGravity(Gravity.TOP or Gravity.CENTER_HORIZONTAL, 0, 180)
        toast.show()
    }

    override fun onDestroy() {
        super.onDestroy()
        stopMonitoring()
        handler.removeCallbacks(simRunnable)
        voice.shutdown()
    }
}
