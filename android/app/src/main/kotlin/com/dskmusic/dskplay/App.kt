package com.dskmusic.dskplay

import android.app.Activity
import android.app.Application
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.media.MediaScannerConnection
import android.os.Bundle
import android.os.IBinder
import android.provider.Settings
import android.util.Log
import androidx.core.content.ContextCompat
import com.ryanheise.audioservice.AudioService
import com.ryanheise.audioservice.AudioServicePlugin
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Registers our custom platform channels on the FlutterEngine that
 * audio_service shares between the UI and the background playback service,
 * instead of via a custom Activity's configureFlutterEngine - swapping which
 * Activity class the manifest launches previously broke app startup, so this
 * avoids touching Activity/manifest activity resolution entirely.
 *
 * That shared engine isn't as permanent as it sounds though: audio_service
 * destroys and later re-creates it whenever the app is fully backgrounded
 * with nothing playing (see AudioServicePlugin.disposeFlutterEngine()).
 * Application.onCreate() only runs once per process, so registering these
 * channels there alone left them silently broken (MissingPluginException)
 * on every engine after the first recreation - confirmed via logcat, and
 * the actual cause of background downloads randomly failing even though the
 * process itself was never killed. Re-registering on every Activity
 * creation (registerChannels() is idempotent/cheap) covers that.
 */
class App : Application() {
  companion object {
    @Volatile
    private var downloadChannel: MethodChannel? = null

    /**
     * Relays a tap on the notification's "Cancelar" action to Dart, where
     * the download loops actually live. Deliberately uses the channel of
     * the engine that is already running instead of asking audio_service
     * for one: AudioServicePlugin.getFlutterEngine() *creates* an engine
     * when there is none, which would boot the whole app just to cancel a
     * download that by definition can't be running.
     */
    fun requestCancelDownloads() {
      downloadChannel?.invokeMethod("cancelAll", null)
    }
  }

  private var lastEngine: FlutterEngine? = null
  private var audioServiceBound = false
  private val audioServiceConnection = object : ServiceConnection {
    override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
      Log.d("DskDownloadBind", "AudioService bound: $service")
    }

    override fun onServiceDisconnected(name: ComponentName?) {
      Log.d("DskDownloadBind", "AudioService disconnected")
    }
  }

  override fun onCreate() {
    super.onCreate()
    registerChannels()
    registerActivityLifecycleCallbacks(
      object : ActivityLifecycleCallbacks {
        override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) =
          registerChannels()

        override fun onActivityStarted(activity: Activity) {}
        override fun onActivityResumed(activity: Activity) {}
        override fun onActivityPaused(activity: Activity) {}
        override fun onActivityStopped(activity: Activity) {}
        override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}
        override fun onActivityDestroyed(activity: Activity) {}
      },
    )
  }

  private fun registerChannels() {
    try {
      val engine = AudioServicePlugin.getFlutterEngine(this)
      if (engine === lastEngine) return
      lastEngine = engine
      // The previous engine's AudioService (if any) is gone along with it -
      // that bind is now stale, so the next download should re-establish it
      // against whichever AudioService instance belongs to this engine.
      audioServiceBound = false

      MethodChannel(engine.dartExecutor.binaryMessenger, "dskplay/media_scanner")
        .setMethodCallHandler { call, result ->
          when (call.method) {
            "scanFile" -> {
              val path = call.argument<String>("path")
              if (path != null) {
                // Files written directly to disk (bypassing MediaStore) leave the
                // system's media index stale, so other apps (file managers, other
                // players) keep showing no/old cover art for them until a rescan.
                MediaScannerConnection.scanFile(applicationContext, arrayOf(path), null, null)
              }
              result.success(null)
            }
            "getAndroidId" -> {
              // Survives app uninstall/reinstall (same signing key, same device
              // user profile), unlike a Firebase anonymous auth uid - used as a
              // stable cloud-backup device code.
              val androidId = Settings.Secure.getString(contentResolver, Settings.Secure.ANDROID_ID)
              result.success(androidId)
            }
            else -> result.notImplemented()
          }
        }

      // Lets Dart keep a download running after the app is swiped away from
      // recents. audio_service's own AudioService destroys the *shared*
      // FlutterEngine (all of this app's Dart code, downloads included)
      // as soon as the Activity detaches and nothing else is bound to it -
      // this bind is what prevents that, and it must happen synchronously
      // here, BEFORE result.success() returns to Dart: doing it later,
      // asynchronously inside a Service's onStartCommand, left a real
      // window where the app could be closed after Dart believed the
      // download was already protected but before it actually was.
      val downloads =
        MethodChannel(engine.dartExecutor.binaryMessenger, "dskplay/download_service")
      downloadChannel = downloads
      downloads
        .setMethodCallHandler { call, result ->
          when (call.method) {
            "start" -> {
              if (!audioServiceBound) {
                // MediaBrowserServiceCompat.onBind() only hands back a real
                // Binder (and audio_service's own MediaBrowserCompat bind
                // does the same under the hood) when the intent carries this
                // exact action - without it, onBind() returns null and this
                // bind may not actually count towards keeping the service
                // (and its FlutterEngine) alive, which is the entire point.
                val intent = Intent(this, AudioService::class.java)
                  .setAction("android.media.browse.MediaBrowserService")
                audioServiceBound = bindService(
                  intent,
                  audioServiceConnection,
                  Context.BIND_AUTO_CREATE,
                )
                Log.d("DskDownloadBind", "bindService() returned $audioServiceBound")
              }
              ContextCompat.startForegroundService(
                this,
                Intent(this, DownloadForegroundService::class.java),
              )
              result.success(null)
            }
            "stop" -> {
              if (audioServiceBound) {
                unbindService(audioServiceConnection)
                audioServiceBound = false
              }
              stopService(Intent(this, DownloadForegroundService::class.java))
              result.success(null)
            }
            // The download notification is built entirely on the native
            // side (see DownloadForegroundService): Dart only pushes what
            // should be on it, so there is exactly one writer and one
            // notification, and the "Cancelar" action keeps working after
            // the app is swiped away from recents.
            "showProgress" -> {
              DownloadForegroundService.showProgress(
                this,
                call.argument<String>("title") ?: "DSK Play",
                call.argument<Int>("progress"),
              )
              result.success(null)
            }
            "showResult" -> {
              DownloadForegroundService.showResult(
                this,
                call.argument<String>("title") ?: "DSK Play",
                call.argument<String>("text") ?: "",
              )
              result.success(null)
            }
            "cancelNotification" -> {
              DownloadForegroundService.cancelNotification(this)
              result.success(null)
            }
            else -> result.notImplemented()
          }
        }
    } catch (e: Exception) {
      // Best-effort: if this fails for any reason, it'll simply be retried
      // on the next Activity creation - getAndroidId/scanFile/download
      // protection calls will throw MissingPluginException until then,
      // caught by their Dart callers.
    }
  }
}
