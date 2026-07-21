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

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

class LyricLine {
  const LyricLine(this.timestamp, this.text);
  final Duration timestamp;
  final String text;
}

class LyricsResult {
  const LyricsResult({
    required this.plainText,
    required this.source,
    this.syncedLines,
    this.label = '',
  });
  final String plainText;
  final String source;
  final List<LyricLine>? syncedLines;
  // Human-readable match info from the source (e.g. "Title - Artist"),
  // used to tell apart multiple candidates in the results picker.
  final String label;

  bool get hasSyncedLyrics => syncedLines != null && syncedLines!.isNotEmpty;
}

class LyricsManager {
  Future<LyricsResult?> fetchLyrics(String artistName, String title) async {
    title = _sanitizeTitle(title);
    if (title.isEmpty || artistName.isEmpty) return null;

    final query = '$artistName $title';

    // LRCLIB and NetEase are tried first since they commonly provide
    // synced (.lrc) lyrics, needed for the karaoke view.
    final fromLrclib = (await _lrclibCandidates(query, limit: 1)).firstOrNull;
    if (fromLrclib != null) return fromLrclib;

    final fromNetease = (await _neteaseCandidates(query, limit: 1)).firstOrNull;
    if (fromNetease != null) return fromNetease;

    final fromGenius = (await _geniusCandidates(query, limit: 1)).firstOrNull;
    if (fromGenius != null) return fromGenius;

    final lyricsFromLyricsOvh = await _fetchLyricsFromLyricsOvh(
      artistName,
      title,
    );
    if (lyricsFromLyricsOvh != null) {
      return LyricsResult(plainText: lyricsFromLyricsOvh, source: 'lyrics.ovh');
    }

    final lyricsFromParolesNet = await _fetchLyricsFromParolesNet(
      artistName.split(',')[0],
      title,
    );
    if (lyricsFromParolesNet != null) {
      return LyricsResult(
        plainText: lyricsFromParolesNet,
        source: 'paroles.net',
      );
    }

    final lyricsFromLyricsMania1 = await _fetchLyricsFromLyricsMania1(
      artistName,
      title,
    );
    if (lyricsFromLyricsMania1 != null) {
      return LyricsResult(
        plainText: lyricsFromLyricsMania1,
        source: 'lyricsmania.com',
      );
    }

    return null;
  }

  // All candidates found across every source, for the results picker.
  // Every source is queried concurrently since this only runs on explicit
  // user action (the "+" button / manual search), not on every song load.
  Future<List<LyricsResult>> searchAllSources(
    String artistName,
    String title,
  ) async {
    title = _sanitizeTitle(title);
    if (title.isEmpty || artistName.isEmpty) return [];

    final query = '$artistName $title';
    final smartSources = await Future.wait([
      _lrclibCandidates(query, limit: 5),
      _neteaseCandidates(query, limit: 5),
      _geniusCandidates(query, limit: 3),
    ]);

    final plainSources = await Future.wait([
      _fetchLyricsFromLyricsOvh(artistName, title),
      _fetchLyricsFromParolesNet(artistName.split(',')[0], title),
      _fetchLyricsFromLyricsMania1(artistName, title),
    ]);
    const plainSourceNames = ['lyrics.ovh', 'paroles.net', 'lyricsmania.com'];

    return [
      for (final candidates in smartSources) ...candidates,
      for (var i = 0; i < plainSources.length; i++)
        if (plainSources[i] != null)
          LyricsResult(
            plainText: plainSources[i]!,
            source: plainSourceNames[i],
          ),
    ];
  }

  // Free-text search across the sources that accept a raw query (used by
  // the user-triggered manual search box in the results picker).
  Future<List<LyricsResult>> searchByQuery(String query) async {
    if (query.trim().isEmpty) return [];

    final smartSources = await Future.wait([
      _lrclibCandidates(query, limit: 5),
      _neteaseCandidates(query, limit: 5),
      _geniusCandidates(query, limit: 3),
    ]);

    return [for (final candidates in smartSources) ...candidates];
  }

  String _sanitizeTitle(String title) {
    // Remove Lyrics/Karaoke only from end of title
    if (title.endsWith(' Lyrics')) {
      return title.substring(0, title.length - 7).trim();
    } else if (title.endsWith(' Karaoke')) {
      return title.substring(0, title.length - 8).trim();
    }
    return title;
  }

