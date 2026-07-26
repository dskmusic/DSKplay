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

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:dskplay/main.dart' show logger;
import 'package:dskplay/services/common_services.dart';
import 'package:dskplay/services/io_service.dart';

/// Kept as an alias so existing call sites/imports don't need to change.
const String exportDirPath = downloadedMusicDirPath;

String _sanitizeFileName(String name) {
  final sanitized = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
  return sanitized.isEmpty ? 'song' : sanitized;
}

/// Downloads (if needed) and copies/converts a song into [exportDirPath],
/// as .mp3 when [asMp3] is true, otherwise as the original .m4a.
/// Returns the saved file path, or null on failure.
Future<String?> exportSongToDevice(dynamic song, {required bool asMp3}) async {
  try {
    final String? ytid = song['ytid'];
    if (ytid == null || ytid.isEmpty) return null;

    if (!await ensureExportStoragePermission()) {
      logger.log('exportSongToDevice: storage permission denied');
      return null;
    }

    // Downloads/refreshes a locally cached, tagged copy of the audio
    // without registering it in the offline library — that should only
    // happen via the explicit "download offline" action, not from
    // exporting a one-off MP3/M4A copy.
    if (!await downloadAndTagAudioFile(song)) {
      return null;
    }
    final sourcePath = FilePaths.getAudioPath(ytid);
    if (!await File(sourcePath).exists()) return null;

    final exportDir = Directory(exportDirPath);
    if (!await exportDir.exists()) await exportDir.create(recursive: true);

    final title = _sanitizeFileName(song['title']?.toString() ?? ytid);
    final artist = song['artist']?.toString().trim() ?? '';
    final baseName = artist.isEmpty
        ? title
        : _sanitizeFileName('$artist - $title');

    if (asMp3) {
      final destPath = '$exportDirPath/$baseName.mp3';
      // -map 0:v? (optional) carries over the embedded cover art as the
      // mp3's ID3 attached picture instead of -vn, which would strip it;
      // metadata (title/artist/album) is copied along by default too.
      final session = await FFmpegKit.execute(
        '-y -i "$sourcePath" -map 0:a -map 0:v? -c:a libmp3lame -ar 44100 '
        '-ac 2 -b:a 192k -c:v copy -id3v2_version 3 "$destPath"',
      );
      final returnCode = await session.getReturnCode();
      if (!ReturnCode.isSuccess(returnCode)) {
        logger.log('exportSongToDevice: ffmpeg conversion failed for $ytid');
        return null;
      }
      await scanMediaFile(destPath);
      return destPath;
    }

    final destPath = '$exportDirPath/$baseName.m4a';
    await File(sourcePath).copy(destPath);
    await scanMediaFile(destPath);
    return destPath;
  } catch (e, stackTrace) {
    logger.log('Error exporting song to device', error: e, stackTrace: stackTrace);
    return null;
  }
}
