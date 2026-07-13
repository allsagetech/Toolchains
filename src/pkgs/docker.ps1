<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
    Name = 'docker'
}

function global:Install-TlcPackage {
	$DockerVersion = '29.1.5'
	$upstream = [TlcSemanticVersion]::new($DockerVersion)
	$TlcPackageConfig.Version = $DockerVersion
	$TlcPackageConfig.UpToDate = -not $upstream.LaterThan($TlcPackageConfig.Latest)
	if ($TlcPackageConfig.UpToDate) { return }

	$InstallRoot = Get-TlcPkgPath ("docker-{0}" -f $DockerVersion)

    if (-not (Test-Path $InstallRoot)) {
        New-Item -ItemType Directory -Path $InstallRoot | Out-Null
    }

    $AssetName = "docker-$DockerVersion.zip"
    $Download  = "https://download.docker.com/win/static/stable/x86_64/$AssetName"

	$ZipPath = Get-TlcStagingPath $AssetName
	$archiveVerifier = { param($path, $uri) Test-TlcAuthenticodeZip -Path $path -Uri $uri -RequiredExecutable 'docker.exe' }

	Write-Host "Downloading Docker $DockerVersion from $Download"
	try {
		Invoke-TlcWebRequest -Uri $Download -OutFile $ZipPath -SignatureVerifier $archiveVerifier

		if (-not (Test-Path $ZipPath)) {
			throw "Failed to download Docker archive from $Download"
		}

		Expand-Archive -LiteralPath $ZipPath -DestinationPath $InstallRoot -Force
	} finally {
		Remove-Item -LiteralPath $ZipPath -Force -ErrorAction SilentlyContinue
	}

    $DockerDir = Join-Path $InstallRoot 'docker'
    $DockerExe = Join-Path $DockerDir 'docker.exe'

	if (-not (Test-Path $DockerExe)) {
		throw "docker.exe not found after extracting $AssetName"
	}
	Assert-TlcDownloadedFile -Path $DockerExe -Uri $Download -RequireValidAuthenticodeSignature

    Write-TlcVars @{
        env = @{
            path = $DockerDir
        }
    }

}

function global:Test-TlcPackageInstall {
    Toolchain exec (Get-TlcPkgUri) {
        docker --version
    }
}
