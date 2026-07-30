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

import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:dskplay/main.dart' show logger;
import 'package:dskplay/models/podcast_model.dart';
import 'package:dskplay/services/download_foreground_service.dart';
import 'package:dskplay/services/io_service.dart';
import 'package:dskplay/services/podcast_manager.dart';

// Episode audio is already a direct, ready-to-play file (mp3/m4a/ogg served
// by the podcast host) - unlike YouTube songs there's no extraction or
// transcoding step, just a plain HTTP download into the app's Descargas
// folder, in a Podcasts/<podcast name> subfolder.
const _podcastsDownloadFolder = 'Podcasts';

/// Downloads [episode]'s audio file for offline playback. No-op (success)
/// if it's already downloaded.
Future<bool> downloadPodcastEpisode(
  Podcast podcast,
  PodcastEpisode episode, {
  void Function(double progress)? onProgress,
}) async {
  if (podcastManager.isDownloaded(episode.key)) return true;

  final uri = Uri.tryParse(episode.audioUrl);
  if (uri == null) return false;

  await DownloadForegroundService.acquire();
  try {
    final folder =
        '$downloadedMusicDirPath/$_podcastsDownloadFolder/'
        '${sanitizeFileName(podcast.title)}';
    final destination = File(
      '$folder/${sanitizeFileName(episode.title)}'
      '${_episodeFileExtension(episode.audioUrl)}',
    );

    final success = await _downloadToFile(
      uri,
      destination,
      onProgress: onProgress,
    );
    if (!success) return false;

    await scanMediaFile(destination.path);
    await podcastManager.addDownloadedEpisode({
      ...episode.toMap(),
      'key': episode.key,
      'podcastTitle': podcast.title,
      'audioPath': destination.path,
    });
    return true;
  } finally {
    DownloadForegroundService.release();
  }
}

/// Sequentially downloads every episode in [episodes] (used by the episode
/// list's multi-select "download selected" action). Returns how many
/// succeeded vs. failed.
Future<({int completed, int failed})> downloadPodcastEpisodes(
  Podcast podcast,
  List<PodcastEpisode> episodes, {
  void Function(int completed, int total)? onProgress,
}) async {
  var completed = 0;
  var failed = 0;

  // Held for the whole batch on top of each episode's own acquire/release,
  // same reasoning as OfflinePlaylistService.downloadPlaylist: without it
  // the protection count could momentarily hit zero between episodes.
  await DownloadForegroundService.acquire();
  try {
    for (final episode in episodes) {
      if (DownloadForegroundService.cancelAllRequested) break;
      final success = await downloadPodcastEpisode(podcast, episode);
      if (success) {
        completed++;
      } else {
        failed++;
      }
      onProgress?.call(completed + failed, episodes.length);
    }
  } finally {
    DownloadForegroundService.release();
  }
  return (completed: completed, failed: failed);
}

String _episodeFileExtension(String url) {
  final path = Uri.tryParse(url)?.path ?? url;
  final dot = path.lastIndexOf('.');
  if (dot == -1) return '.mp3';
  final ext = path.substring(dot);
  // Guards against a stray '.' inside a path segment being mistaken for an
  // extension (real audio extensions are always short: .mp3, .m4a, .ogg...).
  return ext.length <= 5 ? ext : '.mp3';
}

Future<bool> _downloadToFile(
  Uri uri,
  File destination, {
  void Function(double progress)? onProgress,
}) async {
  final client = http.Client();
  final tempFile = File('${destination.path}.part');
  IOSink? sink;
  try {
    final request = http.Request('GET', uri)
      ..headers['User-Agent'] = 'DSKPlay/1.0';
    final response = await client.send(request).timeout(
      const Duration(seconds: 20),
    );
    if (response.statusCode != 200) return false;

    await destination.parent.create(recursive: true);
    sink = tempFile.openWrite();
    final totalBytes = response.contentLength ?? 0;
    var receivedBytes = 0;
    await for (final chunk in response.stream) {
      if (DownloadForegroundService.cancelAllRequested) {
        throw Exception('Download cancelled by user');
      }
      sink.add(chunk);
      receivedBytes += chunk.length;
      if (totalBytes > 0) onProgress?.call(receivedBytes / totalBytes);
    }
    await sink.flush();
    await sink.close();
    sink = null;

    await tempFile.rename(destination.path);
    return true;
  } catch (e, stackTrace) {
    logger.log(
      'Error downloading podcast episode file: $uri',
      error: e,
      stackTrace: stackTrace,
    );
    try {
      await sink?.close();
    } catch (_) {}
    if (await tempFile.exists()) await tempFile.delete();
    return false;
  } finally {
    client.close();
  }
}
