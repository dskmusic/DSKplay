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

import 'dart:math' as math;

import 'package:dskplay/extensions/l10n.dart';
import 'package:dskplay/services/podcast_manager.dart';
import 'package:flutter/material.dart';

/// Small modal to view/edit a free-text note attached to a podcast episode.
/// Notes live in the same Hive 'user' box as everything else, so they're
/// included automatically in exports/backups.
Future<void> showEpisodeNotesDialog(
  BuildContext context, {
  required String episodeKey,
  required String episodeTitle,
}) async {
  final controller = TextEditingController(
    text: podcastManager.getEpisodeNote(episodeKey) ?? '',
  );

  final saved = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(
        episodeTitle,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      content: SizedBox(
        width: math.min(420, MediaQuery.sizeOf(dialogContext).width * 0.9),
        child: TextField(
          controller: controller,
          autofocus: true,
          minLines: 6,
          maxLines: 14,
          decoration: const InputDecoration(
            hintText: 'Escribe tus notas sobre este episodio...',
            border: OutlineInputBorder(),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(dialogContext.l10n!.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(dialogContext.l10n!.save),
        ),
      ],
    ),
  );

  if (saved == true) {
    await podcastManager.setEpisodeNote(episodeKey, controller.text);
  }
  controller.dispose();
}
