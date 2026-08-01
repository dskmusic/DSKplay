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
import 'package:flutter_slidable/flutter_slidable.dart';

/// Shared swipe-to-reveal-actions pane used by every row that supports it
/// (podcast episodes, local files, songs). Kept as one place so all of them
/// reveal/animate the same way regardless of how many actions they show.
ActionPane buildSwipeActionPane(List<SlidableAction> actions) {
  return ActionPane(
    motion: const DrawerMotion(),
    extentRatio: (0.24 * actions.length).clamp(0.24, 0.75),
    children: actions,
  );
}
