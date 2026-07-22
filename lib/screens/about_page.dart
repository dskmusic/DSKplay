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

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:dskplay/constants/app_constants.dart';
import 'package:dskplay/constants/version.dart';
import 'package:dskplay/extensions/l10n.dart';
import 'package:dskplay/services/update_manager.dart';
import 'package:dskplay/utilities/url_launcher.dart';
import 'package:dskplay/widgets/confirmation_dialog.dart';
import 'package:dskplay/widgets/mini_player_bottom_space.dart';

class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  Timer? _versionLongPressTimer;

  void _startVersionLongPress() {
    _versionLongPressTimer = Timer(
      const Duration(seconds: 2),
      _confirmManualBuild,
    );
  }

  void _cancelVersionLongPress() {
    _versionLongPressTimer?.cancel();
    _versionLongPressTimer = null;
  }

  void _confirmManualBuild() {
    _versionLongPressTimer = null;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => ConfirmationDialog(
        confirmationMessage: dialogContext.l10n!.runManualBuildConfirm,
        submitMessage: dialogContext.l10n!.runManualBuild,
        onCancel: () => Navigator.pop(dialogContext),
        onSubmit: () {
          Navigator.pop(dialogContext);
          launchURL(workflowRunUrl);
        },
      ),
    );
  }

  @override
  void dispose() {
    _versionLongPressTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n!.about)),
      body: SingleChildScrollView(
        padding: commonSingleChildScrollViewPadding,
        child: Column(
          children: <Widget>[
            const SizedBox(height: 14),
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'DSK Play',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                      fontSize: 36,
                      fontWeight: FontWeight.bold,
                      fontFamily: 'paytoneOne',
                      letterSpacing: -1.2,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: 40,
                    height: 3,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 12),
                  GestureDetector(
                    onTapDown: (_) => _startVersionLongPress(),
                    onTapUp: (_) => _cancelVersionLongPress(),
                    onTapCancel: _cancelVersionLongPress,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(
                          context,
                        ).colorScheme.secondaryContainer,
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: Text(
                        'v$appVersion',
                        style: TextStyle(
                          color: Theme.of(
                            context,
                          ).colorScheme.onSecondaryContainer,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.2,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                '"Developed by Víctor Castilla, for Lucía, Alicia and Eva, '
                'with all my love."',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontStyle: FontStyle.italic,
                  fontSize: 14,
                  height: 1.5,
                  letterSpacing: 0.3,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: 20),
            RichText(
              textAlign: TextAlign.center,
              text: TextSpan(
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 14,
                ),
                children: [
                  const TextSpan(text: 'Made with ❤️ by '),
                  TextSpan(
                    text: 'DSK',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                    recognizer: TapGestureRecognizer()
                      ..onTap = () => launchURL(
                        Uri.parse(
                          'https://www.dskmusic.com/dsk_dev_redirect.php',
                        ),
                      ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            RichText(
              textAlign: TextAlign.center,
              text: TextSpan(
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 12,
                ),
                children: [
                  const TextSpan(text: 'Based on the open-source '),
                  TextSpan(
                    text: 'Musify',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                    recognizer: TapGestureRecognizer()
                      ..onTap = () => launchURL(
                        Uri.parse('https://github.com/gokadzev/Musify'),
                      ),
                  ),
                  const TextSpan(text: ' project by Valeri Gokadze'),
                ],
              ),
            ),
            const MiniPlayerBottomSpace(),
          ],
        ),
      ),
    );
  }
}