  // ───────────────────────────── LRCLIB ─────────────────────────────
  // Free public API. Returns plain lyrics and, when available, synced
  // (.lrc) lyrics with per-line timestamps.
  Future<List<LyricsResult>> _lrclibCandidates(
    String query, {
    required int limit,
  }) async {
    try {
      final uri = Uri.parse(
        'https://lrclib.net/api/search?q=${Uri.encodeComponent(query)}',
      );
      final response = await http
          .get(uri, headers: {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) return [];

      final results = jsonDecode(response.body);
      if (results is! List) return [];

      final candidates = <LyricsResult>[];
      for (final item in results) {
        if (candidates.length >= limit) break;
        if (item is! Map) continue;
        final plain = (item['plainLyrics'] as String?) ?? '';
        final synced = (item['syncedLyrics'] as String?) ?? '';
        if (plain.isEmpty && synced.isEmpty) continue;

        final syncedLines = synced.isNotEmpty ? _parseLrc(synced) : null;
        final plainText = plain.isNotEmpty
            ? plain
            : (syncedLines?.map((line) => line.text).join('\n') ?? '');
        if (plainText.isEmpty) continue;

        final label = [
          (item['trackName'] as String?) ?? '',
          (item['artistName'] as String?) ?? '',
        ].where((s) => s.isNotEmpty).join(' - ');

        candidates.add(
          LyricsResult(
            plainText: plainText,
            syncedLines: syncedLines,
            source: 'lrclib',
            label: label,
          ),
        );
      }
      return candidates;
    } catch (e) {
      return [];
    }
  }

  // ───────────────────────────── NetEase ─────────────────────────────
  // Unofficial music.163.com endpoints, no API key required (just a
  // Referer header). Lyrics come back as a single .lrc blob.
  Future<List<LyricsResult>> _neteaseCandidates(
    String query, {
    required int limit,
  }) async {
    try {
      final searchUri = Uri.parse(
        'https://music.163.com/api/search/get?type=1&limit=5&offset=0'
        '&s=${Uri.encodeComponent(query)}',
      );
      final searchResponse = await http
          .get(
            searchUri,
            headers: {
              'Accept': 'application/json',
              'Referer': 'https://music.163.com',
              'Cookie': 'appver=2.0.2',
            },
          )
          .timeout(const Duration(seconds: 10));

      if (searchResponse.statusCode != 200) return [];

      final searchJson = jsonDecode(searchResponse.body);
      if (searchJson is! Map) return [];
      final songs = (searchJson['result'] as Map?)?['songs'];
      if (songs is! List || songs.isEmpty) return [];

      final validSongs = songs
          .whereType<Map>()
          .where((song) => song['id'] != null)
          .toList();
      if (validSongs.isEmpty) return [];

      // For the common single-result auto-fetch, stop at the first match
      // instead of hitting the lyric endpoint for every song. Otherwise
      // (results picker), fetch every candidate's lyrics concurrently.
      if (limit == 1) {
        for (final song in validSongs) {
          final result = await _neteaseLyricResult(song);
          if (result != null) return [result];
        }
        return [];
      }

      final settled = await Future.wait(validSongs.map(_neteaseLyricResult));
      return settled.whereType<LyricsResult>().take(limit).toList();
    } catch (e) {
      return [];
    }
  }

  Future<LyricsResult?> _neteaseLyricResult(Map song) async {
    try {
      final id = song['id'];
      final lyricUri = Uri.parse(
        'https://music.163.com/api/song/lyric?id=$id&lv=1&kv=1&tv=-1',
      );
      final lyricResponse = await http
          .get(
            lyricUri,
            headers: {
              'Accept': 'application/json',
              'Referer': 'https://music.163.com',
            },
          )
          .timeout(const Duration(seconds: 10));
      if (lyricResponse.statusCode != 200) return null;

      final lyricJson = jsonDecode(lyricResponse.body);
      if (lyricJson is! Map) return null;
      final raw = ((lyricJson['lrc'] as Map?)?['lyric'] as String?) ?? '';
      if (raw.isEmpty) return null;

      final hasTimestamps = RegExp(r'\[\d{1,2}:\d{2}').hasMatch(raw);
      final syncedLines = hasTimestamps ? _parseLrc(raw) : null;
      final plainText = syncedLines != null
          ? syncedLines.map((line) => line.text).join('\n')
          : raw.replaceAll(RegExp(r'\[[^\]]*\]'), '').trim();
      if (plainText.isEmpty) return null;

      final artists = (song['artists'] as List?)
          ?.whereType<Map>()
          .map((a) => (a['name'] as String?) ?? '')
          .where((s) => s.isNotEmpty)
          .join(', ');
      final label = [
        (song['name'] as String?) ?? '',
        artists ?? '',
      ].where((s) => s.isNotEmpty).join(' - ');

      return LyricsResult(
        plainText: plainText,
        syncedLines: syncedLines,
        source: 'netease',
        label: label,
      );
    } catch (e) {
      return null;
    }
  }

  // ───────────────────────────── Genius ─────────────────────────────
  // Scraped, no API key. Plain lyrics only (Genius doesn't offer synced
  // lyrics).
  Future<List<LyricsResult>> _geniusCandidates(
    String query, {
    required int limit,
  }) async {
    try {
      final searchUri = Uri.parse(
        'https://genius.com/api/search/multi?per_page=5'
        '&q=${Uri.encodeComponent(query)}',
      );
      final searchResponse = await http
          .get(searchUri, headers: {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 10));
      if (searchResponse.statusCode != 200) return [];

      final searchJson = jsonDecode(searchResponse.body);
      if (searchJson is! Map) return [];
      final sections = (searchJson['response'] as Map?)?['sections'];
      if (sections is! List) return [];

      final hitResults = <Map>[];
      for (final section in sections) {
        if (hitResults.length >= 8) break;
        if (section is! Map || section['type'] != 'song') continue;
        final hits = section['hits'];
        if (hits is! List) continue;

        for (final hit in hits) {
          if (hitResults.length >= 8) break;
          final result = (hit as Map?)?['result'];
          final pageUrl = (result as Map?)?['url'] as String?;
          if (result == null || pageUrl == null || pageUrl.isEmpty) continue;
          hitResults.add(result);
        }
      }
      if (hitResults.isEmpty) return [];

      // Same idea as NetEase: fast single early-exit path for the common
      // auto-fetch case, concurrent scraping for the results picker.
      if (limit == 1) {
        for (final result in hitResults) {
          final candidate = await _geniusResultFor(result);
          if (candidate != null) return [candidate];
        }
        return [];
      }

      final settled = await Future.wait(hitResults.map(_geniusResultFor));
      return settled.whereType<LyricsResult>().take(limit).toList();
    } catch (e) {
      return [];
    }
  }

  Future<LyricsResult?> _geniusResultFor(Map result) async {
    final pageUrl = result['url'] as String?;
    if (pageUrl == null || pageUrl.isEmpty) return null;

    final lyrics = await _scrapeGeniusLyrics(pageUrl);
    if (lyrics == null || lyrics.isEmpty) return null;

    final label = [
      (result['title'] as String?) ?? '',
      (result['primary_artist'] as Map?)?['name'] as String? ?? '',
    ].where((s) => s.isNotEmpty).join(' - ');

    return LyricsResult(
      plainText: lyrics,
      source: 'genius',
      label: label,
    );
  }

  Future<String?> _scrapeGeniusLyrics(String pageUrl) async {
    try {
      final response = await http
          .get(Uri.parse(pageUrl))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return null;

      final document = html_parser.parse(response.body);
      var containers = document.querySelectorAll(
        '[data-lyrics-container="true"]',
      );
      if (containers.isEmpty) {
        containers = document.querySelectorAll(
          'div[class^="Lyrics__Container"]',
        );
      }
      if (containers.isEmpty) {
        containers = document.querySelectorAll('div.lyrics');
      }
      if (containers.isEmpty) return null;

      final buffer = StringBuffer();
      for (final container in containers) {
        final text = _extractTextWithBreaks(
          container,
        ).replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
        if (text.isNotEmpty) {
          if (buffer.isNotEmpty) buffer.write('\n\n');
          buffer.write(text);
        }
      }
      final result = buffer.toString().trim();
      return result.isEmpty ? null : result;
    } catch (e) {
      return null;
    }
  }

  // Walks the DOM preserving line breaks on <br>, since Element.text
  // collapses them.
  String _extractTextWithBreaks(dom.Element element) {
    final buffer = StringBuffer();
    void walk(dom.Node node) {
      if (node is dom.Text) {
        buffer.write(node.text);
      } else if (node is dom.Element) {
        if (node.localName == 'br') {
          buffer.write('\n');
        } else {
          for (final child in node.nodes) {
            walk(child);
          }
        }
      }
    }

    for (final child in element.nodes) {
      walk(child);
    }
    return buffer.toString();
  }

  // Parses an .lrc blob (lines like "[01:23.45]lyric text") into
  // timestamped lines, ignoring metadata tags such as [ar:...]/[ti:...].
  List<LyricLine>? _parseLrc(String lrc) {
    final timeTag = RegExp(r'\[(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?\]');
    final lines = <LyricLine>[];

    for (final rawLine in lrc.split('\n')) {
      final matches = timeTag.allMatches(rawLine).toList();
      if (matches.isEmpty) continue;

      final text = rawLine.replaceAll(timeTag, '').trim();
      for (final match in matches) {
        final minutes = int.parse(match.group(1)!);
        final seconds = int.parse(match.group(2)!);
        final fraction = match.group(3);
        final milliseconds = fraction == null
            ? 0
            : int.parse(fraction.padRight(3, '0').substring(0, 3));

        lines.add(
          LyricLine(
            Duration(
              minutes: minutes,
              seconds: seconds,
              milliseconds: milliseconds,
            ),
            text,
          ),
        );
      }
    }

    if (lines.isEmpty) return null;
    lines.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return lines;
  }

  Future<String?> _fetchLyricsFromLyricsOvh(
    String artistName,
    String title,
  ) async {
    try {
      final artistFormatted = _lyricsUrl(artistName.split(',')[0]);
      final titleFormatted = _lyricsUrl(title);
      final uri = Uri.parse(
        'https://api.lyrics.ovh/v1/$artistFormatted/$titleFormatted',
      );
      final response = await http.get(uri).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        final lyrics = json['lyrics'] as String?;
        if (lyrics != null && lyrics.isNotEmpty) {
          return lyrics;
        }
      }
    } catch (e) {
      // Silently fail and return null to try next source
      return null;
    }
    return null;
  }

