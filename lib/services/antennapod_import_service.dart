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

import 'package:sqlite3/sqlite3.dart';
import 'package:dskplay/models/podcast_model.dart';
import 'package:dskplay/services/podcast_manager.dart';

/// Parsed, ready-to-apply contents of an AntennaPod SQLite backup (its
/// `Feeds`/`FeedItems`/`FeedMedia` tables), plus a few counters so the UI can
/// show the user what will be imported before they confirm.
class AntennaPodImportPreview {
  const AntennaPodImportPreview({
    required this.podcasts,
    required this.listenedEpisodeKeys,
    required this.listenedSecondsByPodcast,
    required this.listenedSecondsByMonth,
    required this.listenedSecondsByDay,
    required this.totalListenedSeconds,
  });

  final List<Podcast> podcasts;
  final List<String> listenedEpisodeKeys;
  final Map<String, int> listenedSecondsByPodcast;
  final Map<String, int> listenedSecondsByMonth;
  final Map<String, int> listenedSecondsByDay;
  final int totalListenedSeconds;

  int get podcastCount => podcasts.length;
  int get listenedEpisodeCount => listenedEpisodeKeys.length;
  double get totalListenedHours => totalListenedSeconds / 3600;
}

/// Reads an AntennaPod `.db` backup (SQLite export of its `Feeds`,
/// `FeedItems` and `FeedMedia` tables) and builds an [AntennaPodImportPreview]
/// without touching any app data yet - lets the settings UI show a summary
/// and ask for confirmation before [applyAntennaPodImport] actually merges
/// it in.
///
/// ponytail: AntennaPod only stores a cumulative `played_duration` and
/// `last_played_time` per episode, not a session-by-session log, so all of
/// an episode's listened time is attributed to the single day/month it was
/// last played on - an approximation, not an exact reconstruction of when
/// that time was actually spent.
AntennaPodImportPreview analyzeAntennaPodBackup(String dbPath) {
  final db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
  try {
    final podcasts = <Podcast>[];
    final podcastIdByFeedRowId = <int, String>{};

    final feedRows = db.select(
      'SELECT id, title, author, download_url, image_url FROM Feeds',
    );
    for (final row in feedRows) {
      final feedUrl = row['download_url'] as String?;
      if (feedUrl == null || feedUrl.isEmpty) continue;
      final podcastId = Podcast.idFromFeedUrl(feedUrl);
      podcastIdByFeedRowId[row['id'] as int] = podcastId;
      podcasts.add(
        Podcast(
          id: podcastId,
          title: row['title'] as String? ?? '',
          author: row['author'] as String? ?? '',
          image: row['image_url'] as String? ?? '',
          feedUrl: feedUrl,
        ),
      );
    }

    final listenedEpisodeKeys = <String>[];
    final listenedSecondsByPodcast = <String, int>{};
    final listenedSecondsByMonth = <String, int>{};
    final listenedSecondsByDay = <String, int>{};
    var totalListenedSeconds = 0;

    final episodeRows = db.select('''
      SELECT fi.item_identifier AS guid, fi.feed AS feedRowId, fi.read AS isRead,
             fm.played_duration AS playedDuration, fm.last_played_time AS lastPlayedTime
      FROM FeedItems fi
      LEFT JOIN FeedMedia fm ON fm.feeditem = fi.id
    ''');

    for (final row in episodeRows) {
      final feedRowId = row['feedRowId'] as int?;
      final podcastId = podcastIdByFeedRowId[feedRowId];
      if (podcastId == null) continue;

      final guid = row['guid'] as String?;
      final isRead = (row['isRead'] as int?) == 1;
      final playedDurationMs = row['playedDuration'] as int?;
      final hasPlayedTime = playedDurationMs != null && playedDurationMs > 0;

      if (guid != null && guid.isNotEmpty && (isRead || hasPlayedTime)) {
        listenedEpisodeKeys.add('${podcastId}_${guid.hashCode}');
      }

      if (!hasPlayedTime) continue;
      final seconds = playedDurationMs ~/ 1000;
      if (seconds <= 0) continue;

      totalListenedSeconds += seconds;
      listenedSecondsByPodcast[podcastId] =
          (listenedSecondsByPodcast[podcastId] ?? 0) + seconds;

      final lastPlayedMs = row['lastPlayedTime'] as int?;
      if (lastPlayedMs == null || lastPlayedMs <= 0) continue;
      final playedAt = DateTime.fromMillisecondsSinceEpoch(lastPlayedMs);
      final monthKey =
          '${playedAt.year.toString().padLeft(4, '0')}-'
          '${playedAt.month.toString().padLeft(2, '0')}';
      final dayKey = '$monthKey-${playedAt.day.toString().padLeft(2, '0')}';
      listenedSecondsByMonth[monthKey] =
          (listenedSecondsByMonth[monthKey] ?? 0) + seconds;
      listenedSecondsByDay[dayKey] =
          (listenedSecondsByDay[dayKey] ?? 0) + seconds;
    }

    return AntennaPodImportPreview(
      podcasts: podcasts,
      listenedEpisodeKeys: listenedEpisodeKeys,
      listenedSecondsByPodcast: listenedSecondsByPodcast,
      listenedSecondsByMonth: listenedSecondsByMonth,
      listenedSecondsByDay: listenedSecondsByDay,
      totalListenedSeconds: totalListenedSeconds,
    );
  } finally {
    db.dispose();
  }
}

/// Merges an already-parsed [AntennaPodImportPreview] into the app's podcast
/// data. Purely additive - see [PodcastManager.mergeImportedPodcastData].
Future<int> applyAntennaPodImport(AntennaPodImportPreview preview) {
  return podcastManager.mergeImportedPodcastData(
    subscriptions: preview.podcasts,
    listenedEpisodeKeys: preview.listenedEpisodeKeys,
    listenedSecondsByPodcast: preview.listenedSecondsByPodcast,
    listenedSecondsByMonth: preview.listenedSecondsByMonth,
    listenedSecondsByDay: preview.listenedSecondsByDay,
  );
}
