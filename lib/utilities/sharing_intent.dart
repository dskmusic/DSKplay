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

import 'package:musify/services/audio_service.dart';
import 'package:musify/services/common_services.dart';
import 'package:musify/services/local_files_service.dart';
import 'package:musify/utilities/formatter.dart';

final _youtubeLinkRegex = RegExp(r'(youtube\.com|youtu\.be)');

Future<void> handleYoutubeSharedTextIntent(
  String? value, {
  required MusifyAudioHandler audioHandler,
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
  required MusifyAudioHandler audioHandler,
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
/// the Local files tab.
Future<void> consumeSharedAudioFile(
  String? path, {
  required MusifyAudioHandler audioHandler,
  required void Function(Object error, StackTrace stackTrace) onError,
}) async {
  if (path == null || path.isEmpty || !isAudioFile(path)) return;

  final file = File(path);
  if (!file.existsSync()) return;

  try {
    final song = await buildLocalSongMap(file);
    await audioHandler.playPlaylistSong(
      playlist: {
        'list': [song],
      },
      songIndex: 0,
    );
  } catch (e, stackTrace) {
    onError(e, stackTrace);
  }
}
