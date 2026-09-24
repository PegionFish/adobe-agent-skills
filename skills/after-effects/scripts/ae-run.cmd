@echo off
rem ae-run.cmd - Convenience wrapper for runner.ps1 (Windows)
rem Usage: ae-run.cmd [-Background|-NoUi] <script.jsx> [args-json]
rem Example: ae-run.cmd -Background 'scripts\active-state.jsx'
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0runner.ps1" %*
exit /b 0
