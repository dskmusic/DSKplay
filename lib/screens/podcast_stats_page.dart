/*
 *     Copyright (C) 2026 Víctor Castilla
 *
 *     DSK Play is free software: you can redistribute it and/or modify
 *     it under the terms of the GNU General Public License as published by
 *     the Free Software Foundation, either version 3 of the License, or
 *     (at your option) any later version.
 *
 *     DSK Play is distributed in the hope that it will be useful,
 *     but WITHOUT ANY WARRANTY; without even the implied warranty of
 *     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *     GNU General Public License for more details.
 *
 *     You should have received a copy of the GNU General Public License
 *     along with this program.  If not, see <https://www.gnu.org/licenses/>.
 *
 *
 *     For more information about DSK Play, including how to contribute,
 *     please visit: https://dskmusic.com or https://github.com/dskmusic
 */

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:dskplay/constants/app_constants.dart';
import 'package:dskplay/models/podcast_model.dart';
import 'package:dskplay/services/podcast_manager.dart';
import 'package:dskplay/utilities/artwork_provider.dart';

String _formatHours(int seconds) {
  final hours = seconds / 3600;
  return '${hours.toStringAsFixed(1).replaceAll('.', ',')} horas';
}

String _monthYearLabel(BuildContext context, int year, int month) {
  final locale = Localizations.localeOf(context).toString();
  final raw = DateFormat.MMM(locale).format(DateTime(year, month));
  return '${raw.replaceAll('.', '').toLowerCase()} $year';
}

/// Podcast listening statistics: total hours and per-subscription/per-year
/// breakdowns, built entirely from [PodcastManager.listenedSecondsByPodcast]
/// / [PodcastManager.listenedSecondsByMonth] (kept forever, unlike the
/// wrapped/Time-Machine song stats which trim old months).
class PodcastStatsPage extends StatelessWidget {
  const PodcastStatsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Estadísticas'),
          bottom: const TabBar(
            tabs: [Tab(text: 'Suscripciones'), Tab(text: 'Años')],
          ),
        ),
        body: const TabBarView(
          children: [_SubscriptionsStatsTab(), _YearsStatsTab()],
        ),
      ),
    );
  }
}

