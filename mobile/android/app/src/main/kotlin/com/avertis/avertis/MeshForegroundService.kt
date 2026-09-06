package com.avertis.avertis

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
import android.util.Log
import androidx.core.app.NotificationCompat

/**
 * Keeps the mesh alive while the screen is off.
 *
 * A phone that stops relaying the moment it goes in a pocket is not a relay —
 * it is a dead spot that other nodes have already routed through. Android will
 * suspend a backgrounded app within minutes, so carrying other people's
 * life-critical traffic requires a foreground service and the persistent
 * notification that comes with it.
 *
 * The notification is not decoration: it is the honest disclosure that this
 * app is using the radio continuously, and it doubles as the mesh status
 * readout when the app is not open.
 */
class MeshForegroundService : Service() {

    companion object {
        private const val TAG = "AvertisMeshService"
        private const val CHANNEL_ID = "avertis_mesh"
        private const val NOTIFICATION_ID = 1

        const val ACTION_START = "com.avertis.avertis.MESH_START"
        const val ACTION_STOP = "com.avertis.avertis.MESH_STOP"
        const val ACTION_UPDATE = "com.avertis.avertis.MESH_UPDATE"

        const val EXTRA_NEIGHBORS = "neighbors"
        const val EXTRA_QUEUED = "queued"
        const val EXTRA_CUSTODY = "custody"

        /** Returns false if Android refused to let the service start. */
        fun start(context: Context): Boolean = try {
            val intent = Intent(context, MeshForegroundService::class.java)
                .setAction(ACTION_START)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
            true
        } catch (e: Exception) {
            Log.w(TAG, "could not start mesh service", e)
            false
        }

        fun update(context: Context, neighbors: Int, queued: Int, custody: Int) {
            try {
                context.startService(
                Intent(context, MeshForegroundService::class.java)
                    .setAction(ACTION_UPDATE)
                    .putExtra(EXTRA_NEIGHBORS, neighbors)
                    .putExtra(EXTRA_QUEUED, queued)
                        .putExtra(EXTRA_CUSTODY, custody)
                )
            } catch (e: Exception) {
                Log.w(TAG, "could not update mesh notification", e)
            }
        }

        fun stop(context: Context) {
            try {
                context.startService(
                    Intent(context, MeshForegroundService::class.java)
                        .setAction(ACTION_STOP)
                )
            } catch (e: Exception) {
                Log.w(TAG, "could not stop mesh service", e)
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }

            ACTION_UPDATE -> try {
                notificationManager().notify(
                    NOTIFICATION_ID,
                    buildNotification(
                        intent.getIntExtra(EXTRA_NEIGHBORS, 0),
                        intent.getIntExtra(EXTRA_QUEUED, 0),
                        intent.getIntExtra(EXTRA_CUSTODY, 0),
                    ),
                )
            } catch (e: SecurityException) {
                // Notifications not granted; the service keeps relaying.
                Log.w(TAG, "notification update denied", e)
            }

            else -> if (!startForegroundCompat(buildNotification(0, 0, 0))) {
                // We could not enter the foreground — almost always because
                // the BLE runtime permission that the connectedDevice service
                // type requires has not been granted yet. Stop cleanly; the
                // mesh keeps working while the app is open, and Dart is told
                // so it can say so rather than silently promising background
                // relaying it is not doing.
                stopSelf()
                return START_NOT_STICKY
            }
        }
        // START_STICKY: if Android kills us under memory pressure, come back.
        // Reports held in custody are on disk and are re-offered on restart.
        return START_STICKY
    }

    /**
     * Enter the foreground, or report failure without taking the app with us.
     *
     * Android throws if the connectedDevice service type is used without a
     * Bluetooth runtime permission, and an uncaught throw here crashes the
     * whole process. Losing background relaying is a degradation; losing the
     * app during a disaster is not acceptable.
     */
    private fun startForegroundCompat(notification: Notification): Boolean {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            true
        } catch (e: SecurityException) {
            Log.w(TAG, "foreground service denied: ${e.message}")
            false
        } catch (e: IllegalStateException) {
            // Thrown when the app is not allowed to start an FGS from the
            // background at all.
            Log.w(TAG, "foreground service not permitted right now", e)
            false
        }
    }

    private fun buildNotification(
        neighbors: Int,
        queued: Int,
        custody: Int,
    ): Notification {
        val openApp = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        val title = if (neighbors > 0) {
            "Mesh active · $neighbors node${if (neighbors == 1) "" else "s"} in range"
        } else {
            "Mesh active · searching for nodes"
        }

        val detail = buildString {
            if (custody > 0) {
                append("$custody report${if (custody == 1) "" else "s"} waiting to be confirmed")
            }
            if (queued > 0) {
                if (isNotEmpty()) append(" · ")
                append("$queued packet${if (queued == 1) "" else "s"} queued")
            }
            if (isEmpty()) append("Relaying for nearby devices")
        }

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(detail)
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setContentIntent(openApp)
            .setOngoing(true)
            .setSilent(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            // Visible on the lock screen: someone who has sent an SOS should
            // be able to see it is still being carried without unlocking.
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .build()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Mesh relay",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description =
                "Keeps the Avertis mesh relaying while the screen is off."
            setShowBadge(false)
        }
        notificationManager().createNotificationChannel(channel)
    }

    private fun notificationManager(): NotificationManager =
        getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
}
