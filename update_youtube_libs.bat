@echo off
setlocal enabledelayedexpansion

REM ============================================================
REM  Descarga los archivos "sensibles a cambios de YouTube" desde
REM  el repositorio original de Musify (gokadzev/Musify), por si
REM  YouTube rompe algo y ellos ya lo han arreglado ahi.
REM
REM  Esto SOLO descarga archivos sueltos a sus rutas dentro de
REM  packages\. No compila ni modifica nada mas. Revisa los
REM  cambios (o simplemente prueba a compilar) despues de usarlo.
REM ============================================================

set REPO=gokadzev/Musify
set DESTROOT=%~dp0

where curl >nul 2>nul
if errorlevel 1 (
    echo No se encontro "curl" en este sistema. Windows 10/11 lo trae de
    echo serie normalmente; si no lo tienes, instala curl e intenta de nuevo.
    pause
    exit /b 1
)

echo Consultando la rama por defecto de %REPO%...
set BRANCH=
for /f "usebackq delims=" %%A in (`powershell -NoProfile -Command "try { (Invoke-RestMethod 'https://api.github.com/repos/%REPO%').default_branch } catch {}"`) do (
    set BRANCH=%%A
)
if "%BRANCH%"=="" set BRANCH=master

echo Rama detectada: %BRANCH%
set BASEURL=https://raw.githubusercontent.com/%REPO%/%BRANCH%
echo.

REM ---- youtube_explode_dart (tiene repo publico propio tambien: Hexer10/youtube_explode_dart) ----
call :download packages/youtube_explode_dart/lib/src/reverse_engineering/youtube_http_client.dart
call :download packages/youtube_explode_dart/lib/src/reverse_engineering/player/player_response.dart
call :download packages/youtube_explode_dart/lib/src/reverse_engineering/player/player_source.dart
call :download packages/youtube_explode_dart/lib/src/reverse_engineering/cipher/cipher_manifest.dart
call :download packages/youtube_explode_dart/lib/src/reverse_engineering/cipher/cipher_operations.dart
call :download packages/youtube_explode_dart/lib/src/reverse_engineering/challenges/js_challenge.dart
call :download packages/youtube_explode_dart/lib/src/reverse_engineering/challenges/ejs/base_ejs_solver.dart
call :download packages/youtube_explode_dart/lib/src/reverse_engineering/challenges/ejs/deno_ejs_solver.dart
call :download packages/youtube_explode_dart/lib/src/reverse_engineering/challenges/ejs/ejs.dart
call :download packages/youtube_explode_dart/lib/src/reverse_engineering/challenges/ejs/ejs_modules.g.dart
call :download packages/youtube_explode_dart/lib/src/reverse_engineering/pages/search_page.dart
call :download packages/youtube_explode_dart/lib/src/reverse_engineering/pages/watch_page.dart
call :download packages/youtube_explode_dart/lib/src/reverse_engineering/pages/playlist_page.dart
call :download packages/youtube_explode_dart/lib/src/reverse_engineering/pages/channel_page.dart
call :download packages/youtube_explode_dart/lib/src/reverse_engineering/pages/channel_upload_page.dart
call :download packages/youtube_explode_dart/lib/src/reverse_engineering/pages/channel_about_page.dart
call :download packages/youtube_explode_dart/lib/src/reverse_engineering/dash_manifest.dart
call :download packages/youtube_explode_dart/lib/src/reverse_engineering/hls_manifest.dart

REM ---- youtube_music_explode_dart: OJO, aqui SI modificamos nosotros mismos ----
REM      music_client.dart (paginacion del catalogo de artista). Se descarga
REM      la version del repositorio, se guarda tu version actual por si acaso,
REM      y despues se reaplica automaticamente el parche de paginacion.
echo.
echo Actualizando music_client.dart y reaplicando el parche de paginacion...
set "MUSICCLIENT=%DESTROOT%packages\youtube_music_explode_dart\lib\src\music_client.dart"
if exist "%MUSICCLIENT%" (
    copy /y "%MUSICCLIENT%" "%MUSICCLIENT%.tu_version_actual" >nul
)
call :download packages/youtube_music_explode_dart/lib/src/music_client.dart
powershell -NoProfile -ExecutionPolicy Bypass -File "%DESTROOT%patch_music_client.ps1" -FilePath "%MUSICCLIENT%"

echo.
echo Listo. Cada archivo sobrescrito tiene una copia .bak junto a el
echo (y music_client.dart tiene ademas .tu_version_actual) por si hay
echo que deshacer algo. Si arriba ves un [AVISO] en music_client.dart,
echo el parche automatico no se pudo aplicar y hay que revisarlo a mano
echo comparando con el .tu_version_actual. Intenta compilar despues de esto.
pause
goto :eof

:download
set "FILE=%~1"
set "DEST=%DESTROOT%%FILE%"
set "DEST=%DEST:/=\%"

if exist "%DEST%" (
    copy /y "%DEST%" "%DEST%.bak" >nul
)

echo Descargando %FILE% ...
curl -s --ssl-no-revoke -o "%DEST%" "%BASEURL%/%FILE%"
if errorlevel 1 (
    echo   [ERROR] No se pudo descargar %FILE%
) else (
    echo   OK
)
goto :eof
