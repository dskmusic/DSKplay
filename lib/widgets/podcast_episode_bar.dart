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
import 'package:intl/intl.dart';
import 'package:dskplay/extensions/l10n.dart';
import 'package:dskplay/models/podcast_model.dart';
import 'package:dskplay/services/podcast_download_service.dart';
import 'package:dskplay/services/podcast_manager.dart';
import 'package:dskplay/utilities/artwork_provider.dart';
import 'package:dskplay/utilities/formatter.dart';

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

class _PodcastEpisodeBarState extends State<PodcastEpisodeBar> {
  final ValueNotifier<double?> _downloadProgress = ValueNotifier(null);

  @override
  void dispose() {
    _downloadProgress.dispose();
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n!.downloadFailed)),
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

        return Material(
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
                    ValueListenableBuilder<double?>(
                      valueListenable: _downloadProgress,
                      builder: (context, progress, _) {
                        if (progress != null) {
                          return SizedBox(
                            width: 40,
                            height: 40,
                            child: Padding(
                              padding: const EdgeInsets.all(10),
                              child: CircularProgressIndicator(
                                value: progress > 0 ? progress : null,
                                strokeWidth: 2,
                              ),
                            ),
                          );
                        }
                        return IconButton(
                          onPressed: _handleDownloadTap,
                          icon: Icon(
                            isDownloaded
                                ? FluentIcons.checkmark_circle_24_filled
                                : FluentIcons.arrow_download_24_regular,
                            size: 20,
                            color: isDownloaded
                                ? colorScheme.primary
                                : colorScheme.onSurfaceVariant,
                          ),
                        );
                      },
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
      },
    );
  }
}
