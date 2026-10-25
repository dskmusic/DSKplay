import 'package:dskplay/widgets/seasonal_decor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Season on(int month, int day) => seasonForDate(DateTime(2026, month, day));

  test('el calendario reparte las fiestas sin huecos ni solapes', () {
    expect(on(10, 23), Season.none);
    expect(on(10, 24), Season.halloween);
    expect(on(10, 31), Season.halloween);
    expect(on(11, 2), Season.halloween);
    expect(on(11, 3), Season.none);

    expect(on(12, 2), Season.christmas);
    expect(on(12, 25), Season.christmas);

    // El salto de año es el unico rango que cruza diciembre a enero.
    expect(on(12, 27), Season.newYear);
    expect(on(1, 1), Season.newYear);
    expect(on(1, 2), Season.newYear);

    expect(on(1, 6), Season.epiphany);
    expect(on(1, 7), Season.none);

    expect(on(2, 14), Season.valentines);

    expect(on(6, 19), Season.none);
    expect(on(6, 21), Season.musicDay);
    expect(on(6, 23), Season.none);
  });

  test('los cuatro cumpleaños comparten decoracion y pisan a la fiesta', () {
    expect(on(2, 6), Season.none);
    expect(on(2, 8), Season.birthday); // Víctor
    expect(on(2, 10), Season.none);

    expect(on(3, 31), Season.birthday); // Lucía
    expect(on(4, 23), Season.birthday); // Alicia

    // Eva cae el 1 de diciembre: manda el cumpleaños, no la Navidad.
    expect(on(11, 30), Season.birthday);
    expect(on(12, 1), Season.birthday);
  });
}
