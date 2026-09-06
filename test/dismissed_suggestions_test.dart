import 'dart:io';

import 'package:dskplay/services/common_services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

// Descartar una sugerencia era definitivo y la lista de descartes solo crecia.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    Hive.init(Directory.systemTemp.createTempSync('dskplay_dismissed').path);
    await Hive.openBox('user');
  });

  setUp(() {
    userHiddenRecommendationIds.value = [];
  });

  test('descartar se puede deshacer y no crece sin limite', () async {
    await hideSongFromRecommendations('x1');
    expect(userHiddenRecommendationIds.value, contains('x1'));

    await unhideSongFromRecommendations('x1');
    expect(userHiddenRecommendationIds.value, isNot(contains('x1')));

    for (var i = 0; i < 305; i++) {
      await hideSongFromRecommendations('d$i');
    }

    // Se quedan los ultimos 300: los cinco primeros descartes se han caido.
    expect(userHiddenRecommendationIds.value.length, 300);
    expect(userHiddenRecommendationIds.value.first, 'd5');

    await clearHiddenRecommendations();
    expect(userHiddenRecommendationIds.value, isEmpty);
  });
}
