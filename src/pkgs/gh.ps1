<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
    Name = 'gh'
}

function global:Install-TlcPackage {

    if (-not $env:TLC_PKG_ROOT) {
        throw 'TLC_PKG_ROOT is not set; cannot determine install root for gh.'
    }

    $Params = @{
        Owner        = 'cli'
        Repo         = 'cli'
        AssetPattern = 'gh_.*_windows_amd64\.zip'
        TagPattern   = '^v([0-9]+)\.([0-9]+)\.([0-9]+)$'
    }

    $Asset = Get-GitHubRelease @Params

    $TlcPackageConfig.UpToDate = -not $Asset.Version.LaterThan($TlcPackageConfig.Latest)
    $TlcPackageConfig.Version  = $Asset.Version.ToString()

    if ($TlcPackageConfig.UpToDate) {
        return
    }

    $InstallRoot = Join-Path $env:TLC_PKG_ROOT ("gh-{0}" -f $Asset.Version)

    if (-not (Test-Path $InstallRoot)) {
        New-Item -ItemType Directory -Path $InstallRoot | Out-Null
    }

    $Params = @{
        AssetName = $Asset.Name
        AssetURL  = $Asset.URL
    }
    Install-BuildTool @Params

    $GhExe = Get-ChildItem -Path '\pkg' -Recurse -Include 'gh.exe' |
        Select-Object -First 1

    if (-not $GhExe) {
        throw "Could not find gh.exe after extracting GitHub CLI archive."
    }

    Copy-Item $GhExe.FullName -Destination (Join-Path $InstallRoot 'gh.exe') -Force

    Write-TlcVars @{
        env = @{
            path = $InstallRoot
        }
    }
}

function global:Test-TlcPackageInstall {
    Toolchain exec (Get-TlcPkgUri) {
        gh --version
    }
}
