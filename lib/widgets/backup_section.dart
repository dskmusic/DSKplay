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

import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:dskplay/extensions/l10n.dart';
import 'package:dskplay/main.dart';
import 'package:dskplay/screens/search_page.dart' show reloadSearchHistoryFromStorage;
import 'package:dskplay/services/cloud_backup_service.dart';
import 'package:dskplay/services/common_services.dart';
import 'package:dskplay/services/data_manager.dart';
import 'package:dskplay/services/listening_stats_service.dart';
import 'package:dskplay/services/playlists_manager.dart';
import 'package:dskplay/services/settings_manager.dart';
import 'package:dskplay/utilities/flutter_toast.dart';
import 'package:dskplay/widgets/custom_bar.dart';

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
  bool _busy = false;
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
    final cloud = await cloudBackupService.getCloudBackupTimestamp();
    if (!mounted) return;
    setState(() {
      _localBackupAt = local as DateTime?;
      _cloudBackupAt = cloud;
    });
  }

  String _formatTimestamp(DateTime? value) {
    if (value == null) return 'Never backed up';
    final local = value.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(local.day)}/${two(local.month)}/${local.year} '
        '${two(local.hour)}:${two(local.minute)}';
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
    // The restored settings box may carry a different wrappedEnabled value
    // than the one already loaded into this ValueNotifier; without resyncing
    // it here, recording silently keeps following the pre-restore value
    // until the next cold start, when it would suddenly flip without
    // explanation.
    wrappedEnabled.value =
        await getData('settings', 'wrappedEnabled', defaultValue: true)
            as bool;
    listeningStatsService.reload();
  }

  Future<void> _run(Future<({String message, bool success})> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
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
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _backupLocal() => _run(() async {
    await _showFolderRestrictionsNotice();
    return backupData(context);
  });

  Future<void> _restoreLocal() => _run(() async {
    final result = await restoreData(context);
    if (result.success) await _afterRestore();
    return result;
  });

  Future<void> _backupCloud() => _run(() async {
    final success = await cloudBackupService.uploadBackup();
    return (
      message: success
          ? context.l10n!.backedupSuccess
          : context.l10n!.backupError,
      success: success,
    );
  });

  Future<void> _restoreCloud() => _run(() async {
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

  Future<void> _restoreFromCode() => _run(() async {
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

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        CustomBar(
          context.l10n!.backupUserData,
          FluentIcons.arrow_export_24_regular,
          description: _formatTimestamp(_localBackupAt),
          onTap: _busy ? null : _backupLocal,
        ),
        CustomBar(
          context.l10n!.restoreUserData,
          FluentIcons.arrow_import_24_regular,
          onTap: _busy ? null : _restoreLocal,
        ),
        CustomBar(
          'Cloud backup',
          FluentIcons.cloud_sync_24_regular,
          description: _formatTimestamp(_cloudBackupAt),
          onTap: _busy ? null : _backupCloud,
        ),
        CustomBar(
          'Cloud restore',
          FluentIcons.cloud_add_24_regular,
          onTap: _busy ? null : _restoreCloud,
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
            'Cloud backup uses an anonymous, random device identifier - it '
            "doesn't collect your name, email or any other personal "
            'information. Guarda tu código de recuperación si quieres poder '
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
