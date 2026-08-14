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
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audiotags/audiotags.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:flutter/widgets.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:dskplay/constants/clients.dart';
import 'package:dskplay/main.dart' show logger;
import 'package:dskplay/models/radio_model.dart';
import 'package:dskplay/services/data_manager.dart';
import 'package:dskplay/services/download_foreground_service.dart';
import 'package:dskplay/services/io_service.dart';
import 'package:dskplay/services/lyrics_manager.dart';
import 'package:dskplay/services/playlists_manager.dart';
import 'package:dskplay/services/proxy_manager.dart';
import 'package:dskplay/services/settings_manager.dart';
import 'package:dskplay/utilities/app_utils.dart';
import 'package:dskplay/utilities/formatter.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

List globalSongs = [];

ValueNotifier<List> userLikedSongsList = ValueNotifier<List>(
  Hive.box('user').get('likedSongs', defaultValue: []),
);

ValueNotifier<List<String>> userLikedRadioStations =
    ValueNotifier<List<String>>(
      List<String>.from(
        Hive.box('user').get('likedRadioStations', defaultValue: []),
      ),
    );

ValueNotifier<List<RadioStation>> userCustomRadioStations =
    ValueNotifier<List<RadioStation>>(_loadCustomRadioStations());

List<RadioStation> _loadCustomRadioStations() {
  final raw =
      Hive.box('user').get('customRadioStations', defaultValue: []) as List;
  return raw
      .whereType<Map>()
      .map(
        (station) => RadioStation.fromMap(Map<String, dynamic>.from(station)),
      )
      .toList();
}

Future<void> addCustomRadioStation(RadioStation station) async {
  if (userCustomRadioStations.value.any((s) => s.id == station.id)) return;

  final updated = [...userCustomRadioStations.value, station];
  userCustomRadioStations.value = updated;
  await addOrUpdateData<List>(
    'user',
    'customRadioStations',
    updated.map((s) => s.toMap()).toList(),
  );
}

Future<void> removeCustomRadioStation(String stationId) async {
  final updated = userCustomRadioStations.value
      .where((s) => s.id != stationId)
      .toList();
  userCustomRadioStations.value = updated;
  await addOrUpdateData<List>(
    'user',
    'customRadioStations',
    updated.map((s) => s.toMap()).toList(),
  );
}

// User-defined drag order for the radio stations list (custom + built-in
// combined). Ids missing from here (new/never-reordered stations) fall back
// to their natural position - see [applyRadioStationOrder].
ValueNotifier<List<String>> userRadioStationOrder = ValueNotifier<List<String>>(
  List<String>.from(
    Hive.box('user').get('radioStationOrder', defaultValue: []),
  ),
);

/// Applies the user's stored drag order on top of [naturalIds] (the
/// custom+built-in stations in their default order): known ids keep the
/// relative order the user dragged them into, anything not yet ordered is
/// appended afterwards in its natural order.
List<String> applyRadioStationOrder(List<String> naturalIds) {
  final naturalSet = naturalIds.toSet();
  final ordered = [
    for (final id in userRadioStationOrder.value)
      if (naturalSet.contains(id)) id,
  ];
  final orderedSet = ordered.toSet();
  final remaining = [
    for (final id in naturalIds)
      if (!orderedSet.contains(id)) id,
  ];
  return [...ordered, ...remaining];
}

/// Reorders one entry within the currently displayed radio stations order
/// (mirrors [reorderLikedLibraryItem]). [displayedOrderIds] is the id order
/// the list is showing right now (liked stations bubbled to the top); since
/// that partition is reapplied on every rebuild, dropping an item across the
/// liked/unliked boundary just settles back into the correct group.
void reorderRadioStation(String stationId, int newIndex, List<String> displayedOrderIds) {
  final list = List<String>.from(displayedOrderIds);
  final oldIndex = list.indexOf(stationId);
  if (oldIndex == -1) return;

  final target = newIndex.clamp(0, list.length - 1);
  list.insert(target, list.removeAt(oldIndex));

  userRadioStationOrder.value = list;
  unawaited(addOrUpdateData<List>('user', 'radioStationOrder', list));
}

// Built-in stations live in a compiled-in list (radioStationsDB), so
// "removing" one just remembers its id and hides it from view, instead of
// mutating that list.
ValueNotifier<List<String>> userHiddenRadioStationIds =
    ValueNotifier<List<String>>(
      List<String>.from(
        Hive.box('user').get('hiddenRadioStationIds', defaultValue: []),
      ),
    );

Future<void> hideBuiltInRadioStation(String stationId) async {
  if (userHiddenRadioStationIds.value.contains(stationId)) return;

  final updated = [...userHiddenRadioStationIds.value, stationId];
  userHiddenRadioStationIds.value = updated;
  await addOrUpdateData<List>('user', 'hiddenRadioStationIds', updated);
}

// Backup/restore swaps the 'user' Hive box file on disk, but these
// ValueNotifiers were only seeded once at app start, so they need to be
// refreshed manually after a restore for the change to show up immediately.
void reloadRadioStationsStateFromStorage() {
  final userBox = Hive.box('user');
  userLikedRadioStations.value = List<String>.from(
    userBox.get('likedRadioStations', defaultValue: []),
  );
  userCustomRadioStations.value = _loadCustomRadioStations();
  userHiddenRadioStationIds.value = List<String>.from(
    userBox.get('hiddenRadioStationIds', defaultValue: []),
  );
  userRadioStationOrder.value = List<String>.from(
    userBox.get('radioStationOrder', defaultValue: []),
  );
}

