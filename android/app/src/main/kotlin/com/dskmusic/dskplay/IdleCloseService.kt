package com.dskmusic.dskplay

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * Exists solely to keep the process out of Android's cached-app freezer
 * while the idle-auto-close Handler (see armIdleClose() in App.kt) is
 * counting down. A PARTIAL_WAKE_LOCK alone keeps the CPU running, but a
 * cached process with no foreground service can still be frozen - all
 * threads suspended - regardless of CPU wake state, which is why that
 * Handler never actually fired without this.
 *
 * foregroundServiceType is mediaPlayback (matching DownloadForegroundService,
 * see its manifest entry) rather than dataSync/mediaProcessing: those get a
 * short OS-enforced forced-stop timeout when started from the background.
 */
class IdleCloseService : Service() {
  companion object {
    private const val NOTIFICATION_ID = 900002
    private const val CHANNEL_ID = "idle_close"
  }

  override fun onBind(intent: Intent?): IBinder? = null

  override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
    startForeground(NOTIFICATION_ID, build())
    return START_NOT_STICKY
  }

  private fun build(): Notification {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
      if (manager.getNotificationChannel(CHANNEL_ID) == null) {
        manager.createNotificationChannel(
          NotificationChannel(CHANNEL_ID, "Cierre automático", NotificationManager.IMPORTANCE_MIN)
        )
      }
    }
    return NotificationCompat.Builder(this, CHANNEL_ID)
      .setContentTitle("DSK Play")
      .setSmallIcon(R.mipmap.ic_launcher)
      .setPriority(NotificationCompat.PRIORITY_MIN)
      .setOngoing(true)
      .build()
  }

  // Deliberately does nothing: staying alive after the app's task is
  // swiped away from recents is the entire point of this service.
  override fun onTaskRemoved(rootIntent: Intent?) {}
}
