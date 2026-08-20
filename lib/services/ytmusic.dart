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

import 'package:dskplay/services/newpipe.dart' show Video;
import 'package:http/http.dart' as http;

/// Cliente de YouTube Music (endpoints `WEB_REMIX` de InnerTube).
///
/// Era el paquete local `youtube_music_explode_dart`. Sigue en Dart a
/// propósito: la página de artista de YouTube Music (oyentes mensuales,
/// reproducciones por canción, artistas relacionados, año y tipo de cada
/// release) no la expone NewPipeExtractor, y este cliente sólo necesita un
/// POST de JSON, nada del descifrado de streams que sí se llevó al nativo.
///
/// Sólo devuelve [Video] de `newpipe.dart`, para que `returnSongLayout` valga
/// igual para resultados de YouTube y de YouTube Music.

typedef _JsonMap = Map<String, dynamic>;

/// A canonical YouTube Music artist result.
class MusicArtist {
  const MusicArtist({required this.id, required this.name, this.thumbnailUrl});

  /// Canonical `UC...` artist channel id.
  final String id;

  /// Display name returned by YouTube Music.
  final String name;

  /// Artist avatar URL, when YouTube Music exposes one.
  final String? thumbnailUrl;
}

/// Kind of a release listed on a YouTube Music artist page.
enum MusicReleaseType { album, single, ep, other }

/// A release (album, single or EP) as listed on a YouTube Music artist page.
class MusicAlbum {
  const MusicAlbum(
    this.id,
    this.title, {
    this.thumbnailUrl,
    this.type = MusicReleaseType.other,
    this.year,
  });

  /// Browse id of the release, e.g. `MPREb_...`.
  final String id;

  /// Display title of the release.
  final String title;

  /// Release artwork URL, when YouTube Music exposes one.
  final String? thumbnailUrl;

  /// Whether YouTube Music lists this release as a single or an EP. Album
  /// shelves only label their entries in the full grid, so an unlabelled
  /// release is [MusicReleaseType.other].
  final MusicReleaseType type;

  /// Release year, when YouTube Music exposes one.
  final String? year;

  @override
  String toString() => 'MusicAlbum($id, $title)';
}

/// A YouTube Music release page: the release itself plus its tracks.
class MusicReleasePage {
  const MusicReleasePage({
    required this.id,
    required this.title,
    this.artist,
    this.artistId,
    this.thumbnailUrl,
    this.year,
    this.tracks = const [],
  });

  /// Browse id of the release, e.g. `MPREb_...`.
  final String id;

  /// Display title of the release.
  final String title;

  /// Artist credited for the release, when YouTube Music exposes one.
  final String? artist;

  /// Channel id of that artist, when its name links to its page.
  final String? artistId;

  /// Release artwork URL, when YouTube Music exposes one.
  final String? thumbnailUrl;

  /// Release year, when YouTube Music exposes one.
  final String? year;

  /// The tracks of the release, in order.
  final List<Video> tracks;
}

/// A track of the artist page "Top songs" shelf.
class MusicTopSong {
  const MusicTopSong(this.video, this.playCount);

  /// The track itself.
  final Video video;

  /// Play count as displayed by YouTube Music, e.g. `1.2B plays`, when the
  /// shelf lists one.
  final String? playCount;
}

/// A YouTube Music artist page.
class MusicArtistProfile {
  const MusicArtistProfile({
    required this.id,
    required this.name,
    this.thumbnailUrl,
    this.description,
    this.monthlyListeners,
    this.topSongs = const [],
    this.releases = const [],
    this.relatedArtists = const [],
  });

  /// Canonical `UC...` artist channel id, not necessarily the one the page was
  /// asked for: see [MusicClient.getArtistProfile].
  final String id;

  /// Display name returned by YouTube Music.
  final String name;

  /// Header artwork URL, when YouTube Music exposes one.
  final String? thumbnailUrl;

  /// Artist biography, when YouTube Music exposes one.
  final String? description;

  /// Monthly listeners as displayed by YouTube Music, e.g.
  /// `331M monthly audience`.
  final String? monthlyListeners;

  /// The tracks of the artist page "Top songs" shelf.
  final List<MusicTopSong> topSongs;

  /// Every release of the artist: albums, singles and EPs.
  final List<MusicAlbum> releases;

