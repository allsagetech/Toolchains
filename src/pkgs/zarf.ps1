<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
    Name = 'zarf'
}

function global:Install-TlcPackage {
    $Params = @{
        Owner      = 'zarf-dev'
        Repo       = 'zarf'
        TagPattern = '^v([0-9]+)\.([0-9]+)\.([0-9]+)$'
    }
    $Latest = Get-GitHubTag @Params

    $TlcPackageConfig.UpToDate = -not $Latest.Version.LaterThan($TlcPackageConfig.Latest)
    $TlcPackageConfig.Version  = $Latest.Version.ToString()

    if ($TlcPackageConfig.UpToDate) {
        return
    }

    if (-not $env:TLC_PKG_ROOT) {
        throw 'TLC_PKG_ROOT is not set; cannot determine install root for zarf.'
    }

    $InstallRoot = Join-Path $env:TLC_PKG_ROOT ("zarf-{0}" -f $Latest.Version)
    if (-not (Test-Path $InstallRoot)) {
        New-Item -ItemType Directory -Path $InstallRoot | Out-Null
    }

    $Tag       = $Latest.name
    $AssetName = "zarf_${Tag}_Windows_amd64.exe"
    $Download  = "https://github.com/zarf-dev/zarf/releases/download/$Tag/$AssetName"

    $ExePath = Join-Path $InstallRoot 'zarf.exe'

    Write-Host "Downloading Zarf $Tag from $Download"
    Invoke-WebRequest -Uri $Download -OutFile $ExePath

    if (-not (Test-Path $ExePath)) {
        throw "Failed to download Zarf binary from $Download"
    }

    Write-TlcVars @{
        env = @{
            path = $InstallRoot
        }
    }
}

function global:Test-TlcPackageInstall {
    Toolchain exec (Get-TlcPkgUri) {
        zarf version
    }
}
