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

import 'package:dskplay/services/audio_service.dart';
import 'package:dskplay/services/common_services.dart';
import 'package:dskplay/services/io_service.dart';
import 'package:dskplay/services/local_files_service.dart';
import 'package:dskplay/utilities/formatter.dart';
import 'package:path_provider/path_provider.dart';

final _youtubeLinkRegex = RegExp(r'(youtube\.com|youtu\.be)');

Future<void> handleYoutubeSharedTextIntent(
  String? value, {
  required DskPlayAudioHandler audioHandler,
  required void Function(Object error, StackTrace stackTrace) onError,
}) async {
  if (value == null || !_youtubeLinkRegex.hasMatch(value)) {
    return;
  }

  final songId = getSongId(value);
  if (songId == null) {
    return;
  }

  try {
    final song = await getSongDetails(0, songId);
    await audioHandler.playSong(song);
  } catch (e, stackTrace) {
    onError(e, stackTrace);
  }
}

Future<void> consumeYoutubeSharedTextIntent(
  String? value, {
  required DskPlayAudioHandler audioHandler,
  required void Function(Object error, StackTrace stackTrace) onError,
}) async {
  if (value == null || value.isEmpty) {
    return;
  }

  final normalizedValue = value.trim();
  if (normalizedValue.isEmpty) {
    return;
  }

  await handleYoutubeSharedTextIntent(
    normalizedValue,
    audioHandler: audioHandler,
    onError: onError,
  );
}

/// Plays an audio file opened or shared from another app (e.g. "Open with"
/// or "Share" from a file manager), using the same local-file pipeline as
/// the Local files tab - including queueing up the rest of its folder, with
/// this file at its own position, exactly like tapping it from that tab would.
/// Returns true if playback was actually started, so callers can react
/// (e.g. opening the full player) only when there was really something to play.
Future<bool> consumeSharedAudioFile(
  String? path, {
  required DskPlayAudioHandler audioHandler,
  required void Function(Object error, StackTrace stackTrace) onError,
}) async {
  if (path == null || path.isEmpty || !isAudioFile(path)) return false;

  // The Local files tab already requires this before letting the user
  // browse, but a file opened/shared from another app skips that screen
  // entirely - without it, reading (and therefore playing) the file
  // silently fails on Android 11+ scoped storage.
  if (!await ensureExportStoragePermission()) return false;

  final file = File(path);
  if (!file.existsSync()) return false;

  try {
    // Some apps share a file via a generic content provider that doesn't
    // expose its real location - the native side then has no choice but to
    // copy it into this app's own cache dir before handing us a path. In
    // that case "the file's folder" would just be our cache dir (full of
    // unrelated previously-shared files), so only play this one file
    // instead of queueing up something meaningless.
    final cacheDir = await getTemporaryDirectory();
    final isCachedCopy = path.startsWith(cacheDir.path);

    final List<File> siblings = isCachedCopy
        ? [file]
        : await listAudioFilesInSameFolder(file);
    final songs = await buildLocalSongMaps(siblings);
    final index = siblings.indexWhere((f) => f.path == file.path);
    await audioHandler.playPlaylistSong(
      playlist: {'list': songs},
      songIndex: index == -1 ? 0 : index,
      // A file opened/shared from another app should start a clean queue
      // matching exactly that folder, not fold in whatever was previously
      // queued manually.
      keepManuallyAddedSongs: false,
    );
    return true;
  } catch (e, stackTrace) {
    onError(e, stackTrace);
    return false;
  }
}
