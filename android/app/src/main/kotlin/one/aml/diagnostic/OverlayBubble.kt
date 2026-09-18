package one.aml.diagnostic

import android.content.Context
import android.content.Intent
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PathMeasure
import android.graphics.PixelFormat
import android.graphics.RectF
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.provider.Settings
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.ViewOutlineProvider
import android.view.WindowManager
import android.view.animation.AnimationUtils
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import kotlin.math.exp
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

private const val OVERLAY_YELLOW = 0xFFF6B964.toInt()
private const val OVERLAY_YELLOW_BRIGHT = 0xFFFFF1C2.toInt()
private const val OVERLAY_RED = 0xFFE53935.toInt()
private const val OVERLAY_INK_LIGHT = 0xFFC8C8CC.toInt()
private const val OVERLAY_STOP_DISC = 0xFFF4F4F6.toInt()
private const val OVERLAY_FILL = 0xE61C1C1E.toInt()
private const val OVERLAY_EDGE = 0x33C8C8CC.toInt()

/**
 * Draggable Watch bubble over other apps: small app mark, name,
 * Record (Stop while capturing) / Open / Close glyphs, and a thin
 * Record (Stop while capturing) / Open / Close glyphs. While recording,
 * a 6px pastel golden-yellow highlight runs the pill edge: cruise on top,
 * fall fast down the right, cruise the bottom with that momentum, climb the left slowly.
 */
object OverlayBubble {
    private const val PREFS = "diag_overlay"
    private const val KEY_X = "x"
    private const val KEY_Y = "y"

    private var shell: OverlayShell? = null
    private var params: WindowManager.LayoutParams? = null
    private var recButton: GlyphButton? = null
    private var appIcon: ImageView? = null
    private var appName: TextView? = null
    private var activityStrip: ActivityStrip? = null
    private var windowManager: WindowManager? = null

    fun isShowing(): Boolean = shell != null

