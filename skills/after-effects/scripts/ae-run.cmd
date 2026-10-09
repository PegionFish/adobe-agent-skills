@echo off
rem ae-run.cmd - Convenience wrapper for runner.ps1 (Windows)
rem Usage: ae-run.cmd [-Background|-NoUi] <script.jsx> [args-json]
rem Example: ae-run.cmd -Background 'scripts\active-state.jsx'
rem Propagates runner.ps1's exit code (1 error, 2 version choice, 3 blocked).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0runner.ps1" %*
exit /b %ERRORLEVEL%