  /// Artists the "Fans might also like" shelf points to.
  final List<MusicArtist> relatedArtists;
}

/// Queries the YouTube Music (`WEB_REMIX`) browse endpoints.
class MusicClient {
  const MusicClient();

  static const _remixContext = {
    'client': {
      'clientName': 'WEB_REMIX',
      'clientVersion': '1.20240101.01.00',
      'hl': 'en',
    },
  };

  /// Search filter that restricts results to artists only.
  static const _artistsSearchParams = 'EgWKAQIgAWoMEA4QChADEAQQCRAF';

  static const _artistPageType = 'MUSIC_PAGE_TYPE_ARTIST';

  /// Stands in for the channel of a track whose artist page is unknown.
  static const _unknownChannelId = 'UC0000000000000000000000';

  /// Matches the play count of a top song, e.g. `1.2B plays`. The client asks
  /// for `hl: en`, so the wording is stable.
  static final _playCountPattern = RegExp(
    r'^[\d.,]+\s?[KMB]?\s+plays$',
    caseSensitive: false,
  );

  /// POST a `youtubei/v1/<action>`, que es todo lo que este cliente usaba de
  /// YoutubeHttpClient.sendPost.
  static Future<_JsonMap> _post(String action, Map<String, dynamic> body) async {
    final response = await http.post(
      Uri.parse(
        'https://www.youtube.com/youtubei/v1/$action'
        '?key=AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8&prettyPrint=false',
      ),
      // Mismas cabeceras que ponía YoutubeHttpClient a toda petición. La
      // cookie CONSENT no es decorativa: sin ella YouTube devuelve la página
      // de consentimiento en vez del JSON en buena parte de Europa.
      headers: const {
        'content-type': 'application/json',
        'cookie': 'CONSENT=YES+cb',
        'accept-language': 'en-US,en;q=0.5',
        'user-agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/96.0.4664.18 Safari/537.36',
      },
      body: json.encode(body),
    );

    if (response.statusCode != 200) {
      throw Exception('YouTube Music $action failed: ${response.statusCode}');
    }
    return json.decode(utf8.decode(response.bodyBytes)) as _JsonMap;
  }

  /// Searches YouTube Music for canonical artist entries matching [query].
  Future<List<MusicArtist>> searchArtists(String query) async {
    final normalizedQuery = query.trim();
    if (normalizedQuery.isEmpty) return [];

    final root = await _post('search', {
      'context': _remixContext,
      'query': normalizedQuery,
      'params': _artistsSearchParams,
    });

    final results = <MusicArtist>[];
    final seen = <String>{};
    for (final item in _findRenderers(
      root,
      'musicResponsiveListItemRenderer',
    )) {
      final endpoint = item
          .getMap('navigationEndpoint')
          ?.getMap('browseEndpoint');
      final id = endpoint?.getValue<String>('browseId');
      if (id == null || !id.startsWith('UC') || !seen.add(id)) continue;

      final pageType = endpoint
          ?.getMap('browseEndpointContextSupportedConfigs')
          ?.getMap('browseEndpointContextMusicConfig')
          ?.getValue<String>('pageType');
      if (pageType != _artistPageType) continue;

      final name = _flexColumnText(item, 0) ?? '';
      if (name.trim().isEmpty) continue;

      results.add(
        MusicArtist(
          id: id,
          name: name.trim(),
          thumbnailUrl: _thumbnailUrl(item, 'thumbnail'),
        ),
      );
    }
    return results;
  }

  /// Searches YouTube Music for a track matching [query] and returns the
  /// best match, or `null` if nothing resolves to a playable video.
  ///
  /// Goes through the same `WEB_REMIX` browse/search endpoints as
  /// [getArtistProfile] instead of the public search results page, which is
  /// what keeps this from tripping YouTube's anti-scraping rate limiting the
  /// way scraping `youtube.com/results` repeatedly does.
  ///
  /// Unlike an artist page's "Top songs" shelf, a search result row's second
  /// column is a single `Song • Artist • Album` (or `Video • Channel •
  /// Views`) line rather than a bare artist name, so it has to be split on
  /// the bullet separator first.
  Future<Video?> searchSong(String query) async {
    final normalizedQuery = query.trim();
    if (normalizedQuery.isEmpty) return null;

    final root = await _post('search', {
      'context': _remixContext,
      'query': normalizedQuery,
    });

    Video? fallback;
    for (final item in _findRenderers(
      root,
      'musicResponsiveListItemRenderer',
    )) {
      final videoId = _trackVideoId(item);
      if (videoId == null) continue;

      final title = _flexColumnText(item, 0);
      if (title == null || title.isEmpty) continue;

      final subtitleParts = _splitBullets(_flexColumnText(item, 1));
      final type = subtitleParts.isNotEmpty
          ? subtitleParts.first.toLowerCase()
          : '';
      final artist = subtitleParts.length >= 2
          ? subtitleParts[1]
          : (subtitleParts.isNotEmpty ? subtitleParts.first : '');

      final video = _trackVideo(item, videoId, title, artist, null);
      // Prefer a canonical "Song" row over a "Video"/other row further down.
      if (type == 'song') return video;
      fallback ??= video;
    }
    return fallback;
  }

