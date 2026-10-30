package com.motonav.app.ui

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.util.AttributeSet
import android.view.MotionEvent
import android.view.View
import com.motonav.app.data.Poi

/**
 * 轻量本地地图视图：
 * 以用户位置为中心，用等距圆柱投影把经纬度转成屏幕坐标，
 * 画网格、当前位置、点位（按类型着色），支持点击选中点位。
 */
class MapView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null
) : View(context, attrs) {

    private val gridPaint = Paint().apply { color = Color.parseColor("#232A45"); style = Paint.Style.STROKE; strokeWidth = 1f }
    private val roadPaint = Paint().apply { color = Color.parseColor("#2A3352"); style = Paint.Style.STROKE; strokeWidth = 2f }
    private val userPaint = Paint().apply { color = Color.parseColor("#3D7BFF"); style = Paint.Style.FILL }
    private val userRingPaint = Paint().apply { color = Color.parseColor("#3D7BFF"); style = Paint.Style.STROKE; strokeWidth = 2f }
    private val radiusPaint = Paint().apply { style = Paint.Style.FILL; alpha = 30 }
    private val routePaint = Paint().apply {
        color = Color.parseColor("#3D7BFF"); style = Paint.Style.STROKE
        strokeWidth = 6f; isAntiAlias = true
    }
    private val routeEndPaint = Paint().apply {
        color = Color.WHITE; style = Paint.Style.FILL
    }
    private val textPaint = Paint().apply { color = Color.WHITE; textSize = 26f }
    private val labelPaint = Paint().apply { color = Color.parseColor("#F1F3FA"); textSize = 24f }

    /** 每像素对应米数；数值越小越放大 */
    var metersPerPx = 1.8f
        private set

    private var userLat = 31.8120
    private var userLon = 117.2250
    private var pois: List<Poi> = emptyList()
    private var routePois: List<Poi> = emptyList()
    private var selectedId: Long? = null
    private var route: List<Pair<Double, Double>> = emptyList()

    /** 点选回调 */
    var onPoiClick: ((Poi) -> Unit)? = null

    fun setUser(lat: Double, lon: Double) {
        userLat = lat
        userLon = lon
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

    private fun toScreen(lat: Double, lon: Double): FloatArray {
        val cx = width / 2f
        val cy = height / 2f
        val dLon = (lon - userLon) * 111320.0 / metersPerPx
        val dLat = (lat - userLat) * 110540.0 / metersPerPx
        return floatArrayOf(cx + dLon.toFloat(), cy - dLat.toFloat())
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        canvas.drawColor(Color.parseColor("#0F1220"))
        drawGrid(canvas)
        drawRoads(canvas)
        drawRoute(canvas)
        pois.forEach { drawPoi(canvas, it) }
        drawUser(canvas)
    }

    private fun drawRoute(canvas: Canvas) {
        if (route.size < 2) return
        val path = android.graphics.Path()
        route.forEachIndexed { i, (lat, lon) ->
            val s = toScreen(lat, lon)
            if (i == 0) path.moveTo(s[0], s[1]) else path.lineTo(s[0], s[1])
        }
        canvas.drawPath(path, routePaint)
        route.firstOrNull()?.let { (lat, lon) ->
            val s = toScreen(lat, lon)
            canvas.drawCircle(s[0], s[1], 8f, routeEndPaint)
        }
        route.lastOrNull()?.let { (lat, lon) ->
            val s = toScreen(lat, lon)
            canvas.drawCircle(s[0], s[1], 8f, routeEndPaint)
        }
    }

    private fun drawGrid(canvas: Canvas) {
        val step = 80f
        var x = 0f
        while (x < width) { canvas.drawLine(x, 0f, x, height.toFloat(), gridPaint); x += step }
        var y = 0f
        while (y < height) { canvas.drawLine(0f, y, width.toFloat(), y, gridPaint); y += step }
    }

    private fun drawRoads(canvas: Canvas) {
        // 几条示意道路，纯装饰
        canvas.drawLine(0f, height * 0.42f, width.toFloat(), height * 0.38f, roadPaint)
        canvas.drawLine(0f, height * 0.66f, width.toFloat(), height * 0.70f, roadPaint)
        canvas.drawLine(width * 0.30f, 0f, width * 0.34f, height.toFloat(), roadPaint)
        canvas.drawLine(width * 0.72f, 0f, width * 0.68f, height.toFloat(), roadPaint)
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
            // 沿途点位：外圈白色描边 + 放大，突出显示
            val hl = Paint().apply { color = Color.WHITE; style = Paint.Style.STROKE; strokeWidth = 3f }
            canvas.drawCircle(s[0], s[1], 19f, hl)
        }
        canvas.drawCircle(s[0], s[1], 14f, ring)
        textPaint.color = p.type.color
        // 类型图标（首字）
        val c = p.type.label.first().toString()
        canvas.drawText(c, s[0] - textPaint.measureText(c) / 2, s[1] + 8f, Paint().apply {
            color = Color.WHITE; textSize = 22f; isFakeBoldText = true
        })
        labelPaint.color = p.type.color
        canvas.drawText(p.name, s[0] + 20f, s[1] - 16f, labelPaint)
    }

    private fun drawUser(canvas: Canvas) {
        val cx = width / 2f
        val cy = height / 2f
        canvas.drawCircle(cx, cy, 26f, userRingPaint)
        canvas.drawCircle(cx, cy, 10f, userPaint)
        canvas.drawText("我", cx - 7f, cy + 6f, Paint().apply {
            color = Color.WHITE; textSize = 22f; isFakeBoldText = true
        })
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (event.action == MotionEvent.ACTION_UP) {
            val x = event.x
            val y = event.y
            var best: Poi? = null
            var bestDist = Float.MAX_VALUE
            for (p in pois) {
                val s = toScreen(p.lat, p.lon)
                val d = kotlin.math.hypot(x - s[0], y - s[1])
                if (d < 60f && d < bestDist) { bestDist = d; best = p }
            }
            if (best != null) {
                selectedId = best.id
                onPoiClick?.invoke(best)
                postInvalidate()
                return true
            }
        }
        return super.onTouchEvent(event)
    }

    /** 缩放（保留给未来手势） */
    fun zoomIn() { metersPerPx = (metersPerPx * 0.6f).coerceAtLeast(0.3f); postInvalidate() }
    fun zoomOut() { metersPerPx = (metersPerPx * 1.6f).coerceAtMost(20f); postInvalidate() }
}
