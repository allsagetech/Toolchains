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
	$Params = @{
		Owner = 'dotnet'
		Repo = 'sdk'
		TagPattern = '^v([0-9]+)\.([0-9]+)\.([0-9]+)(?:-rtm.*)?$'
	}
	$Latest = Get-GitHubTag @Params
	$TlcPackageConfig.UpToDate = -not $Latest.Version.LaterThan($TlcPackageConfig.Latest)
	$TlcPackageConfig.Version = $Latest.Version.ToString()
	if ($TlcPackageConfig.UpToDate) {
		return
	}
	$Version = $TlcPackageConfig.Version
	$Params = @{
		AssetName = "dotnet-sdk-$Version.zip"
		AssetURL = "https://builds.dotnet.microsoft.com/dotnet/Sdk/$Version/dotnet-sdk-$Version-win-x64.zip"
	}

	Install-BuildTool @Params
	Write-TlcVars @{
		env = @{
			path = (Get-ChildItem -Path '\pkg' -Recurse -Include 'dotnet.exe' | Select-Object -First 1).DirectoryName
			dotnet_root = '\pkg'
		}
	}
}

function global:Test-TlcPackageInstall {
	Toolchain exec (Get-TlcPkgUri) {
		dotnet --list-sdks
	}
}