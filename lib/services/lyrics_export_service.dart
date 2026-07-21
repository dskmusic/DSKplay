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

import 'dart:io';

import 'package:musify/main.dart' show logger;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

String sanitizeFileNameForExport(String name) {
  final sanitized = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
  return sanitized.isEmpty ? 'lyrics' : sanitized;
}

/// Builds a centered, single-column PDF (title, then artist, then lyrics)
/// and writes it to `$dirPath/$fileName.pdf`. Returns the saved path, or
/// null on failure.
Future<String?> exportLyricsAsPdf({
  required String title,
  required String artist,
  required String lyrics,
  required String dirPath,
  required String fileName,
}) async {
  try {
    final doc = pw.Document();

    // Each block is forced to the full content width via a
    // width:double.infinity Container before centering; otherwise pw.Text
    // only centers its wrapped lines within its own intrinsic (shortest-fit)
    // width, leaving the whole block flush against the left margin.
    pw.Widget centeredBlock(pw.Widget child) {
      return pw.Container(
        width: double.infinity,
        alignment: pw.Alignment.center,
        child: child,
      );
    }

    // Lyrics are laid out one line per widget (rather than one big
    // multi-line Text) so the page-break algorithm can start a new page
    // between lines instead of moving the whole lyrics block as one
    // indivisible unit — otherwise a long lyrics block that doesn't fit
    // under the title/artist gets pushed entirely to page 2, leaving
    // page 1 with just the title and artist.
    const lyricsStyle = pw.TextStyle(fontSize: 12);

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(40),
        build: (context) => [
          centeredBlock(
            pw.Text(
              title,
              style: pw.TextStyle(
                fontSize: 20,
                fontWeight: pw.FontWeight.bold,
              ),
              textAlign: pw.TextAlign.center,
            ),
          ),
          pw.SizedBox(height: 6),
          centeredBlock(
            pw.Text(
              artist,
              style: pw.TextStyle(fontSize: 13, color: PdfColors.grey700),
              textAlign: pw.TextAlign.center,
            ),
          ),
          pw.SizedBox(height: 28),
          for (final line in lyrics.split('\n')) ...[
            centeredBlock(
              pw.Text(
                line.trim().isEmpty ? ' ' : line,
                style: lyricsStyle,
                textAlign: pw.TextAlign.center,
              ),
            ),
            pw.SizedBox(height: 4),
          ],
        ],
      ),
    );

    final dir = Directory(dirPath);
    if (!await dir.exists()) await dir.create(recursive: true);

    final path = '$dirPath/${sanitizeFileNameForExport(fileName)}.pdf';
    await File(path).writeAsBytes(await doc.save());
    return path;
  } catch (e, stackTrace) {
    logger.log('Error exporting lyrics as PDF', error: e, stackTrace: stackTrace);
    return null;
  }
}
