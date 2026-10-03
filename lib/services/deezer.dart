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

import 'dart:convert';

import 'package:dskplay/services/newpipe.dart';
import 'package:dskplay/services/ytmusic.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

/// Respaldo de [MusicClient] contra la API pública de Deezer: la misma ficha de
/// artista (foto, fans, top de canciones, discografía con año y tipo) para
/// cuando YouTube Music cambie sus renderers y el parseo de `ytmusic.dart` se
/// quede a cero. Elegible a mano en ajustes, para poder probarlo sin esperar al
/// fallo.
///
/// No necesita clave ni registro. Lo que Deezer NO tiene son ids de YouTube, y
/// de ellos cuelga todo lo demás de la app (reproducir, navegar, cachear), así
/// que cada nombre hay que resolverlo con [NewPipe.search]: de ahí que esta
/// fuente sea más lenta y menos exacta que YouTube Music, que ya trae los ids
/// puestos.

const _apiBase = 'https://api.deezer.com';
const _httpTimeout = Duration(seconds: 12);

/// Los ids de release de Deezer son numéricos y chocarían con los `MPREb_...`
/// de YouTube Music, que viajan por las mismas cachés y rutas: van marcados
/// para que [albumIdIsDeezer] sepa a quién preguntar por ellos.
const deezerAlbumIdPrefix = 'dz:';

bool albumIdIsDeezer(String albumId) => albumId.startsWith(deezerAlbumIdPrefix);

/// ponytail: topes bajos a propósito. Cada pista de Deezer cuesta UNA búsqueda
/// en YouTube para sacar su videoId, así que un perfil son ~12 llamadas. Si
/// algún día hace falta la lista larga, subir esto.
const _topSongsLimit = 5;
const _relatedArtistsLimit = 5;
const _albumTracksLimit = 25;

class DeezerClient implements MusicSource {
  /// [httpClient] solo lo pasa el test: en la app se usa el de siempre.
  const DeezerClient({http.Client? httpClient}) : _httpClient = httpClient;

  final http.Client? _httpClient;

  @override
  Future<List<MusicArtist>> searchArtists(String query) async {
    final rows = _rowsOf(
      await _get('/search/artist', {'q': query.trim(), 'limit': '5'}),
    );

    final artists = <MusicArtist>[];
    for (final row in rows) {
      final name = _text(row['name']);
      if (name.isEmpty) continue;

      final channelId = await _youtubeChannelId(name);
      if (channelId == null) continue;

      artists.add(
        MusicArtist(id: channelId, name: name, thumbnailUrl: _picture(row)),
      );
    }
    return artists;
  }

  @override
  Future<MusicArtistProfile> getArtistProfile(
    String channelId, {
    String? name,
  }) async {
    final artistName = (name ?? '').trim();
    final artist = await _findArtist(artistName);
    if (artist == null) {
      return MusicArtistProfile(id: channelId, name: artistName);
    }

    final deezerId = _text(artist['id']);
    final displayName = _text(artist['name'], fallback: artistName);
    final results = await Future.wait([
      _get('/artist/$deezerId/top', {'limit': '$_topSongsLimit'}),
      _get('/artist/$deezerId/albums', {'limit': '100'}),
      _get('/artist/$deezerId/related', {'limit': '$_relatedArtistsLimit'}),
    ]);

    final topVideos = await Future.wait([
      for (final track in _rowsOf(results[0]).take(_topSongsLimit))
        _resolveTrack(
          title: _text(track['title']),
          artist: displayName,
          channelId: channelId,
          seconds: _seconds(track['duration']),
        ),
    ]);

    return MusicArtistProfile(
      id: channelId,
      name: displayName,
      thumbnailUrl: _picture(artist),
      // Deezer no publica oyentes mensuales: lo más parecido es su número de
      // fans, ya compactado ("1,2M") porque la UI lo enseña tal cual.
      monthlyListeners: _fanCount(artist['nb_fan']),
      topSongs: [
        for (final video in topVideos)
          // Tampoco da reproducciones por canción (su `rank` es otra cosa),
          // así que sin contador: la UI lo oculta sola.
          if (video != null) MusicTopSong(video, null),
      ],
      releases: _releasesOf(results[1]),
      relatedArtists: await _relatedOf(results[2]),
    );
  }

