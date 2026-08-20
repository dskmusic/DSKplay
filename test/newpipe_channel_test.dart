import 'package:dskplay/services/newpipe.dart';
import 'package:dskplay/utilities/formatter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// Comprueba que el lado Dart entiende EXACTAMENTE lo que manda NewPipeBridge.
// Las cargas útiles están copiadas de la salida real de NewPipeSmokeTest, y se
// entregan como Map<Object?, Object?>, que es lo que produce el códec del
// MethodChannel (no Map<String, dynamic>).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.dskmusic.dskplay/newpipe');

  Map<Object?, Object?> videoItem(String id, String title) => <Object?, Object?>{
    'type': 'video',
    'id': id,
    'title': title,
    'author': 'Coldplay',
    'channelId': 'UCDPM_n1atn2ijUwHd0NNRQw',
    'duration': 273,
    'isLive': false,
    'thumbnail': 'https://i.ytimg.com/vi/$id/hq720.jpg',
  };

  Map<Object?, Object?> playlistItem(String id) => <Object?, Object?>{
    'type': 'playlist',
    'id': id,
    'title': 'Coldplay - Parachutes (Full Album CD)',
    'author': 'Tony Cruz',
    'channelId': 'UC6SUL7PPIOvUchnjkk_HQkA',
    'streamCount': 10,
    'thumbnail': 'https://i.ytimg.com/vi/2XqpXmhM1Fc/hq720.jpg',
  };

  void mock(Object? Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => handler(call));
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('playlistItems convierte lo que manda el nativo', () async {
    late MethodCall seen;
    mock((call) {
      seen = call;
      return <Object?>[videoItem('fcnDmrtj6Sk', 'Shakira, Burna Boy - Dai Dai')];
    });

    final songs = await NewPipe.playlistItems('PLgzTt0k8mXz', limit: 500);

    expect(seen.method, 'playlistItems');
    expect(seen.arguments['id'], 'PLgzTt0k8mXz');
    expect(seen.arguments['limit'], 500);
    expect(songs, hasLength(1));
    expect(songs.first.id, 'fcnDmrtj6Sk');
    expect(songs.first.duration, const Duration(seconds: 273));

    // Es lo que hace getSongsFromPlaylist con cada canción.
    final layout = returnSongLayout(0, songs.first, playlistImage: null);
    expect(layout['ytid'], 'fcnDmrtj6Sk');
    expect(layout['title'], isNotEmpty);
    expect(layout['image'], contains('fcnDmrtj6Sk'));
  });

  test('search de listas se filtra bien con playlistsOf', () async {
    late MethodCall seen;
    mock((call) {
      seen = call;
      return <Object?>[
        playlistItem('PLLFaXG8eSf2-5G1s7YBcade0L2KLcy_Lv'),
        videoItem('yKNxeF4KMsY', 'Coldplay - Yellow'),
      ];
    });

    final raw = await NewPipe.search(
      'coldplay album',
      filters: const [SearchFilter.playlists],
    );
    final playlists = NewPipe.playlistsOf(raw);

    expect(seen.arguments['filters'], ['playlists']);
    expect(playlists, hasLength(1));
    expect(playlists.first.id, 'PLLFaXG8eSf2-5G1s7YBcade0L2KLcy_Lv');
    expect(playlists.first.thumbnail, isNotEmpty);
    expect(playlists.first.streamCount, 10);

    // El mapa que construye getPlaylists a partir de esto.
    final map = {
      'ytid': playlists.first.id,
      'title': playlists.first.title,
      'image': playlists.first.thumbnail,
      'source': 'youtube',
      'list': [],
    };
    expect(map, isA<Map<String, dynamic>>());
  });

  test('un fallo nativo se propaga como PlatformException', () async {
    mock((call) => throw PlatformException(code: 'newpipe', message: 'boom'));
    await expectLater(
      NewPipe.playlistItems('PLwhatever'),
      throwsA(isA<PlatformException>()),
    );
  });
}