    fun show(context: Context) {
        if (!Settings.canDrawOverlays(context)) return
        if (shell != null) {
            refresh()
            return
        }
        val app = context.applicationContext
        val wm = app.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val density = app.resources.displayMetrics.density
        val slop = ViewConfiguration.get(app).scaledTouchSlop
        val prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val corner = dp(density, 20).toFloat()

        val icon = ImageView(app).apply {
            layoutParams = LinearLayout.LayoutParams(dp(density, 14), dp(density, 14))
            scaleType = ImageView.ScaleType.CENTER_CROP
            isClickable = false
            isFocusable = false
            clipToOutline = true
            outlineProvider = object : ViewOutlineProvider() {
                override fun getOutline(view: android.view.View, outline: android.graphics.Outline) {
                    outline.setRoundRect(0, 0, view.width, view.height, dp(density, 4).toFloat())
                }
            }
        }
        val name = TextView(app).apply {
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            ).apply {
                marginStart = dp(density, 6)
                marginEnd = 0
            }
            isClickable = false
            isLongClickable = false
            isFocusable = false
            setTextIsSelectable(false)
            includeFontPadding = false
            setTextColor(OVERLAY_INK_LIGHT)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            typeface = android.graphics.Typeface.create("sans-serif-medium", android.graphics.Typeface.BOLD)
            maxLines = 1
            maxWidth = dp(density, 96)
            ellipsize = android.text.TextUtils.TruncateAt.END
        }
        val rec = GlyphButton(app, density, GlyphButton.Kind.RECORD) {
            if (LogcatEngine.isRecording()) {
                val path = LogcatEngine.stopRecord()
                refresh()
                if (!path.isNullOrBlank()) openCaptureShare(app)
            } else {
                LogcatService.start(app)
                LogcatEngine.start(app)
                LogcatEngine.startRecord(app, LogcatEngine.toolVersion)
                refresh()
            }
        }
        val expand = GlyphButton(app, density, GlyphButton.Kind.EXPAND) {
            openDiagnostic(app)
        }
        val close = GlyphButton(app, density, GlyphButton.Kind.CLOSE) {
            hide(app)
        }
        val row = LinearLayout(app).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(density, 8), dp(density, 5), dp(density, 2), dp(density, 5))
            addView(icon)
            addView(name)
            addView(rec)
            addView(expand)
            addView(close)
        }
        val strip = ActivityStrip(app, density, corner)
        val card = OverlayShell(app, slop).apply {
            background = GradientDrawable().apply {
                setColor(OVERLAY_FILL)
                cornerRadius = corner
                setStroke(dp(density, 1), OVERLAY_EDGE)
            }
            clipToOutline = true
            clipToPadding = false
            elevation = 10f
            addView(
                strip,
                FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.MATCH_PARENT,
                    FrameLayout.LayoutParams.MATCH_PARENT,
                ),
            )
            addView(
                row,
                FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.WRAP_CONTENT,
                    FrameLayout.LayoutParams.WRAP_CONTENT,
                    Gravity.CENTER_VERTICAL,
                ),
            )
        }

        val metrics = app.resources.displayMetrics
        row.measure(
            View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED),
            View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED),
        )
        val lp = WindowManager.LayoutParams(
            row.measuredWidth.coerceAtLeast(1),
            row.measuredHeight.coerceAtLeast(1),
            overlayType(),
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = prefs.getInt(KEY_X, dp(density, 16))
            y = prefs.getInt(KEY_Y, dp(density, 120))
        }

        var originX = lp.x
        var originY = lp.y
        card.onDragStart = {
            originX = lp.x
            originY = lp.y
        }
        card.onDrag = { dx, dy ->
            val width = card.width.coerceAtLeast(dp(density, 120))
            val height = card.height.coerceAtLeast(dp(density, 32))
            lp.x = (originX + dx).coerceIn(0, (metrics.widthPixels - width).coerceAtLeast(0))
            lp.y = (originY + dy).coerceIn(0, (metrics.heightPixels - height).coerceAtLeast(0))
            try {
                wm.updateViewLayout(card, lp)
            } catch (_: Exception) {
            }
        }
        fun pinOverlaySize() {
            val w = row.measuredWidth
            val h = row.measuredHeight
            if (w <= 0 || h <= 0) return
            if (lp.width == w && lp.height == h) return
            lp.width = w
            lp.height = h
            try {
                wm.updateViewLayout(card, lp)
            } catch (_: Exception) {
            }
        }
        row.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> pinOverlaySize() }

        try {
            wm.addView(card, lp)
            shell = card
            params = lp
            windowManager = wm
            recButton = rec
            appIcon = icon
            appName = name
            activityStrip = strip
            refresh()
            LogcatEngine.emitOverlay(true)
        } catch (_: Exception) {
            shell = null
        }
    }

    fun hide(context: Context) {
        val card = shell ?: return
        card.stopSweep()
        shell = null
        recButton = null
        appIcon = null
        appName = null
        activityStrip = null
        val wm = windowManager
            ?: context.applicationContext.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        windowManager = null
        try {
            wm.removeView(card)
        } catch (_: Exception) {
        }
        LogcatEngine.emitOverlay(false)
    }

    fun refresh() {
        val rec = recButton ?: return
        rec.kind = if (LogcatEngine.isRecording()) {
            GlyphButton.Kind.STOP
        } else {
            GlyphButton.Kind.RECORD
        }
        rec.contentDescription = if (rec.kind == GlyphButton.Kind.STOP) {
            "Stop recording"
        } else {
            "Record"
        }
        val ctx = rec.context
        val (drawable, title) = targetIdentity(ctx)
        appName?.text = title
        if (drawable != null) {
            appIcon?.setImageDrawable(drawable)
        } else {
            appIcon?.setImageResource(R.mipmap.ic_launcher_v4)
        }
        val card = shell
        card?.requestLayout()
        activityStrip?.setRecording(LogcatEngine.isRecording())
    }

    private fun openCaptureShare(context: Context) {
        openDiagnostic(context)
    }

    private fun openDiagnostic(context: Context) {
        val launch = Intent(context, MainActivity::class.java)
            .addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP,
            )
        context.startActivity(launch)
    }

    private fun targetIdentity(context: Context): Pair<android.graphics.drawable.Drawable?, String> {
        val pkg = LogcatEngine.targetPackage
        val pm = context.packageManager
        if (pkg.isNullOrBlank()) {
            return try {
                pm.getApplicationIcon(context.packageName) to "Whole device"
            } catch (_: Exception) {
                null to "Whole device"
            }
        }
        return try {
            val info = pm.getApplicationInfo(pkg, 0)
            pm.getApplicationIcon(info) to pm.getApplicationLabel(info).toString()
        } catch (_: Exception) {
            null to pkg.substringAfterLast('.')
        }
    }

    private fun overlayType(): Int {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
        }
    }

    private fun dp(density: Float, value: Int): Int = (value * density).toInt()
}

