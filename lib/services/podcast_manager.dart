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

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:dskplay/main.dart' show audioHandler, logger;
import 'package:dskplay/models/podcast_model.dart';
import 'package:dskplay/models/position_data.dart';
import 'package:dskplay/services/data_manager.dart';
import 'package:dskplay/services/podcast_feed_service.dart';

/// Subscriptions, listened/downloaded state and playback-progress tracking
/// for podcasts. Mirrors the radio stations state kept in
/// common_services.dart, split into its own file since podcasts are a much
/// larger surface area (episodes, downloads, listened status...).
class PodcastManager {
  factory PodcastManager() => _instance;
  PodcastManager._internal();
  static final PodcastManager _instance = PodcastManager._internal();

  // An episode counts as "listened" once this fraction of it has played -
  // matches what real podcast managers do (not just the first few seconds).
  static const double _listenedThreshold = 0.9;
  static const _minDurationForAutoMark = Duration(seconds: 30);

  final ValueNotifier<List<Podcast>> subscriptions =
      ValueNotifier<List<Podcast>>(_loadSubscriptions());

  final ValueNotifier<List<String>> listenedEpisodeKeys =
      ValueNotifier<List<String>>(
        List<String>.from(
          Hive.box('user').get('listenedPodcastEpisodes', defaultValue: []),
        ),
      );

  // Each entry is a PodcastEpisode.toMap() plus 'key', 'podcastTitle' and
  // 'audioPath' (the local downloaded file) so downloads stay browsable and
  // playable even when the podcast/episode isn't in the live feed anymore.
  final ValueNotifier<List<Map>> downloadedEpisodes = ValueNotifier<List<Map>>(
    List<Map>.from(
      Hive.box(
        'userNoBackup',
      ).get('downloadedPodcastEpisodes', defaultValue: []),
    ),
  );

  final ValueNotifier<bool> episodeSortAscending = ValueNotifier<bool>(
    Hive.box('user').get('podcastEpisodeSortAscending', defaultValue: false)
        as bool,
  );

  // Per-podcast override for the episode list order within its detail page
  // (unlike [episodeSortAscending] above, which only orders the
  // subscriptions list by latest episode date). Absent entries default to
  // newest-first (ascending: false), matching the app-wide default.
  final ValueNotifier<Map<String, bool>> episodeSortAscendingByPodcast =
      ValueNotifier<Map<String, bool>>(
        (Hive.box(
                  'user',
                ).get('podcastEpisodeSortAscendingByPodcast', defaultValue: {})
                as Map)
            .map((key, value) => MapEntry(key as String, value as bool)),
      );

  final ValueNotifier<bool> subscriptionsGridView = ValueNotifier<bool>(
    Hive.box('user').get('podcastSubscriptionsGridView', defaultValue: false)
        as bool,
  );

  // Total seconds listened per podcast id, kept forever (unlike the
  // wrapped/Time-Machine song stats, which trim old months down to their top
  // songs) so the statistics screen's all-time subscription ranking stays
  // accurate no matter how long ago an episode was played.
  final ValueNotifier<Map<String, int>> listenedSecondsByPodcast =
      ValueNotifier<Map<String, int>>(
        (Hive.box('user').get('podcastListenedSecondsByPodcast', defaultValue: {})
                as Map)
            .map((key, value) => MapEntry(key as String, value as int)),
      );

  // Total seconds listened per calendar month (key 'yyyy-MM'), across every
  // podcast - drives the statistics screen's history bar chart at month/year
  // granularity.
  final ValueNotifier<Map<String, int>> listenedSecondsByMonth =
      ValueNotifier<Map<String, int>>(
        (Hive.box('user').get('podcastListenedSecondsByMonth', defaultValue: {})
                as Map)
            .map((key, value) => MapEntry(key as String, value as int)),
      );

  // Total seconds listened per calendar day (key 'yyyy-MM-dd'), across every
  // podcast - only day/week granularity in the statistics screen's history
  // chart, so data predating this field simply won't show at those zoom
  // levels.
  final ValueNotifier<Map<String, int>> listenedSecondsByDay =
      ValueNotifier<Map<String, int>>(
        (Hive.box('user').get('podcastListenedSecondsByDay', defaultValue: {})
                as Map)
            .map((key, value) => MapEntry(key as String, value as int)),
      );

