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
import 'package:dskplay/screens/playlist_page.dart';
import 'package:dskplay/services/artist_service.dart';
import 'package:dskplay/services/playlists_manager.dart';
import 'package:dskplay/services/router_service.dart';
import 'package:dskplay/services/settings_manager.dart';
import 'package:dskplay/utilities/app_utils.dart';
import 'package:dskplay/utilities/flutter_toast.dart';
import 'package:dskplay/widgets/artist_shelf.dart';
import 'package:dskplay/widgets/mini_player_bottom_space.dart';
import 'package:dskplay/widgets/playlist_cube.dart';
import 'package:dskplay/widgets/playlist_page/download_button.dart';
import 'package:dskplay/widgets/playlist_page/empty_playlist_state.dart';
import 'package:dskplay/widgets/playlist_page/like_button.dart';
import 'package:dskplay/widgets/playlist_page/playlist_action_buttons.dart';
import 'package:dskplay/widgets/playlist_page/playlist_header.dart';
import 'package:dskplay/widgets/section_header.dart';
import 'package:dskplay/widgets/song_bar.dart';
import 'package:dskplay/widgets/spinner.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// The page an artist opens on: who the artist is, its top songs, its
/// releases and related artists. Offline, this is just the downloaded songs
/// (see [_buildAllSongsPage]), since there is no profile to read.
class ArtistPage extends StatefulWidget {
  const ArtistPage({super.key, required this.artistId, this.artistData});

  final String artistId;
  final Map? artistData;

  @override
  State<ArtistPage> createState() => _ArtistPageState();
}

class _ArtistPageState extends State<ArtistPage> {
  Future<Map<String, dynamic>?>? _artistFuture;

  Map<String, dynamic>? _artist;
  List<Map<String, dynamic>> _topSongs = const [];
  List<String?> _topSongPlayCounts = const [];
  List<Map<String, dynamic>> _albums = const [];
  List<Map<String, dynamic>> _singles = const [];
  List<Map<String, dynamic>> _relatedArtists = const [];

  /// Whether the songs of the artist are being read for the play buttons.
  final _isLoadingCatalog = ValueNotifier<bool>(false);

  @override
  void initState() {
    super.initState();
    // Los adornos de YouTube Music se filtran al pintar, asi que si el ajuste
    // cambia con esta pagina ya abierta hay que repintar: si no, apagarlo
    // pareceria no hacer nada hasta volver a entrar en el artista.
    showArtistExtras.addListener(_onArtistExtrasChanged);
    if (!offlineMode.value) _artistFuture = _loadArtist();
  }

