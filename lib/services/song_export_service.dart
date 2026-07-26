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
import 'package:dskplay/services/io_service.dart';

/// Kept as an alias so existing call sites/imports don't need to change.
const String exportDirPath = downloadedMusicDirPath;

String _sanitizeFileName(String name) {
  final sanitized = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
  return sanitized.isEmpty ? 'song' : sanitized;
}

/// Downloads and copies a song into [exportDirPath] as .mp3. Uses a
/// private temp cache for the download/tagging step (see
/// [downloadAndTagAudioFile]) rather than the shared offline cache, so a
/// manual "download to device" never leaves anything under the public
/// offline folder. Returns the saved file path, or null on failure.
Future<String?> exportSongToDevice(
  dynamic song, {
  void Function(double progress)? onProgress,
}) async {
  String? tempSourcePath;
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

    final exportDir = Directory(exportDirPath);
    if (!await exportDir.exists()) await exportDir.create(recursive: true);

    final title = _sanitizeFileName(song['title']?.toString() ?? ytid);
    final artist = song['artist']?.toString().trim() ?? '';
    final baseName = artist.isEmpty
        ? title
        : _sanitizeFileName('$artist - $title');

    final destPath = '$exportDirPath/$baseName.mp3';
    await File(tempSourcePath).copy(destPath);
    await scanMediaFile(destPath);
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
  }
}
