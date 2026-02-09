<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
    Name = 'yarn'
}

function global:Install-TlcPackage {

    if (-not $env:TLC_PKG_ROOT) {
        throw 'TLC_PKG_ROOT is not set; cannot determine install root for yarn.'
    }

    $InstallRoot = Join-Path $env:TLC_PKG_ROOT 'yarn'

    if (-not (Test-Path $InstallRoot)) {
        New-Item -ItemType Directory -Path $InstallRoot | Out-Null
    }

    $env:npm_config_prefix = $InstallRoot

    & npm install -g yarn

    if ($LASTEXITCODE -ne 0) {
        throw "npm install -g yarn failed with exit code $LASTEXITCODE. Make sure the 'node' package is installed and npm is on PATH."
    }

    $YarnCmd = Join-Path $InstallRoot 'yarn.cmd'
    if (Test-Path $YarnCmd) {
        $version = & $YarnCmd --version
        if ($LASTEXITCODE -eq 0 -and $version) {
            $TlcPackageConfig.Version  = $version.Trim()
            $TlcPackageConfig.UpToDate = $true
        }
    }

    Write-TlcVars @{
        env = @{
            path = $InstallRoot
        }
    }
}

function global:Test-TlcPackageInstall {
    Toolchain exec (Get-TlcPkgUri) {
        yarn --version
    }
}
