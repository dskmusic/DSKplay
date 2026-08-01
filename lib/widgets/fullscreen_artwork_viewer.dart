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

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:dskplay/extensions/l10n.dart';
import 'package:dskplay/main.dart' show logger;
import 'package:dskplay/services/io_service.dart';
import 'package:dskplay/utilities/artwork_provider.dart';
import 'package:dskplay/utilities/flutter_toast.dart';

/// Fullscreen preview of an album/playlist cover with pinch-to-zoom, a
/// double tap to toggle zoomed in/out, and a download-to-device action.
class FullscreenArtworkViewer extends StatefulWidget {
  const FullscreenArtworkViewer({
    super.key,
    required this.artwork,
    required this.fileName,
  });

  final String artwork;
  final String fileName;

  static Future<void> show(
    BuildContext context, {
    required String artwork,
    required String fileName,
  }) {
    return Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: false,
        barrierColor: Colors.black,
        pageBuilder: (_, __, ___) =>
            FullscreenArtworkViewer(artwork: artwork, fileName: fileName),
      ),
    );
  }

  @override
  State<FullscreenArtworkViewer> createState() =>
      _FullscreenArtworkViewerState();
}

class _FullscreenArtworkViewerState extends State<FullscreenArtworkViewer>
    with SingleTickerProviderStateMixin {
  final _transformationController = TransformationController();
  late final _animController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  )..addListener(() => _transformationController.value = _animation.value);
  Animation<Matrix4> _animation = Matrix4Tween(
    begin: Matrix4.identity(),
    end: Matrix4.identity(),
  ).animate(const AlwaysStoppedAnimation(0));
  TapDownDetails? _doubleTapDetails;

  static const double _zoomedScale = 3;

  @override
  void dispose() {
    _animController.dispose();
    _transformationController.dispose();
    super.dispose();
  }

  void _handleDoubleTap() {
    final position = _doubleTapDetails!.localPosition;
    final isZoomedIn = _transformationController.value != Matrix4.identity();
    final endMatrix = isZoomedIn
        ? Matrix4.identity()
        : (Matrix4.identity()
            ..translate(
              -position.dx * (_zoomedScale - 1),
              -position.dy * (_zoomedScale - 1),
            )
            ..scale(_zoomedScale));

    _animation =
        Matrix4Tween(
          begin: _transformationController.value,
          end: endMatrix,
        ).animate(
          CurveTween(
            curve: Curves.easeOut,
          ).animate(_animController),
        );
    _animController.forward(from: 0);
  }

  Future<Uint8List> _readArtworkBytes() async {
    final artwork = widget.artwork;
    if (artwork.startsWith('http')) {
      return (await http.get(Uri.parse(artwork))).bodyBytes;
    }
    if (artwork.startsWith('data:image')) {
      final commaIdx = artwork.indexOf(',');
      return base64Decode(artwork.substring(commaIdx + 1));
    }
    final path = artwork.replaceFirst('file://', '');
    return File(path).readAsBytes();
  }

  Future<void> _download() async {
    try {
      if (!await ensureExportStoragePermission()) {
        if (mounted) showToast(context, context.l10n!.error);
        return;
      }

      final dir = Directory(androidDownloadsDirPath);
      if (!await dir.exists()) await dir.create(recursive: true);

      final bytes = await _readArtworkBytes();
      final file = File('${dir.path}/${sanitizeFileName(widget.fileName)}.jpg');
      await file.writeAsBytes(bytes);
      await scanMediaFile(file.path);

      if (mounted) showToast(context, 'Portada guardada en ${file.path}');
    } catch (e, stackTrace) {
      logger.log('Error saving artwork', error: e, stackTrace: stackTrace);
      if (mounted) showToast(context, context.l10n!.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                onDoubleTapDown: (details) => _doubleTapDetails = details,
                onDoubleTap: _handleDoubleTap,
                child: InteractiveViewer(
                  transformationController: _transformationController,
                  minScale: 1,
                  maxScale: 5,
                  child: Center(
                    child: Image(image: ArtworkProvider.get(widget.artwork)),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 12,
              right: 12,
              child: Row(
                children: [
                  _RoundIconButton(
                    icon: FluentIcons.arrow_download_24_regular,
                    onPressed: _download,
                  ),
                  const SizedBox(width: 12),
                  _RoundIconButton(
                    icon: FluentIcons.dismiss_24_regular,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RoundIconButton extends StatelessWidget {
  const _RoundIconButton({required this.icon, required this.onPressed});

  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        shape: BoxShape.circle,
      ),
      child: IconButton(
        icon: Icon(icon, color: Colors.white),
        onPressed: onPressed,
      ),
    );
  }
}
