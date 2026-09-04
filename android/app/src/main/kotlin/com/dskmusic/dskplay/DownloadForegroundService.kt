package com.dskmusic.dskplay

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
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

    // Cuánto se espera sin noticias de Dart antes de dar la descarga por
    // muerta y limpiar. Holgado a propósito: entre el último byte y el aviso
    // final hay un transcode de ffmpeg y el etiquetado, que en un móvil lento
    // tardan lo suyo, y en una lista también pasa un rato entre canciones.
    private const val IDLE_TIMEOUT_MS = 2L * 60 * 1000

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
    private var timeoutMs = 0

    fun showProgress(context: Context, newTitle: String, newProgress: Int?) {
      title = newTitle
      if (newProgress != null) progress = newProgress.coerceIn(0, 100)
      indeterminate = newProgress == null
      text = if (indeterminate) "" else "$progress%"
      ongoing = true
      notifyNow(context)
      instance?.armIdleWatchdog()
    }

    fun showResult(
      context: Context,
      newTitle: String,
      newText: String,
      autoDismissMs: Int,
    ) {
      title = newTitle
      text = newText
      progress = 100
      indeterminate = false
      ongoing = false
      timeoutMs = autoDismissMs
      // A foreground service's notification can't be dismissed and is wiped
      // when the service stops, so it has to be detached first for the final
      // "Completado"/"Ha fallado" to survive on its own and be swipeable.
      instance?.let {
        ServiceCompat.stopForeground(it, ServiceCompat.STOP_FOREGROUND_DETACH)
      }
      notifyNow(context)
      instance?.cancelIdleWatchdog()
      // Nothing is going to rebuild this notification any more (it belongs to
      // the system now), so leave the state clean for the next download
      // instead of having its first onStartCommand repaint "Completado".
      reset()
    }

    fun cancelNotification(context: Context) {
      instance?.let {
        it.cancelIdleWatchdog()
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
      timeoutMs = 0
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

      // The "Completado" used to be dismissed by a 3s Future on the Dart
      // side, which never ran once audio_service tore the engine down with
      // the download that had just released it - leaving the finished
      // notification sitting in the shade at 100% forever. The system honours
      // this regardless of whether this process is still alive.
      if (!ongoing && timeoutMs > 0) builder.setTimeoutAfter(timeoutMs.toLong())

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
  private var wifiLock: WifiManager.WifiLock? = null

  private val idleHandler = Handler(Looper.getMainLooper())

  /**
   * Limpieza de último recurso: Dart es quien avisa de que una descarga ha
   * terminado (showResult, y el "stop" que para este servicio), pero su
   * engine puede haber muerto ya - audio_service lo destruye al quedarse sin
   * Activity - mientras ffmpeg termina de escribir el fichero en un hilo
   * nativo. El resultado era una notificación clavada en "Descargando... 100%"
   * que nadie iba a retirar, con el wake lock y el wifi lock cogidos detrás.
   */
  private val idleWatchdog = Runnable {
    cancelNotification(applicationContext)
    stopSelf()
  }

  private fun armIdleWatchdog() {
    idleHandler.removeCallbacks(idleWatchdog)
    idleHandler.postDelayed(idleWatchdog, IDLE_TIMEOUT_MS)
  }

  private fun cancelIdleWatchdog() {
    idleHandler.removeCallbacks(idleWatchdog)
  }

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
    armIdleWatchdog()

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

    // The wake lock above keeps the CPU running but does nothing to stop the
    // Wi-Fi radio from dropping into power save as soon as the app leaves the
    // foreground - the socket then stalls half-open without ever closing, so
    // the download receives neither bytes nor an error and only "resumes"
    // when the user reopens the app. FULL_HIGH_PERF is deprecated since API
    // 29 but still the only mode that actually prevents that; LOW_LATENCY
    // only applies while the app is in the foreground, which is precisely
    // when this isn't needed.
    if (wifiLock == null) {
      val wifiManager =
        applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
      @Suppress("DEPRECATION")
      wifiLock = wifiManager
        .createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "dskplay:download")
        .apply {
          setReferenceCounted(false)
          acquire()
        }
    }

    return START_STICKY
  }

  override fun onDestroy() {
    cancelIdleWatchdog()
    wakeLock?.let { if (it.isHeld) it.release() }
    wakeLock = null
    wifiLock?.let { if (it.isHeld) it.release() }
    wifiLock = null
    instance = null
    super.onDestroy()
  }

  // Deliberately does nothing: staying alive after the app's task is
  // swiped away from recents is the entire point of this service.
  override fun onTaskRemoved(rootIntent: Intent?) {}
}
