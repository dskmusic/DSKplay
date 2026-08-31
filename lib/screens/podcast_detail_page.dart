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

import 'package:audio_service/audio_service.dart';
import 'package:dskplay/constants/app_constants.dart';
import 'package:dskplay/extensions/l10n.dart';
import 'package:dskplay/main.dart';
import 'package:dskplay/models/podcast_model.dart';
import 'package:dskplay/services/podcast_download_service.dart';
import 'package:dskplay/services/podcast_feed_service.dart';
import 'package:dskplay/services/podcast_manager.dart';
import 'package:dskplay/utilities/artwork_provider.dart';
import 'package:dskplay/utilities/flutter_toast.dart';
import 'package:dskplay/widgets/confirmation_dialog.dart';
import 'package:dskplay/widgets/fullscreen_artwork_viewer.dart';
import 'package:dskplay/widgets/mini_player_bottom_space.dart';
import 'package:dskplay/widgets/podcast_episode_bar.dart';
import 'package:dskplay/widgets/podcast_episode_options.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';

class PodcastDetailPage extends StatefulWidget {
  const PodcastDetailPage({
    super.key,
    required this.podcast,
    this.openEpisodeKey,
  });

  final Podcast podcast;
  // When set, the matching episode's detail dialog opens automatically once
  // the feed finishes loading - used when arriving here from a place that
  // only knows a specific episode (e.g. the stats screen's history list).
  final String? openEpisodeKey;

  @override
  State<PodcastDetailPage> createState() => _PodcastDetailPageState();
}

class _PodcastDetailPageState extends State<PodcastDetailPage> {
  late Podcast _podcast = widget.podcast;
  List<PodcastEpisode> _episodes = [];
  bool _loading = true;
  bool _loadFailed = false;

  final Set<String> _selectedKeys = {};
  bool get _selectionMode => _selectedKeys.isNotEmpty;

  String _episodeQuery = '';
  // null = show all episodes; true = only listened; false = only pending.
  bool? _listenedFilter;
  bool _descriptionExpanded = false;
  final _searchController = TextEditingController();

  // Keyed by episode key so the "jump to next unlistened" button can scroll
  // to a given row regardless of the current sort/filter, without needing a
  // fixed item extent.
  final Map<String, GlobalKey> _episodeItemKeys = {};
  final ScrollController _episodeListController = ScrollController();

  // Measures the header's actual rendered height (podcast info + search bar)
  // so the jump-offset estimate in [_attemptScrollToEpisode] starts from the
  // right baseline instead of ignoring it, which used to make every jump
  // undershoot by the header's height.
  final GlobalKey _episodeListHeaderKey = GlobalKey();

  // Rough per-row height (artwork 48 + vertical padding/margins) used only
  // to force a far-off row's neighbourhood into the sliver's build range -
  // see [_scrollToNextUnlistened]. Mirrors the same fix in queue_list_view.
  static const double _estimatedEpisodeRowExtent = 70;

  @override
  void initState() {
    super.initState();
    _loadFeed();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _episodeListController.dispose();
    super.dispose();
  }