// Songs the user dismissed from "Recommended for you"; recommendations are
// computed fresh every time (not cached), so this is filtered back out of
// the result rather than mutated at the source.
ValueNotifier<List<String>> userHiddenRecommendationIds =
    ValueNotifier<List<String>>(
      List<String>.from(
        Hive.box('user').get('hiddenRecommendationIds', defaultValue: []),
      ),
    );

Future<void> hideSongFromRecommendations(String ytid) async {
  if (userHiddenRecommendationIds.value.contains(ytid)) return;

  final updated = [...userHiddenRecommendationIds.value, ytid];
  userHiddenRecommendationIds.value = updated;
  await addOrUpdateData<List>('user', 'hiddenRecommendationIds', updated);
}

ValueNotifier<List> userRecentlyPlayed = ValueNotifier<List>(
  Hive.box('user').get('recentlyPlayedSongs', defaultValue: []),
);
ValueNotifier<List> userOfflineSongs = ValueNotifier<List>(
  Hive.box('userNoBackup').get('offlineSongs', defaultValue: []),
);

/// Reorders one entry within [userLikedSongsList] (drag-to-reorder in the
/// "liked songs" library tab, mirroring [reorderLikedLibraryItem]).
void reorderLikedSong(String ytid, int newIndex) {
  _reorderLikedSubsequence(
    ytid,
    newIndex,
    matches: (song) => song['isPodcastEpisode'] != true,
  );
}

/// Reorders one entry among the podcast-episode entries of
/// [userLikedSongsList] (drag-to-reorder in the podcast favorites screen).
void reorderLikedPodcastEpisode(String ytid, int newIndex) {
  _reorderLikedSubsequence(
    ytid,
    newIndex,
    matches: (song) => song['isPodcastEpisode'] == true,
  );
}

/// Reorders one entry within the subsequence of [userLikedSongsList] that
/// [matches] selects, leaving every other entry's own slot untouched -
/// liked songs and liked podcast episodes share the same list but are shown
/// (and reordered) on separate screens, so [reorderLikedSong] and
/// [reorderLikedPodcastEpisode] must only permute their own subsequence
/// instead of reindexing the whole list against a drag position computed
/// from just one of the two filtered views.
void _reorderLikedSubsequence(
  String ytid,
  int newIndex, {
  required bool Function(Map song) matches,
}) {
  final full = List<Map>.from(userLikedSongsList.value.whereType<Map>());
  final slots = <int>[];
  final subsequence = <Map>[];
  for (var i = 0; i < full.length; i++) {
    if (matches(full[i])) {
      slots.add(i);
      subsequence.add(full[i]);
    }
  }

  final oldIndex = subsequence.indexWhere(
    (s) => s['ytid']?.toString() == ytid,
  );
  if (oldIndex == -1) return;

  final target = newIndex.clamp(0, subsequence.length - 1);
  subsequence.insert(target, subsequence.removeAt(oldIndex));

  for (var i = 0; i < slots.length; i++) {
    full[slots[i]] = subsequence[i];
  }

  userLikedSongsList.value = full;
  unawaited(addOrUpdateData<List>('user', 'likedSongs', full));
}

/// Reorders one entry within [userOfflineSongs] (drag-to-reorder in the
/// "offline songs" library tab, only meaningful while sorted by
/// [OfflineSortType.default_]).
void reorderOfflineSong(String ytid, int newIndex) {
  final list = List<Map>.from(userOfflineSongs.value.whereType<Map>());
  final oldIndex = list.indexWhere((s) => s['ytid']?.toString() == ytid);
  if (oldIndex == -1) return;

  final target = newIndex.clamp(0, list.length - 1);
  list.insert(target, list.removeAt(oldIndex));

  userOfflineSongs.value = list;
  unawaited(addOrUpdateData<List>('userNoBackup', 'offlineSongs', list));
}

dynamic nextRecommendedSong;

var _songLikeUpdateToken = 0;
final _latestSongLikeUpdateTokens = <String, int>{};

// Keyed by ytid (falling back to "artist|title" when there's none), so
// re-showing the lyrics of a song already fetched this session - e.g.
// after switching tabs and coming back - is instant instead of
// re-searching every source again. Also used to remember a lyrics result
// the user manually picked from the search picker.
final Map<String, LyricsResult?> _lyricsCache = {};

String lyricsCacheKeyFor(String? songId, String? artist, String title) =>
    (songId != null && songId.isNotEmpty) ? songId : '${artist ?? ''}|$title';

LyricsResult? getCachedLyrics(String cacheKey) => _lyricsCache[cacheKey];

void cacheLyricsResult(String cacheKey, LyricsResult? result) {
  _lyricsCache[cacheKey] = result;
}

void reloadSongLibraryStateFromStorage() {
  final userBox = Hive.box('user');
  userLikedSongsList.value = List.from(
    userBox.get('likedSongs', defaultValue: []),
  );
  userRecentlyPlayed.value = List.from(
    userBox.get('recentlyPlayedSongs', defaultValue: []),
  );
  userHiddenRecommendationIds.value = List<String>.from(
    userBox.get('hiddenRecommendationIds', defaultValue: []),
  );
}

// Timeouts and durations used across manifest fetching and cache validation.
const Duration _manifestTimeout = Duration(seconds: 30);
const Duration _cacheValidationDuration = Duration(hours: 1);