  void _onArtistExtrasChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    showArtistExtras.removeListener(_onArtistExtrasChanged);
    _isLoadingCatalog.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ArtistPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!offlineMode.value &&
        (oldWidget.artistId != widget.artistId ||
            oldWidget.artistData != widget.artistData)) {
      _artistFuture = _loadArtist();
    }
  }

  String get _resolvedArtistId =>
      _artist?['ytid']?.toString() ?? widget.artistId;

  String get _artistTitle =>
      _artist?['title']?.toString() ??
      widget.artistData?['title']?.toString() ??
      '';

  Future<void> _refresh() async {
    final loaded = _artistFuture;
    final refreshed = _loadArtist(forceRefresh: true);
    setState(() {
      _artistFuture = refreshed;
    });

    final refreshedArtist = await refreshed;
    if (!mounted || refreshedArtist != null) return;
    setState(() {
      _artistFuture = loaded;
    });
    showToast(context, context.l10n!.error);
  }

  Future<Map<String, dynamic>?> _loadArtist({bool forceRefresh = false}) async {
    final artistData = widget.artistData;
    try {
      final artist = await getArtistProfile(
        widget.artistId,
        forceRefresh: forceRefresh,
        preferredName: artistData?['title']?.toString(),
        preferredImage: artistData?['image']?.toString(),
        sourceSongId: artistData?['sourceSongId']?.toString(),
        sourceVideoAuthor: artistData?['videoAuthor']?.toString(),
        preferredVerified: artistData?['isVerifiedArtist'] == true,
      );
      if (artist == null) {
        _logNotFound();
        return null;
      }

      _artist = artist;
      // Each entry of the shelf is a song and its play count, side by side.
      final topSongEntries = (artist['topSongs'] as List? ?? const [])
          .whereType<Map>()
          .where((entry) => entry['song'] is Map)
          .toList();
      _topSongs = [
        for (final entry in topSongEntries)
          Map<String, dynamic>.from(entry['song']! as Map),
      ];
      _topSongPlayCounts = [
        for (final entry in topSongEntries) entry['playCount']?.toString(),
      ];
      _relatedArtists = (artist['relatedArtists'] as List? ?? const [])
          .whereType<Map>()
          .map(Map<String, dynamic>.from)
          .toList();
      // Split the discography once per load: the two shelves are rebuilt on
      // every frame and would otherwise filter it again each time.
      final releases = (artist['releases'] as List? ?? const [])
          .whereType<Map>()
          .map(Map<String, dynamic>.from)
          .toList();
      _albums = releases.where((r) => !isSingleOrEpRelease(r)).toList();
      _singles = releases.where(isSingleOrEpRelease).toList();
      return artist;
    } catch (e, stackTrace) {
      logger.log(
        'ArtistPage profile load failed: lookup=${widget.artistId}',
        error: e,
        stackTrace: stackTrace,
      );
      _logNotFound(reason: 'artist load failed');
      return null;
    }
  }

  void _logNotFound({String reason = 'no canonical YouTube Music artist'}) {
    final artistData = widget.artistData;
    logger.log(
      'ArtistPage Not found: lookup=${widget.artistId}; '
      'sourceSongId=${artistData?['sourceSongId']}; '
      'preferredName=${artistData?['title']}; reason=$reason',
    );
  }

  @override
  Widget build(BuildContext context) {
    // Offline: show downloaded songs only; online: fetch full profile.
    if (offlineMode.value) return _buildAllSongsPage();

    return FutureBuilder<Map<String, dynamic>?>(
      future: _artistFuture ??= _loadArtist(),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return Scaffold(
            body: SizedBox(
              height: MediaQuery.sizeOf(context).height - 100,
              child: const Spinner(),
            ),
          );
        }

        final artist = snapshot.data;
        if (artist == null) return _buildNotFoundPage();

        return Scaffold(
          body: SingleChildScrollView(
            padding: commonSingleChildScrollViewPadding,
            child: Column(
              children: [
                _buildHeaderSection(),
                _buildTopSongsSection(),
                if (_albums.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 24),
                    child: ArtistShelf(
                      title: context.l10n!.albums,
                      icon: FluentIcons.cd_16_regular,
                      items: _albums,
                      subtitleOf: _releaseSubtitle,
                      onTap: _openRelease,
                    ),
                  ),
                if (_singles.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 24),
                    child: ArtistShelf(
                      title: context.l10n!.singlesAndEps,
                      icon: FluentIcons.music_note_2_24_regular,
                      items: _singles,
                      subtitleOf: _releaseSubtitle,
                      onTap: _openRelease,
                    ),
                  ),
                if (showArtistExtras.value && _relatedArtists.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 24),
                    child: ArtistShelf(
                      title: context.l10n!.suggestedArtists,
                      icon: FluentIcons.person_24_regular,
                      items: _relatedArtists,
                      cubeIcon: FluentIcons.person_24_filled,
                      circular: true,
                      onTap: _openArtist,
                    ),
                  ),
                const SizedBox(height: 16),
                const MiniPlayerBottomSpace(),
              ],
            ),
          ),
        );
      },
    );
  }

  /// The artist as its full song list: search, sort, download, export, like -
  /// everything the ordinary playlist page already offers.
  Widget _buildAllSongsPage() {
    return PlaylistPage(
      key: ValueKey('artist_${widget.artistId}'),
      playlistId: _resolvedArtistId,
      playlistData: _artist ?? widget.artistData,
      cubeIcon: FluentIcons.person_24_filled,
      isArtist: true,
    );
  }

  /// Shares catalog with the "All songs" page (read once, reused everywhere).
  Future<Map?> _loadCatalog() => getPlaylistInfoForWidget(
    _resolvedArtistId,
    isArtist: true,
    artistName: _artistTitle,
    artistImage: _artist?['image']?.toString(),
    preferredVerified: _artist?['isVerifiedArtist'] == true,
  );

  Future<void> _playArtist({bool shuffle = false}) async {
    _isLoadingCatalog.value = true;
    try {
      final catalog = await _loadCatalog();
      if (!mounted) return;

      final songs = catalog?['list'] as List? ?? const [];
      if (songs.isEmpty) {
        showToast(context, context.l10n!.error);
        return;
      }

      if (shuffle) {
        await audioHandler.addPlaylistToQueue(
          List<Map>.from(songs.whereType<Map>())..shuffle(),
          replace: true,
          startIndex: 0,
        );
      } else {
        await audioHandler.playPlaylistSong(playlist: catalog, songIndex: 0);
      }
    } finally {
      if (mounted) _isLoadingCatalog.value = false;
    }
  }

  Widget _buildNotFoundPage() {
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          // Not finding an artist is an answer, not a failure of the app.
          EmptyPlaylistState(
            icon: FluentIcons.person_24_filled,
            message: context.l10n!.artistNotFound,
          ),
          const SliverMiniPlayerBottomSpace(),
        ],
      ),
    );
  }

  Widget _buildHeaderSection() {
    final screenSize = MediaQuery.sizeOf(context);
    final isLandscape = screenSize.width > screenSize.height;

    return Column(
      children: [
        PlaylistHeader(
          PlaylistCube(
            _artist!,
            size: isLandscape
                ? 250
                : screenSize.width / commonPlaylistArtworkDivision,
            cubeIcon: FluentIcons.person_24_filled,
            showTypeLabel: false,
          ),
          _artistTitle,
          isArtist: true,
          monthlyListeners: showArtistExtras.value
              ? _artist!['monthlyListeners']?.toString()
              : null,
          description: _artist!['description']?.toString(),
        ),
        ValueListenableBuilder<bool>(
          valueListenable: _isLoadingCatalog,
          builder: (_, isLoading, __) => PlaylistActionButtons(
            isLoading: isLoading,
            onPlay: _playArtist,
            onShuffle: () => _playArtist(shuffle: true),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          spacing: 5,
          children: [
            PlaylistLikeButton(
              playlistId: _resolvedArtistId,
              playlistData: () => _artist,
            ),
            PlaylistDownloadButton(
              playlistId: _resolvedArtistId,
              resolvePlaylist: _loadCatalog,
            ),
            IconButton.filledTonal(
              icon: const Icon(FluentIcons.arrow_sync_24_filled),
              iconSize: 24,
              onPressed: _refresh,
              tooltip: context.l10n!.update,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildTopSongsSection() {
    if (!showArtistExtras.value || _topSongs.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      children: [
        const SizedBox(height: 8),
        SectionHeader(
          title: context.l10n!.topSongs,
          icon: FluentIcons.music_note_2_24_filled,
        ),
        ListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: commonListViewBottomPadding,
          itemCount: _topSongs.length,
          itemBuilder: (context, index) => RepaintBoundary(
            key: listItemKey('artist_top_song', index, _topSongs[index]),
            child: SongBar(
              _topSongs[index],
              true,
              rank: index + 1,
              playCountLabel: _topSongPlayCounts[index],
              borderRadius: getItemBorderRadius(index, _topSongs.length),
              onPlay: () => audioHandler.playPlaylistSong(
                playlist: {'title': _artistTitle, 'list': _topSongs},
                songIndex: index,
              ),
            ),
          ),
        ),
      ],
    );
  }

  String _releaseSubtitle(Map<String, dynamic> release) {
    final year = release['year']?.toString();
    final type = switch (release['releaseType']?.toString()) {
      'single' => context.l10n!.single,
      'ep' => 'EP',
      _ => context.l10n!.album,
    };
    return year == null || year.isEmpty ? type : '$type • $year';
  }

  void _openArtist(Map<String, dynamic> artist) {
    final artistId = artist['ytid']?.toString();
    if (artistId == null || artistId.isEmpty) return;

    context.push(
      '${NavigationManager.searchPath}/artist/${Uri.encodeComponent(artistId)}',
      extra: artist,
    );
  }

  void _openRelease(Map<String, dynamic> release) {
    final releaseId = release['ytid']?.toString();
    if (releaseId == null || releaseId.isEmpty) return;

    context.push('${NavigationManager.homePath}/playlist/$releaseId');
  }
}
