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

import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:dskplay/constants/app_constants.dart';
import 'package:dskplay/extensions/l10n.dart';
import 'package:dskplay/main.dart' show logger, audioHandler;
import 'package:dskplay/models/podcast_model.dart';
import 'package:dskplay/services/common_services.dart';
import 'package:dskplay/services/data_manager.dart';
import 'package:dskplay/services/podcast_feed_service.dart';
import 'package:dskplay/services/podcast_manager.dart';
import 'package:dskplay/services/settings_manager.dart';
import 'package:dskplay/utilities/app_utils.dart';
import 'package:dskplay/utilities/flutter_toast.dart';
import 'package:dskplay/utilities/playlist_utils.dart';
import 'package:dskplay/utilities/song_filtering.dart';
import 'package:dskplay/widgets/mini_player_bottom_space.dart';
import 'package:dskplay/widgets/playlist_cube.dart';
import 'package:dskplay/widgets/playlist_page/empty_playlist_state.dart';
import 'package:dskplay/widgets/playlist_page/playlist_header.dart';
import 'package:dskplay/widgets/playlist_page/search_bar_section.dart';
import 'package:dskplay/widgets/song_bar.dart';
import 'package:dskplay/widgets/sort_chips.dart';

enum OfflineSortType { default_, title, artist, dateAdded }

class UserSongsPage extends StatefulWidget {
  const UserSongsPage({super.key, required this.page});

  final String page;

  @override
  State<UserSongsPage> createState() => _UserSongsPageState();
}

class _UserSongsPageState extends State<UserSongsPage> {
  final ValueNotifier<String> _searchQueryNotifier = ValueNotifier('');
  late final TextEditingController _searchController;
  late final FocusNode _searchFocusNode;

  List _getDisplayList(List songsList) {
    var list = filterSongsByQuery(songsList, _searchQueryNotifier.value);
    if (widget.page == 'offline') {
      list = _sortOfflineSongsLocal(
        list,
        _getCurrentOfflineSortType(),
        _getCurrentOfflineSortAscending(),
      );
    }
    return list;
  }

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
    _searchFocusNode = FocusNode();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    _searchQueryNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final title = getTitle(widget.page, context);
    final icon = getIcon(widget.page);
    final isOfflineSongs = title == context.l10n!.offlineSongs;

