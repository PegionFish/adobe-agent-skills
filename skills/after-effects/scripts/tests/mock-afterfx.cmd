@echo off
rem mock-afterfx.cmd - Stub AfterFX.exe used by tests\smoke.ps1.
rem Emulates just enough of the real binary: it echoes the command line it
rem received (so tests can assert the -s payload) and copies the args file to
rem the result file (so tests can assert the argument round-trip).
rem
rem MOCK_AE_MODE:
rem   ok       (default) write the result file
rem   noresult do not write anything, exit 0
rem   fail     exit with code 3
setlocal
echo MOCK_STDOUT: args=%*
echo MOCK_STDERR: none 1>&2
if "%MOCK_AE_MODE%"=="noresult" exit /b 0
if "%MOCK_AE_MODE%"=="fail" exit /b 3
powershell -NoProfile -Command "$a=[System.IO.File]::ReadAllText([System.IO.Path]::Combine($env:TEMP,'ae-assistant-args.json')); [System.IO.File]::WriteAllText([System.IO.Path]::Combine($env:TEMP,'ae-assistant-result.json'), $a)"
exit /b 0
