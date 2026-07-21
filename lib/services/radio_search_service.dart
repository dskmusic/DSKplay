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

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:musify/main.dart' show logger;
import 'package:musify/models/radio_model.dart';

// Free, open station directory: https://www.radio-browser.info
const _radioBrowserHost = 'de1.api.radio-browser.info';

// ArtworkProvider.get() throws on an empty string, so stations without a
// favicon need a real fallback image.
const _fallbackStationImage = 'assets/logo.png';

Future<List<RadioStation>> searchRadioBrowserStations(String query) async {
  final trimmedQuery = query.trim();
  if (trimmedQuery.isEmpty) return [];

  try {
    final uri = Uri.https(_radioBrowserHost, '/json/stations/search', {
      'name': trimmedQuery,
      'limit': '25',
      'hidebroken': 'true',
      'order': 'clickcount',
      'reverse': 'true',
    });

    final response = await http
        .get(uri, headers: {'User-Agent': 'DSKPlay/1.0'})
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) return [];

    final results = jsonDecode(response.body) as List<dynamic>;
    return results
        .whereType<Map>()
        .map(_stationFromRadioBrowserJson)
        .whereType<RadioStation>()
        .toList();
  } catch (e, stackTrace) {
    logger.log(
      'Error searching Radio Browser stations',
      error: e,
      stackTrace: stackTrace,
    );
    return [];
  }
}

RadioStation? _stationFromRadioBrowserJson(Map<dynamic, dynamic> raw) {
  final map = raw.cast<String, dynamic>();
  final id = map['stationuuid'] as String?;
  final name = (map['name'] as String? ?? '').trim();
  final resolvedUrl = (map['url_resolved'] as String? ?? '').trim();
  final streamUrl = resolvedUrl.isNotEmpty
      ? resolvedUrl
      : (map['url'] as String? ?? '').trim();

  if (id == null || name.isEmpty || streamUrl.isEmpty) return null;

  final tags = (map['tags'] as String? ?? '').split(',');
  final genre = tags.isNotEmpty && tags.first.trim().isNotEmpty
      ? tags.first.trim()
      : null;

  final favicon = (map['favicon'] as String? ?? '').trim();

  return RadioStation(
    id: 'rb_$id',
    name: name,
    image: favicon.isNotEmpty ? favicon : _fallbackStationImage,
    streamUrl: streamUrl,
    genre: genre,
  );
}
