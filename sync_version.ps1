# ponytail: Windows-native replacement for update.sh. On Windows, plain
# `bash` often resolves to the WSL launcher instead of Git Bash and fails
# if no WSL distro is installed, so this avoids bash entirely.
$pubspec = Get-Content pubspec.yaml -Raw
if ($pubspec -match 'version:\s*([\d.]+)\+(\d+)') {
    $content = "const appVersion = '$($matches[1])';`nconst appBuildNumber = '$($matches[2])';`n"
    Set-Content -Path 'lib/constants/version.dart' -Value $content -NoNewline
}
