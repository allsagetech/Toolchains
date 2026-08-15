<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

[CmdletBinding()]
param(
	[Parameter(Mandatory=$true)][string]$OutputPath,
	[string]$Repository = 'allsagetech/toolchains',
	[string]$ScanResultsPath
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $repoRoot 'src/main.ps1')

$scanResults = @{}
if ($ScanResultsPath -and (Test-Path -LiteralPath $ScanResultsPath -PathType Leaf)) {
	$scanDocument = Get-Content -LiteralPath $ScanResultsPath -Raw | ConvertFrom-Json
	foreach ($result in @($scanDocument.results)) { $scanResults[[string]$result.package] = $result }
}

$tags = @((Get-DockerTags $Repository).tags)
$records = @()
try {
	foreach ($script in Get-ChildItem -LiteralPath (Join-Path $repoRoot 'src/pkgs') -Recurse -File -Filter '*.ps1' | Sort-Object FullName) {
		Clear-TlcPackageScript
		& $script.FullName
		Test-TlcPackageScript
		$publication = Get-TlcPackagePublicationState
		$name = [string]$TlcPackageConfig.Name
		$canonicalName = if ($TlcPackageConfig.CanonicalName) { [string]$TlcPackageConfig.CanonicalName } else { $name }
		$platform = if ($TlcPackageConfig.Platform) { [string]$TlcPackageConfig.Platform } elseif (Test-TlcRunsOnUbuntu -RunsOn (Get-TlcPackageRunsOn)) { 'linux/amd64' } else { 'windows/amd64' }
		$matcher = if ($TlcPackageConfig.Matcher) { [string]$TlcPackageConfig.Matcher } else { "^$([regex]::Escape($name))-([0-9].+)$" }
		$versions = @($tags | Where-Object { $_ -match $matcher } | ForEach-Object {
			if ($_ -match "^$([regex]::Escape($name))-(.+)$") { $Matches[1].Replace('_', '+') }
		} | Where-Object { $_ } | Sort-Object -Unique)
		$scan = $scanResults[$name]
		$state = if (-not $publication.PublishEligible) { 'quarantined' } elseif ($scan -and [string]$scan.state -ne 'available') { [string]$scan.state } elseif ($versions.Count -gt 0) { 'available' } else { 'unavailable' }
		$reason = if (-not $publication.PublishEligible) { [string]$publication.QuarantineReason } elseif ($scan -and $scan.reason) { [string]$scan.reason } elseif ($versions.Count -eq 0) { 'No durable package version is currently published.' } else { '' }
		$records += [pscustomobject]@{
			name = $name
			canonicalName = $canonicalName
			platform = $platform
			state = $state
			reason = $reason
			versions = $versions
			lastScannedAt = if ($scan -and $scan.scannedAt) { [string]$scan.scannedAt } else { $null }
			digest = if ($scan -and $scan.digest) { [string]$scan.digest } else { $null }
			upstream = if ($TlcPackageConfig.Upstream) { [string]$TlcPackageConfig.Upstream } else { $null }
		}
	}
} finally { Clear-TlcPackageScript }

$packages = foreach ($group in $records | Group-Object canonicalName | Sort-Object Name) {
	$members = @($group.Group)
	$available = @($members | Where-Object state -eq 'available')
	$problem = @($members | Where-Object state -ne 'available')
	$state = if ($available.Count -gt 0) { 'available' } elseif (@($members | Where-Object state -eq 'quarantined').Count -eq $members.Count) { 'quarantined' } elseif (@($members | Where-Object state -eq 'scan-blocked').Count -gt 0) { 'scan-blocked' } else { 'unavailable' }
	$versionsByPlatform = @($available | Group-Object platform | ForEach-Object {
		[pscustomobject]@{ Platform = $_.Name; Versions = @($_.Group.versions | ForEach-Object { $_ } | Sort-Object -Unique) }
	})
	$safeVersions = if ($versionsByPlatform.Count -eq 0) {
		@()
	} elseif ($versionsByPlatform.Count -eq 1) {
		@($versionsByPlatform[0].Versions)
	} else {
		$common = @($versionsByPlatform[0].Versions)
		foreach ($platformVersions in $versionsByPlatform | Select-Object -Skip 1) {
			$set = [Collections.Generic.HashSet[string]]::new([string[]]@($platformVersions.Versions), [StringComparer]::Ordinal)
			$common = @($common | Where-Object { $set.Contains([string]$_) })
		}
		@($common | Sort-Object -Unique)
	}
	[ordered]@{
		name = [string]$group.Name
		state = $state
		reason = (@($problem.reason | Where-Object { $_ } | Sort-Object -Unique) -join ' ')
		versions = @($safeVersions)
		blockedVersions = @($problem.versions | ForEach-Object { $_ } | Sort-Object -Unique)
		platforms = @($members.platform | Sort-Object -Unique)
		aliases = @($members.name | Where-Object { $_ -ne $group.Name } | Sort-Object -Unique)
		lastScannedAt = ($members.lastScannedAt | Where-Object { $_ } | Sort-Object -Descending | Select-Object -First 1)
		digest = ($members.digest | Where-Object { $_ } | Select-Object -First 1)
		upstream = ($members.upstream | Where-Object { $_ } | Sort-Object -Unique | Select-Object -First 1)
	}
}

$document = [ordered]@{
	schemaVersion = 1
	generatedAt = [datetime]::UtcNow.ToString('o')
	repository = $Repository
	packages = @($packages)
}
$parent = Split-Path -Parent ([IO.Path]::GetFullPath($OutputPath))
if ($parent) { [void][IO.Directory]::CreateDirectory($parent) }
[IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath), (($document | ConvertTo-Json -Depth 20) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
Write-Output "Wrote health catalog for $($packages.Count) logical packages to $OutputPath"
