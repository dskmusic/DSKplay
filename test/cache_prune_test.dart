import 'dart:io';

import 'package:dskplay/services/data_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

// La caja 'cache' solo se limpiaba al volver a leer la misma clave, asi que
// todo lo que no se repetia se quedaba dentro y se cargaba en cada arranque.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Box box;

  setUpAll(() async {
    Hive.init(Directory.systemTemp.createTempSync('dskplay_cache').path);
    box = await Hive.openBox('cache');
  });

  setUp(() => box.clear());

  Future<void> put(String key, Object value, Duration age) async {
    await box.put(key, value);
    await box.put('${key}_date', DateTime.now().subtract(age));
  }

  test('se borra lo caducado y se conserva lo vigente', () async {
    // search_: 4 dias de TTL.
    await put('search_viejo', ['a'], const Duration(days: 5));
    await put('search_fresco', ['b'], const Duration(days: 1));
    // Sin clave conocida: 7 dias.
    await put('loquesea', 'x', const Duration(days: 8));

    await cleanupOldCacheEntries();

    expect(box.containsKey('search_viejo'), isFalse);
    expect(box.containsKey('search_viejo_date'), isFalse);
    expect(box.get('search_fresco'), ['b']);
    expect(box.containsKey('loquesea'), isFalse);
  });

  test('el suelo de 6 h protege a quien pide un TTL mas largo', () async {
    // song_*_url caduca a la hora y media segun la clave, pero
    // common_services la lee con 3 h: a las dos horas aun se usa.
    await put('song_abc_high_url', 'https://x', const Duration(hours: 2));
    await put('song_def_high_url', 'https://y', const Duration(hours: 7));

    await cleanupOldCacheEntries();

    expect(box.get('song_abc_high_url'), 'https://x');
    expect(box.containsKey('song_def_high_url'), isFalse);
  });

  test('se tiran las entradas sin fecha y las fechas sin entrada', () async {
    await box.put('sin_fecha', 'x');
    await box.put('fantasma_date', DateTime.now());

    await cleanupOldCacheEntries();

    expect(box.containsKey('sin_fecha'), isFalse);
    expect(box.containsKey('fantasma_date'), isFalse);
  });
}
