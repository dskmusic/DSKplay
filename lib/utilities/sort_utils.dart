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

/// Sorts a list of songs by a given key (title or artist)
void sortSongsByKey(
  List<dynamic> songs,
  String sortKey, {
  bool ascending = true,
}) {
  songs.sort((a, b) {
    final valueA = (a[sortKey] ?? '').toString().toLowerCase();
    final valueB = (b[sortKey] ?? '').toString().toLowerCase();
    return ascending ? valueA.compareTo(valueB) : valueB.compareTo(valueA);
  });
}
