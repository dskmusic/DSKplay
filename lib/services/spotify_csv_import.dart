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

/// Una fila del CSV exportado desde Spotify. `playlist` y `type` sólo vienen
/// en los exportadores que meten varias secciones en el mismo archivo
/// (TuneMyMusic con la biblioteca entera).
typedef SpotifyTrack = ({
  String title,
  String artist,
  String? playlist,
  String? type,
});

/// Una lista del CSV: su nombre (null si el archivo no lo trae) y sus pistas.
typedef SpotifyPlaylistImport = ({String? name, List<SpotifyTrack> tracks});

/// Todo lo que trae el CSV, ya separado por secciones. Chosic y Exportify
/// sólo llenan `playlists`; TuneMyMusic con la biblioteca entera llena las
/// cuatro.
typedef SpotifyLibrary = ({
  List<SpotifyPlaylistImport> playlists,
  List<SpotifyTrack> likedSongs,
  List<SpotifyTrack> albums,
  List<String> artists,
});

/// Cabeceras de título, en orden de preferencia. Van antes que la búsqueda
/// por palabra suelta porque Exportify abre el CSV con "Track URI": buscar
/// sólo "track" se traería el URI como si fuera el título.
const _titleHeaders = [
  'track name',
  'song name',
  'song title',
  'title',
  'track',
  'song',
  'name',
];

const _artistHeaders = [
  'artist name(s)',
  'artist name',
  'artist names',
  'artist(s)',
  'artists',
  'artist',
];

/// Nunca son el título ni el artista aunque contengan la palabra: son
/// identificadores.
const _neverContentHeaders = ['uri', 'url', 'link', 'id', 'isrc'];

/// Valores de la columna `Type` de TuneMyMusic. Las tres secciones que no
/// son listas guardan el nombre del artista o del disco en la columna del
/// título, no una canción.
const _favoriteSongType = 'favorite';
const _albumType = 'album';
const _artistType = 'artist';

/// Lee el CSV de Chosic, Exportify o TuneMyMusic y separa lo que contiene.
///
/// Las cabeceras cambian según el exportador, así que se localizan por
/// nombre en vez de por posición; si no hay cabecera reconocible se asume
/// `título,artista`.
SpotifyLibrary parseSpotifyCsv(String input) {
  final tracks = parseSpotifyCsvTracks(input);
  final likedSongs = <SpotifyTrack>[];
  final albums = <SpotifyTrack>[];
  final artists = <String>[];
  final rest = <SpotifyTrack>[];

  for (final track in tracks) {
    switch (track.type?.toLowerCase().trim()) {
      case _favoriteSongType:
        likedSongs.add(track);
      case _albumType:
        albums.add(track);
      case _artistType:
        artists.add(track.title);
      default:
        rest.add(track);
    }
  }

  return (
    playlists: groupSpotifyTracks(rest),
    likedSongs: likedSongs,
    albums: albums,
    artists: artists,
  );
}

/// Cuántos elementos se importarían en total (canciones de listas, favoritas,
/// álbumes y artistas).
int countSpotifyLibrary(SpotifyLibrary library) =>
    library.playlists.fold<int>(0, (sum, p) => sum + p.tracks.length) +
    library.likedSongs.length +
    library.albums.length +
    library.artists.length;

/// Las pistas en el orden del archivo, sin agrupar por lista.
List<SpotifyTrack> parseSpotifyCsvTracks(String input) {
  // El BOM de Excel/Exportify se pega a la primera cabecera y la deja sin
  // reconocer.
  final text = input.replaceFirst('﻿', '').trim();
  final rows = _parseRows(text, _detectDelimiter(text));
  if (rows.isEmpty) return const [];

  final header = [
    for (final cell in rows.first)
      cell.toLowerCase().replaceAll('"', '').trim(),
  ];
  var titleIndex = _findHeader(header, _titleHeaders);
  var artistIndex = _findHeader(header, _artistHeaders);
  final playlistIndex = header.indexWhere((h) => h.contains('playlist'));
  final typeIndex = header.indexOf('type');

  final hasHeader = titleIndex != -1 && artistIndex != -1;
  if (!hasHeader) {
    titleIndex = 0;
    artistIndex = 1;
  }

  final tracks = <SpotifyTrack>[];
  for (final row in rows.skip(hasHeader ? 1 : 0)) {
    if (row.length <= titleIndex || row.length <= artistIndex) continue;
    final type = typeIndex != -1 && row.length > typeIndex
        ? row[typeIndex].trim()
        : '';
    final title = row[titleIndex].trim();
    if (title.isEmpty) continue;
    // Varios artistas vienen en un solo campo ("A, B, C"); el primero basta
    // para buscar y los demás sólo ensucian la consulta.
    final artist = row[artistIndex].split(RegExp('[,;]')).first.trim();
    final playlist = playlistIndex != -1 && row.length > playlistIndex
        ? row[playlistIndex].trim()
        : '';
    tracks.add((
      title: title,
      artist: artist,
      playlist: playlist.isEmpty ? null : playlist,
      type: type.isEmpty ? null : type,
    ));
  }
  return tracks;
}

/// Reparte las pistas por lista conservando el orden de aparición. Un CSV de
/// una sola lista (Chosic, Exportify) devuelve un único grupo sin nombre.
List<SpotifyPlaylistImport> groupSpotifyTracks(List<SpotifyTrack> tracks) {
  final groups = <String?, List<SpotifyTrack>>{};
  for (final track in tracks) {
    groups.putIfAbsent(track.playlist, () => []).add(track);
  }
  return [
    for (final entry in groups.entries) (name: entry.key, tracks: entry.value),
  ];
}

int _findHeader(List<String> header, List<String> candidates) {
  for (final candidate in candidates) {
    final exact = header.indexOf(candidate);
    if (exact != -1) return exact;
  }
  for (final candidate in candidates) {
    final index = header.indexWhere(
      (h) =>
          h.contains(candidate) &&
          !_neverContentHeaders.any((bad) => h.contains(bad)),
    );
    if (index != -1) return index;
  }
  return -1;
}

String _detectDelimiter(String input) {
  final firstLine = input.split('\n').first;
  var best = ',';
  var bestCount = 0;
  for (final candidate in [',', ';', '\t']) {
    final count = firstLine.split(candidate).length - 1;
    if (count > bestCount) {
      best = candidate;
      bestCount = count;
    }
  }
  return best;
}

List<List<String>> _parseRows(String input, String delimiter) {
  final rows = <List<String>>[];
  var row = <String>[];
  final field = StringBuffer();
  var inQuotes = false;

  void endField() {
    row.add(field.toString());
    field.clear();
  }

  void endRow() {
    endField();
    if (row.any((f) => f.trim().isNotEmpty)) rows.add(row);
    row = <String>[];
  }

  for (var i = 0; i < input.length; i++) {
    final ch = input[i];
    if (inQuotes) {
      if (ch != '"') {
        field.write(ch);
      } else if (i + 1 < input.length && input[i + 1] == '"') {
        field.write('"');
        i++;
      } else {
        inQuotes = false;
      }
    } else if (ch == '"') {
      inQuotes = true;
    } else if (ch == delimiter) {
      endField();
    } else if (ch == '\n' || ch == '\r') {
      if (ch == '\r' && i + 1 < input.length && input[i + 1] == '\n') i++;
      endRow();
    } else {
      field.write(ch);
    }
  }
  endRow();
  return rows;
}
