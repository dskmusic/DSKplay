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
import 'dart:async';

import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:musify/constants/app_constants.dart';
import 'package:musify/database/radio_stations.db.dart';
import 'package:musify/extensions/l10n.dart';
import 'package:musify/main.dart';
import 'package:musify/models/radio_model.dart';
import 'package:musify/services/common_services.dart';
import 'package:musify/services/radio_search_service.dart';
import 'package:musify/utilities/artwork_provider.dart';
import 'package:musify/utilities/flutter_toast.dart';
import 'package:musify/widgets/custom_bar.dart';
import 'package:musify/widgets/mini_player_bottom_space.dart';
import 'package:musify/widgets/radio_station_card.dart';

// Stations without a real image can't use an empty string (ArtworkProvider
// throws on that), so they fall back to the app logo.
const _fallbackStationImage = 'assets/logo.png';

class RadioStationsPage extends StatelessWidget {
  const RadioStationsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n!.radioStations)),
      body: ValueListenableBuilder<List<String>>(
        valueListenable: userHiddenRadioStationIds,
        builder: (context, hiddenIds, _) {
          return ValueListenableBuilder<List<RadioStation>>(
            valueListenable: userCustomRadioStations,
            builder: (context, customStations, _) {
              return ValueListenableBuilder(
                valueListenable: userLikedRadioStations,
                builder: (context, likedStations, _) {
                  final visibleBuiltIn = radioStationsDB
                      .where((s) => !hiddenIds.contains(s.id))
                      .toList();
                  final allStations = _sortWithLikedFirst(
                    [...customStations, ...visibleBuiltIn],
                    likedStations.toSet(),
                  );

                  return SingleChildScrollView(
                    padding: commonSingleChildScrollViewPadding,
                    child: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: CustomBar(
                            context.l10n!.addRadioStation,
                            FluentIcons.add_circle_24_regular,
                            borderRadius: BorderRadius.circular(16),
                            onTap: () => _showAddStationChoice(context),
                          ),
                        ),
                        if (allStations.isEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 40),
                            child: Center(
                              child: Text(context.l10n!.noRadioStations),
                            ),
                          )
                        else
                          ...List.generate(allStations.length, (index) {
                            final station = allStations[index];
                            final isCustom = !radioStationsDB.contains(
                              station,
                            );

                            return Padding(
                              key: ValueKey(station.id),
                              padding: const EdgeInsets.only(bottom: 8),
                              child: GestureDetector(
                                onLongPress: () => _confirmRemoveStation(
                                  context,
                                  station,
                                  isCustom: isCustom,
                                ),
                                child: RadioStationCard(
                                  station: station,
                                  onPressed: () async {
                                    final success = await audioHandler
                                        .playRadioStream(
                                          id: station.id,
                                          name: station.name,
                                          streamUrl: station.streamUrl,
                                          image: station.image,
                                          genre: station.genre,
                                        );

                                    if (!success && context.mounted) {
                                      showToast(
                                        context,
                                        'Failed to play radio station',
                                      );
                                    }
                                  },
                                ),
                              ),
                            );
                          }),
                      ],
                    ),
                  );
                },
              );
            },
          );
        },
      ),
      bottomNavigationBar: const MiniPlayerBottomSpace(),
    );
  }
}

Future<void> _confirmRemoveStation(
  BuildContext context,
  RadioStation station, {
  required bool isCustom,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(context.l10n!.removeStationQuestion),
      content: Text(station.name),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(context.l10n!.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(context.l10n!.confirm),
        ),
      ],
    ),
  );

  if (confirmed != true) return;

  if (isCustom) {
    await removeCustomRadioStation(station.id);
  } else {
    await hideBuiltInRadioStation(station.id);
  }
}

Future<void> _showAddStationChoice(BuildContext context) async {
  final choice = await showDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text(context.l10n!.addRadioStation),
      children: [
        SimpleDialogOption(
          onPressed: () => Navigator.of(context).pop('search'),
          child: Row(
            children: [
              const Icon(FluentIcons.search_24_regular),
              const SizedBox(width: 12),
              Text(context.l10n!.searchStations),
            ],
          ),
        ),
        SimpleDialogOption(
          onPressed: () => Navigator.of(context).pop('manual'),
          child: Row(
            children: [
              const Icon(FluentIcons.edit_24_regular),
              const SizedBox(width: 12),
              Text(context.l10n!.addManually),
            ],
          ),
        ),
      ],
    ),
  );

  if (!context.mounted || choice == null) return;

  if (choice == 'search') {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => const _RadioSearchSheet(),
    );
  } else {
    await _showManualAddDialog(context);
  }
}

