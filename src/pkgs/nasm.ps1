<#
Toolchains
Copyright (c) 2021 - 02-08-2026 U.S. Federal Government
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

$global:TlcPackageConfig = @{
	Name = 'nasm'
}

function global:Install-TlcPackage {
	$Params = @{
		Owner = 'netwide-assembler'
		Repo = 'nasm'
		TagPattern = '^nasm-([0-9]+)\.([0-9]+)(?:\.([0-9]+))?$'
	}
	$Latest = Get-GitHubTag @Params
	$TlcPackageConfig.UpToDate = -not $Latest.Version.LaterThan($TlcPackageConfig.Latest)
	$TlcPackageConfig.Version = $Latest.Version.ToString()
	if ($TlcPackageConfig.UpToDate) {
		return
	}
	$Tag = $Latest.name
	$Version = $Tag.SubString(5)
	$AssetName = "nasm-$Version-win64.zip"
	$Params = @{
		AssetName = $AssetName
		AssetURL = "https://www.nasm.us/pub/nasm/releasebuilds/$Version/win64/$AssetName"
	}
	Install-BuildTool @Params
	Write-TlcVars @{
		env = @{
			path = (Get-ChildItem -Path '\pkg' -Recurse -Include 'nasm.exe' | Select-Object -First 1).DirectoryName
		}
	}
}

function global:Test-TlcPackageInstall {
	Get-Content '\pkg\.tlc'
}