  Future<String?> _fetchLyricsFromParolesNet(
    String artistName,
    String title,
  ) async {
    try {
      final uri = Uri.parse(
        'https://www.paroles.net/${_lyricsUrl(artistName)}/paroles-${_lyricsUrl(title)}',
      );
      final response = await http
          .get(uri)
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => http.Response('', 408),
          );

      if (response.statusCode == 200) {
        final document = html_parser.parse(response.body);
        final songTextElements = document.querySelectorAll('.song-text');

        if (songTextElements.isNotEmpty) {
          final lyricsLines = songTextElements.first.text.split('\n');
          if (lyricsLines.length > 1) {
            lyricsLines.removeAt(0);

            return _removeSpaces(lyricsLines.join('\n'));
          }
        }
      }
    } catch (e) {
      // Silently fail and return null to try next source
      return null;
    }

    return null;
  }

  Future<String?> _fetchLyricsFromLyricsMania1(
    String artistName,
    String title,
  ) async {
    try {
      final uri = Uri.parse(
        'https://www.lyricsmania.com/${_lyricsManiaUrl(title)}_lyrics_${_lyricsManiaUrl(artistName)}.html',
      );
      final response = await http
          .get(uri)
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => http.Response('', 408),
          );

      if (response.statusCode == 200) {
        final document = html_parser.parse(response.body);
        final lyricsBodyElements = document.querySelectorAll('.lyrics-body');

        if (lyricsBodyElements.isNotEmpty) {
          return lyricsBodyElements.first.text;
        }
      }
    } catch (e) {
      // Silently fail and return null
      return null;
    }

    return null;
  }

  String _lyricsUrl(String input) {
    var result = input.replaceAll(' ', '-').toLowerCase();
    // Remove special characters
    result = result.replaceAll(RegExp('[^a-z0-9-]'), '');
    // Clean up multiple/trailing dashes
    result = result.replaceAll(RegExp('-+'), '-');
    if (result.isNotEmpty && result.endsWith('-')) {
      result = result.substring(0, result.length - 1);
    }
    if (result.isNotEmpty && result.startsWith('-')) {
      result = result.substring(1);
    }
    return result;
  }

  String _lyricsManiaUrl(String input) {
    var result = input.replaceAll(' ', '_').toLowerCase();
    if (result.isNotEmpty && result.startsWith('_')) {
      result = result.substring(1);
    }
    if (result.isNotEmpty && result.endsWith('_')) {
      result = result.substring(0, result.length - 1);
    }
    return result;
  }

  String _removeSpaces(String input) {
    return input.replaceAll(RegExp(' {2,}'), ' ');
  }
}
