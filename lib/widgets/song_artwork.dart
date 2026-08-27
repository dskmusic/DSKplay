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
import 'package:dskplay/utilities/formatter.dart';
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
    // Cadena de reservas: si la portada principal falla (un fichero que ya no
    // esta, una miniatura caducada...), se prueba la siguiente en vez de dejar
    // el hueco gris. Asi la caratula que se ve en la lista se ve tambien en el
    // mini reproductor y en el reproductor completo.
    final candidates = <String>[];
    for (final candidate in [
      if (metadata.artUri?.scheme != 'file') metadata.artUri?.toString(),
      metadata.extras?['highResImage']?.toString(),
      metadata.extras?['lowResImage']?.toString(),
      youtubeThumbnailUrl(metadata.extras?['ytid']?.toString()),
    ]) {
      final url = candidate?.trim() ?? '';
      if (url.isNotEmpty && url != 'null' && !candidates.contains(url)) {
        candidates.add(url);
      }
    }

    // NullArtworkWidget queda como ultimo recurso, y pinned a `size`: sin el
    // se iria a su propio 220 por defecto y reventaria el hueco que lo aloja
    // (mini reproductor, fila de la cola...).
    Widget remoteOrNothing() => candidates.isEmpty
        ? NullArtworkWidget(
            size: size,
            iconSize: errorWidgetIconSize,
            borderRadius: borderRadius,
          )
        : _ArtworkWithFallbacks(
            candidates: candidates,
            size: size,
            borderRadius: borderRadius,
            errorWidgetIconSize: errorWidgetIconSize,
          );

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
              if (resolvedPath == null) return remoteOrNothing();
              return ClipRRect(
                borderRadius: BorderRadius.circular(borderRadius),
                child: Image.file(
                  File(resolvedPath),
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) =>
                      remoteOrNothing(),
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
            errorBuilder: (context, error, stackTrace) => remoteOrNothing(),
          ),
        ),
      );
    }

    return remoteOrNothing();
  }
}

class _ArtworkWithFallbacks extends StatefulWidget {
  const _ArtworkWithFallbacks({
    required this.candidates,
    required this.size,
    required this.borderRadius,
    required this.errorWidgetIconSize,
  });

  final List<String> candidates;
  final double size;
  final double borderRadius;
  final double errorWidgetIconSize;

  @override
  State<_ArtworkWithFallbacks> createState() => _ArtworkWithFallbacksState();
}

class _ArtworkWithFallbacksState extends State<_ArtworkWithFallbacks> {
  int _index = 0;

  @override
  void didUpdateWidget(_ArtworkWithFallbacks oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Otra cancion: se vuelve a empezar por su portada buena.
    if (oldWidget.candidates.first != widget.candidates.first) _index = 0;
  }

  void _nextCandidate() {
    if (_index >= widget.candidates.length - 1) return;
    // El errorWidget se pinta durante el build: cambiar de reserva ahi mismo
    // reventaria el frame en curso.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _index++);
    });
  }

  @override
  Widget build(BuildContext context) {
    final artwork = widget.candidates[_index];
    final isLast = _index == widget.candidates.length - 1;
    final fallback = NullArtworkWidget(
      size: widget.size,
      iconSize: widget.errorWidgetIconSize,
      borderRadius: widget.borderRadius,
    );

    // Non-http art sources (e.g. podcast RSS feeds without a real image,
    // falling back to the bundled asset logo) can't be loaded by
    // CachedNetworkImage - ArtworkProvider already knows how to resolve
    // http, asset, data: and file sources, so route those through it
    // instead of always assuming a network URL.
    if (!artwork.startsWith('http')) {
      return SizedBox(
        width: widget.size,
        height: widget.size,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(widget.borderRadius),
          child: Image(
            image: ArtworkProvider.get(artwork),
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) {
              _nextCandidate();
              return isLast ? fallback : const SizedBox.shrink();
            },
          ),
        ),
      );
    }

    return CachedNetworkImage(
      width: widget.size,
      height: widget.size,
      imageUrl: artwork,
      imageBuilder: (context, imageProvider) => ClipRRect(
        borderRadius: BorderRadius.circular(widget.borderRadius),
        child: Image(image: imageProvider, fit: BoxFit.cover),
      ),
      placeholder: (context, url) => const Spinner(),
      errorWidget: (context, url, error) {
        _nextCandidate();
        return isLast ? fallback : const Spinner();
      },
    );
  }
}
