# Windows: build + unit tests + publish a self-contained folder.   Usage:  .\build.ps1
$ErrorActionPreference = 'Stop'
dotnet test tests\MotionRecord.Core.Tests -c Release
dotnet publish src\MotionRecord.App -c Release -r win-x64 --self-contained -o publish
Write-Host "`nГотово: publish\MotionRecord.exe"
Write-Host "Нужен ffmpeg.exe рядом с ним:  .\fetch-ffmpeg.ps1"
