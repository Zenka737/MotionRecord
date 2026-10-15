# Скачивает ffmpeg (gyan.dev essentials build) и кладёт ffmpeg.exe в publish\ и tools\ffmpeg\.  Запускайте сами, когда нужно.
$ErrorActionPreference = 'Stop'
$zip = Join-Path $env:TEMP 'ffmpeg-release-essentials.zip'
Invoke-WebRequest 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip' -OutFile $zip
$tmp = Join-Path $env:TEMP 'mr-ffmpeg'; if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
Expand-Archive $zip $tmp
$exe = Get-ChildItem $tmp -Recurse -Filter ffmpeg.exe | Select-Object -First 1
foreach ($d in @('publish', 'tools\ffmpeg')) { New-Item -ItemType Directory -Force $d | Out-Null; Copy-Item $exe.FullName $d }
Write-Host "ffmpeg.exe скопирован в publish\ и tools\ffmpeg\"
