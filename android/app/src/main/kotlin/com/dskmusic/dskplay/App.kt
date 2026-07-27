package com.dskmusic.dskplay

import android.app.Application
import android.media.MediaScannerConnection
import android.provider.Settings
import com.ryanheise.audioservice.AudioServicePlugin
import io.flutter.plugin.common.MethodChannel

/**
 * Registers our custom platform channel on the FlutterEngine that
 * audio_service shares between the UI and the background playback service,
 * instead of via a custom Activity's configureFlutterEngine - swapping which
 * Activity class the manifest launches previously broke app startup, so this
 * avoids touching Activity/manifest activity resolution entirely.
 */
class App : Application() {
  override fun onCreate() {
    super.onCreate()
    try {
      val engine = AudioServicePlugin.getFlutterEngine(this)
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
    } catch (e: Exception) {
      // Best-effort pre-warm: if this fails for any reason, audio_service
      // still creates its shared engine lazily as usual later - just
      // without this channel available (getAndroidId/scanFile calls will
      // then throw MissingPluginException, caught by their Dart callers).
    }
  }
}
