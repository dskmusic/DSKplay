import 'dart:io';

import 'package:dskplay/services/common_services.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

// Los relacionados que devuelve YouTube mezclan canciones con mixes de horas,
// discos enteros, directos y shorts. La autoplay solo debe coger canciones, y
// nunca algo que ya esta en la cola o acaba de sonar.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.dskmusic.dskplay/newpipe');

  Map<Object?, Object?> item(
    String id, {
    required int duration,
    bool isLive = false,
  }) => <Object?, Object?>{
    'type': 'video',
    'id': id,
    'title': 'Artista - $id',
    'author': 'Artista',
    'channelId': 'UC123',
    'duration': duration,
    'isLive': isLive,
  };

  void mockRelated(List<Object?> items) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => items);
  }

  setUpAll(() async {
    Hive.init(Directory.systemTemp.createTempSync('dskplay_test').path);
    await Hive.openBox('user');
  });

  setUp(() {
    userHiddenRecommendationIds.value = [];
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('descarta mixes, shorts, directos, ocultos y repetidos', () async {
    userHiddenRecommendationIds.value = ['oculta'];
    mockRelated([
      item('mix3h', duration: 10800),
      item('album', duration: 2700),
      item('short', duration: 30),
      item('directo', duration: 4000, isLive: true),
      item('sinDuracion', duration: 0),
      item('semilla', duration: 200),
      item('enCola', duration: 200),
      item('oculta', duration: 200),
      item('buena', duration: 213),
    ]);

    final song = await getSimilarSong('semilla', exclude: {'enCola'});

    expect(song?['ytid'], 'buena');
  });

  test('sin candidatos usables devuelve null', () async {
    mockRelated([item('mix3h', duration: 10800)]);

    expect(await getSimilarSong('semilla'), isNull);
  });
}