/// Fetches a stream manifest for a song, honoring proxy settings.
Future<StreamManifest?> _fetchStreamManifest(String songId) async {
  if (useProxy.value) {
    return ProxyManager().getSongManifest(songId).timeout(_manifestTimeout);
  }

  return ytClient.videos.streams
      .getManifest(songId, ytClients: customClients)
      .timeout(_manifestTimeout);
}

/// Returns a cached song URL if present and still valid.
Future<String?> _getCachedSongUrl(
  String cacheKey,
  Duration cacheDuration,
) async {
  final cachedUrl = await getData(
    'cache',
    cacheKey,
    cachingDuration: cacheDuration,
  );

  if (cachedUrl is! String || cachedUrl.isEmpty) {
    return null;
  }

  final cacheBox = await Hive.openBox('cache');
  final cacheDate = cacheBox.get('${cacheKey}_date') as DateTime?;
  final now = DateTime.now();
  final isOld =
      cacheDate != null && now.difference(cacheDate) > _cacheValidationDuration;

  if (!isOld) {
    return cachedUrl;
  }

  if (await _validateCachedUrl(cachedUrl)) {
    return cachedUrl;
  }

  await deleteData('cache', cacheKey);
  await deleteData('cache', '${cacheKey}_date');
  return null;
}

/// Checks if a cached URL still responds successfully.
Future<bool> _validateCachedUrl(String cachedUrl) async {
  try {
    final response = await http.head(Uri.parse(cachedUrl));
    return response.statusCode >= 200 && response.statusCode < 300;
  } catch (_) {
    return false;
  }
}

// YouTube sends search results in batches of ~20; a single batch isn't
// enough for artists/queries with large catalogs, so fetch several pages.
const _searchResultPages = 5;

Future<List> fetchSongsList(String searchQuery) async {
  try {
    final searchResults = <Video>[];
    var page = await ytClient.search.search(searchQuery);
    searchResults.addAll(page);

    for (var i = 1; i < _searchResultPages; i++) {
      final nextPage = await page.nextPage();
      if (nextPage == null || nextPage.isEmpty) break;
      searchResults.addAll(nextPage);
      page = nextPage;
    }

    return searchResults.map((video) => returnSongLayout(0, video)).toList();
  } catch (e, stackTrace) {
    logger.log('Error in fetchSongsList', error: e, stackTrace: stackTrace);
    return [];
  }
}

Future<List> getRecommendedSongs() async {
  try {
    final recommendations =
        externalRecommendations.value && userRecentlyPlayed.value.isNotEmpty
        ? await _getRecommendationsFromRecentlyPlayed()
        : await _getRecommendationsFromMixedSources();

    if (userHiddenRecommendationIds.value.isEmpty) return recommendations;
    return recommendations
        .where((s) => !userHiddenRecommendationIds.value.contains(s['ytid']))
        .toList();
  } catch (e, stackTrace) {
    logger.log(
      'Error in getRecommendedSongs',
      error: e,
      stackTrace: stackTrace,
    );
    return [];
  }
}

Future<List> _getRecommendationsFromRecentlyPlayed() async {
  final recent = (List.from(
    userRecentlyPlayed.value,
  )..shuffle()).take(5).toList();

  final scores = <String, double>{};
  final songMap = <String, Map>{};

  final futures = recent.asMap().entries.map((entry) async {
    final seedIndex = entry.key;
    final songData = entry.value;
    try {
      final song = await ytClient.videos.get(songData['ytid']);
      final related = await ytClient.videos.getRelatedVideos(song) ?? [];
      for (var i = 0; i < related.length && i < 8; i++) {
        final s = returnSongLayout(0, related[i]);
        final id = s['ytid'];
        final positionWeight = 1.0 - (i / 8);
        final recencyWeight = 1.0 - (seedIndex / recent.length);
        scores[id] = (scores[id] ?? 0) + positionWeight * recencyWeight;
        songMap[id] = s;
      }
    } catch (e, st) {
      logger.log(
        'related videos error for ${songData['ytid']}',
        error: e,
        stackTrace: st,
      );
    }
  }).toList();

  await Future.wait(futures);

  final sorted = scores.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  return sorted.take(15).map((e) => songMap[e.key]!).toList();
}

Future<List> _getRecommendationsFromMixedSources() async {
  final playlistSongs = [
    ...userLikedSongsList.value,
    ...userRecentlyPlayed.value,
  ];

  if (globalSongs.isEmpty) {
    const playlistId = 'PLgzTt0k8mXzEk586ze4BjvDXR7c-TUSnx';
    globalSongs = await getSongsFromPlaylist(playlistId);
  }
  playlistSongs.addAll(globalSongs.take(10));

  if (userCustomPlaylists.value.isNotEmpty) {
    for (final userPlaylist in userCustomPlaylists.value) {
      final _list = List.from(userPlaylist['list'] as List)..shuffle();
      playlistSongs.addAll(_list.take(5));
    }
  }

  return _deduplicateAndShuffle(playlistSongs);
}

List _deduplicateAndShuffle(List playlistSongs) {
  final seenYtIds = <String>{};
  final uniqueSongs = <Map>[];

  playlistSongs.shuffle();

  for (final song in playlistSongs) {
    if (song['ytid'] != null && seenYtIds.add(song['ytid'])) {
      uniqueSongs.add(song);
      // Early exit when we have enough songs
      if (uniqueSongs.length >= 15) break;
    }
  }

  return uniqueSongs;
}

