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
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
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
