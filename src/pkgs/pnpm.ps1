<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
    Name = 'pnpm'
}

function global:Install-TlcPackage {
	$versionOutput = @(& npm view pnpm version) | Select-Object -Last 1
	if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$versionOutput)) {
		throw "npm view pnpm version failed with exit code $LASTEXITCODE"
	}
	$version = ([string]$versionOutput).Trim()
	$upstream = [TlcSemanticVersion]::new($version)
	$TlcPackageConfig.Version = $version
	$TlcPackageConfig.UpToDate = -not $upstream.LaterThan($TlcPackageConfig.Latest)
	if ($TlcPackageConfig.UpToDate) { return }

	$InstallRoot = Get-TlcPkgPath 'pnpm'

    if (-not (Test-Path $InstallRoot)) {
        New-Item -ItemType Directory -Path $InstallRoot | Out-Null
    }

    $env:npm_config_prefix = $InstallRoot

	& npm install -g "pnpm@$version"

    if ($LASTEXITCODE -ne 0) {
        throw "npm install -g pnpm failed with exit code $LASTEXITCODE. Make sure the 'node' package is installed and npm is on PATH."
    }

	Write-TlcVars @{
        env = @{
            path = $InstallRoot
        }
    }
}

function global:Test-TlcPackageInstall {
    Toolchain exec (Get-TlcPkgUri) {
        pnpm --version
    }
}
