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

import 'package:audio_service/audio_service.dart';
import 'package:musify/services/common_services.dart';

Map mediaItemToMap(MediaItem mediaItem) {
  final extras = mediaItem.extras;
  return {
    'id': mediaItem.id,
    'ytid': extras?['ytid'],
    'album': mediaItem.album.toString(),
    'artist': mediaItem.artist.toString(),
    'title': mediaItem.title,
    'artistId': extras?['artistId'],
    'videoAuthor': extras?['videoAuthor'],
    'highResImage': extras?['highResImage'] ?? mediaItem.artUri.toString(),
    'lowResImage': extras?['lowResImage'],
    'isLive': extras?['isLive'] ?? false,
  };
}

MediaItem mapToMediaItem(Map song) {
  final ytid = song['ytid']?.toString();
  final offlineSong = ytid != null
      ? getOfflineSongByYtid(ytid)
      : <String, dynamic>{};
  final isOffline = offlineSong.isNotEmpty;

  // Downloaded-offline songs keep their artwork in the offline DB; local
  // files (never in that DB) carry their own `artworkPath` directly on
  // the song map instead (e.g. extracted from an ID3/Vorbis/MP4 tag).
  final artworkPath =
      (isOffline ? offlineSong['artworkPath'] : song['artworkPath'])
          ?.toString();
  final hasArtworkFile = artworkPath != null && artworkPath.isNotEmpty;

  final artUri = hasArtworkFile
      ? Uri.file(artworkPath)
      : Uri.parse(song['highResImage'].toString());

  return MediaItem(
    id: song['id'].toString(),
    artist: song['artist'].toString().trim(),
    title: song['title'].toString(),
    artUri: artUri,
    duration: song['duration'] != null
        ? Duration(seconds: song['duration'])
        : null,
    extras: {
      'lowResImage': song['lowResImage'],
      'ytid': song['ytid'],
      'artistId': song['artistId'],
      'videoAuthor': song['videoAuthor'],
      'isLive': song['isLive'],
      'highResImage': song['highResImage'],
      'artWorkPath': hasArtworkFile
          ? artworkPath
          : (song['highResImage']?.toString() ?? ''),
    },
  );
}

/// Compares two Duration objects with tolerance for minor differences.
///
/// This prevents unnecessary updates when duration values have minor variations
/// (e.g., due to buffering or precision differences).
bool durationEquals(Duration? prev, Duration? curr) {
  if (prev == curr) return true;
  if (prev == null || curr == null) return prev == curr;

  // Consider durations equal if they differ by less than 1 second
  return (prev - curr).abs() < const Duration(seconds: 1);
}
