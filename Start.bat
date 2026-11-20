@echo off
rem Opens Lightweight APK Builder (no admin rights needed).
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0ApkBuilder.ps1"
