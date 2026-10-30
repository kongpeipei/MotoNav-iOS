package com.motonav.app

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.graphics.Rect
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.text.InputType
import android.view.Gravity
import android.view.MenuItem
import android.view.MotionEvent
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
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.util.Locale

class MainActivity : AppCompatActivity(), LocationListener, SensorEventListener {

    private lateinit var binding: ActivityMainBinding
    private lateinit var repo: PoiRepository
    private val engine = AlertEngine { poi, dist -> onAlert(poi, dist) }
    private val voice = VoiceSpeaker(this)
    private val handler = Handler(Looper.getMainLooper())

    private var locationManager: LocationManager? = null
    private var sensorManager: SensorManager? = null
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

    /** 合肥小区/商铺联想库（内置 + 在线刷新缓存） */
    private var hfPois: List<String> = emptyList()

    private fun loadHefeiPois() {
        // 1) 本地缓存优先
        val cached = prefs.getString("hf_pois", null)
        if (cached != null) {
            try {
                val arr = org.json.JSONArray(cached)
                hfPois = (0 until arr.length()).map { arr.getString(it) }
                refreshSuggestions()
            } catch (_: Exception) { }
        }
        if (hfPois.isEmpty()) {
            try {
                val raw = assets.open("hefei_pois.json").bufferedReader().use { it.readText() }
                val arr = org.json.JSONArray(raw)
                hfPois = (0 until arr.length()).map { arr.getString(it) }
                refreshSuggestions()
            } catch (_: Exception) { }
        }
        // 2) 后台在线刷新（Overpass，失败静默保留内置）
        Thread {
            try {
                val q = "[out:json][timeout:25];" +
                    "(node[\"shop\"](31.55,116.85,32.05,117.70);" +
                    "way[\"shop\"](31.55,116.85,32.05,117.70);" +
                    "node[\"name\"~\"小区|花园|苑|家园|社区|新村|公寓|广场|商场|购物\"](31.55,116.85,32.05,117.70);" +
                    ");out tags;"
                val url = URL("https://overpass-api.de/api/interpreter")
                val conn = url.openConnection() as java.net.HttpURLConnection
                conn.requestMethod = "POST"
                conn.connectTimeout = 15000; conn.readTimeout = 15000
                conn.setRequestProperty("User-Agent", "MotoNavHelper/1.0")
                conn.setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
                conn.doOutput = true
                conn.outputStream.use { it.write("data=${java.net.URLEncoder.encode(q, "UTF-8")}".toByteArray()) }
                val body = conn.inputStream.bufferedReader().use { it.readText() }
                conn.disconnect()
                val root = org.json.JSONObject(body)
                val els = root.getJSONArray("elements")
                val names = LinkedHashSet<String>()
                for (i in 0 until els.length()) {
                    val t = els.getJSONObject(i).optJSONObject("tags")
                    val n = t?.optString("name", "")?.trim() ?: ""
                    if (n.isNotEmpty()) names.add(n)
                }
                if (names.size > 20) {
                    val list = names.toList()
                    prefs.edit().putString("hf_pois", org.json.JSONArray(list).toString()).apply()
                    handler.post { hfPois = list; refreshSuggestions() }
                }
            } catch (_: Exception) { }
        }.start()
    }

    private fun refreshSuggestions(query: String = "") {
        val q = query.trim()
        val items = (repo.all().map { it.name } + history.map { it.first } + hfPois)
            .distinct().map { displayName(it) }
            .filter { q.isEmpty() || it.contains(q, ignoreCase = true) }
            .take(60).toMutableList()
        if (q.isNotEmpty() && items.none { it.contains(q, true) }) {
            items.add(0, "🔍 在线搜索「$q」")
        }
        items.add(NAV_ITEM)
        binding.etSearch.setAdapter(
            NoFilterAdapter(this, android.R.layout.simple_dropdown_item_1line, items)
        )
    }

    /** 不过滤的联想适配器（列表已按输入预过滤，保留 🔍 / ▶ 特殊条目） */
    private class NoFilterAdapter(ctx: Context, res: Int, private val items: List<String>) :
        ArrayAdapter<String>(ctx, res, items) {
        override fun getFilter(): android.widget.Filter = object : android.widget.Filter() {
            override fun performFiltering(constraint: CharSequence?): FilterResults {
                val r = FilterResults()
                r.values = items; r.count = items.size
                return r
            }
            override fun publishResults(constraint: CharSequence?, results: FilterResults?) { }
        }
    }

