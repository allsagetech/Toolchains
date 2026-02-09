<#
Toolchains
Copyright (c) 2021 - 02-08-2026 U.S. Federal Government
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

# End-of-Life is 2026-04-30. See https://nodejs.org/en/about/releases/
$global:TlcPackageConfig = @{
	Name = 'node'
	Matcher = '^node-20\.'
}

function global:Install-TlcPackage {
	$Params = @{
		Owner = 'nodejs'
		Repo = 'node'
		TagPattern = '^v(20)\.([0-9]+)\.([0-9]+)$'
	}
	$Latest = Get-GitHubTag @Params
	$TlcPackageConfig.UpToDate = -not $Latest.Version.LaterThan($TlcPackageConfig.Latest)
	$TlcPackageConfig.Version = $Latest.Version.ToString()
	if ($TlcPackageConfig.UpToDate) {
		return
	}
	$Tag = $Latest.name
	$AssetName = "node-$Tag-win-x64.zip"
	$Params = @{
		AssetName = $AssetName
		AssetURL = "https://nodejs.org/dist/$Tag/$AssetName"
	}
	Install-BuildTool @Params
	Write-TlcVars @{
		env = @{
			path = (Get-ChildItem -Path '\pkg' -Recurse -Include 'node.exe' | Select-Object -First 1).DirectoryName
		}
	}
}

function global:Test-TlcPackageInstall {
	Toolchain exec (Get-TlcPkgUri) {
		node --version
	}
}