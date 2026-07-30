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
import 'package:flutter/material.dart';
import 'package:dskplay/utilities/artwork_provider.dart';
import 'package:dskplay/widgets/no_artwork_cube.dart';
import 'package:dskplay/widgets/spinner.dart';

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
      return SizedBox(
        width: size,
        height: size,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(borderRadius),
          child: Image.file(
            File(metadata.extras?['artWorkPath']),
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) =>
                NullArtworkWidget(iconSize: errorWidgetIconSize),
          ),
        ),
      );
    }

    final artwork = metadata.artUri?.toString() ?? '';
    if (artwork.isEmpty) {
      return NullArtworkWidget(iconSize: errorWidgetIconSize);
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
