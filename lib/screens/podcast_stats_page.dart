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
            tabs: [Tab(text: 'Por podcast'), Tab(text: 'Historial')],
          ),
        ),
        body: const TabBarView(
          children: [_SubscriptionsStatsTab(), _HistoryStatsTab()],
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
                return ValueListenableBuilder<List<String>>(
                  valueListenable: podcastManager.playedEpisodeKeys,
                  builder: (context, playedEpisodeKeys, _) {
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
                        _ArcGauge(
                          totalSeconds: totalSeconds,
                          totalEpisodes: playedEpisodeKeys.length,
                          rangeLabel: rangeLabel,
                        ),
                        const SizedBox(height: 24),
                        for (var i = 0; i < ranked.length; i++)
                          _SubscriptionStatRow(
                            podcast: ranked[i],
                            seconds: byPodcast[ranked[i].id] ?? 0,
                            episodes: playedEpisodeKeys
                                .where((k) => k.startsWith('${ranked[i].id}_'))
                                .length,
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
      },
    );
  }
}

class _ArcGauge extends StatelessWidget {
  const _ArcGauge({
    required this.totalSeconds,
    required this.totalEpisodes,
    required this.rangeLabel,
  });

  final int totalSeconds;
  final int totalEpisodes;
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
        Text(
          '$totalEpisodes ${totalEpisodes == 1 ? 'episodio' : 'episodios'}',
          style: textTheme.bodyMedium?.copyWith(
            color: colorScheme.onSurfaceVariant,
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
    required this.episodes,
    required this.highlighted,
  });

  final Podcast podcast;
  final int seconds;
  final int episodes;
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
          Text(
            '${_formatHours(seconds)} · $episodes ${episodes == 1 ? 'episodio' : 'episodios'}',
          ),
        ],
      ),
    );
  }
}

enum _Granularity {
  day('Días', 30),
  week('Semanas', 12),
  month('Meses', 12),
  year('Años', 10);

  const _Granularity(this.label, this.maxBuckets);

  final String label;
  final int maxBuckets;
}

typedef _Bucket = ({DateTime date, int seconds});

class _HistoryStatsTab extends StatefulWidget {
  const _HistoryStatsTab();

  @override
  State<_HistoryStatsTab> createState() => _HistoryStatsTabState();
}

class _HistoryStatsTabState extends State<_HistoryStatsTab> {
  _Granularity _granularity = _Granularity.week;

  List<_Bucket> _buckets(Map<String, int> byDay, Map<String, int> byMonth) {
    switch (_granularity) {
      case _Granularity.day:
        return _recent(byDay.keys, _granularity.maxBuckets)
            .map((k) => (date: DateTime.parse(k), seconds: byDay[k]!))
            .toList();
      case _Granularity.week:
        {
          final totals = <String, int>{};
          for (final entry in byDay.entries) {
            final date = DateTime.parse(entry.key);
            final monday = date.subtract(Duration(days: date.weekday - 1));
            final key = DateFormat('yyyy-MM-dd').format(monday);
            totals[key] = (totals[key] ?? 0) + entry.value;
          }
          return _recent(totals.keys, _granularity.maxBuckets)
              .map((k) => (date: DateTime.parse(k), seconds: totals[k]!))
              .toList();
        }
      case _Granularity.month:
        return _recent(byMonth.keys, _granularity.maxBuckets)
            .map((k) {
              final parts = k.split('-');
              return (
                date: DateTime(int.parse(parts[0]), int.parse(parts[1])),
                seconds: byMonth[k]!,
              );
            })
            .toList();
      case _Granularity.year:
        {
          final totals = <int, int>{};
          for (final entry in byMonth.entries) {
            final year = int.parse(entry.key.split('-')[0]);
            totals[year] = (totals[year] ?? 0) + entry.value;
          }
          return _recent(totals.keys.map((y) => '$y'), _granularity.maxBuckets)
              .map(
                (k) => (date: DateTime(int.parse(k)), seconds: totals[int.parse(k)]!),
              )
              .toList();
        }
    }
  }

  List<String> _recent(Iterable<String> keys, int max) {
    final sorted = keys.toList()..sort();
    return sorted.length > max
        ? sorted.sublist(sorted.length - max)
        : sorted;
  }

