@echo off
rem One-time installer: fetches the connector scripts into %LOCALAPPDATA% and registers them for this user.
set "DEST=%LOCALAPPDATA%\RanorexTfsConnector"
if not exist "%DEST%" mkdir "%DEST%"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; foreach ($f in 'Start-RanorexDeliveryEmailGenerator.ps1','Register-RanorexProtocol.ps1') { Invoke-WebRequest -UseBasicParsing -Uri ('https://giridharmv.github.io/' + $f) -OutFile (Join-Path $env:LOCALAPPDATA ('RanorexTfsConnector\' + $f)) }"
if errorlevel 1 (
    echo Download failed. Check your network connection and try again.
    pause
    exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%DEST%\Register-RanorexProtocol.ps1"
timeout /t 3 >nul
