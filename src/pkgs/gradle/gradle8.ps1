<#
Toolchains
Copyright (c) 2021 - 02-08-2026 U.S. Federal Government
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
	Name = 'gradle'
	Matcher = '^gradle-8\.'
}

function global:Install-TlcPackage {
	$Params = @{
		Owner = 'gradle'
		Repo = 'gradle'
		TagPattern = '^v(8)\.([0-9]+)\.([0-9]+)$'
	}
	$Latest = Get-GitHubTag @Params
	$TlcPackageConfig.UpToDate = -not $Latest.Version.LaterThan($TlcPackageConfig.Latest)
	$TlcPackageConfig.Version = $Latest.Version.ToString()
	if ($TlcPackageConfig.UpToDate) {
		return
	}
	$Tag = $Latest.name
	$Version = $Tag.SubString(1)
	if ($Version.EndsWith('.0')) {
		$Version = $Version.SubString(0, $Version.Length - 2)
	}
	$AssetName = "gradle-$Version-bin.zip"
	$Params = @{
		AssetName = $AssetName
		AssetURL = "https://services.gradle.org/distributions/$AssetName"
	}
	Install-BuildTool @Params
	Write-TlcVars @{
		env = @{
			path = (Get-ChildItem -Path '\pkg' -Recurse -Include 'gradle.bat' | Select-Object -First 1).DirectoryName
		}
	}
}

function global:Test-TlcPackageInstall {
	Get-Content '\pkg\.tlc'
}