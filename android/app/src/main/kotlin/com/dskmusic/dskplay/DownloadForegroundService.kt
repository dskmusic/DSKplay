package com.dskmusic.dskplay

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat

/**
 * Sole owner of the app's single download notification, and the foreground
 * service that keeps the process alive - and the CPU awake - while a
 * download is running. Driven from Dart over the
 * "dskplay/download_service" MethodChannel registered in [App], which is
 * also where the (more critical, and synchronous) bind that keeps
 * audio_service's shared FlutterEngine alive happens.
 *
 * The notification used to be built on *both* sides - a placeholder here
 * and the real one from Dart via flutter_local_notifications, sharing one
 * id - so two writers fought over it: the percentage jumped backwards, the
 * visible "Cancelar" was whichever had posted last (Dart's, whose action
 * callback never fires once the app is swiped from recents), and every
 * restart of this service repainted the placeholder over real progress.
 * Dart now only pushes title/percentage; everything is built here.
 */
class DownloadForegroundService : Service() {
  companion object {
    const val NOTIFICATION_ID = 900001
    private const val CHANNEL_ID = "downloads"
    private const val ACTION_CANCEL = "com.dskmusic.dskplay.CANCEL_DOWNLOADS"
    private const val WAKE_LOCK_TIMEOUT_MS = 4L * 60 * 60 * 1000 // 4h safety cap

    @Volatile
    private var instance: DownloadForegroundService? = null

    // What is currently on screen. onStartCommand restores *this* instead
    // of resetting to the placeholder - it also runs when the "Cancelar"
    // action fires, since that PendingIntent targets this same service.
    private var title = "DSK Play"
    private var text = "Preparando descarga…"
    private var progress = 0
    private var indeterminate = true
    private var ongoing = true

    fun showProgress(context: Context, newTitle: String, newProgress: Int?) {
      title = newTitle
      if (newProgress != null) progress = newProgress.coerceIn(0, 100)
      indeterminate = newProgress == null
      text = if (indeterminate) "" else "$progress%"
      ongoing = true
      notifyNow(context)
    }

    fun showResult(context: Context, newTitle: String, newText: String) {
      title = newTitle
      text = newText
      progress = 100
      indeterminate = false
      ongoing = false
      // A foreground service's notification can't be dismissed and is wiped
      // when the service stops, so it has to be detached first for the final
      // "Completado"/"Ha fallado" to survive on its own and be swipeable.
      instance?.let {
        ServiceCompat.stopForeground(it, ServiceCompat.STOP_FOREGROUND_DETACH)
      }
      notifyNow(context)
    }

    fun cancelNotification(context: Context) {
      instance?.let {
        ServiceCompat.stopForeground(it, ServiceCompat.STOP_FOREGROUND_REMOVE)
      }
      NotificationManagerCompat.from(context).cancel(NOTIFICATION_ID)
      reset()
    }

    private fun reset() {
      title = "DSK Play"
      text = "Preparando descarga…"
      progress = 0
      indeterminate = true
      ongoing = true
    }

    private fun notifyNow(context: Context) {
      try {
        NotificationManagerCompat.from(context).notify(NOTIFICATION_ID, build(context))
      } catch (e: SecurityException) {
        // POST_NOTIFICATIONS denied - the download itself still runs.
      }
    }

    private fun build(context: Context): Notification {
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        val manager =
          context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) == null) {
          manager.createNotificationChannel(
            NotificationChannel(
              CHANNEL_ID,
              "Descargas",
              NotificationManager.IMPORTANCE_LOW,
            )
          )
        }
      }

      val builder = NotificationCompat.Builder(context, CHANNEL_ID)
        .setContentTitle(title)
        .setContentText(text)
        .setSmallIcon(R.mipmap.ic_launcher)
        .setOnlyAlertOnce(true)
        .setOngoing(ongoing)
        .setAutoCancel(!ongoing)

      if (ongoing) {
        builder.setProgress(100, progress, indeterminate)
        val cancelIntent = Intent(context, DownloadForegroundService::class.java)
          .setAction(ACTION_CANCEL)
        builder.addAction(
          android.R.drawable.ic_menu_close_clear_cancel,
          "Cancelar",
          PendingIntent.getService(
            context,
            0,
            cancelIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
          ),
        )
      }

      return builder.build()
    }
  }

  private var wakeLock: PowerManager.WakeLock? = null

  override fun onBind(intent: Intent?): IBinder? = null

  override fun onCreate() {
    super.onCreate()
    instance = this
  }

  override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
    val cancelRequested = intent?.action == ACTION_CANCEL
    if (cancelRequested) {
      // Immediate feedback: download loops only notice the flag between
      // chunks/songs, so without this the notification would sit on its last
      // percentage for a few seconds as if the tap had done nothing.
      title = "DSK Play"
      text = "Cancelando…"
      indeterminate = true
      ongoing = true
    }

    startForeground(NOTIFICATION_ID, build(this))

    if (cancelRequested) {
      // Downloads notice this and unwind on their own (finishing the current
      // chunk and returning), which drops the acquire/release count to zero
      // and stops this service - and its notification - from Dart.
      App.requestCancelDownloads()
    }

    // A foreground service alone keeps the *process* alive, but the CPU can
    // still doze once the screen is off / app is closed, which stalls the
    // download's network I/O just as effectively as a process kill would -
    // this partial wake lock is what actually keeps bytes flowing.
    if (wakeLock == null) {
      val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
      wakeLock = powerManager
        .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "dskplay:download")
        .apply {
          setReferenceCounted(false)
          acquire(WAKE_LOCK_TIMEOUT_MS)
        }
    }

    return START_STICKY
  }

  override fun onDestroy() {
    wakeLock?.let { if (it.isHeld) it.release() }
    wakeLock = null
    instance = null
    super.onDestroy()
  }

  // Deliberately does nothing: staying alive after the app's task is
  // swiped away from recents is the entire point of this service.
  override fun onTaskRemoved(rootIntent: Intent?) {}
}
