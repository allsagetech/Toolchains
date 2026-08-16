<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

[CmdletBinding()]
param(
	[string]$OutputPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'PACKAGE_INVENTORY.md')
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $repoRoot 'src/main.ps1')

$packagePaths = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'src/pkgs') -Recurse -File -Filter '*.ps1' | Sort-Object FullName | ForEach-Object FullName)
$records = foreach ($descriptor in Read-TlcPackageDescriptors -Path $packagePaths) {
	$config = $descriptor.Config
	$publication = Get-TlcPackagePublicationState -Config $config
	[pscustomobject]@{
		Name = [string]$config.Name
		CanonicalName = if ($config.CanonicalName) { [string]$config.CanonicalName } else { [string]$config.Name }
		Platform = if ($config.Platform) { [string]$config.Platform } elseif (Test-TlcRunsOnUbuntu -RunsOn (Get-TlcPackageRunsOn -Config $config)) { 'linux/amd64' } else { 'windows/amd64' }
		Tier = if ($config.Tier) { [string]$config.Tier } else { 'tooling' }
		Publication = if ($publication.PublishEligible) { 'eligible' } else { 'quarantined' }
		Reason = [string]$publication.QuarantineReason
		Source = $descriptor.Path.Substring($repoRoot.Length + 1).Replace('\', '/')
	}
}

function Escape-MarkdownCell([string]$Value) {
	return ($Value -replace '\|', '\|' -replace '[\r\n]+', ' ').Trim()
}

$eligible = @($records | Where-Object Publication -eq 'eligible').Count
$quarantined = @($records | Where-Object Publication -eq 'quarantined').Count
$lines = [Collections.Generic.List[string]]::new()
$lines.Add('# Package inventory')
$lines.Add('')
$lines.Add('This file is generated from package descriptors. Run `./scripts/export-package-inventory.ps1` after changing `src/pkgs`.')
$lines.Add('')
$lines.Add("- Descriptors: $($records.Count)")
$lines.Add("- Publication eligible: $eligible")
$lines.Add("- Quarantined: $quarantined")
$lines.Add('')
$lines.Add('| Package | Canonical name | Platform | Tier | Publication | Source |')
$lines.Add('| --- | --- | --- | --- | --- | --- |')
foreach ($record in $records | Sort-Object Name,Platform,Source) {
	$state = if ($record.Reason) { "$($record.Publication): $(Escape-MarkdownCell $record.Reason)" } else { $record.Publication }
	$source = Escape-MarkdownCell $record.Source
	$lines.Add("| $(Escape-MarkdownCell $record.Name) | $(Escape-MarkdownCell $record.CanonicalName) | $(Escape-MarkdownCell $record.Platform) | $(Escape-MarkdownCell $record.Tier) | $state | ``$source`` |")
}

$fullOutputPath = [IO.Path]::GetFullPath($OutputPath)
$content = ($lines -join "`n") + "`n"
[IO.File]::WriteAllText($fullOutputPath, $content, [Text.UTF8Encoding]::new($false))
Write-Output "Wrote $($records.Count) package descriptors to $fullOutputPath"
