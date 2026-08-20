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

import 'package:flutter/services.dart';

/// Cliente Dart de NewPipeExtractor, al otro lado del MethodChannel que
/// registra `NewPipeBridge.kt`. Sustituye a `youtube_explode_dart`.
///
/// Los modelos de abajo ([Video], [ThumbnailSet], [AudioStreamInfo]...) llevan
/// a propósito los mismos nombres y campos que usaba youtube_explode_dart, para
/// que el resto de la app (sobre todo `returnSongLayout`) no cambie.
///
/// Toda llamada puede lanzar [PlatformException]; los llamadores ya lo capturan.

const _channel = MethodChannel('com.dskmusic.dskplay/newpipe');

/// Miniaturas de un vídeo. YouTube las sirve por convención de nombre a partir
/// del id, así que no hace falta traerlas del lado nativo.
class ThumbnailSet {
  const ThumbnailSet(this.videoId);

  final String videoId;

  String get lowResUrl => 'https://img.youtube.com/vi/$videoId/default.jpg';
  String get mediumResUrl => 'https://img.youtube.com/vi/$videoId/mqdefault.jpg';
  String get standardResUrl =>
      'https://img.youtube.com/vi/$videoId/sddefault.jpg';
  String get highResUrl => 'https://img.youtube.com/vi/$videoId/hqdefault.jpg';
  String get maxResUrl =>
      'https://img.youtube.com/vi/$videoId/maxresdefault.jpg';
}

class Video {
  Video({
    required this.id,
    required this.title,
    required this.author,
    required this.channelId,
    this.duration,
    this.isLive = false,
  });

  factory Video.fromMap(Map map) {
    final seconds = (map['duration'] as num?)?.toInt() ?? 0;
    return Video(
      id: map['id'] as String,
      title: (map['title'] as String?) ?? '',
      author: (map['author'] as String?) ?? '',
      channelId: (map['channelId'] as String?) ?? '',
      duration: seconds > 0 ? Duration(seconds: seconds) : null,
      isLive: (map['isLive'] as bool?) ?? false,
    );
  }

  final String id;
  final String title;
  final String author;
  final String channelId;
  final Duration? duration;
  final bool isLive;

  ThumbnailSet get thumbnails => ThumbnailSet(id);

  @override
  String toString() => 'Video($id, $title)';
}

/// Lista de reproducción o álbum de YouTube.
class YtPlaylist {
  const YtPlaylist({
    required this.id,
    required this.title,
    required this.author,
    required this.channelId,
    required this.thumbnail,
    this.streamCount = 0,
    this.description = '',
  });

  factory YtPlaylist.fromMap(Map map) => YtPlaylist(
    id: map['id'] as String,
    title: (map['title'] as String?) ?? '',
    author: (map['author'] as String?) ?? '',
    channelId: (map['channelId'] as String?) ?? '',
    thumbnail: (map['thumbnail'] as String?) ?? '',
    streamCount: (map['streamCount'] as num?)?.toInt() ?? 0,
    description: (map['description'] as String?) ?? '',
  );

  final String id;
  final String title;
  final String author;
  final String channelId;
  final String thumbnail;
  final int streamCount;
  final String description;
}

class YtChannel {
  const YtChannel({
    required this.id,
    required this.title,
    required this.thumbnail,
    this.description = '',
    this.subscriberCount = 0,
    this.banner = '',
  });

  factory YtChannel.fromMap(Map map) => YtChannel(
    id: map['id'] as String,
    title: (map['title'] as String?) ?? '',
    thumbnail: (map['thumbnail'] as String?) ?? '',
    description: (map['description'] as String?) ?? '',
    subscriberCount: (map['subscriberCount'] as num?)?.toInt() ?? 0,
    banner: (map['banner'] as String?) ?? '',
  );

  final String id;
  final String title;
  final String thumbnail;
  final String description;
  final int subscriberCount;
  final String banner;
}

/// Un stream de SOLO audio. [url] caduca (unas horas): hay que volver a
/// pedirla antes de reproducir, igual que con youtube_explode_dart.
class AudioStreamInfo {
  const AudioStreamInfo({
    required this.url,
    required this.bitrate,
    required this.itag,
    required this.codec,
    required this.mime,
    required this.container,
  });

