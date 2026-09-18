package one.aml.diagnostic

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedReader
import java.io.File
import java.io.FileOutputStream
import java.nio.charset.StandardCharsets
import java.text.SimpleDateFormat
import java.util.ArrayDeque
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Process-wide logcat capture. The foreground service keeps this alive while
 * the Flutter activity is covered by the app under test.
 */
object LogcatEngine {
    private const val TAG = "DiagLogcat"
    private const val BATCH_MS = 80L
    private const val MAX_BATCH = 80
    private const val MAX_RING = 4000

    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor { thread ->
        Thread(thread, "diag-logcat").apply { isDaemon = true }
    }

    @Volatile var sink: ((Map<String, Any?>) -> Unit)? = null

    private val running = AtomicBoolean(false)
    private val recording = AtomicBoolean(false)
    private val paused = AtomicBoolean(false)

    @Volatile private var process: Process? = null
    @Volatile private var recordStream: FileOutputStream? = null
    @Volatile var recordPath: String? = null
        private set
    @Volatile var pendingMdx: String? = null
        private set
    @Volatile var targetPackage: String? = null
        private set
    @Volatile var targetPid: Int? = null
        private set
    @Volatile var levelsKey: String = "VDIWEF"
        private set
    @Volatile var hideSpam: Boolean = true
        private set
    @Volatile var toolVersion: String = "1.0.3"

    private val noiseTags = setOf(
        "InsetsSource",
        "InsetsController",
        "InsetsControllerImpl",
        "ImeTracker",
        "ImeFocusController",
        "HandwritingStubImpl",
        "HandwritingInit",
        "InsetsAnimationCtrl",
    )
    private val threadtime = Regex(
        """^(\d{2})-(\d{2})\s+(\d{2}):(\d{2}):(\d{2})\.(\d{1,3})\s+(\d+)\s+(\d+)\s+([VDIWEF])\s+(.+?):\s(.*)$""",
    )

    private val batch = CopyOnWriteArrayList<String>()
    private var flushPosted = false
    private val ringLock = Any()
    private val ring = ArrayDeque<String>()

    fun isRunning(): Boolean = running.get()
    fun isRecording(): Boolean = recording.get()
    fun isPaused(): Boolean = paused.get()

    fun start(context: Context) {
        if (!running.compareAndSet(false, true)) {
            emitState()
            return
        }
        io.execute { runLogcat() }
        emitState()
    }

    fun stop() {
        running.set(false)
        stopRecordLocked()
        process?.destroy()
        process = null
        emitState()
    }

    fun setFilter(packageName: String?, pid: Int?, levels: String?, hideSpam: Boolean?) {
        targetPackage = packageName?.trim()?.ifEmpty { null }
        targetPid = pid
        if (!levels.isNullOrBlank()) levelsKey = levels
        if (hideSpam != null) this.hideSpam = hideSpam
        if (!packageName.isNullOrBlank() && pid == null) {
            targetPid = pidOf(packageName)
        }
        emitState()
    }

    fun startRecord(
        context: Context,
        toolVersion: String,
        appLabel: String? = null,
    ): String {
        synchronized(this) {
            stopRecordLocked()
            val dir = mdxDir(context)
            val stamp = fileStamp()
            val pkg = (targetPackage ?: "device").replace(Regex("[^A-Za-z0-9._-]"), "_")
            val file = File(dir, "${pkg}_$stamp.mdx")
            val header = deviceIdentity(context)
                .put("magic", "MDX1")
                .put("toolVersion", toolVersion)
                .put("device", Build.MODEL)
                .put("manufacturer", Build.MANUFACTURER)
                .put("sdk", Build.VERSION.SDK_INT)
                .put("packages", JSONArray().put(targetPackage ?: ""))
                .put("levels", levelsKey)
                .put("startedAt", isoNow())
                .put("source", "logcat")
            val label = appLabel?.trim().orEmpty()
            if (label.isNotEmpty()) header.put("appLabel", label)
            val stream = FileOutputStream(file, false)
            stream.write("${header.toString()}\n".toByteArray(StandardCharsets.UTF_8))
            recordStream = stream
            recordPath = file.absolutePath
            recording.set(true)
            paused.set(false)
        }
        emitState()
        return recordPath!!
    }

    fun mdxDir(context: Context): File {
        return File(context.filesDir, "mdx").apply { mkdirs() }
    }

    fun deviceIdentity(context: Context): JSONObject {
        val name = try {
            Settings.Global.getString(context.contentResolver, Settings.Global.DEVICE_NAME)
        } catch (_: Exception) {
            null
        } ?: try {
            Settings.Secure.getString(context.contentResolver, "bluetooth_name")
        } catch (_: Exception) {
            null
        } ?: Build.MODEL
        return JSONObject()
            .put("brand", Build.BRAND ?: "")
            .put("model", Build.MODEL ?: "")
            .put("deviceName", name)
            .put("manufacturer", Build.MANUFACTURER ?: "")
    }

    fun pauseRecord() {
        if (recording.get()) paused.set(true)
        emitState()
    }

    fun resumeRecord() {
        if (recording.get()) paused.set(false)
        emitState()
    }

    fun stopRecord(): String? {
        val path = synchronized(this) { stopRecordLocked() }
        if (!path.isNullOrBlank()) pendingMdx = path
        emitState()
        if (!path.isNullOrBlank()) {
            emit(mapOf("type" to "mdxReady", "path" to path))
        }
        return path
    }

    fun consumePendingMdx(): String? {
        val path = pendingMdx
        pendingMdx = null
        return path
    }

