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
import 'dart:io';

import 'package:app_links/app_links.dart';
import 'package:audio_service/audio_service.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:dskplay/extensions/l10n.dart';
import 'package:dskplay/localization/app_localizations.dart';
import 'package:dskplay/screens/now_playing_page.dart';
import 'package:dskplay/services/audio_service.dart';
import 'package:dskplay/services/cloud_backup_service.dart';
import 'package:dskplay/services/data_manager.dart';
import 'package:dskplay/services/io_service.dart';
import 'package:dskplay/services/listening_stats_service.dart';
import 'package:dskplay/services/logger_service.dart';
import 'package:dskplay/services/playlist_sharing.dart';
import 'package:dskplay/services/playlists_manager.dart';
import 'package:dskplay/services/router_service.dart';
import 'package:dskplay/services/settings_manager.dart';
import 'package:dskplay/services/update_manager.dart';
import 'package:dskplay/theme/app_themes.dart';
import 'package:dskplay/utilities/flutter_toast.dart';
import 'package:dskplay/utilities/language_utils.dart';
import 'package:dskplay/utilities/playlist_utils.dart';
import 'package:dskplay/utilities/sharing_intent.dart';
import 'package:dskplay/widgets/update_dialog.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

late DskPlayAudioHandler audioHandler;
late StreamSubscription<String?> sharingIntentSubscription;
late StreamSubscription<List<SharedMediaFile>> sharedMediaSubscription;

final logger = Logger();
final appLinks = AppLinks();

class DskPlay extends StatefulWidget {
  const DskPlay({super.key});

  static Future<void> updateAppState(
    BuildContext context, {
    ThemeMode? newThemeMode,
    Locale? newLocale,
    Color? newAccentColor,
    bool? useSystemColor,
  }) async {
    context.findAncestorStateOfType<_DskPlayState>()!.changeSettings(
      newThemeMode: newThemeMode,
      newLocale: newLocale,
      newAccentColor: newAccentColor,
      systemColorStatus: useSystemColor,
    );
  }

  @override
  _DskPlayState createState() => _DskPlayState();
}

