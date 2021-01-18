@echo off
powershell -ExecutionPolicy Unrestricted -Command "try {%~dp0\RunExtractor.ps1 %*} catch {$host.SetShouldExit(99); throw $_}"
exit /B %ERRORLEVEL%
