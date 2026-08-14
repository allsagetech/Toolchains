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

function Get-TlcDockerDesktopRelease {
	param([object]$Metadata)

	if (-not $Metadata) {
		$Metadata = Invoke-TlcRestMethod -Uri 'https://desktop.docker.com/win/main/amd64/appcast.json'
	}

	$candidates = @($Metadata.Items | ForEach-Object {
		$item = $_
		$versionText = [string]$item.AppVersion
		$buildNumber = [string]$item.BuildNumber
		if ($versionText -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$' -or $buildNumber -notmatch '^[0-9]+$') {
			return
		}

		$artifact = @($item.Artifacts | Where-Object {
			[string]$_.Type -eq 'exe' -and [string]$_.URL -match 'Docker(?:%20| )Desktop(?:%20| )Installer\.exe$'
		} | Select-Object -First 1)[0]
		if (-not $artifact) { return }

		$uri = $null
		try { $uri = [Uri][string]$artifact.URL } catch { return }
		$decodedPath = [Uri]::UnescapeDataString($uri.AbsolutePath)
		if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'desktop.docker.com' -or $decodedPath -notmatch '^/win/main/amd64/([0-9]+)/Docker Desktop Installer\.exe$') {
			return
		}
		if ($Matches[1] -ne $buildNumber) { return }

		$checksum = ([string]$artifact.Checksum).Trim().ToLowerInvariant()
		if ($checksum -notmatch '^[0-9a-f]{64}$') { return }

		[long]$length = 0
		if (-not [long]::TryParse([string]$artifact.Length, [ref]$length) -or $length -le 0) { return }

		$releaseDate = [string]$item.Date
		try { $releaseDate = ([datetime]$item.Date).ToUniversalTime().ToString('o') } catch { }

		[pscustomobject]@{
			Version = [TlcSemanticVersion]::new($versionText)
			VersionText = $versionText
			BuildNumber = $buildNumber
			URL = $uri.AbsoluteUri
			Sha256 = $checksum
			Length = $length
			Date = $releaseDate
		}
	})

	if ($candidates.Count -eq 0) {
		throw 'Docker Desktop appcast did not contain a valid Windows x64 installer with a publisher checksum.'
	}

	return @($candidates | Sort-Object -Property `
		@{ Expression = { $_.Version.Major }; Descending = $true },
		@{ Expression = { $_.Version.Minor }; Descending = $true },
		@{ Expression = { $_.Version.Patch }; Descending = $true },
		@{ Expression = { [long]$_.BuildNumber }; Descending = $true } |
		Select-Object -First 1)[0]
}
