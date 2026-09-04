/*
 *     Copyright (C) 2026 Víctor Castilla
 *
 *     DSK Play is free software: you can redistribute it and/or modify
 *     it under the terms of the GNU General Public License as published by
 *     the Free Software Foundation, either version 3 of the License, or
 *     (at your option) any later version.
 *
 *     DSK Play is distributed in the hope that it will be useful,
 *     but WITHOUT ANY WARRANTY; without even the implied warranty of
 *     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *     GNU General Public License for more details.
 *
 *     You should have received a copy of the GNU General Public License
 *     along with this program.  If not, see <https://www.gnu.org/licenses/>.
 *
 *
 *     For more information about DSK Play, including how to contribute,
 *     please visit: https://dskmusic.com or https://github.com/dskmusic
 */

import 'dart:io';

import 'package:dskplay/main.dart' show logger;
import 'package:dskplay/services/download_foreground_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

const MethodChannel _mediaScannerChannel = MethodChannel(
  'dskplay/media_scanner',
);

/// Bumped whenever a file is downloaded/exported to disk (manual MP3
/// download or "make available offline"), so the local files browser can
/// refresh itself instead of showing a stale listing.
final ValueNotifier<int> localFilesRefreshTick = ValueNotifier<int>(0);

void notifyLocalFilesChanged() {
  localFilesRefreshTick.value++;
}

/// Carpeta que el explorador de archivos locales debe abrir en cuanto se
/// muestre; la usa el enlace al origen del reproductor completo.
final ValueNotifier<String?> localFilesPendingFolder = ValueNotifier<String?>(
  null,
);

/// Tells Android's MediaStore to (re)index [path]. Files written directly
/// to disk (as every download/export/tag-edit here does) don't show up —
/// or keep showing stale cover art — in other apps (file managers, other
/// players) until the system rescans them; this makes that happen right
/// away instead of waiting for whatever periodic scan the OS/OEM runs.
Future<void> scanMediaFile(String path) async {
  if (!Platform.isAndroid) return;
  try {
    await _mediaScannerChannel.invokeMethod('scanFile', {'path': path});
  } catch (_) {}
}

/// Android's `Settings.Secure.ANDROID_ID`: stable across an uninstall and
/// reinstall of this same app (same signing key, same device/user profile),
/// unlike a Firebase anonymous auth uid. Used as the cloud-backup device
/// code. Returns null off Android or if the platform call fails.
Future<String?> getAndroidDeviceId() async {
  if (!Platform.isAndroid) return null;
  try {
    final id = await _mediaScannerChannel.invokeMethod<String>('getAndroidId');
    if (id == null || id.isEmpty) {
      logger.log('getAndroidDeviceId: platform returned null/empty ANDROID_ID');
      return null;
    }
    return id;
  } catch (e, stackTrace) {
    logger.log('getAndroidDeviceId: platform call failed', error: e, stackTrace: stackTrace);
    return null;
  }
}

/// Public app folder on external storage. Kept outside the app's private
/// storage so offline downloads survive an uninstall/reinstall and manual
/// exports are easy to find from a file manager.
const String appExternalRootPath = '/storage/emulated/0/DSKplay';
const String offlineMusicDirPath = '$appExternalRootPath/Offline';
const String downloadedMusicDirPath = '$appExternalRootPath/Descargas';

/// The device's actual system Downloads folder (not this app's own
/// Descargas folder above), used for saving cover images so they show up
/// where the user expects them, alongside other downloaded files.
const String androidDownloadsDirPath = '/storage/emulated/0/Download';

late String applicationDirPath;

Future<bool> ensureExportStoragePermission() async {
  if (await Permission.manageExternalStorage.isGranted) return true;
  final status = await Permission.manageExternalStorage.request();
  return status.isGranted;
}

/// Private, app-scoped cache for cover art embedded in offline/downloaded
/// songs' audio tags. Not scanned by the system gallery: the audio file's
/// tag is the source of truth, this is only a fast-read cache derived from
/// it for display, regenerated on demand if missing.
Future<String> offlineArtworkCachePath(
  String songId, {
  String extension = '.jpg',
}) async {
  final tempDir = await getTemporaryDirectory();
  final dir = Directory('${tempDir.path}/offline_artwork');
  if (!await dir.exists()) await dir.create(recursive: true);
  return '${dir.path}/$songId$extension';
}

class FilePaths {
  // File extensions
  // MP3 is the only format written for downloads/offline: it's the one
  // format we've confirmed reads and writes embedded cover art reliably
  // (via ffmpeg transcode + audiotags) across YouTube's varied source
  // codecs/containers.
  static const String audioExtension = '.mp3';
  static const String artworkExtension = '.jpg';

