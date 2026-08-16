<# Toolchains | SPDX-License-Identifier: MPL-2.0 #>

[CmdletBinding()]
param(
	[Parameter(Mandatory=$true)][string]$PriorHealthPath,
	[Parameter(Mandatory=$true)][string]$EvidenceRoot,
	[Parameter(Mandatory=$true)][string]$OutputPath,
	[switch]$CurrentResultsAuthoritative
)

$ErrorActionPreference = 'Stop'
$results = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)

function ConvertTo-PackageScanResult {
	param(
		[Parameter(Mandatory=$true)][object]$Result,
		[Parameter(Mandatory=$true)][string]$Source
	)

	$package = [string]$Result.package
	if ($package -notmatch '^[A-Za-z0-9._-]+$') { throw "Invalid package name in $Source." }
	$state = [string]$Result.state
	if ($state -notin @('available','scan-blocked','scan-error','quarantined','unavailable')) { throw "Invalid scan state for '$package' in $Source." }
	try { $scannedAt = ([datetime]$Result.scannedAt).ToUniversalTime() }
	catch { throw "Invalid scan timestamp for '$package' in $Source." }
	$digest = [string]$Result.digest
	if ($digest -and $digest -notmatch '^sha256:[0-9a-f]{64}$') { throw "Invalid scan digest for '$package' in $Source." }

	return [pscustomobject][ordered]@{
		package = $package
		state = $state
		reason = [string]$Result.reason
		scannedAt = $scannedAt.ToString('o')
		digest = $(if ($digest) { $digest } else { $null })
	}
}

if (-not (Test-Path -LiteralPath $PriorHealthPath -PathType Leaf)) { throw "Prior health file does not exist: $PriorHealthPath" }
$priorEntries = @(Get-Content -LiteralPath $PriorHealthPath -Raw | ConvertFrom-Json)
foreach ($entry in $priorEntries) {
	if (-not $entry.LastScannedAt) { continue }
	$normalized = ConvertTo-PackageScanResult -Source $PriorHealthPath -Result ([pscustomobject]@{
		package = [string]$entry.Name
		state = [string]$entry.State
		reason = [string]$entry.Reason
		scannedAt = $entry.LastScannedAt
		digest = [string]$entry.Digest
	})
	$results[[string]$normalized.package] = $normalized
}

$currentResults = @()
if (Test-Path -LiteralPath $EvidenceRoot -PathType Container) {
	$evidenceFiles = @(
		@(Get-ChildItem -LiteralPath $EvidenceRoot -Recurse -File -Filter '*.health.json')
		@(Get-ChildItem -LiteralPath $EvidenceRoot -Recurse -File -Filter 'result.json')
	) | Sort-Object FullName -Unique
	foreach ($file in $evidenceFiles) {
		$document = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
		$current = if ($null -ne $document.results) { @($document.results) } else { @($document) }
		foreach ($result in $current) { $currentResults += ConvertTo-PackageScanResult -Result $result -Source $file.FullName }
	}
}

foreach ($group in $currentResults | Group-Object package) {
	$members = @($group.Group)
	$state = @('scan-blocked','scan-error','quarantined','unavailable','available') |
		Where-Object { $candidate = $_; @($members | Where-Object state -eq $candidate).Count -gt 0 } |
		Select-Object -First 1
	$latest = $members | Sort-Object { [datetime]$_.scannedAt } -Descending | Select-Object -First 1
	$current = [pscustomobject][ordered]@{
		package = [string]$group.Name
		state = [string]$state
		reason = (@($members.reason | Where-Object { $_ } | Sort-Object -Unique) -join ' ')
		scannedAt = [string]$latest.scannedAt
		digest = [string]$latest.digest
	}
	$existing = $results[[string]$group.Name]
	$replace = $CurrentResultsAuthoritative -or $null -eq $existing -or $current.state -ne 'available' -or $existing.state -eq 'available'
	if ($replace) { $results[[string]$group.Name] = $current }
}

$document = [ordered]@{
	schemaVersion = 1
	results = @($results.Values | Sort-Object package)
}
$parent = Split-Path -Parent ([IO.Path]::GetFullPath($OutputPath))
if ($parent) { [void][IO.Directory]::CreateDirectory($parent) }
[IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath), (($document | ConvertTo-Json -Depth 10) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
Write-Output "Wrote $($results.Count) preserved or current package scan result(s) to $OutputPath"
