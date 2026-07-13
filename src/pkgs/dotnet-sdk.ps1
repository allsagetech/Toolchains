<#
Toolchains
Copyright (c) 2021 - 02-08-2026 U.S. Federal Government
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
	Name = 'dotnet-sdk'
}

function global:Install-TlcPackage {
	$Latest = Get-DotNetReleaseAsset -Product 'sdk' -Rid 'win-x64' -Extension '.zip'
	$TlcPackageConfig.UpToDate = -not $Latest.Version.LaterThan($TlcPackageConfig.Latest)
	$TlcPackageConfig.Version = $Latest.VersionText
	if ($TlcPackageConfig.UpToDate) {
		return
	}
	$Params = @{
		AssetName = $Latest.Name
		AssetURL = $Latest.URL
		ExpectedHash = $Latest.Hash
		ExpectedHashAlgorithm = $Latest.HashAlgorithm
	}

	Install-BuildTool @Params
	Write-TlcVars @{
		env = @{
			path = (Get-ChildItem -Path (Get-TlcPkgRoot) -Recurse -Include 'dotnet.exe' | Select-Object -First 1).DirectoryName
			dotnet_root = Get-TlcPkgRoot
		}
	}
}

function global:Test-TlcPackageInstall {
	Toolchain exec (Get-TlcPkgUri) {
		dotnet --list-sdks
	}
}
