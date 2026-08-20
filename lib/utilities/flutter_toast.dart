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

import 'package:dskplay/main.dart';
import 'package:dskplay/widgets/mini_player.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';

void showToast(
  BuildContext context,
  String text, {
  Duration duration = const Duration(seconds: 3),
  IconData? icon,
  // A SnackBar is painted inside the Scaffold's own layout, so it always
  // renders behind a dialog route's OverlayEntry - set this when calling
  // from within an open dialog (e.g. AlertDialog) to float above it instead.
  bool aboveDialogs = false,
}) {
  final colorScheme = Theme.of(context).colorScheme;

  final content = Row(
    children: [
      Icon(
        icon ?? FluentIcons.checkmark_circle_20_regular,
        color: colorScheme.onSecondaryContainer,
        size: 20,
      ),
      const SizedBox(width: 12),
      Expanded(
        child: Text(
          text,
          style: TextStyle(
            color: colorScheme.onSecondaryContainer,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    ],
  );

  if (aboveDialogs) {
    final overlay = Overlay.of(context, rootOverlay: true);
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (context) => Positioned(
        left: 16,
        right: 16,
        bottom: 24,
        child: Material(
          color: colorScheme.secondaryContainer,
          elevation: 6,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: content,
          ),
        ),
      ),
    );
    overlay.insert(entry);
    Future.delayed(duration, entry.remove);
    return;
  }

  final isMiniPlayerVisible = audioHandler.mediaItem.value != null;
  final bottomMargin =
      12.0 + (isMiniPlayerVisible ? MiniPlayer.playerHeight : 0.0);

  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      margin: EdgeInsets.fromLTRB(16, 12, 16, bottomMargin),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      content: content,
      duration: duration,
    ),
  );
}

void showToastWithButton(
  BuildContext context,
  String text,
  String buttonName,
  VoidCallback onPressedToast, {
  Duration duration = const Duration(seconds: 3),
  IconData? icon,
}) {
  final colorScheme = Theme.of(context).colorScheme;
  final isMiniPlayerVisible = audioHandler.mediaItem.value != null;
  final bottomMargin =
      12.0 + (isMiniPlayerVisible ? MiniPlayer.playerHeight : 0.0);

  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      margin: EdgeInsets.fromLTRB(16, 12, 16, bottomMargin),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      content: Row(
        children: [
          Icon(
            icon ?? FluentIcons.info_20_regular,
            color: colorScheme.onSecondaryContainer,
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(text)),
        ],
      ),
      action: SnackBarAction(
        label: buttonName,
        onPressed: () => onPressedToast(),
      ),
      persist: false,
      duration: duration,
    ),
  );
}
