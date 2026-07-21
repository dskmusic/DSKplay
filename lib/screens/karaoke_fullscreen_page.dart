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
import 'package:musify/services/lyrics_manager.dart';
import 'package:musify/services/settings_manager.dart';
import 'package:musify/widgets/now_playing/karaoke_lyrics_view.dart';
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
          ],
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
