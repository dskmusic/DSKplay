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

import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';
import 'package:dskplay/main.dart' show logger;
import 'package:dskplay/models/podcast_model.dart';

// Free, no-auth podcast directory search - the same one most podcast apps
// bootstrap their catalog from.
const _itunesSearchHost = 'itunes.apple.com';

const _fallbackPodcastImage = 'assets/logo.png';

Future<List<Podcast>> searchPodcasts(String query) async {
  final trimmedQuery = query.trim();
  if (trimmedQuery.isEmpty) return [];

  try {
    final uri = Uri.https(_itunesSearchHost, '/search', {
      'term': trimmedQuery,
      'media': 'podcast',
      'entity': 'podcast',
      'limit': '25',
    });

    final response = await http.get(uri).timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) return [];

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final results = body['results'] as List<dynamic>? ?? [];
    return results
        .whereType<Map>()
        .map(_podcastFromItunesJson)
        .whereType<Podcast>()
        .toList();
  } catch (e, stackTrace) {
    logger.log('Error searching podcasts', error: e, stackTrace: stackTrace);
    return [];
  }
}

Podcast? _podcastFromItunesJson(Map<dynamic, dynamic> raw) {
  final map = raw.cast<String, dynamic>();
  final feedUrl = (map['feedUrl'] as String? ?? '').trim();
  final title = (map['collectionName'] as String? ?? '').trim();
  if (feedUrl.isEmpty || title.isEmpty) return null;

  final image =
      (map['artworkUrl600'] as String? ?? map['artworkUrl100'] as String? ?? '')
          .trim();

  return Podcast(
    id: Podcast.idFromFeedUrl(feedUrl),
    title: title,
    author: (map['artistName'] as String? ?? '').trim(),
    image: image.isNotEmpty ? image : _fallbackPodcastImage,
    feedUrl: feedUrl,
  );
}

/// Fetches and parses [feedUrl]'s RSS feed: the podcast's own metadata
/// (refreshed from the feed itself, so subscribing by a raw feed URL works
/// without an iTunes lookup) plus every episode, newest first.
Future<({Podcast podcast, List<PodcastEpisode> episodes})?> fetchPodcastFeed(
  String feedUrl,
) async {
  try {
    final response = await http
        .get(Uri.parse(feedUrl), headers: {'User-Agent': 'DSKPlay/1.0'})
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) return null;

    final document = XmlDocument.parse(response.body);
    final channels = document.findAllElements('channel');
    if (channels.isEmpty) return null;
    final channel = channels.first;

    final podcastId = Podcast.idFromFeedUrl(feedUrl);
    final podcastImage = _channelImage(channel);
    final podcast = Podcast(
      id: podcastId,
      title: _text(channel, 'title') ?? 'Podcast',
      author: _text(channel, 'itunes:author') ?? '',
      image: podcastImage.isNotEmpty ? podcastImage : _fallbackPodcastImage,
      feedUrl: feedUrl,
      description: _stripHtml(_text(channel, 'description') ?? ''),
    );

    final episodes =
        channel
            .findElements('item')
            .map((item) => _episodeFromItem(item, podcastId, podcast.image))
            .whereType<PodcastEpisode>()
            .toList()
          ..sort(
            (a, b) =>
                (b.pubDate ?? DateTime(0)).compareTo(a.pubDate ?? DateTime(0)),
          );

    return (podcast: podcast, episodes: episodes);
  } catch (e, stackTrace) {
    logger.log(
      'Error fetching podcast feed: $feedUrl',
      error: e,
      stackTrace: stackTrace,
    );
    return null;
  }
}

String _channelImage(XmlElement channel) {
  final href = channel.getElement('itunes:image')?.getAttribute('href')?.trim();
  if (href != null && href.isNotEmpty) return href;
  return channel.getElement('image')?.getElement('url')?.innerText.trim() ?? '';
}

