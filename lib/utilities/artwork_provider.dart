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

import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Ancho en pixeles reales al que decodificar una portada que se va a pintar
/// en un hueco de [size] px logicos, o `null` para decodificarla tal cual.
///
/// Sin esto una miniatura de 320-1000 px se decodifica entera para acabar en
/// un cubo de 50, y lo que ocupa en memoria son los pixeles decodificados, no
/// el JPEG.
///
/// ponytail: solo se recorta por debajo de 320 px, el ancho de la fuente mas
/// pobre que usa la app (`mqdefault`). Por encima de ese tope decodificar al
/// tamano del hueco dejaria de ahorrar para empezar a escalar hacia arriba.
int? artworkDecodeWidth(BuildContext context, double size) {
  final width = (size * MediaQuery.devicePixelRatioOf(context)).round();
  return width > 0 && width < 320 ? width : null;
}

class ArtworkProvider {
  ArtworkProvider._();

  static final Map<String, ImageProvider> _cache = {};

  static ImageProvider get(String artwork) {
    if (artwork.isEmpty) throw ArgumentError('artwork must not be empty');

    final cached = _cache[artwork];
    if (cached != null) return cached;

    late ImageProvider provider;
    try {
      if (artwork.startsWith('http')) {
        provider = CachedNetworkImageProvider(artwork);
      } else if (artwork.startsWith('data:image')) {
        final commaIdx = artwork.indexOf(',');
        if (commaIdx == -1) throw Exception('invalid base64 image');
        final bytes = base64Decode(artwork.substring(commaIdx + 1));
        provider = MemoryImage(bytes);
      } else if (!kIsWeb &&
          (artwork.startsWith('file://') || artwork.startsWith('/'))) {
        final path = artwork.replaceFirst('file://', '');
        provider = FileImage(File(path));
      } else {
        provider = AssetImage(artwork);
      }
    } catch (_) {
      provider = const AssetImage('assets/placeholder.png');
    }

    _cache[artwork] = provider;
    return provider;
  }

  static void clearCache() => _cache.clear();
}
