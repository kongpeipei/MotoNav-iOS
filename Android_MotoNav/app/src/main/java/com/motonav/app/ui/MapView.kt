package com.motonav.app.ui

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Path
import android.util.AttributeSet
import android.util.LruCache
import android.view.GestureDetector
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import android.view.View
import com.motonav.app.data.Poi
import java.io.File
import java.net.URL
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

/**
 * 轻量地图视图（Web Mercator 投影 + OSM 瓦片底图）：
 * - 真实道路瓦片底图（OpenStreetMap 公共瓦片，内存+磁盘缓存）
 * - 以用户位置为中心，按手机朝向旋转（指南针指示正北）
 * - 点位按类型着色；点击选中、长按选点/管理、双指缩放、单指拖动
 * - 搜索预览点（绿色高亮）、市区加油站（橙色标注）
 */
class MapView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null
) : View(context, attrs) {

    private val gridPaint = Paint().apply { color = Color.parseColor("#2A3352"); style = Paint.Style.STROKE; strokeWidth = 1f }
    private val userPaint = Paint().apply { color = Color.parseColor("#3D7BFF"); style = Paint.Style.FILL }
    private val userRingPaint = Paint().apply { color = Color.parseColor("#3D7BFF"); style = Paint.Style.STROKE; strokeWidth = 2f }
    private val radiusPaint = Paint().apply { style = Paint.Style.FILL; alpha = 30 }
    private val routePaint = Paint().apply {
        color = Color.parseColor("#3D7BFF"); style = Paint.Style.STROKE
        strokeWidth = 6f; isAntiAlias = true
    }
    private val textPaint = Paint().apply { color = Color.WHITE; textSize = 26f }
    private val labelPaint = Paint().apply { color = Color.parseColor("#F1F3FA"); textSize = 24f }
    private val compassRing = Paint().apply {
        color = Color.parseColor("#CCFFFFFF"); style = Paint.Style.STROKE; strokeWidth = 2f; isAntiAlias = true
    }
    private val compassBg = Paint().apply {
        color = Color.parseColor("#CC0F1220"); style = Paint.Style.FILL; isAntiAlias = true
    }
    private val compassNeedleN = Paint().apply {
        color = Color.parseColor("#E74C3C"); style = Paint.Style.FILL; isAntiAlias = true
    }
    private val compassNeedleS = Paint().apply {
        color = Color.parseColor("#DDDDDD"); style = Paint.Style.FILL; isAntiAlias = true
    }
    private val gasPaint = Paint().apply { color = Color.parseColor("#FF9800"); style = Paint.Style.FILL }

    /** 每像素对应米数；数值越小越放大 */
    var metersPerPx = 1.8f
        private set

    /** 手机朝向（度，0=北，顺时针），地图随之旋转 */
    private var headingDeg = 0f
    private var hasHeading = false

    private var userLat = 31.8120
    private var userLon = 117.2250
    private var pois: List<Poi> = emptyList()
    private var routePois: List<Poi> = emptyList()
    private var selectedId: Long? = null
    private var route: List<Pair<Double, Double>> = emptyList()
    /** 搜索预览点（绿色高亮） */
    private var previewLat = 0.0
    private var previewLon = 0.0
    private var hasPreview = false
    /** 市区加油站（经纬度） */
    private var gasStations: List<Pair<Double, Double>> = emptyList()
    /** 地图小区/商铺名称标签（纬度,经度,名称） */
    private var placeLabels: List<Triple<Double, Double, String>> = emptyList()
    /** 类别搜索结果（学校/医院/加油站） */
    private var categoryResults: List<Triple<Double, Double, String>> = emptyList()

    /** 视图平移偏移（像素，地图层坐标系），用户拖动地图后保留 */
    private var panX = 0f
    private var panY = 0f
    private var downX = 0f
    private var downY = 0f
    private var dragging = false

    /** 当前绘制矩阵（含朝向旋转），用于触摸坐标逆变换 */
    private val viewMatrix = Matrix()
    private val invMatrix = Matrix()

    /** 点选回调 */
    var onPoiClick: ((Poi) -> Unit)? = null
    /** 长按空白处回调（纬度, 经度） */
    var onLongPress: ((Double, Double) -> Unit)? = null
    /** 长按命中已有点位回调 */
    var onPoiLongPress: ((Poi) -> Unit)? = null
    /** 点击小区/商铺标签回调（纬度, 经度, 名称） */
    var onPlaceClick: ((Double, Double, String) -> Unit)? = null
    var onCategoryClick: ((Double, Double, String) -> Unit)? = null

    // ==================== OSM 瓦片 ====================
    private val R = 6378137.0
    private val tileExecutor = Executors.newFixedThreadPool(3)
    private val tileMemory = object : LruCache<String, Bitmap>(160) {
        override fun sizeOf(key: String, value: Bitmap) = value.byteCount / 1024
    }
    private val tileDiskDir = File(context.filesDir, "osm_tiles")
    private val pendingTiles = ConcurrentHashMap.newKeySet<String>()

    private val gestureDetector = GestureDetector(
        context,
        object : GestureDetector.SimpleOnGestureListener() {
            override fun onLongPress(e: MotionEvent) {
                val s = screenToMap(e.x, e.y)
                val (lat, lon) = mapPointToLatLon(s[0], s[1])
                // 优先命中已有点位
                var best: Poi? = null
                var bestDist = Float.MAX_VALUE
                for (p in pois) {
                    val ps = toScreen(p.lat, p.lon)
                    val d = kotlin.math.hypot(s[0] - ps[0], s[1] - ps[1])
                    if (d < 70f && d < bestDist) { bestDist = d; best = p }
                }
                if (best != null) {
                    onPoiLongPress?.invoke(best)
                } else {
                    onLongPress?.invoke(lat, lon)
                }
                postInvalidate()
            }
        }
    )

    private val scaleDetector = ScaleGestureDetector(
        context,
        object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
            override fun onScale(d: ScaleGestureDetector): Boolean {
                val f = d.scaleFactor
                val newMpp = (metersPerPx / f).coerceIn(0.3f, 40f)
                if (newMpp == metersPerPx) return true
                // 以手势焦点为锚点缩放：焦点对应的地图点屏幕位置不变
                val fx = d.focusX
                val fy = d.focusY
                val anchor = screenToMap(fx, fy)
                val (fLat, fLon) = mapPointToLatLon(anchor[0], anchor[1])
                metersPerPx = newMpp
                val ns = toScreen(fLat, fLon)
                panX += (fx - ns[0])
                panY += (fy - ns[1])
                postInvalidate()
                return true
            }
        }
    )

    // ==================== Web Mercator 投影 ====================

    private fun mercY(latRad: Double): Double = Math.log(Math.tan(Math.PI / 4 + latRad / 2))

    private fun toScreen(lat: Double, lon: Double): FloatArray {
        val mx = Math.toRadians(lon)
        val my = mercY(Math.toRadians(lat))
        val mx0 = Math.toRadians(userLon)
        val my0 = mercY(Math.toRadians(userLat))
        val k = R / metersPerPx
        return floatArrayOf(
            (width / 2f + panX + ((mx - mx0) * k).toFloat()),
            (height / 2f + panY - ((my - my0) * k).toFloat())
        )
    }

    /** 屏幕坐标 → 地图层坐标（抵消朝向旋转） */
    private fun screenToMap(x: Float, y: Float): FloatArray {
        val pts = floatArrayOf(x, y)
        viewMatrix.invert(invMatrix)
        invMatrix.mapPoints(pts)
        return pts
    }

    /** 地图层坐标 → 经纬度 */
    private fun mapPointToLatLon(sx: Float, sy: Float): Pair<Double, Double> {
        val mx0 = Math.toRadians(userLon)
        val my0 = mercY(Math.toRadians(userLat))
        val mx = mx0 + (sx - (width / 2f + panX)) * metersPerPx / R
        val my = my0 - (sy - (height / 2f + panY)) * metersPerPx / R
        val lat = Math.toDegrees(2 * Math.atan(Math.exp(my)) - Math.PI / 2)
        val lon = Math.toDegrees(mx)
        return Pair(lat, lon)
    }

    /** 屏幕增量 → 地图层增量（仅旋转部分，不含平移） */
    private fun rotateDelta(dx: Float, dy: Float): FloatArray {
        val h = Math.toRadians(headingDeg.toDouble())
        val c = Math.cos(h); val s = Math.sin(h)
        return floatArrayOf((dx * c + dy * s).toFloat(), (-dx * s + dy * c).toFloat())
    }

    // ==================== 公开 API ====================

    fun setUser(lat: Double, lon: Double) {
        userLat = lat
        userLon = lon
        postInvalidate()
    }

    /** 设置手机朝向（度），驱动地图旋转与指南针 */
    fun setHeading(deg: Float) {
        headingDeg = deg
        hasHeading = true
        postInvalidate()
    }

    fun resetHeading() { hasHeading = false; headingDeg = 0f; postInvalidate() }

    /** 回到用户位置并重置缩放与平移 */
    fun centerOnUser() {
        metersPerPx = 1.8f
        panX = 0f; panY = 0f
        postInvalidate()
    }

    /** 聚焦到某点（不改变用户位置概念，仅移动视图中心） */
    fun focusOn(lat: Double, lon: Double) {
        val s = toScreen(lat, lon)
        panX += (width / 2f - s[0])
        panY += (height / 2f - s[1])
        postInvalidate()
    }

    /** 设置搜索预览点（绿色高亮），null 清除 */
    fun setPreview(lat: Double, lon: Double) {
        previewLat = lat; previewLon = lon; hasPreview = true
        postInvalidate()
    }

    fun clearPreview() { hasPreview = false; postInvalidate() }

    /** 设置市区加油站列表 */
    fun setGasStations(list: List<Pair<Double, Double>>) {
        gasStations = list
        postInvalidate()
    }

    /** 设置地图小区/商铺名称标签（纬度,经度,名称） */
    fun setPlaceLabels(list: List<Triple<Double, Double, String>>) {
        placeLabels = list
        postInvalidate()
    }

    fun setCategoryResults(list: List<Triple<Double, Double, String>>) {
        categoryResults = list
        postInvalidate()
    }

    /** 缩放地图显示所有加油站 + 当前位置 */
    fun fitGasStations() {
        val pts = mutableListOf(Pair(userLat, userLon))
        pts.addAll(gasStations)
        if (pts.size >= 2) fitPoints(pts, 80f, 120f) else centerOnUser()
    }

    /** 自动缩放使整条路线全览（同时重置平移偏移） */
    fun fitRoute(points: List<Pair<Double, Double>>) {
        if (points.size < 2) return
        fitPoints(points, 60f, 100f)
    }

    private fun fitPoints(points: List<Pair<Double, Double>>, padX: Float, padY: Float) {
        var minX2 = Float.MAX_VALUE; var maxX2 = -Float.MAX_VALUE
        var minY2 = Float.MAX_VALUE; var maxY2 = -Float.MAX_VALUE
        for (p in points) {
            val s = toScreen(p.first, p.second)
            if (s[0] < minX2) minX2 = s[0]
            if (s[0] > maxX2) maxX2 = s[0]
            if (s[1] < minY2) minY2 = s[1]
            if (s[1] > maxY2) maxY2 = s[1]
        }
        val spanX = (maxX2 - minX2).coerceAtLeast(10f)
        val spanY = (maxY2 - minY2).coerceAtLeast(10f)
        val targetX = (width - padX * 2).coerceAtLeast(120f)
        val targetY = (height - padY * 2).coerceAtLeast(120f)
        val f = Math.min(targetX / spanX, targetY / spanY)
        metersPerPx = (metersPerPx / f).coerceIn(0.3f, 40f)
        // 缩放后重算中点，平移居中
        var minX = Float.MAX_VALUE; var maxX = -Float.MAX_VALUE
        var minY = Float.MAX_VALUE; var maxY = -Float.MAX_VALUE
        for (p in points) {
            val s = toScreen(p.first, p.second)
            if (s[0] < minX) minX = s[0]
            if (s[0] > maxX) maxX = s[0]
            if (s[1] < minY) minY = s[1]
            if (s[1] > maxY) maxY = s[1]
        }
        panX += (width / 2f - (minX + maxX) / 2)
        panY += (height / 2f - (minY + maxY) / 2)
        postInvalidate()
    }

    fun setPois(list: List<Poi>) {
        pois = list
        postInvalidate()
    }

    /** 高亮显示路线沿途的点位（违法抓拍提示） */
    fun setRoutePois(list: List<Poi>) {
        routePois = list
        postInvalidate()
    }

    /** 设置导航折线（纬度, 经度），空列表清除路线 */
    fun setRoute(points: List<Pair<Double, Double>>) {
        route = points
        postInvalidate()
    }

    /** 是否已有路线 */
    fun hasRoute(): Boolean = route.size >= 2

    fun setSelected(id: Long?) {
        selectedId = id
        postInvalidate()
    }

    // ==================== 瓦片加载 ====================

    private fun tileZoom(): Int {
        val lat0 = Math.toRadians(userLat)
        val z = Math.log(156543.03392 * Math.cos(lat0) / metersPerPx) / Math.log(2.0)
        return z.toInt().coerceIn(3, 19)
    }

    private fun tileKey(z: Int, x: Int, y: Int) = "$z/$x/$y"

    private fun loadTile(z: Int, x: Int, y: Int) {
        val key = tileKey(z, x, y)
        if (pendingTiles.contains(key)) return
        pendingTiles.add(key)
        val disk = File(tileDiskDir, "$key.png")
        if (disk.exists()) {
            val bmp = BitmapFactory.decodeFile(disk.absolutePath)
            if (bmp != null) tileMemory.put(key, bmp)
            pendingTiles.remove(key)
            postInvalidate()
            return
        }
        tileExecutor.execute {
            try {
                val url = URL("https://tile.openstreetmap.org/$key.png")
                val conn = url.openConnection()
                conn.setRequestProperty("User-Agent", "MotoNavHelper/1.0")
                conn.connectTimeout = 8000
                conn.readTimeout = 8000
                val bmp = BitmapFactory.decodeStream(conn.inputStream)
                conn.inputStream.close()
                if (bmp != null) {
                    tileMemory.put(key, bmp)
                    disk.parentFile?.mkdirs()
                    try { disk.outputStream().use { bmp.compress(Bitmap.CompressFormat.PNG, 90, it) } } catch (_: Exception) { }
                }
            } catch (_: Exception) { }
            pendingTiles.remove(key)
            postInvalidate()
        }
    }

    /** 绘制 OSM 瓦片（在当前旋转坐标系内） */
    private fun drawTiles(canvas: Canvas) {
        if (width <= 0 || height <= 0) return
        val z = tileZoom()
        val my0 = mercY(Math.toRadians(userLat))
        val n = 1 shl z
        val tileXf = (userLon + 180.0) / 360.0 * n
        val tileYf = (1.0 - my0 / Math.PI) / 2.0 * n
        val cx = width / 2f + panX
        val cy = height / 2f + panY
        val x0 = Math.floor(tileXf - cx / 256.0).toInt()
        val x1 = Math.floor(tileXf + (width - cx) / 256.0).toInt()
        val y0 = Math.floor(tileYf - cy / 256.0).toInt()
        val y1 = Math.floor(tileYf + (height - cy) / 256.0).toInt()
        for (tx in x0..x1) {
            for (ty in y0..y1) {
                val wx = ((tx % n) + n) % n
                val wy = ((ty % n) + n) % n
                val key = tileKey(z, wx, wy)
                val bmp = tileMemory.get(key)
                if (bmp != null) {
                    val dx = (cx + (tx - tileXf) * 256.0).toFloat()
                    val dy = (cy + (ty - tileYf) * 256.0).toFloat()
                    canvas.drawBitmap(bmp, dx, dy, null)
                } else {
                    loadTile(z, wx, wy)
                }
            }
        }
    }

    // ==================== 绘制 ====================

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        canvas.drawColor(Color.parseColor("#0F1220"))
        canvas.save()
        if (hasHeading) {
            canvas.rotate(headingDeg, width / 2f, height / 2f)
        }
        canvas.getMatrix(viewMatrix)
        drawTiles(canvas)
        drawGrid(canvas)
        drawRoute(canvas)
        pois.forEach { drawPoi(canvas, it) }
        drawGasStations(canvas)
        drawPlaceLabels(canvas)
        drawCategoryResults(canvas)
        drawPreview(canvas)
        drawUser(canvas)
        canvas.restore()
        drawCompass(canvas)
    }

    private fun drawRoute(canvas: Canvas) {
        if (route.size < 2) return
        val path = Path()
        route.forEachIndexed { i, (lat, lon) ->
            val s = toScreen(lat, lon)
            if (i == 0) path.moveTo(s[0], s[1]) else path.lineTo(s[0], s[1])
        }
        val under = Paint().apply {
            color = Color.parseColor("#AAFFFFFF"); style = Paint.Style.STROKE
            strokeWidth = 10f; isAntiAlias = true
        }
        canvas.drawPath(path, under)
        canvas.drawPath(path, routePaint)
        val startPaint = Paint().apply { color = Color.parseColor("#2ECC71"); style = Paint.Style.FILL }
        val endPaint = Paint().apply { color = Color.parseColor("#E74C3C"); style = Paint.Style.FILL }
        val ring = Paint().apply { color = Color.WHITE; style = Paint.Style.STROKE; strokeWidth = 2f }
        route.firstOrNull()?.let { (lat, lon) ->
            val s = toScreen(lat, lon)
            canvas.drawCircle(s[0], s[1], 9f, startPaint)
            canvas.drawCircle(s[0], s[1], 9f, ring)
            canvas.drawText("起", s[0] - 7f, s[1] + 7f, Paint().apply {
                color = Color.WHITE; textSize = 20f; isFakeBoldText = true
            })
        }
        route.lastOrNull()?.let { (lat, lon) ->
            val s = toScreen(lat, lon)
            canvas.drawCircle(s[0], s[1], 9f, endPaint)
            canvas.drawCircle(s[0], s[1], 9f, ring)
            canvas.drawText("终", s[0] - 7f, s[1] + 7f, Paint().apply {
                color = Color.WHITE; textSize = 20f; isFakeBoldText = true
            })
        }
    }

    private fun drawGrid(canvas: Canvas) {
        // 仅在无瓦片时绘制网格兜底
        if (tileMemory.size() > 0) return
        val step = 80f
        var x = 0f
        while (x < width) { canvas.drawLine(x, 0f, x, height.toFloat(), gridPaint); x += step }
        var y = 0f
        while (y < height) { canvas.drawLine(0f, y, width.toFloat(), y, gridPaint); y += step }
    }

    private fun drawPoi(canvas: Canvas, p: Poi) {
        val s = toScreen(p.lat, p.lon)
        if (s[0] < -80 || s[0] > width + 80 || s[1] < -80 || s[1] > height + 80) return
        val r = (p.radiusM / metersPerPx).coerceAtMost(260f)
        radiusPaint.color = p.type.color
        canvas.drawCircle(s[0], s[1], r, radiusPaint)
        val isSelected = p.id == selectedId
        val isOnRoute = routePois.any { it.id == p.id }
        val ring = Paint().apply {
            color = p.type.color
            style = if (isSelected || isOnRoute) Paint.Style.FILL else Paint.Style.STROKE
            strokeWidth = 3f
        }
        if (isOnRoute) {
            val hl = Paint().apply { color = Color.WHITE; style = Paint.Style.STROKE; strokeWidth = 3f }
            canvas.drawCircle(s[0], s[1], 19f, hl)
        }
        canvas.drawCircle(s[0], s[1], 14f, ring)
        val c = p.type.label.first().toString()
        canvas.drawText(c, s[0] - textPaint.measureText(c) / 2, s[1] + 8f, Paint().apply {
            color = Color.WHITE; textSize = 22f; isFakeBoldText = true
        })
        labelPaint.color = p.type.color
        canvas.drawText(p.name, s[0] + 20f, s[1] - 16f, labelPaint)
    }

    /** 加油站：橙色圆点 + 油字 */
    private fun drawGasStations(canvas: Canvas) {        for ((lat, lon) in gasStations) {
            val s = toScreen(lat, lon)
            if (s[0] < -40 || s[0] > width + 40 || s[1] < -40 || s[1] > height + 40) continue
            canvas.drawCircle(s[0], s[1], 13f, gasPaint)
            canvas.drawCircle(s[0], s[1], 13f, Paint().apply {
                color = Color.WHITE; style = Paint.Style.STROKE; strokeWidth = 2f
            })
            canvas.drawText("油", s[0] - 7f, s[1] + 6f, Paint().apply {
                color = Color.WHITE; textSize = 20f; isFakeBoldText = true
            })
        }
    }

    /** 地图小区/商铺名称标签（放大地图后显示，浅色小字，点击可导航） */
    private fun drawPlaceLabels(canvas: Canvas) {
        if (metersPerPx > 6f || placeLabels.isEmpty()) return
        val bg = Paint().apply {
            color = Color.parseColor("#66000000"); style = Paint.Style.FILL; isAntiAlias = true
        }
        val txt = Paint().apply {
            color = Color.parseColor("#DDFFFFFF"); textSize = 22f; isAntiAlias = true
        }
        for ((lat, lon, name) in placeLabels) {
            val s = toScreen(lat, lon)
            if (s[0] < -120 || s[0] > width + 120 || s[1] < -40 || s[1] > height + 40) continue
            val w = txt.measureText(name) + 12f
            canvas.drawRoundRect(s[0] - w / 2, s[1] - 38f, s[0] + w / 2, s[1] - 16f, 8f, 8f, bg)
            canvas.drawText(name, s[0] - txt.measureText(name) / 2, s[1] - 20f, txt)
            canvas.drawCircle(s[0], s[1] - 4f, 3f, Paint().apply {
                color = Color.parseColor("#88FFFFFF"); style = Paint.Style.FILL
            })
        }
    }

    /** 类别搜索结果（学校/医院/加油站）：彩色圆标 + 名称块，任意缩放级别显示 */
    private fun drawCategoryResults(canvas: Canvas) {
        if (categoryResults.isEmpty()) return
        for ((lat, lon, name) in categoryResults) {
            val s = toScreen(lat, lon)
            if (s[0] < -160 || s[0] > width + 160 || s[1] < -60 || s[1] > height + 60) continue
            val ring = Paint().apply {
                color = Color.parseColor("#2ECC71"); style = Paint.Style.FILL; isAntiAlias = true
            }
            canvas.drawCircle(s[0], s[1], 22f, Paint().apply {
                color = Color.parseColor("#332ECC71"); style = Paint.Style.FILL
            })
            canvas.drawCircle(s[0], s[1], 9f, ring)
            canvas.drawCircle(s[0], s[1], 3f, Paint().apply {
                color = Color.WHITE; style = Paint.Style.FILL
            })
            val bg = Paint().apply {
                color = Color.parseColor("#D9000000"); style = Paint.Style.FILL; isAntiAlias = true
            }
            val txt = Paint().apply {
                color = Color.WHITE; textSize = 21f; isAntiAlias = true
            }
            val w = txt.measureText(name) + 12f
            canvas.drawRoundRect(s[0] - w / 2, s[1] + 14f, s[0] + w / 2, s[1] + 36f, 8f, 8f, bg)
            canvas.drawText(name, s[0] - txt.measureText(name) / 2, s[1] + 31f, txt)
        }
    }

    /** 搜索预览点：绿色高亮圆标 */
    private fun drawPreview(canvas: Canvas) {
        if (!hasPreview) return
        val s = toScreen(previewLat, previewLon)
        val glow = Paint().apply {
            color = Color.parseColor("#2ECC71"); style = Paint.Style.FILL; alpha = 45
        }
        val ring = Paint().apply {
            color = Color.parseColor("#2ECC71"); style = Paint.Style.STROKE; strokeWidth = 3f
        }
        canvas.drawCircle(s[0], s[1], 34f, glow)
        canvas.drawCircle(s[0], s[1], 16f, Paint().apply {
            color = Color.parseColor("#2ECC71"); style = Paint.Style.FILL
        })
        canvas.drawCircle(s[0], s[1], 16f, ring)
        canvas.drawCircle(s[0], s[1], 5f, Paint().apply { color = Color.WHITE; style = Paint.Style.FILL })
    }

    /** 当前位置：箭头指向手机朝向（地图已旋转，箭头画朝北，屏幕显示朝手机方向） */
    private fun drawUser(canvas: Canvas) {
        val cx = width / 2f
        val cy = height / 2f
        val prec = Paint().apply { color = Color.parseColor("#3D7BFF"); style = Paint.Style.FILL; alpha = 22 }
        canvas.drawCircle(cx, cy, 34f, prec)
        canvas.drawCircle(cx, cy, 28f, userRingPaint)
        val arrow = Path()
        arrow.moveTo(cx, cy - 22f)
        arrow.lineTo(cx - 10f, cy + 8f)
        arrow.lineTo(cx, cy + 2f)
        arrow.lineTo(cx + 10f, cy + 8f)
        arrow.close()
        canvas.drawPath(arrow, userPaint)
        canvas.drawCircle(cx, cy, 5f, Paint().apply {
            color = Color.WHITE; style = Paint.Style.FILL
        })
    }

    /** 左上角指南针：指针指示正北（手机朝向上方时指针指向上） */
    private fun drawCompass(canvas: Canvas) {
        val r = 42f
        val cx = r + 18f
        val cy = r + 18f
        canvas.drawCircle(cx, cy, r, compassBg)
        canvas.drawCircle(cx, cy, r, compassRing)
        canvas.save()
        canvas.rotate(headingDeg, cx, cy)
        val north = Path()
        north.moveTo(cx, cy - r + 10f)
        north.lineTo(cx - 9f, cy + 6f)
        north.lineTo(cx, cy - 2f)
        north.lineTo(cx + 9f, cy + 6f)
        north.close()
        canvas.drawPath(north, compassNeedleN)
        val south = Path()
        south.moveTo(cx, cy + r - 10f)
        south.lineTo(cx - 7f, cy - 4f)
        south.lineTo(cx, cy + 2f)
        south.lineTo(cx + 7f, cy - 4f)
        south.close()
        canvas.drawPath(south, compassNeedleS)
        canvas.restore()
        canvas.drawCircle(cx, cy, 3f, Paint().apply { color = Color.WHITE; style = Paint.Style.FILL })
        canvas.drawText("N", cx - 8f, cy - r + 8f, Paint().apply {
            color = Color.WHITE; textSize = 20f; isFakeBoldText = true
        })
    }

    // ==================== 手势 ====================

    override fun onTouchEvent(event: MotionEvent): Boolean {
        gestureDetector.onTouchEvent(event)
        scaleDetector.onTouchEvent(event)
        when (event.action) {
            MotionEvent.ACTION_DOWN -> {
                downX = event.x; downY = event.y
                dragging = false
                return true
            }
            MotionEvent.ACTION_MOVE -> {
                val dx = event.x - downX
                val dy = event.y - downY
                if (scaleDetector.isInProgress) { downX = event.x; downY = event.y; return true }
                if (kotlin.math.hypot(dx.toDouble(), dy.toDouble()) > 8.0) dragging = true
                if (dragging) {
                    val d = rotateDelta(dx, dy)
                    panX += d[0]; panY += d[1]
                    downX = event.x; downY = event.y
                    postInvalidate()
                }
                return true
            }
            MotionEvent.ACTION_UP -> {
                if (dragging || scaleDetector.isInProgress) { dragging = false; return true }
                val s = screenToMap(event.x, event.y)
                var best: Poi? = null
                var bestDist = Float.MAX_VALUE
                for (p in pois) {
                    val ps = toScreen(p.lat, p.lon)
                    val d = kotlin.math.hypot(s[0] - ps[0], s[1] - ps[1])
                    if (d < 60f && d < bestDist) { bestDist = d; best = p }
                }
                if (best != null) {
                    selectedId = best.id
                    onPoiClick?.invoke(best)
                    postInvalidate()
                    return true
                }
                // 未命中点位：尝试命中类别结果（学校/医院/加油站，任意缩放级别）
                if (categoryResults.isNotEmpty()) {
                    var bestCat: Triple<Double, Double, String>? = null
                    var bestD = Float.MAX_VALUE
                    for (p in categoryResults) {
                        val ps = toScreen(p.first, p.second)
                        val d = kotlin.math.hypot(s[0] - ps[0], s[1] - ps[1])
                        if (d < 55f && d < bestD) { bestD = d; bestCat = p }
                    }
                    if (bestCat != null) {
                        onCategoryClick?.invoke(bestCat.first, bestCat.second, bestCat.third)
                        postInvalidate()
                        return true
                    }
                }
                // 未命中点位：尝试命中小区/商铺标签
                if (metersPerPx <= 6f) {
                    var bestPlace: Triple<Double, Double, String>? = null
                    var bestD = Float.MAX_VALUE
                    for (p in placeLabels) {
                        val ps = toScreen(p.first, p.second)
                        val d = kotlin.math.hypot(s[0] - ps[0], s[1] - ps[1])
                        if (d < 55f && d < bestD) { bestD = d; bestPlace = p }
                    }
                    if (bestPlace != null) {
                        onPlaceClick?.invoke(bestPlace.first, bestPlace.second, bestPlace.third)
                        postInvalidate()
                        return true
                    }
                }
            }
        }
        return super.onTouchEvent(event)
    }

    fun zoomIn() { metersPerPx = (metersPerPx * 0.6f).coerceAtLeast(0.3f); postInvalidate() }
    fun zoomOut() { metersPerPx = (metersPerPx * 1.6f).coerceAtMost(40f); postInvalidate() }
}
