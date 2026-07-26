import android.media.MediaScannerConnection
import android.os.Build
import android.os.Bundle
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
  private val mediaScannerChannel = "dskplay/media_scanner"

  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, mediaScannerChannel)
      .setMethodCallHandler { call, result ->
        if (call.method == "scanFile") {
          val path = call.argument<String>("path")
          if (path != null) {
            // Files written directly to disk (bypassing MediaStore) leave the
            // system's media index stale, so other apps (file managers, other
            // players) keep showing no/old cover art for them until a rescan.
            MediaScannerConnection.scanFile(applicationContext, arrayOf(path), null, null)
          }
          result.success(null)
        } else {
          result.notImplemented()
        }
      }
  }

  override fun onCreate(savedInstanceState: Bundle?) {
    // Aligns the Flutter view vertically with the window.
    WindowCompat.setDecorFitsSystemWindows(getWindow(), false)

    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
      // Without this, Android paints its own translucent scrim behind the
      // status/navigation bars for icon legibility, which shows up as a
      // band no Flutter-side AppBar/theme change can remove, since it is
      // drawn by the system compositor, not by Flutter.
      window.isStatusBarContrastEnforced = false
      window.isNavigationBarContrastEnforced = false
    }

    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
      // Disable the Android splash screen fade out animation to avoid
      // a flicker before the similar frame is drawn in Flutter.
      splashScreen.setOnExitAnimationListener { splashScreenView -> splashScreenView.remove() }
    }

    super.onCreate(savedInstanceState)
  }
}
