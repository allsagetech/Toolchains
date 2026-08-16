<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

param(
	[switch]$SkipPush,
	[switch]$IncludeModels,
	[string[]]$ModelPackages
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
	'.\src\pkgs\git-linux.ps1'
)

if ($IncludeModels) {
	if (-not $ModelPackages -or $ModelPackages.Count -eq 0) {
		$ModelPackages = @(
			'smollm2-135m-instruct'
			'smollm2-360m-instruct'
			'qwen2.5-0.5b-instruct'
			'qwen3-0.6b'
		)
	}
	foreach ($modelPackage in $ModelPackages) {
		$scriptPath = if ($modelPackage -match '\.ps1$') { $modelPackage } else { ".\src\pkgs\$modelPackage.ps1" }
		$packageScripts += $scriptPath
	}
}

foreach ($pkg in $packageScripts) {
	Write-Host "=============================="
	Write-Host "PACKAGE SCRIPT: $pkg"
	Write-Host "=============================="

	$config = Invoke-TlcPackageLifecycle -Path $pkg -Publish:(-not $SkipPush)

	if ($config.UpToDate) {
		Write-Host "Skip: $($config.Name) up-to-date"
		continue
	}

	if ($SkipPush) {
		Write-Host "Built and tested (skip push): $($config.Name) $($config.Version)"
		continue
	}

	Write-Host "Pushed: $($config.Name) $($config.Version)"
}
