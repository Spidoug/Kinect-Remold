[CmdletBinding()]
param(
    [string]$JdkHome = '',
    [string]$Output = ''
)
$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$AppRoot = Join-Path $RepoRoot 'binaries\windows\applications\SynKinectStudio'
$StudioBuilder = Join-Path $PSScriptRoot 'Build-Studio.ps1'
$RuntimeJava = Join-Path $AppRoot 'runtime\bin\java.exe'
$NativeExe = Join-Path $AppRoot 'SynKinectStudio.exe'
if (!$Output) { $Output = Join-Path $RepoRoot 'binaries\windows\applications\SynKinectStudio.zip' }

if (!(Test-Path -LiteralPath $NativeExe -PathType Leaf) -or !(Test-Path -LiteralPath $RuntimeJava -PathType Leaf)) {
  & $StudioBuilder -JdkHome $JdkHome
  if ($LASTEXITCODE -ne 0) { throw "Studio native application build failed with exit code $LASTEXITCODE." }
}
if (!(Test-Path -LiteralPath $NativeExe -PathType Leaf)) { throw "Release invariant violated: $NativeExe is missing." }
if (!(Test-Path -LiteralPath $RuntimeJava -PathType Leaf)) { throw "Release invariant violated: $RuntimeJava is missing." }

$required = @(
  'SynKinectStudio.exe', 'app\SynKinectStudio.jar', 'app\core-4.4.6.jar',
  'app\gluegen-rt-2.5.0.jar', 'app\jogl-all-2.5.0.jar', 'app\SynKinectStudio-module-api.jar',
  'app\gluegen-rt-2.5.0-natives-windows-amd64.jar', 'app\jogl-all-2.5.0-natives-windows-amd64.jar',
  'runtime\bin\java.exe', 'runtime\bin\javaw.exe', 'data\studio\config\config.properties', 'data\studio\resources\synkinect-studio-icon.png'
)
foreach ($relative in $required) {
  $path = Join-Path $AppRoot $relative
  if (!(Test-Path -LiteralPath $path -PathType Leaf)) { throw "Release invariant violated: missing $relative" }
}

$outDir = Split-Path -Parent $Output
if (!(Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
if (Test-Path -LiteralPath $Output) { Remove-Item -LiteralPath $Output -Force }
Compress-Archive -Path (Join-Path $AppRoot '*') -DestinationPath $Output -CompressionLevel Optimal
Write-Host "Portable Windows release created: $Output" -ForegroundColor Green