    /** 联想展示简化：去掉"与XX路交口"，只显示地址名称（导航目标不变） */
    private fun displayName(name: String): String {
        if (!name.contains("交口") && !name.contains("路口") && !name.contains("交叉口")) return name
        val m = Regex("^(.*?(大道|路|街|巷|线|口))与.*(交口|路口|交叉口)$").find(name)
        if (m != null) return m.groupValues[1]
        return name.replace(Regex("(交口|路口|交叉口)$"), "")
    }

    companion object {
        private const val NAV_ITEM = "▶ 开始导航"
    }

    // ==================== 天气（Open-Meteo 免费接口） ====================

    private fun fetchWeather() {
        Thread {
            try {
                val url = URL("https://api.open-meteo.com/v1/forecast?latitude=$lastLat&longitude=$lastLon&current_weather=true&daily=temperature_2m_max,temperature_2m_min&timezone=Asia%2FShanghai&forecast_days=2")
                val conn = url.openConnection() as HttpURLConnection
                conn.connectTimeout = 10000; conn.readTimeout = 10000
                conn.setRequestProperty("User-Agent", "MotoNavHelper/1.0")
                val body = conn.inputStream.bufferedReader().use { it.readText() }
                conn.disconnect()
                val root = org.json.JSONObject(body)
                val cw = root.getJSONObject("current_weather")
                val temp = cw.getDouble("temperature")
                val code = cw.getInt("weathercode")
                val icon = weatherIcon(code)
                var tomorrow: String? = null
                try {
                    val daily = root.getJSONObject("daily")
                    val maxArr = daily.getJSONArray("temperature_2m_max")
                    val minArr = daily.getJSONArray("temperature_2m_min")
                    if (maxArr.length() > 1 && minArr.length() > 1) {
                        val tMax = maxArr.getDouble(1).toInt()
                        val tMin = minArr.getDouble(1).toInt()
                        tomorrow = "明日 $tMin~$tMax°"
                    }
                } catch (_: Exception) { }
                handler.post {
                    binding.tvWeather.visibility = android.view.View.VISIBLE
                    binding.tvWeather.text = "$icon ${temp.toInt()}°"
                    if (tomorrow != null) {
                        binding.tvTomorrow.visibility = android.view.View.VISIBLE
                        binding.tvTomorrow.text = tomorrow
                    }
                }
            } catch (_: Exception) { }
        }.start()
    }

    private fun weatherIcon(code: Int): String = when (code) {
        0 -> "☀️"
        1, 2 -> "🌤️"
        3 -> "☁️"
        45, 48 -> "🌫️"
        51, 53, 55, 56, 57 -> "🌦️"
        61, 63, 65, 66, 67 -> "🌧️"
        71, 73, 75, 77 -> "🌨️"
        80, 81, 82 -> "🌦️"
        85, 86 -> "🌨️"
        95, 96, 99 -> "⛈️"
        else -> "🌡️"
    }

    // ==================== 市区加油站（Overpass） ====================