class _DskPlayState extends State<DskPlay> with WidgetsBindingObserver {
  void changeSettings({
    ThemeMode? newThemeMode,
    Locale? newLocale,
    Color? newAccentColor,
    bool? systemColorStatus,
  }) {
    setState(() {
      if (newThemeMode != null) {
        themeMode = newThemeMode;
        brightness = getBrightnessFromThemeMode(newThemeMode);
      }
      if (newLocale != null) {
        languageSetting = newLocale;
      }
      if (newAccentColor != null) {
        if (systemColorStatus != null &&
            useSystemColor.value != systemColorStatus) {
          useSystemColor.value = systemColorStatus;
          addOrUpdateData<bool>(
            'settings',
            'useSystemColor',
            systemColorStatus,
          );
        }
        primaryColorSetting = newAccentColor;
      }
    });
  }

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);

    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

    final platformDispatcher = PlatformDispatcher.instance;

    // This callback is called every time the brightness changes.
    platformDispatcher.onPlatformBrightnessChanged = () {
      if (themeMode == ThemeMode.system) {
        setState(() {
          brightness = platformDispatcher.platformBrightness;
        });
      }
    };

    offlineMode.addListener(_onOfflineModeChanged);

    sharingIntentSubscription = ReceiveSharingIntent.getTextStream().listen(
      (String? value) async {
        await consumeYoutubeSharedTextIntent(
          value,
          audioHandler: audioHandler,
          onError: (error, stackTrace) {
            logger.log(
              'Error while playing shared song:',
              error: error,
              stackTrace: stackTrace,
            );
          },
        );
      },
      onError: (err) {
        logger.log('getTextStream error:', error: err);
      },
    );

    sharedMediaSubscription = ReceiveSharingIntent.getMediaStream().listen(
      (List<SharedMediaFile> mediaList) async {
        for (final media in mediaList) {
          final started = await consumeSharedAudioFile(
            media.path,
            audioHandler: audioHandler,
            onError: (error, stackTrace) {
              logger.log(
                'Error while playing opened/shared audio file:',
                error: error,
                stackTrace: stackTrace,
              );
            },
          );
          if (started) _openNowPlayingFromExternalFile();
        }
      },
      onError: (err) {
        logger.log('getMediaStream error:', error: err);
      },
    );

    ReceiveSharingIntent.getInitialMedia().then((mediaList) async {
      for (final media in mediaList) {
        final started = await consumeSharedAudioFile(
          media.path,
          audioHandler: audioHandler,
          onError: (error, stackTrace) {
            logger.log(
              'Error while playing initial shared audio file:',
              error: error,
              stackTrace: stackTrace,
            );
          },
        );
        if (started) _openNowPlayingFromExternalFile();
      }
    });

    try {
      LicenseRegistry.addLicense(() async* {
        final license = await rootBundle.loadString(
          'assets/licenses/paytone.txt',
        );
        yield LicenseEntryWithLineBreaks(['paytoneOne'], license);
      });
    } catch (e, stackTrace) {
      logger.log(
        'License Registration Error',
        error: e,
        stackTrace: stackTrace,
      );
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => _checkForUpdateSilently());
  }

  void _openNowPlayingFromExternalFile() {
    final context = NavigationManager().context;
    if (context.mounted) Navigator.of(context).push(createNowPlayingRoute());
  }

  Future<void> _checkForUpdateSilently() async {
    final info = await checkForUpdate();
    if (info == null) return;
    final context = NavigationManager().context;
    if (context.mounted) await showUpdateAvailableDialog(context, info);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // Persist listening stats when the app leaves the foreground. This is the
    // reliable moment to snapshot and flush: unlike widget dispose, these
    // callbacks are delivered before the OS suspends or terminates the process.
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      listeningStatsService.recordListeningSessionProgress(
        wasPlaying: audioHandler.audioPlayer.playing,
      );
      unawaited(listeningStatsService.flush());
      unawaited(cloudBackupService.uploadBackup());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    offlineMode.removeListener(_onOfflineModeChanged);

    Hive.close();
    sharingIntentSubscription.cancel();
    sharedMediaSubscription.cancel();
    super.dispose();
  }

  void _onOfflineModeChanged() {
    // Force rebuild when offline mode changes
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return DynamicColorBuilder(
      builder: (lightColorScheme, darkColorScheme) {
        final colorScheme = getAppColorScheme(
          lightColorScheme,
          darkColorScheme,
        );

        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            // A transparent nav bar color is silently ignored on recent
            // Android versions (edge-to-edge enforcement), which then just
            // falls back to a light default instead of matching the theme -
            // an explicit color is required to reliably get a dark bar in
            // dark theme.
            systemNavigationBarColor: brightness == Brightness.dark
                ? Colors.black
                : Colors.white,
            systemNavigationBarContrastEnforced: false,
            statusBarBrightness: brightness == Brightness.dark
                ? Brightness.light
                : Brightness.dark,
            statusBarIconBrightness: brightness == Brightness.dark
                ? Brightness.light
                : Brightness.dark,
            systemNavigationBarIconBrightness: brightness == Brightness.dark
                ? Brightness.light
                : Brightness.dark,
          ),
          child: MaterialApp.router(
            themeMode: themeMode,
            darkTheme: getAppTheme(colorScheme),
            theme: getAppTheme(colorScheme),
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: appSupportedLocales,
            locale: languageSetting,
            routerConfig: NavigationManager.router,
          ),
        );
      },
    );
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _AppBootstrap());
}

class _AppBootstrap extends StatefulWidget {
  const _AppBootstrap();

  @override
  State<_AppBootstrap> createState() => _AppBootstrapState();
}

