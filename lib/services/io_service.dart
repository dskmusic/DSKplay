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

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

const MethodChannel _mediaScannerChannel = MethodChannel(
  'dskplay/media_scanner',
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

  // Directory names
  static const String tracksDir = 'tracks';
  static const String artworksDir = 'artworks';

  // Get full paths for various file types
  static String getAudioPath(String songId) {
    return '$applicationDirPath/$tracksDir/$songId$audioExtension';
  }

  static String getArtworkPath(String songId) {
    return '$applicationDirPath/$artworksDir/$songId$artworkExtension';
  }

  // Ensure directories exist
  static Future<void> ensureDirectoriesExist() async {
    final tracksDirectory = Directory('$applicationDirPath/$tracksDir');
    final artworksDirectory = Directory('$applicationDirPath/$artworksDir');

    if (!await tracksDirectory.exists()) {
      await tracksDirectory.create(recursive: true);
    }

    if (!await artworksDirectory.exists()) {
      await artworksDirectory.create(recursive: true);
    }
  }
}