private class OverlayShell(
    context: Context,
    private val slop: Int,
) : FrameLayout(context) {
    var onDragStart: (() -> Unit)? = null
    var onDrag: ((dx: Int, dy: Int) -> Unit)? = null
    var onDragEnd: (() -> Unit)? = null

    private var downRawX = 0f
    private var downRawY = 0f
    private var dragging = false

    init {
        setPadding(0, 0, 0, 0)
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        var w = 0
        var h = 0
        for (i in 0 until childCount) {
            val child = getChildAt(i)
            if (child is ActivityStrip) continue
            child.measure(
                MeasureSpec.makeMeasureSpec(0, MeasureSpec.UNSPECIFIED),
                MeasureSpec.makeMeasureSpec(0, MeasureSpec.UNSPECIFIED),
            )
            w = max(w, child.measuredWidth)
            h = max(h, child.measuredHeight)
        }
        w = w.coerceAtLeast(suggestedMinimumWidth)
        h = h.coerceAtLeast(suggestedMinimumHeight)
        setMeasuredDimension(w, h)
        val stripW = MeasureSpec.makeMeasureSpec(w, MeasureSpec.EXACTLY)
        val stripH = MeasureSpec.makeMeasureSpec(h, MeasureSpec.EXACTLY)
        for (i in 0 until childCount) {
            val child = getChildAt(i)
            if (child is ActivityStrip) {
                child.measure(stripW, stripH)
            }
        }
    }

    fun startSweep() {
        for (i in 0 until childCount) {
            (getChildAt(i) as? ActivityStrip)?.startSweep()
        }
    }

    fun stopSweep() {
        for (i in 0 until childCount) {
            (getChildAt(i) as? ActivityStrip)?.stopSweep()
        }
    }

    override fun onInterceptTouchEvent(ev: MotionEvent): Boolean {
        when (ev.actionMasked) {
            MotionEvent.ACTION_DOWN -> noteDown(ev)
            MotionEvent.ACTION_MOVE -> {
                if (!dragging && movedPastSlop(ev)) {
                    dragging = true
                    return true
                }
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> dragging = false
        }
        return dragging
    }

    override fun onTouchEvent(ev: MotionEvent): Boolean {
        when (ev.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                noteDown(ev)
                return true
            }
            MotionEvent.ACTION_MOVE -> {
                if (!dragging && movedPastSlop(ev)) dragging = true
                if (dragging) {
                    onDrag?.invoke(
                        (ev.rawX - downRawX).toInt(),
                        (ev.rawY - downRawY).toInt(),
                    )
                }
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                if (dragging) onDragEnd?.invoke()
                dragging = false
            }
        }
        return true
    }

    private fun noteDown(ev: MotionEvent) {
        downRawX = ev.rawX
        downRawY = ev.rawY
        dragging = false
        onDragStart?.invoke()
    }

    private fun movedPastSlop(ev: MotionEvent): Boolean {
        return hypot(
            (ev.rawX - downRawX).toDouble(),
            (ev.rawY - downRawY).toDouble(),
        ) > slop
    }
}

