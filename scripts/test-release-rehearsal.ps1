<# Toolchains | SPDX-License-Identifier: MPL-2.0 #>

[CmdletBinding()]
param(
	[Parameter(Mandatory=$true)][string]$OutputPath,
	[ValidateRange(1, 60000)][int]$MaximumCatalogMilliseconds = 5000
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $repoRoot 'src/main.ps1')

$paths = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'src/pkgs') -Recurse -File -Filter '*.ps1' | Sort-Object FullName | ForEach-Object FullName)
$stopwatch = [Diagnostics.Stopwatch]::StartNew()
$descriptors = @(Read-TlcPackageDescriptors -Path $paths)
$stopwatch.Stop()
if ($stopwatch.ElapsedMilliseconds -gt $MaximumCatalogMilliseconds) {
	throw "Release catalog preparation took $($stopwatch.ElapsedMilliseconds) ms, above the $MaximumCatalogMilliseconds ms budget."
}

$entries = foreach ($descriptor in $descriptors) {
	$config = $descriptor.Config
	$publication = Get-TlcPackagePublicationState -Config $config
	$runsOn = Get-TlcPackageRunsOn -Config $config
	$publishRunsOn = Get-TlcPackagePublishRunsOn -Config $config
	$tier = if ($config.Tier) { [string]$config.Tier } else { 'tooling' }
	[ordered]@{
		name = [string]$config.Name
		matcher = [string]$config.Matcher
		path = $descriptor.Path.Substring($repoRoot.Length + 1).Replace('\', '/')
		runsOn = $runsOn
		publishRunsOn = $publishRunsOn
		tier = $tier
		publishEligible = [bool]$publication.PublishEligible
		quarantineReason = [string]$publication.QuarantineReason
	}
}

$invalidFamilies = @()
foreach ($family in $descriptors | Group-Object { [string]$_.Config.Name } | Where-Object Count -gt 1) {
	$matchers = @($family.Group | ForEach-Object { [string]$_.Config.Matcher })
	if (@($matchers | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0 -or @($matchers | Sort-Object -Unique).Count -ne $family.Count) {
		$invalidFamilies += $family.Name
	}
}
if ($invalidFamilies.Count -gt 0) { throw "Release package families require distinct anchored matchers: $($invalidFamilies -join ', ')" }
$eligible = @($entries | Where-Object publishEligible)
$publishable = @($entries | Where-Object { $_.publishEligible -and $_.tier -ne 'model-large' })
$quarantined = @($entries | Where-Object { -not $_.publishEligible })
$modelConfigs = @($descriptors | ForEach-Object { [pscustomobject]@{ Name = [string]$_.Config.Name; Tier = if ($_.Config.Tier) { [string]$_.Config.Tier } else { 'tooling' } } })
$models = @(Get-TlcModelCategoryPackages -PackageConfigs $modelConfigs)

$canonicalEntries = @($entries | Sort-Object name | ForEach-Object { "{0}|{1}|{2}|{3}|{4}|{5}" -f $_.name,$_.path,$_.runsOn,$_.publishRunsOn,$_.tier,$_.publishEligible }) -join "`n"
$hash = [Security.Cryptography.SHA256]::Create()
try { $fingerprint = -join ($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonicalEntries)) | ForEach-Object { $_.ToString('x2') }) }
finally { $hash.Dispose() }

$document = [ordered]@{
	schemaVersion = 1
	descriptorCount = $descriptors.Count
	eligibleCount = $eligible.Count
	publishableCount = $publishable.Count
	quarantinedCount = $quarantined.Count
	modelCount = $models.Count
	catalogMilliseconds = $stopwatch.ElapsedMilliseconds
	fingerprint = $fingerprint
	entries = @($entries | Sort-Object name)
}
$fullOutputPath = [IO.Path]::GetFullPath($OutputPath)
$parent = Split-Path -Parent $fullOutputPath
if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
[IO.File]::WriteAllText($fullOutputPath, (($document | ConvertTo-Json -Depth 10) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
Write-Output "Release rehearsal validated $($descriptors.Count) descriptors ($($publishable.Count) publishable, $($quarantined.Count) quarantined) in $($stopwatch.ElapsedMilliseconds) ms."
