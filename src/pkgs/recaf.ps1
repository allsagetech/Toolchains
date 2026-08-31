<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
	Name = 'recaf'
	CanonicalName = 'recaf'
	Platform = 'windows/amd64'
	BuildRevision = 1
	Upstream = 'https://github.com/Col-E/Recaf'
}

function global:Install-TlcPackage {
	function Get-TlcRecafVerifiedSha256 {
		param(
			[Parameter(Mandatory = $true)][hashtable]$Asset
		)

		$sha256 = [string]$Asset.ExpectedSha256
		if ($sha256 -notmatch '^[0-9a-fA-F]{64}$') {
			$sha256 = Get-TlcGitHubReleaseAssetSha256 -Uri ([string]$Asset.URL)
		}
		if ($sha256 -notmatch '^[0-9a-fA-F]{64}$') {
			throw "no verified SHA-256 was published for $($Asset.Name)"
		}
		return $sha256.ToLowerInvariant()
	}

	# Recaf 4 currently publishes its Windows distribution as an alpha artifact.
	# Keep the channel explicit so a future stable 4.x release is reviewed before
	# it replaces this package's integrity contract.
	$recaf = Get-GitHubRelease `
		-Owner 'Col-E' `
		-Repo 'Recaf' `
		-AssetPattern '^recaf-4x-alpha-win-86-x64\.jar$' `
		-TagPattern '^([0-9]+)\.([0-9]+)\.([0-9]+)-alpha$'
	$packageVersion = [TlcSemanticVersion]::new("$($recaf.Version)+$($TlcPackageConfig.BuildRevision)")
	$TlcPackageConfig.Version = $packageVersion.ToString()
	$TlcPackageConfig.UpToDate = -not $packageVersion.LaterThan($TlcPackageConfig.Latest)
	if ($TlcPackageConfig.UpToDate) { return }

	$runtime = Get-GitHubRelease `
		-Owner 'adoptium' `
		-Repo 'temurin25-binaries' `
		-AssetPattern '^OpenJDK25U-jre_x64_windows_hotspot_.+\.zip$' `
		-TagPattern '^jdk-(25)\.([0-9]+)\.([0-9]+)(?:\.[0-9]+)?\+[0-9]+$'

	$pkgRoot = Get-TlcPkgRoot
	New-Item -Path $pkgRoot -ItemType Directory -Force | Out-Null
	$recafJar = Get-TlcPkgPath 'recaf.jar'
	Invoke-TlcWebRequest -Uri $recaf.URL -OutFile $recafJar -ExpectedSha256 (Get-TlcRecafVerifiedSha256 -Asset $recaf) | Out-Null

	$runtimeStage = Get-TlcStagingPath 'recaf-runtime'
	if (Test-Path -LiteralPath $runtimeStage) {
		Remove-Item -LiteralPath $runtimeStage -Recurse -Force
	}
	New-Item -Path $runtimeStage -ItemType Directory -Force | Out-Null
	Install-BuildTool -AssetName $runtime.Name -AssetURL $runtime.URL -ToolDir $runtimeStage `
		-ExpectedSha256 (Get-TlcRecafVerifiedSha256 -Asset $runtime)

	$java = @(Get-ChildItem -LiteralPath $runtimeStage -Recurse -File -Filter 'java.exe')
	if ($java.Count -ne 1) {
		throw "Recaf runtime archive must contain exactly one java.exe; found $($java.Count)."
	}
	$runtimeRoot = Split-Path -Parent $java[0].DirectoryName
	$runtimeDestination = Get-TlcPkgPath 'runtime'
	if (Test-Path -LiteralPath $runtimeDestination) {
		Remove-Item -LiteralPath $runtimeDestination -Recurse -Force
	}
	Move-Item -LiteralPath $runtimeRoot -Destination $runtimeDestination

	$launcher = @'
@echo off
"%~dp0runtime\bin\java.exe" -jar "%~dp0recaf.jar" %*
'@
	[IO.File]::WriteAllText((Get-TlcPkgPath 'recaf.cmd'), $launcher, [Text.UTF8Encoding]::new($false))
	Write-TlcVars @{ env = @{ path = $pkgRoot } }
}

function global:Test-TlcPackageInstall {
	Toolchain exec (Get-TlcPkgUri) {
		recaf --help
	}
}