Future<void> updateSongLikeStatus(
  dynamic songId,
  bool add, {
  Map? songData,
}) async {
  try {
    final normalizedSongId = songId?.toString().trim() ?? '';
    if (normalizedSongId.isEmpty) return;

    final updateToken = ++_songLikeUpdateToken;
    _latestSongLikeUpdateTokens[normalizedSongId] = updateToken;

    final songToAdd = add
        ? await _resolveSongForLikedStatus(normalizedSongId, songData)
        : null;

    if (_latestSongLikeUpdateTokens[normalizedSongId] != updateToken) {
      return;
    }

    final updatedLikedSongs = _deduplicateLikedSongs(userLikedSongsList.value);

    if (add) {
      if (songToAdd != null &&
          !updatedLikedSongs.any(
            (song) => song['ytid']?.toString() == normalizedSongId,
          )) {
        updatedLikedSongs.insert(0, songToAdd);
      }
    } else {
      updatedLikedSongs.removeWhere(
        (song) => song['ytid']?.toString() == normalizedSongId,
      );
    }

    if (_likedSongIdsAreEqual(userLikedSongsList.value, updatedLikedSongs))
      return;

    userLikedSongsList.value = updatedLikedSongs;
    unawaited(
      addOrUpdateData<List>('user', 'likedSongs', userLikedSongsList.value),
    );
  } catch (e, stackTrace) {
    logger.log(
      'Error updating song like status',
      error: e,
      stackTrace: stackTrace,
    );
  }
}

Future<Map?> _resolveSongForLikedStatus(String songId, Map? songData) async {
  if (songData?['ytid']?.toString() == songId) {
    return Map<String, dynamic>.from(songData!);
  }

  final cachedSong = _findSongById(userLikedSongsList.value, songId);
  if (cachedSong != null) return Map<String, dynamic>.from(cachedSong);

  return getSongDetails(userLikedSongsList.value.length, songId);
}

Map? _findSongById(Iterable<dynamic> songs, String songId) {
  for (final song in songs) {
    if (song is Map && song['ytid']?.toString() == songId) return song;
  }

  return null;
}

List _deduplicateLikedSongs(Iterable<dynamic> likedSongs) {
  final seenSongIds = <String>{};
  final deduplicatedSongs = [];

  for (final song in likedSongs) {
    if (song is! Map) {
      deduplicatedSongs.add(song);
      continue;
    }

    final songId = song['ytid']?.toString();
    if (songId == null || songId.isEmpty) {
      deduplicatedSongs.add(song);
      continue;
    }

    if (seenSongIds.add(songId)) {
      deduplicatedSongs.add(song);
    }
  }

  return deduplicatedSongs;
}

bool _likedSongIdsAreEqual(List previous, List updated) {
  if (previous.length != updated.length) return false;

  for (var i = 0; i < previous.length; i++) {
    final previousSong = previous[i];
    final updatedSong = updated[i];
    if (previousSong is! Map || updatedSong is! Map) {
      if (previousSong != updatedSong) return false;
      continue;
    }

    if (previousSong['ytid']?.toString() != updatedSong['ytid']?.toString()) {
      return false;
    }
  }

  return true;
}

Future<void> renameSongInLikedSongs(
  dynamic songId,
  String newTitle,
  String newArtist,
) async {
  try {
    final songIndex = userLikedSongsList.value.indexWhere(
      (song) => song['ytid'] == songId,
    );

    if (songIndex != -1) {
      final updatedList = List.from(userLikedSongsList.value);
      updatedList[songIndex] = Map.from(updatedList[songIndex] as Map)
        ..['title'] = newTitle
        ..['artist'] = newArtist;
      userLikedSongsList.value = updatedList;

      unawaited(
        addOrUpdateData<List>('user', 'likedSongs', userLikedSongsList.value),
      );
    }
  } catch (e, stackTrace) {
    logger.log(
      'Error renaming song in liked songs',
      error: e,
      stackTrace: stackTrace,
    );
    rethrow;
  }
}

bool isSongAlreadyLiked(songIdToCheck) {
  final songId = songIdToCheck?.toString();
  return userLikedSongsList.value.any(
    (song) => song['ytid']?.toString() == songId,
  );
}

bool isPlaylistAlreadyLiked(playlistIdToCheck) {
  final playlistId = playlistIdToCheck?.toString();
  if (playlistId == null || playlistId.isEmpty) return false;
  return userLikedPlaylists.value.any(
    (playlist) => playlist['ytid']?.toString() == playlistId,
  );
}

bool isRadioStationLiked(String radioStationId) {
  return userLikedRadioStations.value.contains(radioStationId);
}

Future<void> addRadioStationToLiked(String radioStationId) async {
  if (!userLikedRadioStations.value.contains(radioStationId)) {
    final updatedList = List<String>.from(userLikedRadioStations.value)
      ..add(radioStationId);
    userLikedRadioStations.value = updatedList;
    await addOrUpdateData<List<String>>(
      'user',
      'likedRadioStations',
      updatedList,
    );
  }
}

Future<void> removeRadioStationFromLiked(String radioStationId) async {
  if (userLikedRadioStations.value.contains(radioStationId)) {
    final updatedList = List<String>.from(userLikedRadioStations.value)
      ..remove(radioStationId);
    userLikedRadioStations.value = updatedList;
    unawaited(
      addOrUpdateData<List<String>>('user', 'likedRadioStations', updatedList),
    );
  }
}

bool isSongAlreadyOffline(songIdToCheck) =>
    userOfflineSongs.value.any((song) => song['ytid'] == songIdToCheck);

