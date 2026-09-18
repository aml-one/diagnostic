package one.aml.diagnostic

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

class LogcatService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                LogcatEngine.stop()
                OverlayBubble.hide(this)
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }
            else -> {
                ensureChannel()
                val notification = buildNotification()
                if (Build.VERSION.SDK_INT >= 34) {
                    startForeground(
                        NOTIFICATION_ID,
                        notification,
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
                    )
                } else {
                    startForeground(NOTIFICATION_ID, notification)
                }
                LogcatEngine.start(this)
            }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        LogcatEngine.stop()
        super.onDestroy()
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Diagnostic capture",
            NotificationManager.IMPORTANCE_LOW,
        )
        channel.setShowBadge(false)
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val launch = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val title = when {
            LogcatEngine.isPaused() -> "Capture paused"
            LogcatEngine.isRecording() -> "Recording logcat"
            else -> "Watching logcat"
        }
        val stop = PendingIntent.getService(
            this,
            1,
            Intent(this, LogcatService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText("AmL Diagnostic is capturing device logs.")
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentIntent(launch)
            .addAction(0, "Stop", stop)
            .setOngoing(true)
            .setSilent(true)
            .build()
    }

    companion object {
        const val CHANNEL_ID = "diag_logcat"
        const val NOTIFICATION_ID = 71
        const val ACTION_STOP = "one.aml.diagnostic.STOP_LOGCAT"

        fun start(context: Context) {
            val intent = Intent(context, LogcatService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            val intent = Intent(context, LogcatService::class.java).setAction(ACTION_STOP)
            context.startService(intent)
        }
    }
}
