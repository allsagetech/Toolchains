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
$packagePaths = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'src/pkgs') -Recurse -File -Filter '*.ps1' | Sort-Object FullName | ForEach-Object FullName)
foreach ($descriptor in Read-TlcPackageDescriptors -Path $packagePaths) {
		$config = $descriptor.Config
		$publication = Get-TlcPackagePublicationState -Config $config
		if (-not $publication.PublishEligible) { continue }
		$name = [string]$config.Name
		$matcher = if ($config.Matcher) { [string]$config.Matcher } else { "^$([regex]::Escape($name))-([0-9].+)$" }
		$candidates = @($tags | Where-Object { $_ -match $matcher } | ForEach-Object {
			$tag = [string]$_
			if ($tag -match "^$([regex]::Escape($name))-(.+)$") {
				$versionText = $Matches[1].Replace('_', '+')
				try { [pscustomobject]@{ Tag = $tag; Version = [TlcSemanticVersion]::new($versionText) } } catch { Write-Debug "Skipping invalid package tag '$tag': $($_.Exception.Message)" }
			}
		} | Where-Object { $_ } | Sort-Object Version)
		if ($candidates.Count -eq 0) { continue }
		$latest = $candidates[0]
		$entries += [ordered]@{
			id = [IO.Path]::GetFileNameWithoutExtension($descriptor.Path)
			package = $name
			tag = [string]$latest.Tag
			image = "$Repository`:$($latest.Tag)"
			platform = if ($config.Platform) { [string]$config.Platform } elseif (Test-TlcRunsOnUbuntu -RunsOn (Get-TlcPackageRunsOn -Config $config)) { 'linux/amd64' } else { 'windows/amd64' }
			vex = [string]$config.Vex
		}
}
$document = [ordered]@{ include = $entries }
[IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath), ($document | ConvertTo-Json -Depth 10 -Compress), [Text.UTF8Encoding]::new($false))
Write-Output "Wrote rescan matrix for $($entries.Count) package descriptors to $OutputPath"
