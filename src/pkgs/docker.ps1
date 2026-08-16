<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
	Name = 'docker'
}

function global:Install-TlcPackage {
	# Independently reviewed checksum from microsoft/winget-pkgs commit
	# 096356d4bd44c85b4e5a7b1752d57d61b114ff0b. The payload remains on
	# Docker's official HTTPS origin and any byte change fails closed.
	$DockerVersion = '29.7.2'
	$ExpectedSha256 = 'ed9222f478a5d143ac90e8e2fd3209b5076382cdb4b210321f97aa4b68bc6811'
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

	Write-Host "Downloading Docker $DockerVersion from $Download"
	try {
		Invoke-TlcWebRequest -Uri $Download -OutFile $ZipPath -ExpectedSha256 $ExpectedSha256

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