private class ActivityStrip(
    context: Context,
    density: Float,
    private val cornerRadius: Float,
) : View(context) {
    private var recording = false
    private val stroke = 6f
    private val vCruise = 130f * density
    private val vMax = 400f * density
    private val vClimb = 38f * density
    private val gravity = 1000f * density
    private val climbBrake = 1100f * density
    private val loop = Path()
    private val measure = PathMeasure()
    private val pos = FloatArray(2)
    private val tan = FloatArray(2)
    private val bounds = RectF()
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = stroke
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
        color = OVERLAY_YELLOW
        isDither = false
    }
    private var pathLen = 0f
    private var distance = 0f
    private var velocity = vCruise
    private var lastFrame = 0L
    private val tick = object : Runnable {
        override fun run() {
            if (!recording) return
            step()
            invalidate()
            postOnAnimation(this)
        }
    }

    init {
        setWillNotDraw(false)
        isClickable = false
        isFocusable = false
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
    }

    fun setRecording(active: Boolean) {
        recording = active
        if (active) {
            startSweep()
        } else {
            stopSweep()
        }
        invalidate()
    }

    fun startSweep() {
        if (pathLen <= 0f) rebuildPath()
        lastFrame = 0L
        if (distance <= 0f) {
            distance = 0f
            velocity = vCruise
        }
        removeCallbacks(tick)
        postOnAnimation(tick)
    }

    fun stopSweep() {
        recording = false
        removeCallbacks(tick)
        lastFrame = 0L
        distance = 0f
        velocity = vCruise
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        rebuildPath()
    }

    override fun onDraw(canvas: Canvas) {
        if (!recording || pathLen < 8f) return
        val band = (pathLen * 0.16f).coerceAtLeast(stroke * 18f)
        val step = 2.4f
        val samples = (band / step).toInt().coerceAtLeast(10)
        val last = (samples - 1).coerceAtLeast(1)
        paint.strokeWidth = stroke
        for (i in 0 until samples) {
            val t = i / last.toFloat()
            val fade = sin(Math.PI * t).toFloat()
            val core = exp(-((t - 0.5f) * 18f) * ((t - 0.5f) * 18f))
            val a = (fade * (150f + 105f * core)).toInt().coerceIn(0, 255)
            if (a < 8) continue
            paint.color = Color.argb(
                a,
                Color.red(OVERLAY_YELLOW) + ((Color.red(OVERLAY_YELLOW_BRIGHT) - Color.red(OVERLAY_YELLOW)) * core).toInt(),
                Color.green(OVERLAY_YELLOW) + ((Color.green(OVERLAY_YELLOW_BRIGHT) - Color.green(OVERLAY_YELLOW)) * core).toInt(),
                Color.blue(OVERLAY_YELLOW) + ((Color.blue(OVERLAY_YELLOW_BRIGHT) - Color.blue(OVERLAY_YELLOW)) * core).toInt(),
            )
            val d = (distance - band + t * band + pathLen) % pathLen
            measure.getPosTan(d, pos, tan)
            canvas.drawLine(
                pos[0],
                pos[1],
                pos[0] + tan[0] * step,
                pos[1] + tan[1] * step,
                paint,
            )
        }
    }

    override fun onDetachedFromWindow() {
        stopSweep()
        super.onDetachedFromWindow()
    }

    override fun onTouchEvent(event: MotionEvent): Boolean = false

    private fun rebuildPath() {
        val w = width.toFloat()
        val h = height.toFloat()
        loop.reset()
        pathLen = 0f
        if (w < 8f || h < 8f) return
        val inset = stroke / 2f
        val rr = min(cornerRadius, min((w - inset * 2f) / 2f, (h - inset * 2f) / 2f))
        bounds.set(inset, inset, w - inset, h - inset)
        loop.addRoundRect(bounds, rr, rr, Path.Direction.CW)
        measure.setPath(loop, false)
        pathLen = measure.length
        if (distance >= pathLen) distance = 0f
    }

    private fun step() {
        if (pathLen < 8f) {
            rebuildPath()
            if (pathLen < 8f) return
        }
        val now = AnimationUtils.currentAnimationTimeMillis()
        val dt = if (lastFrame == 0L) {
            0.016f
        } else {
            ((now - lastFrame) / 1000f).coerceIn(0.001f, 0.05f)
        }
        lastFrame = now
        measure.getPosTan(distance, pos, tan)
        val ty = tan[1]
        velocity = when {
            ty > 0.2f -> (velocity + gravity * ty * dt).coerceAtMost(vMax)
            ty < -0.2f -> (velocity - climbBrake * dt).coerceAtLeast(vClimb)
            else -> {
                val blend = (7f * dt).coerceAtMost(1f)
                velocity + (vCruise - velocity) * blend
            }
        }
        distance = (distance + velocity * dt) % pathLen
        if (distance < 0f) distance += pathLen
    }
}