    return Scaffold(
      body: Padding(
        padding: commonSingleChildScrollViewPadding,
        child: ValueListenableBuilder(
          valueListenable: widget.page == 'liked'
              ? userLikedSongsList
              : widget.page == 'offline'
              ? userOfflineSongs
              : userRecentlyPlayed,
          builder: (_, songsList, __) => _buildCustomScrollView(
            title,
            icon,
            songsList.length,
            isOfflineSongs,
          ),
        ),
      ),
    );
  }

  OfflineSortType _getCurrentOfflineSortType() {
    return OfflineSortType.values.firstWhere(
      (e) => e.name == offlineSortSetting,
      orElse: () => OfflineSortType.default_,
    );
  }

  bool _getCurrentOfflineSortAscending() => offlineSortAscending;

  Widget _buildCustomScrollView(
    String title,
    IconData icon,
    int songsLength,
    bool isOfflineSongs,
  ) {
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: _buildHeaderSection(title, icon, songsLength, isOfflineSongs),
        ),
        buildSongList(title),
        const SliverMiniPlayerBottomSpace(),
      ],
    );
  }

  String getTitle(String page, BuildContext context) {
    return switch (page) {
      'liked' => context.l10n!.likedSongs,
      'offline' => context.l10n!.offlineSongs,
      'recents' => context.l10n!.recentlyPlayed,
      _ => context.l10n!.playlist,
    };
  }

  IconData getIcon(String page) {
    return switch (page) {
      'liked' => FluentIcons.heart_24_regular,
      'offline' => FluentIcons.cloud_off_24_regular,
      'recents' => FluentIcons.history_24_regular,
      _ => FluentIcons.heart_24_regular,
    };
  }

  Widget _buildHeaderSection(
    String title,
    IconData icon,
    int songsLength,
    bool isOfflineSongs,
  ) {
    final colorScheme = Theme.of(context).colorScheme;

    return Column(
      children: [
        PlaylistHeader(
          _buildPlaylistImage(title, icon),
          title,
          songsLength: songsLength,
        ),
        if (songsLength > 0) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    icon: const Icon(FluentIcons.play_24_filled),
                    label: Text(context.l10n!.play),
                    onPressed: () {
                      final songsList = widget.page == 'liked'
                          ? userLikedSongsList.value
                          : widget.page == 'offline'
                          ? userOfflineSongs.value
                          : userRecentlyPlayed.value;
                      var sortedList = songsList;
                      if (isOfflineSongs) {
                        sortedList = _sortOfflineSongsLocal(
                          songsList,
                          _getCurrentOfflineSortType(),
                          _getCurrentOfflineSortAscending(),
                        );
                      }
                      final playlist = {
                        'ytid': '',
                        'title': title,
                        'source': 'user-created',
                        'list': sortedList,
                      };
                      audioHandler.playPlaylistSong(
                        playlist: playlist,
                        songIndex: 0,
                      );
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: colorScheme.secondaryContainer,
                      foregroundColor: colorScheme.onSecondaryContainer,
                    ),
                    icon: const Icon(FluentIcons.arrow_shuffle_24_filled),
                    label: Text(context.l10n!.shuffle),
                    onPressed: () async {
                      final songs = widget.page == 'liked'
                          ? userLikedSongsList.value
                          : widget.page == 'offline'
                          ? userOfflineSongs.value
                          : userRecentlyPlayed.value;
                      if (songs.isEmpty) return;
                      final shuffled = List<Map>.from(songs.whereType<Map>())
                        ..shuffle();
                      await audioHandler.addPlaylistToQueue(
                        shuffled,
                        replace: true,
                        startIndex: 0,
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
        if (isOfflineSongs && songsLength > 1) ...[
          const SizedBox(height: 20),
          SortChips<OfflineSortType>(
            currentSortType: _getCurrentOfflineSortType(),
            sortTypes: OfflineSortType.values,
            sortTypeToString: _getSortTypeDisplayText,
            ascending: _getCurrentOfflineSortAscending(),
            onSelected: (type, ascending) {
              setState(() {
                addOrUpdateData<String>(
                  'settings',
                  'offlineSortType',
                  type.name,
                );
                addOrUpdateData<bool>(
                  'settings',
                  'offlineSortAscending',
                  ascending,
                );
                offlineSortSetting = type.name;
                offlineSortAscending = ascending;
              });
            },
          ),
        ],
        if (songsLength > 0) ...[
          const SizedBox(height: 16),
          SearchBarSection(
            controller: _searchController,
            focusNode: _searchFocusNode,
            onSearchChanged: (value) => _searchQueryNotifier.value = value,
            labelText: context.l10n!.search,
          ),
        ],
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _buildPlaylistImage(String title, IconData icon) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    final isLandscape = screenWidth > MediaQuery.sizeOf(context).height;
    return PlaylistCube(
      {'title': title},
      // Half the usual playlist artwork size: these library tabs (recents,
      // liked, offline) show a generic icon, not real artwork, so the
      // normal full-width cube wastes vertical space here.
      size: (isLandscape ? 250 : screenWidth / commonPlaylistArtworkDivision) / 2,
      cubeIcon: icon,
    );
  }

  Widget buildSongList(String title) {
    final isLikedSongs = title == context.l10n!.likedSongs;
    final isRecentlyPlayed = title == context.l10n!.recentlyPlayed;
    final isOfflineSongs = title == context.l10n!.offlineSongs;

    return ValueListenableBuilder<String>(
      valueListenable: _searchQueryNotifier,
      builder: (_, searchQuery, __) {
        final songsList = widget.page == 'liked'
            ? userLikedSongsList.value
            : widget.page == 'offline'
            ? userOfflineSongs.value
            : userRecentlyPlayed.value;
        final listKeyScope = 'user_song_${widget.page}';
        final isSearching = searchQuery.isNotEmpty;
        final displayList = _getDisplayList(songsList);
        var sortedList = songsList;
        if (isOfflineSongs) {
          sortedList = _sortOfflineSongsLocal(
            songsList,
            _getCurrentOfflineSortType(),
            _getCurrentOfflineSortAscending(),
          );
        }
        final playlist = {
          'ytid': '',
          'title': title,
          'source': 'user-created',
          'list': sortedList,
        };

        if (displayList.isEmpty) {
          final emptyIcon = isLikedSongs
              ? FluentIcons.heart_24_regular
              : FluentIcons.text_bullet_list_24_filled;
          return EmptyPlaylistState(
            icon: emptyIcon,
            message: context.l10n!.playlistEmpty,
          );
        }

        return SliverList(
          key: isOfflineSongs && !isSearching
              ? ValueKey((
                  _getCurrentOfflineSortType(),
                  _getCurrentOfflineSortAscending(),
                ))
              : null,
          delegate: SliverChildBuilderDelegate((context, index) {
            final song = displayList[index];
            final borderRadius = getItemBorderRadius(index, displayList.length);
            return RepaintBoundary(
              key: listItemKey(listKeyScope, index, song),
              child: _buildSongBar(
                song,
                index,
                borderRadius,
                playlist,
                isRecentSong: isRecentlyPlayed,
                isOfflineSongsList: isOfflineSongs,
              ),
            );
          }, childCount: displayList.length),
        );
      },
    );
  }

  // A podcast episode's ytid is its internal key, not a real YouTube video
  // id - playPlaylistSong would try to resolve it as one and fail. Replay it
  // the same way the podcast player (and Time Machine) does instead.
  Future<void> _playSong(Map song, Map playlist, int index) async {
    if (song['isPodcastEpisode'] == true) {
      final audioUrl = song['audioUrl']?.toString();
      final guid = song['guid']?.toString();
      final podcastId = song['podcastId']?.toString();
      if (audioUrl == null ||
          audioUrl.isEmpty ||
          guid == null ||
          guid.isEmpty ||
          podcastId == null ||
          podcastId.isEmpty) {
        // Recorded before this data was tracked - nothing to replay it with.
        if (mounted) showToast(context, context.l10n!.error);
        return;
      }

      // The audioUrl was recorded the first time this episode was played and
      // never touched again - some hosts rotate or expire enclosure URLs
      // after a while, which then fails to play here even though the same
      // episode still streams fine anywhere that re-reads the live feed.
      // Refetch it and prefer whatever the feed currently reports, falling
      // back to the recorded URL only if the podcast/episode can't be found
      // there anymore.
      var currentAudioUrl = audioUrl;
      final subscribedPodcast = podcastManager.subscriptions.value.where(
        (p) => p.id == podcastId,
      );
      if (subscribedPodcast.isNotEmpty) {
        final feed = await fetchPodcastFeed(subscribedPodcast.first.feedUrl);
        final matchingEpisodes = feed?.episodes.where((e) => e.guid == guid);
        if (matchingEpisodes != null && matchingEpisodes.isNotEmpty) {
          currentAudioUrl = matchingEpisodes.first.audioUrl;
        }
      }

      await audioHandler.playPodcastEpisode(
        PodcastEpisode(
          guid: guid,
          podcastId: podcastId,
          title: song['title']?.toString() ?? '',
          audioUrl: currentAudioUrl,
          image: song['highResImage']?.toString() ?? '',
        ),
        podcastTitle: song['artist']?.toString() ?? '',
      );
      return;
    }

    final fullIndex = PlaylistUtils.findSongIndexByYtid(playlist, song['ytid']);
    if (fullIndex == -1) {
      logger.log('Warning: Song ${song['ytid']} not found in full song list');
    }
    await audioHandler.playPlaylistSong(
      playlist: playlist,
      songIndex: fullIndex != -1 ? fullIndex : index,
    );
  }

  Widget _buildSongBar(
    Map song,
    int index,
    BorderRadius borderRadius,
    Map playlist, {
    bool isRecentSong = false,
    bool isOfflineSongsList = false,
  }) {
    final isLikedSongs = playlist['title'] == context.l10n!.likedSongs;

    return SongBar(
      key: listItemKey('user_song', index, song),
      song,
      true,
      onPlay: () => _playSong(song, playlist, index),
      borderRadius: borderRadius,
      isRecentSong: isRecentSong,
      isFromLikedSongs: isLikedSongs,
      isFromOfflineSongsList: isOfflineSongsList,
    );
  }

  String _getSortTypeDisplayText(OfflineSortType type) {
    return switch (type) {
      OfflineSortType.default_ => context.l10n!.default_,
      OfflineSortType.title => context.l10n!.name,
      OfflineSortType.artist => context.l10n!.artist,
      OfflineSortType.dateAdded => context.l10n!.dateAdded,
    };
  }

  List _sortOfflineSongsLocal(List list, OfflineSortType type, bool ascending) {
    final sortedList = List<dynamic>.from(list);
    switch (type) {
      case OfflineSortType.default_:
        return sortedList;
      case OfflineSortType.title:
        sortedList.sort((a, b) {
          final titleA = (a['title'] ?? '').toString().toLowerCase();
          final titleB = (b['title'] ?? '').toString().toLowerCase();
          return ascending
              ? titleA.compareTo(titleB)
              : titleB.compareTo(titleA);
        });
        break;
      case OfflineSortType.artist:
        sortedList.sort((a, b) {
          final artistA = (a['artist'] ?? '').toString().toLowerCase();
          final artistB = (b['artist'] ?? '').toString().toLowerCase();
          return ascending
              ? artistA.compareTo(artistB)
              : artistB.compareTo(artistA);
        });
        break;
      case OfflineSortType.dateAdded:
        // Original (established) default is newest-first.
        sortedList.sort((a, b) {
          final dateA = a['dateAdded'] as int? ?? 0;
          final dateB = b['dateAdded'] as int? ?? 0;
          return ascending ? dateB.compareTo(dateA) : dateA.compareTo(dateB);
        });
        break;
    }
    return sortedList;
  }
}