  String _label(BuildContext context, List<_Bucket> buckets, int index) {
    final bucket = buckets[index];
    final locale = Localizations.localeOf(context).toString();
    final newYear = index == 0 || buckets[index - 1].date.year != bucket.date.year;
    switch (_granularity) {
      case _Granularity.year:
        return '${bucket.date.year}';
      case _Granularity.month:
        {
          final raw = DateFormat.MMM(
            locale,
          ).format(bucket.date).replaceAll('.', '');
          return newYear ? '$raw ${bucket.date.year}' : raw;
        }
      case _Granularity.day:
      case _Granularity.week:
        {
          final raw = DateFormat(
            'd MMM',
            locale,
          ).format(bucket.date).replaceAll('.', '');
          return newYear ? '$raw ${bucket.date.year}' : raw;
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Map<String, int>>(
      valueListenable: podcastManager.listenedSecondsByDay,
      builder: (context, byDay, _) {
        return ValueListenableBuilder<Map<String, int>>(
          valueListenable: podcastManager.listenedSecondsByMonth,
          builder: (context, byMonth, _) {
            if (byDay.isEmpty && byMonth.isEmpty) return const _EmptyStats();

            final buckets = _buckets(byDay, byMonth);

            return ListView(
              padding: commonSingleChildScrollViewPadding,
              children: [
                const SizedBox(height: 16),
                Center(
                  child: SegmentedButton<_Granularity>(
                    segments: [
                      for (final g in _Granularity.values)
                        ButtonSegment(value: g, label: Text(g.label)),
                    ],
                    selected: {_granularity},
                    onSelectionChanged: (selection) =>
                        setState(() => _granularity = selection.first),
                  ),
                ),
                const SizedBox(height: 24),
                if (buckets.isEmpty)
                  const _EmptyStats()
                else ...[
                  _HistoryBarChart(
                    buckets: buckets,
                    labelBuilder: (i) => _label(context, buckets, i),
                  ),
                  const SizedBox(height: 8),
                  Center(
                    child: Text(
                      'Tiempo reproducido por ${_granularity.label.toLowerCase()}',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ],
            );
          },
        );
      },
    );
  }
}

class _HistoryBarChart extends StatelessWidget {
  const _HistoryBarChart({required this.buckets, required this.labelBuilder});

  final List<_Bucket> buckets;
  final String Function(int index) labelBuilder;

  static const _height = 180.0;
  static const _maxVisibleLabels = 6;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final maxHours = buckets.map((b) => b.seconds / 3600).reduce(math.max);
    final niceMax = _niceMaxHours(maxHours);

    final labelStride = (buckets.length / _maxVisibleLabels).ceil().clamp(
      1,
      1 << 30,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Horas',
          style: textTheme.labelSmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 4),
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
                  Text(_axisLabel(niceMax), style: textTheme.labelSmall),
                  Text(_axisLabel(niceMax / 2), style: textTheme.labelSmall),
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
                    const Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: Divider(height: 1),
                    ),
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
                          for (var i = 0; i < buckets.length; i++)
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 1.5,
                                ),
                                child: FractionallySizedBox(
                                  heightFactor:
                                      ((buckets[i].seconds / 3600) / niceMax)
                                          .clamp(0.01, 1.0),
                                  alignment: Alignment.bottomCenter,
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: i.isEven
                                          ? colorScheme.primary
                                          : colorScheme.tertiary,
                                      borderRadius: const BorderRadius.vertical(
                                        top: Radius.circular(3),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
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
                  for (var i = 0; i < buckets.length; i++)
                    Expanded(
                      child: (i % labelStride == 0 ||
                              i == buckets.length - 1)
                          ? Text(
                              labelBuilder(i),
                              style: textTheme.labelSmall,
                              overflow: TextOverflow.ellipsis,
                            )
                          : const SizedBox.shrink(),
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

// Fixed 30-hour gridlines suited months/years buckets but rendered a whole
// week/day's listening (usually well under an hour) as an invisible sliver -
// round up to whichever of these common step sizes fits, so a bar for a
// few minutes' listening is still readable.
const _niceSteps = [
  0.25,
  0.5,
  1,
  2,
  3,
  5,
  10,
  15,
  20,
  30,
  50,
  75,
  100,
  150,
  200,
  300,
  500,
  750,
  1000,
];

double _niceMaxHours(double maxHours) {
  if (maxHours <= 0) return 1;
  for (final step in _niceSteps) {
    if (maxHours <= step) return step.toDouble();
  }
  return (maxHours / 500).ceil() * 500;
}

String _axisLabel(double hours) {
  if (hours < 1) return '${(hours * 60).round()} min';
  if (hours == hours.roundToDouble()) return '${hours.toInt()}';
  return hours.toStringAsFixed(1).replaceAll('.', ',');
}
