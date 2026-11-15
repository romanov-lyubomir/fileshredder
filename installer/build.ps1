# Builds the release app and packages it as dist\FileShredder-Setup-<version>.exe.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

$iscc = @(
  "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
  "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
  "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) { throw 'Inno Setup 6 is not installed.' }

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$redist = Get-ChildItem "$vs\VC\Redist\MSVC" -Recurse -Filter 'vcruntime140.dll' |
  Where-Object { $_.FullName -match '\\x64\\Microsoft\.VC\d+\.CRT\\' -and $_.FullName -notmatch 'onecore|debug' } |
  Sort-Object FullName -Descending | Select-Object -First 1
if (-not $redist) { throw 'The Visual C++ runtime was not found.' }

flutter build windows --release
if ($LASTEXITCODE -ne 0) { throw 'flutter build failed.' }

& $iscc "/DVcRedist=$($redist.DirectoryName)" (Join-Path $PSScriptRoot 'fileshredder.iss')
if ($LASTEXITCODE -ne 0) { throw 'Inno Setup failed.' }
