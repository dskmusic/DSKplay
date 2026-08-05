param([string]$FilePath)

if (-not (Test-Path -LiteralPath $FilePath)) {
    Write-Host "  [ERROR] No existe $FilePath, no se puede parchear."
    exit 1
}

$content = Get-Content -Raw -LiteralPath $FilePath

if ($content.Contains('_findContinuationToken')) {
    Write-Host "  music_client.dart ya trae la paginacion de discografia. No hace falta parchear."
    exit 0
}

# Upstream (gokadzev/Musify) folded the old standalone getArtistReleases/
# getAlbumTracks methods into a combined getArtistProfile/getAlbum API at some
# point. This fork still calls the old, simpler methods directly (see
# artist_service.dart), so instead of adopting the new shape they're
# reinserted here as-is, rebuilt on whichever low-level helpers
# (_browse/_findRenderers/_collectReleases/_collectMoreReleaseBrowses/etc.)
# upstream still exposes. If those helpers themselves get renamed upstream,
# this insertion will still succeed (it doesn't touch them) but the build
# will fail loudly instead - that's still a "needs manual review" case, just
# caught one step later.
$insertAnchor = '  List<MusicTopSong> _parseTopSongs('

$insertIdx = $content.IndexOf($insertAnchor)

if ($insertIdx -lt 0) {
    Write-Host "  [AVISO] No se encontro el punto de referencia esperado; no se pudo parchear automaticamente."
    Write-Host "  Aplica el fix a mano: metodos getArtistReleases/getAlbumTracks (con paginacion) + _continueBrowse/_findContinuationToken (compara con music_client.dart.tu_version_actual)."
    exit 1
}

$newCode = @'
  /// Returns the full discography (albums, singles and EPs) of a YouTube Music
  /// artist.
  Future<List<MusicAlbum>> getArtistReleases(dynamic channelId) async {
    final id = ChannelId.fromString(channelId).value;
    final root = await _browse(id);

    final releases = <String, MusicAlbum>{};
    _collectReleases(root, releases);

    for (final more in _collectMoreReleaseBrowses(root)) {
      try {
        var grid = await _browse(more.$1, params: more.$2);
        _collectReleases(grid, releases);

        // "See all" grids (e.g. an artist's full singles list) are
        // themselves paginated; keep following continuation tokens so large
        // catalogs aren't cut off at the first page.
        var guard = 0;
        var token = _findContinuationToken(grid);
        while (token != null && guard++ < 25) {
          grid = await _continueBrowse(token);
          _collectReleases(grid, releases);
          token = _findContinuationToken(grid);
        }
      } catch (_) {
        // Keep inline releases if a secondary grid fails.
      }
    }

    return releases.values.toList();
  }

  /// Returns the tracks of a release as [Video]s.
  Future<List<Video>> getAlbumTracks(
    String albumBrowseId, {
    required String author,
    String? channelId,
  }) async {
    final root = await _browse(albumBrowseId);
    final resolvedChannelId = (channelId != null && channelId.isNotEmpty)
        ? ChannelId.fromString(channelId)
        : ChannelId('UC0000000000000000000000');

    final videos = <Video>[];
    final seen = <String>{};
    for (final item in _findRenderers(
      root,
      'musicResponsiveListItemRenderer',
    )) {
      final videoId = _trackVideoId(item);
      if (videoId == null || !seen.add(videoId)) continue;

      final title = _flexColumnText(item, 0);
      if (title == null || title.isEmpty) continue;

      videos.add(
        Video(
          VideoId(videoId),
          title,
          author,
          resolvedChannelId,
          null,
          null,
          null,
          '',
          _parseDuration(_fixedColumnText(item)),
          ThumbnailSet(videoId),
          null,
          const Engagement(0, null, null),
          false,
        ),
      );
    }

    return videos;
  }

  Future<_JsonMap> _continueBrowse(String token) {
    return _httpClient.sendPost('browse', {
      'context': _remixContext,
      'continuation': token,
    });
  }

  String? _findContinuationToken(_JsonMap root) {
    for (final renderer in _findRenderers(root, 'continuationItemRenderer')) {
      final token = renderer
          .getMap('continuationEndpoint')
          ?.getMap('continuationCommand')
          ?.getValue<String>('token');
      if (token != null) return token;
    }
    return null;
  }

'@

# Match the target file's line endings (this project's .dart files use CRLF).
# PowerShell here-strings swallow a trailing blank line before the closing
# '@, so the extra blank-line separator is added back explicitly here.
$newCode = (($newCode -replace "`r`n", "`n") -replace "`n", "`r`n") + "`r`n"

$patched = $content.Substring(0, $insertIdx) + $newCode + $content.Substring($insertIdx)

Set-Content -LiteralPath $FilePath -Value $patched -NoNewline
Write-Host "  Parche de getArtistReleases/getAlbumTracks (con paginacion) aplicado automaticamente a music_client.dart."
exit 0
