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
import 'package:musify/extensions/l10n.dart';
import 'package:musify/services/settings_manager.dart';
import 'package:musify/theme/app_colors.dart';

Future<void> showKaraokeColorSettingsDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => const _KaraokeColorSettingsDialog(),
  );
}

class _KaraokeColorSettingsDialog extends StatelessWidget {
  const _KaraokeColorSettingsDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.l10n!.karaokeColors),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _KaraokeColorRow(
              label: context.l10n!.karaokeBackgroundColor,
              notifier: karaokeBackgroundColor,
              onSet: setKaraokeBackgroundColor,
            ),
            _KaraokeColorRow(
              label: context.l10n!.karaokeActiveLyricColor,
              notifier: karaokeActiveLyricColor,
              onSet: setKaraokeActiveLyricColor,
            ),
            _KaraokeColorRow(
              label: context.l10n!.karaokeInactiveLyricColor,
              notifier: karaokeInactiveLyricColor,
              onSet: setKaraokeInactiveLyricColor,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: resetKaraokeColors,
          child: Text(context.l10n!.resetToDefaults),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.l10n!.close),
        ),
      ],
    );
  }
}

class _KaraokeColorRow extends StatelessWidget {
  const _KaraokeColorRow({
    required this.label,
    required this.notifier,
    required this.onSet,
  });

  final String label;
  final ValueNotifier<Color> notifier;
  final void Function(Color) onSet;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Color>(
      valueListenable: notifier,
      builder: (context, color, _) {
        return InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _pickColor(context),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(child: Text(label)),
              ],
            ),
          ),
        );
      },
    );
  }

  // A plain dialog (not a bottom sheet) since this is opened from within
  // another dialog, which has no Scaffold ancestor for showBottomSheet to
  // attach to.
  void _pickColor(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final current = notifier.value;

    showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: GridView.builder(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 5,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
            ),
            shrinkWrap: true,
            physics: const BouncingScrollPhysics(),
            itemCount: karaokeColorPalette.length,
            itemBuilder: (context, index) {
              final color = karaokeColorPalette[index];
              final isSelected = color.toARGB32() == current.toARGB32();

              return GestureDetector(
                onTap: () {
                  onSet(color);
                  Navigator.pop(dialogContext);
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: isSelected
                          ? colorScheme.onSurface
                          : colorScheme.outlineVariant,
                      width: isSelected ? 3 : 1,
                    ),
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
      ),
    );
  }
}
