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

import 'package:file_picker/file_picker.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:go_router/go_router.dart';
import 'package:dskplay/constants/app_constants.dart';
import 'package:dskplay/extensions/l10n.dart';
import 'package:dskplay/main.dart';
import 'package:dskplay/screens/bottom_navigation_page.dart';
import 'package:dskplay/screens/search_page.dart';
import 'package:dskplay/services/antennapod_import_service.dart';
import 'package:dskplay/services/common_services.dart';
import 'package:dskplay/services/data_manager.dart';
import 'package:dskplay/services/listening_stats_service.dart';
import 'package:dskplay/services/playlist_download_service.dart';
import 'package:dskplay/services/playlists_manager.dart';
import 'package:dskplay/services/router_service.dart';
import 'package:dskplay/services/settings_manager.dart';
import 'package:dskplay/services/update_manager.dart';
import 'package:dskplay/theme/app_colors.dart';
import 'package:dskplay/theme/app_themes.dart';
import 'package:dskplay/utilities/flutter_bottom_sheet.dart';
import 'package:dskplay/utilities/flutter_toast.dart';
import 'package:dskplay/utilities/language_utils.dart';
import 'package:dskplay/utilities/url_launcher.dart';
import 'package:dskplay/widgets/backup_section.dart';
import 'package:dskplay/widgets/bottom_sheet_bar.dart';
import 'package:dskplay/widgets/confirmation_dialog.dart';
import 'package:dskplay/widgets/custom_bar.dart';
import 'package:dskplay/widgets/mini_player_bottom_space.dart';
import 'package:dskplay/widgets/section_header.dart';
import 'package:dskplay/widgets/update_dialog.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final primaryColor = Theme.of(context).colorScheme.primary;
    final activatedColor = Theme.of(context).colorScheme.secondaryContainer;
    final inactivatedColor = Theme.of(context).colorScheme.surfaceContainerHigh;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) BottomNavigationPage.handleBackPress(context);
      },
      child: Scaffold(
      appBar: AppBar(title: Text(context.l10n!.settings)),
      body: SingleChildScrollView(
        padding: commonSingleChildScrollViewPadding,
        child: Column(
          children: <Widget>[
            _buildPreferencesSection(
              context,
              primaryColor,
              activatedColor,
              inactivatedColor,
            ),
            if (!offlineMode.value) _buildOnlineFeaturesSection(context),
            _buildOthersSection(context),
            const SizedBox(height: 20),
            const MiniPlayerBottomSpace(),
          ],
        ),
      ),
      ),
    );
  }

  Widget _buildPreferencesSection(
    BuildContext context,
    Color primaryColor,
    Color activatedColor,
    Color inactivatedColor,
  ) {
    final isOffline = offlineMode.value;

    return Column(
      children: [
        SectionHeader(
          title: context.l10n!.preferences,
          icon: FluentIcons.options_24_filled,
        ),
        CustomBar(
          context.l10n!.accentColor,
          FluentIcons.color_24_regular,
          borderRadius: commonCustomBarRadiusFirst,
          onTap: () => _showAccentColorPicker(context),
        ),
        CustomBar(
          context.l10n!.themeMode,
          FluentIcons.weather_sunny_28_regular,
          onTap: () => _showThemeModePicker(context),
        ),
        CustomBar(
          context.l10n!.language,
          FluentIcons.translate_24_regular,
          onTap: () => _showLanguagePicker(context),
        ),
        CustomBar(
          context.l10n!.audioQuality,
          FluentIcons.music_note_1_24_regular,
          onTap: () => _showAudioQualityPicker(context),
        ),
        CustomBar(
          context.l10n!.equalizer,
          FluentIcons.data_histogram_24_regular,
          onTap: () => context.push('/settings/equalizer'),
        ),
        ValueListenableBuilder<bool>(
          valueListenable: volumeNormalizationEnabled,
          builder: (_, value, __) {
            return CustomBar(
              'Normalización de volumen',
              FluentIcons.speaker_2_24_regular,
              description: 'Iguala el volumen entre canciones',
              trailing: Switch(
                value: value,
                onChanged: (value) => _toggleVolumeNormalization(context, value),
              ),
            );
          },
        ),
        CustomBar(
          context.l10n!.dynamicColor,
          FluentIcons.toggle_left_24_regular,
          trailing: Switch(
            value: useSystemColor.value,
            onChanged: (value) => _toggleSystemColor(context, value),
          ),
        ),
        ValueListenableBuilder<bool>(
          valueListenable: predictiveBack,
          builder: (_, value, __) {
            return CustomBar(
              context.l10n!.predictiveBack,
              FluentIcons.position_backward_24_regular,
              trailing: Switch(
                value: value,
                onChanged: (value) => _togglePredictiveBack(context, value),
              ),
            );
          },
        ),
        ValueListenableBuilder<bool>(
          valueListenable: useProxy,
          builder: (_, value, __) {
            return CustomBar(
              context.l10n!.useProxy,
              FluentIcons.shield_24_regular,
              description: context.l10n!.useProxyDescription,
              trailing: Switch(
                value: value,
                onChanged: (value) {
                  useProxy.value = value;
                  addOrUpdateData<bool>('settings', 'useProxy', value);
                  showToast(context, context.l10n!.settingChangedMsg);
                },
              ),
            );
          },
        ),
        ValueListenableBuilder<bool>(
          valueListenable: wrappedEnabled,
          builder: (_, value, __) {
            return CustomBar(
              context.l10n!.listeningStats,
              FluentIcons.clock_24_regular,
              description: context.l10n!.listeningStatsDescription,
              trailing: Switch(
                value: value,
                onChanged: (value) => _toggleWrapped(context, value),
              ),
            );
          },
        ),
        ValueListenableBuilder<bool>(
          valueListenable: includePodcastsInTimeMachine,
          builder: (_, value, __) {
            return CustomBar(
              'Incluir podcasts en máquina del tiempo',
              FluentIcons.mic_24_regular,
              description:
                  'Muestra u oculta los podcasts en las estadísticas de máquina del tiempo',
              trailing: Switch(
                value: value,
                onChanged: (value) =>
                    _toggleIncludePodcastsInTimeMachine(context, value),
              ),
            );
          },
        ),
        ValueListenableBuilder<bool>(
          valueListenable: showArtistExtras,
          builder: (_, value, __) {
            return CustomBar(
              'Datos extra de artista',
              FluentIcons.person_24_regular,
              description:
                  'Oyentes mensuales, top de canciones con reproducciones y '
                  'artistas relacionados. Desactivalo si YouTube cambia algo y '
                  'salen mal: los albumes y las canciones no se ven afectados',
              trailing: Switch(
                value: value,
                onChanged: (value) => _toggleShowArtistExtras(context, value),
              ),
            );
          },
        ),
        ValueListenableBuilder<bool>(
          valueListenable: rememberLastPlayback,
          builder: (_, value, __) {
            return CustomBar(
              context.l10n!.rememberLastPlayback,
              FluentIcons.arrow_clockwise_24_regular,
              description: context.l10n!.rememberLastPlaybackDescription,
              trailing: Switch(
                value: value,
                onChanged: (value) => _toggleRememberLastPlayback(context, value),
              ),
            );
          },
        ),
        ValueListenableBuilder<int>(
          valueListenable: autoCloseAfterPauseMinutes,
          builder: (_, value, __) {
            return CustomBar(
              'Cierre automático por inactividad',
              FluentIcons.timer_24_regular,
              description: value <= 0
                  ? 'Nunca se cierra sola'
                  : 'Se cierra tras $value min inactiva',
              onTap: () => _showAutoCloseAfterPausePicker(context),
            );
          },
        ),
        ValueListenableBuilder<bool>(
          valueListenable: nativeIdleCloseBackupEnabled,
          builder: (_, value, __) {
            return CustomBar(
              'Respaldo nativo del cierre automático',
              FluentIcons.shield_task_24_regular,
              description:
                  'Servicio que mantiene el proceso vivo (con su propia '
                  'notificación) para garantizar el cierre automático. '
                  'Desactívalo solo para comprobar si el temporizador '
                  'funciona por sí solo',
              trailing: Switch(
                value: value,
                onChanged: (value) =>
                    _toggleNativeIdleCloseBackup(context, value),
              ),
            );
          },
        ),
        ValueListenableBuilder<String>(
          valueListenable: startScreenSetting,
          builder: (_, value, __) {
            return CustomBar(
              'Pantalla de inicio',
              FluentIcons.home_24_regular,
              description: _startScreenLabel(context, value),
              onTap: () => _showStartScreenPicker(context),
            );
          },
        ),
        ValueListenableBuilder<bool>(
          valueListenable: offlineMode,
          builder: (_, value, __) {
            return CustomBar(
              context.l10n!.offlineMode,
              FluentIcons.cloud_off_24_regular,
              description: context.l10n!.offlineModeDescription,
              borderRadius: isOffline
                  ? commonCustomBarRadiusLast
                  : BorderRadius.zero,
              trailing: Switch(
                value: value,
                onChanged: (value) => _toggleOfflineMode(context, value),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildOnlineFeaturesSection(BuildContext context) {
    return Column(
      children: [
        ValueListenableBuilder<bool>(
          valueListenable: sponsorBlockSupport,
          builder: (_, value, __) {
            return CustomBar(
              'SponsorBlock',
              FluentIcons.cut_24_regular,
              description: context.l10n!.sponsorBlockDescription,
              trailing: Switch(
                value: value,
                onChanged: (value) => _toggleSponsorBlock(context, value),
              ),
            );
          },
        ),
        ValueListenableBuilder<bool>(
          valueListenable: playNextSongAutomatically,
          builder: (_, value, __) {
            return CustomBar(
              context.l10n!.automaticSongPicker,
              FluentIcons.music_note_2_play_20_regular,
              description: context.l10n!.automaticSongPickerDescription,
              trailing: Switch(
                value: value,
                onChanged: (value) {
                  _toggleAutoPlayNext(context, value);
                  showToast(context, context.l10n!.settingChangedMsg);
                },
              ),
            );
          },
        ),
        ValueListenableBuilder<bool>(
          valueListenable: externalRecommendations,
          builder: (_, value, __) {
            return CustomBar(
              context.l10n!.externalRecommendations,
              FluentIcons.channel_share_24_regular,
              description: context.l10n!.externalRecommendationsDescription,
              borderRadius: commonCustomBarRadiusLast,
              trailing: Switch(
                value: value,
                onChanged: (value) =>
                    _toggleExternalRecommendations(context, value),
              ),
            );
          },
        ),

        _buildToolsSection(context),
        _buildSponsorSection(context),
      ],
    );
  }

  Widget _buildToolsSection(BuildContext context) {
    return Column(
      children: [
        SectionHeader(
          title: context.l10n!.tools,
          icon: FluentIcons.toolbox_24_filled,
        ),
        CustomBar(
          context.l10n!.clearCache,
          FluentIcons.broom_24_regular,
          borderRadius: commonCustomBarRadiusFirst,
          onTap: () async {
            final cleared = await clearCache();
            showToast(
              context,
              cleared ? '${context.l10n!.cacheMsg}!' : context.l10n!.error,
            );
          },
        ),
        CustomBar(
          context.l10n!.clearSearchHistory,
          FluentIcons.history_24_regular,
          onTap: () => _showConfirmationDialog(
            context: context,
            confirmationMessage: context.l10n!.clearSearchHistoryQuestion,
            onSubmit: () {
              searchHistoryNotifier.value = [];
              deleteData('user', 'searchHistory');
              showToast(context, '${context.l10n!.searchHistoryMsg}!');
            },
          ),
        ),
        CustomBar(
          context.l10n!.clearRecentlyPlayed,
          FluentIcons.receipt_play_24_regular,
          onTap: () => _showConfirmationDialog(
            context: context,
            confirmationMessage: context.l10n!.clearRecentlyPlayedQuestion,
            onSubmit: () {
              userRecentlyPlayed.value = [];
              deleteData('user', 'recentlyPlayedSongs');
              showToast(context, '${context.l10n!.recentlyPlayedMsg}!');
            },
          ),
        ),
        CustomBar(
          context.l10n!.clearListeningStats,
          FluentIcons.clock_24_regular,
          onTap: () => _showConfirmationDialog(
            context: context,
            confirmationMessage: context.l10n!.clearListeningStatsQuestion,
            submitMessage: context.l10n!.delete,
            isDangerous: true,
            onSubmit: () async {
              audioHandler.resetListeningStatsSession(flushStats: false);
              await listeningStatsService.clearStats();
              audioHandler.startListeningStatsSessionIfNeeded();
              if (context.mounted) {
                showToast(context, '${context.l10n!.listeningStatsCleared}!');
              }
            },
          ),
        ),
        CustomBar(
          context.l10n!.deleteDownloads,
          FluentIcons.delete_24_regular,
          onTap: () => _showConfirmationDialog(
            context: context,
            confirmationMessage: context.l10n!.deleteDownloadsQuestion,
            submitMessage: context.l10n!.delete,
            isDangerous: true,
            onSubmit: () async {
              try {
                await offlinePlaylistService.deleteAllDownloads();
                if (context.mounted) {
                  showToast(context, context.l10n!.downloadsDeleted);
                }
              } catch (e) {
                if (context.mounted) {
                  showToast(context, context.l10n!.error);
                }
              }
            },
          ),
        ),
        const BackupSection(),
        CustomBar(
          'Exportar datos (listas, podcasts, etc.)',
          FluentIcons.arrow_export_24_regular,
          onTap: () async {
            try {
              final result = await exportUserDataToFile(context);
              if (context.mounted) {
                showToast(
                  context,
                  result.message,
                  icon: result.success
                      ? null
                      : FluentIcons.error_circle_24_regular,
                );
              }
            } catch (e, str) {
              logger.log('Error exporting user data', error: e, stackTrace: str);
              if (context.mounted) {
                showToast(
                  context,
                  context.l10n!.error,
                  icon: FluentIcons.error_circle_24_regular,
                );
              }
            }
          },
        ),
        CustomBar(
          'Importar datos (listas, podcasts, etc.)',
          FluentIcons.arrow_import_24_regular,
          onTap: () async {
            final confirmed = await _showImportConfirmation(
              context,
              'Esto añadirá las listas y los datos de podcast del archivo '
              'seleccionado a los que ya tienes. No se sobrescribirá ni se '
              'borrará nada existente.',
            );
            if (confirmed != true || !context.mounted) return;

            try {
              final result = await importUserDataFromFile(context);
              if (context.mounted) {
                showToast(
                  context,
                  result.message,
                  icon: result.success
                      ? null
                      : FluentIcons.error_circle_24_regular,
                );
              }
            } catch (e, str) {
              logger.log('Error importing user data', error: e, stackTrace: str);
              if (context.mounted) {
                showToast(
                  context,
                  context.l10n!.error,
                  icon: FluentIcons.error_circle_24_regular,
                );
              }
            }
          },
        ),
        CustomBar(
          'Importar desde otra app',
          FluentIcons.arrow_import_24_regular,
          description: 'Migra suscripciones y estadísticas desde un backup'
              ' (.db) de AntennaPod',
          borderRadius: commonCustomBarRadiusLast,
          onTap: () => _importFromOtherApp(context),
        ),
      ],
    );
  }

  Future<bool?> _showImportConfirmation(
    BuildContext context,
    String message,
  ) {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => ConfirmationDialog(
        confirmationMessage: message,
        submitMessage: context.l10n!.confirm,
        onCancel: () => Navigator.of(dialogContext).pop(false),
        onSubmit: () => Navigator.of(dialogContext).pop(true),
      ),
    );
  }

  Future<void> _importFromOtherApp(BuildContext context) async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['db'],
    );
    final path = result?.files.firstOrNull?.path;
    if (path == null) return;

    late final AntennaPodImportPreview preview;
    try {
      preview = analyzeAntennaPodBackup(path);
    } catch (e, str) {
      logger.log('Error analyzing AntennaPod backup', error: e, stackTrace: str);
      if (context.mounted) {
        showToast(
          context,
          'No se ha podido leer el archivo seleccionado',
          icon: FluentIcons.error_circle_24_regular,
        );
      }
      return;
    }

    if (!context.mounted) return;
    if (preview.podcastCount == 0) {
      showToast(
        context,
        'No se han encontrado podcasts en el archivo seleccionado',
        icon: FluentIcons.error_circle_24_regular,
      );
      return;
    }

    final confirmed = await _showImportConfirmation(
      context,
      'Se encontraron ${preview.podcastCount} podcasts, '
      '${preview.listenedEpisodeCount} episodios escuchados y '
      '${preview.totalListenedHours.toStringAsFixed(1)} horas de '
      'reproducción. Esto se añadirá a tus datos actuales sin '
      'sobrescribir ni borrar nada existente.',
    );
    if (confirmed != true || !context.mounted) return;

    try {
      await applyAntennaPodImport(preview);
      if (context.mounted) {
        showToast(context, '${context.l10n!.restoredSuccess}!');
      }
    } catch (e, str) {
      logger.log('Error importing AntennaPod backup', error: e, stackTrace: str);
      if (context.mounted) {
        showToast(
          context,
          context.l10n!.error,
          icon: FluentIcons.error_circle_24_regular,
        );
      }
    }
  }

  Widget _buildSponsorSection(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Column(
      children: [
        SectionHeader(
          title: context.l10n!.becomeSponsor,
          icon: FluentIcons.heart_24_filled,
        ),
        Card(
          margin: const EdgeInsets.only(bottom: 3),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(15),
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(15)),
            child: Material(
              color: colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(15),
              child: InkWell(
                borderRadius: BorderRadius.circular(15),
                onTap: () => launchURL(Uri.parse('https://ko-fi.com/dskmusic')),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 12,
                    horizontal: 16,
                  ),
                  child: SizedBox(
                    height: 45,
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: colorScheme.onPrimaryContainer.withValues(
                              alpha: 0.15,
                            ),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            FluentIcons.heart_24_regular,
                            color: colorScheme.onPrimaryContainer,
                            size: 24,
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Text(
                            context.l10n!.sponsorProject,
                            style: TextStyle(
                              color: colorScheme.onPrimaryContainer,
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: colorScheme.onPrimaryContainer.withValues(
                              alpha: 0.1,
                            ),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(
                            FluentIcons.arrow_right_24_regular,
                            color: colorScheme.onPrimaryContainer,
                            size: 16,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildOthersSection(BuildContext context) {
    return Column(
      children: [
        SectionHeader(
          title: context.l10n!.others,
          icon: FluentIcons.more_circle_24_filled,
        ),
        CustomBar(
          context.l10n!.licenses,
          FluentIcons.document_24_regular,
          borderRadius: commonCustomBarRadiusFirst,
          onTap: () => NavigationManager.router.go('/settings/license'),
        ),
        CustomBar(
          '${context.l10n!.copyLogs} (${logger.getLogCount()})',
          FluentIcons.error_circle_24_regular,
          onTap: () async => showToast(context, await logger.copyLogs(context)),
        ),
        CustomBar(
          context.l10n!.checkForUpdates,
          FluentIcons.arrow_sync_24_regular,
          onTap: () => _checkForUpdates(context),
        ),
        CustomBar(
          context.l10n!.about,
          FluentIcons.book_information_24_regular,
          borderRadius: commonCustomBarRadiusLast,
          onTap: () => NavigationManager.router.go('/settings/about'),
        ),
      ],
    );
  }

  Future<void> _checkForUpdates(BuildContext context) async {
    final info = await checkForUpdate(ignoreDismissed: true);
    if (!context.mounted) return;
    if (info == null) {
      showToast(context, context.l10n!.noUpdatesAvailable);
      return;
    }
    await showUpdateAvailableDialog(context, info);
  }

  void _showAccentColorPicker(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // Last preset is replaced by a rainbow tile that opens a full color
    // picker instead of a fixed swatch.
    final presetColors = availableColors.sublist(
      0,
      availableColors.length - 1,
    );

    showCustomBottomSheet(
      context,
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: GridView.builder(
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 5,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
          ),
          shrinkWrap: true,
          physics: const BouncingScrollPhysics(),
          itemCount: presetColors.length + 1,
          itemBuilder: (context, index) {
            if (index == presetColors.length) {
              return GestureDetector(
                onTap: () => _pickCustomColor(context),
                child: Container(
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: SweepGradient(
                      colors: [
                        Colors.red,
                        Colors.yellow,
                        Colors.green,
                        Colors.cyan,
                        Colors.blue,
                        Colors.purple,
                        Colors.red,
                      ],
                    ),
                  ),
                  child: const Icon(
                    FluentIcons.color_24_filled,
                    color: Colors.white,
                    size: 22,
                  ),
                ),
              );
            }

            final color = presetColors[index];
            final isSelected = color == primaryColorSetting;

            return GestureDetector(
              onTap: () {
                addOrUpdateData<int>(
                  'settings',
                  'accentColor',
                  color.toARGB32(),
                );
                DskPlay.updateAppState(
                  context,
                  newAccentColor: color,
                  useSystemColor: false,
                );
                showToast(context, context.l10n!.accentChangeMsg);
                closeCurrentBottomSheet();
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: isSelected
                      ? Border.all(color: colorScheme.onSurface, width: 3)
                      : null,
                ),
                child: isSelected
                    ? Icon(
                        FluentIcons.checkmark_20_filled,
                        color: color.computeLuminance() > 0.5
                            ? Colors.black
                            : Colors.white,
                        size: 24,
                      )
                    : null,
              ),
            );
          },
        ),
      ),
    );
  }

  void _showThemeModePicker(BuildContext context) {
    final isAmoled = usePureBlackColor.value;

    showCustomBottomSheet(
      context,
      ListView(
        shrinkWrap: true,
        physics: const BouncingScrollPhysics(),
        padding: commonListViewBottomPadding,
        children: [
          BottomSheetBar(
            context.l10n!.themeModeSystem,
            () => _selectThemeMode(context, ThemeMode.system, amoled: false),
            themeMode == ThemeMode.system,
            icon: FluentIcons.phone_24_regular,
          ),
          BottomSheetBar(
            context.l10n!.themeModeLight,
            () => _selectThemeMode(context, ThemeMode.light, amoled: false),
            themeMode == ThemeMode.light,
            icon: FluentIcons.weather_sunny_24_regular,
          ),
          BottomSheetBar(
            context.l10n!.themeModeDark,
            () => _selectThemeMode(context, ThemeMode.dark, amoled: false),
            themeMode == ThemeMode.dark && !isAmoled,
            icon: FluentIcons.weather_moon_24_regular,
          ),
          BottomSheetBar(
            'AMOLED',
            () => _selectThemeMode(context, ThemeMode.dark, amoled: true),
            themeMode == ThemeMode.dark && isAmoled,
            icon: FluentIcons.weather_moon_24_filled,
          ),
          BottomSheetBar(
            context.l10n!.custom,
            () => _pickCustomColor(context),
            false,
            icon: FluentIcons.color_24_regular,
          ),
        ],
      ),
    );
  }

  Future<void> _selectThemeMode(
    BuildContext context,
    ThemeMode mode, {
    required bool amoled,
  }) async {
    addOrUpdateData<int>('settings', 'themeIndex', mode.index);
    addOrUpdateData<bool>('settings', 'usePureBlackColor', amoled);
    usePureBlackColor.value = amoled;
    await DskPlay.updateAppState(context, newThemeMode: mode);
    closeCurrentBottomSheet();
  }

  /// Opens a full color-wheel picker so the user can choose any accent
  /// color, rather than being limited to the fixed [availableColors]
  /// presets. Shared by the "AMOLED/Custom" theme-mode entry and the
  /// rainbow swatch in the accent color picker.
  Future<void> _pickCustomColor(BuildContext context) async {
    var picked = primaryColorSetting;
    final result = await showDialog<Color>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.l10n!.accentColor),
        content: SingleChildScrollView(
          child: ColorPicker(
            pickerColor: primaryColorSetting,
            onColorChanged: (color) => picked = color,
            enableAlpha: false,
            labelTypes: const [],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(context.l10n!.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, picked),
            child: Text(context.l10n!.save),
          ),
        ],
      ),
    );
    if (result == null || !context.mounted) return;

    addOrUpdateData<int>('settings', 'accentColor', result.toARGB32());
    await DskPlay.updateAppState(
      context,
      newAccentColor: result,
      useSystemColor: false,
    );
    if (context.mounted) showToast(context, context.l10n!.accentChangeMsg);
    closeCurrentBottomSheet();
  }

  void _showLanguagePicker(BuildContext context) {
    final availableLanguages = appLanguages.toList();
    final activeLanguageCode = Localizations.localeOf(context).languageCode;
    final activeScriptCode = Localizations.localeOf(context).scriptCode;
    final activeLanguageFullCode = activeScriptCode != null
        ? '$activeLanguageCode-$activeScriptCode'
        : activeLanguageCode;

    showCustomBottomSheet(
      context,
      ListView.builder(
        shrinkWrap: true,
        physics: const BouncingScrollPhysics(),
        padding: commonListViewBottomPadding,
        itemCount: availableLanguages.length,
        itemBuilder: (context, index) {
          final language = availableLanguages[index];
          final newLocale = getLocaleFromLanguageCode(language);
          final newLocaleFullCode = newLocale.scriptCode != null
              ? '${newLocale.languageCode}-${newLocale.scriptCode}'
              : newLocale.languageCode;

          return BottomSheetBar(
            getLanguageDisplayName(context, language),
            () {
              addOrUpdateData<String>(
                'settings',
                'languageCode',
                newLocaleFullCode,
              );
              DskPlay.updateAppState(context, newLocale: newLocale);
              showToast(context, context.l10n!.languageMsg);
              Navigator.pop(context);
            },
            activeLanguageFullCode == newLocaleFullCode,
          );
        },
      ),
    );
  }

  void _showAudioQualityPicker(BuildContext context) {
    final availableQualities = ['low', 'medium', 'high'];
    final qualityNames = [
      context.l10n!.audioQualityLow,
      context.l10n!.audioQualityMedium,
      context.l10n!.audioQualityHigh,
    ];
    const qualityIcons = [
      FluentIcons.speaker_1_24_regular,
      FluentIcons.speaker_2_24_regular,
      FluentIcons.speaker_2_24_filled,
    ];

    showCustomBottomSheet(
      context,
      ListView.builder(
        shrinkWrap: true,
        physics: const BouncingScrollPhysics(),
        padding: commonListViewBottomPadding,
        itemCount: availableQualities.length,
        itemBuilder: (context, index) {
          final quality = availableQualities[index];

          return BottomSheetBar(
            qualityNames[index],
            () {
              addOrUpdateData<String>('settings', 'audioQuality', quality);
              audioQualitySetting.value = quality;
              showToast(context, context.l10n!.audioQualityMsg);
              Navigator.pop(context);
            },
            audioQualitySetting.value == quality,
            icon: qualityIcons[index],
          );
        },
      ),
    );
  }

  void _showAutoCloseAfterPausePicker(BuildContext context) {
    const options = [0, 1, 5, 10, 15, 30, 60];
    const labels = [
      'Nunca',
      '1 minuto',
      '5 minutos',
      '10 minutos',
      '15 minutos',
      '30 minutos',
      '60 minutos',
    ];

    showCustomBottomSheet(
      context,
      ListView.builder(
        shrinkWrap: true,
        physics: const BouncingScrollPhysics(),
        padding: commonListViewBottomPadding,
        itemCount: options.length,
        itemBuilder: (context, index) {
          final minutes = options[index];

          return BottomSheetBar(
            labels[index],
            () {
              addOrUpdateData<int>(
                'settings',
                'autoCloseAfterPauseMinutes',
                minutes,
              );
              autoCloseAfterPauseMinutes.value = minutes;
              showToast(context, context.l10n!.settingChangedMsg);
              Navigator.pop(context);
            },
            autoCloseAfterPauseMinutes.value == minutes,
            icon: FluentIcons.timer_24_regular,
          );
        },
      ),
    );
  }

  String _startScreenLabel(BuildContext context, String path) {
    return switch (path) {
      NavigationManager.podcastsPath => context.l10n!.podcasts,
      NavigationManager.libraryPath => context.l10n!.library,
      NavigationManager.localFilesPath => context.l10n!.localFiles,
      NavigationManager.settingsPath => context.l10n!.settings,
      _ => context.l10n!.home,
    };
  }

  void _showStartScreenPicker(BuildContext context) {
    const options = NavigationManager.startScreenOptions;
    const icons = [
      FluentIcons.home_24_regular,
      FluentIcons.mic_24_regular,
      FluentIcons.book_24_regular,
      FluentIcons.folder_24_regular,
      FluentIcons.settings_24_regular,
    ];

    showCustomBottomSheet(
      context,
      ListView.builder(
        shrinkWrap: true,
        physics: const BouncingScrollPhysics(),
        padding: commonListViewBottomPadding,
        itemCount: options.length,
        itemBuilder: (context, index) {
          final path = options[index];

          return BottomSheetBar(
            _startScreenLabel(context, path),
            () {
              addOrUpdateData<String>('settings', 'startScreen', path);
              startScreenSetting.value = path;
              showToast(context, context.l10n!.settingChangedMsg);
              Navigator.pop(context);
            },
            startScreenSetting.value == path,
            icon: icons[index],
          );
        },
      ),
    );
  }

  void _toggleVolumeNormalization(BuildContext context, bool value) {
    addOrUpdateData<bool>('settings', 'volumeNormalizationEnabled', value);
    volumeNormalizationEnabled.value = value;
    showToast(context, context.l10n!.settingChangedMsg);
  }

  void _toggleSystemColor(BuildContext context, bool value) {
    addOrUpdateData<bool>('settings', 'useSystemColor', value);
    useSystemColor.value = value;
    DskPlay.updateAppState(
      context,
      newAccentColor: primaryColorSetting,
      useSystemColor: value,
    );
    showToast(context, context.l10n!.settingChangedMsg);
  }

  void _togglePredictiveBack(BuildContext context, bool value) {
    addOrUpdateData<bool>('settings', 'predictiveBack', value);
    predictiveBack.value = value;
    transitionsBuilder = value
        ? const PredictiveBackPageTransitionsBuilder()
        : const CupertinoPageTransitionsBuilder();
    DskPlay.updateAppState(context);
    showToast(context, context.l10n!.settingChangedMsg);
  }

  void _toggleRememberLastPlayback(BuildContext context, bool value) {
    addOrUpdateData<bool>('settings', 'rememberLastPlayback', value);
    rememberLastPlayback.value = value;
    showToast(context, context.l10n!.settingChangedMsg);
  }

  Future<void> _toggleWrapped(BuildContext context, bool value) async {
    if (!value) {
      audioHandler.resetListeningStatsSession(
        countCurrentTick: true,
        flushStats: false,
      );
      await listeningStatsService.flush();
    }

    await addOrUpdateData<bool>('settings', 'wrappedEnabled', value);
    wrappedEnabled.value = value;
    listeningStatsService.reload();
    if (value) {
      audioHandler.startListeningStatsSessionIfNeeded();
    }
    if (context.mounted) {
      showToast(context, context.l10n!.settingChangedMsg);
    }
  }

  void _toggleShowArtistExtras(BuildContext context, bool value) {
    addOrUpdateData<bool>('settings', 'showArtistExtras', value);
    showArtistExtras.value = value;
    showToast(context, context.l10n!.settingChangedMsg);
  }

  void _toggleIncludePodcastsInTimeMachine(BuildContext context, bool value) {
    addOrUpdateData<bool>('settings', 'includePodcastsInTimeMachine', value);
    includePodcastsInTimeMachine.value = value;
    showToast(context, context.l10n!.settingChangedMsg);
  }

  void _toggleNativeIdleCloseBackup(BuildContext context, bool value) {
    addOrUpdateData<bool>('settings', 'nativeIdleCloseBackupEnabled', value);
    nativeIdleCloseBackupEnabled.value = value;
    showToast(context, context.l10n!.settingChangedMsg);
  }

  void _toggleOfflineMode(BuildContext context, bool value) {
    addOrUpdateData<bool>('settings', 'offlineMode', value);
    offlineMode.value = value;

    // Trigger router refresh and notify about the change
    NavigationManager.refreshRouter();

    showToast(context, context.l10n!.settingChangedMsg);
  }

  void _toggleSponsorBlock(BuildContext context, bool value) {
    addOrUpdateData<bool>('settings', 'sponsorBlockSupport', value);
    sponsorBlockSupport.value = value;
    showToast(context, context.l10n!.settingChangedMsg);
  }

  void _toggleAutoPlayNext(BuildContext context, bool value) {
    addOrUpdateData<bool>('settings', 'playNextSongAutomatically', value);
    playNextSongAutomatically.value = value;
    showToast(context, context.l10n!.settingChangedMsg);
  }

  void _toggleExternalRecommendations(BuildContext context, bool value) {
    addOrUpdateData<bool>('settings', 'externalRecommendations', value);
    externalRecommendations.value = value;
    showToast(context, context.l10n!.settingChangedMsg);
  }

  void _showConfirmationDialog({
    required BuildContext context,
    required String confirmationMessage,
    required VoidCallback onSubmit,
    String? submitMessage,
    bool isDangerous = false,
  }) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return ConfirmationDialog(
          submitMessage: submitMessage ?? context.l10n!.clear,
          confirmationMessage: confirmationMessage,
          isDangerous: isDangerous,
          onCancel: () => Navigator.of(context).pop(),
          onSubmit: () {
            Navigator.of(context).pop();
            onSubmit();
          },
        );
      },
    );
  }

}
