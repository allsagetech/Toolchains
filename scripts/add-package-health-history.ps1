<# Toolchains | SPDX-License-Identifier: MPL-2.0 #>

[CmdletBinding()]
param(
	[Parameter(Mandatory=$true)][string]$CatalogPath,
	[Parameter(Mandatory=$true)][string]$PriorHealthPath,
	[string]$OutputPath = $CatalogPath
)

$ErrorActionPreference = 'Stop'

function ConvertTo-TlcHealthTimestamp {
	param([object]$Value)
	if (-not $Value) { return $null }
	try { return ([datetime]$Value).ToUniversalTime() }
	catch { throw "Invalid package-health timestamp: $Value" }
}

$catalog = Get-Content -LiteralPath $CatalogPath -Raw | ConvertFrom-Json
if ([int]$catalog.schemaVersion -ne 1 -or $null -eq $catalog.packages -or -not $catalog.generatedAt) {
	throw 'The package health catalog is not a supported schemaVersion 1 document.'
}
$generatedAt = ConvertTo-TlcHealthTimestamp -Value $catalog.generatedAt

$priorByName = @{}
if (Test-Path -LiteralPath $PriorHealthPath -PathType Leaf) {
	foreach ($entry in @(Get-Content -LiteralPath $PriorHealthPath -Raw | ConvertFrom-Json)) {
		$name = [string]$entry.Name
		if (-not $name) { $name = [string]$entry.name }
		if ($name) { $priorByName[$name] = $entry }
	}
}

foreach ($package in @($catalog.packages)) {
	$name = [string]$package.name
	if (-not $name) { throw 'A package health catalog entry is missing its name.' }
	$state = [string]$package.state
	$lastScannedAt = ConvertTo-TlcHealthTimestamp -Value $package.lastScannedAt
	$currentLastClean = ConvertTo-TlcHealthTimestamp -Value $package.lastCleanScannedAt
	$prior = $priorByName[$name]
	$priorState = if ($prior) { [string]$prior.State } else { '' }
	if (-not $priorState -and $prior) { $priorState = [string]$prior.state }

	$priorStateSince = if ($prior) { ConvertTo-TlcHealthTimestamp -Value $prior.StateSince } else { $null }
	if (-not $priorStateSince -and $prior) { $priorStateSince = ConvertTo-TlcHealthTimestamp -Value $prior.stateSince }
	$priorLastScannedAt = if ($prior) { ConvertTo-TlcHealthTimestamp -Value $prior.LastScannedAt } else { $null }
	if (-not $priorLastScannedAt -and $prior) { $priorLastScannedAt = ConvertTo-TlcHealthTimestamp -Value $prior.lastScannedAt }
	$priorLastClean = if ($prior) { ConvertTo-TlcHealthTimestamp -Value $prior.LastCleanScannedAt } else { $null }
	if (-not $priorLastClean -and $prior) { $priorLastClean = ConvertTo-TlcHealthTimestamp -Value $prior.lastCleanScannedAt }

	$stateSince = if ($prior -and $priorState -ieq $state) {
		if ($priorStateSince) { $priorStateSince } elseif ($priorLastScannedAt) { $priorLastScannedAt } elseif ($lastScannedAt) { $lastScannedAt } else { $generatedAt }
	} elseif ($lastScannedAt) {
		$lastScannedAt
	} else {
		$generatedAt
	}
	$lastClean = if ($state -ieq 'available') {
		if ($currentLastClean) { $currentLastClean } else { $lastScannedAt }
	} elseif ($priorLastClean) {
		$priorLastClean
	} elseif ($priorState -ieq 'available') {
		$priorLastScannedAt
	} else {
		$null
	}

	$package | Add-Member -NotePropertyName stateSince -NotePropertyValue $stateSince.ToString('o') -Force
	$package | Add-Member -NotePropertyName lastCleanScannedAt -NotePropertyValue $(if ($lastClean) { $lastClean.ToString('o') } else { $null }) -Force
}

$resolvedOutput = [IO.Path]::GetFullPath($OutputPath)
$parent = Split-Path -Parent $resolvedOutput
if ($parent) { [void][IO.Directory]::CreateDirectory($parent) }
[IO.File]::WriteAllText($resolvedOutput, (($catalog | ConvertTo-Json -Depth 20) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
Write-Output "Added state history to $(@($catalog.packages).Count) package health record(s) in $resolvedOutput"