  /// Splits a `Song • Artist • Album` style subtitle line on its bullet
  /// separators.
  List<String> _splitBullets(String? text) {
    if (text == null) return const [];
    return text
        .split('•')
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList();
  }

  /// Returns a YouTube Music artist page: header details, top songs, the full
  /// discography and the artists it points to.
  ///
  /// [channelId] does not have to be the channel of the artist itself: the
  /// channel that uploads its videos — a label, a VEVO channel — answers with
  /// a partial page of the same artist, whose header still points at the
  /// canonical channel. [MusicArtistProfile.id] holds that one, so a caller
  /// that asked with an uploader can tell and read the real page instead.
  Future<MusicArtistProfile> getArtistProfile(dynamic channelId) async {
    final id = channelId.toString();
    final root = await _browse(id);

    final header =
        _firstRenderer(root, 'musicImmersiveHeaderRenderer') ??
        _firstRenderer(root, 'musicVisualHeaderRenderer');
    final name = (_runsText(header?.getMap('title')) ?? '').trim();
    final canonicalId = _headerChannelId(header) ?? id;

    return MusicArtistProfile(
      id: canonicalId,
      name: name,
      thumbnailUrl: _thumbnailUrl(header, 'thumbnail'),
      description: _runsText(header?.getMap('description')),
      monthlyListeners: _runsText(header?.getMap('monthlyListenerCount')),
      topSongs: _parseTopSongs(root, channelId: canonicalId, author: name),
      releases: await _collectDiscography(root),
      relatedArtists: _collectRelatedArtists(
        root,
      ).where((artist) => artist.id != canonicalId).toList(),
    );
  }

  /// Channel the subscribe button of a page header subscribes to, which is the
  /// artist itself even on the page of a channel that only uploads for it.
  String? _headerChannelId(_JsonMap? header) {
    final channelId = header
        ?.getMap('subscriptionButton')
        ?.getMap('subscribeButtonRenderer')
        ?.getValue<String>('channelId');
    return (channelId != null && channelId.startsWith('UC')) ? channelId : null;
  }

  /// Returns a release with its tracks, credited to the artist its own header
  /// names.
  Future<MusicReleasePage> getAlbum(String albumBrowseId) async {
    final root = await _browse(albumBrowseId);
    final header =
        _firstRenderer(root, 'musicResponsiveHeaderRenderer') ??
        _firstRenderer(root, 'musicDetailHeaderRenderer');
    final albumArtist = _runsText(header?.getMap('straplineTextOne'))?.trim();
    final albumArtistId = _straplineChannelId(header);

    final videos = <Video>[];
    final seen = <String>{};
    for (final item in _findRenderers(
      root,
      'musicResponsiveListItemRenderer',
    )) {
      final videoId = _trackVideoId(item);
      if (videoId == null || !seen.add(videoId)) continue;

      final title = _flexColumnText(item, 0);
      if (title == null || title.isEmpty) continue;

      videos.add(
        _trackVideo(item, videoId, title, albumArtist ?? '', albumArtistId),
      );
    }

    return MusicReleasePage(
      id: albumBrowseId,
      title: _runsText(header?.getMap('title'))?.trim() ?? '',
      artist: albumArtist,
      artistId: albumArtistId,
      thumbnailUrl: _thumbnailUrl(header, 'thumbnail'),
      year: _releaseYearOf(_subtitleParts(header)),
      tracks: videos,
    );
  }

