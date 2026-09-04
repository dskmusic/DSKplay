package com.dskmusic.dskplay

import android.app.Activity
import android.app.Application
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.media.MediaScannerConnection
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Process
import android.provider.Settings
import android.util.Log
import androidx.core.content.ContextCompat
import com.ryanheise.audioservice.AudioService
import com.ryanheise.audioservice.AudioServicePlugin
import com.dskmusic.dskplay.cast.CastBridge
import com.dskmusic.dskplay.youtube.NewPipeBridge
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

    @Volatile
    private var appContext: Context? = null

    // A cached process with no foreground service can be frozen (all
    // threads suspended) regardless of wake locks or pending Handler
    // callbacks, which would silently stop the countdowns below from ever
    // firing - see IdleCloseService's own doc comment. Idempotent to start
    // twice (just redelivers onStartCommand), so no ref-counting needed;
    // only cancelIdleClose() stops it, since scheduleHardExit's own
    // runnable kills the process directly and has nothing left to clean up.
    private fun startIdleKeepAlive(endTimeMillis: Long) {
      appContext?.let {
        val intent = Intent(it, IdleCloseService::class.java)
          .putExtra(IdleCloseService.EXTRA_END_TIME_MILLIS, endTimeMillis)
        ContextCompat.startForegroundService(it, intent)
      }
    }

    private fun stopIdleKeepAlive() {
      appContext?.let { it.stopService(Intent(it, IdleCloseService::class.java)) }
    }

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

    // Backs up the Dart-side idle-auto-close timer (audio_service.dart's
    // _scheduleIdleAutoClose): audio_service destroys the FlutterEngine
    // (and every Dart Timer with it) almost immediately once the app is
    // backgrounded with nothing playing, so that timer never survives long
    // enough to fire and the process is left orphaned - still alive, just
    // with nothing left running to close it. This Handler lives on the
    // Application, not the engine, so it outlives that teardown.
    private val idleCloseHandler = Handler(Looper.getMainLooper())
    private var idleCloseRunnable: Runnable? = null

    private fun armIdleClose(minutes: Int) {
      cancelIdleClose()
      if (minutes <= 0) return
      val delayMs = minutes * 60_000L
      startIdleKeepAlive(System.currentTimeMillis() + delayMs)
      val runnable = Runnable { Process.killProcess(Process.myPid()) }
      idleCloseRunnable = runnable
      idleCloseHandler.postDelayed(runnable, delayMs)
    }

    private fun cancelIdleClose() {
      idleCloseRunnable?.let { idleCloseHandler.removeCallbacks(it) }
      idleCloseRunnable = null
      stopIdleKeepAlive()
    }

    // Backs up Dart's own exit(0) call in AudioHandler.stop()/_exitIfIdle:
    // that whole shutdown path runs on the shared FlutterEngine, which
    // audio_service can tear down mid-flight (its service stopping itself
    // as part of the very stop() call that scheduled this), stranding
    // exit(0) before it ever runs and leaving the process alive. Separate
    // runnable from the one above so an in-progress idle-close arm/cancel
    // never interferes with this one, or vice versa.
    private var hardExitRunnable: Runnable? = null

    fun scheduleHardExit(delayMs: Long) {
      hardExitRunnable?.let { idleCloseHandler.removeCallbacks(it) }
      startIdleKeepAlive(System.currentTimeMillis() + delayMs)
      val runnable = Runnable { Process.killProcess(Process.myPid()) }
      hardExitRunnable = runnable
      idleCloseHandler.postDelayed(runnable, delayMs)
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
    appContext = applicationContext
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

      // Extraccion de YouTube (busqueda/streams/listas) con NewPipeExtractor.
      NewPipeBridge.register(engine.dartExecutor.binaryMessenger)

      // Reproduccion en Chromecast y Smart TV (DLNA).
      CastBridge.register(engine.dartExecutor.binaryMessenger, this)

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
                call.argument<Int>("autoDismissMs") ?: 0,
              )
              result.success(null)
            }
            "cancelNotification" -> {
              DownloadForegroundService.cancelNotification(this)
              result.success(null)
            }
            "armIdleClose" -> {
              armIdleClose(call.argument<Int>("minutes") ?: 0)
              result.success(null)
            }
            "cancelIdleClose" -> {
              cancelIdleClose()
              result.success(null)
            }
            "scheduleHardExit" -> {
              scheduleHardExit((call.argument<Int>("delayMs") ?: 15000).toLong())
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
