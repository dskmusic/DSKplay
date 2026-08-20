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
import 'package:dskplay/main.dart';
import 'package:dskplay/models/podcast_model.dart';
import 'package:dskplay/services/podcast_download_service.dart';
import 'package:dskplay/services/podcast_manager.dart';
import 'package:dskplay/utilities/artwork_provider.dart';
import 'package:dskplay/utilities/flutter_toast.dart';
import 'package:dskplay/utilities/formatter.dart';
import 'package:dskplay/widgets/custom_bar.dart' show CustomBar;
import 'package:dskplay/widgets/swipe_action_pane.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:intl/intl.dart';

/// A single episode row: artwork, title, publish date/duration, listened
/// state, download and play actions, plus a checkbox when [selectionMode]
/// is active. Mirrors the general row structure used across the app's other
/// bars ([CustomBar]-style icon box + title/description + trailing).
class PodcastEpisodeBar extends StatefulWidget {
  const PodcastEpisodeBar({
    super.key,
    required this.episode,
    required this.podcast,
    required this.onTap,
    this.isPlaying = false,
    this.onPlayPauseTap,
    this.selectionMode = false,
    this.selected = false,
    this.onSelectToggle,
    this.onLongPress,
  });

  final PodcastEpisode episode;
  final Podcast podcast;
  final VoidCallback onTap;
  final bool isPlaying;
  // Tapped by the row's own play/pause button. Falls back to [onTap] (start
  // from scratch) when null; the detail page passes a callback that toggles
  // play/pause instead when this episode is already the one loaded.
  final VoidCallback? onPlayPauseTap;
  final bool selectionMode;
  final bool selected;
  final VoidCallback? onSelectToggle;
  final VoidCallback? onLongPress;

  @override
  State<PodcastEpisodeBar> createState() => _PodcastEpisodeBarState();
}

