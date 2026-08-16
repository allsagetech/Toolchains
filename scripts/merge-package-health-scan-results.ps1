<# Toolchains | SPDX-License-Identifier: MPL-2.0 #>

[CmdletBinding()]
param(
	[Parameter(Mandatory=$true)][string]$PriorHealthPath,
	[Parameter(Mandatory=$true)][string]$EvidenceRoot,
	[Parameter(Mandatory=$true)][string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$results = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)

function Add-PackageScanResult {
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

	$results[$package] = [pscustomobject][ordered]@{
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
	Add-PackageScanResult -Source $PriorHealthPath -Result ([pscustomobject]@{
		package = [string]$entry.Name
		state = [string]$entry.State
		reason = [string]$entry.Reason
		scannedAt = $entry.LastScannedAt
		digest = [string]$entry.Digest
	})
}

if (Test-Path -LiteralPath $EvidenceRoot -PathType Container) {
	foreach ($file in Get-ChildItem -LiteralPath $EvidenceRoot -Recurse -File -Filter '*.health.json' | Sort-Object FullName) {
		$document = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
		$current = if ($null -ne $document.results) { @($document.results) } else { @($document) }
		foreach ($result in $current) { Add-PackageScanResult -Result $result -Source $file.FullName }
	}
}

$document = [ordered]@{
	schemaVersion = 1
	results = @($results.Values | Sort-Object package)
}
$parent = Split-Path -Parent ([IO.Path]::GetFullPath($OutputPath))
if ($parent) { [void][IO.Directory]::CreateDirectory($parent) }
[IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath), (($document | ConvertTo-Json -Depth 10) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
Write-Output "Wrote $($results.Count) preserved or current package scan result(s) to $OutputPath"
