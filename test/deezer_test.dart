import 'dart:convert';

import 'package:dskplay/services/artist_service.dart';
import 'package:dskplay/services/deezer.dart';
import 'package:dskplay/services/ytmusic.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Responde con [routes] a la primera ruta que encaje y apunta lo que se pidio.
MockClient _client(Map<String, Object> routes, List<String> calls) {
  return MockClient((request) async {
    calls.add(request.url.path);
    for (final entry in routes.entries) {
      if (request.url.path == entry.key) {
        return http.Response(
          jsonEncode(entry.value),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
    }
    return http.Response('{"error":{"type":"DataException"}}', 200);
  });
}

void main() {
  test('albumIdIsDeezer solo reclama los ids marcados', () {
    expect(albumIdIsDeezer('dz:302127'), isTrue);
    expect(albumIdIsDeezer('MPREb_abc123'), isFalse);
  });

  // Quien enruta un id suelto tiene que ver las dos clases de release: con
  // solo mirar 'MPRE', los albumes de Deezer se iban a buscar a YouTube como
  // si fueran listas suyas y la pantalla salia en blanco.
  test('isArtistAlbumId reconoce releases de las dos fuentes', () {
    expect(isArtistAlbumId('dz:302127'), isTrue);
    expect(isArtistAlbumId('MPREb_abc123'), isTrue);
    expect(isArtistAlbumId('PLabc123'), isFalse);
    expect(isArtistAlbumId('UCabc123'), isFalse);
  });

  test('getArtistReleases mapea prefijo, tipo y año', () async {
    final calls = <String>[];
    final client = DeezerClient(
      httpClient: _client({
        '/search/artist': {
          'data': [
            {'id': 999, 'name': 'Coldplay Tribute Band'},
            {'id': 892, 'name': 'Coldplay', 'picture_xl': 'https://d/c.jpg'},
          ],
        },
        '/artist/892/albums': {
          'data': [
            {
              'id': 1,
              'title': 'Parachutes',
              'record_type': 'album',
              'release_date': '2000-07-10',
              'cover_xl': 'https://d/p.jpg',
            },
            {'id': 2, 'title': 'Yellow', 'record_type': 'single'},
            {'id': 3, 'title': 'Acoustic', 'record_type': 'ep'},
            // Deezer repite releases entre paginas: la misma no debe contarse
            // dos veces.
            {'id': 1, 'title': 'Parachutes', 'record_type': 'album'},
          ],
        },
      }, calls),
    );

    final releases = await client.getArtistReleases('UCxyz', name: 'Coldplay');

    // El nombre exacto gana al primer resultado de la busqueda.
    expect(calls, contains('/artist/892/albums'));
    expect(releases.length, 3);

    final album = releases.first;
    expect(album.id, 'dz:1');
    expect(album.title, 'Parachutes');
    expect(album.type, MusicReleaseType.album);
    expect(album.year, '2000');
    expect(album.thumbnailUrl, 'https://d/p.jpg');

    expect(releases[1].type, MusicReleaseType.single);
    expect(releases[2].type, MusicReleaseType.ep);
  });

  test('un 200 con {"error"} se trata como sin datos', () async {
    final client = DeezerClient(httpClient: _client({}, []));

    expect(await client.getArtistReleases('UCxyz', name: 'Coldplay'), isEmpty);
    // Sin artista, el perfil sale vacio pero conserva el canal de YouTube:
    // artist_service decide entonces si prueba la otra fuente.
    final profile = await client.getArtistProfile('UCxyz', name: 'Coldplay');
    expect(profile.id, 'UCxyz');
    expect(profile.releases, isEmpty);
    expect(profile.monthlyListeners, isNull);
  });

  test('sin nombre de artista no se llama a Deezer', () async {
    final calls = <String>[];
    final client = DeezerClient(httpClient: _client({}, calls));

    expect(await client.getArtistReleases('UCxyz'), isEmpty);
    expect(calls, isEmpty);
  });
}
