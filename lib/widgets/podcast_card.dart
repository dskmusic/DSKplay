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

import 'package:dskplay/extensions/l10n.dart';
import 'package:dskplay/models/podcast_model.dart';
import 'package:dskplay/services/podcast_manager.dart';
import 'package:dskplay/utilities/artwork_provider.dart';
import 'package:dskplay/widgets/confirmation_dialog.dart';
import 'package:dskplay/widgets/radio_station_card.dart' show RadioStationCard;
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';

/// Card for a podcast, used both in search results and in the subscriptions
/// grid. Mirrors [RadioStationCard]'s layout, with a subscribe toggle
/// instead of a favorite one.
class PodcastCard extends StatelessWidget {
  const PodcastCard({super.key, required this.podcast, required this.onTap});

  final Podcast podcast;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Card(
      elevation: 0,
      color: colorScheme.surfaceContainer,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      margin: EdgeInsets.zero,
      child: GestureDetector(
        onTap: onTap,
        onLongPress: podcastManager.isSubscribed(podcast.id)
            ? () => podcastManager.togglePinned(podcast.id)
            : null,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Image(
                      image: ArtworkProvider.get(podcast.image),
                      width: 56,
                      height: 56,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) => Container(
                        width: 56,
                        height: 56,
                        color: colorScheme.primaryContainer,
                        child: Icon(
                          FluentIcons.mic_24_regular,
                          color: colorScheme.onPrimaryContainer,
                          size: 26,
                        ),
                      ),
                    ),
                  ),
                  // New-episode dot: reacts to both notifiers since
                  // hasNewEpisode() compares across them.
                  Positioned(
                    top: -5,
                    right: -5,
                    child: ValueListenableBuilder<Map<String, List<String>>>(
                      valueListenable: podcastManager.episodeKeysByPodcast,
                      builder: (context, _, _) =>
                          ValueListenableBuilder<List<String>>(
                            valueListenable:
                                podcastManager.listenedEpisodeKeys,
                            builder: (context, _, _) {
                              if (!podcastManager.isSubscribed(podcast.id) ||
                                  !podcastManager.hasNewEpisode(podcast.id)) {
                                return const SizedBox.shrink();
                              }
                              return Container(
                                width: 18,
                                height: 18,
                                decoration: BoxDecoration(
                                  color: colorScheme.error,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: colorScheme.surfaceContainer,
                                    width: 2.5,
                                  ),
                                ),
                              );
                            },
                          ),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        ValueListenableBuilder<List<String>>(
                          valueListenable: podcastManager.pinnedPodcastIds,
                          builder: (_, pinnedIds, __) {
                            if (!pinnedIds.contains(podcast.id)) {
                              return const SizedBox.shrink();
                            }
                            return Padding(
                              padding: const EdgeInsets.only(right: 4),
                              child: Icon(
                                FluentIcons.pin_24_filled,
                                size: 13,
                                color: colorScheme.primary,
                              ),
                            );
                          },
                        ),
                        Expanded(
                          child: Text(
                            podcast.title,
                            style: textTheme.titleSmall?.copyWith(
                              color: colorScheme.onSurface,
                              fontWeight: FontWeight.w700,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      podcast.author,
                      style: textTheme.labelSmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 5),
              ValueListenableBuilder<List<Podcast>>(
                valueListenable: podcastManager.subscriptions,
                builder: (context, _, _) {
                  final isSubscribed = podcastManager.isSubscribed(
                    podcast.id,
                  );
                  return IconButton.filledTonal(
                    onPressed: () =>
                        _confirmAndToggleSubscription(context, isSubscribed),
                    icon: Icon(
                      isSubscribed
                          ? FluentIcons.checkmark_circle_24_filled
                          : FluentIcons.add_circle_24_regular,
                      size: 18,
                    ),
                    style: IconButton.styleFrom(
                      backgroundColor: isSubscribed
                          ? colorScheme.primaryContainer
                          : colorScheme.surfaceContainerHighest,
                      foregroundColor: isSubscribed
                          ? colorScheme.onPrimaryContainer
                          : colorScheme.onSurfaceVariant,
                      minimumSize: const Size(36, 36),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmAndToggleSubscription(
    BuildContext context,
    bool isSubscribed,
  ) async {
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
      await podcastManager.unsubscribe(podcast.id);
    } else {
      await podcastManager.subscribe(podcast);
    }
  }
}

/// Compact tile for the subscriptions grid view: just the artwork and a
/// trimmed title below it, with the same new-episode and pinned badges as
/// [PodcastCard].
class PodcastGridTile extends StatelessWidget {
  const PodcastGridTile({super.key, required this.podcast, required this.onTap});

  final Podcast podcast;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return GestureDetector(
      onTap: onTap,
      onLongPress: podcastManager.isSubscribed(podcast.id)
          ? () => podcastManager.togglePinned(podcast.id)
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image(
                    image: ArtworkProvider.get(podcast.image),
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) => ColoredBox(
                      color: colorScheme.primaryContainer,
                      child: Icon(
                        FluentIcons.mic_24_regular,
                        color: colorScheme.onPrimaryContainer,
                        size: 26,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: -5,
                  right: -5,
                  child: ValueListenableBuilder<Map<String, List<String>>>(
                    valueListenable: podcastManager.episodeKeysByPodcast,
                    builder: (context, _, _) =>
                        ValueListenableBuilder<List<String>>(
                          valueListenable: podcastManager.listenedEpisodeKeys,
                          builder: (context, _, _) {
                            if (!podcastManager.isSubscribed(podcast.id) ||
                                !podcastManager.hasNewEpisode(podcast.id)) {
                              return const SizedBox.shrink();
                            }
                            return Container(
                              width: 18,
                              height: 18,
                              decoration: BoxDecoration(
                                color: colorScheme.error,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: colorScheme.surface,
                                  width: 2.5,
                                ),
                              ),
                            );
                          },
                        ),
                  ),
                ),
                Positioned(
                  top: -5,
                  left: -5,
                  child: ValueListenableBuilder<List<String>>(
                    valueListenable: podcastManager.pinnedPodcastIds,
                    builder: (_, pinnedIds, __) {
                      if (!pinnedIds.contains(podcast.id)) {
                        return const SizedBox.shrink();
                      }
                      return Container(
                        padding: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          color: colorScheme.primary,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: colorScheme.surface,
                            width: 2,
                          ),
                        ),
                        child: Icon(
                          FluentIcons.pin_24_filled,
                          size: 10,
                          color: colorScheme.onPrimary,
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            podcast.title,
            style: textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w600),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
