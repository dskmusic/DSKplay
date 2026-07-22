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

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:dskplay/screens/playlist_page.dart';
import 'package:dskplay/screens/user_songs_page.dart';
import 'package:dskplay/utilities/language_utils.dart';

// Preferences

final playNextSongAutomatically = ValueNotifier<bool>(
  Hive.box('settings').get('playNextSongAutomatically', defaultValue: false),
);

final useSystemColor = ValueNotifier<bool>(
  Hive.box('settings').get('useSystemColor', defaultValue: true),
);

final usePureBlackColor = ValueNotifier<bool>(
  Hive.box('settings').get('usePureBlackColor', defaultValue: false),
);

final offlineMode = ValueNotifier<bool>(
  Hive.box('settings').get('offlineMode', defaultValue: false),
);

final wrappedEnabled = ValueNotifier<bool>(
  Hive.box('settings').get('wrappedEnabled', defaultValue: true),
);

final predictiveBack = ValueNotifier<bool>(
  Hive.box('settings').get('predictiveBack', defaultValue: true),
);

final sponsorBlockSupport = ValueNotifier<bool>(
  Hive.box('settings').get('sponsorBlockSupport', defaultValue: false),
);

final externalRecommendations = ValueNotifier<bool>(
  Hive.box('settings').get('externalRecommendations', defaultValue: false),
);

final useProxy = ValueNotifier<bool>(
  Hive.box('settings').get('useProxy', defaultValue: false),
);

final audioQualitySetting = ValueNotifier<String>(
  Hive.box('settings').get('audioQuality', defaultValue: 'high'),
);

List<double> _readEqualizerGains() {
  final raw = Hive.box(
    'settings',
  ).get('equalizerBandGains', defaultValue: const <dynamic>[]);

  if (raw is List) {
    return raw.map((value) => value is num ? value.toDouble() : 0.0).toList();
  }

  return <double>[];
}

final equalizerEnabled = ValueNotifier<bool>(
  Hive.box('settings').get('equalizerEnabled', defaultValue: false),
);

final equalizerBandGains = ValueNotifier<List<double>>(_readEqualizerGains());

Locale languageSetting = getLocaleFromLanguageCode(
  Hive.box(
        'settings',
      ).get('languageCode', defaultValue: detectSystemLanguageCode())
      as String,
);

final themeModeSetting =
    Hive.box('settings').get('themeIndex', defaultValue: 0) as int;

String playlistSortSetting = Hive.box(
  'settings',
).get('playlistSortType', defaultValue: PlaylistSortType.default_.name);

bool playlistSortAscending =
    Hive.box('settings').get('playlistSortAscending', defaultValue: true)
        as bool;

String offlineSortSetting = Hive.box(
  'settings',
).get('offlineSortType', defaultValue: OfflineSortType.default_.name);

bool offlineSortAscending =
    Hive.box('settings').get('offlineSortAscending', defaultValue: true)
        as bool;

Color primaryColorSetting = Color(
  Hive.box('settings').get('accentColor', defaultValue: 0xff91cef4),
);

const karaokeDefaultBackgroundColor = Color(0xFF121212);
const karaokeDefaultActiveLyricColor = Color(0xFF90CAF9);
const karaokeDefaultInactiveLyricColor = Color(0xFF9E9E9E);

final karaokeBackgroundColor = ValueNotifier<Color>(
  Color(
    Hive.box('settings').get(
      'karaokeBackgroundColor',
      defaultValue: karaokeDefaultBackgroundColor.toARGB32(),
    ),
  ),
);

final karaokeActiveLyricColor = ValueNotifier<Color>(
  Color(
    Hive.box('settings').get(
      'karaokeActiveLyricColor',
      defaultValue: karaokeDefaultActiveLyricColor.toARGB32(),
    ),
  ),
);

final karaokeInactiveLyricColor = ValueNotifier<Color>(
  Color(
    Hive.box('settings').get(
      'karaokeInactiveLyricColor',
      defaultValue: karaokeDefaultInactiveLyricColor.toARGB32(),
    ),
  ),
);

void setKaraokeBackgroundColor(Color color) {
  karaokeBackgroundColor.value = color;
  Hive.box('settings').put('karaokeBackgroundColor', color.toARGB32());
}

void setKaraokeActiveLyricColor(Color color) {
  karaokeActiveLyricColor.value = color;
  Hive.box('settings').put('karaokeActiveLyricColor', color.toARGB32());
}

void setKaraokeInactiveLyricColor(Color color) {
  karaokeInactiveLyricColor.value = color;
  Hive.box('settings').put('karaokeInactiveLyricColor', color.toARGB32());
}

void resetKaraokeColors() {
  setKaraokeBackgroundColor(karaokeDefaultBackgroundColor);
  setKaraokeActiveLyricColor(karaokeDefaultActiveLyricColor);
  setKaraokeInactiveLyricColor(karaokeDefaultInactiveLyricColor);
}

final shuffleNotifier = ValueNotifier<bool>(
  Hive.box('settings').get('shuffleEnabled', defaultValue: false),
);

final repeatNotifier = ValueNotifier<AudioServiceRepeatMode>(
  AudioServiceRepeatMode.values[Hive.box(
    'settings',
  ).get('repeatMode', defaultValue: 0)],
);

// Non-storage notifiers

var sleepTimerNotifier = ValueNotifier<Duration?>(null);

// Server-Notifiers

final announcementURL = ValueNotifier<String?>(null);