PodcastEpisode? _episodeFromItem(
  XmlElement item,
  String podcastId,
  String podcastImage,
) {
  final title = _text(item, 'title');
  final audioUrl = item.getElement('enclosure')?.getAttribute('url')?.trim();
  if (title == null || audioUrl == null || audioUrl.isEmpty) return null;

  final guid = _text(item, 'guid') ?? audioUrl;
  final description =
      _text(item, 'itunes:summary') ?? _text(item, 'description') ?? '';
  final episodeImage = item
      .getElement('itunes:image')
      ?.getAttribute('href')
      ?.trim();

  return PodcastEpisode(
    guid: guid,
    podcastId: podcastId,
    title: title,
    audioUrl: audioUrl,
    image: (episodeImage != null && episodeImage.isNotEmpty)
        ? episodeImage
        : podcastImage,
    description: _stripHtml(description),
    pubDate: _parseRfc822Date(_text(item, 'pubDate')),
    durationSeconds: _parseItunesDuration(_text(item, 'itunes:duration')),
  );
}

String? _text(XmlElement element, String tag) {
  final value = element.getElement(tag)?.innerText.trim();
  return (value != null && value.isNotEmpty) ? value : null;
}

/// RSS descriptions are frequently HTML (`<p>`, `<a>`, entities...); episode
/// rows/detail pages here only render plain text.
String _stripHtml(String input) {
  if (input.isEmpty) return input;
  try {
    return html_parser.parse(input).body?.text.trim() ?? input.trim();
  } catch (_) {
    return input.trim();
  }
}

int? _parseItunesDuration(String? raw) {
  if (raw == null) return null;
  if (!raw.contains(':')) return int.tryParse(raw);

  final parts = raw.split(':').map((p) => int.tryParse(p) ?? 0).toList();
  if (parts.length == 3) return parts[0] * 3600 + parts[1] * 60 + parts[2];
  if (parts.length == 2) return parts[0] * 60 + parts[1];
  return null;
}

const _monthNames = {
  'jan': 1,
  'feb': 2,
  'mar': 3,
  'apr': 4,
  'may': 5,
  'jun': 6,
  'jul': 7,
  'aug': 8,
  'sep': 9,
  'oct': 10,
  'nov': 11,
  'dec': 12,
};

const _namedZoneOffsetHours = {
  'ut': 0,
  'gmt': 0,
  'utc': 0,
  'est': -5,
  'edt': -4,
  'cst': -6,
  'cdt': -5,
  'mst': -7,
  'mdt': -6,
  'pst': -8,
  'pdt': -7,
};

/// Lenient RFC 822 (RSS `pubDate`) parser: dart:io's HttpDate only accepts
/// the strict RFC 1123/GMT form, but feeds commonly use numeric offsets
/// (`+0000`) or US zone names (`PDT`).
///
/// ponytail: covers the shapes real-world feeds actually use; anything else
/// falls back to [DateTime.tryParse] (ISO 8601) and then null - an episode
/// with an unparsed date just sorts to the end instead of crashing the feed.
DateTime? _parseRfc822Date(String? raw) {
  if (raw == null) return null;
  final cleaned = raw.trim().replaceFirst(RegExp(r'^[A-Za-z]+,\s*'), '');
  final match = RegExp(
    r'^(\d{1,2})\s+([A-Za-z]{3})\w*\s+(\d{2,4})\s+(\d{1,2}):(\d{2})(?::(\d{2}))?\s*([+-]\d{4}|[A-Za-z]+)?$',
  ).firstMatch(cleaned);
  if (match == null) return DateTime.tryParse(raw.trim());

  final month = _monthNames[match.group(2)!.toLowerCase()];
  if (month == null) return DateTime.tryParse(raw.trim());

  final day = int.parse(match.group(1)!);
  var year = int.parse(match.group(3)!);
  if (year < 100) year += year < 70 ? 2000 : 1900;
  final hour = int.parse(match.group(4)!);
  final minute = int.parse(match.group(5)!);
  final second = int.tryParse(match.group(6) ?? '0') ?? 0;
  final zone = match.group(7);

  var offsetMinutes = 0;
  if (zone != null) {
    if (zone.startsWith('+') || zone.startsWith('-')) {
      final sign = zone.startsWith('-') ? -1 : 1;
      final hh = int.tryParse(zone.substring(1, 3)) ?? 0;
      final mm = int.tryParse(zone.substring(3, 5)) ?? 0;
      offsetMinutes = sign * (hh * 60 + mm);
    } else {
      offsetMinutes = (_namedZoneOffsetHours[zone.toLowerCase()] ?? 0) * 60;
    }
  }

  return DateTime.utc(
    year,
    month,
    day,
    hour,
    minute,
    second,
  ).subtract(Duration(minutes: offsetMinutes));
}
