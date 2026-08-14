<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
	Name = 'docker-desktop'
}

function global:Install-TlcPackage {
	$release = Get-TlcDockerDesktopRelease
	$TlcPackageConfig.Version = $release.VersionText
	$TlcPackageConfig.UpToDate = -not $release.Version.LaterThan($TlcPackageConfig.Latest)
	if ($TlcPackageConfig.UpToDate) { return }

	$pkgRoot = Get-TlcPkgRoot
	New-Item -ItemType Directory -Path $pkgRoot -Force | Out-Null
	$assetRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\assets\docker-desktop'))
	Copy-Item -LiteralPath (Join-Path $assetRoot 'docker-desktop-install.ps1') -Destination $pkgRoot -Force
	Copy-Item -LiteralPath (Join-Path $assetRoot 'docker-desktop-install.cmd') -Destination $pkgRoot -Force

	$metadata = [ordered]@{
		version = $release.VersionText
		buildNumber = $release.BuildNumber
		uri = $release.URL
		sha256 = $release.Sha256
		length = $release.Length
		releaseDate = $release.Date
		publisher = 'Docker Inc'
		metadataSource = 'https://desktop.docker.com/win/main/amd64/appcast.json'
	}
	[IO.File]::WriteAllText(
		(Join-Path $pkgRoot 'docker-desktop-release.json'),
		($metadata | ConvertTo-Json -Depth 5)
	)

	Write-TlcVars @{ env = @{ path = $pkgRoot } }
}

function global:Test-TlcPackageInstall {
	Toolchain exec (Get-TlcPkgUri) {
		docker-desktop-install -Help
	}
}
