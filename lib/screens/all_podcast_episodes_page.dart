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

import 'package:audio_service/audio_service.dart';
import 'package:dskplay/constants/app_constants.dart';
import 'package:dskplay/extensions/l10n.dart';
import 'package:dskplay/main.dart';
import 'package:dskplay/models/podcast_model.dart';
import 'package:dskplay/services/podcast_feed_service.dart';
import 'package:dskplay/services/podcast_manager.dart';
import 'package:dskplay/widgets/mini_player_bottom_space.dart';
import 'package:dskplay/widgets/podcast_episode_bar.dart';
import 'package:dskplay/widgets/podcast_episode_options.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';

/// Cross-podcast "what's new" feed: the latest [_maxEpisodes] episodes across
/// every subscription, newest first, so recent releases can be scanned in
/// one place instead of opening each podcast individually.
class AllPodcastEpisodesPage extends StatefulWidget {
  const AllPodcastEpisodesPage({super.key});

  @override
  State<AllPodcastEpisodesPage> createState() =>
      _AllPodcastEpisodesPageState();
}

class _AllPodcastEpisodesPageState extends State<AllPodcastEpisodesPage> {
  static const _maxEpisodes = 50;

  bool _loading = true;
  List<(PodcastEpisode, Podcast)> _items = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);

    final perPodcast = await Future.wait(
      podcastManager.subscriptions.value.map((
        podcast,
      ) async {
        final result = await fetchPodcastFeed(podcast.feedUrl);
        if (result == null) {
          return <(PodcastEpisode, Podcast)>[];
        }
        return <(PodcastEpisode, Podcast)>[
          for (final episode in result.episodes) (episode, result.podcast),
        ];
      }),
    );

    final merged = perPodcast.expand((episodes) => episodes).toList()
      ..sort(
        (a, b) => (b.$1.pubDate ?? DateTime(0)).compareTo(
          a.$1.pubDate ?? DateTime(0),
        ),
      );

    if (!mounted) return;
    setState(() {
      _items = merged.take(_maxEpisodes).toList();
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Novedades'),
        actions: [
          IconButton(
            tooltip: context.l10n!.refresh,
            onPressed: _loading ? null : _load,
            icon: const Icon(FluentIcons.arrow_sync_24_regular),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _items.isEmpty
          ? Center(child: Text(context.l10n!.noPodcastSubscriptions))
          : StreamBuilder<MediaItem?>(
              stream: audioHandler.mediaItem,
              builder: (context, snapshot) {
                final nowPlayingKey = snapshot.data?.id;
                return StreamBuilder<PlaybackState>(
                  stream: audioHandler.playbackState,
                  builder: (context, playbackSnapshot) {
                    final isPlaying = playbackSnapshot.data?.playing ?? false;
                    return ListView.builder(
                      padding: commonSingleChildScrollViewPadding,
                      itemCount: _items.length,
                      itemBuilder: (context, index) {
                        final (episode, podcast) = _items[index];
                        final episodeIsPlaying =
                            episode.key == nowPlayingKey && isPlaying;
                        return Padding(
                          key: ValueKey(episode.key),
                          padding: const EdgeInsets.only(bottom: 6),
                          child: PodcastEpisodeBar(
                            episode: episode,
                            podcast: podcast,
                            isPlaying: episodeIsPlaying,
                            onTap: () =>
                                showPodcastEpisodeOptions(context, podcast, episode),
                            onPlayPauseTap: () => episode.key == nowPlayingKey
                                ? (isPlaying
                                      ? audioHandler.pause()
                                      : audioHandler.play())
                                : playPodcastEpisode(context, podcast, episode),
                          ),
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
