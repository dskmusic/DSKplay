import 'dart:io';

import 'package:dskplay/services/playlists_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

void main() {
  setUpAll(() async {
    Hive.init(Directory.systemTemp.createTempSync('dskplay_test').path);
    await Hive.openBox('user');
  });

  setUp(() {
    userPlaylistFolders.value = [
      {
        'id': 'c1',
        'name': 'Propias',
        'kind': 'custom',
        'playlists': <Map>[],
      },
      {
        'id': 'l1',
        'name': 'Favoritas A',
        'kind': 'liked',
        'playlists': [
          {'ytid': 'b'},
        ],
      },
      {
        'id': 'l2',
        'name': 'Favoritas B',
        'kind': 'liked',
        'playlists': <Map>[],
      },
    ];
    userLikedPlaylists.value = [
      {'ytid': 'a', 'title': 'A'},
      {'ytid': 'b', 'title': 'B'},
      {'ytid': 'c', 'title': 'C'},
    ];
  });

  test('las carpetas se separan por tipo', () {
    expect(playlistFoldersOfKind('liked').map((f) => f['id']), ['l1', 'l2']);
    expect(playlistFoldersOfKind('custom').map((f) => f['id']), ['c1']);
    expect(playlistIdsInFolders('liked'), {'b'});
  });

  test('la sección de favoritas oculta las que están en carpetas', () {
    expect(getLikedPlaylistItems().map((p) => p['ytid']), ['a', 'c']);
    expect(getLikedPlaylistItems(includeInFolders: true).length, 3);
  });

  test('reordenar favoritas ignora las que viven en carpetas', () {
    // La vista muestra [a, c]; llevar "c" al principio no mueve a "b".
    reorderLikedLibraryItem('c', 0, isArtist: false);

    expect(userLikedPlaylists.value.map((p) => p['ytid']), ['c', 'b', 'a']);
  });

  test('reordenar carpetas sólo afecta a las de su tipo', () {
    reorderPlaylistFolder('l2', 0, kind: 'liked');

    expect(userPlaylistFolders.value.map((f) => f['id']), ['c1', 'l2', 'l1']);
  });

  test('reordenar listas dentro de una carpeta', () {
    userPlaylistFolders.value = [
      {
        'id': 'l1',
        'kind': 'liked',
        'playlists': [
          {'ytid': 'x'},
          {'ytid': 'y'},
          {'ytid': 'z'},
        ],
      },
    ];

    reorderPlaylistInFolder('l1', 'z', 0);

    final folder = userPlaylistFolders.value.first;
    expect((folder['playlists']! as List).map((p) => p['ytid']), [
      'z',
      'x',
      'y',
    ]);
  });
  test('la caratula de una carpeta se guarda y se quita', () {
    setPlaylistFolderImage('c1', 'https://img/portada.jpg');
    expect(userPlaylistFolders.value.first['image'], 'https://img/portada.jpg');

    setPlaylistFolderImage('c1', '');
    expect(userPlaylistFolders.value.first.containsKey('image'), false);
  });

}
