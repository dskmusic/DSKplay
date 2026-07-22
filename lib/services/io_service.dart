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

import 'package:permission_handler/permission_handler.dart';

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

class FilePaths {
  // File extensions
  static const String audioExtension = '.m4a';
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
