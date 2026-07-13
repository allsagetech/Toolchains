<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

[CmdletBinding()]
param(
	[string]$CanonicalRoot
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$specRoot = Join-Path $repoRoot 'schema'
$manifest = Get-Content -LiteralPath (Join-Path $specRoot 'package-spec.manifest.json') -Raw | ConvertFrom-Json
$version = (Get-Content -LiteralPath (Join-Path $specRoot 'PACKAGE_SPEC_VERSION') -Raw).Trim()
if ($version -ne [string]$manifest.version) {
	throw "Package specification version file '$version' does not match manifest version '$($manifest.version)'."
}

. (Join-Path $repoRoot 'src/main.ps1')

foreach ($relative in @($manifest.validFixtures)) {
	$path = Join-Path $specRoot $relative
	$definition = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
	Test-TlcToolchainDefinition -Definition $definition -Context $relative | Out-Null
}
foreach ($relative in @($manifest.invalidFixtures)) {
	$path = Join-Path $specRoot $relative
	$definition = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
	$rejected = $false
	try {
		Test-TlcToolchainDefinition -Definition $definition -Context $relative | Out-Null
	} catch {
		$rejected = $true
	}
	if (-not $rejected) { throw "Invalid package specification fixture was accepted: $relative" }
}

$relativeFiles = @([string]$manifest.schema) + @($manifest.validFixtures) + @($manifest.invalidFixtures)
$builder = New-Object Text.StringBuilder
foreach ($relative in ($relativeFiles | Sort-Object)) {
	$content = [IO.File]::ReadAllText((Join-Path $specRoot $relative)).Replace("`r`n", "`n").Replace("`r", "`n")
	[void]$builder.Append($relative.Replace('\', '/')).Append("`n").Append($content).Append("`n")
}
$hasher = [Security.Cryptography.SHA256]::Create()
try {
	$contentHash = -join ($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($builder.ToString())) | ForEach-Object { $_.ToString('x2') })
} finally {
	$hasher.Dispose()
}
if (-not $manifest.contentSha256 -or $contentHash -ne [string]$manifest.contentSha256) {
	throw "Vendored package specification content hash mismatch. Expected $($manifest.contentSha256), got $contentHash."
}

if (-not $CanonicalRoot) {
	$candidate = Join-Path (Split-Path $repoRoot -Parent) 'Toolchain/schema'
	if (Test-Path -LiteralPath $candidate -PathType Container) { $CanonicalRoot = $candidate }
}
if ($CanonicalRoot) {
	foreach ($relative in @('PACKAGE_SPEC_VERSION', 'package-spec.manifest.json', [string]$manifest.schema) + @($manifest.validFixtures) + @($manifest.invalidFixtures)) {
		$local = (Get-Content -LiteralPath (Join-Path $specRoot $relative) -Raw).Replace("`r`n", "`n").Replace("`r", "`n")
		$canonical = (Get-Content -LiteralPath (Join-Path $CanonicalRoot $relative) -Raw).Replace("`r`n", "`n").Replace("`r", "`n")
		if ($local -cne $canonical) { throw "Vendored package specification drifted from canonical file: $relative" }
	}
}

Write-Host "Validated package specification v$version with $(@($manifest.validFixtures).Count) valid and $(@($manifest.invalidFixtures).Count) invalid fixtures."
