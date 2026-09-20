package one.aml.diagnostic

import android.Manifest
import android.app.AppOpsManager
import android.content.ClipData
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.charset.StandardCharsets
import java.util.concurrent.TimeUnit

class MainActivity : FlutterActivity() {
    private var logEvents: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        LogcatEngine.sink = { event ->
            logEvents?.success(event)
        }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, LOGCAT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    logEvents = events
                    LogcatEngine.emitState()
                }

                override fun onCancel(arguments: Any?) {
                    logEvents = null
                }
            })

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DEVICE_CHANNEL)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "permissions" -> result.success(permissions())
                        "openSettings" -> {
                            openSettings(call.argument<String>("which") ?: "")
                            result.success(true)
                        }
                        "listPackages" -> {
                            Thread {
                                try {
                                    val apps = listPackages()
                                    runOnUiThread { result.success(apps) }
                                } catch (error: Exception) {
                                    runOnUiThread {
                                        result.error("diag", error.message, null)
                                    }
                                }
                            }.start()
                        }
                        "pidOf" -> {
                            val pkg = call.argument<String>("packageName") ?: ""
                            result.success(LogcatEngine.pidOf(pkg))
                        }
                        "startWatch" -> {
                            val version = call.argument<String>("toolVersion")
                            if (!version.isNullOrBlank()) LogcatEngine.toolVersion = version
                            LogcatEngine.attach(this)
                            LogcatEngine.setFilter(
                                call.argument("packageName"),
                                call.argument("pid"),
                                call.argument("levels"),
                                call.argument("hideSpam"),
                            )
                            LogcatService.start(this)
                            OverlayBubble.refresh()
                            result.success(LogcatEngine.snapshot())
                        }
                        "stopWatch" -> {
                            if (OverlayBubble.isShowing() || LogcatEngine.isRecording()) {
                                result.success(true)
                            } else {
                                OverlayBubble.hide(this)
                                LogcatService.stop(this)
                                result.success(true)
                            }
                        }
                        "setFilter" -> {
                            LogcatEngine.attach(this)
                            LogcatEngine.setFilter(
                                call.argument("packageName"),
                                call.argument("pid"),
                                call.argument("levels"),
                                call.argument("hideSpam"),
                            )
                            OverlayBubble.refresh()
                            result.success(LogcatEngine.snapshot())
                        }
                        "startRecord" -> {
                            val version = call.argument<String>("toolVersion")
                                ?: LogcatEngine.toolVersion
                            val path = LogcatEngine.startRecord(
                                this,
                                version,
                                call.argument("appLabel"),
                            )
                            OverlayBubble.refresh()
                            result.success(path)
                        }
                        "deviceIdentity" -> {
                            val identity = LogcatEngine.deviceIdentity(this)
                            result.success(
                                mapOf(
                                    "brand" to identity.optString("brand"),
                                    "model" to identity.optString("model"),
                                    "deviceName" to identity.optString("deviceName"),
                                    "manufacturer" to identity.optString("manufacturer"),
                                ),
                            )
                        }
                        "mdxDirectory" -> {
                            result.success(LogcatEngine.mdxDir(this).absolutePath)
                        }
                        "pauseRecord" -> {
                            LogcatEngine.pauseRecord()
                            OverlayBubble.refresh()
                            result.success(LogcatEngine.snapshot())
                        }
                        "resumeRecord" -> {
                            LogcatEngine.resumeRecord()
                            OverlayBubble.refresh()
                            result.success(LogcatEngine.snapshot())
                        }
                        "stopRecord" -> {
                            val path = LogcatEngine.stopRecord()
                            OverlayBubble.refresh()
                            result.success(path)
                        }
                        "recordState" -> result.success(LogcatEngine.snapshot())
                        "showOverlay" -> {
                            OverlayBubble.show(this)
                            result.success(OverlayBubble.isShowing())
                        }
                        "hideOverlay" -> {
                            OverlayBubble.hide(this)
                            result.success(true)
                        }
                        "shareMdx" -> {
                            val path = call.argument<String>("path") ?: ""
                            shareMdx(path, call.argument("packageName"))
                            result.success(true)
                        }
                        "isPackageInstalled" -> {
                            val pkg = call.argument<String>("packageName") ?: ""
                            result.success(isPackageInstalled(pkg))
                        }
                        "consumePendingMdx" -> result.success(LogcatEngine.consumePendingMdx())
                        "requestNotifications" -> {
                            requestNotifications()
                            result.success(true)
                        }
                        "dumpsys" -> {
                            val command = call.argument<String>("command") ?: ""
                            Thread {
                                try {
                                    val out = runDumpsys(command)
                                    runOnUiThread { result.success(out) }
                                } catch (error: Exception) {
                                    runOnUiThread {
                                        result.error("diag", error.message, null)
                                    }
                                }
                            }.start()
                        }
                        "snapshotLogs" -> result.success(LogcatEngine.recentLines())
                        "dumpLogcat" -> {
                            val maxLines = call.argument<Int>("maxLines") ?: 4000
                            Thread {
                                try {
                                    val lines = LogcatEngine.dumpLogcat(maxLines)
                                    runOnUiThread { result.success(lines) }
                                } catch (error: Exception) {
                                    runOnUiThread {
                                        result.error("diag", error.message, null)
                                    }
                                }
                            }.start()
                        }
                        "selfCheckDump" -> {
                            val maxLines = call.argument<Int>("maxLines") ?: 4000
                            Thread {
                                try {
                                    val lines = LogcatEngine.dumpBuffers(maxLines)
                                    runOnUiThread {
                                        result.success(
                                            mapOf(
                                                "pid" to android.os.Process.myPid(),
                                                "lines" to lines,
                                            ),
                                        )
                                    }
                                } catch (error: Exception) {
                                    runOnUiThread {
                                        result.error("diag", error.message, null)
                                    }
                                }
                            }.start()
                        }
                        else -> result.notImplemented()
                    }
                } catch (error: Exception) {
                    result.error("diag", error.message, null)
                }
            }
    }

    override fun onDestroy() {
        LogcatEngine.sink = null
        logEvents = null
        // Do not stop LogcatService here. HyperOS destroys this activity when
        // the user opens the app under test; killing logcat re-prompts
        // "Allow Diagnostic to access all device logs?".
        super.onDestroy()
    }

    private fun permissions(): Map<String, Any?> {
        val notifications = if (Build.VERSION.SDK_INT >= 33) {
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.POST_NOTIFICATIONS,
            ) == PackageManager.PERMISSION_GRANTED
        } else {
            true
        }
        val power = getSystemService(PowerManager::class.java)
        return mapOf(
            "readLogs" to (checkSelfPermission(Manifest.permission.READ_LOGS) ==
                PackageManager.PERMISSION_GRANTED),
            "overlay" to Settings.canDrawOverlays(this),
            "notifications" to notifications,
            "batteryUnrestricted" to (power?.isIgnoringBatteryOptimizations(packageName) == true),
            "xiaomi" to isXiaomi(),
            "appOpsReadLogs" to appOpsReadLogsAllowed(),
        )
    }

    private fun appOpsReadLogsAllowed(): Boolean {
        return appOpAllowed("android:read_logs") ||
            appOpAllowed("android:read_device_logs") ||
            appOpAllowedInt(114) ||
            appOpAllowedInt(10017)
    }

    private fun appOpAllowedInt(op: Int): Boolean {
        return try {
            val ops = getSystemService(AppOpsManager::class.java) ?: return false
            val method = AppOpsManager::class.java.getMethod(
                "checkOpNoThrow",
                Int::class.javaPrimitiveType,
                Int::class.javaPrimitiveType,
                String::class.java,
            )
            val mode = method.invoke(ops, op, android.os.Process.myUid(), packageName) as Int
            mode == AppOpsManager.MODE_ALLOWED
        } catch (_: Exception) {
            false
        }
    }

    private fun appOpAllowed(op: String): Boolean {
        return try {
            val ops = getSystemService(AppOpsManager::class.java) ?: return false
            val mode = if (Build.VERSION.SDK_INT >= 29) {
                ops.unsafeCheckOpNoThrow(
                    op,
                    android.os.Process.myUid(),
                    packageName,
                )
            } else {
                @Suppress("DEPRECATION")
                ops.checkOpNoThrow(
                    op,
                    android.os.Process.myUid(),
                    packageName,
                )
            }
            mode == AppOpsManager.MODE_ALLOWED
        } catch (_: Exception) {
            false
        }
    }

    private fun openSettings(which: String) {
        when (which) {
            "overlay" -> startActivity(
                Intent(
                    Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                    Uri.parse("package:$packageName"),
                ),
            )
            "notifications" -> {
                val intent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                    .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                startActivity(intent)
            }
            "battery" -> {
                val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                    .setData(Uri.parse("package:$packageName"))
                startActivity(intent)
            }
            "autostart" -> openAutostart()
            else -> startActivity(
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                    .setData(Uri.parse("package:$packageName")),
            )
        }
    }

    private fun openAutostart() {
        val candidates = listOf(
            Intent("miui.intent.action.OP_AUTO_START").addCategory(Intent.CATEGORY_DEFAULT),
            Intent().setClassName(
                "com.miui.securitycenter",
                "com.miui.permcenter.autostart.AutoStartManagementActivity",
            ),
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                .setData(Uri.parse("package:$packageName")),
        )
        for (intent in candidates) {
            try {
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(intent)
                return
            } catch (_: Exception) {
            }
        }
    }

    private fun listPackages(): List<Map<String, Any?>> {
        val pm = packageManager
        val apps = pm.getInstalledApplications(PackageManager.GET_META_DATA)
        return apps
            .asSequence()
            .filter { info ->
                info.packageName != packageName &&
                    (info.flags and ApplicationInfo.FLAG_SYSTEM) == 0
            }
            .map { info ->
                mapOf(
                    "packageName" to info.packageName,
                    "label" to pm.getApplicationLabel(info).toString(),
                )
            }
            .toList()
    }

    private fun shareMdx(path: String, targetPackage: String?) {
        val file = File(path)
        if (!file.exists()) return
        val uri = FileProvider.getUriForFile(
            this,
            "$packageName.fileprovider",
            file,
        )
        val mime = when {
            file.name.endsWith(".mdxd", ignoreCase = true) ->
                "application/x-aml-mdxd"
            file.name.endsWith(".mdx", ignoreCase = true) ->
                "application/x-aml-mdx"
            else -> "*/*"
        }
        val send = Intent(Intent.ACTION_SEND)
            .setType(mime)
            .putExtra(Intent.EXTRA_STREAM, uri)
            .putExtra(Intent.EXTRA_SUBJECT, file.name)
            .addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_ACTIVITY_NEW_TASK,
            )
        send.clipData = ClipData.newUri(contentResolver, file.name, uri)
        val target = targetPackage?.trim().orEmpty()
        if (target.isNotEmpty()) {
            send.setPackage(target)
            grantUriPermission(target, uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        try {
            if (target.isNotEmpty()) {
                startActivity(send)
            } else {
                startActivity(Intent.createChooser(send, "Share Diagnostic capture"))
            }
        } catch (_: Exception) {
            // Dart shows the missing-app snackbar.
        }
    }

    private fun isPackageInstalled(packageName: String): Boolean {
        if (packageName.isBlank()) return false
        return try {
            if (Build.VERSION.SDK_INT >= 33) {
                packageManager.getPackageInfo(
                    packageName,
                    PackageManager.PackageInfoFlags.of(0),
                )
            } else {
                @Suppress("DEPRECATION")
                packageManager.getPackageInfo(packageName, 0)
            }
            true
        } catch (_: PackageManager.NameNotFoundException) {
            false
        }
    }

    private fun runDumpsys(command: String): String {
        val extra = command.trim().split(Regex("\\s+")).filter { it.isNotEmpty() }
        if (extra.isEmpty()) return ""
        val proc = ProcessBuilder(listOf("/system/bin/dumpsys") + extra)
            .redirectErrorStream(true)
            .start()
        val collected = StringBuilder()
        val reader = Thread {
            proc.inputStream.bufferedReader(StandardCharsets.UTF_8).use { stream ->
                collected.append(stream.readText())
            }
        }
        reader.start()
        val finished = try {
            proc.waitFor(4, TimeUnit.SECONDS)
        } catch (_: InterruptedException) {
            false
        }
        if (!finished) {
            proc.destroyForcibly()
        }
        try {
            reader.join(1_000)
        } catch (_: InterruptedException) {
            // ignore
        }
        val text = collected.toString()
        val clipped = if (text.length > 200_000) text.substring(0, 200_000) else text
        android.util.Log.i(
            "DiagDumpsys",
            "dumpsys ${extra.joinToString(" ")} chars=${clipped.length} head=${clipped.take(160).replace('\n', ' ')}",
        )
        return clipped
    }

    private fun requestNotifications() {
        if (Build.VERSION.SDK_INT >= 33) {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                71,
            )
        }
    }

    private fun isXiaomi(): Boolean {
        val maker = "${Build.MANUFACTURER} ${Build.BRAND}".lowercase()
        return maker.contains("xiaomi") ||
            maker.contains("redmi") ||
            maker.contains("poco") ||
            maker.contains("blackshark")
    }

    companion object {
        const val DEVICE_CHANNEL = "one.aml.diagnostic/device"
        const val LOGCAT_CHANNEL = "one.aml.diagnostic/logcat"
    }
}
