<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
    Name = 'docker'
}

function global:Install-TlcPackage {

    if (-not $env:TLC_PKG_ROOT) {
        throw 'TLC_PKG_ROOT is not set; cannot determine install root for docker.'
    }

    $DockerVersion = '29.1.5'

    $TlcPackageConfig.Version  = $DockerVersion
    $TlcPackageConfig.UpToDate = $true

    $InstallRoot = Join-Path $env:TLC_PKG_ROOT ("docker-{0}" -f $DockerVersion)

    if (-not (Test-Path $InstallRoot)) {
        New-Item -ItemType Directory -Path $InstallRoot | Out-Null
    }

    $AssetName = "docker-$DockerVersion.zip"
    $Download  = "https://download.docker.com/win/static/stable/x86_64/$AssetName"

    $ZipPath = Join-Path $InstallRoot $AssetName

    Write-Host "Downloading Docker $DockerVersion from $Download"
    Invoke-WebRequest -Uri $Download -OutFile $ZipPath

    if (-not (Test-Path $ZipPath)) {
        throw "Failed to download Docker archive from $Download"
    }

    Expand-Archive -LiteralPath $ZipPath -DestinationPath $InstallRoot -Force

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

    if ($env:TLC_DOCKER_REPO) {
        Write-Host "Building and pushing Docker package image '$($TlcPackageConfig.Name)' version '$DockerVersion' to $env:TLC_DOCKER_REPO"

        try {
            Invoke-DockerPush -name $TlcPackageConfig.Name -version $DockerVersion
        }
        catch {
            Write-Warning "Failed to build/push Docker image for package '$($TlcPackageConfig.Name)': $($_.Exception.Message)"
            throw
        }
    }
    else {
        Write-Host "TLC_DOCKER_REPO is not set; skipping Docker image push for docker package."
    }
}

function global:Test-TlcPackageInstall {
    Toolchain exec (Get-TlcPkgUri) {
        docker --version
    }
}