  /// Called from [ListeningStatsService.recordListening] whenever a podcast
  /// episode accrues listened time, so podcast statistics stay in sync with
  /// the same tick/session accounting used for song stats, without inheriting
  /// its per-month song trimming.
  Future<void> recordListenedTime(
    String podcastId,
    Duration listenedDuration,
    DateTime at,
  ) async {
    final seconds = listenedDuration.inSeconds;
    if (seconds <= 0) return;

    listenedSecondsByPodcast.value = {
      ...listenedSecondsByPodcast.value,
      podcastId: (listenedSecondsByPodcast.value[podcastId] ?? 0) + seconds,
    };
    await addOrUpdateData<Map>(
      'user',
      'podcastListenedSecondsByPodcast',
      listenedSecondsByPodcast.value,
    );

    final monthKey =
        '${at.year.toString().padLeft(4, '0')}-'
        '${at.month.toString().padLeft(2, '0')}';
    listenedSecondsByMonth.value = {
      ...listenedSecondsByMonth.value,
      monthKey: (listenedSecondsByMonth.value[monthKey] ?? 0) + seconds,
    };
    await addOrUpdateData<Map>(
      'user',
      'podcastListenedSecondsByMonth',
      listenedSecondsByMonth.value,
    );

    final dayKey =
        '$monthKey-${at.day.toString().padLeft(2, '0')}';
    listenedSecondsByDay.value = {
      ...listenedSecondsByDay.value,
      dayKey: (listenedSecondsByDay.value[dayKey] ?? 0) + seconds,
    };
    await addOrUpdateData<Map>(
      'user',
      'podcastListenedSecondsByDay',
      listenedSecondsByDay.value,
    );
  }

  // Ordered by the sequence they were pinned in (not alphabetical/date) - the
  // subscriptions list always shows these first, in this exact order, ahead
  // of whatever ascending/descending sort the user has picked.
  final ValueNotifier<List<String>> pinnedPodcastIds =
      ValueNotifier<List<String>>(
        List<String>.from(
          Hive.box('user').get('pinnedPodcastIds', defaultValue: []),
        ),
      );

  // Podcasts don't carry their own "latest episode" date - it only becomes
  // known once its feed has been fetched (subscribing or opening its detail
  // page). Recorded progressively so the subscriptions list can sort by it
  // without eagerly re-fetching every feed just to render the list.
  final ValueNotifier<Map<String, String>> latestEpisodeDates =
      ValueNotifier<Map<String, String>>(
        Map<String, String>.from(
          Hive.box('user').get('podcastLatestEpisodeDates', defaultValue: {}),
        ),
      );

  // Every episode key seen in each podcast's feed the last time it was
  // fetched (subscribing, opening its detail page, or refreshing), so the
  // subscriptions list can badge podcasts that have any episode not yet in
  // [listenedEpisodeKeys] - whether that's because it's a new release or
  // because the user explicitly marked it unlistened.
  final ValueNotifier<Map<String, List<String>>> episodeKeysByPodcast =
      ValueNotifier<Map<String, List<String>>>(
        (Hive.box('user').get('podcastEpisodeKeys', defaultValue: {}) as Map)
            .map(
              (key, value) =>
                  MapEntry(key as String, List<String>.from(value as List)),
            ),
      );

  String? _lastAutoMarkedKey;
  StreamSubscription<PositionData>? _positionSub;

  static List<Podcast> _loadSubscriptions() {
    final raw =
        Hive.box('user').get('podcastSubscriptions', defaultValue: []) as List;
    return raw
        .whereType<Map>()
        .map((p) => Podcast.fromMap(Map<String, dynamic>.from(p)))
        .toList();
  }

  bool isSubscribed(String podcastId) =>
      subscriptions.value.any((p) => p.id == podcastId);

  Future<void> subscribe(Podcast podcast) async {
    if (isSubscribed(podcast.id)) return;
    subscriptions.value = [...subscriptions.value, podcast];
    await _persistSubscriptions();
  }

  Future<void> unsubscribe(String podcastId) async {
    subscriptions.value = subscriptions.value
        .where((p) => p.id != podcastId)
        .toList();
    await _persistSubscriptions();
    await _unpin(podcastId);
  }

  Future<void> _persistSubscriptions() => addOrUpdateData<List>(
    'user',
    'podcastSubscriptions',
    subscriptions.value.map((p) => p.toMap()).toList(),
  );

  bool isPinned(String podcastId) =>
      pinnedPodcastIds.value.contains(podcastId);

