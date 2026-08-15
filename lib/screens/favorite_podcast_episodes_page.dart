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
import 'package:go_router/go_router.dart';
import 'package:dskplay/constants/app_constants.dart';
import 'package:dskplay/extensions/l10n.dart';
import 'package:dskplay/main.dart' show audioHandler;
import 'package:dskplay/models/podcast_model.dart';
import 'package:dskplay/services/common_services.dart';
import 'package:dskplay/services/podcast_manager.dart';
import 'package:dskplay/utilities/app_utils.dart';
import 'package:dskplay/utilities/artwork_provider.dart';
import 'package:dskplay/utilities/flutter_toast.dart';
import 'package:dskplay/utilities/formatter.dart';
import 'package:dskplay/widgets/confirmation_dialog.dart';
import 'package:dskplay/widgets/mini_player_bottom_space.dart';
import 'package:dskplay/widgets/overflow_menu_button.dart';
import 'package:dskplay/widgets/podcast_episode_notes_dialog.dart';
import 'package:dskplay/widgets/podcast_episode_options.dart';
import 'package:dskplay/widgets/popup_menu_item.dart';

/// A filtered view of [userLikedSongsList] showing only the entries with
/// `isPodcastEpisode: true` - reached via the heart icon on the podcasts
/// screen, mirroring the "liked songs" library tab for music.
class FavoritePodcastEpisodesPage extends StatelessWidget {
  const FavoritePodcastEpisodesPage({super.key});

