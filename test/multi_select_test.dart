import 'package:dskplay/widgets/multi_select.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('mantener pulsado abre selección; en selección el tile no '
      'recibe toques', (tester) async {
    var childTaps = 0;
    var toggles = 0;
    var longPresses = 0;

    Widget build(bool selectionMode) => MaterialApp(
      home: Scaffold(
        body: buildSelectableItem(
          selectionMode: selectionMode,
          selected: false,
          onToggle: () => toggles++,
          onLongPress: () => longPresses++,
          child: GestureDetector(
            onTap: () => childTaps++,
            child: const SizedBox(width: 200, height: 60, child: Text('tile')),
          ),
        ),
      ),
    );

    await tester.pumpWidget(build(false));
    await tester.tap(find.text('tile'));
    await tester.longPress(find.text('tile'));
    expect(childTaps, 1);
    expect(longPresses, 1);

    await tester.pumpWidget(build(true));
    // warnIfMissed: el toque lo recoge el envoltorio, no el tile ignorado.
    await tester.tap(find.text('tile'), warnIfMissed: false);
    expect(toggles, 1);
    // El menú de tres puntos y el reproducir del tile quedan neutralizados.
    expect(childTaps, 1);
  });
}
