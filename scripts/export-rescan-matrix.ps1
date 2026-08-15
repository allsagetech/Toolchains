<# Toolchains | SPDX-License-Identifier: MPL-2.0 #>
[CmdletBinding()]
param(
	[Parameter(Mandatory=$true)][string]$OutputPath,
	[string]$Repository = 'allsagetech/toolchains'
)
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $repoRoot 'src/main.ps1')
$tags = @((Get-DockerTags $Repository).tags)
$entries = @()
try {
	foreach ($script in Get-ChildItem -LiteralPath (Join-Path $repoRoot 'src/pkgs') -Recurse -File -Filter '*.ps1' | Sort-Object FullName) {
		Clear-TlcPackageScript
		& $script.FullName
		Test-TlcPackageScript
		$publication = Get-TlcPackagePublicationState
		if (-not $publication.PublishEligible) { continue }
		$name = [string]$TlcPackageConfig.Name
		$matcher = if ($TlcPackageConfig.Matcher) { [string]$TlcPackageConfig.Matcher } else { "^$([regex]::Escape($name))-([0-9].+)$" }
		$candidates = @($tags | Where-Object { $_ -match $matcher } | ForEach-Object {
			if ($_ -match "^$([regex]::Escape($name))-(.+)$") {
				$versionText = $Matches[1].Replace('_', '+')
				try { [pscustomobject]@{ Tag = [string]$_; Version = [TlcSemanticVersion]::new($versionText) } } catch { }
			}
		} | Where-Object { $_ } | Sort-Object Version)
		if ($candidates.Count -eq 0) { continue }
		$latest = $candidates[0]
		$entries += [ordered]@{
			id = [IO.Path]::GetFileNameWithoutExtension($script.Name)
			package = $name
			tag = [string]$latest.Tag
			image = "$Repository`:$($latest.Tag)"
			platform = if ($TlcPackageConfig.Platform) { [string]$TlcPackageConfig.Platform } elseif (Test-TlcRunsOnUbuntu -RunsOn (Get-TlcPackageRunsOn)) { 'linux/amd64' } else { 'windows/amd64' }
			vex = [string]$TlcPackageConfig.Vex
		}
	}
} finally { Clear-TlcPackageScript }
$document = [ordered]@{ include = $entries }
[IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath), ($document | ConvertTo-Json -Depth 10 -Compress), [Text.UTF8Encoding]::new($false))
Write-Output "Wrote rescan matrix for $($entries.Count) package descriptors to $OutputPath"
