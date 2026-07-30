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
import 'package:dskplay/services/common_services.dart';
import 'package:dskplay/services/download_foreground_service.dart';
import 'package:dskplay/services/io_service.dart';

/// Kept as an alias so existing call sites/imports don't need to change.
const String exportDirPath = downloadedMusicDirPath;

/// Downloads and copies a song into [exportDirPath] as .mp3 (or, when
/// [folder] is given, into a subfolder of it — used for playlist/album
/// exports so their songs land together instead of in the Descargas root).
/// Uses a private temp cache for the download/tagging step (see
/// [downloadAndTagAudioFile]) rather than the shared offline cache, so a
/// manual "download to device" never leaves anything under the public
/// offline folder. Returns the saved file path, or null on failure.
Future<String?> exportSongToDevice(
  dynamic song, {
  void Function(double progress)? onProgress,
  String? folder,
}) async {
  String? tempSourcePath;
  // Covers the whole export, not just the temp download/transcode step -
  // releasing right after that left the final copy-to-destination step
  // below unprotected, so the engine could be torn down before the file
  // ever reached its real destination (only the orphaned temp copy would
  // exist). Awaited so no bytes are downloaded before the protective
  // service is confirmed up.
  await DownloadForegroundService.acquire();
  try {
    final String? ytid = song['ytid'];
    if (ytid == null || ytid.isEmpty) return null;

    if (!await ensureExportStoragePermission()) {
      logger.log('exportSongToDevice: storage permission denied');
      return null;
    }

    tempSourcePath = await downloadAndTagAudioFile(
      song,
      onProgress: onProgress,
    );
    if (tempSourcePath == null || !await File(tempSourcePath).exists()) {
      return null;
    }

    final destDirPath = (folder != null && folder.isNotEmpty)
        ? '$exportDirPath/$folder'
        : exportDirPath;
    final exportDir = Directory(destDirPath);
    if (!await exportDir.exists()) await exportDir.create(recursive: true);

    final title = sanitizeFileName(song['title']?.toString() ?? ytid);
    final artist = song['artist']?.toString().trim() ?? '';
    final baseName = artist.isEmpty
        ? title
        : sanitizeFileName('$artist - $title');

    final destPath = '$destDirPath/$baseName.mp3';
    await File(tempSourcePath).copy(destPath);
    await scanMediaFile(destPath);
    notifyLocalFilesChanged();
    return destPath;
  } catch (e, stackTrace) {
    logger.log('Error exporting song to device', error: e, stackTrace: stackTrace);
    return null;
  } finally {
    try {
      if (tempSourcePath != null && await File(tempSourcePath).exists()) {
        await File(tempSourcePath).delete();
      }
    } catch (_) {}
    DownloadForegroundService.release();
  }
}

/// Sequentially exports every song in [playlist]'s `list` into a subfolder
/// of [exportDirPath] named after the playlist/album title. Returns the
/// number of songs saved vs. failed.
Future<({int completed, int failed})> exportPlaylistToDevice(
  Map playlist, {
  void Function(int completed, int total)? onProgress,
}) async {
  final songs = List<dynamic>.from(playlist['list'] as List? ?? []);
  if (songs.isEmpty) return (completed: 0, failed: 0);

  final folder = sanitizeFileName(
    playlist['title']?.toString() ?? 'Playlist',
  );
  var completed = 0;
  var failed = 0;
  // Held for the whole playlist, on top of each song's own acquire/release
  // in exportSongToDevice - without this, the protection count could
  // momentarily hit zero between songs, which was enough of a gap for the
  // engine to get torn down before the next song ever got protected again.
  await DownloadForegroundService.acquire();
  try {
    for (final song in songs) {
      if (DownloadForegroundService.cancelAllRequested) break;
      final path = await exportSongToDevice(song, folder: folder);
      if (path != null) {
        completed++;
      } else {
        failed++;
      }
      onProgress?.call(completed + failed, songs.length);
    }
  } finally {
    DownloadForegroundService.release();
  }
  return (completed: completed, failed: failed);
}
