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

class RadioStation {
  const RadioStation({
    required this.id,
    required this.name,
    required this.image,
    required this.streamUrl,
    this.genre,
    this.description,
  });
  factory RadioStation.fromMap(Map<String, dynamic> map) {
    return RadioStation(
      id: map['id'] as String,
      name: map['name'] as String,
      image: map['image'] as String,
      streamUrl: map['streamUrl'] as String,
      genre: map['genre'] as String?,
      description: map['description'] as String?,
    );
  }

  final String id;
  final String name;
  final String image;
  final String streamUrl;
  final String? genre;
  final String? description;

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'image': image,
      'streamUrl': streamUrl,
      'genre': genre,
      'description': description,
    };
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is RadioStation && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;
}
