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

import 'package:dskplay/constants/app_constants.dart';
import 'package:dskplay/extensions/l10n.dart';
import 'package:dskplay/main.dart';
import 'package:dskplay/screens/bottom_navigation_page.dart';
import 'package:dskplay/services/common_services.dart';
import 'package:dskplay/services/listening_stats_service.dart';
import 'package:dskplay/services/playlists_manager.dart';
import 'package:dskplay/services/settings_manager.dart';
import 'package:dskplay/utilities/app_utils.dart';
import 'package:dskplay/utilities/async_loader.dart';
import 'package:dskplay/utilities/flutter_toast.dart';
import 'package:dskplay/utilities/listening_stats_utils.dart';
import 'package:dskplay/widgets/announcement_box.dart';
import 'package:dskplay/widgets/listening_recap_card.dart';
import 'package:dskplay/widgets/mini_player_bottom_space.dart';
import 'package:dskplay/widgets/playlist_cube.dart';
import 'package:dskplay/widgets/section_header.dart';
import 'package:dskplay/widgets/song_bar.dart';
import 'package:dskplay/widgets/spinner.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  _HomePageState createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late Future<List> _suggestedPlaylistsFuture;
  late Future<List> _recommendedSongsFuture;

  // Tandas de sugerencias ya vistas, para poder volver atras si el usuario
  // refresca sin querer. Se pierden al salir de la pantalla: es un "deshacer",
  // no un historial.
  final List<List<dynamic>> _suggestedPlaylistsHistory = [];
  List<dynamic>? _currentSuggestedPlaylists;

  @override
  void initState() {
    super.initState();
    _suggestedPlaylistsFuture = getPlaylists(
      playlistsNum: recommendedCubesNumber,
    );
    _recommendedSongsFuture = getRecommendedSongs();
    externalRecommendations.addListener(_refreshRecommendedSongs);
    includePodcastsInSuggestions.addListener(_refreshRecommendedSongs);
  }

  @override
  void dispose() {
    externalRecommendations.removeListener(_refreshRecommendedSongs);
    includePodcastsInSuggestions.removeListener(_refreshRecommendedSongs);
    super.dispose();
  }

  void _refreshRecommendedSongs() {
    if (!mounted) return;
    setState(() {
      _recommendedSongsFuture = getRecommendedSongs();
    });
  }

  Future<void> _dismissSuggestion(dynamic song) async {
    final ytid = song['ytid']?.toString();
    if (ytid == null || ytid.isEmpty) return;
    await hideSongFromRecommendations(ytid);
    _refreshRecommendedSongs();
  }

  void _refreshSuggestedPlaylists() {
    if (!mounted) return;
    final shown = _currentSuggestedPlaylists;
    if (shown != null && shown.isNotEmpty) {
      _suggestedPlaylistsHistory.add(shown);
    }
    setState(() {
      _suggestedPlaylistsFuture = getPlaylists(
        playlistsNum: recommendedCubesNumber,
      );
    });
  }

  void _restorePreviousSuggestedPlaylists() {
    if (!mounted) return;
    if (_suggestedPlaylistsHistory.isEmpty) {
      showToast(context, context.l10n!.noPreviousSuggestions);
      return;
    }
    final previous = _suggestedPlaylistsHistory.removeLast();
    setState(() {
      _suggestedPlaylistsFuture = Future.value(previous);
    });
  }

  @override
  Widget build(BuildContext context) {
    final playlistHeight = MediaQuery.sizeOf(context).height * 0.25 / 1.1;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) BottomNavigationPage.handleBackPress(context);
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('DSK Play'),
              Text('by DSK', style: TextStyle(fontSize: 11)),
            ],
          ),
        ),
        body: SingleChildScrollView(
          padding: commonSingleChildScrollViewPadding,
          child: Column(
            children: [
              ValueListenableBuilder<String?>(
                valueListenable: announcementURL,
                builder: (_, _url, __) {
                  if (_url == null) return const SizedBox.shrink();
                  final isSponsorshipAnnouncement =
                      isSponsorshipAnnouncementUrl(_url);
                  final _message = isSponsorshipAnnouncement
                      ? context.l10n!.sponsorProject
                      : context.l10n!.newAnnouncement;
                  final _icon = isSponsorshipAnnouncement
                      ? FluentIcons.heart_24_filled
                      : FluentIcons.megaphone_24_filled;

                  return AnnouncementBox(
                    message: _message,
                    url: _url,
                    icon: _icon,
                    onDismiss: () async {
                      announcementURL.value = null;
                    },
                  );
                },
              ),
              _buildSuggestedPlaylists(playlistHeight),
              _buildSuggestedPlaylists(playlistHeight, showOnlyLiked: true),
              _buildCurrentMonthRecapSection(),
              _buildRecommendedSongsSection(),
              const MiniPlayerBottomSpace(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSuggestedPlaylists(
    double playlistHeight, {
    bool showOnlyLiked = false,
  }) {
    if (showOnlyLiked) {
      return ValueListenableBuilder<List<Map>>(
        valueListenable: userLikedPlaylists,
        builder: (_, likedPlaylists, __) => _buildSuggestedPlaylistsSection(
          playlistHeight,
          likedPlaylists
              .where((playlist) => !isArtistPlaylist(playlist))
              .take(likedCubesNumber)
              .toList(),
          showOnlyLiked: true,
        ),
      );
    }

    return AsyncLoader<List<dynamic>>(
      future: _suggestedPlaylistsFuture,
      // Sin el hueco el indicador queda pegado al "by DSK" de la barra.
      loadingWidget: const Padding(
        padding: EdgeInsets.only(top: 28, bottom: 12),
        child: Spinner(),
      ),
      builder: (context, playlists) =>
          _buildSuggestedPlaylistsSection(playlistHeight, playlists),
    );
  }

  Widget _buildSuggestedPlaylistsSection(
    double playlistHeight,
    List<dynamic> playlists, {
    bool showOnlyLiked = false,
  }) {
    if (playlists.isEmpty) return const SizedBox.shrink();

    final sectionTitle = showOnlyLiked
        ? context.l10n!.backToFavorites
        : context.l10n!.suggestedPlaylists;
    final maxItems = showOnlyLiked ? likedCubesNumber : recommendedCubesNumber;
    final itemsNumber = playlists.length.clamp(0, maxItems);
    if (!showOnlyLiked) _currentSuggestedPlaylists = playlists;
    final isLargeScreen = MediaQuery.of(context).size.width > 480;

    return Column(
      children: [
        SectionHeader(
          title: sectionTitle,
          icon: showOnlyLiked
              ? FluentIcons.heart_24_filled
              : FluentIcons.list_24_filled,
          actionButton: showOnlyLiked
              ? null
              : RawGestureDetector(
                  // 2 s mantenido = volver a la tanda anterior. El
                  // LongPressGestureRecognizer gana la puja del gesto al
                  // cumplirse el tiempo, asi que el toque corto sigue
                  // refrescando con normalidad.
                  gestures: {
                    LongPressGestureRecognizer:
                        GestureRecognizerFactoryWithHandlers<
                          LongPressGestureRecognizer
                        >(
                          () => LongPressGestureRecognizer(
                            duration: const Duration(seconds: 2),
                          ),
                          (instance) => instance.onLongPress =
                              _restorePreviousSuggestedPlaylists,
                        ),
                  },
                  // Sin `tooltip`: el suyo se dispara al medio segundo de
                  // mantener pulsado y le robaba el gesto al recognizer, asi
                  // que solo salia el globo de ayuda y nunca la tanda
                  // anterior.
                  child: IconButton(
                    icon: const Icon(FluentIcons.arrow_clockwise_24_regular),
                    onPressed: _refreshSuggestedPlaylists,
                  ),
                ),
        ),
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: playlistHeight),
          child: isLargeScreen
              ? _buildHorizontalList(playlists, itemsNumber, playlistHeight)
              : _buildCarouselView(playlists, itemsNumber, playlistHeight),
        ),
      ],
    );
  }

  Widget _buildHorizontalList(
    List<dynamic> playlists,
    int itemCount,
    double height,
  ) {
    return ListView.builder(
      scrollDirection: Axis.horizontal,
      itemCount: itemCount,
      itemBuilder: (context, index) {
        final playlist = playlists[index];
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: GestureDetector(
            onTap: () => context.push('/home/playlist/${playlist['ytid']}'),
            child: PlaylistCube(playlist, size: height),
          ),
        );
      },
    );
  }

  Widget _buildCarouselView(
    List<dynamic> playlists,
    int itemCount,
    double height,
  ) {
    return CarouselView.weighted(
      flexWeights: const <int>[3, 2, 1],
      itemSnapping: true,
      onTap: (index) =>
          context.push('/home/playlist/${playlists[index]['ytid']}'),
      children: List.generate(itemCount, (index) {
        return PlaylistCube(playlists[index], size: height * 2);
      }),
    );
  }

  Widget _buildRecommendedSongsSection() {
    return AsyncLoader<List<dynamic>>(
      future: _recommendedSongsFuture,
      builder: (context, data) {
        if (data.isEmpty) return const SizedBox.shrink();
        return _buildRecommendedForYouSection(context, data);
      },
    );
  }

  Widget _buildCurrentMonthRecapSection() {
    return ListenableBuilder(
      listenable: Listenable.merge([
        wrappedEnabled,
        includePodcastsInTimeMachine,
      ]),
      builder: (context, __) {
        if (!wrappedEnabled.value) return const SizedBox.shrink();

        final currentMonthKey = listeningStatsMonthKey(DateTime.now());
        final monthStats = listeningStatsService.monthStats(currentMonthKey);
        final songs = listeningStatsService.monthTopSongs(currentMonthKey);
        final displayMinutes = monthDisplayMinutes(monthStats);
        if (displayMinutes <= 0 && songs.isEmpty) {
          return const SizedBox.shrink();
        }

        final previewSongs = songs.take(wrappedShareSongsLimit).toList();
        final periodLabel = formatMonthPeriodLabel(
          Localizations.localeOf(context),
          currentMonthKey,
        );

        return Column(
          children: [
            SectionHeader(
              title: context.l10n!.timeMachine,
              icon: FluentIcons.data_trending_24_filled,
            ),
            ListeningRecapCard(
              periodLabel: periodLabel,
              minutes: displayMinutes,
              songs: previewSongs,
              onSongTap: (index) => _playRecapSongs(previewSongs, index),
              onRemoveSong: _removeFromTimeMachine,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 10, 8, 0),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.tonalIcon(
                  onPressed: () => context.push('/home/timeMachine'),
                  icon: const Icon(FluentIcons.arrow_right_24_regular),
                  label: Text(context.l10n!.listeningStats),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _playRecapSongs(
    List<Map<String, dynamic>> songs,
    int index,
  ) async {
    if (songs.isEmpty) return;
    await audioHandler.playPlaylistSong(
      playlist: {'title': context.l10n!.timeMachine, 'list': songs},
      songIndex: index,
    );
  }

  Future<void> _removeFromTimeMachine(Map<String, dynamic> song) async {
    final ytid = song['ytid']?.toString();
    if (ytid == null || ytid.isEmpty) return;
    await listeningStatsService.removeSongFromStats(ytid);
    if (mounted) setState(() {});
  }

  Widget _buildRecommendedForYouSection(
    BuildContext context,
    List<dynamic> data,
  ) {
    final recommendedTitle = context.l10n!.recommendedForYou;

    return Column(
      children: [
        SectionHeader(
          title: recommendedTitle,
          icon: FluentIcons.sparkle_24_filled,
          actionButton: IconButton(
            onPressed: () async {
              await audioHandler.playPlaylistSong(
                playlist: {'title': recommendedTitle, 'list': data},
                songIndex: 0,
              );
            },
            icon: Icon(
              FluentIcons.play_circle_24_filled,
              color: Theme.of(context).colorScheme.primary,
              size: 30,
            ),
          ),
        ),
        ListView.builder(
          shrinkWrap: true,
          physics: const BouncingScrollPhysics(),
          itemCount: data.length,
          padding: commonListViewBottomPadding,
          itemBuilder: (context, index) {
            final borderRadius = getItemBorderRadius(index, data.length);
            return RepaintBoundary(
              key: listItemKey('home_recommended', index, data[index]),
              child: SongBar(
                data[index],
                true,
                borderRadius: borderRadius,
                onDismissSuggestion: () => _dismissSuggestion(data[index]),
              ),
            );
          },
        ),
      ],
    );
  }
}