    private fun loadGasStations(showAll: Boolean) {
        Thread {
            try {
                val q = "[out:json][timeout:25];node[\"amenity\"=\"fuel\"](31.55,116.85,32.05,117.70);out;"
                val url = URL("https://overpass-api.de/api/interpreter")
                val conn = url.openConnection() as HttpURLConnection
                conn.requestMethod = "POST"
                conn.connectTimeout = 15000; conn.readTimeout = 15000
                conn.setRequestProperty("User-Agent", "MotoNavHelper/1.0")
                conn.setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
                conn.doOutput = true
                conn.outputStream.use { it.write("data=${URLEncoder.encode(q, "UTF-8")}".toByteArray()) }
                val body = conn.inputStream.bufferedReader().use { it.readText() }
                conn.disconnect()
                val root = org.json.JSONObject(body)
                val els = root.getJSONArray("elements")
                val list = mutableListOf<Pair<Double, Double>>()
                for (i in 0 until els.length()) {
                    val e = els.getJSONObject(i)
                    val lat = e.optDouble("lat", 0.0)
                    val lon = e.optDouble("lon", 0.0)
                    if (lat != 0.0 && lon != 0.0) list.add(Pair(lat, lon))
                }
                handler.post {
                    binding.mapView.setGasStations(list)
                    if (showAll && list.isNotEmpty()) {
                        binding.mapView.fitGasStations()
                        showToast("已显示市区 ${list.size} 个加油站")
                    }
                }
            } catch (_: Exception) {
                if (showAll) handler.post { showToast("加油站数据加载失败，请检查网络") }
            }
        }.start()
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

        // 搜索框智能联想：点位名称 + 历史目的地 + 合肥小区/商铺 + 在线搜索入口 + 尾部开始导航
        loadHefeiPois()
        refreshSuggestions()
        binding.etSearch.addTextChangedListener(object : android.text.TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) { }
            override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {
                refreshSuggestions(s?.toString() ?: "")
                // 一键清除按钮：有内容时显示
                binding.btnClear.visibility =
                    if (s.isNullOrEmpty()) android.view.View.GONE else android.view.View.VISIBLE
            }
            override fun afterTextChanged(s: android.text.Editable?) { }
        })
        // 一键清除输入内容
        binding.btnClear.setOnClickListener {
            binding.etSearch.setText("")
            binding.etSearch.dismissDropDown()
            binding.btnClear.visibility = android.view.View.GONE
            binding.mapView.setCategoryResults(emptyList())
            binding.categoryRow.visibility = android.view.View.GONE
            binding.categoryChips.removeAllViews()
        }
        binding.etSearch.setOnItemClickListener { _, _, pos, _ ->
            val name = binding.etSearch.adapter.getItem(pos) as String
            when {
                name == NAV_ITEM -> {
                    hideKeyboard()
                    toggleNavigation()
                }
                name.startsWith("🔍") -> {
                    val q = name.substringAfter("「").substringBefore("」")
                    onlineSearch(q)
                }
                else -> doSearch(name)
            }
        }
        binding.btnSearch.setOnClickListener {
            val q = binding.etSearch.text.toString().trim()
            if (q.isEmpty()) { showToast("请输入目的地"); return@setOnClickListener }
            if (q.startsWith("🔍")) { onlineSearch(q.substringAfter("「").substringBefore("」")); return@setOnClickListener }
            doSearch(q)
        }
        binding.etSearch.setOnEditorActionListener { _, _, _ ->
            doSearch(binding.etSearch.text.toString())
            true
        }
        binding.btnMenu.setOnClickListener { showMenu() }
        binding.btnLocate.setOnClickListener {
            binding.mapView.setUser(lastLat, lastLon)
            binding.mapView.centerOnUser()
            showToast("已回到当前位置")
        }
        binding.btnZoomIn.setOnClickListener { binding.mapView.zoomIn() }
        binding.btnZoomOut.setOnClickListener { binding.mapView.zoomOut() }
        // 搜索预览"去这里" / 点选"导航到此处"：规划路线
        binding.btnGoHere.setOnClickListener {
            if (pendingName.isNotEmpty()) {
                planRouteTo(pendingLat, pendingLon, pendingName)
                binding.btnGoHere.visibility = android.view.View.GONE
                binding.mapView.clearPreview()
                binding.mapView.setSelected(null)
                pendingName = ""
            }
        }
        binding.btnExitNav.setOnClickListener { toggleNavigation() }
        // 加油站：拉取市区加油站并缩放显示
        binding.btnGas.setOnClickListener {
            loadGasStations(showAll = true)
            binding.mapView.setUser(lastLat, lastLon)
            binding.mapView.fitGasStations()
        }
        // 长按地图空白：添加违法拍照 / 导航到这里
        binding.mapView.onLongPress = { lat, lon -> showMapLongPressMenu(lat, lon) }
        // 长按已有点位：删除 / 导航到这里
        binding.mapView.onPoiLongPress = { poi -> showPoiManageMenu(poi) }
        // 点击点位/小区：高亮并显示"导航到此处"按钮
        binding.mapView.onPoiClick = { poi ->
            binding.mapView.setSelected(poi.id)
            setPendingNav(poi.lat, poi.lon, poi.name, "导航到此处：${poi.name}")
        }
        binding.mapView.onPlaceClick = { lat, lon, name ->
            setPendingNav(lat, lon, name, "导航到此处：${name}")
        }
        binding.mapView.onCategoryClick = { lat, lon, name ->
            // 类别结果标注点击：直接规划路线并清理类别结果
            planRouteTo(lat, lon, name)
            binding.mapView.setCategoryResults(emptyList())
            binding.categoryRow.visibility = android.view.View.GONE
            binding.categoryChips.removeAllViews()
        }
        // 预加载地图小区名称标签
        loadPlaceLabels()
        // 手机朝向传感器：驱动地图旋转 + 指南针
        sensorManager = getSystemService(Context.SENSOR_SERVICE) as SensorManager
        sensorManager?.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)?.let {
            sensorManager?.registerListener(this, it, SensorManager.SENSOR_DELAY_UI)
        }
        // 天气（Open-Meteo 免费接口，显示在 ⋯ 左侧）
        fetchWeather()
        // 后台预取加油站缓存
        loadGasStations(showAll = false)

        createNotificationChannel()
        ensurePermissions()
    }

    /** 点击搜索框以外任意位置收起键盘 */
    override fun dispatchTouchEvent(ev: MotionEvent): Boolean {
        if (ev.action == MotionEvent.ACTION_DOWN) {
            val v = currentFocus
            if (v is EditText) {
                val out = Rect()
                v.getGlobalVisibleRect(out)
                if (!out.contains(ev.rawX.toInt(), ev.rawY.toInt())) {
                    hideKeyboard()
                    v.clearFocus()
                }
            }
        }
        return super.dispatchTouchEvent(ev)
    }

    private fun hideKeyboard() {
        (getSystemService(Context.INPUT_METHOD_SERVICE) as android.view.inputmethod.InputMethodManager)
            .hideSoftInputFromWindow(binding.rootLayout.windowToken, 0)
    }

    override fun onSensorChanged(event: SensorEvent) {
        if (event.sensor.type == Sensor.TYPE_ROTATION_VECTOR && event.values.size >= 3) {
            val rot = FloatArray(9)
            SensorManager.getRotationMatrixFromVector(rot, event.values)
            val remap = FloatArray(9)
            SensorManager.remapCoordinateSystem(rot, SensorManager.AXIS_X, SensorManager.AXIS_Y, remap)
            val orient = FloatArray(3)
            SensorManager.getOrientation(remap, orient)
            val deg = (Math.toDegrees(orient[0].toDouble()) + 360.0) % 360.0
            binding.mapView.setHeading(deg.toFloat())
        }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}

    override fun onResume() {
        super.onResume()
        binding.mapView.setUser(lastLat, lastLon)
        sensorManager?.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)?.let {
            sensorManager?.registerListener(this, it, SensorManager.SENSOR_DELAY_UI)
        }
    }

    override fun onPause() {
        super.onPause()
        sensorManager?.unregisterListener(this)
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
        // v1.12：默认开启监控，不再显示"GPS 已开启"状态条
        if (!navigating) showToast("已开启监控，接近点位将语音提醒")
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

    /** 搜索预览目标（地图跳转绿色高亮，等待用户点"去这里"） */
    private var previewLat = 0.0
    private var previewLon = 0.0
    private var previewName = ""
    /** 待导航目标（搜索预览或点击地图地点） */
    private var pendingLat = 0.0
    private var pendingLon = 0.0
    private var pendingName = ""

    private fun setPendingNav(lat: Double, lon: Double, name: String, btnText: String) {
        pendingLat = lat; pendingLon = lon; pendingName = name
        binding.btnGoHere.visibility = android.view.View.VISIBLE
        binding.btnGoHere.text = btnText
    }

    private fun showPreview(lat: Double, lon: Double, name: String) {
        previewLat = lat; previewLon = lon; previewName = name
        binding.mapView.setPreview(lat, lon)
        binding.mapView.focusOn(lat, lon)
        setPendingNav(lat, lon, name, "去这里：${displayName(name)}")
        binding.tvStatus.text = "已定位到「$name」，点「去这里」规划路线"
    }

    private fun doSearch(q: String) {
        val query = q.trim()
        if (query.isEmpty()) { showToast("请输入目的地"); return }
        // 类别搜索：学校/医院/加油站 → 附近10公里所有点位高亮，点击直接规划路线
        val cat = categoryKeyword(query)
        if (cat != null) {
            binding.etSearch.dismissDropDown()
            fetchCategory(query, cat.first, cat.second)
            return
        }
        // 支持 纬度,经度
        val coord = query.split(",", "，").map { it.trim() }
        if (coord.size == 2) {
            val lat = coord[0].toDoubleOrNull()
            val lon = coord[1].toDoubleOrNull()
            if (lat != null && lon != null && lat in -90.0..90.0 && lon in -180.0..180.0) {
                showPreview(lat, lon, "坐标目的地 $lat,$lon")
                return
            }
        }
        // 在点位库中按名称匹配
        val hits = repo.all().filter { it.name.contains(query, ignoreCase = true) }
        if (hits.isNotEmpty()) {
            if (hits.size == 1) {
                val p = hits.first()
                binding.mapView.setSelected(p.id)
                showPreview(p.lat, p.lon, p.name)
            } else {
                AlertDialog.Builder(this)
                    .setTitle("选择目的地（${hits.size} 个匹配）")
                    .setItems(hits.map { "${it.name} · ${it.type.label}" }.toTypedArray()) { _, which ->
                        val p = hits[which]
                        showPreview(p.lat, p.lon, p.name)
                    }
                    .setNegativeButton("取消", null)
                    .show()
            }
            return
        }
        // 合肥小区/商铺：联想命中则在线查询坐标后预览（精确）
        if (hfPois.any { it.contains(query, ignoreCase = true) }) {
            showToast("正在查询「$query」位置…")
            Thread {
                val c = fetchNameCoordinate(query, fuzzy = false)
                handler.post {
                    if (c != null) {
                        showPreview(c.first, c.second, query)
                    } else {
                        onlineSearch(query)
                    }
                }
            }.start()
            return
        }
        // 兜底：模糊在线搜索（覆盖未收录的新小区/商铺）
        onlineSearch(query)
    }

    /** 通过 Overpass 按名称查询合肥地点坐标（纬度,经度），失败返回 null。
     *  fuzzy=true 时模糊匹配 node/way/relation（小区多为 way，精确匹配找不到时兜底） */
    private fun fetchNameCoordinate(name: String, fuzzy: Boolean = false): Pair<Double, Double>? {
        return try {
            val esc = name.replace("\\", "\\\\").replace("\"", "\\\"").replace("[", "\\[").replace("]", "\\]")
            val q = if (fuzzy)
                "[out:json][timeout:20];(node[\"name\"~\"$esc\",i](31.55,116.85,32.05,117.70);way[\"name\"~\"$esc\",i](31.55,116.85,32.05,117.70);relation[\"name\"~\"$esc\",i](31.55,116.85,32.05,117.70););out center 15;"
            else
                "[out:json][timeout:15];node[\"name\"=\"$name\"](31.55,116.85,32.05,117.70);out center 1;"
            val url = URL("https://overpass-api.de/api/interpreter")
            val conn = url.openConnection() as java.net.HttpURLConnection
            conn.requestMethod = "POST"
            conn.connectTimeout = 12000; conn.readTimeout = 12000
            conn.setRequestProperty("User-Agent", "MotoNavHelper/1.0")
            conn.setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
            conn.doOutput = true
            conn.outputStream.use { it.write("data=${java.net.URLEncoder.encode(q, "UTF-8")}".toByteArray()) }
            val body = conn.inputStream.bufferedReader().use { it.readText() }
            conn.disconnect()
            val root = org.json.JSONObject(body)
            val els = root.optJSONArray("elements") ?: return null
            // 模糊结果优先取名称完全包含关键词的
            var best: Pair<Double, Double>? = null
            var bestIsExact = false
            for (i in 0 until els.length()) {
                val e = els.getJSONObject(i)
                var lat = e.optDouble("lat", 0.0)
                var lon = e.optDouble("lon", 0.0)
                val c = e.optJSONObject("center")
                if ((lat == 0.0 || lon == 0.0) && c != null) {
                    lat = c.getDouble("lat"); lon = c.getDouble("lon")
                }
                if (lat == 0.0 || lon == 0.0) continue
                val exact = e.optJSONObject("tags")?.optString("name", "")?.contains(name, ignoreCase = true) == true
                if (exact && !bestIsExact) { best = Pair(lat, lon); bestIsExact = true }
                if (best == null) best = Pair(lat, lon)
            }
            best
        } catch (_: Exception) {
            null
        }
    }

    /** 在线搜索兜底：联想库未收录的地点（如新小区），Overpass 模糊查询后预览 */
    private fun onlineSearch(name: String) {
        showToast("正在在线搜索「$name」…")
        Thread {
            val c = fetchNameCoordinate(name, fuzzy = true)
            handler.post {
                if (c != null) {
                    showPreview(c.first, c.second, name)
                } else {
                    showToast("未找到「$name」，可尝试地图长按选点或换更短的关键词")
                }
            }
        }.start()
    }

    // ==================== 类别搜索（学校/医院/加油站，附近10公里） ====================

    /** 判断关键词是否为类别搜索，返回 (类别名, Overpass amenity 匹配式) */
    private fun categoryKeyword(q: String): Pair<String, String>? = when {
        q.contains("学校") || q.contains("中学") || q.contains("小学") || q.contains("大学") || q.contains("学院") || q.contains("幼儿园") ->
            "学校" to "school|kindergarten|college|university"
        q.contains("医院") || q.contains("诊所") || q.contains("卫生") || q.contains("卫生院") ->
            "医院" to "hospital|clinic|doctors|dentist"
        q.contains("加油站") || q.contains("油站") ->
            "加油站" to "fuel"
        else -> null
    }

    /** 拉取附近约10公里类别点位并在地图高亮 + 底部结果条（点击直接规划路线） */
    private fun fetchCategory(q: String, kind: String, amenity: String) {
        val centerLat = if (lastLat != 0.0) lastLat else 31.86
        val centerLon = if (lastLon != 0.0) lastLon else 117.28
        val dLat = 0.09; val dLon = 0.11
        val bbox = "${centerLat - dLat},${centerLon - dLon},${centerLat + dLat},${centerLon + dLon}"
        showToast("正在查找附近10公里$kind…")
        Thread {
            try {
                val qs = "[out:json][timeout:25];(node[\"amenity\"~\"$amenity\"]($bbox);way[\"amenity\"~\"$amenity\"]($bbox););out center 80;"
                val url = URL("https://overpass-api.de/api/interpreter")
                val conn = url.openConnection() as java.net.HttpURLConnection
                conn.requestMethod = "POST"
                conn.connectTimeout = 20000; conn.readTimeout = 25000
                conn.setRequestProperty("User-Agent", "MotoNavHelper/1.0")
                conn.setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
                conn.doOutput = true
                conn.outputStream.use { it.write("data=${java.net.URLEncoder.encode(qs, "UTF-8")}".toByteArray()) }
                val body = conn.inputStream.bufferedReader().use { it.readText() }
                conn.disconnect()
                val root = org.json.JSONObject(body)
                val els = root.getJSONArray("elements")
                val seen = LinkedHashMap<String, Triple<Double, Double, String>>()
                val results = mutableListOf<Triple<Double, Double, String>>()
                for (i in 0 until els.length()) {
                    val e = els.getJSONObject(i)
                    val t = e.optJSONObject("tags")
                    val n = t?.optString("name", "")?.trim() ?: ""
                    if (n.isEmpty()) continue
                    var lat = e.optDouble("lat", 0.0)
                    var lon = e.optDouble("lon", 0.0)
                    val c = e.optJSONObject("center")
                    if ((lat == 0.0 || lon == 0.0) && c != null) {
                        lat = c.getDouble("lat"); lon = c.getDouble("lon")
                    }
                    if (lat == 0.0 || lon == 0.0) continue
                    // 10公里内才保留
                    val dist = haversine(centerLat, centerLon, lat, lon)
                    if (dist > 10000) continue
                    if (seen.putIfAbsent(n, Triple(lat, lon, n)) == null) {
                        results.add(Triple(lat, lon, n))
                    }
                }
                // 按距离升序
                results.sortBy { haversine(centerLat, centerLon, it.first, it.second) }
                handler.post {
                    if (results.isEmpty()) {
                        binding.categoryChips.removeAllViews()
                        binding.categoryRow.visibility = android.view.View.GONE
                        binding.mapView.setCategoryResults(emptyList())
                        binding.tvStatus.text = "附近10公里未找到$kind"
                        return@post
                    }
                    binding.mapView.setCategoryResults(results)
                    binding.categoryChips.removeAllViews()
                    for (r in results.take(30)) {
                        val chip = android.widget.TextView(this)
                        chip.text = "${displayName(r.third)} · ${fmtDist(haversine(centerLat, centerLon, r.first, r.second))} · 导航"
                        chip.setTextColor(0xFFFFFFFF.toInt())
                        chip.textSize = 13f
                        chip.setPadding(28, 18, 28, 18)
                        chip.setBackgroundColor(0xE64C9AFF.toInt())
                        chip.setOnClickListener {
                            planRouteTo(r.first, r.second, r.third)
                            binding.categoryRow.visibility = android.view.View.GONE
                            binding.categoryChips.removeAllViews()
                            binding.mapView.setCategoryResults(emptyList())
                        }
                        binding.categoryChips.addView(chip, android.widget.LinearLayout.LayoutParams(
                            android.view.ViewGroup.LayoutParams.WRAP_CONTENT,
                            android.view.ViewGroup.LayoutParams.WRAP_CONTENT
                        ).apply { marginEnd = 20 })
                    }
                    binding.categoryRow.visibility = android.view.View.VISIBLE
                    binding.tvStatus.text = "找到 ${results.size} 个$kind，点击可直接规划路线"
                }
            } catch (e: Exception) {
                handler.post { binding.tvStatus.text = "查询${kind}失败，请稍后重试" }
            }
        }.start()
    }

    private fun fmtDist(d: Double): String =
        if (d < 1000) "${d.toInt()}m" else String.format("%.1fkm", d / 1000)

    /** Haversine 距离（米） */
    private fun haversine(lat1: Double, lon1: Double, lat2: Double, lon2: Double): Double {
        val R = 6371000.0
        val dLat = Math.toRadians(lat2 - lat1)
        val dLon = Math.toRadians(lon2 - lon1)
        val a = Math.sin(dLat / 2) * Math.sin(dLat / 2) +
                Math.cos(Math.toRadians(lat1)) * Math.cos(Math.toRadians(lat2)) *
                Math.sin(dLon / 2) * Math.sin(dLon / 2)
        return 2 * R * Math.asin(Math.sqrt(a))
    }

    /** 地图小区/商铺名称标签（带坐标，点击可导航） */
    private var placeLabels: List<Triple<Double, Double, String>> = emptyList()

    private fun loadPlaceLabels() {
        Thread {
            try {
                val q = "[out:json][timeout:30];(node[\"name\"~\"小区|花园|苑|家园|社区|新村|公寓|广场|商场|购物|中心\"](31.55,116.85,32.05,117.70);way[\"name\"~\"小区|花园|苑|家园|社区|新村|公寓|广场|商场|购物|中心\"](31.55,116.85,32.05,117.70););out center 500;"
                val url = URL("https://overpass-api.de/api/interpreter")
                val conn = url.openConnection() as java.net.HttpURLConnection
                conn.requestMethod = "POST"
                conn.connectTimeout = 20000; conn.readTimeout = 20000
                conn.setRequestProperty("User-Agent", "MotoNavHelper/1.0")
                conn.setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
                conn.doOutput = true
                conn.outputStream.use { it.write("data=${java.net.URLEncoder.encode(q, "UTF-8")}".toByteArray()) }
                val body = conn.inputStream.bufferedReader().use { it.readText() }
                conn.disconnect()
                val root = org.json.JSONObject(body)
                val els = root.getJSONArray("elements")
                val seen = LinkedHashMap<String, Triple<Double, Double, String>>()
                for (i in 0 until els.length()) {
                    val e = els.getJSONObject(i)
                    val t = e.optJSONObject("tags")
                    val n = t?.optString("name", "")?.trim() ?: ""
                    if (n.isEmpty() || n.length > 12) continue
                    var lat = e.optDouble("lat", 0.0)
                    var lon = e.optDouble("lon", 0.0)
                    val c = e.optJSONObject("center")
                    if ((lat == 0.0 || lon == 0.0) && c != null) {
                        lat = c.getDouble("lat"); lon = c.getDouble("lon")
                    }
                    if (lat == 0.0 || lon == 0.0) continue
                    seen.putIfAbsent(n, Triple(lat, lon, n))
                }
                if (seen.size > 30) {
                    handler.post {
                        placeLabels = seen.values.take(600)
                        binding.mapView.setPlaceLabels(placeLabels)
                    }
                }
            } catch (_: Exception) { }
        }.start()
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
                    val line = listOf(Pair(fromLat, fromLon), Pair(lat, lon))
                    binding.mapView.setRoute(line)
                    binding.mapView.setRoutePois(nearbyPoisOnRoute(line))
                    binding.mapView.fitRoute(line)
                    routeTurns = emptyList()
                    binding.tvStatus.text = "路线服务不可用，已显示直线到「$name」"
                } else {
                    binding.mapView.setRoute(r.points)
                    binding.mapView.fitRoute(r.points)
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
        binding.mapView.setRoute(emptyList())
        binding.mapView.setRoutePois(emptyList())
        routeTurns = emptyList()
        binding.tvStatus.text = "已清除路线"
        updateNavUI()
        if (!monitoring) binding.tvStatus.text = getString(R.string.status_waiting)
    }

    // ==================== 实时导航播报 ====================

    /** 导航态切换搜索框 / 退出导航按钮 */
    private fun updateNavUI() {
        if (navigating) {
            binding.searchRow.visibility = android.view.View.GONE
            binding.btnExitNav.visibility = android.view.View.VISIBLE
            binding.btnGoHere.visibility = android.view.View.GONE
            binding.historyRow.visibility = android.view.View.GONE
            binding.mapView.clearPreview()
        } else {
            binding.searchRow.visibility = android.view.View.VISIBLE
            binding.btnExitNav.visibility = android.view.View.GONE
            binding.historyRow.visibility = if (history.isEmpty()) android.view.View.GONE else android.view.View.VISIBLE
        }
    }

    private fun toggleNavigation() {
        if (routeTurns.isEmpty() && binding.mapView.hasRoute().not()) { showToast("请先搜索目的地并规划路线"); return }
        if (navigating) {
            navigating = false
            voice.speak("导航结束")
            showToast("导航已结束")
        } else {
            navigating = true
            startMonitoring()
            voice.speak("开始导航到$destName，全程${binding.tvStatus.text}")
            showToast("开始导航：沿路线行驶，到达自动播报")
        }
        updateNavUI()
    }

    private fun checkNavigation(lat: Double, lon: Double) {
        // 到达判定
        val toDest = distTo(lat, lon, destLat, destLon)
        if (toDest < 100.0) {
            voice.speak("已到达目的地，$destName，导航结束")
            showToast("已到达：$destName")
            navigating = false
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
                text = displayName(name)
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
        pop.menu.add(0, 9, 0, getString(R.string.menu_clear_history))
        pop.menu.add(0, 10, 0, getString(R.string.menu_clear_route))
        pop.menu.add(0, 7, 0, getString(R.string.menu_import))
        pop.menu.add(0, 8, 0, getString(R.string.menu_export))
        pop.setOnMenuItemClickListener { item -> onMenuItem(item) }
        pop.show()
    }

    private fun onMenuItem(item: MenuItem): Boolean {
        return when (item.itemId) {
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

    /** 长按已有点位：删除 / 导航到这里 */
    private fun showPoiManageMenu(poi: Poi) {
        val msg = String.format(Locale.CHINA, "类型：%s\n纬度 %.5f\n经度 %.5f", poi.type.label, poi.lat, poi.lon)
        AlertDialog.Builder(this)
            .setTitle(poi.name)
            .setMessage(msg)
            .setItems(arrayOf("导航到这里", "删除该点位")) { _, which ->
                when (which) {
                    0 -> planRouteTo(poi.lat, poi.lon, poi.name)
                    1 -> {
                        repo.remove(poi.id)
                        refreshPois()
                        binding.mapView.setSelected(null)
                        showToast("已删除：${poi.name}")
                    }
                }
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
