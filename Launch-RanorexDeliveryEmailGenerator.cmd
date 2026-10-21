@echo off
start "Ranorex TFS Proxy" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-RanorexDeliveryEmailGenerator.ps1"
