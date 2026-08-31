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

import 'package:dskplay/extensions/l10n.dart';
import 'package:dskplay/main.dart';
import 'package:dskplay/models/podcast_model.dart';
import 'package:dskplay/services/podcast_download_service.dart';
import 'package:dskplay/services/podcast_manager.dart';
import 'package:dskplay/utilities/artwork_provider.dart';
import 'package:dskplay/utilities/flutter_toast.dart';
import 'package:dskplay/utilities/formatter.dart';
import 'package:dskplay/widgets/playback_icon_button.dart';
import 'package:dskplay/widgets/podcast_html_description.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

enum _EpisodeAction { play, download }

/// Mirrors confirmResumePodcast's dialog style; shared by every place that
/// starts episode playback while something else may already be playing (the
/// podcast detail page's episode list and the cross-podcast "new episodes"
/// list).
Future<bool?> _confirmAddToQueueOrPlayNow(BuildContext context) {
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

/// Plays [episode] (or queues it, if something else is already playing and
/// the user chooses to) - shared so every episode list behaves identically.
Future<void> playPodcastEpisode(
  BuildContext context,
  Podcast podcast,
  PodcastEpisode episode,
) async {
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
      audioHandler.mediaItem.valueOrNull?.extras?['isPodcastEpisode'] == true &&
      audioHandler.isPlaying;
  if (somethingIsPlaying) {
    final addToQueue = await _confirmAddToQueueOrPlayNow(context);
    if (addToQueue == null || !context.mounted) return;
    if (addToQueue) {
      await audioHandler.addPodcastEpisodeToQueue(
        episode,
        podcastTitle: podcast.title,
        localPath: localPath,
      );
      if (context.mounted) showToast(context, context.l10n!.addToQueue);
      return;
    }
  }

  final success = await audioHandler.playPodcastEpisode(
    episode,
    podcastTitle: podcast.title,
    localPath: localPath,
  );
  if (!success && context.mounted) {
    showToast(context, context.l10n!.playbackFailed);
  }
}

Future<void> _copyEpisodeInfo(
  BuildContext context,
  Podcast podcast,
  PodcastEpisode episode,
) async {
  await Clipboard.setData(
    ClipboardData(text: podcastEpisodeCopyText(podcast.title, episode)),
  );
  if (context.mounted) {
    showToast(context, context.l10n!.episodeInfoCopied, aboveDialogs: true);
  }
}

Future<void> _shareEpisodeInfo(Podcast podcast, PodcastEpisode episode) async {
  await SharePlus.instance.share(
    ShareParams(
      text: podcastEpisodeCopyText(podcast.title, episode),
      subject: episode.title,
    ),
  );
}

/// Shows the episode detail/actions dialog (artwork, description, copy,
/// share, download, play) - the "tap an episode" equivalent of a three-dot
/// menu, shared by every episode list in the app so they all offer the same
/// options.
Future<void> showPodcastEpisodeOptions(
  BuildContext context,
  Podcast podcast,
  PodcastEpisode episode,
) async {
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
            if (episode.pubDate != null || episode.durationSeconds != null) ...[
              const SizedBox(height: 12),
              Center(
                child: Text(
                  [
                    if (episode.pubDate != null)
                      DateFormat.yMMMd().format(episode.pubDate!),
                    if (episode.durationSeconds != null)
                      formatDuration(episode.durationSeconds!),
                  ].join(' • '),
                  style: Theme.of(dialogContext).textTheme.bodySmall?.copyWith(
                    color: Theme.of(dialogContext).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
            if (episode.description.isNotEmpty) ...[
              const SizedBox(height: 12),
              PodcastHtmlDescription(
                data: episode.description,
                color: Theme.of(dialogContext).colorScheme.onSurface,
              ),
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
              onPressed: () =>
                  _copyEpisodeInfo(dialogContext, podcast, episode),
              icon: const Icon(FluentIcons.copy_24_regular),
            ),
            IconButton(
              tooltip: context.l10n!.share,
              onPressed: () => _shareEpisodeInfo(podcast, episode),
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
      await playPodcastEpisode(context, podcast, episode);
    case _EpisodeAction.download:
      unawaited(downloadPodcastEpisode(podcast, episode));
    case null:
      break;
  }
}