  @override
  Future<List<MusicAlbum>> getArtistReleases(
    String channelId, {
    String? name,
  }) async {
    final artist = await _findArtist((name ?? '').trim());
    if (artist == null) return [];

    return _releasesOf(
      await _get('/artist/${_text(artist['id'])}/albums', {'limit': '100'}),
    );
  }

  @override
  Future<MusicReleasePage> getAlbum(String albumId) async {
    final deezerId = _stripPrefix(albumId);
    final album = await _get('/album/$deezerId', const {});
    if (album == null) throw StateError('Deezer album $deezerId not found');

    final artist = album['artist'];
    final artistName = artist is Map ? _text(artist['name']) : '';
    final tracks = await _resolveTracks(
      _rowsOf(album['tracks']),
      artist: artistName,
      channelId: null,
    );

    return MusicReleasePage(
      id: albumId,
      title: _text(album['title']),
      artist: artistName.isEmpty ? null : artistName,
      thumbnailUrl: _cover(album),
      year: _year(album['release_date']),
      tracks: tracks,
    );
  }

  @override
  Future<List<Video>> getAlbumTracks(
    String albumId, {
    required String author,
    String? channelId,
  }) async {
    final deezerId = _stripPrefix(albumId);
    return _resolveTracks(
      _rowsOf(await _get('/album/$deezerId/tracks', {'limit': '50'})),
      artist: author,
      channelId: channelId,
    );
  }

  // --- Deezer ---

