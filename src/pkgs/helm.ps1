<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
    Name = 'helm'
}

function global:Install-TlcPackage {
    $Params = @{
        Owner      = 'helm'
        Repo       = 'helm'
        TagPattern = '^v([0-9]+)\.([0-9]+)\.([0-9]+)$'
    }
    $Latest = Get-GitHubTag @Params

    $TlcPackageConfig.UpToDate = -not $Latest.Version.LaterThan($TlcPackageConfig.Latest)
    $TlcPackageConfig.Version  = $Latest.Version.ToString()

    if ($TlcPackageConfig.UpToDate) {
        return
    }

    if (-not $env:TLC_PKG_ROOT) {
        throw 'TLC_PKG_ROOT is not set; cannot determine install root for helm.'
    }

    $InstallRoot = Join-Path $env:TLC_PKG_ROOT ("helm-{0}" -f $Latest.Version)
    if (-not (Test-Path $InstallRoot)) {
        New-Item -ItemType Directory -Path $InstallRoot | Out-Null
    }

    $Tag       = $Latest.name
    $AssetName = "helm-$Tag-windows-amd64.zip"
    $Download  = "https://get.helm.sh/$AssetName"

    $ZipPath = Join-Path $InstallRoot $AssetName

    Write-Host "Downloading Helm $Tag from $Download"
    Invoke-WebRequest -Uri $Download -OutFile $ZipPath

    if (-not (Test-Path $ZipPath)) {
        throw "Failed to download Helm archive from $Download"
    }

    Expand-Archive -LiteralPath $ZipPath -DestinationPath $InstallRoot -Force

    $HelmExe = Get-ChildItem -Path $InstallRoot -Recurse -Filter 'helm.exe' |
        Select-Object -First 1

    if (-not $HelmExe) {
        throw "helm.exe not found after extracting $AssetName"
    }

    $TargetExe = Join-Path $InstallRoot 'helm.exe'
    if ($HelmExe.FullName -ne $TargetExe) {
        Copy-Item $HelmExe.FullName -Destination $TargetExe -Force
    }

    Write-TlcVars @{
        env = @{
            path = $InstallRoot
        }
    }
}

function global:Test-TlcPackageInstall {
    Toolchain exec (Get-TlcPkgUri) {
        helm version
    }
}
