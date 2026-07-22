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
import 'package:dskplay/extensions/l10n.dart';
import 'package:dskplay/services/update_manager.dart';
import 'package:dskplay/utilities/flutter_toast.dart';
import 'package:dskplay/utilities/url_launcher.dart';

Future<void> showUpdateAvailableDialog(
  BuildContext context,
  UpdateInfo info,
) {
  return showDialog<void>(
    context: context,
    builder: (context) => _UpdateDialog(info: info),
  );
}

class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog({required this.info});
  final UpdateInfo info;

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  double? _progress;

  Future<void> _downloadAndInstall() async {
    setState(() => _progress = 0);
    try {
      final file = await downloadUpdate(
        widget.info,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      await installUpdate(file);
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (!mounted) return;
      setState(() => _progress = null);
      showToast(context, context.l10n!.updateCheckFailed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final downloading = _progress != null;

    return AlertDialog(
      icon: Icon(
        FluentIcons.arrow_download_24_regular,
        color: colorScheme.primary,
        size: 32,
      ),
      title: Text(context.l10n!.appUpdateIsAvailable),
      content: downloading
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(context.l10n!.downloadingUpdate),
                const SizedBox(height: 12),
                LinearProgressIndicator(
                  value: _progress! > 0 ? _progress : null,
                ),
              ],
            )
          : Text(
              '${context.l10n!.newBuildAvailable}: ${widget.info.tag}',
              textAlign: TextAlign.center,
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
      actionsAlignment: MainAxisAlignment.center,
      actions: downloading
          ? null
          : [
              TextButton(
                onPressed: () {
                  dismissUpdate(widget.info.tag);
                  Navigator.of(context).pop();
                },
                child: Text(context.l10n!.ignoreThisVersion),
              ),
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: colorScheme.outline),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: () {
                  launchURL(Uri.parse(widget.info.releaseUrl));
                  Navigator.of(context).pop();
                },
                child: Text(context.l10n!.viewOnGithub),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: _downloadAndInstall,
                child: Text(context.l10n!.downloadAppUpdate),
              ),
            ],
    );
  }
}
