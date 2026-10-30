@echo off
rem Netis NX62 / Netcore N60 Pro: OpenWrt 25.12.5 from Windows, see flash-windows.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0flash-windows.ps1" %*
pause
