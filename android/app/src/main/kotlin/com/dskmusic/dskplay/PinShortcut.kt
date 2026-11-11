package com.dskmusic.dskplay

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Base64
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.net.URL

/**
 * "Anadir al escritorio": pide al launcher un acceso directo fijado que abre la
 * app con un enlace dskplay://play/... (lo reproduce main.dart).
 */
object PinShortcut {
  private const val CHANNEL = "dskplay/pin_shortcut"
  private const val ICON_SIZE = 432
  private const val ACTIVITY = "com.ryanheise.audioservice.AudioServiceActivity"

  fun register(messenger: BinaryMessenger, ctx: Context) {
    MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
      if (call.method != "pin") {
        result.notImplemented()
        return@setMethodCallHandler
      }
      val id = call.argument<String>("id")
      val label = call.argument<String>("label")
      val uri = call.argument<String>("uri")
      if (id == null || label == null || uri == null) {
        result.error("bad_args", "id, label y uri son obligatorios", null)
        return@setMethodCallHandler
      }
      if (!ShortcutManagerCompat.isRequestPinShortcutSupported(ctx)) {
        result.success(false)
        return@setMethodCallHandler
      }
      val image = call.argument<String>("image")
      // La descarga de la portada no puede ir en el hilo principal.
      Thread {
        val ok = try {
          val bitmap = loadBitmap(image)
          val icon = if (bitmap != null) {
            IconCompat.createWithAdaptiveBitmap(bitmap)
          } else {
            IconCompat.createWithResource(ctx, R.mipmap.ic_launcher)
          }
          val intent = Intent(Intent.ACTION_VIEW, Uri.parse(uri)).setClassName(ctx, ACTIVITY)
          val info = ShortcutInfoCompat.Builder(ctx, id)
            .setShortLabel(label)
            .setLongLabel(label)
            .setIcon(icon)
            .setIntent(intent)
            .build()
          ShortcutManagerCompat.requestPinShortcut(ctx, info, null)
        } catch (e: Exception) {
          false
        }
        Handler(Looper.getMainLooper()).post { result.success(ok) }
      }.start()
    }
  }

  /** URL http(s), data URI base64 o ruta de fichero; null si no hay o falla. */
  private fun loadBitmap(source: String?): Bitmap? {
    if (source.isNullOrBlank()) return null
    return try {
      val raw = when {
        source.startsWith("http") -> {
          val conn = URL(source).openConnection().apply {
            connectTimeout = 8000
            readTimeout = 8000
          }
          conn.getInputStream().use { BitmapFactory.decodeStream(it) }
        }
        source.startsWith("data:image") -> {
          val bytes = Base64.decode(source.substringAfter(','), Base64.DEFAULT)
          BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
        }
        else -> BitmapFactory.decodeFile(source)
      } ?: return null
      // Recorte cuadrado centrado: los launchers esperan un icono cuadrado.
      val side = minOf(raw.width, raw.height)
      val square = Bitmap.createBitmap(raw, (raw.width - side) / 2, (raw.height - side) / 2, side, side)
      Bitmap.createScaledBitmap(square, ICON_SIZE, ICON_SIZE, true)
    } catch (e: Exception) {
      null
    }
  }
}
