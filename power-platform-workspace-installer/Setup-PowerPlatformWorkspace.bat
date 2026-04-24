@echo off
title Power Platform Workspace Setup
echo.
echo  ===============================================
echo   Power Platform Workspace — One-click Setup
echo  ===============================================
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup-PowerPlatformWorkspace.ps1"
echo.
pause
