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

typedef SortTypeToStringConverter<T> = String Function(T type);
typedef OnSortTypeSelected<T> = void Function(T type, bool ascending);

/// Tapping the already-selected chip flips [ascending] instead of no-op;
/// tapping a different chip keeps its own default (ascending) direction.
class SortChips<T extends Enum> extends StatelessWidget {
  const SortChips({
    required this.currentSortType,
    required this.sortTypes,
    required this.sortTypeToString,
    required this.onSelected,
    this.ascending = true,
    super.key,
  });

  final T currentSortType;
  final List<T> sortTypes;
  final SortTypeToStringConverter<T> sortTypeToString;
  final OnSortTypeSelected<T> onSelected;
  final bool ascending;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: sortTypes.map((type) {
          final isSelected = currentSortType == type;
          final chipColor = isSelected
              ? colorScheme.onSecondaryContainer
              : colorScheme.onSurfaceVariant;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilterChip(
              selected: isSelected,
              showCheckmark: false,
              label: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    sortTypeToString(type),
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                      color: chipColor,
                    ),
                  ),
                  if (isSelected) ...[
                    const SizedBox(width: 4),
                    Icon(
                      ascending
                          ? Icons.arrow_upward_rounded
                          : Icons.arrow_downward_rounded,
                      size: 14,
                      color: chipColor,
                    ),
                  ],
                ],
              ),
              backgroundColor: colorScheme.surfaceContainerHigh,
              selectedColor: colorScheme.secondaryContainer,
              side: BorderSide.none,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              onSelected: (_) {
                onSelected(type, !isSelected || !ascending);
              },
            ),
          );
        }).toList(),
      ),
    );
  }
}
