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
import 'package:dskplay/services/playlists_manager.dart';
import 'package:dskplay/widgets/dialog_item.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';

/// Resultado del selector: [folderId] `null` significa "Biblioteca" (sacar de
/// la carpeta). Si el usuario cancela, el `Future` devuelve `null`.
typedef FolderPickerResult = ({String? folderId});

/// Diálogo compartido para elegir carpeta de destino.
///
/// Lo usan tanto el menú de una lista suelta como los borrados/movimientos en
/// lote, así que la lista de carpetas y los textos viven aquí y no duplicados
/// en cada pantalla.
Future<FolderPickerResult?> showFolderPickerDialog(
  BuildContext context, {
  required String folderKind,
  String? excludeFolderId,
  bool allowLibrary = true,
}) {
  return showDialog<FolderPickerResult>(
    context: context,
    builder: (context) {
      final colorScheme = Theme.of(context).colorScheme;
      return AlertDialog(
        icon: Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: colorScheme.secondaryContainer,
            shape: BoxShape.circle,
          ),
          child: Icon(
            FluentIcons.folder_arrow_right_24_regular,
            color: colorScheme.secondary,
            size: 28,
          ),
        ),
        title: Text(
          context.l10n!.moveToFolder,
          style: TextStyle(
            color: colorScheme.onSurface,
            fontWeight: FontWeight.w600,
          ),
          textAlign: TextAlign.center,
        ),
        contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        content: SizedBox(
          width: double.maxFinite,
          child: ValueListenableBuilder<List>(
            valueListenable: userPlaylistFolders,
            builder: (context, folders, _) {
              final availableFolders = folders
                  .where(
                    (folder) =>
                        folder['id'] != excludeFolderId &&
                        (folder['kind']?.toString() ?? 'custom') == folderKind,
                  )
                  .toList();

              if (!allowLibrary && availableFolders.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text(
                    context.l10n!.noFolders,
                    style: TextStyle(color: colorScheme.onSurfaceVariant),
                    textAlign: TextAlign.center,
                  ),
                );
              }

              return ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: [
                  if (allowLibrary)
                    DialogItem(
                      icon: FluentIcons.library_24_regular,
                      iconColor: colorScheme.primary,
                      iconBgColor: colorScheme.primaryContainer,
                      label: context.l10n!.library,
                      onTap: () =>
                          Navigator.pop(context, (folderId: null)),
                    ),
                  ...availableFolders.map(
                    (folder) => DialogItem(
                      icon: FluentIcons.folder_24_regular,
                      iconColor: colorScheme.secondary,
                      iconBgColor: colorScheme.secondaryContainer,
                      label: folder['name'] as String,
                      onTap: () => Navigator.pop(context, (
                        folderId: folder['id'] as String,
                      )),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        actions: [
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: () => Navigator.pop(context),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                side: BorderSide(color: colorScheme.outline),
              ),
              child: Text(
                context.l10n!.cancel,
                style: TextStyle(
                  color: colorScheme.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      );
    },
  );
}