  static PodcastEpisode _episodeFromMap(Map song) {
    return PodcastEpisode(
      guid: song['guid']?.toString() ?? '',
      podcastId: song['podcastId']?.toString() ?? '',
      title: song['title']?.toString() ?? '',
      audioUrl: song['audioUrl']?.toString() ?? '',
      image: song['highResImage']?.toString() ?? '',
      description: song['description']?.toString() ?? '',
      durationSeconds: song['duration'] as int?,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Podcasts favoritos')),
      body: ValueListenableBuilder<List>(
        valueListenable: userLikedSongsList,
        builder: (context, likedSongs, _) {
          final episodes = likedSongs
              .whereType<Map>()
              .where((s) => s['isPodcastEpisode'] == true)
              .toList();

          if (episodes.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      FluentIcons.heart_24_regular,
                      size: 64,
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withAlpha(120),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'No tienes episodios de podcast marcados como favoritos',
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            );
          }

          return ReorderableListView.builder(
            padding: commonSingleChildScrollViewPadding,
            itemCount: episodes.length,
            onReorder: (oldIndex, newIndex) {
              final ytid = episodes[oldIndex]['ytid']?.toString();
              if (ytid == null) return;
              final target = newIndex > oldIndex ? newIndex - 1 : newIndex;
              reorderLikedPodcastEpisode(ytid, target);
            },
            itemBuilder: (context, index) {
              final song = episodes[index];
              final ytid = song['ytid']?.toString() ?? '';
              return Padding(
                key: ValueKey(ytid.isNotEmpty ? ytid : index),
                padding: const EdgeInsets.only(bottom: 8),
                child: _FavoriteEpisodeTile(
                  song: song,
                  borderRadius: getItemBorderRadius(index, episodes.length),
                  reorderHandle: ReorderableDragStartListener(
                    index: index,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Icon(
                        FluentIcons.re_order_24_regular,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
      bottomNavigationBar: const MiniPlayerBottomSpace(),
    );
  }
}

class _FavoriteEpisodeTile extends StatelessWidget {
  const _FavoriteEpisodeTile({
    required this.song,
    required this.borderRadius,
    required this.reorderHandle,
  });

  final Map song;
  final BorderRadius borderRadius;
  final Widget reorderHandle;

  // Reuses the shared playPodcastEpisode flow (pending-resume check, and the
  // "something is already playing - play now or queue?" dialog) so tapping a
  // favorite behaves exactly like tapping the same episode from any other
  // podcast episode list in the app.
  Future<void> _play(BuildContext context) async {
    final podcastId = song['podcastId']?.toString() ?? '';
    final guid = song['guid']?.toString() ?? '';
    final fallbackAudioUrl = song['audioUrl']?.toString() ?? '';
    if (fallbackAudioUrl.isEmpty) {
      showToast(context, context.l10n!.error);
      return;
    }

    final audioUrl = await podcastManager.resolveLatestEpisodeAudioUrl(
      podcastId,
      guid,
      fallbackAudioUrl,
    );
    if (!context.mounted) return;

    final stored = FavoritePodcastEpisodesPage._episodeFromMap(song);
    final episode = PodcastEpisode(
      guid: stored.guid,
      podcastId: stored.podcastId,
      title: stored.title,
      audioUrl: audioUrl,
      image: stored.image,
      description: stored.description,
      durationSeconds: stored.durationSeconds,
    );

    final podcast = _findSubscribedPodcast() ??
        Podcast(
          id: podcastId,
          title: song['artist']?.toString() ?? '',
          author: '',
          image: episode.image,
          feedUrl: '',
        );

    await playPodcastEpisode(context, podcast, episode);
  }

  Future<void> _addToQueue(BuildContext context, {bool playNext = false}) async {
    await audioHandler.addPodcastEpisodeToQueue(
      FavoritePodcastEpisodesPage._episodeFromMap(song),
      podcastTitle: song['artist']?.toString() ?? '',
      playNext: playNext,
    );
    if (context.mounted) {
      showToast(
        context,
        context.l10n!.addToQueue,
        duration: const Duration(seconds: 1),
      );
    }
  }

  Podcast? _findSubscribedPodcast() {
    final podcastId = song['podcastId']?.toString();
    if (podcastId == null || podcastId.isEmpty) return null;
    final matches = podcastManager.subscriptions.value.where(
      (p) => p.id == podcastId,
    );
    return matches.isEmpty ? null : matches.first;
  }

  Future<void> _confirmAndRemove(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => ConfirmationDialog(
        confirmationMessage:
            '¿Quitar "${song['title']}" de podcasts favoritos?',
        submitMessage: 'Quitar',
        isDangerous: true,
        onCancel: () => Navigator.of(dialogContext).pop(false),
        onSubmit: () => Navigator.of(dialogContext).pop(true),
      ),
    );
    if (confirmed != true) return;

    final ytid = song['ytid']?.toString();
    if (ytid == null || ytid.isEmpty) return;
    await updateSongLikeStatus(ytid, false);
    if (context.mounted) {
      showToast(
        context,
        'Quitado de podcasts favoritos',
        duration: const Duration(seconds: 1),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final duration = song['duration'] as int?;
    final subscribedPodcast = _findSubscribedPodcast();

    return Material(
      color: colorScheme.surfaceContainerLow,
      borderRadius: borderRadius,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _play(context),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image(
                  image: ArtworkProvider.get(
                    song['highResImage']?.toString() ?? '',
                  ),
                  width: 52,
                  height: 52,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) => Container(
                    width: 52,
                    height: 52,
                    color: colorScheme.primaryContainer,
                    child: Icon(
                      FluentIcons.headphones_24_regular,
                      color: colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      song['title']?.toString() ?? '',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                        color: colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [
                        if ((song['artist']?.toString() ?? '').isNotEmpty)
                          song['artist'].toString(),
                        if (duration != null) formatDuration(duration),
                      ].join(' • '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              reorderHandle,
              OverflowMenuButton<String>(
                onSelected: (value) async {
                  switch (value) {
                    case 'play':
                      await _play(context);
                    case 'play_next':
                      await _addToQueue(context, playNext: true);
                    case 'add_to_queue':
                      await _addToQueue(context);
                    case 'go_to_podcast':
                      if (subscribedPodcast != null) {
                        context.push('/podcasts/detail', extra: subscribedPodcast);
                      }
                    case 'notes':
                      await showEpisodeNotesDialog(
                        context,
                        episodeKey: song['ytid']?.toString() ?? '',
                        episodeTitle: song['title']?.toString() ?? '',
                      );
                    case 'remove':
                      await _confirmAndRemove(context);
                  }
                },
                itemBuilder: (context) => [
                  buildPopupMenuItem<String>(
                    value: 'play',
                    icon: FluentIcons.play_24_filled,
                    label: context.l10n!.play,
                    colorScheme: colorScheme,
                  ),
                  buildPopupMenuItem<String>(
                    value: 'play_next',
                    icon: FluentIcons.receipt_play_24_regular,
                    label: context.l10n!.playNext,
                    colorScheme: colorScheme,
                  ),
                  buildPopupMenuItem<String>(
                    value: 'add_to_queue',
                    icon: FluentIcons.text_bullet_list_add_24_regular,
                    label: context.l10n!.addToQueue,
                    colorScheme: colorScheme,
                  ),
                  if (subscribedPodcast != null)
                    buildPopupMenuItem<String>(
                      value: 'go_to_podcast',
                      icon: FluentIcons.mic_24_regular,
                      label: 'Ir al podcast',
                      colorScheme: colorScheme,
                    ),
                  buildPopupMenuItem<String>(
                    value: 'notes',
                    icon: FluentIcons.note_24_regular,
                    label: 'Ver/editar notas',
                    colorScheme: colorScheme,
                  ),
                  buildPopupMenuItem<String>(
                    value: 'remove',
                    icon: FluentIcons.heart_off_24_regular,
                    label: 'Quitar de favoritos',
                    colorScheme: colorScheme,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