bool isPlaylistFullyOffline(List songs) {
  if (songs.isEmpty) return false;
  final offlineIds = userOfflineSongs.value.map((s) => s['ytid']).toSet();
  return songs.every((s) => offlineIds.contains(s['ytid']));
}

Map<String, dynamic> getOfflineSongByYtid(String ytid) {
  try {
    final song = userOfflineSongs.value.firstWhere(
      (s) => s['ytid'] == ytid,
      orElse: () => <String, dynamic>{},
    );
    return Map<String, dynamic>.from(song);
  } catch (_) {
    return <String, dynamic>{};
  }
}

Future<List<String>> getSearchSuggestions(String query) async {
  // Custom implementation:

  // const baseUrl = 'https://suggestqueries.google.com/complete/search';
  // final parameters = {
  //   'client': 'firefox',
  //   'ds': 'yt',
  //   'q': query,
  // };

  // final uri = Uri.parse(baseUrl).replace(queryParameters: parameters);

  // try {
  //   final response = await http.get(
  //     uri,
  //     headers: {
  //       'User-Agent':
  //           'Mozilla/5.0 (Windows NT 10.0; rv:96.0) Gecko/20100101 Firefox/96.0',
  //     },
  //   );

  //   if (response.statusCode == 200) {
  //     final suggestions = jsonDecode(response.body)[1] as List<dynamic>;
  //     final suggestionStrings = suggestions.cast<String>().toList();
  //     return suggestionStrings;
  //   }
  // } catch (e, stackTrace) {
  //   logger.log('Error in getSearchSuggestions:$e\n$stackTrace');
  // }

  // Built-in implementation:

  final suggestions = await ytClient.search.getQuerySuggestions(query);

  return suggestions;
}

Future<List<Map<String, int>>> getSkipSegments(String id) async {
  try {
    final res = await ProxyManager().getProxiedResponse(
      Uri(
        scheme: 'https',
        host: 'sponsor.ajay.app',
        path: '/api/skipSegments',
        queryParameters: {
          'videoID': id,
          'category': [
            'sponsor',
            'selfpromo',
            'interaction',
            'intro',
            'outro',
            'music_offtopic',
          ],
          'actionType': 'skip',
        },
      ),
    );
    if (res.statusCode == 200 && res.body != 'Not Found') {
      final data = jsonDecode(res.body);
      final segments = data.map((obj) {
        return Map.castFrom<String, dynamic, String, int>({
          'start': obj['segment'].first.toInt(),
          'end': obj['segment'].last.toInt(),
        });
      }).toList();
      return List.castFrom<dynamic, Map<String, int>>(segments);
    } else {
      return [];
    }
  } catch (e, stackTrace) {
    logger.log('Error in getSkipSegments', error: e, stackTrace: stackTrace);
    return [];
  }
}

Future<void> getSimilarSong(String songYtId) async {
  try {
    final song = await ytClient.videos.get(songYtId);
    final relatedSongs = await ytClient.videos.getRelatedVideos(song) ?? [];

    if (relatedSongs.isNotEmpty) {
      nextRecommendedSong = returnSongLayout(0, relatedSongs[0]);
    } else {
      logger.log('No related songs found for $songYtId');
    }
  } catch (e, stackTrace) {
    logger.log(
      'Error while fetching next similar song:',
      error: e,
      stackTrace: stackTrace,
    );
  }
}

/// Fetches the best available audio stream for a song.
Future<AudioOnlyStreamInfo?> fetchBestAudioStream(String? songId) async {
  try {
    if (songId == null || songId.isEmpty) {
      logger.log('fetchBestAudioStream: songId is null or empty');
      return null;
    }

    final manifest = await _fetchStreamManifest(songId);
    final audioStream = manifest?.audioOnly;
    if (audioStream == null || audioStream.isEmpty) {
      logger.log('fetchBestAudioStream: no audio streams for $songId');
      return null;
    }
    return selectAudioOnlyStreamForQuality(audioStream.sortByBitrate());
  } on TimeoutException catch (_) {
    logger.log('fetchBestAudioStream request timed out for $songId');
    return null;
  } catch (e, stackTrace) {
    logger.log(
      'Error while fetching best audio stream',
      error: e,
      stackTrace: stackTrace,
    );
    return null;
  }
}

/// Resolves a playable stream URL for a song (cached when possible).
Future<String?> fetchSongStreamUrl(String songId, bool isLive) async {
  try {
    if (songId.isEmpty) {
      logger.log('fetchSongStreamUrl: songId is empty');
      return null;
    }
    if (isLive) {
      final streamInfo = await ytClient.videos.streamsClient
          .getHttpLiveStreamUrl(VideoId(songId));
      return streamInfo;
    }

    const _cacheDuration = Duration(hours: 3);
    final cacheKey = 'song_${songId}_${audioQualitySetting.value}_url';

    // Try to get from cache
    final cachedUrl = await _getCachedSongUrl(cacheKey, _cacheDuration);
    if (cachedUrl != null) {
      return cachedUrl;
    }

    // Get fresh URL
    final manifest = await _fetchStreamManifest(songId);
    final audioStreams = manifest?.audioOnly;
    if (audioStreams == null || audioStreams.isEmpty) {
      logger.log('fetchSongStreamUrl: no audio streams for $songId');
      return null;
    }

    final selectedStream = selectAudioOnlyStreamForQuality(
      audioStreams.sortByBitrate(),
    );
    final url = selectedStream.url.toString();

    unawaited(addOrUpdateData<String>('cache', cacheKey, url));

    return url;
  } on TimeoutException catch (_) {
    logger.log('fetchSongStreamUrl request timed out for $songId');
    return null;
  } catch (e, stackTrace) {
    logger.log(
      'Error in fetchSongStreamUrl for $songId:',
      error: e,
      stackTrace: stackTrace,
    );
    return null;
  }
}