    private fun stopRecordLocked(): String? {
        val path = recordPath
        try {
            recordStream?.flush()
            recordStream?.close()
        } catch (_: Exception) {
        }
        recordStream = null
        recording.set(false)
        paused.set(false)
        return path
    }

    fun pidOf(packageName: String): Int? {
        return try {
            val proc = Runtime.getRuntime().exec(arrayOf("pidof", packageName))
            val text = proc.inputStream.bufferedReader(StandardCharsets.UTF_8).use(BufferedReader::readText)
            proc.waitFor()
            text.trim().split(Regex("\\s+")).firstOrNull()?.toIntOrNull()
        } catch (error: Exception) {
            Log.w(TAG, "pidof failed: ${error.message}")
            null
        }
    }

    fun snapshot(): Map<String, Any?> = mapOf(
        "running" to running.get(),
        "recording" to recording.get(),
        "paused" to paused.get(),
        "path" to recordPath,
        "packageName" to targetPackage,
        "pid" to targetPid,
        "levels" to levelsKey,
        "hideSpam" to hideSpam,
    )

    fun recentLines(): List<String> {
        synchronized(ringLock) {
            return ArrayList(ring)
        }
    }

    /**
     * One-shot `logcat -d` for Diagnose / Refresh. Uses a live pid lookup so a
     * stale Watch filter does not dump an empty buffer.
     */
    fun dumpLogcat(maxLines: Int = 4000): List<String> {
        val cap = maxLines.coerceIn(200, 8000)
        val previousPid = targetPid
        try {
            val pkg = targetPackage
            if (pkg != null) {
                targetPid = pidOf(pkg)
            }
            val proc = ProcessBuilder(
                listOf(
                    "/system/bin/logcat",
                    "-d",
                    "-v",
                    "threadtime",
                    "-t",
                    cap.toString(),
                ),
            )
                .redirectErrorStream(true)
                .start()
            val kept = ArrayList<String>(cap)
            try {
                proc.inputStream.bufferedReader(StandardCharsets.UTF_8).use { reader ->
                    while (true) {
                        val line = reader.readLine() ?: break
                        if (!shouldKeep(line)) continue
                        kept.add(line)
                    }
                }
                if (!proc.waitFor(10, TimeUnit.SECONDS)) {
                    proc.destroyForcibly()
                }
            } catch (error: Exception) {
                Log.w(TAG, "dumpLogcat failed: ${error.message}")
                proc.destroyForcibly()
            }
            Log.i(TAG, "dumpLogcat kept=${kept.size} pid=$targetPid pkg=$targetPackage")
            return if (kept.size <= cap) {
                kept
            } else {
                ArrayList(kept.subList(kept.size - cap, kept.size))
            }
        } finally {
            targetPid = previousPid
        }
    }

    private fun runLogcat() {
        try {
            val proc = Runtime.getRuntime().exec(
                arrayOf("logcat", "-v", "threadtime"),
            )
            process = proc
            proc.inputStream.bufferedReader(StandardCharsets.UTF_8).use { reader ->
                while (running.get()) {
                    val line = reader.readLine() ?: break
                    onLine(line)
                }
            }
        } catch (error: Exception) {
            Log.e(TAG, "logcat failed", error)
            emit(
                mapOf(
                    "type" to "error",
                    "message" to (error.message ?: "logcat failed"),
                ),
            )
        } finally {
            running.set(false)
            process = null
            emitState()
        }
    }

    private fun onLine(raw: String) {
        if (!shouldKeep(raw)) return
        remember(raw)
        if (recording.get() && !paused.get()) {
            appendRecord(raw)
        }
        batch.add(raw)
        scheduleFlush()
    }

    private fun remember(raw: String) {
        synchronized(ringLock) {
            while (ring.size >= MAX_RING) {
                ring.removeFirst()
            }
            ring.addLast(raw)
        }
    }

    private fun shouldKeep(raw: String): Boolean {
        val match = threadtime.find(raw) ?: return true
        val pid = match.groupValues[7].toIntOrNull()
        val level = match.groupValues[9]
        val tag = match.groupValues[10].trim()
        val wantedPid = targetPid
        if (wantedPid != null && pid != wantedPid) return false
        if (levelsKey.isNotEmpty() && !levelsKey.contains(level)) return false
        if (hideSpam && noiseTags.contains(tag)) return false
        return true
    }

    private fun appendRecord(raw: String) {
        val stream = recordStream ?: return
        try {
            stream.write((raw + "\n").toByteArray(StandardCharsets.UTF_8))
        } catch (error: Exception) {
            Log.w(TAG, "mdx write failed: ${error.message}")
        }
    }

    private fun scheduleFlush() {
        if (flushPosted) {
            if (batch.size >= MAX_BATCH) flushNow()
            return
        }
        flushPosted = true
        main.postDelayed({ flushNow() }, BATCH_MS)
    }

    private fun flushNow() {
        flushPosted = false
        if (batch.isEmpty()) return
        val lines = ArrayList<String>(batch.size)
        lines.addAll(batch)
        batch.clear()
        emit(mapOf("type" to "batch", "lines" to lines))
    }

    fun emitState() {
        emit(mapOf("type" to "state") + snapshot())
        main.post { OverlayBubble.refresh() }
    }

    fun emitOverlay(showing: Boolean) {
        emit(mapOf("type" to "overlay", "showing" to showing))
    }

    private fun emit(event: Map<String, Any?>) {
        main.post {
            sink?.invoke(event)
        }
    }

    private fun isoNow(): String {
        val fmt = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US)
        fmt.timeZone = TimeZone.getTimeZone("UTC")
        return fmt.format(Date())
    }

    private fun fileStamp(): String {
        val fmt = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US)
        return fmt.format(Date())
    }
}
