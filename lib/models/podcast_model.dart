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

/// A subscribed/discoverable podcast (an RSS feed).
///
/// [id] is derived from [feedUrl] (see [Podcast.idFromFeedUrl]) so the same
/// feed always resolves to the same id regardless of where it was
/// discovered (search vs. manual add).
class Podcast {
  const Podcast({
    required this.id,
    required this.title,
    required this.author,
    required this.image,
    required this.feedUrl,
    this.description = '',
  });

  factory Podcast.fromMap(Map<String, dynamic> map) {
    return Podcast(
      id: map['id'] as String,
      title: map['title'] as String,
      author: map['author'] as String? ?? '',
      image: map['image'] as String? ?? '',
      feedUrl: map['feedUrl'] as String,
      description: map['description'] as String? ?? '',
    );
  }

  static String idFromFeedUrl(String feedUrl) => 'pod_${feedUrl.hashCode}';

  final String id;
  final String title;
  final String author;
  final String image;
  final String feedUrl;
  final String description;

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'author': author,
      'image': image,
      'feedUrl': feedUrl,
      'description': description,
    };
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is Podcast && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;
}

/// A single episode parsed from a podcast's RSS feed.
///
/// [key] uniquely identifies the episode across the whole app (used as the
/// listened/downloaded/media-item id) - the RSS `guid` alone isn't
/// guaranteed unique across different podcasts.
class PodcastEpisode {
  const PodcastEpisode({
    required this.guid,
    required this.podcastId,
    required this.title,
    required this.audioUrl,
    required this.image,
    this.description = '',
    this.pubDate,
    this.durationSeconds,
  });

  factory PodcastEpisode.fromMap(Map<String, dynamic> map) {
    return PodcastEpisode(
      guid: map['guid'] as String,
      podcastId: map['podcastId'] as String,
      title: map['title'] as String,
      audioUrl: map['audioUrl'] as String,
      image: map['image'] as String? ?? '',
      description: map['description'] as String? ?? '',
      pubDate: map['pubDate'] != null
          ? DateTime.tryParse(map['pubDate'] as String)
          : null,
      durationSeconds: map['durationSeconds'] as int?,
    );
  }

  final String guid;
  final String podcastId;
  final String title;
  final String audioUrl;
  final String image;
  final String description;
  final DateTime? pubDate;
  final int? durationSeconds;

  String get key => '${podcastId}_${guid.hashCode}';

  Map<String, dynamic> toMap() {
    return {
      'guid': guid,
      'podcastId': podcastId,
      'title': title,
      'audioUrl': audioUrl,
      'image': image,
      'description': description,
      'pubDate': pubDate?.toIso8601String(),
      'durationSeconds': durationSeconds,
    };
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is PodcastEpisode && other.key == key;
  }

  @override
  int get hashCode => key.hashCode;
}

/// Plain-text summary of an episode (podcast, episode title, description,
/// audio link) for the "copy episode info" buttons in the episode list and
/// full-screen player.
String podcastEpisodeCopyText(String podcastTitle, PodcastEpisode episode) {
  final lines = [
    podcastTitle,
    episode.title,
    if (episode.description.trim().isNotEmpty) episode.description.trim(),
    if (episode.audioUrl.trim().isNotEmpty) episode.audioUrl.trim(),
  ];
  return lines.join('\n\n');
}
