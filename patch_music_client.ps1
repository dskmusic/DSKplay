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

$startAnchor = '  Future<List<MusicAlbum>> getArtistReleases(dynamic channelId) async {'
$endAnchor = '  /// Returns the top tracks shown on the YouTube Music artist page.'
$helperAnchor = '  void _collectReleases(_JsonMap root, Map<String, MusicAlbum> into) {'

$startIdx = $content.IndexOf($startAnchor)
$endIdx = $content.IndexOf($endAnchor)
$helperIdx = $content.IndexOf($helperAnchor)

if ($startIdx -lt 0 -or $endIdx -lt 0 -or $helperIdx -lt 0 -or $endIdx -le $startIdx) {
    Write-Host "  [AVISO] No se encontraron los puntos de referencia esperados; no se pudo parchear automaticamente."
    Write-Host "  Aplica el fix a mano: bucle de paginacion en getArtistReleases + metodos _continueBrowse/_findContinuationToken (compara con music_client.dart.tu_version_actual)."
    exit 1
}

$newMethod = @'
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

'@

$helperMethods = @'
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
$newMethod = (($newMethod -replace "`r`n", "`n") -replace "`n", "`r`n") + "`r`n"
$helperMethods = (($helperMethods -replace "`r`n", "`n") -replace "`n", "`r`n") + "`r`n"

$patched = $content.Substring(0, $startIdx) + $newMethod + $content.Substring($endIdx)

$helperIdx2 = $patched.IndexOf($helperAnchor)
if ($helperIdx2 -lt 0) {
    Write-Host "  [AVISO] No se pudo insertar _continueBrowse/_findContinuationToken automaticamente."
    Set-Content -LiteralPath $FilePath -Value $patched -NoNewline
    exit 1
}
$patched = $patched.Substring(0, $helperIdx2) + $helperMethods + $patched.Substring($helperIdx2)

Set-Content -LiteralPath $FilePath -Value $patched -NoNewline
Write-Host "  Parche de paginacion de discografia aplicado automaticamente a music_client.dart."
