package one.aml.diagnostic

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedOutputStream
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
    private const val LIVE_BATCH_MS = 200L
    private const val RECORD_BATCH_MS = 400L
    private const val MAX_BATCH = 40
    private const val MAX_RING = 4000
    private const val FILE_FLUSH_EVERY = 16
    private const val FILE_FLUSH_MS = 250L

    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor { thread ->
        Thread(thread, "diag-logcat").apply { isDaemon = true }
    }

    @Volatile var sink: ((Map<String, Any?>) -> Unit)? = null

    private val running = AtomicBoolean(false)
    private val recording = AtomicBoolean(false)
    private val paused = AtomicBoolean(false)

    @Volatile private var process: Process? = null
    @Volatile private var recordFos: FileOutputStream? = null
    @Volatile private var recordBuf: BufferedOutputStream? = null
    private var writesSinceFlush = 0
    private var lastFileFlushMs = 0L
    @Volatile var recordPath: String? = null
        private set
    @Volatile var pendingMdx: String? = null
        private set
    @Volatile var targetPackage: String? = null
        private set
    @Volatile var targetPid: Int? = null
        private set
    @Volatile private var targetPids: Set<Int> = emptySet()
    @Volatile var levelsKey: String = "VDIWEF"
        private set
    @Volatile var hideSpam: Boolean = true
        private set
    @Volatile var toolVersion: String = "1.0.3"
    @Volatile private var appContext: Context? = null
    @Volatile private var targetUid: Int? = null
    @Volatile private var uidScoped: Boolean = false
    @Volatile private var uidFilterOk: Boolean = true
    @Volatile private var logcatGeneration: Int = 0

    private val noiseTags = setOf(
        "InsetsSource",
        "InsetsController",
        "InsetsControllerImpl",
        "ImeTracker",
        "ImeFocusController",
        "HandwritingStubImpl",
        "HandwritingInit",
        "InsetsAnimationCtrl",
        "NotiHistoryDatabase",
        "IconCustomizer",
        "ThemedIcon",
        "IconPolicy",
    )
    private val oneDropTags = setOf("OneDrop", "OneDropP2p", "OneDropEngine")
    private val nearbyTags = setOf(
        "WifiService",
        "WifiClient",
        "WifiNative",
        "WifiManager",
        "LocationManager",
        "NsdManager",
        "ConnectivityService",
        "NearbyConnections",
        "BluetoothAdapter",
        "BluetoothLeScanner",
    )
    private val lifecycleTags = setOf(
        "ActivityManager",
        "ActivityTaskManager",
        "WindowManager",
    )
    private const val oneDropPackage = "one.aml.onedrop"
    private val threadtime = Regex(
        """^(\d{2})-(\d{2})\s+(\d{2}):(\d{2}):(\d{2})\.(\d{1,3})\s+(\d+)\s+(\d+)\s+([VDIWEF])\s+(.+?):\s(.*)$""",
    )

    private val batch = CopyOnWriteArrayList<String>()
    private var flushPosted = false
    private val ringLock = Any()
    private val ring = ArrayDeque<String>()
    private val liveKeep = KeepState()

    private class KeepState {
        var lastParsedKept = false
    }

    fun isRunning(): Boolean = running.get()
    fun isRecording(): Boolean = recording.get()
    fun isPaused(): Boolean = paused.get()

    fun attach(context: Context) {
        appContext = context.applicationContext
    }

    fun start(context: Context) {
        attach(context)
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
        val previousPackage = targetPackage
        targetPackage = packageName?.trim()?.ifEmpty { null }
        if (!levels.isNullOrBlank()) levelsKey = levels
        if (hideSpam != null) this.hideSpam = hideSpam
        val lookedUp = targetPackage?.let(::pidsOf) ?: emptySet()
        targetPids = if (pid != null) lookedUp + pid else lookedUp
        targetPid = pid ?: targetPids.firstOrNull()
        targetUid = targetPackage?.let(::uidOf)
        liveKeep.lastParsedKept = false
        uidScoped = targetPackage != null &&
            targetPackage != oneDropPackage &&
            targetUid != null &&
            uidFilterOk
        if (previousPackage != targetPackage) {
            uidFilterOk = true
            uidScoped = targetPackage != null &&
                targetPackage != oneDropPackage &&
                targetUid != null
            logcatGeneration++
            process?.destroy()
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
            val fos = FileOutputStream(file, false)
            val buf = BufferedOutputStream(fos, 32 * 1024)
            buf.write("${header.toString()}\n".toByteArray(StandardCharsets.UTF_8))
            buf.flush()
            fos.fd.sync()
            recordFos = fos
            recordBuf = buf
            writesSinceFlush = 0
            lastFileFlushMs = SystemClock.uptimeMillis()
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
        flushRecord()
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
            recordBuf?.flush()
            recordFos?.fd?.sync()
            recordBuf?.close()
        } catch (_: Exception) {
        }
        recordBuf = null
        recordFos = null
        writesSinceFlush = 0
        recording.set(false)
        paused.set(false)
        return path
    }

    fun pidOf(packageName: String): Int? = pidsOf(packageName).firstOrNull()

    fun uidOf(packageName: String): Int? {
        val ctx = appContext ?: return null
        return try {
            ctx.packageManager.getPackageUid(packageName, 0)
        } catch (_: Exception) {
            try {
                ctx.packageManager.getApplicationInfo(packageName, 0).uid
            } catch (_: Exception) {
                null
            }
        }
    }

    fun pidsOf(packageName: String): Set<Int> {
        val fromPidof = pidofExec(packageName)
        if (fromPidof.isNotEmpty()) return fromPidof
        return pidsFromPs(packageName)
    }

    private fun pidofExec(packageName: String): Set<Int> {
        return try {
            val proc = Runtime.getRuntime().exec(arrayOf("pidof", packageName))
            val text = proc.inputStream.bufferedReader(StandardCharsets.UTF_8).use(BufferedReader::readText)
            proc.waitFor()
            text.trim().split(Regex("\\s+")).mapNotNull { it.toIntOrNull() }.toSet()
        } catch (error: Exception) {
            Log.w(TAG, "pidof failed: ${error.message}")
            emptySet()
        }
    }

    private fun pidsFromPs(packageName: String): Set<Int> {
        return try {
            val proc = Runtime.getRuntime().exec(arrayOf("ps", "-A"))
            val text = proc.inputStream.bufferedReader(StandardCharsets.UTF_8).use(BufferedReader::readText)
            proc.waitFor()
            val prefix = "$packageName:"
            val found = mutableSetOf<Int>()
            for (row in text.lineSequence()) {
                if (!row.contains(packageName)) continue
                val parts = row.trim().split(Regex("\\s+"))
                if (parts.size < 2) continue
                val name = parts.last()
                if (name != packageName && !name.startsWith(prefix)) continue
                parts.getOrNull(1)?.toIntOrNull()?.let(found::add)
            }
            found
        } catch (error: Exception) {
            Log.w(TAG, "ps failed: ${error.message}")
            emptySet()
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
     * Unfiltered main + crash `logcat -d` for the Diagnostic self-check.
     * Does not apply the live Watch pid filter.
     */
    fun dumpBuffers(maxLines: Int = 4000): List<String> {
        val cap = maxLines.coerceIn(200, 8000)
        val kept = ArrayList<String>(cap)
        readLogcatDump(
            listOf(
                "/system/bin/logcat",
                "-d",
                "-v",
                "threadtime",
                "-t",
                cap.toString(),
            ),
            kept,
            cap,
        )
        readLogcatDump(
            listOf(
                "/system/bin/logcat",
                "-b",
                "crash",
                "-d",
                "-v",
                "threadtime",
            ),
            kept,
            cap,
        )
        readLogcatDump(
            listOf(
                "/system/bin/logcat",
                "-d",
                "-v",
                "threadtime",
                "-t",
                "800",
                "-s",
                "OneDrop:V",
                "OneDropP2p:V",
                "OneDropEngine:V",
            ),
            kept,
            cap,
        )
        return if (kept.size <= cap) {
            kept
        } else {
            ArrayList(kept.subList(kept.size - cap, kept.size))
        }
    }

    private fun readLogcatDump(command: List<String>, into: ArrayList<String>, cap: Int) {
        val proc = try {
            ProcessBuilder(command).redirectErrorStream(true).start()
        } catch (error: Exception) {
            Log.w(TAG, "logcat dump failed: ${error.message}")
            return
        }
        try {
            proc.inputStream.bufferedReader(StandardCharsets.UTF_8).use { reader ->
                while (into.size < cap) {
                    val line = reader.readLine() ?: break
                    if (line.isNotEmpty()) into.add(line)
                }
            }
            if (!proc.waitFor(10, TimeUnit.SECONDS)) {
                proc.destroyForcibly()
            }
        } catch (error: Exception) {
            Log.w(TAG, "logcat dump read failed: ${error.message}")
            proc.destroyForcibly()
        }
    }

    /**
     * One-shot `logcat -d` for Diagnose / Refresh. Uses a live pid lookup so a
     * stale Watch filter does not dump an empty buffer.
     */
    fun dumpLogcat(maxLines: Int = 4000): List<String> {
        val cap = maxLines.coerceIn(200, 8000)
        val previousPid = targetPid
        val previousPids = targetPids
        val dumpKeep = KeepState()
        try {
            val pkg = targetPackage
            if (pkg != null) {
                targetPids = pidsOf(pkg)
                targetPid = targetPids.firstOrNull()
            }
            val proc = ProcessBuilder(dumpCommand())
                .redirectErrorStream(true)
                .start()
            val kept = ArrayList<String>(cap)
            try {
                proc.inputStream.bufferedReader(StandardCharsets.UTF_8).use { reader ->
                    while (true) {
                        val line = reader.readLine() ?: break
                        if (!shouldKeep(line, dumpKeep)) continue
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
            targetPids = previousPids
        }
    }

    private fun runLogcat() {
        while (running.get()) {
            val gen = logcatGeneration
            seedRecent()
            val proc = try {
                ProcessBuilder(followCommand()).redirectErrorStream(true).start()
            } catch (error: Exception) {
                Log.e(TAG, "logcat failed", error)
                emit(
                    mapOf(
                        "type" to "error",
                        "message" to (error.message ?: "logcat failed"),
                    ),
                )
                break
            }
            process = proc
            val startedAt = SystemClock.uptimeMillis()
            try {
                proc.inputStream.bufferedReader(StandardCharsets.UTF_8).use { reader ->
                    while (running.get() && gen == logcatGeneration) {
                        val line = reader.readLine() ?: break
                        onLine(line)
                    }
                }
            } catch (error: Exception) {
                Log.e(TAG, "logcat read failed", error)
            } finally {
                try {
                    proc.destroy()
                } catch (_: Exception) {
                }
                if (process === proc) process = null
            }
            if (!running.get()) break
            if (uidFilterOk &&
                targetUid != null &&
                targetPackage != oneDropPackage &&
                SystemClock.uptimeMillis() - startedAt < 800L
            ) {
                uidFilterOk = false
                uidScoped = false
                Log.w(TAG, "logcat --uid rejected; following unfiltered")
            }
            if (!running.get()) break
            if (gen == logcatGeneration) {
                try {
                    Thread.sleep(200)
                } catch (_: InterruptedException) {
                    break
                }
            }
        }
        running.set(false)
        process = null
        emitState()
    }

    private fun seedRecent() {
        val dumpKeep = KeepState()
        val command = dumpCommand()
        val proc = try {
            ProcessBuilder(command).redirectErrorStream(true).start()
        } catch (error: Exception) {
            Log.w(TAG, "logcat dump failed: ${error.message}")
            return
        }
        val chunk = ArrayList<String>(MAX_BATCH)
        try {
            proc.inputStream.bufferedReader(StandardCharsets.UTF_8).use { reader ->
                while (running.get()) {
                    val line = reader.readLine() ?: break
                    if (!shouldKeep(line, dumpKeep)) continue
                    remember(line)
                    if (recording.get() && !paused.get()) appendRecord(line)
                    chunk.add(line)
                    if (chunk.size >= MAX_BATCH) {
                        emit(mapOf("type" to "batch", "lines" to ArrayList(chunk)))
                        chunk.clear()
                    }
                }
            }
            if (!proc.waitFor(10, TimeUnit.SECONDS)) {
                proc.destroyForcibly()
            }
        } catch (error: Exception) {
            Log.w(TAG, "logcat dump read failed: ${error.message}")
            proc.destroyForcibly()
        }
        if (chunk.isNotEmpty()) {
            emit(mapOf("type" to "batch", "lines" to chunk))
        }
        Log.i(TAG, "seeded Watch dump pkg=$targetPackage")
    }

    private fun dumpCommand(): List<String> {
        val args = mutableListOf(
            "/system/bin/logcat",
            "-d",
            "-v",
            "threadtime",
            "-t",
            "4000",
        )
        appendUidArgs(args)
        return args
    }

    private fun followCommand(): List<String> {
        val args = mutableListOf("logcat", "-v", "threadtime")
        appendUidArgs(args)
        return args
    }

    private fun appendUidArgs(args: MutableList<String>) {
        if (!uidFilterOk) return
        if (targetPackage == oneDropPackage) return
        val uid = targetUid ?: return
        args.add("--uid")
        args.add(uid.toString())
    }

    private fun onLine(raw: String) {
        if (!shouldKeep(raw, liveKeep)) return
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

    private fun shouldKeep(raw: String, state: KeepState): Boolean {
        val match = threadtime.find(raw)
        if (match == null) {
            return state.lastParsedKept
        }
        val pid = match.groupValues[7].toIntOrNull()
        val level = match.groupValues[9]
        val tag = match.groupValues[10].trim()
        val message = match.groupValues[11]
        val pids = targetPids
        val pkg = targetPackage
        val keep = when {
            hideSpam && noiseTags.contains(tag) -> false
            levelsKey.isNotEmpty() && !levelsKey.contains(level) -> false
            isTaggedAppLog(tag, message, pkg) -> true
            pkg == oneDropPackage && isOneDropNearbyTag(tag) -> true
            pids.isNotEmpty() && pid != null && pid in pids -> true
            uidScoped && !pkg.isNullOrBlank() -> true
            pkg.isNullOrBlank() -> true
            lifecycleTags.contains(tag) && raw.contains(pkg) -> true
            pkg == oneDropPackage && raw.contains(pkg) -> true
            else -> false
        }
        state.lastParsedKept = keep
        return keep
    }

    private fun isOneDropNearbyTag(tag: String): Boolean {
        if (tag.startsWith("BtGatt") || tag.startsWith("Bluetooth")) return true
        return tag in nearbyTags
    }

    private fun isTaggedAppLog(tag: String, message: String, pkg: String?): Boolean {
        if (pkg != oneDropPackage) return false
        if (tag in oneDropTags) return true
        return tag == "flutter" &&
            (message.startsWith("[OneDrop]") || message.startsWith("OneDrop:"))
    }

    private fun appendRecord(raw: String) {
        val buf = recordBuf ?: return
        try {
            buf.write((raw + "\n").toByteArray(StandardCharsets.UTF_8))
            writesSinceFlush++
            val now = SystemClock.uptimeMillis()
            if (writesSinceFlush >= FILE_FLUSH_EVERY) {
                buf.flush()
                writesSinceFlush = 0
            }
            if (now - lastFileFlushMs >= FILE_FLUSH_MS) {
                flushRecord()
            }
        } catch (error: Exception) {
            Log.w(TAG, "mdx write failed: ${error.message}")
        }
    }

    private fun flushRecord() {
        try {
            recordBuf?.flush()
            recordFos?.fd?.sync()
            writesSinceFlush = 0
            lastFileFlushMs = SystemClock.uptimeMillis()
        } catch (error: Exception) {
            Log.w(TAG, "mdx flush failed: ${error.message}")
        }
    }

    private fun batchDelay(): Long = if (recording.get()) RECORD_BATCH_MS else LIVE_BATCH_MS

    private fun scheduleFlush() {
        if (flushPosted) {
            if (batch.size >= MAX_BATCH) flushNow()
            return
        }
        flushPosted = true
        main.postDelayed({ flushNow() }, batchDelay())
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
