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

import 'package:dskplay/extensions/l10n.dart';
import 'package:dskplay/main.dart';
import 'package:dskplay/screens/search_page.dart' show reloadSearchHistoryFromStorage;
import 'package:dskplay/services/cloud_backup_service.dart';
import 'package:dskplay/services/common_services.dart';
import 'package:dskplay/services/data_manager.dart';
import 'package:dskplay/services/listening_stats_service.dart';
import 'package:dskplay/services/playlists_manager.dart';
import 'package:dskplay/services/podcast_manager.dart';
import 'package:dskplay/services/settings_manager.dart';
import 'package:dskplay/theme/app_themes.dart';
import 'package:dskplay/utilities/flutter_toast.dart';
import 'package:dskplay/widgets/custom_bar.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

/// Local (single file) and cloud (anonymous, Firebase-backed) backup/restore,
/// each showing when it was last done so it's obvious which one is newer.
class BackupSection extends StatefulWidget {
  const BackupSection({super.key});

  @override
  State<BackupSection> createState() => _BackupSectionState();
}

class _BackupSectionState extends State<BackupSection> {
  DateTime? _localBackupAt;
  DateTime? _cloudBackupAt;
  int? _cloudBackupSize;
  bool _busy = false;
  // Which action is running, so only that row shows a spinner instead of
  // the whole section just going quietly unresponsive - that silence was
  // what made a slow/stuck backup look like nothing was happening at all.
  String? _busyAction;
  final _codeController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadTimestamps();
  }

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _loadTimestamps() async {
    final local = await getData('userNoBackup', 'lastLocalBackupAt');
    final cloud = await cloudBackupService.getCloudBackupInfo();
    if (!mounted) return;
    setState(() {
      _localBackupAt = local as DateTime?;
      _cloudBackupAt = cloud.updatedAt;
      _cloudBackupSize = cloud.sizeInBytes;
    });
  }

  String _formatTimestamp(DateTime? value) {
    if (value == null) return 'Nunca respaldado';
    final local = value.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(local.day)}/${two(local.month)}/${local.year} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  String _formatSize(int? bytes) {
    if (bytes == null) return '';
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    return '${(kb / 1024).toStringAsFixed(1)} MB';
  }

  String _formatCloudDescription() {
    final timestamp = _formatTimestamp(_cloudBackupAt);
    final size = _formatSize(_cloudBackupSize);
    return size.isEmpty ? timestamp : '$timestamp  -  $size';
  }

  Future<void> _showFolderRestrictionsNotice() async {
    final colorScheme = Theme.of(context).colorScheme;
    await showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: Icon(
          FluentIcons.info_24_regular,
          color: colorScheme.primary,
          size: 32,
        ),
        content: Text(
          dialogContext.l10n!.folderRestrictions,
          style: TextStyle(color: colorScheme.onSurfaceVariant),
          textAlign: TextAlign.center,
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: <Widget>[
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(dialogContext.l10n!.understand),
          ),
        ],
      ),
    );
  }

  Future<void> _afterRestore() async {
    reloadSongLibraryStateFromStorage();
    reloadPlaylistLibraryStateFromStorage();
    reloadSearchHistoryFromStorage();
    reloadRadioStationsStateFromStorage();
    podcastManager.reloadFromStorage();
    // Every preference in the restored 'settings' box at once, instead of
    // the handful this used to resync by hand - each setting that wasn't on
    // that list stayed on its pre-restore value until a cold start, which
    // looked like the backup had never contained it.
    reloadSettingsFromStorage();
    listeningStatsService.reload();

    // Theme, accent and language aren't just values: the widget tree has to
    // be told to rebuild with them, which reloadSettingsFromStorage() can't
    // do without a BuildContext.
    final restoredThemeIndex =
        await getData('settings', 'themeIndex', defaultValue: 0) as int;

    if (mounted) {
      DskPlay.updateAppState(
        context,
        newThemeMode: getThemeMode(restoredThemeIndex),
        newAccentColor: primaryColorSetting,
        newLocale: languageSetting,
        useSystemColor: useSystemColor.value,
      );
    }
  }

  Future<void> _run(
    Future<({String message, bool success})> Function() action, {
    required String actionKey,
  }) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _busyAction = actionKey;
    });
    try {
      final result = await action();
      if (mounted) {
        showToast(
          context,
          result.message,
          icon: result.success ? null : FluentIcons.error_circle_24_regular,
        );
      }
    } catch (e, stackTrace) {
      logger.log('Backup/restore error', error: e, stackTrace: stackTrace);
      if (mounted) {
        showToast(
          context,
          context.l10n!.error,
          icon: FluentIcons.error_circle_24_regular,
        );
      }
    } finally {
      await _loadTimestamps();
      if (mounted) {
        setState(() {
          _busy = false;
          _busyAction = null;
        });
      }
    }
  }

  Future<void> _backupLocal() => _run(actionKey: 'local_backup', () async {
    await _showFolderRestrictionsNotice();
    return backupData(context);
  });

  Future<void> _restoreLocal() => _run(actionKey: 'local_restore', () async {
    final result = await restoreData(context);
    if (result.success) await _afterRestore();
    return result;
  });

  Future<void> _backupCloud() => _run(actionKey: 'cloud_backup', () async {
    final success = await cloudBackupService.uploadBackup(force: true);
    final error = cloudBackupService.lastUploadError;
    return (
      message: success
          ? context.l10n!.backedupSuccess
          : error != null
          ? '${context.l10n!.backupError}: $error'
          : context.l10n!.backupError,
      success: success,
    );
  });

  Future<void> _restoreCloud() => _run(actionKey: 'cloud_restore', () async {
    final data = (await cloudBackupService.downloadBackup()).data;
    if (data == null) {
      return (message: context.l10n!.restoreError, success: false);
    }
    await applyBackupSnapshot(data);
    await _afterRestore();
    return (message: context.l10n!.restoredSuccess, success: true);
  });

  Future<void> _copyDeviceCode() async {
    final code = cloudBackupService.deviceCode;
    if (code == null) return;
    await Clipboard.setData(ClipboardData(text: code));
    if (mounted) showToast(context, 'Código copiado');
  }

  Future<void> _restoreFromCode() => _run(actionKey: 'code_restore', () async {
    final code = _codeController.text.trim();
    if (code.isEmpty) {
      return (message: 'Introduce un código de recuperación', success: false);
    }
    final data = (await cloudBackupService.downloadBackup(code: code)).data;
    if (data == null) {
      return (message: context.l10n!.restoreError, success: false);
    }
    await applyBackupSnapshot(data);
    await _afterRestore();
    _codeController.clear();
    return (message: context.l10n!.restoredSuccess, success: true);
  });

  Widget? _spinnerFor(String actionKey) {
    if (_busyAction != actionKey) return null;
    return const SizedBox(
      width: 20,
      height: 20,
      child: CircularProgressIndicator(strokeWidth: 2.5),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        CustomBar(
          context.l10n!.backupUserData,
          FluentIcons.arrow_export_24_regular,
          description: _formatTimestamp(_localBackupAt),
          onTap: _busy ? null : _backupLocal,
          trailing: _spinnerFor('local_backup'),
        ),
        CustomBar(
          context.l10n!.restoreUserData,
          FluentIcons.arrow_import_24_regular,
          onTap: _busy ? null : _restoreLocal,
          trailing: _spinnerFor('local_restore'),
        ),
        CustomBar(
          'Respaldo en la nube',
          FluentIcons.cloud_sync_24_regular,
          description: _formatCloudDescription(),
          onTap: _busy ? null : _backupCloud,
          trailing: _spinnerFor('cloud_backup'),
        ),
        CustomBar(
          'Restaurar desde la nube',
          FluentIcons.cloud_add_24_regular,
          onTap: _busy ? null : _restoreCloud,
          trailing: _spinnerFor('cloud_restore'),
        ),
        CustomBar(
          'Tu código de recuperación',
          FluentIcons.key_24_regular,
          description: cloudBackupService.deviceCode ?? 'No disponible aún',
          onTap: cloudBackupService.deviceCode == null ? null : _copyDeviceCode,
          trailing: const Icon(FluentIcons.copy_24_regular),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _codeController,
                  decoration: const InputDecoration(
                    labelText: 'Restaurar con código',
                    isDense: true,
                  ),
                  enabled: !_busy,
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _busy ? null : _restoreFromCode,
                child: const Text('Restaurar'),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Text(
            'El respaldo en la nube usa un identificador anónimo y '
            'aleatorio: no recopila tu nombre, correo ni ningún otro dato '
            'personal. Guarda tu código de recuperación si quieres poder '
            'restaurar tras borrar los datos de la app o reinstalarla.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}
