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

import 'package:flutter/material.dart';
import 'package:musify/main.dart';
import 'package:musify/models/position_data.dart';
import 'package:musify/services/lyrics_manager.dart';
import 'package:musify/services/settings_manager.dart';

// Shows the previous/active/next lyric line only, always centered in the
// available space, so the highlighted line is never pinned to the bottom
// regardless of how long or how many lines the lyrics have. Colors are
// user-customizable (see karaoke_color_dialog.dart) and persist via
// settings_manager.
class KaraokeLyricsView extends StatelessWidget {
  const KaraokeLyricsView({super.key, required this.lines});
  final List<LyricLine> lines;

  int _activeIndexFor(Duration position) {
    var index = -1;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].timestamp <= position) {
        index = i;
      } else {
        break;
      }
    }
    return index;
  }

  @override
  Widget build(BuildContext context) {
    // Forces this to always fill the space offered by the parent (a Stack
    // gives loose constraints), regardless of how short the lyric lines
    // are. Without this, the Column below shrinks to the width of its
    // widest line, leaving the background uncovered and the text
    // off-center relative to the card.
    return SizedBox.expand(
      child: ValueListenableBuilder<Color>(
        valueListenable: karaokeBackgroundColor,
        builder: (context, backgroundColor, _) {
          return ValueListenableBuilder<Color>(
            valueListenable: karaokeActiveLyricColor,
            builder: (context, activeColor, _) {
              return ValueListenableBuilder<Color>(
                valueListenable: karaokeInactiveLyricColor,
                builder: (context, inactiveColor, _) {
                  return ColoredBox(
                    color: backgroundColor,
                    child: _buildContent(activeColor, inactiveColor),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildContent(Color activeColor, Color inactiveColor) {
    return StreamBuilder<PositionData>(
      stream: audioHandler.positionDataStream,
      builder: (context, snapshot) {
        final position = snapshot.data?.position ?? Duration.zero;
        final activeIndex = _activeIndexFor(
          position,
        ).clamp(0, lines.length - 1);
        final hasPrevious = activeIndex - 1 >= 0;
        final hasNext = activeIndex + 1 < lines.length;

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (hasPrevious) ...[
                _buildLine(
                  lines[activeIndex - 1].text,
                  color: inactiveColor,
                  active: false,
                ),
                const SizedBox(height: 20),
              ],
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: _buildLine(
                  lines[activeIndex].text,
                  color: activeColor,
                  active: true,
                  key: ValueKey(activeIndex),
                ),
              ),
              if (hasNext) ...[
                const SizedBox(height: 20),
                _buildLine(
                  lines[activeIndex + 1].text,
                  color: inactiveColor,
                  active: false,
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildLine(
    String text, {
    required Color color,
    required bool active,
    Key? key,
  }) {
    return Text(
      text,
      key: key,
      textAlign: TextAlign.center,
      style: TextStyle(
        fontSize: active ? 22 : 16,
        fontWeight: active ? FontWeight.w700 : FontWeight.w500,
        height: 1.4,
        color: color,
      ),
    );
  }
}
