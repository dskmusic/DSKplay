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

import 'package:dskplay/services/newpipe.dart';

const _noiseTerms =
    'official music video|official lyric video|official lyrics video|'
    'official video|official 4k video|official audio|lyric video|'
    'lyrics video|official hd video|lyric visualizer|lyric vizualizer|'
    'official visualizer|official vizualizer|official visualiser|official vizualiser|lyrics|lyric|official song clip|'
    'official|karaoke';

// Bracket groups that contain a noise term anywhere inside: (Official Video)
final _bracketedNoisePattern = RegExp(
  r'[\(\[][^\)\]]*(?:' + _noiseTerms + r')[^\)\]]*[\)\]]',
  caseSensitive: false,
);

// Same noise phrases unbracketed at the end of a title, e.g. after | is stripped.
final _trailingNoisePattern = RegExp(
  r'\s*[-–—]?\s*\b(?:' + _noiseTerms + r'|audio)\b\s*$',
  caseSensitive: false,
);

String formatSongTitle(String title) {
  // Remove bracketed groups first to avoid false matches on real title words.
  var t = title.replaceAll(_bracketedNoisePattern, '');

  // Strip lone brackets, pipes, and decode HTML entities.
  t = t
      .replaceAll(RegExp(r'[\[\]()|]'), '')
      .replaceAll('&amp;', '&')
      .replaceAll('&#039;', "'")
      .replaceAll('&quot;', '"')
      .trimLeft();

  // Strip trailing unbracketed noise; loop to handle stacked suffixes.
  String prev;
  do {
    prev = t;
    t = t.replaceAll(_trailingNoisePattern, '');
  } while (t != prev);

  return t.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
}

Map<String, dynamic> returnSongLayout(
  int index,
  Video song, {
  String? playlistImage,
}) {
  // Split only on the first ' - ' so dashes inside the title are preserved.
  final sep = song.title.indexOf(' - ');
  final artist = sep != -1 ? song.title.substring(0, sep) : song.author;
  final rawTitle = sep != -1 ? song.title.substring(sep + 3) : song.title;
  final title = formatSongTitle(rawTitle);

  return {
    'id': index,
    'ytid': song.id,
    'title': title.isEmpty ? rawTitle.trim() : title,
    'artist': artist,
    'artistId': song.channelId,
    'videoAuthor': song.author,
    'image': playlistImage ?? song.thumbnails.standardResUrl,
    'lowResImage': playlistImage ?? song.thumbnails.lowResUrl,
    'highResImage': playlistImage ?? song.thumbnails.maxResUrl,
    'duration': song.duration?.inSeconds,
    'isLive': song.isLive,
  };
}

/// Miniatura de YouTube reconstruida desde el id del video.
///
/// Las listas guardadas (sugeridas que se anaden a la biblioteca, importadas,
/// copias antiguas...) a veces llegan sin `image`/`lowResImage` y la fila se
/// quedaba con el cubo gris. Estas URLs de `i.ytimg.com` son deterministas y
/// no caducan, asi que se pueden recomponer con solo el id.
String? youtubeThumbnailUrl(String? ytid, {bool highRes = false}) {
  final id = ytid?.trim() ?? '';
  // Los ids de YouTube son 11 caracteres. Los internos de la app
  // ('customId-...', episodios de podcast) no sirven aqui.
  if (id.length != 11 || id.contains('/')) return null;
  final quality = highRes ? 'hqdefault' : 'mqdefault';
  return 'https://i.ytimg.com/vi/$id/$quality.jpg';
}

/// Imagen de una cancion, con reserva a partir del id cuando el mapa guardado
/// no trae ninguna. Devuelve cadena vacia si no hay nada que pintar.
String songArtworkUrl(dynamic song, {bool highRes = false}) {
  if (song is! Map) return '';
  const lowFirst = ['lowResImage', 'image', 'highResImage'];
  const highFirst = ['highResImage', 'image', 'lowResImage'];
  for (final key in highRes ? highFirst : lowFirst) {
    final value = song[key]?.toString().trim() ?? '';
    if (value.isNotEmpty && value != 'null') return value;
  }
  return youtubeThumbnailUrl(song['ytid']?.toString(), highRes: highRes) ?? '';
}

String? getSongId(String url) => VideoId.parseVideoId(url);

String formatDuration(int audioDurationInSeconds) {
  final duration = Duration(seconds: audioDurationInSeconds);

  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  final seconds = duration.inSeconds.remainder(60);

  return [
    if (hours > 0) hours.toString().padLeft(2, '0'),
    minutes.toString().padLeft(2, '0'),
    seconds.toString().padLeft(2, '0'),
  ].join(':');
}