Future<Map<String, dynamic>> getSongDetails(
  int songIndex,
  String songId,
) async {
  try {
    final song = await ytClient.videos.get(songId);
    return returnSongLayout(songIndex, song);
  } catch (e, stackTrace) {
    logger.log(
      'Error while getting song details',
      error: e,
      stackTrace: stackTrace,
    );
    rethrow;
  }
}

Future<LyricsResult?> getSongLyrics(
  String? artist,
  String title, {
  String? songId,
}) async {
  if (artist == null) return null;

  final cacheKey = lyricsCacheKeyFor(songId, artist, title);
  if (_lyricsCache.containsKey(cacheKey)) {
    return _lyricsCache[cacheKey];
  }

  final result = await LyricsManager().fetchLyrics(artist, title);
  final cleanedResult = result != null ? cleanLyricsResult(result) : null;
  cacheLyricsResult(cacheKey, cleanedResult);
  return cleanedResult;
}

// Normalizes whitespace in a fetched lyrics result. Also applied to
// results the user manually picks from the lyrics search picker.
LyricsResult cleanLyricsResult(LyricsResult result) {
  // Strips lines like "© music.163.com" that some lyrics sources tack on.
  var plainText = result.plainText
      .split('\n')
      .where((line) => !line.contains('©'))
      .join('\n');
  plainText = plainText.replaceAll(RegExp(r'\n{4}'), '\n\n');
  plainText = plainText.replaceAll(RegExp(r'\n{2}'), '\n');
  plainText = plainText.trim();
  return LyricsResult(
    plainText: plainText,
    source: result.source,
    syncedLines: result.syncedLines,
    label: result.label,
  );
}

/// Downloads [song]'s audio stream and writes it to [audioFile] as a real,
/// taggable MP4/M4A container with title/artist/album/cover embedded
/// directly in the file's tag (cached separately too, for fast display).
///
/// This is the shared core behind both [makeSongOffline] (which also marks
/// the song as available offline in the user's library) and
/// [downloadAndTagAudioFile] (which doesn't) — kept separate so exporting a
/// one-off MP3/M4A copy never has the side effect of adding the song to the
/// offline library.
Future<bool> _downloadAndTagAudioFile(
  Map song,
  String ytid,
  File audioFile, {
  void Function(double progress)? onProgress,
}) async {
  if (DownloadForegroundService.cancelAllRequested) return false;

  final rawFile = File('${audioFile.path}.raw');
  await audioFile.parent.create(recursive: true);

  IOSink? fileStream;
  try {
    final audioManifest = await fetchBestAudioStream(ytid);
    if (audioManifest == null) {
      logger.log('_downloadAndTagAudioFile: audioManifest is null for $ytid');
      return false;
    }

    final stream = ytClient.videos.streamsClient.get(audioManifest);
    fileStream = rawFile.openWrite();
    final totalBytes = audioManifest.size.totalBytes;
    var receivedBytes = 0;
    await for (final chunk in stream) {
      if (DownloadForegroundService.cancelAllRequested) {
        throw Exception('Download cancelled by user');
      }
      fileStream.add(chunk);
      receivedBytes += chunk.length;
      if (totalBytes > 0) onProgress?.call(receivedBytes / totalBytes);
    }
    await fileStream.flush();
    await fileStream.close();
    fileStream = null;
  } catch (e, stackTrace) {
    logger.log(
      'Error downloading audio file',
      error: e,
      stackTrace: stackTrace,
    );
    try {
      await fileStream?.close();
    } catch (_) {}
    if (await rawFile.exists()) {
      await rawFile.delete();
    }
    return false;
  }

  // Always transcode to MP3 with libmp3lame, regardless of the source
  // codec/container (YouTube serves anything from AAC-in-MP4 to
  // Opus-in-WebM): it's the one format that has proven to both embed and
  // read back cover art reliably here, everything else was a gamble on
  // whether a given source codec could even be stream-copied into the
  // destination container.
  try {
    final session = await FFmpegKit.executeWithArguments([
      '-y',
      '-i',
      rawFile.path,
      '-map',
      '0:a',
      '-c:a',
      'libmp3lame',
      '-b:a',
      '192k',
      audioFile.path,
    ]);
    if (!ReturnCode.isSuccess(await session.getReturnCode())) {
      logger.log('_downloadAndTagAudioFile: mp3 transcode failed for $ytid');
      return false;
    }
  } catch (e, stackTrace) {
    logger.log(
      'Error transcoding audio file to mp3',
      error: e,
      stackTrace: stackTrace,
    );
    return false;
  } finally {
    try {
      if (await rawFile.exists()) await rawFile.delete();
    } catch (_) {}
  }

  // Tagging below is best-effort on top of the now-guaranteed-valid mp3
  // and must never leave audioFile missing/corrupted if it fails.
  await _tagAudioFile(song, ytid, audioFile);
  await scanMediaFile(audioFile.path);
  return true;
}

