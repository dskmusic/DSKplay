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
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';

/// Tamano comun de los botones redondos de la fila de acciones (reproducir,
/// mezclar, me gusta, descargar...). Con el tamano por defecto los siete que
/// puede haber no caben de largo en pantallas normales.
const playlistActionIconSize = 22.0;

/// Tamano fijo y forma explicita: con `visualDensity` el alto encogia mas que
/// el ancho y los botones salian ovalados.
const playlistActionButtonStyle = ButtonStyle(
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  padding: WidgetStatePropertyAll(EdgeInsets.zero),
  minimumSize: WidgetStatePropertyAll(Size.square(42)),
  fixedSize: WidgetStatePropertyAll(Size.square(42)),
  shape: WidgetStatePropertyAll(CircleBorder()),
);

/// El de reproducir va un pelin mas grande para que destaque del resto.
const _playButtonStyle = ButtonStyle(
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  padding: WidgetStatePropertyAll(EdgeInsets.zero),
  minimumSize: WidgetStatePropertyAll(Size.square(46)),
  fixedSize: WidgetStatePropertyAll(Size.square(46)),
  shape: WidgetStatePropertyAll(CircleBorder()),
);

/// Play and shuffle whatever the page is about, shared by the playlist and
/// the artist pages. While [isLoading] the songs are still being read, so
/// both buttons wait instead of playing an incomplete list.
///
/// With [compact] the pair shrinks to two round icon buttons meant to sit at
/// the start of the row of secondary actions (like, download...), which is
/// what the app's compact mode uses to save a whole row of height.
class PlaylistActionButtons extends StatelessWidget {
  const PlaylistActionButtons({
    super.key,
    required this.onPlay,
    required this.onShuffle,
    this.isLoading = false,
    this.compact = false,
  });

  final VoidCallback onPlay;

  final VoidCallback onShuffle;

  final bool isLoading;

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    if (compact) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 5,
        children: [
          IconButton.filled(
            icon: isLoading
                ? const _Spinner()
                : const Icon(FluentIcons.play_24_filled),
            iconSize: 24,
            style: _playButtonStyle,
            onPressed: isLoading ? null : onPlay,
            tooltip: context.l10n!.play,
          ),
          IconButton.filledTonal(
            icon: isLoading
                ? const _Spinner()
                : const Icon(FluentIcons.arrow_shuffle_24_filled),
            iconSize: playlistActionIconSize,
            style: playlistActionButtonStyle,
            onPressed: isLoading ? null : onShuffle,
            tooltip: context.l10n!.shuffle,
          ),
        ],
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        children: [
          Expanded(
            child: FilledButton.icon(
              icon: isLoading
                  ? const _Spinner()
                  : const Icon(FluentIcons.play_24_filled),
              label: Text(context.l10n!.play),
              onPressed: isLoading ? null : onPlay,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: colorScheme.secondaryContainer,
                foregroundColor: colorScheme.onSecondaryContainer,
              ),
              icon: isLoading
                  ? const _Spinner()
                  : const Icon(FluentIcons.arrow_shuffle_24_filled),
              label: Text(context.l10n!.shuffle),
              onPressed: isLoading ? null : onShuffle,
            ),
          ),
        ],
      ),
    );
  }
}

/// Replaces the icon of a button while its songs are being read.
class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: 18,
      height: 18,
      child: CircularProgressIndicator(strokeWidth: 2),
    );
  }
}
