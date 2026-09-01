import 'package:dskplay/utilities/listening_stats_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('previous month stays visible on the 1st of a new month', () {
    final august = applyListeningTimeDelta(
      createEmptyListeningStats(2026, currentMonthKey: '2026-08'),
      listenedDuration: const Duration(minutes: 30),
      listenedAt: DateTime(2026, 8, 20, 12),
    );

    final visible = visibleListeningStatsMonthKeys(august, DateTime(2026, 9));

    expect(visible, ['2026-08']);
  });
}