  factory AudioStreamInfo.fromMap(Map map) => AudioStreamInfo(
    url: (map['url'] as String?) ?? '',
    bitrate: (map['bitrate'] as num?)?.toInt() ?? 0,
    itag: (map['itag'] as num?)?.toInt() ?? 0,
    codec: (map['codec'] as String?) ?? '',
    mime: (map['mime'] as String?) ?? '',
    container: (map['container'] as String?) ?? '',
  );

  final String url;
  final int bitrate;
  final int itag;

  /// p.ej. `mp4a.40.2`, `opus`.
  final String codec;

  /// p.ej. `audio/mp4`.
  final String mime;

  /// p.ej. `m4a`, `webm`.
  final String container;
}

extension AudioStreamList on List<AudioStreamInfo> {
  /// De mayor a menor bitrate (el nativo ya los manda así; se reordena por si
  /// la lista viene de otro sitio).
  List<AudioStreamInfo> sortByBitrate() =>
      List<AudioStreamInfo>.from(this)
        ..sort((a, b) => b.bitrate.compareTo(a.bitrate));

  AudioStreamInfo withHighestBitrate() =>
      reduce((a, b) => b.bitrate > a.bitrate ? b : a);
}

/// Detalles de un vídeo más sus streams de audio, en una sola llamada nativa.
class VideoStreams {
  const VideoStreams({
    required this.video,
    required this.audioOnly,
    required this.hlsUrl,
  });

  factory VideoStreams.fromMap(Map map) => VideoStreams(
    video: Video.fromMap(map),
    audioOnly: [
      for (final s in (map['audio'] as List? ?? const []))
        AudioStreamInfo.fromMap(s as Map),
    ],
    hlsUrl: (map['hlsUrl'] as String?) ?? '',
  );

  final Video video;
  final List<AudioStreamInfo> audioOnly;
  final String hlsUrl;
}

/// Filtros de búsqueda de NewPipeExtractor
/// (`YoutubeSearchQueryHandlerFactory`).
abstract final class SearchFilter {
  static const videos = 'videos';
  static const channels = 'channels';
  static const playlists = 'playlists';
  static const musicSongs = 'music_songs';
  static const musicVideos = 'music_videos';
  static const musicAlbums = 'music_albums';
  static const musicPlaylists = 'music_playlists';
  static const musicArtists = 'music_artists';
}

/// Pestañas de un canal (`ChannelTabs` de NewPipeExtractor).
abstract final class ChannelTab {
  static const videos = 'videos';
  static const playlists = 'playlists';
  static const albums = 'albums';
  static const shorts = 'shorts';
  static const livestreams = 'livestreams';
}

abstract final class NewPipe {
  /// Busca en YouTube. [pages] son páginas de ~20 resultados.
  ///
  /// Devuelve los mapas crudos: cada uno trae `type` (`video`/`playlist`/
  /// `channel`) para poder separarlos con [videosOf]/[playlistsOf].
  static Future<List<Map>> search(
    String query, {
    List<String> filters = const [SearchFilter.videos],
    int pages = 1,
  }) async {
    final res = await _channel.invokeListMethod<Object?>('search', {
      'query': query,
      'filters': filters,
      'pages': pages,
    });
    return (res ?? const []).cast<Map>();
  }

  /// Enruta la extracción por un proxy HTTP `ip:puerto`, o directo si es null.
  /// Es estado global del proceso: la siguiente llamada ya lo usa.
  static Future<void> setProxy(String? hostPort) =>
      _channel.invokeMethod<void>('setProxy', {'proxy': hostPort});

  static Future<List<String>> suggestions(String query) async =>
      (await _channel.invokeListMethod<String>('suggestions', {
        'query': query,
      })) ??
      const [];

  static Future<Video> video(String id) async =>
      Video.fromMap((await _channel.invokeMethod<Map>('video', {'id': id}))!);

  static Future<List<Video>> related(String id) async {
    final res = await _channel.invokeListMethod<Object?>('related', {'id': id});
    return [for (final m in res ?? const []) Video.fromMap(m! as Map)];
  }

  /// Detalles + streams de audio. Es la llamada cara: una sola por canción.
  static Future<VideoStreams> streams(String id) async => VideoStreams.fromMap(
    (await _channel.invokeMethod<Map>('streams', {'id': id}))!,
  );