  /// Pins are appended to the end of the list, so the pinned section of the
  /// subscriptions list reflects the order podcasts were pinned in.
  Future<void> togglePinned(String podcastId) async {
    if (isPinned(podcastId)) {
      await _unpin(podcastId);
    } else {
      pinnedPodcastIds.value = [...pinnedPodcastIds.value, podcastId];
      await _persistPinned();
    }
  }

  Future<void> _unpin(String podcastId) async {
    if (!isPinned(podcastId)) return;
    pinnedPodcastIds.value = pinnedPodcastIds.value
        .where((id) => id != podcastId)
        .toList();
    await _persistPinned();
  }

  Future<void> _persistPinned() =>
      addOrUpdateData<List>('user', 'pinnedPodcastIds', pinnedPodcastIds.value);

  bool isListened(String episodeKey) =>
      listenedEpisodeKeys.value.contains(episodeKey);

  Future<void> setListened(String episodeKey, {required bool listened}) async {
    final current = listenedEpisodeKeys.value;
    if (listened == current.contains(episodeKey)) return;

    listenedEpisodeKeys.value = listened
        ? [...current, episodeKey]
        : current.where((k) => k != episodeKey).toList();
    await _persistListened();
  }

  Future<void> setAllListened(
    List<String> episodeKeys, {
    required bool listened,
  }) async {
    final current = listenedEpisodeKeys.value.toSet();
    if (listened) {
      current.addAll(episodeKeys);
    } else {
      current.removeAll(episodeKeys);
    }
    listenedEpisodeKeys.value = current.toList();
    await _persistListened();
  }

  Future<void> _persistListened() => addOrUpdateData<List>(
    'user',
    'listenedPodcastEpisodes',
    listenedEpisodeKeys.value,
  );

  bool isDownloaded(String episodeKey) =>
      downloadedEpisodes.value.any((e) => e['key'] == episodeKey);

  Map? getDownloadedEpisode(String episodeKey) {
    final match = downloadedEpisodes.value.where((e) => e['key'] == episodeKey);
    return match.isEmpty ? null : match.first;
  }

  Future<void> addDownloadedEpisode(Map episodeData) async {
    downloadedEpisodes.value = [
      ...downloadedEpisodes.value.where((e) => e['key'] != episodeData['key']),
      episodeData,
    ];
    await addOrUpdateData<List>(
      'userNoBackup',
      'downloadedPodcastEpisodes',
      downloadedEpisodes.value,
    );
  }

  Future<void> removeDownloadedEpisode(String episodeKey) async {
    final entry = getDownloadedEpisode(episodeKey);
    if (entry == null) return;

    final path = entry['audioPath'] as String?;
    if (path != null && path.isNotEmpty) {
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } catch (e, stackTrace) {
        logger.log(
          'Error deleting downloaded podcast episode file',
          error: e,
          stackTrace: stackTrace,
        );
      }
    }

