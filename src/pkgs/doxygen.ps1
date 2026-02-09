<#
Toolchains
Copyright (c) 2021 - 02-08-2026 U.S. Federal Government
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
	Name = 'doxygen'
}

function global:Install-TlcPackage {
	$Params = @{
		Owner = 'doxygen'
		Repo = 'doxygen'
		TagPattern = '^Release_([0-9]+)_([0-9]+)_([0-9]+)$'
	}
	$Latest = Get-GitHubTag @Params
	$TlcPackageConfig.UpToDate = -not $Latest.Version.LaterThan($TlcPackageConfig.Latest)
	$TlcPackageConfig.Version = $Latest.Version.ToString()
	if ($TlcPackageConfig.UpToDate) {
		return
	}
	$Tag = $Latest.name
	$Version = $Latest.version.ToString()
	$AssetName = "doxygen-$Version.windows.x64.bin.zip"
	$Params = @{
		AssetName = $AssetName
		AssetURL = "https://www.doxygen.nl/files/$AssetName"
	}
	Install-BuildTool @Params
	Write-TlcVars @{
		env = @{
			path = (Get-ChildItem -Path '\pkg' -Recurse -Include 'doxygen.exe' | Select-Object -First 1).DirectoryName
		}
	}
}

function global:Test-TlcPackageInstall {
	Toolchain exec (Get-TlcPkgUri) {
		doxygen --version
	}
}