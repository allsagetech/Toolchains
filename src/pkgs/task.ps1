<#
Toolchains
Copyright (c) 2021 - 02-08-2026 U.S. Federal Government
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
	Name = 'task'
	GoToolchain = 'go1.26.6'
	BuildRevision = 1
	PatchedCryptoVersion = 'v0.53.0'
	PatchedNetVersion = 'v0.56.0'
	PatchedTextVersion = 'v0.39.0'
	PatchedGrpcVersion = 'v1.82.1'
}

function global:Install-TlcPackage {
	$Params = @{
		Owner = 'go-task'
		Repo = 'task'
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
		-Module 'github.com/go-task/task/v3' `
		-Version ([string]$Latest.Name) `
		-Command 'github.com/go-task/task/v3/cmd/task' `
		-OutputPath (Get-TlcPkgPath 'task.exe') `
		-MinimumModules @{
			'golang.org/x/crypto' = $TlcPackageConfig.PatchedCryptoVersion
			'golang.org/x/net' = $TlcPackageConfig.PatchedNetVersion
			'golang.org/x/text' = $TlcPackageConfig.PatchedTextVersion
			'google.golang.org/grpc' = $TlcPackageConfig.PatchedGrpcVersion
		} `
		-GoToolchain $TlcPackageConfig.GoToolchain

	Write-TlcVars @{
		env = @{
			path = Get-TlcPkgRoot
		}
	}
}

function global:Test-TlcPackageInstall {
	Toolchain exec (Get-TlcPkgUri) {
		task --version
	}
}