private class GlyphButton(
    context: Context,
    private val density: Float,
    kind: Kind,
    onClick: () -> Unit,
) : View(context) {
    enum class Kind { RECORD, STOP, EXPAND, CLOSE }

    var kind: Kind = kind
        set(value) {
            field = value
            invalidate()
        }

    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)

    init {
        val size = (32 * density).toInt()
        layoutParams = LinearLayout.LayoutParams(size, size)
        isClickable = true
        isFocusable = true
        setOnClickListener { onClick() }
        contentDescription = when (kind) {
            Kind.RECORD -> "Record"
            Kind.STOP -> "Stop recording"
            Kind.EXPAND -> "Open Diagnostic"
            Kind.CLOSE -> "Close flying window"
        }
    }

    override fun onDraw(canvas: Canvas) {
        val cx = width / 2f
        val cy = height / 2f
        val glyph = 7.5f * density
        when (kind) {
            Kind.RECORD -> {
                paint.style = Paint.Style.FILL
                paint.color = OVERLAY_RED
                canvas.drawCircle(cx, cy, glyph, paint)
            }
            Kind.STOP -> {
                paint.style = Paint.Style.FILL
                paint.color = OVERLAY_STOP_DISC
                canvas.drawCircle(cx, cy, glyph, paint)
                paint.color = OVERLAY_RED
                val s = glyph
                val r = 1.2f * density
                canvas.drawRoundRect(cx - s / 2, cy - s / 2, cx + s / 2, cy + s / 2, r, r, paint)
            }
            Kind.EXPAND -> {
                paint.style = Paint.Style.STROKE
                paint.strokeWidth = 1.4f * density
                paint.color = OVERLAY_INK_LIGHT
                val s = glyph * 1.45f
                canvas.drawRoundRect(
                    cx - s / 2,
                    cy - s / 2,
                    cx + s / 2,
                    cy + s / 2,
                    1.8f * density,
                    1.8f * density,
                    paint,
                )
                paint.style = Paint.Style.FILL
                canvas.drawRoundRect(
                    cx - 0.7f * density,
                    cy - 0.7f * density,
                    cx + s / 2,
                    cy + s / 2,
                    1.3f * density,
                    1.3f * density,
                    paint,
                )
            }
            Kind.CLOSE -> {
                paint.style = Paint.Style.STROKE
                paint.strokeWidth = 1.4f * density
                paint.strokeCap = Paint.Cap.ROUND
                paint.color = OVERLAY_INK_LIGHT
                val arm = glyph * 0.58f
                canvas.drawLine(cx - arm, cy - arm, cx + arm, cy + arm, paint)
                canvas.drawLine(cx + arm, cy - arm, cx - arm, cy + arm, paint)
            }
        }
    }
}
