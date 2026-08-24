import 'dart:io';

import 'package:dskplay/services/playlists_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

void main() {
  setUpAll(() async {
    Hive.init(Directory.systemTemp.createTempSync('dskplay_test').path);
    await Hive.openBox('user');
  });

  test('reordena sólo las listas que están fuera de carpetas', () {
    userPlaylistFolders.value = [
      {
        'id': 'f1',
        'name': 'Carpeta',
        'playlists': [
          {'ytid': 'b'},
        ],
      },
    ];
    userCustomPlaylists.value = [
      {'ytid': 'a'},
      {'ytid': 'b'},
      {'ytid': 'c'},
    ];

    // La vista muestra [a, c]; llevar "c" al principio no debe mover a "b",
    // que vive dentro de la carpeta.
    reorderCustomPlaylist('c', 0);

    expect(userCustomPlaylists.value.map((p) => p['ytid']), ['c', 'b', 'a']);
  });

  test('reordena canciones dentro de una lista propia', () {
    final playlist = {
      'ytid': 'customId-1',
      'source': 'user-created',
      'list': [
        {'ytid': 's1'},
        {'ytid': 's2'},
        {'ytid': 's3'},
      ],
    };
    userCustomPlaylists.value = [playlist];

    expect(reorderSongInPlaylist(playlist, 2, 0), isTrue);
    expect((playlist['list']! as List).map((s) => s['ytid']), [
      's3',
      's1',
      's2',
    ]);
    // Fuera de rango o al mismo sitio: no toca nada.
    expect(reorderSongInPlaylist(playlist, 9, 0), isFalse);
    expect(reorderSongInPlaylist(playlist, 1, 1), isFalse);
  });
}