  static Future<YtPlaylist> playlist(String id) async => YtPlaylist.fromMap(
    (await _channel.invokeMethod<Map>('playlist', {'id': id}))!,
  );

  /// Canciones de una lista, ya paginadas del lado nativo.
  ///
  /// ponytail: tope de 500. youtube_explode_dart las traía todas, pero una
  /// lista más larga que eso tarda más en cargar que lo que nadie va a
  /// escuchar de una sentada. Si hace falta, subir [limit] (el nativo corta a
  /// las 40 páginas).
  static Future<List<Video>> playlistItems(String id, {int limit = 500}) async {
    final res = await _channel.invokeListMethod<Object?>('playlistItems', {
      'id': id,
      'limit': limit,
    });
    return [for (final m in res ?? const []) Video.fromMap(m! as Map)];
  }

  static Future<YtChannel> channel(String id) async => YtChannel.fromMap(
    (await _channel.invokeMethod<Map>('channel', {'id': id}))!,
  );

  /// Contenido de una pestaña de canal (vídeos, listas, álbumes...).
  static Future<List<Map>> channelTab(
    String id,
    String tab, {
    int limit = 200,
  }) async {
    final res = await _channel.invokeListMethod<Object?>('channelTab', {
      'id': id,
      'tab': tab,
      'limit': limit,
    });
    return (res ?? const []).cast<Map>();
  }

  static List<Video> videosOf(List<Map> items) => [
    for (final m in items)
      if (m['type'] == 'video') Video.fromMap(m),
  ];

  static List<YtPlaylist> playlistsOf(List<Map> items) => [
    for (final m in items)
      if (m['type'] == 'playlist') YtPlaylist.fromMap(m),
  ];

  static List<YtChannel> channelsOf(List<Map> items) => [
    for (final m in items)
      if (m['type'] == 'channel') YtChannel.fromMap(m),
  ];
}

final _videoIdPattern = RegExp('[a-zA-Z0-9_-]{11}');

/// Reemplazo de `VideoId` de youtube_explode_dart, solo con lo que se usa.
abstract final class VideoId {
  /// Extrae el id de 11 caracteres de una URL de YouTube (o lo devuelve tal
  /// cual si ya lo es). `null` si no hay ninguno.
  static String? parseVideoId(String url) {
    final trimmed = url.trim();
    if (_isVideoId(trimmed)) return trimmed;

    final uri = Uri.tryParse(trimmed);
    if (uri == null) return null;

    final fromQuery = uri.queryParameters['v'];
    if (fromQuery != null && _isVideoId(fromQuery)) return fromQuery;

    // youtu.be/<id>, /embed/<id>, /shorts/<id>, /live/<id>
    for (final segment in uri.pathSegments.reversed) {
      if (_isVideoId(segment)) return segment;
    }
    return null;
  }

  static bool _isVideoId(String value) =>
      value.length == 11 && _videoIdPattern.matchAsPrefix(value)?.end == 11;
}

/// Reemplazo de `PlaylistId` de youtube_explode_dart, solo con lo que se usa.
abstract final class PlaylistId {
  static final _pattern = RegExp('^[a-zA-Z0-9_-]{2,}\$');

  /// Id de la lista dentro de una URL de YouTube (o la propia id). `null` si
  /// no hay ninguna. Las mixes `RD...`/`UL...` no se aceptan: YouTube las
  /// genera al vuelo y no se pueden abrir como lista.
  static String? parsePlaylistId(String url) {
    final trimmed = url.trim();
    final value = trimmed.contains('/') || trimmed.contains('?')
        ? Uri.tryParse(trimmed)?.queryParameters['list']
        : trimmed;
    if (value == null || value.isEmpty) return null;
    if (value.startsWith('RD') || value.startsWith('UL')) return null;
    return _pattern.hasMatch(value) ? value : null;
  }
}

/// Reemplazo de `ChannelId` de youtube_explode_dart, solo con lo que se usa.
abstract final class ChannelId {
  static bool validateChannelId(String id) {
    final value = id.trim();
    return value.length == 24 &&
        value.startsWith('UC') &&
        RegExp(r'^UC[a-zA-Z0-9_-]{22}$').hasMatch(value);
  }
}