  /// Channel id behind the artist name of a release header, when it links to
  /// the page of that artist.
  String? _straplineChannelId(_JsonMap? header) {
    final runs = header?.getMap('straplineTextOne')?.getList('runs');
    for (final run in runs?.whereType<Map>() ?? const <Map>[]) {
      final browseId = run
          .cast<String, dynamic>()
          .getMap('navigationEndpoint')
          ?.getMap('browseEndpoint')
          ?.getValue<String>('browseId');
      if (browseId != null && browseId.startsWith('UC')) return browseId;
    }
    return null;
  }

  Future<_JsonMap> _browse(String browseId, {String? params}) {
    return _post('browse', {
      'context': _remixContext,
      'browseId': browseId,
      if (params != null) 'params': params,
    });
  }

  /// Every release of the artist page: the grid behind each shelf's "More"
  /// button, plus the entries only shown inline.
  Future<List<MusicAlbum>> _collectDiscography(_JsonMap root) async {
    final grids = await Future.wait([
      for (final more in _collectMoreReleaseBrowses(root))
        _browse(
          more.$1,
          params: more.$2,
        ).catchError((_) => <String, dynamic>{}),
    ]);

    // Grids first: they label the release type, the inline previews of an
    // album shelf do not, and [_collectReleases] keeps the first entry seen.
    final releases = <String, MusicAlbum>{};
    for (final grid in grids) {
      _collectReleases(grid, releases);
    }
    _collectReleases(root, releases);
    return releases.values.toList();
  }

  /// Returns the full discography (albums, singles and EPs) of a YouTube Music
  /// artist.
  Future<List<MusicAlbum>> getArtistReleases(dynamic channelId) async {
    final id = channelId.toString();
    final root = await _browse(id);

    final releases = <String, MusicAlbum>{};
    _collectReleases(root, releases);

    for (final more in _collectMoreReleaseBrowses(root)) {
      try {
        var grid = await _browse(more.$1, params: more.$2);
        _collectReleases(grid, releases);

        // "See all" grids (e.g. an artist's full singles list) are
        // themselves paginated; keep following continuation tokens so large
        // catalogs aren't cut off at the first page.
        var guard = 0;
        var token = _findContinuationToken(grid);
        while (token != null && guard++ < 25) {
          grid = await _continueBrowse(token);
          _collectReleases(grid, releases);
          token = _findContinuationToken(grid);
        }
      } catch (_) {
        // Keep inline releases if a secondary grid fails.
      }
    }

    return releases.values.toList();
  }

  /// Returns the tracks of a release as [Video]s.
  Future<List<Video>> getAlbumTracks(
    String albumBrowseId, {
    required String author,
    String? channelId,
  }) async {
    final root = await _browse(albumBrowseId);
    final resolvedChannelId = (channelId != null && channelId.isNotEmpty)
        ? channelId
        : _unknownChannelId;

    final videos = <Video>[];
    final seen = <String>{};
    for (final item in _findRenderers(
      root,
      'musicResponsiveListItemRenderer',
    )) {
      final videoId = _trackVideoId(item);
      if (videoId == null || !seen.add(videoId)) continue;

      final title = _flexColumnText(item, 0);
      if (title == null || title.isEmpty) continue;

      videos.add(
        Video(
          id: videoId,
          title: title,
          author: author,
          channelId: resolvedChannelId,
          duration: _parseDuration(_fixedColumnText(item)),
        ),
      );
    }

    return videos;
  }

  Future<_JsonMap> _continueBrowse(String token) {
    return _post('browse', {
      'context': _remixContext,
      'continuation': token,
    });
  }

  String? _findContinuationToken(_JsonMap root) {
    for (final renderer in _findRenderers(root, 'continuationItemRenderer')) {
      final token = renderer
          .getMap('continuationEndpoint')
          ?.getMap('continuationCommand')
          ?.getValue<String>('token');
      if (token != null) return token;
    }
    return null;
  }