/// Best-effort tagging of an already-downloaded, already-mp3 [audioFile]:
/// writes title/artist/album/cover to a temp copy first and only replaces
/// the original once that succeeds, so a tag-write failure can never
/// corrupt or delete the already-working, playable audio file.
Future<void> _tagAudioFile(Map song, String ytid, File audioFile) async {
  final coverUrl = song['highResImage']?.toString();
  final coverBytes = (coverUrl != null && coverUrl.isNotEmpty)
      ? await _fetchArtworkBytes(coverUrl)
      : null;

  final tag = Tag(
    title: song['title']?.toString(),
    trackArtist: song['artist']?.toString(),
    album: song['album']?.toString(),
    pictures: coverBytes != null
        ? [
            Picture(
              pictureType: PictureType.coverFront,
              mimeType: MimeType.jpeg,
              bytes: coverBytes,
            ),
          ]
        : [],
  );

  // Must keep a real .mp3 extension: audiotags relies on it to pick the
  // right format parser, so an extension-less/mismatched temp name (e.g.
  // ".tagging") makes it fail with "No format could be determined" even
  // though the file's actual content is a perfectly valid MP3.
  final workingCopy = File('${audioFile.path}.tagging.mp3');
  try {
    await audioFile.copy(workingCopy.path);
    await AudioTags.write(workingCopy.path, tag);
    await workingCopy.copy(audioFile.path);
    if (coverBytes != null) {
      final cachedPath = await offlineArtworkCachePath(ytid);
      await File(cachedPath).writeAsBytes(coverBytes, flush: true);
    }
  } catch (e, stackTrace) {
    logger.log(
      'Error embedding cover art into audio file for $ytid',
      error: e,
      stackTrace: stackTrace,
    );
  } finally {
    try {
      if (await workingCopy.exists()) await workingCopy.delete();
    } catch (_) {}
  }
}

/// Downloads and tags [song]'s audio into a private temp file — never the
/// shared offline cache/library — and returns its path, or null on
/// failure. Used by the "export to device" (MP3) feature, which must not
/// leave anything under the public offline folder; only the explicit
/// "make available offline" action ([makeSongOffline]) does that.
Future<String?> downloadAndTagAudioFile(
  dynamic song, {
  void Function(double progress)? onProgress,
}) async {
  final String? ytid = song['ytid'];
  if (ytid == null || ytid.isEmpty) {
    logger.log('downloadAndTagAudioFile: song["ytid"] is null or empty');
    return null;
  }

  if (!await ensureExportStoragePermission()) {
    logger.log('downloadAndTagAudioFile: storage permission denied');
    return null;
  }

  final tempDir = await getTemporaryDirectory();
  final cacheDir = Directory('${tempDir.path}/export_cache');
  if (!await cacheDir.exists()) await cacheDir.create(recursive: true);
  final audioFile = File('${cacheDir.path}/$ytid.mp3');

  final success = await _downloadAndTagAudioFile(
    song as Map,
    ytid,
    audioFile,
    onProgress: onProgress,
  );
  return success ? audioFile.path : null;
}

Future<bool> makeSongOffline(
  dynamic song, {
  void Function(double progress)? onProgress,
  String? folder,
}) async {
  // Covers the *whole* operation, not just the download itself - releasing
  // early (e.g. right after the audio file is written) left the follow-up
  // work (recording the song as offline below) unprotected, so the engine
  // could still be torn down before that ever ran: the file would exist on
  // disk but the app would never learn about it. Awaited so no bytes are
  // downloaded before the protective service is confirmed up.
  await DownloadForegroundService.acquire();
  try {
    final String? ytid = song['ytid'];

    if (ytid == null || ytid.isEmpty) {
      logger.log('makeSongOffline: song["ytid"] is null or empty');
      return false;
    }

    if (!await ensureExportStoragePermission()) {
      logger.log('makeSongOffline: storage permission denied');
      return false;
    }

    if (isSongAlreadyOffline(ytid)) {
      final existingPath =
          getOfflineSongByYtid(ytid)['audioPath'] as String? ??
          FilePaths.getAudioPath(ytid);
      if (await File(existingPath).exists()) {
        return true;
      }
    }

    final offlineSong = Map<String, dynamic>.from(song as Map);

    final audioFile = File(FilePaths.getAudioPath(ytid, folder: folder));

    if (!await _downloadAndTagAudioFile(
      offlineSong,
      ytid,
      audioFile,
      onProgress: onProgress,
    )) {
      return false;
    }

    final cachedArtworkPath = await offlineArtworkCachePath(ytid);
    offlineSong['artworkPath'] = await File(cachedArtworkPath).exists()
        ? cachedArtworkPath
        : null;

    offlineSong['audioPath'] = audioFile.path;
    offlineSong['dateAdded'] = DateTime.now().millisecondsSinceEpoch;

    try {
      final existingIndex = userOfflineSongs.value.indexWhere(
        (s) => s['ytid'] == ytid,
      );

      final updatedOfflineSongs = List.from(userOfflineSongs.value);
      if (existingIndex != -1) {
        updatedOfflineSongs[existingIndex] = offlineSong;
      } else {
        updatedOfflineSongs.add(offlineSong);
      }
      userOfflineSongs.value = updatedOfflineSongs;

      unawaited(
        addOrUpdateData<List>(
          'userNoBackup',
          'offlineSongs',
          userOfflineSongs.value,
        ),
      );
    } catch (e, st) {
      logger.log(
        'Error updating global offline songs list',
        error: e,
        stackTrace: st,
      );
    }

    notifyLocalFilesChanged();
    return true;
  } catch (e, stackTrace) {
    logger.log('Error making song offline', error: e, stackTrace: stackTrace);
    return false;
  } finally {
    DownloadForegroundService.release();
  }
}

