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
import 'package:dskplay/widgets/confirmation_dialog.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';

/// Selección múltiple para borrar en las listas de la biblioteca.
///
/// Se entra manteniendo pulsado un elemento y se sale con la X. Los elementos
/// no se tocan por dentro: en modo selección se les pone una casilla delante y
/// se les ignoran los toques ([IgnorePointer]), así el menú de tres puntos y
/// el deslizar no se disparan sin querer mientras se seleccionan.

/// Barra superior mientras hay selección activa.
AppBar buildSelectionAppBar(
  BuildContext context, {
  required int selectedCount,
  required VoidCallback onClose,
  required VoidCallback onSelectAll,
  required VoidCallback onDelete,
}) {
  return AppBar(
    leading: IconButton(
      icon: const Icon(FluentIcons.dismiss_24_regular),
      tooltip: context.l10n!.cancel,
      onPressed: onClose,
    ),
    title: Text('$selectedCount seleccionados'),
    actions: [
      IconButton(
        icon: const Icon(FluentIcons.select_all_on_24_regular),
        tooltip: 'Seleccionar todo',
        onPressed: onSelectAll,
      ),
      IconButton(
        icon: const Icon(FluentIcons.delete_24_regular),
        tooltip: context.l10n!.delete,
        color: Theme.of(context).colorScheme.error,
        onPressed: selectedCount == 0 ? null : onDelete,
      ),
    ],
  );
}

/// Envuelve un elemento de lista para poder seleccionarlo.
Widget buildSelectableItem({
  required bool selectionMode,
  required bool selected,
  required VoidCallback onToggle,
  required VoidCallback onLongPress,
  required Widget child,
}) {
  if (!selectionMode) {
    return GestureDetector(onLongPress: onLongPress, child: child);
  }
  return GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: onToggle,
    child: Row(
      children: [
        Checkbox(value: selected, onChanged: (_) => onToggle()),
        Expanded(child: IgnorePointer(child: child)),
      ],
    ),
  );
}

/// Confirmación previa a cualquier borrado en lote.
Future<bool> confirmMultiDelete(BuildContext context, String message) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => ConfirmationDialog(
      confirmationMessage: message,
      submitMessage: dialogContext.l10n!.delete,
      isDangerous: true,
      onCancel: () => Navigator.of(dialogContext).pop(false),
      onSubmit: () => Navigator.of(dialogContext).pop(true),
    ),
  );
  return confirmed ?? false;
}
