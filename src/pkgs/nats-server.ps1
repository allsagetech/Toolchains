<#
Toolchains
Copyright (c) 2021 - 02-08-2026 U.S. Federal Government
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
	Name = 'nats-server'
	GoToolchain = 'go1.26.6'
	BuildRevision = 1
	PatchedCryptoVersion = 'v0.55.0'
}

function global:Install-TlcPackage {
	$Params = @{
		Owner = 'nats-io'
		Repo = 'nats-server'
		TagPattern = '^v([0-9]+)\.([0-9]+)\.([0-9]+)$'
	}
	$Latest = Get-GitHubTag @Params
	$upstreamVersion = $Latest.Version.ToString()
	$packageVersion = [TlcSemanticVersion]::new("$upstreamVersion+$($TlcPackageConfig.BuildRevision)")
	$TlcPackageConfig.UpToDate = -not $packageVersion.LaterThan($TlcPackageConfig.Latest)
	$TlcPackageConfig.Version = $packageVersion.ToString()
	if ($TlcPackageConfig.UpToDate) {
		return
	}

	Invoke-TlcVerifiedGoCommandBuild `
		-Module 'github.com/nats-io/nats-server/v2' `
		-Version ([string]$Latest.Name) `
		-Command 'github.com/nats-io/nats-server/v2' `
		-OutputPath (Get-TlcPkgPath 'nats-server.exe') `
		-MinimumModules @{ 'golang.org/x/crypto' = $TlcPackageConfig.PatchedCryptoVersion } `
		-GoToolchain $TlcPackageConfig.GoToolchain

	Write-TlcVars @{
		env = @{
			path = Get-TlcPkgRoot
		}
	}
}

function global:Test-TlcPackageInstall {
	Toolchain exec (Get-TlcPkgUri) {
		nats-server --version
	}
}
