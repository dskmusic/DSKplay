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
import 'package:dskplay/screens/playlist_page.dart';
import 'package:dskplay/screens/user_songs_page.dart';
import 'package:dskplay/utilities/language_utils.dart';
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';

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

/// Un unico interruptor para los tres sitios donde los podcasts se mezclan
/// con la musica: sugerencias, recientes y maquina del tiempo. Hereda su
/// valor de los dos ajustes separados que habia antes: si alguno estaba
/// apagado, se queda apagado.
final includePodcasts = ValueNotifier<bool>(
  Hive.box('settings').get(
    'includePodcasts',
    defaultValue:
        Hive.box(
          'settings',
        ).get('includePodcastsInTimeMachine', defaultValue: true) &&
        Hive.box(
          'settings',
        ).get('includePodcastsInSuggestions', defaultValue: true),
  ),
);

final rememberLastPlayback = ValueNotifier<bool>(
  Hive.box('settings').get('rememberLastPlayback', defaultValue: true),
);

/// Interruptor de emergencia para los adornos de la página de artista que
/// vienen de YouTube Music: oyentes mensuales, top de canciones con sus
/// reproducciones y artistas relacionados.
///
/// Los saca `lib/services/ytmusic.dart` leyendo los renderers de YouTube
/// Music, que es la única extracción que NO cubre NewPipeExtractor: si Google
/// cambia ese formato, ninguna actualización de NewPipe lo arregla. Cuando
/// dejan de venir, la UI ya los oculta sola; esto es para el otro caso, el de
/// que lleguen pero con datos mal.
///
/// Solo tapa la interfaz: los datos se siguen pidiendo y cacheando, así que
/// volver a activarlo los enseña al momento.
final showArtistExtras = ValueNotifier<bool>(
  Hive.box('settings').get('showArtistExtras', defaultValue: true),
);

/// Which bottom-nav tab the app opens on at cold start (route path, e.g.
/// '/home', '/podcasts'). Read once by NavigationManager's initialLocation -
/// stored in the same 'settings' box as everything else, so it's carried
/// along by export/import and cloud backup for free.
final startScreenSetting = ValueNotifier<String>(
  Hive.box('settings').get('startScreen', defaultValue: '/home'),
);

// Minutes paused (with nothing resuming) before the app closes itself
// outright; 0 means "never". See DskPlayAudioHandler's pause-auto-close
// timer.
final autoCloseAfterPauseMinutes = ValueNotifier<int>(
  Hive.box('settings').get('autoCloseAfterPauseMinutes', defaultValue: 10),
);

// Desvanecido del temporizador de apagado: en vez de cortar de golpe, baja
// el volumen durante los ultimos segundos.
final sleepTimerFadeEnabled = ValueNotifier<bool>(
  Hive.box('settings').get('sleepTimerFadeEnabled', defaultValue: true),
);

final sleepTimerFadeSeconds = ValueNotifier<int>(
  Hive.box('settings').get('sleepTimerFadeSeconds', defaultValue: 20),
);

// Debug: lets you test whether the Dart-only timer above closes the app by
// itself, without the native foreground-service backup (and its notification)
// covering for it if the Flutter engine gets torn down while backgrounded.
final nativeIdleCloseBackupEnabled = ValueNotifier<bool>(
  Hive.box('settings').get('nativeIdleCloseBackupEnabled', defaultValue: true),
);

/// Modo compacto: encoge cabeceras y accesos directos para que entre mas
/// contenido en pantalla. Activado por defecto.
final compactMode = ValueNotifier<bool>(
  Hive.box('settings').get('compactMode', defaultValue: true),
);

/// Escala de la imagen de cabecera de listas, albumes y artistas.
double get compactHeaderScale => compactMode.value ? 0.9 : 1;

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

final volumeNormalizationEnabled = ValueNotifier<bool>(
  Hive.box('settings').get('volumeNormalizationEnabled', defaultValue: false),
);

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

/// Cabeceras de la biblioteca que el usuario ha plegado. Vive en la caja
/// `settings`, asi que entra sola en la copia de seguridad.
final collapsedLibrarySections = ValueNotifier<List<String>>(
  List<String>.from(
    Hive.box('settings').get('collapsedLibrarySections', defaultValue: []),
  ),
);

void toggleLibrarySectionCollapsed(String sectionId) {
  final updated = List<String>.from(collapsedLibrarySections.value);
  if (!updated.remove(sectionId)) updated.add(sectionId);
  collapsedLibrarySections.value = updated;
  Hive.box('settings').put('collapsedLibrarySections', updated);
}

bool isLibrarySectionCollapsed(String sectionId) =>
    collapsedLibrarySections.value.contains(sectionId);

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

/// `ytid` de lo que suena ahora mismo. Lo alimenta el AudioHandler desde el
/// stream de `mediaItem`, así que da igual por qué camino haya empezado la
/// reproducción: las filas de canción lo escuchan para pintar la marca de
/// "sonando".
final nowPlayingYtid = ValueNotifier<String?>(null);

/// Lista, álbum o carpeta de la que salió lo que suena, con las claves
/// `ytid`, `title` y `source`. `null` cuando la reproducción no viene de una
/// lista concreta (una canción suelta, radio...).
/// Se rescata de Hive al arrancar para que el enlace del reproductor siga
/// funcionando con la cancion que se restaura de la sesion anterior.
final nowPlayingSource = ValueNotifier<Map?>(
  Hive.box('user').get('nowPlayingSource') as Map?,
);

var sleepTimerNotifier = ValueNotifier<Duration?>(null);

// Server-Notifiers

final announcementURL = ValueNotifier<String?>(null);
