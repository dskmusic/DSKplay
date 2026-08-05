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

import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:dskplay/constants/app_constants.dart';
import 'package:dskplay/extensions/l10n.dart';
import 'package:dskplay/models/podcast_model.dart';
import 'package:dskplay/screens/all_podcast_episodes_page.dart';
import 'package:dskplay/screens/podcast_stats_page.dart';
import 'package:dskplay/services/podcast_feed_service.dart';
import 'package:dskplay/services/podcast_manager.dart';
import 'package:dskplay/widgets/mini_player_bottom_space.dart';
import 'package:dskplay/widgets/podcast_card.dart';

const _addPodcastUrlHint = 'https://ejemplo.com/feed.rss';

class PodcastsPage extends StatefulWidget {
  const PodcastsPage({super.key});

  @override
  State<PodcastsPage> createState() => _PodcastsPageState();
}

class _PodcastsPageState extends State<PodcastsPage> {
  bool _refreshing = false;

  Future<void> _refresh() async {
    setState(() => _refreshing = true);
    await podcastManager.refreshAllSubscriptions();
    if (mounted) setState(() => _refreshing = false);
  }

  Future<void> _addPodcastByUrl() async {
    final controller = TextEditingController();
    final feedUrl = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Añadir podcast por URL'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: _addPodcastUrlHint,
            border: OutlineInputBorder(),
          ),
          onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(context.l10n!.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: Text(context.l10n!.add),
          ),
        ],
      ),
    );

    final trimmedUrl = feedUrl?.trim() ?? '';
    if (trimmedUrl.isEmpty || !mounted) return;

    final uri = Uri.tryParse(trimmedUrl);
    if (uri == null ||
        !uri.isAbsolute ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('URL no válida')));
      return;
    }

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    final result = await fetchPodcastFeed(trimmedUrl);
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();

    if (result == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n!.podcastLoadFailed)));
      return;
    }

    await podcastManager.subscribe(result.podcast);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Suscrito a "${result.podcast.title}"')),
    );
  }

  void _openPodcast(Podcast podcast) {
    // A nested go_router route (like playlist/artist detail pages), not a
    // raw root-navigator push: the latter stacked the detail page above the
    // whole shell Scaffold, hiding the mini player behind it instead of
    // keeping it on top like every other in-branch page.
    context.push('/podcasts/detail', extra: podcast);
  }

  void _openDiscover({bool autoFocusSearch = false}) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => Scaffold(
          appBar: AppBar(title: Text(context.l10n!.discover)),
          body: _DiscoverTab(
            onOpenPodcast: _openPodcast,
            autoFocusSearch: autoFocusSearch,
          ),
          bottomNavigationBar: const MiniPlayerBottomSpace(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n!.podcasts),
        actions: [
          IconButton(
            tooltip: context.l10n!.search,
            onPressed: () => _openDiscover(autoFocusSearch: true),
            icon: const Icon(FluentIcons.search_24_regular),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                IconButton(
                  tooltip: 'Novedades de todos los podcasts',
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (context) => const AllPodcastEpisodesPage(),
                    ),
                  ),
                  icon: const Icon(FluentIcons.apps_list_24_regular),
                ),
                ValueListenableBuilder<bool>(
                  valueListenable: podcastManager.subscriptionsGridView,
                  builder: (context, gridView, _) => IconButton(
                    tooltip: gridView ? 'Ver en lista' : 'Ver en cuadrícula',
                    onPressed: () =>
                        podcastManager.setSubscriptionsGridView(!gridView),
                    icon: Icon(
                      gridView
                          ? FluentIcons.list_24_regular
                          : FluentIcons.grid_24_regular,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: context.l10n!.refresh,
                  onPressed: _refreshing ? null : _refresh,
                  icon: _refreshing
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2.5),
                        )
                      : const Icon(FluentIcons.arrow_sync_24_regular),
                ),
                ValueListenableBuilder<bool>(
                  valueListenable: podcastManager.episodeSortAscending,
                  builder: (context, ascending, _) => IconButton(
                    tooltip: context.l10n!.sortByDate,
                    onPressed: () =>
                        podcastManager.setEpisodeSortAscending(!ascending),
                    icon: Icon(
                      ascending
                          ? FluentIcons.arrow_sort_up_24_regular
                          : FluentIcons.arrow_sort_down_24_regular,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Estadísticas',
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (context) => const PodcastStatsPage(),
                    ),
                  ),
                  icon: const Icon(FluentIcons.data_bar_vertical_24_regular),
                ),
                IconButton(
                  tooltip: 'Añadir podcast por URL',
                  onPressed: _addPodcastByUrl,
                  icon: const Icon(FluentIcons.add_24_regular),
                ),
              ],
            ),
          ),
          Expanded(
            child: ValueListenableBuilder<bool>(
              valueListenable: podcastManager.subscriptionsGridView,
              builder: (context, gridView, _) => _SubscriptionsTab(
                onOpenPodcast: _openPodcast,
                gridView: gridView,
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: const MiniPlayerBottomSpace(),
    );
  }
}

