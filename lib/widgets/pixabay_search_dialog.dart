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

import 'package:dskplay/main.dart';
import 'package:dskplay/services/pixabay_service.dart';
import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';

/// Busca una imagen en Pixabay y devuelve la elegida como data URI base64,
/// igual que la selección desde el dispositivo. `null` si se cierra sin
/// elegir.
Future<String?> showPixabaySearchDialog(BuildContext context) {
  return showDialog<String>(
    context: context,
    builder: (_) => const Dialog.fullscreen(child: _PixabaySearchView()),
  );
}

class _PixabaySearchView extends StatefulWidget {
  const _PixabaySearchView();

  @override
  State<_PixabaySearchView> createState() => _PixabaySearchViewState();
}

class _PixabaySearchViewState extends State<_PixabaySearchView> {
  final _queryController = TextEditingController();
  final _results = <PixabayImage>[];
  PixabayMediaType _type = PixabayMediaType.photo;
  int _page = 1;
  bool _loading = false;
  bool _loadingMore = false;
  bool _hasMore = false;
  bool _searched = false;
  String? _error;

  /// Imagen abierta a pantalla completa; volver a los resultados es sólo
  /// ponerla a null, así la búsqueda sigue intacta detrás.
  PixabayImage? _preview;
  bool _settingImage = false;

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _queryController.text.trim();
    if (query.isEmpty || _loading) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _error = null;
      _searched = true;
    });
    try {
      final results = await searchPixabay(
        query,
        type: _type,
        lang: pixabayLangFor(Localizations.localeOf(context).languageCode),
      );
      if (!mounted) return;
      setState(() {
        _results
          ..clear()
          ..addAll(results);
        _page = 1;
        _hasMore = results.length >= pixabayPageSize;
        _loading = false;
      });
    } catch (e, stackTrace) {
      logger.log('Pixabay search failed', error: e, stackTrace: stackTrace);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'No se ha podido buscar. Revisa la conexión.';
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || _loading) return;
    setState(() => _loadingMore = true);
    try {
      final results = await searchPixabay(
        _queryController.text.trim(),
        type: _type,
        page: _page + 1,
        lang: pixabayLangFor(Localizations.localeOf(context).languageCode),
      );
      if (!mounted) return;
      // Pixabay repite resultados al pasarse de la última página en las
      // búsquedas con pocos aciertos; los repetidos sólo ensucian la rejilla.
      final knownIds = _results.map((r) => r.id).toSet();
      final fresh = results.where((r) => !knownIds.contains(r.id)).toList();
      setState(() {
        _results.addAll(fresh);
        _page++;
        _hasMore = results.length >= pixabayPageSize && fresh.isNotEmpty;
        _loadingMore = false;
      });
    } catch (e, stackTrace) {
      logger.log('Pixabay load more failed', error: e, stackTrace: stackTrace);
      if (!mounted) return;
      setState(() {
        _loadingMore = false;
        _hasMore = false;
      });
    }
  }

  Future<void> _useImage(PixabayImage image) async {
    setState(() => _settingImage = true);
    String? dataUri;
    try {
      dataUri = await downloadImageAsDataUri(image.webformatUrl);
    } catch (e, stackTrace) {
      logger.log('Pixabay download failed', error: e, stackTrace: stackTrace);
    }
    if (!mounted) return;
    if (dataUri == null) {
      setState(() {
        _settingImage = false;
        _error = 'No se ha podido descargar la imagen.';
        _preview = null;
      });
      return;
    }
    Navigator.of(context).pop(dataUri);
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(FluentIcons.dismiss_24_regular),
          onPressed: preview == null
              ? () => Navigator.of(context).pop()
              : () => setState(() => _preview = null),
        ),
        title: Text(
          preview == null ? 'Buscar imagen en Pixabay' : 'Vista previa',
        ),
      ),
      body: preview == null ? _buildSearch(context) : _buildPreview(preview),
    );
  }

  Widget _buildSearch(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: TextField(
            controller: _queryController,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _search(),
            decoration: InputDecoration(
              hintText: 'Paisaje, concierto, rock...',
              filled: true,
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: const Icon(FluentIcons.search_24_regular),
                onPressed: _search,
              ),
            ),
          ),
        ),
        SizedBox(
          height: 56,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            children: [
              for (final type in PixabayMediaType.values)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(type.label),
                    selected: _type == type,
                    onSelected: (_) {
                      setState(() => _type = type);
                      if (_queryController.text.trim().isNotEmpty) _search();
                    },
                  ),
                ),
            ],
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        Expanded(child: _buildResults(context)),
      ],
    );
  }

  Widget _buildResults(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_results.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _searched
                ? 'Sin resultados'
                : 'Escribe qué buscas y pulsa la lupa.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
      ),
      itemCount: _results.length + (_hasMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == _results.length) {
          return Center(
            child: _loadingMore
                ? const CircularProgressIndicator()
                : IconButton.filledTonal(
                    icon: const Icon(FluentIcons.arrow_download_24_regular),
                    tooltip: 'Más resultados',
                    onPressed: _loadMore,
                  ),
          );
        }
        final image = _results[index];
        return InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => setState(() => _preview = image),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.network(
              image.previewUrl,
              fit: BoxFit.cover,
              errorBuilder: (context, _, __) => ColoredBox(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: const Icon(FluentIcons.image_off_24_regular),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildPreview(PixabayImage image) {
    return Column(
      children: [
        Expanded(
          child: InteractiveViewer(
            maxScale: 5,
            child: Center(
              child: Image.network(
                image.largeUrl,
                fit: BoxFit.contain,
                loadingBuilder: (context, child, progress) => progress == null
                    ? child
                    : const Center(child: CircularProgressIndicator()),
                errorBuilder: (context, _, __) =>
                    const Icon(FluentIcons.image_off_24_regular, size: 48),
              ),
            ),
          ),
        ),
        if (image.tags.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              image.tags,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _settingImage
                      ? null
                      : () => setState(() => _preview = null),
                  child: const Text('Volver a resultados'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _settingImage ? null : () => _useImage(image),
                  child: _settingImage
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2.5),
                        )
                      : const Text('Usar esta imagen'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
