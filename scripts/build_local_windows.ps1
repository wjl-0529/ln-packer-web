param(
  [switch]$SkipInstall,
  [switch]$Zip
)

$ErrorActionPreference = "Stop"

$Root = Resolve-Path (Join-Path $PSScriptRoot "..")
$PackageName = "bili-novel-UI-Packer"
$ReadmeName = (-join ([char[]](0x4F7F, 0x7528, 0x8BF4, 0x660E))) + ".md"
$DistRoot = Join-Path $Root "dist\local-windows"
$PackageDir = Join-Path $DistRoot $PackageName
$LocalDart = Join-Path $Root ".tools\dart-sdk\bin\dart.exe"
$DartExe = if ($env:DART_EXE) {
  $env:DART_EXE
} elseif (Test-Path $LocalDart) {
  $LocalDart
} else {
  "dart"
}

function Invoke-Checked {
  param(
    [string]$FilePath,
    [string[]]$Arguments
  )
  & $FilePath @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "$FilePath $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
  }
}

Push-Location $Root
try {
  if ($DartExe -eq "dart" -and -not (Get-Command dart -ErrorAction SilentlyContinue)) {
    throw "dart was not found. Install Dart SDK or set DART_EXE to dart.exe."
  }

  if (-not $SkipInstall -and -not (Test-Path "web\node_modules")) {
    Invoke-Checked "npm.cmd" @("--prefix", "web", "install")
  }

  Invoke-Checked "npm.cmd" @("--prefix", "web", "run", "build")
  Invoke-Checked $DartExe @("pub", "get")

  if (Test-Path $PackageDir) {
    Remove-Item -LiteralPath $PackageDir -Recurse -Force
  }

  New-Item -ItemType Directory -Force -Path $PackageDir | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $PackageDir "web") | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $PackageDir "data") | Out-Null

  Invoke-Checked $DartExe @("compile", "exe", "bin/server.dart", "-o", (Join-Path $PackageDir "server.exe"))
  Copy-Item -LiteralPath "web\dist" -Destination (Join-Path $PackageDir "web\dist") -Recurse
  Copy-Item -LiteralPath "packaging\local-windows\start.bat" -Destination $PackageDir
  Copy-Item -LiteralPath "packaging\local-windows\stop.bat" -Destination $PackageDir
  Copy-Item -LiteralPath "packaging\local-windows\README-local.md" -Destination (Join-Path $PackageDir $ReadmeName)

  if ($Zip) {
    $ZipPath = Join-Path $DistRoot "$PackageName.zip"
    if (Test-Path $ZipPath) {
      Remove-Item -LiteralPath $ZipPath -Force
    }
    Compress-Archive -LiteralPath $PackageDir -DestinationPath $ZipPath
  }

  Write-Host "Windows portable package generated: $PackageDir"
} finally {
  Pop-Location
}
