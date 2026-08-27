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

import 'package:dskplay/widgets/section_title.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';

class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.icon,
    this.actionButton,
    this.onTap,
    this.isCollapsed,
  });
  final String title;
  final IconData? icon;
  final Widget? actionButton;

  /// Si se indica, el icono y el titulo son pulsables (plegar la seccion).
  final VoidCallback? onTap;

  /// Estado del chevron; solo se pinta cuando hay [onTap].
  final bool? isCollapsed;

  @override
  Widget build(BuildContext context) {
    final titleWidget = SectionTitle(
      title,
      Theme.of(context).colorScheme.primary,
      icon: icon,
    );

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
          child: onTap == null
              ? titleWidget
              : InkWell(
                  onTap: onTap,
                  child: Row(
                    children: [
                      Flexible(child: titleWidget),
                      const SizedBox(width: 6),
                      Icon(
                        isCollapsed ?? false
                            ? FluentIcons.chevron_down_20_regular
                            : FluentIcons.chevron_up_20_regular,
                        size: 18,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ],
                  ),
                ),
        ),
        if (actionButton != null) actionButton!,
      ],
    );
  }
}
