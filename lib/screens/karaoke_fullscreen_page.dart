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
import 'package:dskplay/services/lyrics_manager.dart';
import 'package:dskplay/services/settings_manager.dart';
import 'package:dskplay/widgets/now_playing/karaoke_lyrics_view.dart';
import 'package:dskplay/widgets/playback_icon_button.dart';
import 'package:dskplay/widgets/position_slider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

// Fullscreen lyrics view, mainly meant for karaoke mode: keeps the screen
// awake while open and exits (disabling the wakelock again) on the device's
// back button, same as any normal pushed route.
class KaraokeFullscreenPage extends StatefulWidget {
  const KaraokeFullscreenPage({
    super.key,
    required this.result,
    required this.karaokeEnabled,
  });

  final LyricsResult result;
  final bool karaokeEnabled;

  @override
  State<KaraokeFullscreenPage> createState() => _KaraokeFullscreenPageState();
}

class _KaraokeFullscreenPageState extends State<KaraokeFullscreenPage> {
  late bool _karaokeEnabled =
      widget.karaokeEnabled && widget.result.hasSyncedLyrics;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: _karaokeEnabled
          ? karaokeBackgroundColor.value
          : colorScheme.surface,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: _karaokeEnabled
                  ? KaraokeLyricsView(lines: widget.result.syncedLines!)
                  : SingleChildScrollView(
                      padding: const EdgeInsets.all(32),
                      physics: const BouncingScrollPhysics(),
                      child: Center(
                        child: Text(
                          widget.result.plainText,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w500,
                            height: 1.6,
                            color: colorScheme.onSurface,
                          ),
                        ),
                      ),
                    ),
            ),
            Positioned(
              left: 8,
              top: 8,
              child: _CircleIconButton(
                icon: FluentIcons.dismiss_24_regular,
                onTap: () => Navigator.of(context).maybePop(),
              ),
            ),
            if (widget.result.hasSyncedLyrics)
              Positioned(
                right: 8,
                top: 8,
                child: _CircleIconButton(
                  icon: _karaokeEnabled
                      ? FluentIcons.mic_sparkle_24_filled
                      : FluentIcons.mic_sparkle_24_regular,
                  onTap: () =>
                      setState(() => _karaokeEnabled = !_karaokeEnabled),
                ),
              ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _FullscreenTransportBar(colorScheme: colorScheme),
            ),
          ],
        ),
      ),
    );
  }
}

class _FullscreenTransportBar extends StatelessWidget {
  const _FullscreenTransportBar({required this.colorScheme});
  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withValues(alpha: 0),
            Colors.black.withValues(alpha: 0.35),
          ],
        ),
      ),
      child: DefaultTextStyle.merge(
        style: const TextStyle(color: Colors.white),
        child: Theme(
          data: theme.copyWith(
            sliderTheme: theme.sliderTheme.copyWith(
              activeTrackColor: Colors.white,
              inactiveTrackColor: Colors.white24,
              thumbColor: Colors.white,
              overlayColor: Colors.white24,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              PlaybackIconButton(
                iconSize: 24,
                iconColor: Colors.white,
                backgroundColor: Colors.white.withValues(alpha: 0.2),
              ),
              const SizedBox(width: 12),
              const Expanded(child: PositionSlider()),
            ],
          ),
        ),
      ),
    );
  }
}

class _CircleIconButton extends StatelessWidget {
  const _CircleIconButton({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.35),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(icon, color: Colors.white, size: 22),
        ),
      ),
    );
  }
}