  Future<void> _loadFeed() async {
    setState(() {
      _loading = true;
      _loadFailed = false;
    });

    final result = await fetchPodcastFeed(_podcast.feedUrl);
    if (!mounted) return;

    if (result == null) {
      setState(() {
        _loading = false;
        _loadFailed = true;
      });
      return;
    }

    setState(() {
      _podcast = result.podcast;
      _episodes = result.episodes;
      _loading = false;
    });

    unawaited(
      podcastManager.recordLatestEpisodeDate(
        _podcast.id,
        _episodes.isNotEmpty ? _episodes.first.pubDate : null,
      ),
    );
    unawaited(podcastManager.recordEpisodeKeys(_podcast.id, _episodes));

    if (podcastManager.isSubscribed(_podcast.id)) {
      // Keep the stored subscription metadata (title/image) fresh with what
      // the feed reports now.
      await podcastManager.subscribe(_podcast);
    }

    final openKey = widget.openEpisodeKey;
    if (openKey != null) {
      PodcastEpisode? episode;
      for (final e in _episodes) {
        if (e.key == openKey) {
          episode = e;
          break;
        }
      }
      if (episode != null && mounted) {
        final found = episode;
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => mounted ? _showEpisodeOptions(found) : null,
        );
      }
    }
  }

  List<PodcastEpisode> _sortedEpisodes(bool ascending) {
    final sorted = [..._episodes];
    sorted.sort((a, b) {
      final dateA = a.pubDate ?? DateTime(0);
      final dateB = b.pubDate ?? DateTime(0);
      return ascending ? dateA.compareTo(dateB) : dateB.compareTo(dateA);
    });

    var filtered = sorted;
    if (_listenedFilter != null) {
      filtered = filtered
          .where((e) => podcastManager.isListened(e.key) == _listenedFilter)
          .toList();
    }

    final query = _episodeQuery.trim().toLowerCase();
    if (query.isEmpty) return filtered;
    return filtered
        .where((e) => e.title.toLowerCase().contains(query))
        .toList();
  }

  // Shared row layout (icon + label + optional trailing check) so every
  // item in the episode overflow menu looks the same, whether it's a
  // one-shot action or one of the mutually-exclusive filter options.
  PopupMenuItem<String> _episodeMenuItem({
    required String value,
    required IconData icon,
    required String label,
    bool selected = false,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return PopupMenuItem(
      value: value,
      child: Row(
        children: [
          Icon(icon, size: 20),
          const SizedBox(width: 12),
          Expanded(child: Text(label)),
          if (selected)
            Icon(
              FluentIcons.checkmark_24_filled,
              size: 18,
              color: colorScheme.primary,
            ),
        ],
      ),
    );
  }

  void _toggleSelection(String key) {
    setState(() {
      if (!_selectedKeys.remove(key)) _selectedKeys.add(key);
    });
  }

  void _scrollToNextUnlistened(List<PodcastEpisode> episodes) {
    final targetIndex = episodes.indexWhere(
      (episode) => !podcastManager.isListened(episode.key),
    );

    if (targetIndex == -1) {
      showToast(context, context.l10n!.allEpisodesListened);
      return;
    }

    _attemptScrollToEpisode(episodes[targetIndex].key, targetIndex);
  }

  // The row for a target far down the list may not be built yet (the
  // sliver only realizes rows within/near the current viewport), so
  // Scrollable.ensureVisible on its still-null context would silently do
  // nothing - jump to an estimated offset first to force that neighbourhood
  // to build, then retry ensureVisible once a real, laid-out context
  // exists. Mirrors the same fix in queue_list_view.dart, but re-jumps on
  // every attempt (rather than once) and nudges further each time: a single
  // fixed-per-row guess ignoring the header's height used to undershoot long
  // lists, stopping short of the actual target.
  void _attemptScrollToEpisode(
    String episodeKey,
    int targetIndex, [
    int attempt = 0,
  ]) {
    if (!mounted || !_episodeListController.hasClients) return;

    final targetContext = _episodeItemKeys[episodeKey]?.currentContext;
    if (targetContext != null) {
      Scrollable.ensureVisible(
        targetContext,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOut,
        alignment: 0.1,
      );
      return;
    }

    if (attempt >= 6) return;

    final headerHeight =
        (_episodeListHeaderKey.currentContext?.findRenderObject() as RenderBox?)
            ?.size
            .height ??
        120;
    final estimatedOffset =
        headerHeight + targetIndex * _estimatedEpisodeRowExtent + attempt * 300;
    _episodeListController.jumpTo(
      estimatedOffset.clamp(
        0.0,
        _episodeListController.position.maxScrollExtent,
      ),
    );
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _attemptScrollToEpisode(episodeKey, targetIndex, attempt + 1),
    );
  }

  Future<void> _playEpisode(PodcastEpisode episode) =>
      playPodcastEpisode(context, _podcast, episode);

  Future<void> _showEpisodeOptions(PodcastEpisode episode) =>
      showPodcastEpisodeOptions(context, _podcast, episode);

  // Mirrors the dialog in podcast_episode_options.dart; kept local since
  // that one only handles a single episode, while this covers the bulk
  // "play selected" action.
  Future<bool?> _confirmAddToQueueOrPlayNow() {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Ya se está reproduciendo un episodio'),
        content: const Text('¿Qué quieres hacer con este episodio?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Reproducir ahora'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(context.l10n!.addToQueue),
          ),
        ],
      ),
    );
  }

  Future<void> _markSelected({required bool listened}) async {
    await podcastManager.setAllListened(
      _selectedKeys.toList(),
      listened: listened,
    );
    setState(_selectedKeys.clear);
  }

  Future<void> _downloadSelected() async {
    final episodes = _episodes
        .where((e) => _selectedKeys.contains(e.key))
        .toList();
    setState(_selectedKeys.clear);
    await downloadPodcastEpisodes(_podcast, episodes);
  }

  Future<void> _playSelected() async {
    final episodes = _episodes
        .where((e) => _selectedKeys.contains(e.key))
        .toList();
    setState(_selectedKeys.clear);
    if (episodes.isEmpty) return;

    final localPathsByEpisodeKey = <String, String>{
      for (final episode in episodes)
        if (podcastManager.getDownloadedEpisode(episode.key)?['audioPath']
            case final String path)
          episode.key: path,
    };

    final somethingIsPlaying =
        audioHandler.mediaItem.valueOrNull?.extras?['isPodcastEpisode'] ==
            true &&
        audioHandler.isPlaying;
    if (somethingIsPlaying) {
      final addToQueue = await _confirmAddToQueueOrPlayNow();
      if (addToQueue == null || !mounted) return;
      if (addToQueue) {
        await audioHandler.addPodcastEpisodesToQueue(
          episodes,
          podcastTitle: _podcast.title,
          localPathsByEpisodeKey: localPathsByEpisodeKey,
        );
        if (mounted) showToast(context, context.l10n!.addToQueue);
        return;
      }
    }

    final success = await audioHandler.playPodcastEpisodesQueue(
      episodes,
      podcastTitle: _podcast.title,
      localPathsByEpisodeKey: localPathsByEpisodeKey,
    );
    if (!success && mounted) {
      showToast(context, context.l10n!.playbackFailed);
    }
  }

  Future<void> _markAllEpisodes({required bool listened}) async {
    await podcastManager.setAllListened(
      _episodes.map((e) => e.key).toList(),
      listened: listened,
    );
  }

  Future<void> _confirmAndToggleSubscription(bool isSubscribed) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => ConfirmationDialog(
        confirmationMessage: isSubscribed
            ? dialogContext.l10n!.confirmUnsubscribeQuestion
            : dialogContext.l10n!.confirmSubscribeQuestion,
        submitMessage: isSubscribed
            ? dialogContext.l10n!.unsubscribe
            : dialogContext.l10n!.subscribe,
        onCancel: () => Navigator.of(dialogContext).pop(false),
        onSubmit: () => Navigator.of(dialogContext).pop(true),
      ),
    );
    if (confirmed != true) return;

    if (isSubscribed) {
      await podcastManager.unsubscribe(_podcast.id);
    } else {
      await podcastManager.subscribe(_podcast);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: _selectionMode
            ? Text('${_selectedKeys.length}')
            : Text(
                _podcast.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
        leading: _selectionMode
            ? IconButton(
                icon: const Icon(FluentIcons.dismiss_24_regular),
                onPressed: () => setState(_selectedKeys.clear),
              )
            : null,
        actions: _selectionMode
            ? [
                IconButton(
                  tooltip: context.l10n!.markAsListened,
                  icon: const Icon(FluentIcons.checkmark_circle_24_regular),
                  onPressed: () => _markSelected(listened: true),
                ),
                IconButton(
                  tooltip: context.l10n!.markAsNotListened,
                  icon: const Icon(FluentIcons.circle_24_regular),
                  onPressed: () => _markSelected(listened: false),
                ),
                IconButton(
                  tooltip: context.l10n!.downloadSelected,
                  icon: const Icon(FluentIcons.arrow_download_24_regular),
                  onPressed: _downloadSelected,
                ),
                IconButton(
                  tooltip: context.l10n!.play,
                  icon: const Icon(FluentIcons.play_24_regular),
                  onPressed: _playSelected,
                ),
              ]
            : [
                ValueListenableBuilder<Map<String, bool>>(
                  valueListenable: podcastManager.episodeSortAscendingByPodcast,
                  builder: (context, _, _) {
                    final ascending = podcastManager.episodeSortAscendingFor(
                      _podcast.id,
                    );
                    return IconButton(
                      tooltip: context.l10n!.sortByDate,
                      onPressed: () => podcastManager
                          .setEpisodeSortAscendingFor(_podcast.id, !ascending),
                      icon: Icon(
                        ascending
                            ? FluentIcons.arrow_sort_up_24_regular
                            : FluentIcons.arrow_sort_down_24_regular,
                      ),
                    );
                  },
                ),
                ValueListenableBuilder<List<Podcast>>(
                  valueListenable: podcastManager.subscriptions,
                  builder: (context, _, _) {
                    final isSubscribed = podcastManager.isSubscribed(
                      _podcast.id,
                    );
                    return IconButton(
                      tooltip: isSubscribed
                          ? context.l10n!.unsubscribe
                          : context.l10n!.subscribe,
                      icon: Icon(
                        isSubscribed
                            ? FluentIcons.checkmark_circle_24_filled
                            : FluentIcons.add_circle_24_regular,
                      ),
                      onPressed: () =>
                          _confirmAndToggleSubscription(isSubscribed),
                    );
                  },
                ),
                PopupMenuButton<String>(
                  onSelected: (value) {
                    switch (value) {
                      case 'mark_all_listened':
                        _markAllEpisodes(listened: true);
                        break;
                      case 'mark_all_not_listened':
                        _markAllEpisodes(listened: false);
                        break;
                      case 'filter_all':
                        setState(() => _listenedFilter = null);
                        break;
                      case 'filter_listened':
                        setState(() => _listenedFilter = true);
                        break;
                      case 'filter_pending':
                        setState(() => _listenedFilter = false);
                        break;
                    }
                  },
                  itemBuilder: (context) => [
                    _episodeMenuItem(
                      value: 'mark_all_listened',
                      icon: FluentIcons.checkmark_circle_24_regular,
                      label: context.l10n!.markAllAsListened,
                    ),
                    _episodeMenuItem(
                      value: 'mark_all_not_listened',
                      icon: FluentIcons.circle_24_regular,
                      label: context.l10n!.markAllAsNotListened,
                    ),
                    const PopupMenuDivider(),
                    _episodeMenuItem(
                      value: 'filter_all',
                      icon: FluentIcons.apps_list_24_regular,
                      label: 'Ver todos',
                      selected: _listenedFilter == null,
                    ),
                    _episodeMenuItem(
                      value: 'filter_listened',
                      icon: FluentIcons.checkmark_circle_24_filled,
                      label: 'Ver solo reproducidos',
                      selected: _listenedFilter == true,
                    ),
                    _episodeMenuItem(
                      value: 'filter_pending',
                      icon: FluentIcons.circle_24_filled,
                      label: 'Ver solo pendientes',
                      selected: _listenedFilter == false,
                    ),
                  ],
                ),
              ],
      ),
      body: PopScope(
        // El boton del dispositivo tambien deshace la seleccion, no
        // solo la X de la barra.
        canPop: !_selectionMode,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) setState(_selectedKeys.clear);
        },
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _loadFailed
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(context.l10n!.podcastLoadFailed),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: _loadFeed,
                      child: Text(context.l10n!.retry),
                    ),
                  ],
                ),
              )
            : ListenableBuilder(
                listenable: Listenable.merge([
                  podcastManager.episodeSortAscendingByPodcast,
                  podcastManager.listenedEpisodeKeys,
                ]),
                builder: (context, _) {
                  final episodes = _sortedEpisodes(
                    podcastManager.episodeSortAscendingFor(_podcast.id),
                  );
                  return StreamBuilder<MediaItem?>(
                    stream: audioHandler.mediaItem,
                    builder: (context, snapshot) {
                      final nowPlayingKey = snapshot.data?.id;
                      return StreamBuilder<PlaybackState>(
                        stream: audioHandler.playbackState,
                        builder: (context, playbackSnapshot) {
                          final isPlaying =
                              playbackSnapshot.data?.playing ?? false;
                          return ListView(
                            controller: _episodeListController,
                            padding: commonSingleChildScrollViewPadding,
                            children: [
                              Column(
                                key: _episodeListHeaderKey,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 12,
                                    ),
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        GestureDetector(
                                          onTap: () =>
                                              FullscreenArtworkViewer.show(
                                                context,
                                                artwork: _podcast.image,
                                                fileName: _podcast.title,
                                              ),
                                          child: ClipRRect(
                                            borderRadius: BorderRadius.circular(
                                              12,
                                            ),
                                            child: Image(
                                              image: ArtworkProvider.get(
                                                _podcast.image,
                                              ),
                                              width: 88,
                                              height: 88,
                                              fit: BoxFit.cover,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                _podcast.title,
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .titleMedium
                                                    ?.copyWith(
                                                      fontWeight:
                                                          FontWeight.w700,
                                                    ),
                                              ),
                                              const SizedBox(height: 2),
                                              Text(
                                                _podcast.author,
                                                style: TextStyle(
                                                  color: colorScheme
                                                      .onSurfaceVariant,
                                                ),
                                              ),
                                              const SizedBox(height: 2),
                                              Text(
                                                '${_episodes.length} ${context.l10n!.episodes}',
                                                style: TextStyle(
                                                  color: colorScheme
                                                      .onSurfaceVariant,
                                                  fontSize: 12,
                                                ),
                                              ),
                                              if (_podcast
                                                  .description
                                                  .isNotEmpty) ...[
                                                const SizedBox(height: 4),
                                                GestureDetector(
                                                  onTap: () => setState(
                                                    () => _descriptionExpanded =
                                                        !_descriptionExpanded,
                                                  ),
                                                  child: Text(
                                                    _podcast.description,
                                                    maxLines:
                                                        _descriptionExpanded
                                                        ? null
                                                        : 3,
                                                    overflow:
                                                        _descriptionExpanded
                                                        ? null
                                                        : TextOverflow.ellipsis,
                                                    style: Theme.of(
                                                      context,
                                                    ).textTheme.bodySmall,
                                                  ),
                                                ),
                                              ],
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 12),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: TextField(
                                            controller: _searchController,
                                            decoration: InputDecoration(
                                              hintText:
                                                  context.l10n!.searchEpisodes,
                                              prefixIcon: const Icon(
                                                FluentIcons.search_24_regular,
                                              ),
                                              isDense: true,
                                              border: OutlineInputBorder(
                                                borderRadius:
                                                    BorderRadius.circular(12),
                                              ),
                                            ),
                                            onChanged: (value) => setState(
                                              () => _episodeQuery = value,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        IconButton(
                                          tooltip: context
                                              .l10n!
                                              .nextUnlistenedEpisode,
                                          onPressed: () =>
                                              _scrollToNextUnlistened(episodes),
                                          icon: const Icon(
                                            FluentIcons
                                                .arrow_circle_down_24_regular,
                                          ),
                                          style: IconButton.styleFrom(
                                            backgroundColor: colorScheme
                                                .surfaceContainerHighest,
                                            shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              for (final episode in episodes)
                                Padding(
                                  key: _episodeItemKeys.putIfAbsent(
                                    episode.key,
                                    GlobalKey.new,
                                  ),
                                  padding: const EdgeInsets.only(bottom: 6),
                                  child: PodcastEpisodeBar(
                                    episode: episode,
                                    podcast: _podcast,
                                    isPlaying:
                                        episode.key == nowPlayingKey &&
                                        isPlaying,
                                    selectionMode: _selectionMode,
                                    selected: _selectedKeys.contains(
                                      episode.key,
                                    ),
                                    onSelectToggle: () =>
                                        _toggleSelection(episode.key),
                                    onLongPress: () =>
                                        _toggleSelection(episode.key),
                                    onTap: () => _selectionMode
                                        ? _toggleSelection(episode.key)
                                        : _showEpisodeOptions(episode),
                                    onPlayPauseTap: _selectionMode
                                        ? null
                                        : () => episode.key == nowPlayingKey
                                              ? (isPlaying
                                                    ? audioHandler.pause()
                                                    : audioHandler.play())
                                              : _playEpisode(episode),
                                  ),
                                ),
                            ],
                          );
                        },
                      );
                    },
                  );
                },
              ),
      ),
      bottomNavigationBar: const MiniPlayerBottomSpace(),
    );
  }
}