class _PodcastEpisodeBarState extends State<PodcastEpisodeBar>
    with SingleTickerProviderStateMixin {
  final ValueNotifier<double?> _downloadProgress = ValueNotifier(null);
  late final _slidableController = SlidableController(this);

  @override
  void dispose() {
    _downloadProgress.dispose();
    _slidableController.dispose();
    super.dispose();
  }

  Future<void> _handleDownloadTap() async {
    if (podcastManager.isDownloaded(widget.episode.key)) {
      await podcastManager.removeDownloadedEpisode(widget.episode.key);
      return;
    }
    if (_downloadProgress.value != null) return;

    _downloadProgress.value = 0;
    final success = await downloadPodcastEpisode(
      widget.podcast,
      widget.episode,
      onProgress: (progress) => _downloadProgress.value = progress,
    );
    _downloadProgress.value = null;
    if (!success && mounted) {
      showToast(context, context.l10n!.downloadFailed);
    }
  }

  Future<void> _handlePlayNext() async {
    await audioHandler.addPodcastEpisodeToQueue(
      widget.episode,
      podcastTitle: widget.podcast.title,
      playNext: true,
    );
    if (mounted) {
      showToast(
        context,
        context.l10n!.addToQueue,
        duration: const Duration(seconds: 1),
      );
    }
  }

  Future<void> _handleAddToQueue() async {
    await audioHandler.addPodcastEpisodeToQueue(
      widget.episode,
      podcastTitle: widget.podcast.title,
    );
    if (mounted) {
      showToast(
        context,
        context.l10n!.addToQueue,
        duration: const Duration(seconds: 1),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final episode = widget.episode;

    return ListenableBuilder(
      listenable: Listenable.merge([
        podcastManager.listenedEpisodeKeys,
        podcastManager.downloadedEpisodes,
      ]),
      builder: (context, _) {
        final isListened = podcastManager.isListened(episode.key);
        final isDownloaded = podcastManager.isDownloaded(episode.key);

        final row = Material(
          color: widget.isPlaying
              ? colorScheme.primaryContainer.withValues(alpha: 0.3)
              : colorScheme.surfaceContainerLow,
          child: InkWell(
            onTap: widget.selectionMode
                ? widget.onSelectToggle
                : widget.onTap,
            onLongPress: widget.onLongPress,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                vertical: 8,
                horizontal: 10,
              ),
              child: Row(
                children: [
                  if (widget.selectionMode)
                    Checkbox(
                      value: widget.selected,
                      onChanged: (_) => widget.onSelectToggle?.call(),
                    )
                  else
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image(
                            image: ArtworkProvider.get(episode.image),
                            width: 48,
                            height: 48,
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stackTrace) =>
                                Container(
                                  width: 48,
                                  height: 48,
                                  color: colorScheme.primaryContainer,
                                  child: Icon(
                                    FluentIcons.headphones_24_regular,
                                    color: colorScheme.onPrimaryContainer,
                                  ),
                                ),
                          ),
                        ),
                        // Only feedback for the download swipe action - a
                        // full button would eat back the title space this
                        // whole change is meant to free up.
                        Positioned(
                          right: -4,
                          bottom: -4,
                          child: ValueListenableBuilder<double?>(
                            valueListenable: _downloadProgress,
                            builder: (context, progress, _) {
                              if (progress != null) {
                                return Container(
                                  width: 18,
                                  height: 18,
                                  padding: const EdgeInsets.all(3),
                                  decoration: BoxDecoration(
                                    color: colorScheme.surfaceContainerLow,
                                    shape: BoxShape.circle,
                                  ),
                                  child: CircularProgressIndicator(
                                    value: progress > 0 ? progress : null,
                                    strokeWidth: 2,
                                  ),
                                );
                              }
                              if (!isDownloaded) return const SizedBox.shrink();
                              return Container(
                                width: 18,
                                height: 18,
                                decoration: BoxDecoration(
                                  color: colorScheme.surfaceContainerLow,
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  FluentIcons.checkmark_circle_24_filled,
                                  size: 18,
                                  color: colorScheme.primary,
                                ),
                              );
                            },
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
                        Text(
                          episode.title,
                          style: textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: isListened
                                ? colorScheme.onSurfaceVariant
                                : colorScheme.onSurface,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          [
                            if (episode.pubDate != null)
                              DateFormat.yMMMd().format(episode.pubDate!),
                            if (episode.durationSeconds != null)
                              formatDuration(episode.durationSeconds!),
                          ].join(' • '),
                          style: textTheme.labelSmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (!widget.selectionMode) ...[
                    IconButton(
                      onPressed: () => podcastManager.setListened(
                        episode.key,
                        listened: !isListened,
                      ),
                      icon: Icon(
                        isListened
                            ? FluentIcons.checkmark_circle_24_filled
                            : FluentIcons.checkmark_circle_24_regular,
                        size: 20,
                        color: isListened
                            ? colorScheme.primary
                            : colorScheme.onSurfaceVariant,
                      ),
                    ),
                    IconButton.filled(
                      onPressed: widget.onPlayPauseTap ?? widget.onTap,
                      icon: Icon(
                        widget.isPlaying
                            ? FluentIcons.pause_24_filled
                            : FluentIcons.play_24_filled,
                        size: 16,
                      ),
                      style: IconButton.styleFrom(
                        backgroundColor: colorScheme.primary.withValues(
                          alpha: 0.15,
                        ),
                        foregroundColor: colorScheme.primary,
                        minimumSize: const Size(40, 40),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );

        if (widget.selectionMode) return row;

        return Slidable(
          key: ValueKey(episode.key),
          controller: _slidableController,
          startActionPane: buildSwipeActionPane([
            SlidableAction(
              onPressed: (_) => _handlePlayNext(),
              backgroundColor: colorScheme.primaryContainer,
              foregroundColor: colorScheme.onPrimaryContainer,
              icon: FluentIcons.receipt_play_24_regular,
              label: 'Siguiente',
            ),
            SlidableAction(
              onPressed: (_) => _handleAddToQueue(),
              backgroundColor: colorScheme.primaryContainer,
              foregroundColor: colorScheme.onPrimaryContainer,
              icon: FluentIcons.text_bullet_list_add_24_regular,
              label: 'Cola',
            ),
            SlidableAction(
              onPressed: (_) => _handleDownloadTap(),
              backgroundColor: colorScheme.secondaryContainer,
              foregroundColor: colorScheme.onSecondaryContainer,
              icon: isDownloaded
                  ? FluentIcons.checkmark_circle_24_filled
                  : FluentIcons.arrow_download_24_regular,
              label: isDownloaded ? 'Quitar' : 'Descargar',
            ),
          ]),
          // A full swipe past the reveal width flips the listened state and
          // bounces the pane back to closed, mirroring AntennaPod's one-move
          // swipe-to-toggle instead of requiring a reveal-then-tap.
          endActionPane: ActionPane(
            motion: const DrawerMotion(),
            extentRatio: 0.28,
            dismissible: DismissiblePane(
              dismissThreshold: 0.28,
              confirmDismiss: () async {
                podcastManager.setListened(episode.key, listened: !isListened);
                // Snappier close than the library default, with a small
                // overshoot for a subtle bounce back into place.
                _slidableController.close(
                  duration: const Duration(milliseconds: 150),
                  curve: Curves.easeOutBack,
                );
                return false;
              },
              onDismissed: () {},
            ),
            children: [
              SlidableAction(
                onPressed: (_) => podcastManager.setListened(
                  episode.key,
                  listened: !isListened,
                ),
                backgroundColor: colorScheme.tertiaryContainer,
                foregroundColor: colorScheme.onTertiaryContainer,
                icon: isListened
                    ? FluentIcons.checkmark_circle_24_regular
                    : FluentIcons.checkmark_circle_24_filled,
                label: isListened ? 'Pendiente' : 'Escuchado',
              ),
            ],
          ),
          child: row,
        );
      },
    );
  }
}