Future<void> _showManualAddDialog(BuildContext context) async {
  final nameController = TextEditingController();
  final urlController = TextEditingController();
  final imageController = TextEditingController();
  final genreController = TextEditingController();

  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(context.l10n!.addRadioStation),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: InputDecoration(
                labelText: context.l10n!.stationNameLabel,
              ),
            ),
            TextField(
              controller: urlController,
              decoration: InputDecoration(
                labelText: context.l10n!.stationStreamUrl,
              ),
            ),
            TextField(
              controller: imageController,
              decoration: InputDecoration(
                labelText: context.l10n!.stationImageUrlOptional,
              ),
            ),
            TextField(
              controller: genreController,
              decoration: InputDecoration(
                labelText: context.l10n!.stationGenreOptional,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(context.l10n!.cancel),
        ),
        FilledButton(
          onPressed: () async {
            final name = nameController.text.trim();
            final url = urlController.text.trim();
            if (name.isEmpty || url.isEmpty) {
              showToast(dialogContext, context.l10n!.stationDetailsInvalid);
              return;
            }

            final image = imageController.text.trim();
            final genre = genreController.text.trim();
            await addCustomRadioStation(
              RadioStation(
                id: 'custom_${DateTime.now().millisecondsSinceEpoch}',
                name: name,
                image: image.isNotEmpty ? image : _fallbackStationImage,
                streamUrl: url,
                genre: genre.isNotEmpty ? genre : null,
              ),
            );

            if (dialogContext.mounted) {
              Navigator.of(dialogContext).pop();
              showToast(context, context.l10n!.stationAdded);
            }
          },
          child: Text(context.l10n!.add),
        ),
      ],
    ),
  );
}

class _RadioSearchSheet extends StatefulWidget {
  const _RadioSearchSheet();

  @override
  State<_RadioSearchSheet> createState() => _RadioSearchSheetState();
}

class _RadioSearchSheetState extends State<_RadioSearchSheet> {
  final _controller = TextEditingController();
  List<RadioStation> _results = [];
  bool _loading = false;
  Timer? _debounce;

  @override
  void dispose() {
    _controller.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();

    if (value.trim().isEmpty) {
      setState(() => _results = []);
      return;
    }

    _debounce = Timer(const Duration(milliseconds: 500), () async {
      setState(() => _loading = true);
      final results = await searchRadioBrowserStations(value);
      if (!mounted) return;
      setState(() {
        _results = results;
        _loading = false;
      });
    });
  }

  Future<void> _addStation(RadioStation station) async {
    await addCustomRadioStation(station);
    if (!mounted) return;
    showToast(context, context.l10n!.stationAdded);
  }

  Future<void> _previewStation(RadioStation station) async {
    final success = await audioHandler.playRadioStream(
      id: station.id,
      name: station.name,
      streamUrl: station.streamUrl,
      image: station.image,
      genre: station.genre,
    );
    if (!success && mounted) {
      showToast(context, 'Failed to play radio station');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.7,
        child: Column(
          children: [
            TextField(
              controller: _controller,
              autofocus: true,
              decoration: InputDecoration(
                labelText: context.l10n!.searchStations,
                prefixIcon: const Icon(FluentIcons.search_24_regular),
                border: const OutlineInputBorder(),
              ),
              onChanged: _onChanged,
            ),
            const SizedBox(height: 12),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _results.isEmpty
                  ? Center(child: Text(context.l10n!.noStationsFound))
                  : ListView.separated(
                      itemCount: _results.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 4),
                      itemBuilder: (context, index) {
                        final station = _results[index];
                        return ListTile(
                          leading: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image(
                              image: ArtworkProvider.get(station.image),
                              width: 48,
                              height: 48,
                              fit: BoxFit.cover,
                              errorBuilder: (context, error, stackTrace) =>
                                  Container(
                                    width: 48,
                                    height: 48,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primaryContainer,
                                    child: const Icon(
                                      FluentIcons.sound_source_24_regular,
                                    ),
                                  ),
                            ),
                          ),
                          title: Text(station.name, maxLines: 1),
                          subtitle: station.genre != null
                              ? Text(station.genre!, maxLines: 1)
                              : null,
                          trailing: IconButton(
                            icon: const Icon(
                              FluentIcons.add_circle_24_regular,
                            ),
                            onPressed: () => _addStation(station),
                          ),
                          onTap: () => _previewStation(station),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

List<T> _sortWithLikedFirst<T>(List<T> stations, Set<String> likedIds) {
  final liked = <T>[];
  final rest = <T>[];

  for (final station in stations) {
    final id = (station as dynamic).id as String;
    if (likedIds.contains(id)) {
      liked.add(station);
    } else {
      rest.add(station);
    }
  }

  return [...liked, ...rest];
}