    downloadedEpisodes.value = downloadedEpisodes.value
        .where((e) => e['key'] != episodeKey)
        .toList();
    await addOrUpdateData<List>(
      'userNoBackup',
      'downloadedPodcastEpisodes',
      downloadedEpisodes.value,
    );
  }

  /// Drops any entry in [downloadedEpisodes] whose local file no longer
  /// exists (e.g. deleted from another app's file manager while this app was
  /// closed) - otherwise it stays "marked downloaded" forever and playback
  /// fails when it tries to play the missing file. Call once at startup.
  Future<void> pruneMissingDownloads() async {
    final missingKeys = <String>[];
    for (final episode in downloadedEpisodes.value) {
      final path = episode['audioPath'] as String?;
      if (path == null || path.isEmpty || !await File(path).exists()) {
        missingKeys.add(episode['key'] as String);
      }
    }
    if (missingKeys.isEmpty) return;

    downloadedEpisodes.value = downloadedEpisodes.value
        .where((e) => !missingKeys.contains(e['key']))
        .toList();
    await addOrUpdateData<List>(
      'userNoBackup',
      'downloadedPodcastEpisodes',
      downloadedEpisodes.value,
    );
  }

  DateTime? latestEpisodeDate(String podcastId) {
    final raw = latestEpisodeDates.value[podcastId];
    return raw != null ? DateTime.tryParse(raw) : null;
  }

  Future<void> recordLatestEpisodeDate(String podcastId, DateTime? date) async {
    if (date == null) return;
    latestEpisodeDates.value = {
      ...latestEpisodeDates.value,
      podcastId: date.toIso8601String(),
    };
    await addOrUpdateData<Map>(
      'user',
      'podcastLatestEpisodeDates',
      latestEpisodeDates.value,
    );
  }

  /// Re-fetches every subscribed podcast's feed to refresh
  /// [latestEpisodeDates] (so subscription-list sorting reflects newly
  /// published episodes) and [episodeKeysByPodcast] (so the new-episode
  /// badge stays accurate) without needing to open each podcast's detail
  /// page. Called on app startup and from the subscriptions screen's refresh
  /// button.
  Future<void> refreshAllSubscriptions() async {
    await Future.wait(
      subscriptions.value.map((podcast) async {
        final result = await fetchPodcastFeed(podcast.feedUrl);
        if (result == null || result.episodes.isEmpty) return;
        await recordLatestEpisodeDate(
          podcast.id,
          result.episodes.first.pubDate,
        );
        await recordEpisodeKeys(podcast.id, result.episodes);
      }),
    );
  }

  Future<void> recordEpisodeKeys(
    String podcastId,
    List<PodcastEpisode> episodes,
  ) async {
    episodeKeysByPodcast.value = {
      ...episodeKeysByPodcast.value,
      podcastId: episodes.map((e) => e.key).toList(),
    };
    await addOrUpdateData<Map>(
      'user',
      'podcastEpisodeKeys',
      episodeKeysByPodcast.value,
    );
  }

  /// Whether [podcastId] has any episode not yet in [listenedEpisodeKeys] -
  /// drives the subscriptions list's "new episode" badge. True for both a
  /// newly published episode and one the user explicitly marked unlistened.
  bool hasNewEpisode(String podcastId) {
    final keys = episodeKeysByPodcast.value[podcastId];
    if (keys == null) return false;
    return keys.any((key) => !listenedEpisodeKeys.value.contains(key));
  }

  Future<void> setEpisodeSortAscending(bool ascending) async {
    episodeSortAscending.value = ascending;
    await addOrUpdateData<bool>(
      'user',
      'podcastEpisodeSortAscending',
      ascending,
    );
  }

  bool episodeSortAscendingFor(String podcastId) =>
      episodeSortAscendingByPodcast.value[podcastId] ?? false;

  Future<void> setEpisodeSortAscendingFor(
    String podcastId,
    bool ascending,
  ) async {
    episodeSortAscendingByPodcast.value = {
      ...episodeSortAscendingByPodcast.value,
      podcastId: ascending,
    };
    await addOrUpdateData<Map>(
      'user',
      'podcastEpisodeSortAscendingByPodcast',
      episodeSortAscendingByPodcast.value,
    );
  }

  Future<void> setSubscriptionsGridView(bool gridView) async {
    subscriptionsGridView.value = gridView;
    await addOrUpdateData<bool>(
      'user',
      'podcastSubscriptionsGridView',
      gridView,
    );
  }

  /// Merges externally-imported podcast data (subscriptions, listened
  /// episodes, pinned podcasts and listening-time stats) into the current
  /// state without ever discarding anything already present - shared by the
  /// "import data"/"import from other app" settings features so imports are
  /// always additive, never destructive.
  Future<int> mergeImportedPodcastData({
    List<Podcast> subscriptions = const [],
    List<String> listenedEpisodeKeys = const [],
    List<String> pinnedPodcastIds = const [],
    Map<String, int> listenedSecondsByPodcast = const {},
    Map<String, int> listenedSecondsByMonth = const {},
    Map<String, int> listenedSecondsByDay = const {},
  }) async {
    var addedCount = 0;

    for (final podcast in subscriptions) {
      if (!isSubscribed(podcast.id)) {
        await subscribe(podcast);
        addedCount++;
      }
    }

    if (listenedEpisodeKeys.isNotEmpty) {
      final before = this.listenedEpisodeKeys.value.length;
      await setAllListened(listenedEpisodeKeys, listened: true);
      addedCount += this.listenedEpisodeKeys.value.length - before;
    }

    for (final id in pinnedPodcastIds) {
      if (!isPinned(id)) {
        await togglePinned(id);
        addedCount++;
      }
    }

    await _mergeStatsMax(
      'podcastListenedSecondsByPodcast',
      this.listenedSecondsByPodcast,
      listenedSecondsByPodcast,
    );
    await _mergeStatsMax(
      'podcastListenedSecondsByMonth',
      this.listenedSecondsByMonth,
      listenedSecondsByMonth,
    );
    await _mergeStatsMax(
      'podcastListenedSecondsByDay',
      this.listenedSecondsByDay,
      listenedSecondsByDay,
    );

    return addedCount;
  }

  // ponytail: merges by keeping the larger value per key instead of summing,
  // so re-importing the same source file twice doesn't double-count listened
  // time. Trade-off: if two sources both hold genuine, different time for the
  // same key, only the larger one survives - acceptable for a manual, rare
  // import compared to the risk of inflating stats on every re-import.
  Future<void> _mergeStatsMax(
    String hiveKey,
    ValueNotifier<Map<String, int>> notifier,
    Map<String, int> incoming,
  ) async {
    if (incoming.isEmpty) return;
    final merged = Map<String, int>.from(notifier.value);
    for (final entry in incoming.entries) {
      final current = merged[entry.key] ?? 0;
      if (entry.value > current) merged[entry.key] = entry.value;
    }
    notifier.value = merged;
    await addOrUpdateData<Map>('user', hiveKey, merged);
  }

  // Backup/restore swaps the 'user'/'userNoBackup' Hive box files on disk,
  // but these ValueNotifiers were only seeded once at app start - refresh
  // them manually afterwards, same as reloadRadioStationsStateFromStorage.
  void reloadFromStorage() {
    subscriptions.value = _loadSubscriptions();
    listenedEpisodeKeys.value = List<String>.from(
      Hive.box('user').get('listenedPodcastEpisodes', defaultValue: []),
    );
    downloadedEpisodes.value = List<Map>.from(
      Hive.box(
        'userNoBackup',
      ).get('downloadedPodcastEpisodes', defaultValue: []),
    );
    episodeSortAscending.value =
        Hive.box('user').get('podcastEpisodeSortAscending', defaultValue: false)
            as bool;
    subscriptionsGridView.value =
        Hive.box(
              'user',
            ).get('podcastSubscriptionsGridView', defaultValue: false)
            as bool;
    episodeSortAscendingByPodcast.value =
        (Hive.box(
                  'user',
                ).get(
                  'podcastEpisodeSortAscendingByPodcast',
                  defaultValue: {},
                )
                as Map)
            .map((key, value) => MapEntry(key as String, value as bool));
    latestEpisodeDates.value = Map<String, String>.from(
      Hive.box('user').get('podcastLatestEpisodeDates', defaultValue: {}),
    );
    episodeKeysByPodcast.value =
        (Hive.box('user').get('podcastEpisodeKeys', defaultValue: {}) as Map)
            .map(
              (key, value) =>
                  MapEntry(key as String, List<String>.from(value as List)),
            );
    pinnedPodcastIds.value = List<String>.from(
      Hive.box('user').get('pinnedPodcastIds', defaultValue: []),
    );
    listenedSecondsByPodcast.value =
        (Hive.box(
                  'user',
                ).get('podcastListenedSecondsByPodcast', defaultValue: {})
                as Map)
            .map((key, value) => MapEntry(key as String, value as int));
    listenedSecondsByMonth.value =
        (Hive.box(
                  'user',
                ).get('podcastListenedSecondsByMonth', defaultValue: {})
                as Map)
            .map((key, value) => MapEntry(key as String, value as int));
    listenedSecondsByDay.value =
        (Hive.box(
                  'user',
                ).get('podcastListenedSecondsByDay', defaultValue: {})
                as Map)
            .map((key, value) => MapEntry(key as String, value as int));
  }

  /// Watches playback progress and auto-marks the currently playing episode
  /// as listened once [_listenedThreshold] of it has played. Podcast
  /// episode media items always carry a [Podcast.idFromFeedUrl]-derived id
  /// (prefixed `pod_`), which is how this tells them apart from songs/radio
  /// without needing a dedicated "now playing a podcast" flag. Call once at
  /// app startup.
  void attachAutoMarkListened() {
    _positionSub?.cancel();
    _positionSub = audioHandler.positionDataStream.listen((data) {
      final episodeKey = audioHandler.mediaItem.value?.id;
      if (episodeKey == null || !episodeKey.startsWith('pod_')) return;
      if (episodeKey == _lastAutoMarkedKey) return;
      if (data.duration < _minDurationForAutoMark) return;

      final progress =
          data.position.inMilliseconds / data.duration.inMilliseconds;
      if (progress >= _listenedThreshold) {
        _lastAutoMarkedKey = episodeKey;
        unawaited(setListened(episodeKey, listened: true));
      }
    });
  }
}

final podcastManager = PodcastManager();
