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

import 'package:audio_service/audio_service.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:dskplay/services/local_files_service.dart';
import 'package:dskplay/utilities/artwork_provider.dart';
import 'package:dskplay/widgets/no_artwork_cube.dart';
import 'package:dskplay/widgets/spinner.dart';
import 'package:flutter/material.dart';

class SongArtworkWidget extends StatelessWidget {
  const SongArtworkWidget({
    super.key,
    required this.size,
    required this.metadata,
    this.borderRadius = 10.0,
    this.errorWidgetIconSize = 20.0,
  });
  final double size;
  final MediaItem metadata;
  final double borderRadius;
  final double errorWidgetIconSize;

  @override
  Widget build(BuildContext context) {
    if (metadata.artUri?.scheme == 'file') {
      final artworkPath = metadata.extras?['artWorkPath'] as String;
      final audioPath = metadata.extras?['audioPath'] as String?;
      // A cached artworkPath recorded long ago can point at a file that's
      // since been evicted (e.g. cleared cache) - re-extract it from the
      // source audio file on demand rather than showing a blank cover.
      if (!File(artworkPath).existsSync() &&
          audioPath != null &&
          audioPath.isNotEmpty) {
        return SizedBox(
          width: size,
          height: size,
          child: FutureBuilder<String?>(
            future: reextractLocalArtwork(audioPath),
            builder: (context, snapshot) {
              final resolvedPath = snapshot.data;
              if (resolvedPath == null) {
                return NullArtworkWidget(
                  size: size,
                  iconSize: errorWidgetIconSize,
                  borderRadius: borderRadius,
                );
              }
              return ClipRRect(
                borderRadius: BorderRadius.circular(borderRadius),
                child: Image.file(
                  File(resolvedPath),
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) =>
                      NullArtworkWidget(
                        size: size,
                        iconSize: errorWidgetIconSize,
                        borderRadius: borderRadius,
                      ),
                ),
              );
            },
          ),
        );
      }

      return SizedBox(
        width: size,
        height: size,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(borderRadius),
          child: Image.file(
            File(artworkPath),
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) => NullArtworkWidget(
              size: size,
              iconSize: errorWidgetIconSize,
              borderRadius: borderRadius,
            ),
          ),
        ),
      );
    }

    final artwork = metadata.artUri?.toString() ?? '';
    if (artwork.isEmpty) {
      // Must stay pinned to `size` like every other branch here - without
      // it this falls back to NullArtworkWidget's own 220 default, blowing
      // up whatever fixed-size layout (mini player, queue row...) hosts it.
      return NullArtworkWidget(
        size: size,
        iconSize: errorWidgetIconSize,
        borderRadius: borderRadius,
      );
    }

    // Non-http art sources (e.g. podcast RSS feeds without a real image,
    // falling back to the bundled asset logo) can't be loaded by
    // CachedNetworkImage - ArtworkProvider already knows how to resolve
    // http, asset, data: and file sources, so route those through it
    // instead of always assuming a network URL.
    if (!artwork.startsWith('http')) {
      return SizedBox(
        width: size,
        height: size,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(borderRadius),
          child: Image(
            image: ArtworkProvider.get(artwork),
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) =>
                NullArtworkWidget(iconSize: errorWidgetIconSize),
          ),
        ),
      );
    }

    return CachedNetworkImage(
      width: size,
      height: size,
      imageUrl: artwork,
      imageBuilder: (context, imageProvider) => ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: Image(image: imageProvider, fit: BoxFit.cover),
      ),
      placeholder: (context, url) => const Spinner(),
      errorWidget: (context, url, error) =>
          NullArtworkWidget(iconSize: errorWidgetIconSize),
    );
  }
}
