<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

param(
	[switch]$SkipPush
)

$ErrorActionPreference = 'Stop'

$isWindowsHost = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)
if ($isWindowsHost) {
	throw 'This script is for Linux package builds. Run it on a Linux host or Linux CI runner.'
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $repoRoot

. .\src\main.ps1

$packageScripts = @(
	'.\src\pkgs\codex-linux.ps1'
	'.\src\pkgs\git-linux.ps1'
	'.\src\pkgs\llvm-linux.ps1'
)

foreach ($pkg in $packageScripts) {
	Write-Host "=============================="
	Write-Host "PACKAGE SCRIPT: $pkg"
	Write-Host "=============================="

	Clear-TlcPackageScript
	Invoke-TlcScript $pkg

	if ($TlcPackageConfig.UpToDate) {
		Write-Host "Skip: $($TlcPackageConfig.Name) up-to-date"
		continue
	}

	Test-TlcPackageInstall
	Assert-TlcDefinitionFile | Out-Null

	if ($SkipPush) {
		Write-Host "Built and tested (skip push): $($TlcPackageConfig.Name) $($TlcPackageConfig.Version)"
		continue
	}

	Invoke-DockerPush $TlcPackageConfig.Name $TlcPackageConfig.Version
	if ($LASTEXITCODE -ne 0) {
		throw "Invoke-DockerPush failed (exit code $LASTEXITCODE) for $($TlcPackageConfig.Name)"
	}
	Write-Host "Pushed: $($TlcPackageConfig.Name) $($TlcPackageConfig.Version)"
}

Clear-TlcPackageScript
