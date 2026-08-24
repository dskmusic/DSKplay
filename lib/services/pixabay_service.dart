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

/// Búsqueda de imágenes libres en Pixabay (pixabay.com), la misma fuente que
/// usa Soniloco. La clave es la del plan gratuito y viaja dentro del APK: no
/// da acceso a nada más que a buscar, pero si algún día se abusa de ella hay
/// que regenerarla en pixabay.com, no hay más remedio.
const _pixabayKey = '10012913-1fa6410e31f10870fa3a0dc3c';

const pixabayPageSize = 30;

/// Idiomas que acepta el parámetro `lang` de Pixabay; buscar "gato" con
/// `lang=en` no devuelve nada, así que la búsqueda sigue al idioma de la app.
const _pixabayLanguages = {
  'cs',
  'da',
  'de',
  'en',
  'es',
  'fr',
  'id',
  'it',
  'hu',
  'nl',
  'no',
  'pl',
  'pt',
  'ro',
  'sk',
  'fi',
  'sv',
  'tr',
  'vi',
  'th',
  'bg',
  'ru',
  'el',
  'ja',
  'ko',
  'zh',
};

String pixabayLangFor(String languageCode) =>
    _pixabayLanguages.contains(languageCode) ? languageCode : 'en';

enum PixabayMediaType {
  photo('photo', 'Fotos'),
  illustration('illustration', 'Ilustraciones'),
  vector('vector', 'Vectores'),
  all('all', 'Todo');

  const PixabayMediaType(this.apiValue, this.label);

  final String apiValue;
  final String label;
}

class PixabayImage {
  const PixabayImage({
    required this.id,
    required this.previewUrl,
    required this.webformatUrl,
    required this.largeUrl,
    required this.tags,
  });

  factory PixabayImage.fromJson(Map<String, dynamic> json) {
    final preview = (json['previewURL'] ?? '') as String;
    final webformat = (json['webformatURL'] ?? '') as String;
    final large = (json['largeImageURL'] ?? '') as String;
    return PixabayImage(
      id: '${json['id']}',
      previewUrl: preview,
      // Se guarda como portada esta versión (~640px): la grande son varios MB
      // en base64 dentro de la base de datos para una carátula que se ve a
      // 300px como mucho.
      webformatUrl: webformat.isNotEmpty ? webformat : preview,
      largeUrl: large.isNotEmpty
          ? large
          : (webformat.isNotEmpty ? webformat : preview),
      tags: (json['tags'] ?? '') as String,
    );
  }

  final String id;
  final String previewUrl;
  final String webformatUrl;
  final String largeUrl;
  final String tags;
}

/// Lanza si la petición falla, para poder distinguir "sin resultados" de
/// "no hay red" en la interfaz.
Future<List<PixabayImage>> searchPixabay(
  String query, {
  PixabayMediaType type = PixabayMediaType.photo,
  int page = 1,
  String lang = 'en',
}) async {
  final uri = Uri.https('pixabay.com', '/api/', {
    'key': _pixabayKey,
    'q': query,
    'image_type': type.apiValue,
    'safesearch': 'true',
    'per_page': '$pixabayPageSize',
    'page': '$page',
    'lang': lang,
  });

  final response = await http.get(uri);
  if (response.statusCode != 200) {
    throw Exception('Pixabay ${response.statusCode}');
  }
  final hits = (jsonDecode(response.body) as Map)['hits'] as List? ?? const [];
  return [
    for (final hit in hits)
      if ((hit as Map)['previewURL'] != null)
        PixabayImage.fromJson(hit.cast<String, dynamic>()),
  ];
}

/// Descarga la imagen y la devuelve como data URI, el mismo formato que
/// produce la selección desde el dispositivo.
Future<String?> downloadImageAsDataUri(String url) async {
  final response = await http.get(Uri.parse(url));
  if (response.statusCode != 200) return null;
  final mimeType = url.toLowerCase().endsWith('.png')
      ? 'image/png'
      : 'image/jpeg';
  return 'data:$mimeType;base64,${base64Encode(response.bodyBytes)}';
}