class _SubscriptionsTab extends StatelessWidget {
  const _SubscriptionsTab({
    required this.onOpenPodcast,
    required this.gridView,
  });

  final void Function(Podcast podcast) onOpenPodcast;
  final bool gridView;

  List<Podcast> _sorted(
    List<Podcast> podcasts,
    Map<String, String> latestDates,
    bool ascending,
    List<String> pinnedIds,
  ) {
    final withDate = <Podcast>[];
    final withoutDate = <Podcast>[];
    for (final podcast in podcasts) {
      if (pinnedIds.contains(podcast.id)) continue;
      (latestDates.containsKey(podcast.id) ? withDate : withoutDate).add(
        podcast,
      );
    }
    withDate.sort((a, b) {
      final dateA = DateTime.parse(latestDates[a.id]!);
      final dateB = DateTime.parse(latestDates[b.id]!);
      return ascending ? dateA.compareTo(dateB) : dateB.compareTo(dateA);
    });

    // Pinned podcasts always come first, in the order they were pinned -
    // isolated from the date-based sort above entirely.
    final pinned = [
      for (final id in pinnedIds)
        ...podcasts.where((p) => p.id == id),
    ];
    return [...pinned, ...withDate, ...withoutDate];
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<Podcast>>(
      valueListenable: podcastManager.subscriptions,
      builder: (context, subscriptions, _) {
        if (subscriptions.isEmpty) {
          return Center(child: Text(context.l10n!.noPodcastSubscriptions));
        }

        return ValueListenableBuilder<Map<String, String>>(
          valueListenable: podcastManager.latestEpisodeDates,
          builder: (context, latestDates, _) {
            return ValueListenableBuilder<bool>(
              valueListenable: podcastManager.episodeSortAscending,
              builder: (context, ascending, _) {
                return ValueListenableBuilder<List<String>>(
                  valueListenable: podcastManager.pinnedPodcastIds,
                  builder: (context, pinnedIds, _) {
                    final sorted = _sorted(
                      subscriptions,
                      latestDates,
                      ascending,
                      pinnedIds,
                    );
                    return gridView ? _buildGrid(sorted) : _buildList(sorted);
                  },
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildList(List<Podcast> sorted) {
    return ListView.builder(
      padding: commonSingleChildScrollViewPadding,
      itemCount: sorted.length,
      itemBuilder: (context, index) {
        final podcast = sorted[index];
        return Padding(
          key: ValueKey(podcast.id),
          padding: const EdgeInsets.only(bottom: 8),
          child: PodcastCard(
            podcast: podcast,
            onTap: () => onOpenPodcast(podcast),
          ),
        );
      },
    );
  }

  Widget _buildGrid(List<Podcast> sorted) {
    return GridView.builder(
      padding: commonSingleChildScrollViewPadding,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 12,
        mainAxisSpacing: 18,
        childAspectRatio: 0.8,
      ),
      itemCount: sorted.length,
      itemBuilder: (context, index) {
        final podcast = sorted[index];
        return PodcastGridTile(
          key: ValueKey(podcast.id),
          podcast: podcast,
          onTap: () => onOpenPodcast(podcast),
        );
      },
    );
  }
}

class _DiscoverTab extends StatefulWidget {
  const _DiscoverTab({
    required this.onOpenPodcast,
    this.autoFocusSearch = false,
  });

  final void Function(Podcast podcast) onOpenPodcast;
  final bool autoFocusSearch;

  @override
  State<_DiscoverTab> createState() => _DiscoverTabState();
}

class _DiscoverTabState extends State<_DiscoverTab> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  List<Podcast> _results = [];
  bool _loading = false;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    if (widget.autoFocusSearch) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _focusNode.requestFocus(),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();

    if (value.trim().isEmpty) {
      setState(() => _results = []);
      return;
    }

    _debounce = Timer(const Duration(milliseconds: 500), () async {
      setState(() => _loading = true);
      final results = await searchPodcasts(value);
      if (!mounted) return;
      setState(() {
        _results = results;
        _loading = false;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          TextField(
            controller: _controller,
            focusNode: _focusNode,
            decoration: InputDecoration(
              labelText: context.l10n!.searchPodcasts,
              prefixIcon: const Icon(FluentIcons.search_24_regular),
              border: const OutlineInputBorder(),
            ),
            onChanged: _onChanged,
          ),
          const SizedBox(height: 12),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _results.isEmpty
                ? Center(child: Text(context.l10n!.noPodcastsFound))
                : ListView.builder(
                    itemCount: _results.length,
                    itemBuilder: (context, index) {
                      final podcast = _results[index];
                      return Padding(
                        key: ValueKey(podcast.id),
                        padding: const EdgeInsets.only(bottom: 8),
                        child: PodcastCard(
                          podcast: podcast,
                          onTap: () => widget.onOpenPodcast(podcast),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
