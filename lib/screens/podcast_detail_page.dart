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
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
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
import 'package:dskplay/widgets/mini_player_bottom_space.dart';
import 'package:dskplay/widgets/playback_icon_button.dart';
import 'package:dskplay/widgets/podcast_episode_bar.dart';

class PodcastDetailPage extends StatefulWidget {
  const PodcastDetailPage({super.key, required this.podcast});

  final Podcast podcast;

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
  }

  List<PodcastEpisode> _sortedEpisodes(bool ascending) {
    final sorted = [..._episodes];
    sorted.sort((a, b) {
      final dateA = a.pubDate ?? DateTime(0);
      final dateB = b.pubDate ?? DateTime(0);
      return ascending ? dateA.compareTo(dateB) : dateB.compareTo(dateA);
    });

    final query = _episodeQuery.trim().toLowerCase();
    if (query.isEmpty) return sorted;
    return sorted.where((e) => e.title.toLowerCase().contains(query)).toList();
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

  Future<void> _playEpisode(PodcastEpisode episode) async {
    final pending = audioHandler.pendingPodcastResume;
    if (pending != null &&
        pending.episode.key == episode.key &&
        pending.position > Duration.zero) {
      await confirmResumePodcast(context);
      return;
    }

    final downloaded = podcastManager.getDownloadedEpisode(episode.key);
    final localPath = downloaded?['audioPath'] as String?;

    final somethingIsPlaying =
        audioHandler.mediaItem.valueOrNull?.extras?['isPodcastEpisode'] ==
            true &&
        audioHandler.audioPlayer.playing;
    if (somethingIsPlaying) {
      final addToQueue = await _confirmAddToQueueOrPlayNow();
      if (addToQueue == null || !mounted) return;
      if (addToQueue) {
        await audioHandler.addPodcastEpisodeToQueue(
          episode,
          podcastTitle: _podcast.title,
          localPath: localPath,
        );
        if (mounted) showToast(context, context.l10n!.addToQueue);
        return;
      }
    }

    final success = await audioHandler.playPodcastEpisode(
      episode,
      podcastTitle: _podcast.title,
      localPath: localPath,
    );
    if (!success && mounted) {
      showToast(context, context.l10n!.playbackFailed);
    }
  }

  // Mirrors confirmResumePodcast's dialog style; kept local since it's only
  // relevant to this page's episode-tap flow.
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

  Future<void> _copyEpisodeInfo(PodcastEpisode episode) async {
    await Clipboard.setData(
      ClipboardData(text: podcastEpisodeCopyText(_podcast.title, episode)),
    );
    if (mounted) {
      showToast(context, context.l10n!.episodeInfoCopied, aboveDialogs: true);
    }
  }

  Future<void> _shareEpisodeInfo(PodcastEpisode episode) async {
    await SharePlus.instance.share(
      ShareParams(
        text: podcastEpisodeCopyText(_podcast.title, episode),
        subject: episode.title,
      ),
    );
  }

  Future<void> _showEpisodeOptions(PodcastEpisode episode) async {
    final action = await showDialog<_EpisodeAction>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(episode.title),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image(
                    image: ArtworkProvider.get(episode.image),
                    width: 120,
                    height: 120,
                    fit: BoxFit.cover,
                  ),
                ),
              ),
              if (episode.description.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(episode.description),
              ],
            ],
          ),
        ),
        actionsAlignment: MainAxisAlignment.spaceBetween,
        actions: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: context.l10n!.copyEpisodeInfo,
                onPressed: () => _copyEpisodeInfo(episode),
                icon: const Icon(FluentIcons.copy_24_regular),
              ),
              IconButton(
                tooltip: context.l10n!.share,
                onPressed: () => _shareEpisodeInfo(episode),
                icon: const Icon(FluentIcons.share_24_regular),
              ),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton.icon(
                onPressed: () =>
                    Navigator.of(dialogContext).pop(_EpisodeAction.download),
                icon: const Icon(FluentIcons.arrow_download_24_regular),
                label: Text(context.l10n!.download),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: () =>
                    Navigator.of(dialogContext).pop(_EpisodeAction.play),
                icon: const Icon(FluentIcons.play_24_filled),
                label: Text(context.l10n!.play),
              ),
            ],
          ),
        ],
      ),
    );

    switch (action) {
      case _EpisodeAction.play:
        await _playEpisode(episode);
      case _EpisodeAction.download:
        unawaited(downloadPodcastEpisode(_podcast, episode));
      case null:
        break;
    }
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
        audioHandler.audioPlayer.playing;
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
                      onPressed: () => podcastManager.setEpisodeSortAscendingFor(
                        _podcast.id,
                        !ascending,
                      ),
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
                PopupMenuButton<bool>(
                  onSelected: (listened) =>
                      _markAllEpisodes(listened: listened),
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: true,
                      child: Text(context.l10n!.markAllAsListened),
                    ),
                    PopupMenuItem(
                      value: false,
                      child: Text(context.l10n!.markAllAsNotListened),
                    ),
                  ],
                ),
              ],
      ),
      body: _loading
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
          : ValueListenableBuilder<Map<String, bool>>(
              valueListenable: podcastManager.episodeSortAscendingByPodcast,
              builder: (context, _, _) {
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
                                      ClipRRect(
                                        borderRadius: BorderRadius.circular(12),
                                        child: Image(
                                          image: ArtworkProvider.get(
                                            _podcast.image,
                                          ),
                                          width: 88,
                                          height: 88,
                                          fit: BoxFit.cover,
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
                                                    fontWeight: FontWeight.w700,
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
                                                  maxLines: _descriptionExpanded
                                                      ? null
                                                      : 3,
                                                  overflow: _descriptionExpanded
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
                                        tooltip:
                                            context.l10n!.nextUnlistenedEpisode,
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
                                            borderRadius: BorderRadius.circular(
                                              12,
                                            ),
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
                                      episode.key == nowPlayingKey && isPlaying,
                                  selectionMode: _selectionMode,
                                  selected: _selectedKeys.contains(episode.key),
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
      bottomNavigationBar: const MiniPlayerBottomSpace(),
    );
  }
}

enum _EpisodeAction { play, download }
