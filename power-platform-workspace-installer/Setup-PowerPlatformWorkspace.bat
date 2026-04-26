@echo off
title Power Platform Workspace Setup
echo.
echo  ===============================================
echo   Power Platform Workspace — One-click Setup
echo  ===============================================
echo.
:: -ExecutionPolicy Bypass is required because many organisations restrict
:: PowerShell script execution by default (e.g. AllSigned or Restricted).
:: This flag applies only to this single process — it does not change the
:: machine-wide or user-level policy. Once the window closes, the override
:: is gone. The .ps1 script is fully readable and open source.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup-PowerPlatformWorkspace.ps1"
echo.
pause