  // Legacy subdirectory names, kept only so old installs' files (and the
  // one-time migration in main.dart) can still be found/cleaned up. New
  // downloads are written directly under [applicationDirPath] instead:
  // single songs in the Offline root, playlist/album songs in a subfolder
  // named after the playlist/album (see [getAudioPath]'s `folder` param).
  static const String tracksDir = 'tracks';
  static const String artworksDir = 'artworks';

  // Get full paths for various file types. [folder], when provided, nests
  // the file under a subdirectory of the offline root (used for
  // playlist/album downloads); singles keep using the root directly.
  static String getAudioPath(String songId, {String? folder}) {
    final base = (folder != null && folder.isNotEmpty)
        ? '$applicationDirPath/$folder'
        : applicationDirPath;
    return '$base/$songId$audioExtension';
  }

  static String getArtworkPath(String songId) {
    return '$applicationDirPath/$artworksDir/$songId$artworkExtension';
  }

  // Ensure the offline root directory exists.
  static Future<void> ensureDirectoriesExist() async {
    final directory = Directory(applicationDirPath);
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
  }
}

/// Removes characters that aren't safe in a folder/file name on Android's
/// external storage, used to derive playlist/album download subfolders and
/// exported filenames from user-provided titles.
String sanitizeFileName(String name) {
  final sanitized = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
  return sanitized.isEmpty ? 'DSKplay' : sanitized;
}

/// Sin datos durante este tiempo se da el intento por muerto y se reintenta.
/// Un socket que se queda a medias -- lo que pasa justo al cerrar la app
/// desde recientes, cuando el Wi-Fi entra en ahorro de energia -- no emite ni
/// un byte ni un error: sin esto el `await for` esperaba indefinidamente, la
/// notificacion se quedaba clavada en el mismo % y la descarga solo revivia
/// al volver a abrir la app.
const Duration _downloadIdleTimeout = Duration(seconds: 30);
const int _downloadMaxAttempts = 4;
const Duration _downloadRetryDelay = Duration(seconds: 2);

/// Descarga [uri] en [file], reanudando desde donde se cortara.
///
/// Unico camino de descarga de la app (canciones, exportaciones y episodios
/// de podcast): el corte se detecta con [_downloadIdleTimeout] y el reintento
/// pide `Range: bytes=N-` para continuar el fichero que ya esta en disco en
/// vez de perder lo descargado y empezar de cero.
///
/// Devuelve false al agotar los reintentos, si el servidor responde algo que
/// no sea 200/206, o si el usuario cancela desde la notificacion; en todos
/// esos casos el fichero parcial se queda en disco y lo borra quien llama.
Future<bool> downloadUriToFile(
  Uri uri,
  File file, {
  Map<String, String> headers = const {},
  void Function(double progress)? onProgress,
}) async {
  await file.parent.create(recursive: true);
  if (await file.exists()) await file.delete();

  var received = 0;

  for (var attempt = 1; attempt <= _downloadMaxAttempts; attempt++) {
    if (DownloadForegroundService.cancelAllRequested) return false;

    // El IOSink bufferiza, asi que tras un corte parte de lo contado en
    // memoria puede no haber llegado al disco: lo unico fiable para saber
    // desde que byte reanudar es el tamano real del fichero.
    received = await file.exists() ? await file.length() : 0;

    final client = http.Client();
    IOSink? sink;
    try {
      final request = http.Request('GET', uri)..headers.addAll(headers);
      if (received > 0) request.headers['Range'] = 'bytes=$received-';
      final response = await client.send(request).timeout(_downloadIdleTimeout);

      if (response.statusCode != 200 && response.statusCode != 206) {
        logger.log('downloadUriToFile: HTTP ${response.statusCode} for $uri');
        return false;
      }
      // Un servidor que ignora Range contesta 200 con el fichero entero, no
      // 206: hay que truncar y empezar de cero en lugar de pegar bytes
      // duplicados al final de lo ya descargado.
      final resuming = response.statusCode == 206 && received > 0;
      if (!resuming) received = 0;
      final total = (response.contentLength ?? 0) + received;

      sink = file.openWrite(mode: resuming ? FileMode.append : FileMode.write);
      await for (final chunk in response.stream.timeout(_downloadIdleTimeout)) {
        if (DownloadForegroundService.cancelAllRequested) return false;
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress?.call(received / total);
      }
      await sink.flush();
      await sink.close();
      sink = null;

      // Un socket cerrado limpiamente a mitad de fichero no lanza error: sin
      // esta comprobacion se daba por buena una descarga truncada (que luego
      // ffmpeg convertia en un mp3 cortado).
      if (total == 0 || received >= total) return true;
      logger.log('downloadUriToFile: truncado en $received/$total, reintento');
    } catch (e) {
      logger.log('downloadUriToFile: intento $attempt fallido para $uri: $e');
    } finally {
      try {
        await sink?.close();
      } catch (_) {}
      client.close();
    }

    if (attempt < _downloadMaxAttempts) {
      await Future<void>.delayed(_downloadRetryDelay);
    }
  }
  return false;
}
