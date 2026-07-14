<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

[CmdletBinding()]
param(
	[Parameter(Mandatory=$true)][string]$OutputPath,
	[string]$Repository = $(if ($env:TLC_DOCKER_REPO) { $env:TLC_DOCKER_REPO } else { 'allsagetech/toolchains' })
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $repoRoot
. .\src\main.ps1

if ($Repository -notmatch '^[a-z0-9][a-z0-9._-]*/[a-z0-9][a-z0-9._-]*$') {
	throw "Model marker publication requires a Docker Hub namespace/repository, got '$Repository'."
}

$configs = @()
try {
	$packageScripts = Get-ChildItem -Path .\src\pkgs -Filter '*.ps1' -Recurse -File | Sort-Object FullName
	foreach ($packageScript in $packageScripts) {
		Clear-TlcPackageScript
		& $packageScript.FullName
		Test-TlcPackageScript
		$configs += ,[pscustomobject]@{
			Name = [string]$TlcPackageConfig.Name
			Tier = if ($TlcPackageConfig.Tier) { [string]$TlcPackageConfig.Tier } else { 'tooling' }
		}
	}
} finally {
	Clear-TlcPackageScript
}

$modelPackages = @(Get-TlcModelCategoryPackages -PackageConfigs $configs)

$document = [ordered]@{
	schemaVersion   = 1
	repository      = $Repository
	desiredPackages = @($modelPackages | ForEach-Object { [string]$_.Package })
}

$outputFullPath = [IO.Path]::GetFullPath($OutputPath)
$outputDirectory = Split-Path -Parent $outputFullPath
if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
	New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}
$temporaryPath = "$outputFullPath.$([Guid]::NewGuid().ToString('n')).tmp"
try {
	[IO.File]::WriteAllText($temporaryPath, ($document | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
	Move-Item -LiteralPath $temporaryPath -Destination $outputFullPath -Force
} finally {
	Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
}

Write-Host "Exported $($modelPackages.Count) desired model package name(s) to $outputFullPath."
