<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
    Name = 'dependabot'
}

function global:Install-TlcPackage {
    $Params = @{
        Owner      = 'dependabot'
        Repo       = 'cli'
        TagPattern = '^v([0-9]+)\.([0-9]+)\.([0-9]+)$'
    }
    $Latest = Get-GitHubTag @Params

    $TlcPackageConfig.UpToDate = -not $Latest.Version.LaterThan($TlcPackageConfig.Latest)
    $TlcPackageConfig.Version  = $Latest.Version.ToString()
    if ($TlcPackageConfig.UpToDate) {
        return
    }

    if (-not $env:TLC_PKG_ROOT) {
        throw 'TLC_PKG_ROOT is not set; cannot determine install root for dependabot.'
    }

    $InstallRoot = Join-Path $env:TLC_PKG_ROOT ("dependabot-{0}" -f $Latest.Version)

    if (-not (Test-Path $InstallRoot)) {
        New-Item -ItemType Directory -Path $InstallRoot | Out-Null
    }

    $GoPath = Join-Path $InstallRoot 'gopath'
    if (-not (Test-Path $GoPath)) {
        New-Item -ItemType Directory -Path $GoPath | Out-Null
    }

    $env:GOBIN      = $InstallRoot
    $env:GOPATH     = $GoPath
    $env:GOMODCACHE = Join-Path $GoPath 'pkg\mod'

    $VersionTag = $Latest.name

    & go install ("github.com/dependabot/cli/cmd/dependabot@{0}" -f $VersionTag)

    if ($LASTEXITCODE -ne 0) {
        throw "go install for dependabot failed with exit code $LASTEXITCODE. Make sure the 'go' package is installed and on PATH."
    }

    Write-TlcVars @{
        env = @{
            path = $InstallRoot
        }
    }
}

function global:Test-TlcPackageInstall {
    Toolchain exec (Get-TlcPkgUri) {
        dependabot --version
    }
}