  List<MusicTopSong> _parseTopSongs(
    _JsonMap root, {
    required String channelId,
    required String author,
  }) {
    final shelf = _firstRenderer(root, 'musicShelfRenderer');
    if (shelf == null) return const [];

    final songs = <MusicTopSong>[];
    final seen = <String>{};
    for (final item in _findRenderers(
      shelf,
      'musicResponsiveListItemRenderer',
    )) {
      final videoId = _trackVideoId(item);
      if (videoId == null || !seen.add(videoId)) continue;

      final title = _flexColumnText(item, 0);
      if (title == null || title.isEmpty) continue;

      final trackAuthor = _flexColumnText(item, 1);
      songs.add(
        MusicTopSong(
          _trackVideo(
            item,
            videoId,
            title,
            (trackAuthor == null || trackAuthor.isEmpty) ? author : trackAuthor,
            channelId,
          ),
          _playCountText(item),
        ),
      );
    }

    return songs;
  }

  /// One track row of a shelf or of a release, as a [Video]. Only the fields
  /// YouTube Music lists in a row are known, the rest is left empty.
  Video _trackVideo(
    _JsonMap item,
    String videoId,
    String title,
    String author,
    String? channelId,
  ) {
    return Video(
      id: videoId,
      title: title,
      author: author,
      channelId: channelId ?? _unknownChannelId,
      duration: _parseDuration(_fixedColumnText(item)),
    );
  }

  /// The play count column of a top song, when the shelf lists one. Its
  /// position varies, so every column after the title is probed.
  String? _playCountText(_JsonMap item) {
    for (var index = 1; index < 4; index++) {
      final text = _flexColumnText(item, index);
      if (text != null && _playCountPattern.hasMatch(text)) return text;
    }
    return null;
  }

  void _collectReleases(dynamic root, Map<String, MusicAlbum> into) {
    for (final item in _findRenderers(root, 'musicTwoRowItemRenderer')) {
      final browseId = item
          .getMap('navigationEndpoint')
          ?.getMap('browseEndpoint')
          ?.getValue<String>('browseId');
      if (browseId == null || !browseId.startsWith('MPRE')) continue;

      final title = _runsText(item.getMap('title'));
      // `Album • 2019`, `Single • 2021`, or just the year when the entry is an
      // inline preview.
      final subtitle = _subtitleParts(item);
      into.putIfAbsent(
        browseId,
        () => MusicAlbum(
          browseId,
          title?.trim() ?? '',
          thumbnailUrl: _thumbnailUrl(item, 'thumbnailRenderer'),
          type: _releaseTypeOf(subtitle),
          year: _releaseYearOf(subtitle),
        ),
      );
    }
  }

  /// Collects the artists of the "Fans might also like" shelf. They sit in the
  /// same rows as the releases, told apart by their channel browse id.
  List<MusicArtist> _collectRelatedArtists(dynamic root) {
    final artists = <String, MusicArtist>{};
    for (final item in _findRenderers(root, 'musicTwoRowItemRenderer')) {
      final endpoint = item
          .getMap('navigationEndpoint')
          ?.getMap('browseEndpoint');
      final browseId = endpoint?.getValue<String>('browseId');
      if (browseId == null || !browseId.startsWith('UC')) continue;

      final pageType = endpoint
          ?.getMap('browseEndpointContextSupportedConfigs')
          ?.getMap('browseEndpointContextMusicConfig')
          ?.getValue<String>('pageType');
      if (pageType != _artistPageType) continue;

      final name = _runsText(item.getMap('title'))?.trim();
      if (name == null || name.isEmpty) continue;

      artists.putIfAbsent(
        browseId,
        () => MusicArtist(
          id: browseId,
          name: name,
          thumbnailUrl: _thumbnailUrl(item, 'thumbnailRenderer'),
        ),
      );
    }
    return artists.values.toList();
  }

  List<(String, String?)> _collectMoreReleaseBrowses(_JsonMap root) {
    final result = <(String, String?)>[];
    for (final header in _findRenderers(
      root,
      'musicCarouselShelfBasicHeaderRenderer',
    )) {
      final endpoint = header
          .getMap('moreContentButton')
          ?.getMap('buttonRenderer')
          ?.getMap('navigationEndpoint')
          ?.getMap('browseEndpoint');
      final browseId = endpoint?.getValue<String>('browseId');
      if (browseId == null || !browseId.startsWith('MPAD')) continue;
      result.add((browseId, endpoint?.getValue<String>('params')));
    }
    return result;
  }

  List<String> _subtitleParts(_JsonMap? item) {
    final subtitle = _runsText(item?.getMap('subtitle'));
    if (subtitle == null) return const [];
    return subtitle
        .split('•')
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList();
  }

