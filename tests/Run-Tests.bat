@echo off
REM Runs the full Pester test suite in this folder.
REM Uses %~dp0 so the path works for any user / any clone location.
setlocal

set "TESTS_DIR=%~dp0"

echo Running Pester tests in "%TESTS_DIR%"
echo.

powershell -NoProfile -ExecutionPolicy Bypass -Command "Import-Module Pester -MinimumVersion 5.0; $r = Invoke-Pester -Path '%TESTS_DIR%' -Output Detailed -PassThru; exit $r.FailedCount"
set "RC=%ERRORLEVEL%"

echo.
if not "%RC%"=="0" (echo %RC% test(s) FAILED.) else (echo All tests passed.)
echo Done. Press any key to close.
pause >nul
endlocal & exit /b %RC%