Future<bool> removeSongFromOffline(dynamic songId) async {
  try {
    // Look up the actual recorded path first: playlist/album downloads are
    // saved under a subfolder, so recomputing a root-only path here would
    // miss them.
    final audioPath =
        getOfflineSongByYtid(songId.toString())['audioPath'] as String? ??
        FilePaths.getAudioPath(songId);
    final audioFile = File(audioPath);
    // Legacy public artwork file (pre-embedded-cover versions of the app);
    // harmless no-op if it doesn't exist.
    final artworkFile = File(FilePaths.getArtworkPath(songId));
    final cachedArtworkFile = File(await offlineArtworkCachePath(songId));

    try {
      if (await audioFile.exists()) await audioFile.delete(recursive: true);
    } catch (e, stackTrace) {
      logger.log('Error deleting audio file', error: e, stackTrace: stackTrace);
    }

    try {
      if (await artworkFile.exists()) await artworkFile.delete(recursive: true);
    } catch (e, stackTrace) {
      logger.log(
        'Error deleting artwork file',
        error: e,
        stackTrace: stackTrace,
      );
    }

    try {
      if (await cachedArtworkFile.exists()) {
        await cachedArtworkFile.delete(recursive: true);
      }
    } catch (e, stackTrace) {
      logger.log(
        'Error deleting cached artwork file',
        error: e,
        stackTrace: stackTrace,
      );
    }

    try {
      userOfflineSongs.value = List.from(userOfflineSongs.value)
        ..removeWhere((song) => song['ytid'] == songId);
      unawaited(
        addOrUpdateData<List>(
          'userNoBackup',
          'offlineSongs',
          userOfflineSongs.value,
        ),
      );
    } catch (e, st) {
      logger.log(
        'Error updating offline songs registry after removal',
        error: e,
        stackTrace: st,
      );
    }

    return true;
  } catch (e, stackTrace) {
    logger.log(
      'Error removing song from offline storage',
      error: e,
      stackTrace: stackTrace,
    );
    return false;
  }
}

Future<Uint8List?> _fetchArtworkBytes(String url) async {
  try {
    final response = await ProxyManager().getProxiedResponse(Uri.parse(url));

    if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
      return response.bodyBytes;
    }
    logger.log('Failed to download artwork. Status code: ${response.statusCode}');
  } catch (e, stackTrace) {
    logger.log('Error downloading artwork', error: e, stackTrace: stackTrace);
  }

  return null;
}

const recentlyPlayedSongsLimit = 100;

/// Updates the recently played list and listening count for [songId].
///
/// When [songFallback] is provided, its metadata is used to seed the history
/// entry if the song has never been played before. This avoids a network
/// request when registering offline songs whose metadata is already available
/// locally (e.g. from [userOfflineSongs]).
Future<void> updateRecentlyPlayed(dynamic songId, {Map? songFallback}) async {
  try {
    final now = DateTime.now();

    if (userRecentlyPlayed.value.isNotEmpty &&
        userRecentlyPlayed.value[0]['ytid'] == songId) {
      final updatedList = List.from(userRecentlyPlayed.value);
      final existing = Map.from(updatedList[0] as Map);
      existing['listeningCount'] = (existing['listeningCount'] ?? 0) + 1;
      existing['lastPlayed'] = now;
      updatedList[0] = existing;
      userRecentlyPlayed.value = updatedList;
      unawaited(
        addOrUpdateData<List>(
          'user',
          'recentlyPlayedSongs',
          userRecentlyPlayed.value,
        ),
      );
      return;
    }

    final existingIndex = userRecentlyPlayed.value.indexWhere(
      (song) => song['ytid'] == songId,
    );

    final updatedList = List.from(userRecentlyPlayed.value);

    if (existingIndex == -1 && updatedList.length >= recentlyPlayedSongsLimit) {
      updatedList.removeLast();
    }

    if (existingIndex != -1) {
      final song = Map.from(updatedList.removeAt(existingIndex) as Map);
      song['listeningCount'] = (song['listeningCount'] ?? 0) + 1;
      song['lastPlayed'] = now;
      updatedList.insert(0, song);
    } else {
      final dynamic fetchedSongDetails = songFallback != null
          ? Map<String, dynamic>.from(songFallback)
          : await getSongDetails(0, songId);

      if (fetchedSongDetails is! Map) {
        logger.log('Failed to update recently played: invalid song details');
        return;
      }

      final newSongDetails = Map<String, dynamic>.from(fetchedSongDetails);
      newSongDetails['ytid'] ??= songId;
      newSongDetails['listeningCount'] = 1;
      newSongDetails['lastPlayed'] = now;
      updatedList.insert(0, newSongDetails);
    }

    userRecentlyPlayed.value = updatedList;
    unawaited(
      addOrUpdateData<List>(
        'user',
        'recentlyPlayedSongs',
        userRecentlyPlayed.value,
      ),
    );
  } catch (e, stackTrace) {
    logger.log(
      'Error updating recently played',
      error: e,
      stackTrace: stackTrace,
    );
  }
}

Future<void> removeFromRecentlyPlayed(dynamic songId) async {
  if (userRecentlyPlayed.value.any((song) => song['ytid'] == songId)) {
    userRecentlyPlayed.value = List.from(userRecentlyPlayed.value)
      ..removeWhere((song) => song['ytid'] == songId);
    unawaited(
      addOrUpdateData<List>(
        'user',
        'recentlyPlayedSongs',
        userRecentlyPlayed.value,
      ),
    );
  }
}
