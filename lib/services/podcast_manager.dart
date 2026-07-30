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

  String? _lastAutoMarkedKey;
  StreamSubscription<PositionData>? _positionSub;

  static List<Podcast> _loadSubscriptions() {
    final raw =
        Hive.box('user').get('podcastSubscriptions', defaultValue: [])
            as List;
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
  }

  Future<void> _persistSubscriptions() => addOrUpdateData<List>(
    'user',
    'podcastSubscriptions',
    subscriptions.value.map((p) => p.toMap()).toList(),
  );

  bool isListened(String episodeKey) =>
      listenedEpisodeKeys.value.contains(episodeKey);

  Future<void> setListened(
    String episodeKey, {
    required bool listened,
  }) async {
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
    final match = downloadedEpisodes.value.where(
      (e) => e['key'] == episodeKey,
    );
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

  Future<void> setEpisodeSortAscending(bool ascending) async {
    episodeSortAscending.value = ascending;
    await addOrUpdateData<bool>(
      'user',
      'podcastEpisodeSortAscending',
      ascending,
    );
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
        Hive.box(
              'user',
            ).get('podcastEpisodeSortAscending', defaultValue: false)
            as bool;
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
