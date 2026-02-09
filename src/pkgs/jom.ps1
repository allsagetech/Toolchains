<#
Toolchains
Copyright (c) 2021 - 02-08-2026 U.S. Federal Government
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
	Name = 'jom'
}

function global:Install-TlcPackage {
	$Params = @{
		Owner = 'qt-labs'
		Repo = 'jom'
		TagPattern = '^v([0-9]+)\.([0-9]+)\.([0-9]+)$'
	}
	$Latest = Get-GitHubTag @Params
	$TlcPackageConfig.UpToDate = -not $Latest.Version.LaterThan($TlcPackageConfig.Latest)
	$TlcPackageConfig.Version = $Latest.Version.ToString()
	if ($TlcPackageConfig.UpToDate) {
		return
	}
	$Tag = $Latest.name
	$Version = $Tag.SubString(1).replace('.', '_')
	$AssetName = "jom_$Version.zip"
	$Params = @{
		AssetName = $AssetName
		AssetURL = "http://qt.mirror.constant.com/official_releases/jom/$AssetName"
	}
	Install-BuildTool @Params
	Write-TlcVars @{
		env = @{
			path = (Get-ChildItem -Path '\pkg' -Recurse -Include 'jom.exe' | Select-Object -First 1).DirectoryName
		}
	}
}

function global:Test-TlcPackageInstall {
	Get-Content '\pkg\.tlc'
}