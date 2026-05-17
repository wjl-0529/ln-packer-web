@echo off
setlocal
if exist "%~dp0server.pid" (
  for /f %%p in (%~dp0server.pid) do taskkill /PID %%p /F >nul 2>nul
  del "%~dp0server.pid" >nul 2>nul
)
endlocal
