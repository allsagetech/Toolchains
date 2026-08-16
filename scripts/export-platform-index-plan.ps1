<# Toolchains | SPDX-License-Identifier: MPL-2.0 #>
[CmdletBinding()]
param(
	[Parameter(Mandatory=$true)][string]$OutputPath,
	[string]$Repository = 'allsagetech/toolchains',
	[string[]]$Tags
)
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $repoRoot 'src/main.ps1')
$descriptors = @()
$packagePaths = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'src/pkgs') -Recurse -File -Filter '*.ps1' | Sort-Object FullName | ForEach-Object FullName)
foreach ($descriptor in Read-TlcPackageDescriptors -Path $packagePaths) {
	$config = $descriptor.Config
	$publication = Get-TlcPackagePublicationState -Config $config
	if (-not $publication.PublishEligible -or -not $config.CanonicalName -or -not $config.Platform) { continue }
	$descriptors += [pscustomobject]@{ Name = [string]$config.Name; CanonicalName = [string]$config.CanonicalName; Platform = [string]$config.Platform }
}
$tags = if ($PSBoundParameters.ContainsKey('Tags')) { @($Tags) } else { @((Get-DockerTags $Repository).tags) }
$indexes = @()
foreach ($group in $descriptors | Group-Object CanonicalName | Sort-Object Name) {
	$members = @($group.Group | Sort-Object Platform)
	if (@($members.Platform | Sort-Object -Unique).Count -lt 2) { continue }
	$versionsByPlatform = @{}
	$sourcesByPlatform = @{}
	foreach ($member in $members) {
		$slug = $member.Platform.Replace('/', '-')
		$prefix = "tlc-platform-v1-$slug--$($member.CanonicalName)--"
		$sourceMap = @{}
		foreach ($tag in @($tags | Where-Object { $_.StartsWith($prefix, [StringComparison]::Ordinal) })) {
			$sourceMap[$tag.Substring($prefix.Length)] = "$Repository`:$tag"
		}
		# Seed the hidden immutable platform leaf from the existing durable tag
		# during the first index migration. Once the hidden tag exists it always
		# wins, avoiding a canonical tag that has since become an index.
		$durablePrefix = "$($member.Name)-"
		foreach ($tag in @($tags | Where-Object { $_.StartsWith($durablePrefix, [StringComparison]::Ordinal) })) {
			$safeVersion = $tag.Substring($durablePrefix.Length)
			if (-not $sourceMap.ContainsKey($safeVersion)) { $sourceMap[$safeVersion] = "$Repository`:$tag" }
		}
		$sourcesByPlatform[$member.Platform] = $sourceMap
		$versionsByPlatform[$member.Platform] = @($sourceMap.Keys)
	}
	$commonVersions = [string[]]@($versionsByPlatform[$members[0].Platform])
	foreach ($member in $members | Select-Object -Skip 1) {
		$available = [Collections.Generic.HashSet[string]]::new([string[]]@($versionsByPlatform[$member.Platform]), [StringComparer]::Ordinal)
		$commonVersions = @($commonVersions | Where-Object { $available.Contains($_) })
	}
	foreach ($safeVersion in $commonVersions | Sort-Object -Unique) {
		$sources = @($members | ForEach-Object { [string]$sourcesByPlatform[$_.Platform][$safeVersion] })
		$leafTags = @($members | ForEach-Object { "$Repository`:tlc-platform-v1-$($_.Platform.Replace('/', '-'))--$($_.CanonicalName)--$safeVersion" })
		$markers = @($members.Name | Where-Object { $_ -ne $group.Name } | Sort-Object -Unique | ForEach-Object { "$Repository`:tlc-kind-platform-v1--$_--$($group.Name)" })
		$indexes += [ordered]@{ target = "$Repository`:$($group.Name)-$safeVersion"; sources = $sources; leafTags = $leafTags; markers = $markers; platforms = @($members.Platform) }
	}
}
$document = [ordered]@{ schemaVersion = 1; repository = $Repository; generatedAt = [datetime]::UtcNow.ToString('o'); indexes = $indexes }
[IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath), (($document | ConvertTo-Json -Depth 20) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
Write-Output "Wrote $($indexes.Count) platform index plan(s) to $OutputPath"
