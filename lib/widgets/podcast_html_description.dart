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
import 'package:flutter_html/flutter_html.dart';
import 'package:url_launcher/url_launcher.dart';

final _htmlTagPattern = RegExp('<[a-zA-Z/][^>]*>');

/// Renders a podcast/episode description, which RSS feeds deliver as either
/// plain text or HTML (paragraphs, links, inline images) - shared by every
/// place a description is shown so both forms display correctly instead of
/// dumping raw markup as text.
class PodcastHtmlDescription extends StatelessWidget {
  const PodcastHtmlDescription({
    super.key,
    required this.data,
    this.color,
    this.fontSize = 14,
  });

  final String data;
  final Color? color;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textColor = color ?? colorScheme.onSurface;

    // Plain-text descriptions have no tags to render - turn line breaks into
    // <br/> first, otherwise Html collapses them into a single paragraph.
    final html = _htmlTagPattern.hasMatch(data)
        ? data
        : data.split('\n').map(_escape).join('<br/>');

    return LayoutBuilder(
      builder: (context, constraints) {
        // flutter_html resolves an image's percentage width against pixels
        // literally (100% -> 100px) rather than the available space, so the
        // only way to get a full-width, centered image is to hand it an
        // already-resolved pixel width and center it with auto margins.
        final imageWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 300.0;

        return Html(
          data: html,
          style: {
            'body': Style(
              margin: Margins.zero,
              padding: HtmlPaddings.zero,
              fontSize: FontSize(fontSize),
              color: textColor,
              lineHeight: LineHeight.number(1.5),
            ),
            'a': Style(color: colorScheme.primary),
            'img': Style(
              display: Display.block,
              width: Width(imageWidth),
              margin: Margins(left: Margin.auto(), right: Margin.auto()),
            ),
          },
          onLinkTap: (url, _, _) {
            if (url == null) return;
            final uri = Uri.tryParse(url);
            if (uri != null) {
              launchUrl(uri, mode: LaunchMode.externalApplication);
            }
          },
        );
      },
    );
  }

  static String _escape(String text) => text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
}
