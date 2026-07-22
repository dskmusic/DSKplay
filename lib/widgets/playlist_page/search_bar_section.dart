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
import 'package:dskplay/widgets/custom_search_bar.dart';

class SearchBarSection extends StatefulWidget {
  const SearchBarSection({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onSearchChanged,
    required this.labelText,
  });
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onSearchChanged;
  final String labelText;

  @override
  State<SearchBarSection> createState() => _SearchBarSectionState();
}

class _SearchBarSectionState extends State<SearchBarSection> {
  @override
  Widget build(BuildContext context) {
    return CustomSearchBar(
      controller: widget.controller,
      focusNode: widget.focusNode,
      labelText: widget.labelText,
      onSubmitted: (_) {},
      onChanged: widget.onSearchChanged,
    );
  }
}
