<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$ErrorActionPreference = 'Stop'

$pkgRoot = $env:TLC_PKG_ROOT
if (-not $pkgRoot) { $pkgRoot = "D:\pkg" }

Write-Host "Using TLC_PKG_ROOT=$pkgRoot"

if (Test-Path $pkgRoot) { Remove-Item -Recurse -Force $pkgRoot }
New-Item -ItemType Directory -Path $pkgRoot -Force | Out-Null

. .\src\main.ps1

Get-ChildItem -Recurse .\src\pkgs\ -Filter *.ps1 | ForEach-Object {
  Write-Host "=============================="
  Write-Host "PACKAGE SCRIPT: $($_.FullName)"
  Write-Host "=============================="

  $stageRoot = Join-Path $pkgRoot "_stage"
  if (Test-Path $stageRoot) { Remove-Item -Recurse -Force $stageRoot }
  New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null

  $env:TLC_STAGE_ROOT = $stageRoot

  Clear-TlcPackageScript
  Invoke-TlcScript $_.FullName

  $upToDate = $false
  if ($null -ne $TlcPackageConfig) {
    $p = $TlcPackageConfig.PSObject.Properties["UpToDate"]
    if ($null -ne $p) { $upToDate = [bool]$p.Value }
  }

  if (-not $upToDate) {
    Test-TlcPackageInstall
    Assert-TlcDefinitionFile | Out-Null
    Invoke-DockerPush $TlcPackageConfig.Name $TlcPackageConfig.Version
    if ($LASTEXITCODE -ne 0) { throw "Invoke-DockerPush failed (exit code $LASTEXITCODE)" }
    Write-Host "Pushed: $($TlcPackageConfig.Name) $($TlcPackageConfig.Version)"
  } else {
    Write-Host "Skip: $($_.Name) up-to-date"
  }
}