  Future<Map<String, dynamic>?> _get(
    String path,
    Map<String, String> query,
  ) async {
    final uri = Uri.parse(
      '$_apiBase$path',
    ).replace(queryParameters: query.isEmpty ? null : query);
    final response = await (_httpClient?.get(uri) ?? http.get(uri)).timeout(
      _httpTimeout,
    );
    if (response.statusCode != 200) return null;

    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map<String, dynamic>) return null;
    // Deezer contesta 200 con {"error": {...}} cuando algo no existe o se le
    // va la mano con el ritmo de peticiones.
    if (decoded['error'] != null) return null;
    return decoded;
  }

  /// El artista de Deezer que mejor casa con [name], o null si no hay ninguno.
  Future<Map<String, dynamic>?> _findArtist(String name) async {
    if (name.isEmpty) return null;

    final rows = _rowsOf(
      await _get('/search/artist', {'q': name, 'limit': '5'}),
    );
    if (rows.isEmpty) return null;

    final wanted = _canonical(name);
    for (final row in rows) {
      if (_canonical(_text(row['name'])) == wanted) return row;
    }
    return rows.first;
  }

  List<MusicAlbum> _releasesOf(Map<String, dynamic>? payload) {
    final releases = <String, MusicAlbum>{};
    for (final row in _rowsOf(payload)) {
      final id = _text(row['id']);
      final title = _text(row['title']);
      if (id.isEmpty || title.isEmpty) continue;

      releases.putIfAbsent(
        id,
        () => MusicAlbum(
          '$deezerAlbumIdPrefix$id',
          title,
          thumbnailUrl: _cover(row),
          type: _releaseType(_text(row['record_type'])),
          year: _year(row['release_date']),
        ),
      );
    }
    return releases.values.toList();
  }

  Future<List<MusicArtist>> _relatedOf(Map<String, dynamic>? payload) async {
    final artists = <MusicArtist>[];
    for (final row in _rowsOf(payload).take(_relatedArtistsLimit)) {
      final name = _text(row['name']);
      if (name.isEmpty) continue;

      final channelId = await _youtubeChannelId(name);
      if (channelId == null) continue;

      artists.add(
        MusicArtist(id: channelId, name: name, thumbnailUrl: _picture(row)),
      );
    }
    return artists;
  }

  // --- YouTube: lo que Deezer no puede dar ---

  /// Canal `UC...` del artista [name], que es como lo identifica la app.
  Future<String?> _youtubeChannelId(String name) async {
    try {
      final items = await NewPipe.search(
        name,
        filters: const [SearchFilter.channels],
      );
      for (final item in items) {
        if (item['type'] != 'channel') continue;
        final id = item['id']?.toString() ?? '';
        if (id.startsWith('UC')) return id;
      }
    } catch (_) {
      // Sin canal no hay artista que abrir: se descarta la fila.
    }
    return null;
  }

  Future<List<Video>> _resolveTracks(
    List<Map<String, dynamic>> rows, {
    required String artist,
    required String? channelId,
  }) async {
    final resolved = await Future.wait([
      for (final row in rows.take(_albumTracksLimit))
        _resolveTrack(
          title: _text(row['title']),
          artist: artist,
          channelId: channelId,
          seconds: _seconds(row['duration']),
        ),
    ]);
    return [
      for (final video in resolved)
        if (video != null) video,
    ];
  }

  /// Busca la pista en YouTube y se queda con la que mejor cuadra en duración:
  /// buscar por texto trae remixes, directos y reacciones de veinte minutos, y
  /// la duración es lo único que Deezer da para distinguirlos.
  Future<Video?> _resolveTrack({
    required String title,
    required String artist,
    required String? channelId,
    required int seconds,
  }) async {
    if (title.isEmpty) return null;

    try {
      final query = artist.isEmpty ? title : '$artist $title';
      final candidates = NewPipe.videosOf(
        await NewPipe.search(query, filters: const [SearchFilter.videos]),
      ).where((video) => !video.isLive).take(5).toList();
      if (candidates.isEmpty) return null;

      var best = candidates.first;
      if (seconds > 0) {
        var bestGap = _durationGap(best, seconds);
        for (final candidate in candidates.skip(1)) {
          final gap = _durationGap(candidate, seconds);
          if (gap < bestGap) {
            best = candidate;
            bestGap = gap;
          }
        }
      }

      return Video(
        id: best.id,
        title: title,
        author: artist.isEmpty ? best.author : artist,
        channelId: channelId ?? best.channelId,
        duration: best.duration ?? Duration(seconds: seconds),
      );
    } catch (_) {
      return null;
    }
  }

  int _durationGap(Video video, int seconds) {
    final duration = video.duration;
    if (duration == null) return 1 << 20;
    return (duration.inSeconds - seconds).abs();
  }

  // --- JSON ---

  List<Map<String, dynamic>> _rowsOf(Object? payload) {
    final data = payload is Map ? payload['data'] : null;
    if (data is! List) return const [];
    return [
      for (final row in data)
        if (row is Map) Map<String, dynamic>.from(row),
    ];
  }

  String _text(Object? value, {String fallback = ''}) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty || text == 'null' ? fallback : text;
  }

  String? _picture(Map<String, dynamic> row) => _firstUrl(row, const [
    'picture_xl',
    'picture_big',
    'picture_medium',
    'picture',
  ]);

  String? _cover(Map<String, dynamic> row) =>
      _firstUrl(row, const ['cover_xl', 'cover_big', 'cover_medium', 'cover']);

  String? _firstUrl(Map<String, dynamic> row, List<String> keys) {
    for (final key in keys) {
      final url = _text(row[key]);
      if (url.isNotEmpty) return url;
    }
    return null;
  }

  String? _year(Object? releaseDate) {
    final date = _text(releaseDate);
    return date.length >= 4 ? date.substring(0, 4) : null;
  }

  int _seconds(Object? duration) =>
      duration is num ? duration.toInt() : int.tryParse(_text(duration)) ?? 0;

  String? _fanCount(Object? fans) {
    final count = fans is num ? fans.toInt() : int.tryParse(_text(fans)) ?? 0;
    return count > 0 ? NumberFormat.compact().format(count) : null;
  }

  MusicReleaseType _releaseType(String recordType) => switch (recordType) {
    'album' => MusicReleaseType.album,
    'single' => MusicReleaseType.single,
    'ep' => MusicReleaseType.ep,
    _ => MusicReleaseType.other,
  };

  String _canonical(String value) =>
      value.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');

  String _stripPrefix(String albumId) => albumId.startsWith(deezerAlbumIdPrefix)
      ? albumId.substring(deezerAlbumIdPrefix.length)
      : albumId;
}

/// Instancia compartida: no guarda estado, cada llamada es un GET.
const deezer = DeezerClient();