class _EmptyStats extends StatelessWidget {
  const _EmptyStats();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        'Aún no hay estadísticas de reproducción',
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _SubscriptionsStatsTab extends StatelessWidget {
  const _SubscriptionsStatsTab();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Map<String, int>>(
      valueListenable: podcastManager.listenedSecondsByPodcast,
      builder: (context, byPodcast, _) {
        if (byPodcast.isEmpty) return const _EmptyStats();

        return ValueListenableBuilder<Map<String, int>>(
          valueListenable: podcastManager.listenedSecondsByMonth,
          builder: (context, byMonth, _) {
            return ValueListenableBuilder<List<Podcast>>(
              valueListenable: podcastManager.subscriptions,
              builder: (context, subscriptions, _) {
                final totalSeconds = byPodcast.values.fold(
                  0,
                  (sum, value) => sum + value,
                );

                final ranked =
                    subscriptions
                        .where((p) => (byPodcast[p.id] ?? 0) > 0)
                        .toList()
                      ..sort(
                        (a, b) => (byPodcast[b.id] ?? 0).compareTo(
                          byPodcast[a.id] ?? 0,
                        ),
                      );

                final monthKeys = byMonth.keys.toList()..sort();
                String rangeLabel = '';
                if (monthKeys.isNotEmpty) {
                  final first = monthKeys.first.split('-');
                  final last = monthKeys.last.split('-');
                  final start = _monthYearLabel(
                    context,
                    int.parse(first[0]),
                    int.parse(first[1]),
                  );
                  final end = _monthYearLabel(
                    context,
                    int.parse(last[0]),
                    int.parse(last[1]),
                  );
                  rangeLabel = 'Reproducido entre $start y $end';
                }

                return ListView(
                  padding: commonSingleChildScrollViewPadding,
                  children: [
                    const SizedBox(height: 16),
                    _ArcGauge(totalSeconds: totalSeconds, rangeLabel: rangeLabel),
                    const SizedBox(height: 24),
                    for (var i = 0; i < ranked.length; i++)
                      _SubscriptionStatRow(
                        podcast: ranked[i],
                        seconds: byPodcast[ranked[i].id] ?? 0,
                        highlighted: i == 0,
                      ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }
}

class _ArcGauge extends StatelessWidget {
  const _ArcGauge({required this.totalSeconds, required this.rangeLabel});

  final int totalSeconds;
  final String rangeLabel;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Column(
      children: [
        SizedBox(
          height: 150,
          width: double.infinity,
          child: Stack(
            alignment: Alignment.topCenter,
            children: [
              CustomPaint(
                size: const Size(double.infinity, 150),
                painter: _ArcPainter(
                  color: colorScheme.primary,
                  trackColor: colorScheme.surfaceContainerHighest,
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 60),
                child: Text(
                  _formatHours(totalSeconds),
                  style: textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (rangeLabel.isNotEmpty)
          Text(
            rangeLabel,
            style: textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
      ],
    );
  }
}

class _ArcPainter extends CustomPainter {
  _ArcPainter({required this.color, required this.trackColor});

  final Color color;
  final Color trackColor;

  static const _strokeWidth = 14.0;

  @override
  void paint(Canvas canvas, Size size) {
    final maxDiameter = size.width - _strokeWidth;
    final diameter = math.min(maxDiameter, (size.height - _strokeWidth) * 2);
    final rect = Rect.fromLTWH(
      (size.width - diameter) / 2,
      _strokeWidth / 2,
      diameter,
      diameter,
    );

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = _strokeWidth
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, math.pi, math.pi, false, paint);

    final markerCenter = Offset(rect.center.dx + diameter / 2, rect.center.dy);
    canvas.drawCircle(
      markerCenter,
      _strokeWidth * 0.55,
      Paint()..color = trackColor,
    );
  }

  @override
  bool shouldRepaint(covariant _ArcPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.trackColor != trackColor;
}

class _SubscriptionStatRow extends StatelessWidget {
  const _SubscriptionStatRow({
    required this.podcast,
    required this.seconds,
    required this.highlighted,
  });

  final Podcast podcast;
  final int seconds;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image(
          image: ArtworkProvider.get(podcast.image),
          width: 48,
          height: 48,
          fit: BoxFit.cover,
        ),
      ),
      title: Text(podcast.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: highlighted ? colorScheme.primary : colorScheme.outline,
            ),
          ),
          const SizedBox(width: 6),
          Text(_formatHours(seconds)),
        ],
      ),
    );
  }
}

class _YearsStatsTab extends StatelessWidget {
  const _YearsStatsTab();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Map<String, int>>(
      valueListenable: podcastManager.listenedSecondsByMonth,
      builder: (context, byMonth, _) {
        if (byMonth.isEmpty) return const _EmptyStats();

        final sortedKeys = byMonth.keys.toList()..sort();
        final months = [
          for (final key in sortedKeys)
            (
              year: int.parse(key.split('-')[0]),
              month: int.parse(key.split('-')[1]),
              seconds: byMonth[key]!,
            ),
        ];

        final yearTotals = <int, int>{};
        for (final m in months) {
          yearTotals[m.year] = (yearTotals[m.year] ?? 0) + m.seconds;
        }
        final sortedYears = yearTotals.keys.toList()
          ..sort((a, b) => b.compareTo(a));

        final maxHours = months
            .map((m) => m.seconds / 3600)
            .reduce(math.max);
        final niceMax = maxHours <= 0
            ? 30
            : (((maxHours / 30).ceil()) * 30).clamp(30, 1 << 30);

        return ListView(
          padding: commonSingleChildScrollViewPadding,
          children: [
            const SizedBox(height: 16),
            _MonthlyBarChart(months: months, niceMax: niceMax),
            const SizedBox(height: 8),
            Center(
              child: Text(
                'Tiempo reproducido por mes',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Divider(height: 1),
            for (final year in sortedYears)
              ListTile(
                title: Text('$year'),
                subtitle: Text(_formatHours(yearTotals[year]!)),
              ),
          ],
        );
      },
    );
  }
}

typedef _MonthBucket = ({int year, int month, int seconds});

Color _yearColor(ColorScheme colorScheme, List<int> years, int year) {
  final index = years.indexOf(year);
  return index.isEven ? colorScheme.primary : colorScheme.tertiary;
}

class _MonthlyBarChart extends StatelessWidget {
  const _MonthlyBarChart({required this.months, required this.niceMax});

  final List<_MonthBucket> months;
  final int niceMax;

  static const _height = 180.0;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final years = <int>[for (final m in months) m.year].toSet().toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 30,
              height: _height,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('$niceMax', style: textTheme.labelSmall),
                  Text('${niceMax ~/ 2}', style: textTheme.labelSmall),
                  const SizedBox(height: 12),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: SizedBox(
                height: _height,
                child: Stack(
                  children: [
                    const Positioned(top: 0, left: 0, right: 0, child: Divider(height: 1)),
                    Positioned(
                      top: _height / 2,
                      left: 0,
                      right: 0,
                      child: const Divider(height: 1),
                    ),
                    Positioned.fill(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          for (var i = 0; i < months.length; i++) ...[
                            if (i > 0 && months[i].year != months[i - 1].year)
                              Container(
                                width: 1,
                                height: _height,
                                color: colorScheme.outlineVariant,
                              ),
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 1.5,
                                ),
                                child: FractionallySizedBox(
                                  heightFactor:
                                      ((months[i].seconds / 3600) / niceMax)
                                          .clamp(0.01, 1.0),
                                  alignment: Alignment.bottomCenter,
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: _yearColor(
                                        colorScheme,
                                        years,
                                        months[i].year,
                                      ),
                                      borderRadius: const BorderRadius.vertical(
                                        top: Radius.circular(3),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            const SizedBox(width: 38),
            Expanded(
              child: Row(
                children: [
                  for (final year in years)
                    Expanded(
                      flex: months.where((m) => m.year == year).length,
                      child: Text('$year', style: textTheme.labelSmall),
                    ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}