  MusicReleaseType _releaseTypeOf(List<String> subtitleParts) {
    for (final part in subtitleParts) {
      switch (part.toLowerCase()) {
        case 'album':
          return MusicReleaseType.album;
        case 'single':
          return MusicReleaseType.single;
        case 'ep':
          return MusicReleaseType.ep;
      }
    }
    return MusicReleaseType.other;
  }

  String? _releaseYearOf(List<String> subtitleParts) {
    for (final part in subtitleParts) {
      if (RegExp(r'^(19|20)\d{2}$').hasMatch(part)) return part;
    }
    return null;
  }

  String? _trackVideoId(_JsonMap item) {
    return item
        .getMap('overlay')
        ?.getMap('musicItemThumbnailOverlayRenderer')
        ?.getMap('content')
        ?.getMap('musicPlayButtonRenderer')
        ?.getMap('playNavigationEndpoint')
        ?.getMap('watchEndpoint')
        ?.getValue<String>('videoId');
  }

  String? _flexColumnText(_JsonMap item, int index) {
    final columns = item.getList('flexColumns');
    if (columns == null || columns.length <= index) return null;
    final column = columns[index];
    if (column is! Map) return null;
    return _runsText(
      column
          .cast<String, dynamic>()
          .getMap('musicResponsiveListItemFlexColumnRenderer')
          ?.getMap('text'),
    );
  }

  String? _runsText(_JsonMap? node) {
    final runs = node?.getList('runs')?.whereType<Map>().parseRuns();
    return (runs == null || runs.isEmpty) ? null : runs;
  }

  String? _fixedColumnText(_JsonMap item) {
    final columns = item.getList('fixedColumns');
    if (columns == null || columns.isEmpty) return null;
    final lastColumn = columns.last;
    if (lastColumn is! Map) return null;
    return lastColumn
        .cast<String, dynamic>()
        .getMap('musicResponsiveListItemFixedColumnRenderer')
        ?.getMap('text')
        ?.getList('runs')
        ?.whereType<Map>()
        .parseRuns();
  }

  /// The largest artwork URL under [key], which holds a thumbnail renderer:
  /// `thumbnail` on headers and list items, `thumbnailRenderer` on shelf rows.
  String? _thumbnailUrl(_JsonMap? node, String key) {
    final thumbnails = node
        ?.getMap(key)
        ?.getMap('musicThumbnailRenderer')
        ?.getMap('thumbnail')
        ?.getList('thumbnails');
    if (thumbnails == null || thumbnails.isEmpty) return null;
    final thumbnail = thumbnails.last;
    if (thumbnail is! Map) return null;
    return thumbnail.cast<String, dynamic>().getValue<String>('url');
  }

  Duration? _parseDuration(String? value) {
    if (value == null) return null;
    final parts = value.trim().split(':');
    if (parts.isEmpty || parts.length > 3) return null;

    var seconds = 0;
    for (final part in parts) {
      final n = int.tryParse(part.trim());
      if (n == null) return null;
      seconds = seconds * 60 + n;
    }
    return Duration(seconds: seconds);
  }

  _JsonMap? _firstRenderer(dynamic node, String rendererKey) {
    for (final renderer in _findRenderers(node, rendererKey)) {
      return renderer;
    }
    return null;
  }

  Iterable<_JsonMap> _findRenderers(dynamic node, String rendererKey) sync* {
    if (node is Map) {
      final match = node[rendererKey];
      if (match is Map) yield match.cast<String, dynamic>();
      for (final value in node.values) {
        yield* _findRenderers(value, rendererKey);
      }
    } else if (node is List) {
      for (final value in node) {
        yield* _findRenderers(value, rendererKey);
      }
    }
  }
}

extension _MapReader on Map<String, dynamic> {
  Map<String, dynamic>? getMap(String key) {
    final value = this[key];
    return value is Map ? value.cast<String, dynamic>() : null;
  }

  List<dynamic>? getList(String key) {
    final value = this[key];
    return value is List ? value : null;
  }

  T? getValue<T>(String key) {
    final value = this[key];
    return value is T ? value : null;
  }
}

extension _RunsParser on Iterable<Map<dynamic, dynamic>> {
  String parseRuns() {
    return map((run) => run['text']?.toString() ?? '').join();
  }
}

/// Instancia compartida: no guarda estado, cada llamada es un POST.
const ytMusic = MusicClient();
