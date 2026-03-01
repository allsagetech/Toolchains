<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
    Name = 'codex'
}

function global:Install-TlcPackage {

    if (-not $env:TLC_PKG_ROOT) {
        throw 'TLC_PKG_ROOT is not set; cannot determine install root for codex.'
    }

    $latestInfo = Invoke-TlcRestMethod -Uri 'https://registry.npmjs.org/@openai%2Fcodex/latest'
    $version = [string]$latestInfo.version
    if (-not $version) {
        throw 'Could not determine the latest @openai/codex version from npm.'
    }

    $TlcPackageConfig.Version = $version
    $TlcPackageConfig.UpToDate = -not ([TlcSemanticVersion]::new($version).LaterThan($TlcPackageConfig.Latest))
    if ($TlcPackageConfig.UpToDate) {
        return
    }

    $nodeTag = Get-GitHubTag -Owner 'nodejs' -Repo 'node' -TagPattern '^v(22)\.([0-9]+)\.([0-9]+)$'
    $nodeAssetName = "node-$($nodeTag.Name)-win-x64.zip"
    Install-BuildTool -AssetName $nodeAssetName -AssetURL "https://nodejs.org/dist/$($nodeTag.Name)/$nodeAssetName"

    $nodeRoot = (Get-ChildItem -Path '\pkg' -Recurse -Include 'node.exe' | Select-Object -First 1).DirectoryName
    if (-not $nodeRoot) {
        throw 'Could not find node.exe after extracting the Node.js archive.'
    }

    $npmCmd = Join-Path $nodeRoot 'npm.cmd'
    if (-not (Test-Path $npmCmd)) {
        throw "Could not find npm.cmd in $nodeRoot"
    }

    $installRoot = Join-Path $env:TLC_PKG_ROOT 'codex'
    if (-not (Test-Path $installRoot)) {
        New-Item -ItemType Directory -Path $installRoot | Out-Null
    }

    $env:npm_config_prefix = $installRoot
    $env:npm_config_cache = Join-Path $env:TEMP 'toolchains-npm-cache'
    $env:Path = "$nodeRoot;$env:Path"

    & $npmCmd install -g "@openai/codex@$version"
    if ($LASTEXITCODE -ne 0) {
        throw "npm install -g @openai/codex@$version failed with exit code $LASTEXITCODE."
    }

    $codexCmd = Join-Path $installRoot 'codex.cmd'
    if (-not (Test-Path $codexCmd)) {
        throw "Could not find codex.cmd in $installRoot after npm install."
    }

    Write-TlcVars @{
        env = @{
            path = "$installRoot;$nodeRoot"
        }
    }
}

function global:Test-TlcPackageInstall {
    Toolchain exec (Get-TlcPkgUri) {
        codex --version
    }
}
