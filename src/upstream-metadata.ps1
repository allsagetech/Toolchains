<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

function Get-TlcMavenReleaseVersion {
	param([Parameter(Mandatory=$true)]$Metadata)
	$document = if ($Metadata -is [xml]) { $Metadata } else { [xml][string]$Metadata }
	$value = [string]$document.metadata.versioning.release
	if ($value -notmatch '^[0-9]+(?:\.[0-9]+){2,3}$') {
		throw 'Maven metadata did not contain a valid release version.'
	}
	return [TlcSemanticVersion]::new($value)
}

function Get-TlcVisualStudioBuildToolsRelease {
	param(
		[Parameter(Mandatory=$true)][string]$Content,
		[TlcSemanticVersion]$VersionWanted
	)
	$candidates = @($Content -split '</tr>' | ForEach-Object {
		if ($_ -match '(?s)<tr\b.+\bLTSC\b.+>([0-9]+\.[0-9]+\.[0-9]+)</.+ href="([^"]+/vs_BuildTools\.exe)"') {
			[pscustomobject]@{ Version = [TlcSemanticVersion]::new($Matches[1]); URI = [string]$Matches[2] }
		}
	})
	if ($VersionWanted) {
		return @($candidates | Where-Object { $VersionWanted.CompareTo($_.Version) -eq 0 } | Select-Object -First 1)[0]
	}
	return @($candidates | Sort-Object -Property @{ Expression = { $_.Version.Major }; Descending = $true }, @{ Expression = { $_.Version.Minor }; Descending = $true }, @{ Expression = { $_.Version.Patch }; Descending = $true }, @{ Expression = { $_.Version.Build }; Descending = $true } | Select-Object -First 1)[0]
}
