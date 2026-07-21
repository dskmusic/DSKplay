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

import 'package:flutter/material.dart';

/// Creates a PopupMenuItem with consistent icon + label styling
PopupMenuItem<T> buildPopupMenuItem<T>({
  required T value,
  required IconData icon,
  required String label,
  required ColorScheme colorScheme,
  Color? iconColor,
  TextStyle? labelStyle,
  double iconSize = 24,
  double spacing = 8,
}) {
  return PopupMenuItem<T>(
    value: value,
    child: Row(
      children: [
        Icon(icon, color: iconColor ?? colorScheme.primary, size: iconSize),
        SizedBox(width: spacing),
        Text(
          label,
          style: labelStyle ?? TextStyle(color: colorScheme.onSurface),
        ),
      ],
    ),
  );
}
