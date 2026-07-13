<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

[CmdletBinding(SupportsShouldProcess)]
param(
	[Parameter(Mandatory=$true)][string]$SourceRoot
)

$ErrorActionPreference = 'Stop'
$source = (Resolve-Path -LiteralPath $SourceRoot).Path
$destination = Join-Path (Split-Path $PSScriptRoot -Parent) 'schema'
$manifest = Get-Content -LiteralPath (Join-Path $source 'package-spec.manifest.json') -Raw | ConvertFrom-Json
$relativeFiles = @('PACKAGE_SPEC_VERSION', 'package-spec.manifest.json', [string]$manifest.schema) + @($manifest.validFixtures) + @($manifest.invalidFixtures)
foreach ($relative in $relativeFiles) {
	$sourcePath = Join-Path $source $relative
	if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { throw "Canonical package specification file is missing: $relative" }
	$destinationPath = Join-Path $destination $relative
	if ($PSCmdlet.ShouldProcess($destinationPath, "Update from canonical package specification v$($manifest.version)")) {
		New-Item -ItemType Directory -Path (Split-Path $destinationPath -Parent) -Force | Out-Null
		Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
	}
}

if (-not $WhatIfPreference) {
	& (Join-Path $PSScriptRoot 'test-package-spec.ps1') -CanonicalRoot $source
}