class _AppBootstrapState extends State<_AppBootstrap> {
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    initialisation().then((_) {
      if (mounted) setState(() => _ready = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    return _ready ? const DskPlay() : const _SplashScreen();
  }
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    final isDark =
        WidgetsBinding.instance.platformDispatcher.platformBrightness ==
        Brightness.dark;
    // Matches the native Android splash background so there's no color
    // flash handing off from it to this widget-based splash.
    final backgroundColor = isDark
        ? const Color(0xff151515)
        : const Color(0xfff9fafd);
    // Settings (and therefore the user's accent color) aren't loaded yet at
    // this point, so a fixed color is used instead of `primaryColorSetting`.
    const splashAccentColor = Color(0xff91cef4);

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: backgroundColor,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: const [
              Text(
                'DSK Play',
                style: TextStyle(
                  fontSize: 30,
                  fontFamily: 'paytoneOne',
                  fontWeight: FontWeight.w500,
                  color: splashAccentColor,
                  letterSpacing: -0.5,
                ),
              ),
              SizedBox(height: 4),
              Text(
                'by DSK',
                style: TextStyle(fontSize: 12, color: splashAccentColor),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> initialisation() async {
  try {
    await Hive.initFlutter();

    await Future.wait([
      Hive.openBox('settings'),
      Hive.openBox('user'),
      Hive.openBox('userNoBackup'),
      Hive.openBox('cache'),
    ]);

    onUserDataChanged = cloudBackupService.scheduleAutoBackup;
    unawaited(cloudBackupService.init());

    audioHandler = await AudioService.init(
      builder: DskPlayAudioHandler.new,
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.dskmusic.dskplay',
        androidNotificationChannelName: 'DSK Play',
        androidNotificationIcon: 'drawable/notification_icon',
        androidShowNotificationBadge: true,
        androidStopForegroundOnPause: false,
      ),
    );

    // Init router
    NavigationManager.instance;

    try {
      // Listen to incoming links while app is running
      appLinks.uriLinkStream.listen(
        handleIncomingLink,
        onError: (err) {
          logger.log('URI link error:', error: err);
        },
      );
    } on PlatformException {
      logger.log('Failed to get initial uri');
    }
  } catch (e, stackTrace) {
    logger.log('Initialization Error', error: e, stackTrace: stackTrace);
  }

  final oldInternalDirPath = (await getApplicationDocumentsDirectory()).path;
  applicationDirPath = offlineMusicDirPath;

  try {
    // Only migrate/create eagerly if permission was already granted in a
    // previous session (e.g. via the "download to device" feature); avoid
    // prompting for the "All files access" permission on every cold start.
    if (await Permission.manageExternalStorage.isGranted) {
      await FilePaths.ensureDirectoriesExist();
      await _migrateOfflineFilesToExternalStorage(oldInternalDirPath);
    }
  } catch (e, stackTrace) {
    logger.log(
      'Error preparing external offline storage',
      error: e,
      stackTrace: stackTrace,
    );
  }
}

/// One-time move of offline songs/artwork downloaded before this app version
/// (internal, private storage) to the new external DSKplay/Offline folder,
/// so they aren't silently orphaned by the storage-location change.
Future<void> _migrateOfflineFilesToExternalStorage(
  String oldRootPath,
) async {
  if (oldRootPath == applicationDirPath) return;

  for (final subdir in [FilePaths.tracksDir, FilePaths.artworksDir]) {
    final oldDir = Directory('$oldRootPath/$subdir');
    if (!await oldDir.exists()) continue;

    final newDir = Directory('$applicationDirPath/$subdir');
    await newDir.create(recursive: true);

    await for (final entity in oldDir.list()) {
      if (entity is! File) continue;
      final newPath = '${newDir.path}/${entity.uri.pathSegments.last}';
      try {
        if (!await File(newPath).exists()) {
          await entity.copy(newPath);
        }
        await entity.delete();
      } catch (e, stackTrace) {
        logger.log(
          'Error migrating offline file ${entity.path}',
          error: e,
          stackTrace: stackTrace,
        );
      }
    }

    try {
      if (await oldDir.list().isEmpty) await oldDir.delete();
    } catch (_) {}
  }
}

void handleIncomingLink(Uri? uri) async {
  if (uri == null || uri.scheme != 'dskplay' || uri.host != 'playlist') return;

  if (uri.pathSegments.length < 2 || uri.pathSegments[0] != 'custom') return;

  try {
    final encodedPlaylist = uri.pathSegments[1];
    final playlist = await PlaylistSharingService.decodeAndExpandPlaylist(
      encodedPlaylist,
    );

    if (playlist == null) {
      _showPlaylistError();
      return;
    }

    // Ensure the incoming playlist has a unique id so it can be removed later
    if (playlist['ytid'] == null || playlist['ytid'].toString().isEmpty) {
      playlist['ytid'] = PlaylistUtils.generateCustomPlaylistId();
    }

    // Check for duplicate by title and song ytids
    final incomingYtids = (playlist['list'] as List<dynamic>)
        .map((s) => s['ytid'].toString())
        .toList();

    final isDuplicate = PlaylistUtils.playlistExists(
      playlist,
      incomingYtids,
      userCustomPlaylists.value,
    );

    if (isDuplicate) {
      showToast(
        NavigationManager().context,
        NavigationManager().context.l10n!.playlistAlreadyExists,
      );
    } else {
      userCustomPlaylists.value = [...userCustomPlaylists.value, playlist];
      unawaited(
        addOrUpdateData<List>(
          'user',
          'customPlaylists',
          userCustomPlaylists.value,
        ),
      );
      showToast(
        NavigationManager().context,
        '${NavigationManager().context.l10n!.addedSuccess}!',
      );
    }
  } catch (e) {
    _showPlaylistError();
  }
}

void _showPlaylistError() {
  showToast(
    NavigationManager().context,
    NavigationManager().context.l10n!.failedToLoadPlaylist,
  );
}
