@echo off
setlocal
set "APP_DIR=%~dp0"
if "%PACKER_PORT%"=="" set "PACKER_PORT=8080"
set "PACKER_HOST=127.0.0.1"
set "PACKER_PUBLIC_DIR=%APP_DIR%web\dist"
set "PACKER_DATA_DIR=%APP_DIR%data"
if "%PACKER_MAX_CONCURRENT%"=="" set "PACKER_MAX_CONCURRENT=1"
if "%PACKER_FILE_TTL_HOURS%"=="" set "PACKER_FILE_TTL_HOURS=24"
if not exist "%PACKER_DATA_DIR%" mkdir "%PACKER_DATA_DIR%"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$app=$env:APP_DIR; $exe=Join-Path $app 'server.exe'; if(!(Test-Path $exe)){throw 'server.exe was not found.'}; $p=Start-Process -FilePath $exe -WorkingDirectory $app -WindowStyle Hidden -PassThru; Set-Content -Path (Join-Path $app 'server.pid') -Value $p.Id -Encoding ASCII"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$url='http://localhost:%PACKER_PORT%/api/health'; for($i=0;$i -lt 30;$i++){ try{Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 1 | Out-Null; break}catch{Start-Sleep -Milliseconds 500} }"
start "" "http://localhost:%PACKER_PORT%"
endlocal
